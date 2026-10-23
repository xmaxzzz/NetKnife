# Page «Wi-Fi обход»: NetKnife collects a walk for HelpDesk (protocol netknife-survey/1, lib\Collector.ps1).
#   • connection: «Подключить к Helpdesk» — the string from the web (or a bare code) → per-site token (DPAPI);
#     several objects can be connected, one is active;
#   • directory: object → plan → series from GET /sites, cached on disk, works offline;
#   • the walk itself (pages\Walk.ps1) on a read-only plan (pages\PlanView.ps1), the monitor (pages\Roam.ps1) and the
#     Wi-Fi scanner (pages\Wifi.ps1) as panels of this page;
#   • the outbox: «Стоп» queues the walk, a background worker sends it (gzip envelope, WAV in parts with resume),
#     the list shows the server stages and the link to the report in HelpDesk.

$script:CollectorLib = Join-Path $PSScriptRoot "..\lib\Collector.ps1"
$script:SvSel = @{ Key = ""; Conn = $null; Site = $null; Plan = $null; Series = $null; ImagePath = "" }
$script:SvQueueItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:SvPanels = @("PageWalk", "PageRoam", "PageWifi")
$script:SvKick = $false
$script:SvNetSig = ""
$script:SvDirAt = [DateTime]::MinValue
$script:SvSync = $false

# ---------------------------------------------------------------- connections (Settings.Collectors)

function Get-SurveyConns { return @(@($script:Settings.Collectors) | Where-Object { $_ -and $_.TokenEnc }) }
function Get-SurveyConnKey { param($C) return "$($C.Url)|$($C.Site.slug)" }
function Get-SurveyConn { param([string]$Key) return @(Get-SurveyConns | Where-Object { (Get-SurveyConnKey $_) -eq $Key }) | Select-Object -First 1 }
function Get-SurveyActiveConn { $C = Get-SurveyConn "$($script:Settings.CollectorActive)"; if (-not $C) { $C = @(Get-SurveyConns) | Select-Object -First 1 }; return $C }

function Save-SurveyConn {
    param($Rec)
    $K = Get-SurveyConnKey $Rec
    $script:Settings.Collectors = @(@(Get-SurveyConns | Where-Object { (Get-SurveyConnKey $_) -ne $K }) + @($Rec))
    Save-Settings
}

function Get-SurveyMe { param($C) if (-not $C -or -not $C.MeJson) { return $null }; try { return ("$($C.MeJson)" | ConvertFrom-Json -AsHashtable) } catch { return $null } }

function Format-SurveyConn {
    param($C)
    if (-not $C) { return "Не подключено к Helpdesk" }
    $Me = Get-SurveyMe $C
    $Host_ = ([Uri]$C.Url).Host
    return "$($C.Site.name) · $Host_ · токен …$($C.Last4)$(if ($Me) { " · $($Me['user']['name'])" })"
}

# ---------------------------------------------------------------- workers

$script:SvPairBody = {
    param($Q, $Ctl, $Lib, $Url, $Code, $Name, $Version, $LogPath)
    . $Lib
    $script:CollectorLogPath = $LogPath
    $R = Invoke-CollectorPair -Url $Url -Code $Code -Name $Name -Version $Version
    $Me = $null
    if ($R.Ok) { $Me = Get-CollectorMe @{ Url = $R.Url; Token = $R.Token; Version = $Version } }
    $Q.Enqueue(@{ Type = "cqpair"; R = $R; Me = $Me })
}

$script:SvMeBody = {
    param($Q, $Ctl, $Lib, $Key, $Url, $TokenEnc, $Version, $LogPath)
    . $Lib
    $script:CollectorLogPath = $LogPath
    $Q.Enqueue(@{ Type = "cqme"; Key = $Key; R = (Get-CollectorMe @{ Url = $Url; Token = (Unprotect-CollectorToken $TokenEnc); Version = $Version }) })
}

$script:SvDirBody = {
    param($Q, $Ctl, $Lib, $Conns, $Version, $DataDir, $LogPath)
    . $Lib
    $script:DataDir = $DataDir; $script:CollectorLogPath = $LogPath
    foreach ($K in $Conns.Keys) {
        $C = $Conns[$K]
        $R = Update-CollectorSites @{ Url = $C.Url; Token = (Unprotect-CollectorToken $C.TokenEnc); Version = $Version } $K
        $Q.Enqueue(@{ Type = "cqdir"; Key = $K; Ok = $R.Ok; Code = $R.Code; Error = $R.Error })
    }
}

$script:SvSendBody = {
    param($Q, $Ctl, $Lib, $Conns, $Version, $DataDir, $LogPath, $Force)
    . $Lib
    $script:DataDir = $DataDir; $script:CollectorLogPath = $LogPath
    foreach ($K in @($Conns.Keys)) { $Conns[$K].Token = Unprotect-CollectorToken $Conns[$K].TokenEnc; $Conns[$K].Remove("TokenEnc") }
    $On = { param($E) $Q.Enqueue(@{ Type = "cq"; Kind = $E.Kind; Key = $E.Key; Text = $E.Text; Site = "$($E.State.SiteName)"; Walk = "$($E.State.WalkId)"; Stage = "$($E.State.Stage)"; Rooms = $E.State.Rooms }) }.GetNewClosure()
    [void](Invoke-OutboxPass -Conns $Conns -Version $Version -OnEvent $On -Ctl $Ctl -Force:$Force)
}

$script:SvPlanBody = {
    param($Q, $Ctl, $Lib, $Url, $TokenEnc, $Version, $Site, $Files, $LogPath)
    . $Lib
    $script:CollectorLogPath = $LogPath
    $Ctx = @{ Url = $Url; Token = (Unprotect-CollectorToken $TokenEnc); Version = $Version }
    foreach ($F in $Files) { $Q.Enqueue(@{ Type = "cqplan"; R = (Send-CollectorPlanImport $Ctx $Site $F) }) }
}

function Get-SurveyConnMap {
    $M = @{}
    foreach ($C in @(Get-SurveyConns)) { $Me = Get-SurveyMe $C; $M[(Get-SurveyConnKey $C)] = @{ Url = $C.Url; TokenEnc = $C.TokenEnc; Limits = $(if ($Me) { $Me['limits'] } else { @{} }) } }
    return $M
}

# one pass over the outbox in the background; a new request during a pass re-runs it afterwards
function Start-SurveySend {
    param([switch]$Now)
    if (Test-WorkerRunning "cq-send") { $script:SvKick = $true; return }
    $Map = Get-SurveyConnMap
    [void](Start-Worker -Name "cq-send" -Body $script:SvSendBody -ArgList @($script:CollectorLib, $Map, $script:AppVersion, $script:DataDir, $script:LogPath, [bool]$Now) -OnMessage {
        param($M)
        if ($M.Type -ne "cq") { return }
        switch ($M.Kind) {
            "sent" { Show-Toast "Обход отправлен в Helpdesk · $($M.Site)" }
            "error" { Show-Toast "Обход не отправлен: $($M.Text)" "fail" }
            "stage" { if ($M.Stage -eq "done") { Show-Toast "Helpdesk: обход обработан, помещений $($M.Rooms)" } elseif ($M.Stage -eq "failed") { Show-Toast "Helpdesk: ошибка обработки обхода — повторить можно в вебе" "fail" } }
        }
        Update-SurveyQueue
    } -OnDone {
        Update-SurveyQueue
        if ($script:SvKick) { $script:SvKick = $false; Start-SurveySend }
    })
}

function Start-SurveyDirectory {
    param([switch]$Manual)
    if (Test-WorkerRunning "cq-dir") { return }
    $Map = @{}
    foreach ($C in @(Get-SurveyConns)) { $Map[(Get-SurveyConnKey $C)] = @{ Url = $C.Url; TokenEnc = $C.TokenEnc } }
    if (-not $Map.Count) { if ($Manual) { Show-Toast "Сначала подключите сборщик к Helpdesk" "warn" }; return }
    $script:SvDirAt = [DateTime]::Now
    if ($Manual) { $Ui.SvHint.Text = "Обновляю справочник…" }
    [void](Start-Worker -Name "cq-dir" -Body $script:SvDirBody -ArgList @($script:CollectorLib, $Map, $script:AppVersion, $script:DataDir, $script:LogPath) -State @{ Manual = [bool]$Manual } -OnMessage {
        param($M)
        if ($M.Type -ne "cqdir") { return }
        if (-not $M.Ok) {
            $C = Get-SurveyConn $M.Key
            $Msg = $(if ($M.Code -eq 401) { "Токен объекта «$($C.Site.name)» не принят — подключите сборщик заново кодом" } elseif ($M.Code -eq 0) { "Нет связи с Helpdesk — работаю по сохранённому справочнику" } else { "Справочник не обновлён: $($M.Error)" })
            if ($State.Manual -or $M.Code -eq 401) { Show-Toast $Msg $(if ($M.Code -eq 401) { "fail" } else { "warn" }) }
            $script:SvDirError = $Msg
        } else { $script:SvDirError = "" }
    } -OnDone { Update-SurveySites })
}

# ---------------------------------------------------------------- directory → object / plan / series

function Get-SurveySiteItems {
    $Cache = Read-CollectorSitesCache
    $L = foreach ($C in @(Get-SurveyConns)) {
        $K = Get-SurveyConnKey $C
        $D = $Cache[$K]
        $Sites = @($(if ($D) { $D['sites'] } else { @() }) | Where-Object { $_ })
        if (-not $Sites.Count) { [pscustomobject]@{ Key = "$K|$($C.Site.slug)"; Label = "$($C.Site.name) (справочник не загружен)"; Conn = $C; Site = $null; CanWrite = $false }; continue }
        foreach ($S in $Sites) {
            [pscustomobject]@{ Key = "$K|$($S['slug'])"; Label = "$($S['name'])$(if (-not $S['can_write']) { '  · только просмотр' })"; Conn = $C; Site = $S; CanWrite = [bool]$S['can_write'] }
        }
    }
    return @($L)
}

function Update-SurveySites {
    $script:SvSync = $true
    $Items = @(Get-SurveySiteItems)
    $Ui.SvSite.ItemsSource = $Items; $Ui.SvSite.DisplayMemberPath = "Label"
    $Want = "$($script:Settings.CollectorSel.Key)"
    $Act = Get-SurveyActiveConn
    $Pick = @($Items | Where-Object { $_.Key -eq $Want }) | Select-Object -First 1
    if (-not $Pick -and $Act) { $Pick = @($Items | Where-Object { $_.Key -like "$(Get-SurveyConnKey $Act)|*" }) | Select-Object -First 1 }
    if (-not $Pick) { $Pick = $Items | Select-Object -First 1 }
    $Ui.SvSite.SelectedItem = $Pick
    $script:SvSync = $false
    Set-SurveySite
}

function Set-SurveySite {
    if ($script:SvSync) { return }
    $I = $Ui.SvSite.SelectedItem
    $script:SvSel.Conn = $(if ($I) { $I.Conn } else { $null }); $script:SvSel.Site = $(if ($I) { $I.Site } else { $null }); $script:SvSel.Key = $(if ($I) { $I.Key } else { "" })
    if ($I -and $I.Conn -and "$($script:Settings.CollectorActive)" -ne (Get-SurveyConnKey $I.Conn)) { $script:Settings.CollectorActive = Get-SurveyConnKey $I.Conn; Save-Settings }
    $Plans = @($(if ($I -and $I.Site) { @($I.Site['plans']) } else { @() }) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Id = [int]$_['id']; Label = "$($_['name'])"; Plan = $_ } })
    $script:SvSync = $true
    $Ui.SvPlan.ItemsSource = $Plans; $Ui.SvPlan.DisplayMemberPath = "Label"
    $Sel = $script:Settings.CollectorSel
    $Want = $(if ($Sel -and "$($Sel.Key)" -eq $script:SvSel.Key) { [int]$Sel.PlanId } elseif ($I -and $I.Conn.PlanId) { [int]$I.Conn.PlanId } else { 0 })
    $Ui.SvPlan.SelectedItem = $(@($Plans | Where-Object { $_.Id -eq $Want }) + @($Plans) | Select-Object -First 1)
    $script:SvSync = $false
    Set-SurveyPlan
}

function Set-SurveyPlan {
    if ($script:SvSync) { return }
    $P = $Ui.SvPlan.SelectedItem
    $script:SvSel.Plan = $(if ($P) { $P.Plan } else { $null })
    $script:SvSel.ImagePath = $(if ($P) { Get-CollectorPlanImagePath $P.Plan } else { "" })
    if ($script:SvSel.ImagePath -and -not (Test-Path $script:SvSel.ImagePath)) { $script:SvSel.ImagePath = "" }
    $L = [System.Collections.Generic.List[object]]::new()
    $L.Add([pscustomobject]@{ Value = "before"; Name = "Исходная"; Phase = "before"; Label = "До — «Исходная»" })
    $L.Add([pscustomobject]@{ Value = "after"; Name = "После правок"; Phase = "after"; Label = "После — последняя серия «после»" })
    foreach ($S in @($(if ($P) { @($P.Plan['series']) } else { @() }) | Where-Object { $_ })) {
        $Nm = "$($S['name'])"
        if ($Nm -and $Nm -ne "Исходная") { $L.Add([pscustomobject]@{ Value = $Nm; Name = $Nm; Phase = "$($S['phase'])"; Label = "$Nm ($(if ("$($S['phase'])" -eq 'after') { 'после' } else { 'до' }))" }) }
    }
    $script:SvSync = $true
    $Ui.SvSeries.ItemsSource = @($L); $Ui.SvSeries.DisplayMemberPath = "Label"
    $Sel = $script:Settings.CollectorSel
    $Want = $(if ($Sel -and "$($Sel.Key)" -eq $script:SvSel.Key -and [int]$Sel.PlanId -eq $(if ($P) { $P.Id } else { -1 })) { "$($Sel.Series)" } else { "before" })
    $Ui.SvSeries.SelectedItem = $(@($L | Where-Object { $_.Value -eq $Want }) + @($L) | Select-Object -First 1)
    $script:SvSync = $false
    Set-SurveySeries
}

function Set-SurveySeries {
    if ($script:SvSync) { return }
    $script:SvSel.Series = $Ui.SvSeries.SelectedItem
    if ($script:SvSel.Key) {
        $script:Settings.CollectorSel = @{ Key = $script:SvSel.Key; PlanId = $(if ($Ui.SvPlan.SelectedItem) { $Ui.SvPlan.SelectedItem.Id } else { 0 }); Series = $(if ($script:SvSel.Series) { $script:SvSel.Series.Value } else { "" }) }
        Save-Settings
    }
    Update-SurveyHint
    Update-WalkPanel
    Update-PageSub
}

function Test-SurveyCanStart {
    $I = $Ui.SvSite.SelectedItem
    return [bool]($I -and $I.Conn -and $I.Site -and $I.CanWrite -and $script:SvSel.Plan -and $script:SvSel.Series)
}

# what goes into the envelope; $null (with a toast) when «Старт» is not possible
function Get-SurveyTarget {
    $I = $Ui.SvSite.SelectedItem
    if (-not $I -or -not $I.Conn) { Show-Toast "Сначала подключите сборщик к Helpdesk" "warn"; return $null }
    if (-not $I.Site) { Show-Toast "Справочник объекта не загружен — нужна связь с Helpdesk («Обновить»)" "warn"; return $null }
    if (-not $I.CanWrite) { Show-Toast "Нет прав загружать обходы на этот объект" "warn"; return $null }
    if (-not $script:SvSel.Plan) { Show-Toast "У объекта нет плана — создайте его в Helpdesk" "warn"; return $null }
    if (-not $script:SvSel.Series) { Show-Toast "Выберите серию" "warn"; return $null }
    $S = $script:SvSel.Series
    return @{ Url = $I.Conn.Url; Site = "$($I.Site['slug'])"; SiteName = "$($I.Site['name'])"; PlanId = [int]$script:SvSel.Plan['id']; PlanName = "$($script:SvSel.Plan['name'])"
        Series = $S.Value; SeriesLabel = $S.Name; Phase = $S.Phase; ImagePath = $script:SvSel.ImagePath }
}

function Update-SurveyHint {
    $C = Get-SurveyActiveConn
    $Ui.SvConnText.Text = Format-SurveyConn $C
    $I = $Ui.SvSite.SelectedItem
    $Me = $(if ($I -and $I.Conn) { Get-SurveyMe $I.Conn } else { $null })
    $H = @()
    if (-not @(Get-SurveyConns).Count) { $H += "Подключите сборщик: в Helpdesk «Объект → Инструменты → Wi-Fi обследование → Подключить NetKnife», строку вставьте сюда кнопкой «Подключить к Helpdesk»." }
    elseif ($I -and -not $I.Site) { $H += "Справочник объекта ещё не загружен — нужна связь с Helpdesk." }
    elseif ($I -and -not $I.CanWrite) { $H += "На этом объекте у вас нет права загружать обходы — «Старт» недоступен." }
    elseif ($I -and -not $script:SvSel.Plan) { $H += "У объекта нет плана — создайте его в Helpdesk (Объект → Инструменты → Wi-Fi)." }
    if ($Me -and -not $Me['scope']) { $H += "Токен устаревший (на все объекты) — подключите заново кодом." }
    if ($Me -and "$($Me['transcriber'])" -eq "none") { $H += "Сервер не распознаёт голос: помещения будут определяться только по кликам и выбору из списка." }
    if ($script:SvDirError) { $H += $script:SvDirError }
    $Ui.SvHint.Text = $H -join "  "
    $Ui.SvHint.Visibility = $(if ($H.Count) { "Visible" } else { "Collapsed" })
}

# ---------------------------------------------------------------- outbox in the UI

function Add-SurveyOutbox {
    param([string]$WalkPath, [string]$Wav, [hashtable]$Target)
    try { return Add-OutboxWalk -WalkJson ([IO.File]::ReadAllText($WalkPath, [Text.Encoding]::UTF8)) -WavPath $Wav -Target $Target -Version $script:AppVersion }
    catch { return @{ Ok = $false; Error = "$_" } }
}

function Get-SurveyReportUrl {
    param($St)
    $U = "$($St.ReportUrl)"
    if ($U -like "/*") { $U = "$($St.Url)$U" }
    if (-not $U) { $U = "$($St.Url)/objects/$($St.Site)/tools/wifi_survey/$($St.PlanId)" }
    return $U
}

function Get-SurveyStageText {
    param($St)
    switch ("$($St.Stage)") {
        "received" { return "принят сервером" }
        "audio" { return "ждём запись" }
        "stt" { return "распознаём голос" }
        "timeline" { return "строим хронологию" }
        "calc" { return "считаем серию" }
        "done" { return "готов$(if ($null -ne $St.Rooms) { " · помещений $($St.Rooms)" })" }
        "failed" { return "ошибка обработки: $($St.StageError) (повторить — в Helpdesk)" }
        default { return "" }
    }
}

function Update-SurveyQueue {
    $Items = @(Get-OutboxItems)
    # the timer calls this every 10 s: rebuild the rows (and their buttons) only when something changed
    $Sig = (@($Items | ForEach-Object { $S = $_.State; "$($_.Key)|$($S.State)|$($S.Step)|$(@($S.PartsDone).Count)|$($S.Stage)|$($S.NextAt)|$($S.LastError)|$($_.Paused)" }) -join "`n")
    if ($Sig -eq $script:SvQueueSig -and $script:SvQueueItems.Count -eq $Items.Count) { return }
    $script:SvQueueSig = $Sig
    $script:SvQueueItems.Clear()
    foreach ($I in ($Items | Sort-Object { "$($_.State.QueuedAt)" } -Descending)) {
        $St = $I.State
        $Started = ConvertTo-CollectorDate $St.Started
        $Title = "$(if ($Started) { $Started.ToString('dd.MM HH:mm') }) · $($St.SiteName) · $(if ($St.SeriesLabel) { $St.SeriesLabel } else { $St.Series }) · $(Format-WalkTime ([double]$St.Duration))$(if ($St.Note) { " · $($St.Note)" })"
        $B = @()
        switch ($St.State) {
            "queued" {
                $Nx = ConvertTo-CollectorDate $St.NextAt
                $Txt = "в очереди$(if ($I.Paused) { ' · пауза: токен не принят' } elseif ($Nx -and $Nx -gt [DateTime]::Now) { " · попытка в $($Nx.ToString('HH:mm:ss'))" })$(if ($St.LastError) { " · $($St.LastError)" })"
                $Kind = $(if ($St.LastError) { "warn" } else { "wait" })
            }
            "sending" { $Txt = $(if ($St.Step -eq "parts" -and $St.PartsTotal) { "запись: $(@($St.PartsDone).Count) из $($St.PartsTotal) частей" } elseif ($St.Step -eq "complete") { "запись: сборка на сервере" } else { "отправляется" }); $Kind = "wait" }
            "sent" {
                $Txt = "отправлено · id $($St.ServerId)$(if (Get-SurveyStageText $St) { ' · ' + (Get-SurveyStageText $St) })"
                $Kind = $(if ($St.Stage -eq "failed") { "fail" } else { "ok" })
                $B += @{ T = "Открыть в Helpdesk"; A = "open" }
            }
            "error" {
                $Txt = "ошибка: $($St.LastError)"; $Kind = "fail"
                switch ($St.ErrKind) {
                    "conflict" { $B += @{ T = "Отправить как новый"; A = "new" } }
                    "unauthorized" { $B += @{ T = "Отправить снова"; A = "retry" } }
                    { $_ -in @("notfound", "forbidden") } { $B += @{ T = "Под выбранный план"; A = "retarget" } }
                }
                $B += @{ T = "Убрать из очереди"; A = "drop" }
            }
            default { $Txt = "$($St.State)"; $Kind = "info" }
        }
        $Row = [ordered]@{ Key = $I.Key; Title = $Title; Status = $Txt; Kind = $Kind }
        for ($n = 1; $n -le 3; $n++) {
            $X = $(if ($B.Count -ge $n) { $B[$n - 1] } else { $null })
            $Row["B${n}Text"] = $(if ($X) { $X.T } else { "" }); $Row["B${n}Tag"] = $(if ($X) { "cq:$($X.A)|$($I.Key)" } else { "" }); $Row["B${n}Vis"] = $(if ($X) { "Visible" } else { "Collapsed" })
        }
        $script:SvQueueItems.Add([pscustomobject]$Row)
    }
    $Ui.SvQueueEmpty.Visibility = $(if ($script:SvQueueItems.Count) { "Collapsed" } else { "Visible" })
    $script:SvQueueCount = @($Items | Where-Object { $_.State.State -in @("queued", "sending") }).Count
    $script:SvQueueErrors = @($Items | Where-Object { $_.State.State -eq "error" }).Count
    Update-PageSub
}

# buttons in the queue rows: Tag = "cq:<action>|<site>/<dir>"
function Invoke-SurveyQueueAction {
    param([string]$Val)
    $A, $Key = $Val -split '\|', 2
    $Dir = Get-OutboxPath $Key
    if (-not (Test-Path $Dir)) { Update-SurveyQueue; return }
    $St = Read-OutboxState $Dir
    switch ($A) {
        "open" { Start-Process (Get-SurveyReportUrl $St) }
        "drop" {
            if (-not (Show-Confirm "Убрать из очереди?" "Обход «$($St.WalkId)» не уйдёт в Helpdesk. Файл обхода в папке wifiplan останется." "Убрать" -Danger)) { return }
            Remove-Item $Dir -Recurse -Force
        }
        "new" { [void](Reset-OutboxAsNew $Dir); Start-SurveySend -Now }
        "retry" {
            if (Test-Path (Join-Path (Split-Path $Dir -Parent) ".paused")) { Show-Toast "Сначала подключите сборщик заново кодом («Подключить к Helpdesk»)" "warn"; return }
            Reset-OutboxRetry $Dir; Start-SurveySend -Now
        }
        "retarget" {
            $T = Get-SurveyTarget
            if (-not $T) { return }
            if (-not (Show-Confirm "Пересобрать конверт?" "Обход «$($St.WalkId)» уйдёт на «$($T.SiteName)», план «$($T.PlanName)», серия «$($T.SeriesLabel)»." "Пересобрать")) { return }
            Reset-OutboxTarget $Dir $T; Start-SurveySend -Now
        }
    }
    Update-SurveyQueue
}

function Get-SurveySub {
    $P = @()
    if ($script:Walk -and $script:Walk.Running) { $P += "идёт обход" }
    if ($script:SvSel.Site) { $P += "$($script:SvSel.Site['name'])$(if ($script:SvSel.Plan) { ' · ' + $script:SvSel.Plan['name'] })" }
    elseif (-not @(Get-SurveyConns).Count) { $P += "сбор обхода для Helpdesk" }
    if ($script:SvQueueCount) { $P += "в очереди $($script:SvQueueCount)" }
    if ($script:SvQueueErrors) { $P += "ошибок $($script:SvQueueErrors)" }
    return $P -join " · "
}

# ---------------------------------------------------------------- connect dialog

function Update-SurveyConnList {
    $D = $script:SvDlg; if (-not $D) { return }
    $Act = "$($script:Settings.CollectorActive)"
    $D.List.ItemsSource = @(Get-SurveyConns | ForEach-Object {
        $K = Get-SurveyConnKey $_
        [pscustomobject]@{ Key = $K; Label = "$(if ($K -eq $Act) { '● ' } else { '   ' })$(Format-SurveyConn $_)" }
    })
    $D.List.DisplayMemberPath = "Label"
}

function Show-SurveyConnectDialog {
    $D = New-Dialog "Подключение к Helpdesk" @"
<StackPanel>
    <TextBlock Text="Подключить к Helpdesk" FontFamily="{StaticResource DisplayFont}" FontSize="18" FontWeight="SemiBold"/>
    <TextBlock Text="В Helpdesk: Объект → Инструменты → Wi-Fi обследование → «Подключить NetKnife» → «Скопировать». Вставьте строку сюда (или голый код — тогда сервер тот же, что в прошлый раз). Код одноразовый, действует 15 минут." Foreground="{StaticResource Sub}" TextWrapping="Wrap" FontSize="12.5" Margin="0,6,0,10"/>
    <DockPanel>
        <Button x:Name="FPairBtn" DockPanel.Dock="Right" Style="{StaticResource AccentBtn}" Content="Подключить" Padding="14,7" Margin="8,0,0,0" IsDefault="True"/>
        <TextBox x:Name="FPair" Style="{StaticResource MonoField}" Tag="строка подключения"/>
    </DockPanel>
    <TextBlock Text="ПОДКЛЮЧЁННЫЕ ОБЪЕКТЫ  (● — активный)" Style="{StaticResource Caption}" Margin="0,16,0,4"/>
    <ListBox x:Name="FList" Height="130" Background="Transparent" BorderThickness="1" BorderBrush="{StaticResource Line}" Foreground="{StaticResource Text}" FontSize="12.5"/>
    <TextBlock x:Name="FInfo" FontFamily="{StaticResource MonoFont}" FontSize="12" TextWrapping="Wrap" Margin="0,8,0,0" Foreground="{StaticResource Sub}"/>
    <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
        <Button x:Name="FActive" Style="{StaticResource Btn}" Content="Сделать активным" Padding="12,6"/>
        <Button x:Name="FCheck" Style="{StaticResource Btn}" Content="Проверить" Padding="12,6" Margin="8,0,0,0"/>
        <Button x:Name="FDrop" Style="{StaticResource Btn}" Content="Отключить" Padding="12,6" Margin="8,0,0,0"/>
        <Button Style="{StaticResource GhostBtn}" Content="Закрыть" Padding="12,6" Margin="24,0,0,0" IsCancel="True"/>
    </StackPanel>
</StackPanel>
"@ 620
    $script:SvDlg = @{ Win = $D; Pair = $D.FindName("FPair"); List = $D.FindName("FList"); Info = $D.FindName("FInfo"); PairBtn = $D.FindName("FPairBtn") }
    Update-SurveyConnList
    $D.FindName("FPairBtn").Add_Click({
        $X = $script:SvDlg
        $P = ConvertFrom-PairString $X.Pair.Text "$($script:Settings.CollectorUrl)"
        if ($P.Error) { $X.Info.Text = $P.Error; $X.Info.Foreground = Get-Brush "Fail"; return }
        $X.Info.Text = "Подключаюсь к $(([Uri]$P.Url).Host)…"; $X.Info.Foreground = Get-Brush "Warn"; $X.PairBtn.IsEnabled = $false
        [void](Start-Worker -Name "cq-pair" -Replace -Body $script:SvPairBody -ArgList @($script:CollectorLib, $P.Url, $P.Code, "NetKnife $env:COMPUTERNAME", $script:AppVersion, $script:LogPath) -OnMessage {
            param($M)
            if ($M.Type -ne "cqpair") { return }
            Complete-SurveyPair $M.R $M.Me
        })
    })
    $D.FindName("FActive").Add_Click({
        $S = $script:SvDlg.List.SelectedItem; if (-not $S) { return }
        $script:Settings.CollectorActive = $S.Key; $script:Settings.CollectorSel = $null; Save-Settings
        Update-SurveyConnList; Update-SurveySites
    })
    $D.FindName("FCheck").Add_Click({
        $S = $script:SvDlg.List.SelectedItem
        $C = $(if ($S) { Get-SurveyConn $S.Key } else { Get-SurveyActiveConn })
        if (-not $C) { return }
        Start-SurveyCheck $C
    })
    $D.FindName("FDrop").Add_Click({
        $S = $script:SvDlg.List.SelectedItem; if (-not $S) { return }
        $C = Get-SurveyConn $S.Key
        if (-not (Show-Confirm "Отключить объект?" "Токен «$($C.Site.name)» удалится из NetKnife. Обходы этого объекта в очереди подождут нового подключения. Отозвать токен на сервере — в Helpdesk, блок «Сборщики»." "Отключить" -Danger)) { return }
        $script:Settings.Collectors = @(Get-SurveyConns | Where-Object { (Get-SurveyConnKey $_) -ne $S.Key })
        if ("$($script:Settings.CollectorActive)" -eq $S.Key) { $script:Settings.CollectorActive = "" }
        Save-Settings
        Update-SurveyConnList; Update-SurveySites
    })
    $script:SvDlg.List.Add_SelectionChanged({ $S = $script:SvDlg.List.SelectedItem; if ($S) { $C = Get-SurveyConn $S.Key; $Me = Get-SurveyMe $C; $script:SvDlg.Info.Text = $(if ($Me) { Format-CollectorMe $Me } else { "не проверено — «Проверить»" }); $script:SvDlg.Info.Foreground = Get-Brush "Sub" } })
    $D.Add_ContentRendered({ [void]$script:SvDlg.Pair.Focus() })
    [void]$D.ShowDialog()
    $script:SvDlg = $null
    Update-SurveyHint
}

function Complete-SurveyPair {
    param($R, $Me)
    $X = $script:SvDlg
    if ($X) { $X.PairBtn.IsEnabled = $true }
    if (-not $R.Ok) {
        if ($X) { $X.Info.Text = $R.Error; $X.Info.Foreground = Get-Brush "Fail" } else { Show-Toast $R.Error "fail" }
        return
    }
    $Rec = @{ Url = $R.Url; Site = @{ slug = $R.Site.slug; name = $R.Site.name }; TokenId = $R.TokenId; Last4 = $R.Last4; TokenEnc = (Protect-CollectorToken $R.Token); PlanId = $R.PlanId
        MeJson = $(if ($Me -and $Me.Ok) { $Me.Me | ConvertTo-Json -Depth 8 -Compress } else { "" }); CheckedAt = [DateTime]::Now.ToString("o") }
    Save-SurveyConn $Rec
    $script:Settings.CollectorUrl = $R.Url
    $script:Settings.CollectorActive = Get-SurveyConnKey $Rec
    Save-Settings
    Clear-OutboxPause $R.Site.slug
    if ($X) {
        $X.Pair.Text = ""
        $X.Info.Text = "Подключено: $($R.Site.name)$(if ($Me -and $Me.Ok) { ' · ' + (Format-CollectorMe $Me.Me) })"; $X.Info.Foreground = Get-Brush "Ok"
        Update-SurveyConnList
    }
    Show-Toast "Helpdesk: подключён объект «$($R.Site.name)»"
    Start-SurveyDirectory
    Update-SurveyQueue
}

function Start-SurveyCheck {
    param($C)
    if ($script:SvDlg) { $script:SvDlg.Info.Text = "Проверяю…"; $script:SvDlg.Info.Foreground = Get-Brush "Warn" }
    [void](Start-Worker -Name "cq-me" -Replace -Body $script:SvMeBody -ArgList @($script:CollectorLib, (Get-SurveyConnKey $C), $C.Url, $C.TokenEnc, $script:AppVersion, $script:LogPath) -OnMessage {
        param($M)
        if ($M.Type -ne "cqme") { return }
        $C = Get-SurveyConn $M.Key
        $Txt = ""; $Kind = "Ok"
        if ($M.R.Ok) {
            $C.MeJson = $M.R.Me | ConvertTo-Json -Depth 8 -Compress; $C.CheckedAt = [DateTime]::Now.ToString("o"); Save-SurveyConn $C
            $Txt = Format-CollectorMe $M.R.Me
            if (-not $M.R.Me['scope']) { $Kind = "Warn" }
        } else { $Txt = $M.R.Error; $Kind = "Fail" }
        if ($script:SvDlg) { $script:SvDlg.Info.Text = $Txt; $script:SvDlg.Info.Foreground = Get-Brush $Kind; Update-SurveyConnList } else { Show-Toast $Txt $(if ($Kind -eq "Ok") { "info" } else { "warn" }) }
        Update-SurveyHint
    })
}

# ---------------------------------------------------------------- old local data → HelpDesk

function Get-SurveyLegacyPlans {
    if (-not (Test-Path $script:WplanDir)) { return @() }
    return @(Get-ChildItem $script:WplanDir -Filter *.json | Where-Object { $_.Name -notmatch '\.walk-|\.meta\.json$' })
}

# old plans wifiplan\<site>.json (+ picture) → POST plans/import + PUT plans/{id}/image; local files stay
function Show-SurveyPlanImport {
    $T = $Ui.SvSite.SelectedItem
    if (-not $T -or -not $T.Conn -or -not $T.Site) { Show-Toast "Выберите подключённый объект — планы уйдут на него" "warn"; return }
    $Files = @(Get-SurveyLegacyPlans)
    if (-not $Files.Count) { Show-Toast "Старых планов в папке wifiplan нет" "info"; return }
    $D = New-Dialog "Старые планы → Helpdesk" @"
<StackPanel>
    <TextBlock Text="Отправить старые планы в Helpdesk" FontFamily="{StaticResource DisplayFont}" FontSize="18" FontWeight="SemiBold"/>
    <TextBlock x:Name="FText" Foreground="{StaticResource Sub}" TextWrapping="Wrap" FontSize="12.5" Margin="0,6,0,10"/>
    <ListBox x:Name="FList" Height="200" SelectionMode="Multiple" Background="Transparent" BorderThickness="1" BorderBrush="{StaticResource Line}" Foreground="{StaticResource Text}" FontSize="12.5"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Button Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="Отправить" MinWidth="120" Margin="8,0,0,0" IsDefault="True"/>
    </StackPanel>
</StackPanel>
"@ 560
    $D.FindName("FText").Text = "Каждый выбранный план станет новым планом объекта «$($T.Site['name'])» (с картинкой, если она есть). Файлы в %APPDATA%\NetKnife\wifiplan не удаляются."
    $L = $D.FindName("FList")
    $L.ItemsSource = @($Files | ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Label = "$($_.BaseName)   ·   $($_.LastWriteTime.ToString('dd.MM.yyyy'))" } }); $L.DisplayMemberPath = "Label"
    $L.SelectAll()
    $D.FindName("FOk").Add_Click({ $D.DialogResult = $true })
    if (-not $D.ShowDialog()) { return }
    $Sel = @($L.SelectedItems | ForEach-Object { $_.Path })
    if (-not $Sel.Count) { return }
    $script:SvPlanResults = [System.Collections.Generic.List[object]]::new()
    Show-Toast "Отправляю планов: $($Sel.Count)…" "info"
    [void](Start-Worker -Name "cq-plans" -Replace -Body $script:SvPlanBody -ArgList @($script:CollectorLib, $T.Conn.Url, $T.Conn.TokenEnc, $script:AppVersion, "$($T.Site['slug'])", $Sel, $script:LogPath) -OnMessage {
        param($M)
        if ($M.Type -eq "cqplan") { $script:SvPlanResults.Add($M.R) }
    } -OnDone {
        $R = @($script:SvPlanResults)
        $Ok = @($R | Where-Object { $_.Ok }).Count
        $Bad = @($R | Where-Object { $_.Error } | ForEach-Object { "$($_.Name): $($_.Error)" })
        if ($Bad.Count) { Show-Confirm "Старые планы" "Принято планов: $Ok из $($R.Count)." "OK" -Detail ($Bad -join "`n") | Out-Null } else { Show-Toast "Планы в Helpdesk: $Ok" }
        Start-SurveyDirectory
    })
}

# old walks wifiplan\*.walk-*.json → the queue (copy without Words/Phrases/Timeline/Notes); incompatible files stay
function Add-SurveyLegacyWalks {
    $T = Get-SurveyTarget
    if (-not $T) { return }
    $Dlg = New-Object Microsoft.Win32.OpenFileDialog
    $Dlg.Title = "Старая прогулка → Helpdesk (объект «$($T.SiteName)», план «$($T.PlanName)»)"; $Dlg.Filter = "Прогулки NetKnife (*.walk-*.json)|*.walk-*.json"; $Dlg.Multiselect = $true
    if (Test-Path $script:WplanDir) { $Dlg.InitialDirectory = $script:WplanDir }
    if (-not $Dlg.ShowDialog($script:Win)) { return }
    $Ok = 0; $Bad = @()
    foreach ($F in @($Dlg.FileNames)) {
        $R = $(try { Add-OutboxLegacyWalk -Path $F -Target $T -Version $script:AppVersion } catch { @{ Ok = $false; Error = "$(Split-Path $F -Leaf): $_" } })
        if ($R.Ok) { $Ok++ } else { $Bad += $R.Error }
    }
    Update-SurveyQueue
    if ($Ok) { Start-SurveySend -Now }
    if ($Bad.Count) { Show-Toast "В очередь: $Ok · не подходят (файлы остались на месте): $($Bad -join '; ')" "warn" } else { Show-Toast "Старые прогулки в очереди: $Ok" }
}

# ---------------------------------------------------------------- start-up

# a walk cut by a crash (.json.partial without .json): offer to send it, Duration = the last T in the file
function Invoke-SurveyRecover {
    if (-not (Test-Path $script:WplanDir)) { return }
    foreach ($P in @(Get-ChildItem $script:WplanDir -Filter "*.walk-*.json.partial")) {
        $Base = $P.FullName -replace '\.json\.partial$', ''
        if (Test-Path "$Base.json") { Remove-Item $P.FullName -Force; continue }
        $Meta = $(try { Get-Content "$Base.meta.json" -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch { $null })
        if (-not $Meta) { Write-AppLog "walk recover: нет $Base.meta.json"; continue }
        if (-not (Show-Confirm "Незавершённый обход" "Обход от $($P.LastWriteTime.ToString('dd.MM HH:mm')) на «$($Meta.SiteName)» не был остановлен (программа закрылась). Отправить незавершённый обход в Helpdesk?" "Отправить")) { continue }
        try {
            $N = [System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($P.FullName, [Text.Encoding]::UTF8))
            $J = [IO.File]::ReadAllText($P.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json -AsHashtable
            $Last = 0.1
            foreach ($K in @("Clicks", "Marks", "Conn", "Scans", "Events", "Rooms")) { foreach ($X in @($J[$K])) { if ($X -and [double]$X['T'] -gt $Last) { $Last = [double]$X['T'] } } }
            $N["Duration"] = [System.Text.Json.Nodes.JsonNode][double][Math]::Round($Last, 1)
            Write-CollectorFile "$Base.json" ($N.ToJsonString((Get-CollectorJsonOptions)))
            $Wav = "$Base.wav"
            if (Test-Path $Wav) { [void](Repair-CollectorWav $Wav) } else { $Wav = "" }
            $T = @{}; foreach ($K in $Meta.Keys) { $T[$K] = $Meta[$K] }
            $R = Add-SurveyOutbox "$Base.json" $Wav $T
            if ($R.Ok) { Remove-Item $P.FullName -Force } else { Show-Toast "Не поставлен в очередь: $($R.Error)" "fail" }
        } catch { Write-AppLog "walk recover ${Base}: $_"; Show-Toast "Незавершённый обход не прочитан: $_" "fail" }
    }
}

# the local speech engine is gone: offer once to free its folder (up to ~475 MB)
function Invoke-SurveySpeechCleanup {
    if ($script:Settings.SpeechCleanupAsked) { return }
    $D = Join-Path $script:DataDir "whisper"
    if (-not (Test-Path $D)) { return }
    $script:Settings.SpeechCleanupAsked = $true; Save-Settings
    $Mb = [Math]::Round(((Get-ChildItem $D -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB)
    if (Show-Confirm "Удалить локальное распознавание речи?" "Голос теперь распознаёт сервер Helpdesk. Папка $D ($Mb МБ) больше не нужна. Удалить её?" "Удалить" -Danger) {
        try { Remove-Item $D -Recurse -Force; Show-Toast "Папка распознавания удалена ($Mb МБ)" } catch { Show-Toast "Не удалось удалить: $_" "fail" }
    }
}

function Invoke-SurveyStartup {
    try { $N = Remove-OutboxExpired; if ($N) { Write-AppLog "outbox: удалено отправленных старше 14 дней — $N" } } catch { Write-AppLog "outbox cleanup: $_" }
    try { Invoke-SurveyRecover } catch { Write-AppLog "walk recover: $_" }
    try { Invoke-SurveySpeechCleanup } catch { Write-AppLog "speech cleanup: $_" }
    Update-SurveyQueue
    Start-SurveySend -Now
}

function Get-SurveyNetSig {
    try {
        return (@([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { $_.OperationalStatus -eq "Up" } | ForEach-Object {
            $_.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq "InterNetwork" } | ForEach-Object { "$($_.Address)" }
        }) | Sort-Object) -join ","
    } catch { return "" }
}

# every 10 s: a due attempt (NextAt / polling), or the network changed → send now
function Invoke-SurveyTick {
    $Sig = Get-SurveyNetSig
    $Changed = ($script:SvNetSig -and $Sig -ne $script:SvNetSig)
    $script:SvNetSig = $Sig
    if ($Changed) { Start-SurveySend -Now; return }
    $Due = @(Get-OutboxItems | Where-Object { Test-OutboxDue $_ }).Count
    if ($Due) { Start-SurveySend }
    if ($script:Page -eq "wifi") { Update-SurveyQueue }
}

# ---------------------------------------------------------------- page

function Show-SurveyPanel {
    param([string]$Name)
    foreach ($N in $script:SvPanels) { $Ui[$N].Visibility = $(if ($N -eq $Name) { "Visible" } else { "Collapsed" }) }
    $Ui.SvTabWalk.Style = $script:Win.FindResource($(if ($Name -eq "PageWalk") { "Btn" } else { "GhostBtn" }))
    $Ui.SvTabRoam.Style = $script:Win.FindResource($(if ($Name -eq "PageRoam") { "Btn" } else { "GhostBtn" }))
    $Ui.SvTabAir.Style = $script:Win.FindResource($(if ($Name -eq "PageWifi") { "Btn" } else { "GhostBtn" }))
    if ($Name -eq "PageWifi" -and -not $script:WifiItems.Count) { Start-WifiScan }
}

function Show-SurveyPage {
    if (-not $script:SvInit) { return }
    Update-SurveyHint
    Update-SurveyQueue
    if (([DateTime]::Now - $script:SvDirAt).TotalSeconds -gt 60) { Start-SurveyDirectory }
}

function Initialize-SurveyPage {
    # the scanner and the monitor are panels of this page
    foreach ($N in @("PageWifi", "PageRoam")) {
        $P = $Ui[$N]
        if ($P.Parent -ne $Ui.SvHost) { $P.Parent.Children.Remove($P); [void]$Ui.SvHost.Children.Add($P) }
        $P.Margin = New-Object System.Windows.Thickness 0
        $P.Visibility = "Collapsed"
    }
    $Ui.SvQueue.ItemsSource = $script:SvQueueItems
    $Ui.SvConnect.Add_Click({ Show-SurveyConnectDialog })
    $Ui.SvRefresh.Add_Click({ Start-SurveyDirectory -Manual })
    $Ui.SvSendNow.Add_Click({ Start-SurveySend -Now; Show-Toast "Отправляю очередь…" "info" })
    $Ui.SvOpen.Add_Click({
        $T = $Ui.SvSite.SelectedItem
        if (-not $T -or -not $T.Site -or -not $script:SvSel.Plan) { Show-Toast "Выберите объект и план" "warn"; return }
        Start-Process "$($T.Conn.Url)/objects/$($T.Site['slug'])/tools/wifi_survey/$($script:SvSel.Plan['id'])"
    })
    $Ui.SvMore.Add_Click({
        param($S, $E)
        Show-Menu $S @(
            (New-MenuItem "Отправить старые планы в Helpdesk…" 0xE898 { Show-SurveyPlanImport })
            (New-MenuItem "Отправить старую прогулку в Helpdesk…" 0xE8B5 { Add-SurveyLegacyWalks })
            (New-MenuItem "Папка очереди" 0xE838 { $D = Get-OutboxDir; if (-not (Test-Path $D)) { New-Item -ItemType Directory -Path $D | Out-Null }; Start-Process explorer.exe -ArgumentList (Quote-Arg $D) })
        )
    })
    $Ui.SvTabWalk.Add_Click({ Show-SurveyPanel "PageWalk" })
    $Ui.SvTabRoam.Add_Click({ Show-SurveyPanel "PageRoam" })
    $Ui.SvTabAir.Add_Click({ Show-SurveyPanel "PageWifi" })
    $Ui.SvSite.Add_SelectionChanged({ Set-SurveySite })
    $Ui.SvPlan.Add_SelectionChanged({ Set-SurveyPlan })
    $Ui.SvSeries.Add_SelectionChanged({ Set-SurveySeries })
    Initialize-WalkPage
    Show-SurveyPanel "PageWalk"
    Update-SurveySites
    $script:SvNetSig = Get-SurveyNetSig
    $script:SvTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SvTimer.Interval = [TimeSpan]::FromSeconds(10)
    $script:SvTimer.Add_Tick({ try { Invoke-SurveyTick } catch { Write-AppLog "survey tick: $_" } })
    $script:SvTimer.Start()
    $script:Win.Add_ContentRendered({ try { Invoke-SurveyStartup } catch { Write-AppLog "survey startup: $_" } })
    $script:SvInit = $true
}
