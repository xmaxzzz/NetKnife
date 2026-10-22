# Page: Wi-Fi wizard — one tab for everything wireless. The existing Wi-Fi scanner, planner and roaming monitor
# panels are moved into the wizard host at start-up; the wizard decides which one is visible and what to do on
# each step: prepare (site, router, AP list + current power) → floor plan (picture, rooms, where the APs hang) →
# voice-annotated walk "before" (pages\Walk.ps1: roaming test + survey in one go) → calculation and entering values
# into Omada → walk "after" → summary (was/became). Wizard progress lives in the site plan (plan.Wizard), so a site
# can be resumed later.

$script:WhStep = 1
$script:WhPhase = ""      # "before" / "after" while a roaming step is open — Stop-RoamMonitor stores its result there
$script:WhSteps = @(
    @{ N = 1; Key = "prep";  Title = "Подготовка";      Panel = "WhPrep" }
    @{ N = 2; Key = "plan";  Title = "План";            Panel = "PageFloor" }
    @{ N = 3; Key = "walk1"; Title = "Прогулка до";     Panel = "PageWalk" }
    @{ N = 4; Key = "calc";  Title = "Расчёт → Omada";  Panel = "PageWplan" }
    @{ N = 5; Key = "walk2"; Title = "Прогулка после";  Panel = "PageWalk" }
    @{ N = 6; Key = "sum";   Title = "Итог";            Panel = "WhSummary" }
)
$script:WhPanels = @("WhPrep", "WhSummary", "PageWifi", "PageWplan", "PageRoam", "PageFloor", "PageWalk")

function Get-WhState {
    if (-not $script:Wplan) { return @{} }
    if (-not $script:Wplan.Wizard) { $script:Wplan.Wizard = @{ V = 2; Step = 1; Applied = $false; AfterSeries = ""; RoamBefore = $null; RoamAfter = $null; RouterId = ""; WalkBefore = ""; WalkAfter = ""; Walks = @() } }
    $W = $script:Wplan.Wizard
    # wizard v1 had 7 steps (test → survey → calc → survey → test → summary): map onto the walk steps
    if (-not $W.V) { $W.Step = @{ 1 = 1; 2 = 3; 3 = 3; 4 = 4; 5 = 5; 6 = 5; 7 = 6 }[[int]$W.Step]; if (-not $W.Step) { $W.Step = 1 }; $W.V = 2 }
    return $W
}

function Test-WhStepDone {
    param([int]$N)
    if (-not $script:Wplan) { return $false }
    $W = Get-WhState
    $Base = @($script:Wplan.Points | Where-Object { $_.Series -eq $script:WplanBaseSeries }).Count
    switch ($N) {
        1 { return [bool]($W.RouterId -and @(Get-MtCachedAps $W.RouterId).Count -and @($script:Wplan.Ssids).Count) }
        2 { $F = $script:Wplan.Floor; return [bool]($F -and $F.Image -and $F.Aps -and $F.Aps.Count) }
        3 { return [bool]($W.WalkBefore -or $W.RoamBefore -or $Base -ge 2) }
        4 { return [bool]$W.Applied }
        5 { return [bool]($W.WalkAfter -or $W.RoamAfter -or ($W.AfterSeries -and @($script:Wplan.Points | Where-Object { $_.Series -eq $W.AfterSeries }).Count)) }
    }
    return $false
}

# ---------------------------------------------------------------- stepper

function Update-WhStepper {
    $P = $Ui.WhSteps
    $P.Children.Clear()
    foreach ($S in $script:WhSteps) {
        $B = New-Object System.Windows.Controls.Button
        $Done = Test-WhStepDone $S.N
        $B.Style = $script:Win.FindResource($(if ($S.N -eq $script:WhStep) { "AccentBtn" } elseif ($Done) { "Btn" } else { "GhostBtn" }))
        $B.Padding = New-Object System.Windows.Thickness 10, 6, 12, 6
        $B.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
        $Sp = New-Object System.Windows.Controls.StackPanel; $Sp.Orientation = "Horizontal"
        $G = New-Object System.Windows.Controls.TextBlock
        $G.Text = $(if ($Done -and $S.N -ne $script:WhStep) { [string][char]0xE73E } else { "$($S.N)" })
        $G.FontFamily = $(if ($Done -and $S.N -ne $script:WhStep) { $script:Win.FindResource("IconFont") } else { $script:Win.FindResource("MonoFont") })
        $G.FontWeight = "SemiBold"; $G.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0; $G.VerticalAlignment = "Center"
        if ($Done -and $S.N -ne $script:WhStep) { $G.Foreground = Get-Brush "Ok" }
        $T = New-Object System.Windows.Controls.TextBlock; $T.Text = $S.Title; $T.VerticalAlignment = "Center"
        [void]$Sp.Children.Add($G); [void]$Sp.Children.Add($T)
        $B.Content = $Sp
        $B.Tag = "wh:$($S.N)"
        [void]$P.Children.Add($B)
    }
}

function Show-WhPanel {
    param([string]$Name)
    foreach ($N in $script:WhPanels) { $Ui[$N].Visibility = $(if ($N -eq $Name) { "Visible" } else { "Collapsed" }) }
}

function Set-WhStep {
    param([int]$N)
    if ($N -lt 1) { $N = 1 }; if ($N -gt $script:WhSteps.Count) { $N = $script:WhSteps.Count }
    if ($script:Walk -and $script:Walk.Running -and $script:WhStep -ne $N) {
        if (-not (Show-Confirm "Остановить прогулку?" "Идёт запись прогулки. Остановить, расшифровать и сохранить результат шага?" "Остановить")) { return }
        Stop-Walk
    }
    $script:WhStep = $N
    $S = $script:WhSteps[$N - 1]
    if ($script:Wplan) { (Get-WhState).Step = $N; Save-Wplan }
    $script:WhPhase = ""
    $Ui.WhCalcExtra.Visibility = "Collapsed"
    $Ui.WhPrev.IsEnabled = ($N -gt 1)
    $Ui.WhNext.Visibility = $(if ($N -lt $script:WhSteps.Count) { "Visible" } else { "Collapsed" })
    $Ui.WhTitle.Text = "Шаг $N из $($script:WhSteps.Count) · $($S.Title)"
    $W = Get-WhState
    switch ($S.Key) {
        "prep" {
            $Ui.WhText.Text = $(if (-not @(Get-MtRouters).Count) { "Роутер MikroTik ещё не добавлен — подключи его (блок ниже), потом выбери объект. " } else { "" }) + "Выбери объект и роутер (кнопка «Найти в сети» ищет MikroTik, как Winbox). Список точек и их имена подтянутся из DHCP роутера. Двойной клик по точке — впиши её текущую мощность из Omada (Devices → точка → Config → Radios): тогда расчёт даст точные dBm."
            Update-WhPrep
        }
        "plan" {
            $Ui.WhText.Text = "Загрузи план помещений (PNG, JPG, PDF или скриншот из буфера). «Распознать помещения» — ИИ прочитает подписи и обведёт комнаты; поправь названия: именно их ты будешь называть вслух на прогулке. Затем выбери справа каждую точку доступа и кликни на плане, где она висит."
            Update-FloorPage
        }
        { $_ -in @("walk1", "walk2") } {
            $Ph = $(if ($S.Key -eq "walk1") { "before" } else { "after" })
            $script:WhPhase = $Ph
            if ($Ph -eq "after" -and -not $W.AfterSeries) {
                $L = @(Get-WplanSeriesList); $K = 1; while ($L -contains "После правок $K") { $K++ }
                $W.AfterSeries = "После правок $K"; Save-Wplan
            }
            if ($W.RouterId -and $Ui.RoamRouter) { $Ui.RoamRouter.SelectedValue = $W.RouterId }
            $Ui.WhText.Text = $(if (@((Get-Floor).Route).Count) { "Маршрут из $(@((Get-Floor).Route).Count) точек: иди по нему и на каждой точке жми «Дошёл» (или пробел) — место на карте будет точным. " } else { "" }) + $(if ($Ph -eq "before") { "Исходная картина. «Старт» и иди по объекту обычным шагом. Входя в помещение, назови его вслух, как на плане («кухня», «коридор спальни»); если что-то не так — скажи («тут пропало») или нажми «Отметка». Можно кликать на плане, где стоишь — карта станет точнее. В каждом помещении задержись на 15–20 с. «Стоп» — расшифровка голоса, карта, замеры для расчёта." } else { "Проверка после правок в Omada: пройди тот же маршрут, называя те же помещения. Результат сохранится как «после» (серия «$($W.AfterSeries)») и пойдёт в итог." })
            Show-WalkStep $Ph
        }
        "calc" {
            Set-WhPlanLayout "calc"
            $Ui.WpSeries.Text = $script:WplanBaseSeries
            Use-WplanSite
            $Ui.WpReport.Text = Get-WplanReport
            $Ui.WhCalcExtra.Visibility = "Visible"
            $Ui.WhApplied.IsChecked = [bool]$W.Applied
            $Ui.WhText.Text = "Ниже — прогноз и значения для каждой точки (после правки поправки или потолков — «Рассчитать»). «Лист для Omada» копирует таблицу (точка → канал → ширина → мощность). Внеси значения в Omada, затем отметь «Внёс в Omada» и нажми «Принять как текущие» — следующий расчёт будет от новых мощностей."
        }
        "sum" {
            $Ui.WhText.Text = "Сравнение до/после: сигнал по местам и роуминг по точкам. HTML-отчёт — для заказчика или монтажника; «Совет ИИ» разберёт, что осталось."
            Update-WhSummary
        }
    }
    Show-WhPanel $S.Panel
    Update-WhStepper
    Update-PageSub
}

# fallback inside a walk step: the old stand-and-measure survey for the same series
function Show-WhManualSurvey {
    Set-WhPlanLayout "survey"
    $W = Get-WhState
    $Ui.WpSeries.Text = $(if ($script:WhPhase -eq "after" -and $W.AfterSeries) { $W.AfterSeries } else { $script:WplanBaseSeries })
    Show-WhPanel "PageWplan"
    $Ui.WhText.Text = "Ручные замеры (серия «$($Ui.WpSeries.Text)»): встань в помещении, введи название и Enter — 3 прохода скана. Вернуться к прогулке — кнопка шага сверху."
}

# The planner panel is shared by the survey and calc steps; each step shows only its part (site, SSID and series
# are owned by the wizard: step 1 and the step itself).
function Get-WhUp {
    param($El, [type]$Type)
    $P = $El.Parent
    while ($P -and $P -isnot $Type) { $P = $P.Parent }
    return $P
}

function Set-WhPlanLayout {
    param([ValidateSet("survey", "calc")][string]$Mode)
    $Calc = ($Mode -eq "calc")
    $Vis = { param([bool]$On) if ($On) { "Visible" } else { "Collapsed" } }
    (Get-WhUp $Ui.WpSite ([System.Windows.Controls.Grid])).Visibility = "Collapsed"
    $Series = Get-WhUp $Ui.WpOffset ([System.Windows.Controls.Grid])
    $Series.Visibility = & $Vis $Calc
    $SBox = Get-WhUp $Ui.WpSeries ([System.Windows.Controls.StackPanel])
    $SBox.Visibility = "Collapsed"
    $Series.ColumnDefinitions[0].Width = New-Object System.Windows.GridLength 0
    $Series.ColumnDefinitions[1].Width = New-Object System.Windows.GridLength 0
    $Series.Margin = New-Object System.Windows.Thickness 0
    $Ui.WpRoom.Parent.Visibility = & $Vis (-not $Calc)
    $Ui.WpRoom.Parent.Margin = New-Object System.Windows.Thickness 0
    $Ui.WpStatus.Visibility = & $Vis (-not $Calc)
    $Lists = Get-WhUp $Ui.WpPoints ([System.Windows.Controls.Grid])
    $Lists.Visibility = & $Vis (-not $Calc)
    $Report = Get-WhUp $Ui.WpReport ([System.Windows.Controls.Border])
    $Report.Visibility = & $Vis $Calc
    # rows: lists take the free height while surveying, the report while calculating
    $Ui.PageWplan.RowDefinitions[1].Height = $(if ($Calc) { New-Object System.Windows.GridLength 0 } else { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) })
    $Ui.PageWplan.RowDefinitions[2].Height = $(if ($Calc) { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) } else { New-Object System.Windows.GridLength 0 })
    # report toolbar: the sheet lives in the wizard bar, comparison and HTML — in the summary step
    foreach ($B in @($Ui.WpCopySheet, $Ui.WpCompare, $Ui.WpHtml)) { $B.Visibility = "Collapsed" }
}

function Show-WhAir {
    Show-WhPanel "PageWifi"
    $Ui.WhTitle.Text = "Эфир · соседние сети"
    $Ui.WhText.Text = "Все сети вокруг: сигнал, канал, производитель. Полезно перед выбором каналов — видно, где соседи. Вернуться к мастеру — кнопка шага сверху."
    $Ui.WhCalcExtra.Visibility = "Collapsed"
    if (-not $script:WifiItems.Count) { Start-WifiScan }
}

function Get-WhSub {
    if (-not $script:Wplan) { return "Мастер: подготовка → план → прогулка → расчёт → проверка" }
    $Done = @(1..5 | Where-Object { Test-WhStepDone $_ }).Count
    return "$($script:Wplan.Site) · шагов выполнено: $Done из 5"
}

# ---------------------------------------------------------------- step 1: preparation

function Update-WhPrep {
    $W = Get-WhState
    $Ui.WhSite.Text = $(if ($script:Wplan) { $script:Wplan.Site } else { "" })
    $Ui.WhSsids.Text = $(if ($script:Wplan) { @($script:Wplan.Ssids) -join ", " } else { "" })
    # routers (a single known router is picked automatically)
    $All = @(Get-MtRouters)
    if (-not $W.RouterId -and $All.Count -eq 1 -and $script:Wplan) { $W.RouterId = $All[0].Id; Save-Wplan }
    $Ui.WhNoRouter.Visibility = $(if ($All.Count) { "Collapsed" } else { "Visible" })
    $Items = @([pscustomobject]@{ Id = ""; Label = "— выбери роутер —" }) + @(Get-MtRouters | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Label = "$($_.Name)  ·  $($_.Host)$(if (-not $_.Ready) { '  ·  не подготовлен' })" } })
    $script:WhRouterSync = $true
    $Ui.WhRouter.ItemsSource = $Items; $Ui.WhRouter.DisplayMemberPath = "Label"; $Ui.WhRouter.SelectedValuePath = "Id"
    $Ui.WhRouter.SelectedValue = $(if ($W.RouterId -and ($Items | Where-Object { $_.Id -eq $W.RouterId })) { $W.RouterId } else { "" })
    $script:WhRouterSync = $false
    # APs: router DHCP list ∪ planner list
    $Rows = [ordered]@{}
    foreach ($A in @(Get-MtCachedAps $W.RouterId)) { $Rows[$A.Key] = @{ Key = $A.Key; Name = $A.Name; Ip = $A.Ip; Mac = $A.Mac } }
    if ($script:Wplan) { foreach ($K in $script:Wplan.Aps.Keys) { if (-not $Rows.Contains($K)) { $Rows[$K] = @{ Key = $K; Name = ""; Ip = ""; Mac = "" } } } }
    $List = foreach ($K in $Rows.Keys) {
        $R = $Rows[$K]
        $A = $(if ($script:Wplan) { $script:Wplan.Aps[$K] } else { $null })
        $Nm = $(if ($A -and $A.Name) { $A.Name } elseif ($R.Name) { $R.Name } else { "AP " + $K })
        $Tx = $(if ($A -and ("$($A.Tx24)" -or "$($A.Tx5)")) { "2.4: $(if ("$($A.Tx24)") { $A.Tx24 } else { '?' }) · 5: $(if ("$($A.Tx5)") { $A.Tx5 } else { '?' }) dBm" } else { "мощность не указана" })
        $Air = Format-WplanAir $A
        if ($A -and $A.Omada) { $Om = @(foreach ($Bb in @("2.4", "5")) { $X = $A.Omada[$Bb]; if ($X) { "$Bb к$($X.Ch)/$($X.W)$(if ($X.Mode -and $X.Mode -ne 'custom') { " $($X.Mode)" })" } }) -join " · "; if ($Om) { $Air = "Omada: $Om" } }
        [pscustomobject]@{ Key = $K; NoTx = (-not ($A -and ("$($A.Tx24)" -or "$($A.Tx5)"))); Label = ("{0,-24} {1,-16} {2,-18} {3,-34} {4}" -f $Nm, $R.Ip, $R.Mac, $Tx, $(if ($Air -like "Omada:*") { $Air } elseif ($Air) { "эфир: $Air" } else { "" })) }
    }
    $Ui.WhAps.ItemsSource = @($List); $Ui.WhAps.DisplayMemberPath = "Label"
    # readiness
    $C = @()
    $C += $(if ($script:Wplan -and $script:Wplan.Site) { "✔ объект: $($script:Wplan.Site)" } else { "✖ объект не выбран" })
    $C += $(if (@($script:Wplan.Ssids).Count) { "✔ SSID: $(@($script:Wplan.Ssids) -join ', ')" } else { "✖ SSID объекта не указан" })
    $Rt = $(if ($W.RouterId) { Get-MtRouter $W.RouterId } else { $null })
    $C += $(if ($Rt) { "✔ роутер: $($Rt.Name)$(if (-not $Rt.Ready) { ' (не подготовлен — работает через админа)' })" } else { "✖ роутер не выбран — без него не будет пинга точек и DHCP в тесте роуминга" })
    $NAp = @($List).Count
    $NTx = @($List | Where-Object { -not $_.NoTx }).Count
    $NAir = @($List | Where-Object { $_.Label -match 'эфир:' }).Count
    $C += $(if ($NAp) { "✔ точек: $NAp" } else { "✖ точки не найдены — «Обновить с роутера»" })
    $C += $(if ($NAp -and $NTx -eq $NAp) { "✔ мощности указаны у всех" } elseif ($NAp) { "▲ мощность указана у $NTx из $NAp — «CSV для мощностей»: впиши их из Omada одной таблицей" } else { "" })
    $C += $(if ($NAp -and $NAir -eq $NAp) { "✔ каналы и ширина из эфира — у всех" } elseif ($NAp) { "▲ из эфира прочитано $NAir из $NAp точек — дальние видны с прогулки или если подойти ближе и нажать «Считать из эфира»" } else { "" })
    if ($script:Wplan.OmadaCountry -and $script:Wplan.OmadaCountry -ne "RU") { $C += "▲ страна сайта в Omada: $($script:Wplan.OmadaCountry) — объект в России? Site Settings → Country/Region" }
    elseif ($script:Wplan.AirCountry -and $script:Wplan.AirCountry -ne "RU") { $C += "▲ страна сайта в эфире: $($script:Wplan.AirCountry) — объект в России? Site Settings → Country/Region (влияет на доступные каналы 5 ГГц)" }
    $Fl = @(@($script:Wplan.Aps.Values) | Where-Object { $_.Air })
    if ($Fl.Count) {
        $Kv = "11k $(@($Fl | Where-Object { $_.Air.K }).Count)/$($Fl.Count) · 11v $(@($Fl | Where-Object { $_.Air.V }).Count)/$($Fl.Count) · 11r $(@($Fl | Where-Object { $_.Air.R }).Count)/$($Fl.Count)"
        $Sc = (@($Fl | ForEach-Object { $_.Air.Sec } | Where-Object { $_ }) | Sort-Object -Unique) -join ", "
        $C += "  роуминг в эфире: $Kv · безопасность: $Sc"
    }
    $Ui.WhChecks.Text = ($C | Where-Object { $_ }) -join "`n"
    Update-WhStepper
}

function Set-WhSite {
    param([string]$Site)
    $Site = $Site.Trim()
    if (-not $Site) { return }
    $Ui.WpSite.Text = $Site
    Open-WplanSite $Site
    Update-WhPrep
}

function Set-WhRouter {
    if ($script:WhRouterSync -or -not $script:Wplan) { return }
    $W = Get-WhState
    $W.RouterId = "$($Ui.WhRouter.SelectedValue)"
    Save-Wplan
    $script:Settings.RoamRouterId = $W.RouterId; Save-Settings
    if ($Ui.RoamRouter) { $Ui.RoamRouter.SelectedValue = $W.RouterId }
    if ($W.RouterId) { $R = Get-MtRouter $W.RouterId; if ($R -and -not @(Get-MtCachedAps $R.Id).Count) { Start-MtApRefresh $R { param($A) Update-WhPrep } } }
    Update-WhPrep
}

function Open-WhApDialog {
    $S = $Ui.WhAps.SelectedItem
    if (-not $S -or -not $script:Wplan) { return }
    if (-not $script:Wplan.Aps.ContainsKey($S.Key)) {
        $Nm = $(if ($script:Settings.MtApNames) { "$($script:Settings.MtApNames[$S.Key])" } else { "" })
        $script:Wplan.Aps[$S.Key] = @{ Name = $Nm; Tx24 = ""; Tx5 = ""; Bssids = @() }
    }
    Show-WplanApDialog $S.Key
    Update-WhPrep
}

# ---------------------------------------------------------------- reading the air / CSV / verify

$script:WhAirBody = {
    param($Q, $Ctl, $Rounds)
    $All = @()
    for ($i = 1; $i -le $Rounds; $i++) {
        if ($Ctl.Stop) { return }
        try { $L = [NetKnife.Wlan]::Scan(3200) } catch { $Q.Enqueue(@{ Type = "airdone"; Error = "$($_.Exception.Message)" }); return }
        $All += @(foreach ($B in $L) { @{ Bssid = $B.Bssid; Ssid = $B.Ssid; Ch = $B.Channel; Band = $B.Band; Rssi = $B.Rssi; W = $B.Width; K = $B.K; V = $B.V; R = $B.R; Sec = $B.Sec; Cc = $B.Country } })
        $Q.Enqueue(@{ Type = "airround"; N = $i; Total = $Rounds })
    }
    $Q.Enqueue(@{ Type = "airdone"; Samples = $All })
}

# 3 scans of the air → channel/width/11kvr/security per AP; $Then gets the AP keys seen
function Start-WhAirRead {
    param([scriptblock]$Then, [string]$Label = "Читаю эфир")
    if (-not $script:Wplan) { Show-Toast "Сначала выбери объект" "warn"; return }
    if (Test-WorkerRunning "wh-air") { return }
    $script:WhAirThen = $Then
    Set-MtStatus "$Label (3 прохода, ~12 с)…" "wait"
    [void](Start-Worker -Name "wh-air" -Replace -Body $script:WhAirBody -ArgList @(3) -OnMessage {
        param($M)
        if ($M.Type -eq "airround") { Set-MtStatus "Эфир: проход $($M.N) из $($M.Total)…" "wait"; return }
        if ($M.Type -ne "airdone") { return }
        if ($M.Error) { Set-MtStatus "Эфир не прочитан: $($M.Error)" "fail"; return }
        Register-WplanAps @($M.Samples)
        Save-Wplan
        $Seen = @(@($M.Samples) | Where-Object { Test-WplanOurs $_ } | ForEach-Object { Get-WplanKey $_.Bssid } | Sort-Object -Unique)
        Set-MtStatus "Эфир: видно своих точек $($Seen.Count) из $($script:Wplan.Aps.Count)$(if ($script:Wplan.AirCountry) { " · страна $($script:Wplan.AirCountry)" })" "ok"
        if ($script:WhAirThen) { & $script:WhAirThen $Seen }
    })
}

# AP rows for the CSV: router DHCP list ∪ planner list, with what the air says
function Get-WhApRows {
    $W = Get-WhState
    $Rows = [ordered]@{}
    foreach ($A in @(Get-MtCachedAps $W.RouterId)) { $Rows[$A.Key] = @{ Key = $A.Key; Mac = $A.Mac; Ip = $A.Ip; Name = $A.Name } }
    foreach ($K in @($script:Wplan.Aps.Keys)) { if (-not $Rows.Contains($K)) { $Rows[$K] = @{ Key = $K; Mac = ""; Ip = ""; Name = "" } } }
    foreach ($R in $Rows.Values) { $R.Name = Get-WplanApName $R.Key; $R.Ap = $script:Wplan.Aps[$R.Key] }
    return @($Rows.Values | Sort-Object { $_.Name })
}

function Export-WhPowerCsv {
    if (-not $script:Wplan) { return }
    $F = Show-SaveFile "Таблица мощностей" "CSV для Excel (*.csv)|*.csv" "$($script:Wplan.Site) — мощности точек.csv"
    if (-not $F) { return }
    $L = @("Точка;MAC;IP;2.4 канал;2.4 ширина МГц;2.4 мощность dBm;5 канал;5 ширина МГц;5 мощность dBm;ключ")
    foreach ($R in @(Get-WhApRows)) {
        $A = $R.Ap; $A24 = $(if ($A -and $A.Air) { $A.Air["2.4"] } else { $null }); $A5 = $(if ($A -and $A.Air) { $A.Air["5"] } else { $null })
        # every cell is a string: an if without a value would drop out of the array and shift the columns
        $Cells = @("$($R.Name)", "$($R.Mac)", "$($R.Ip)", "$(if ($A24) { $A24.Ch })", "$(if ($A24) { $A24.W })", "$(if ($A) { $A.Tx24 })", "$(if ($A5) { $A5.Ch })", "$(if ($A5) { $A5.W })", "$(if ($A) { $A.Tx5 })", "$($R.Key)")
        $L += (@($Cells | ForEach-Object { $_ -replace ';', ',' }) -join ";")
    }
    # UTF-8 with BOM — Excel opens Cyrillic correctly
    [IO.File]::WriteAllText($F, ($L -join "`r`n"), [Text.UTF8Encoding]::new($true))
    Show-Toast "Таблица сохранена — впиши мощности (Omada → Devices → точка → Config → Radios) и загрузи обратно"
    try { Start-Process $F } catch { }
}

function Import-WhPowerCsv {
    if (-not $script:Wplan) { return }
    $F = @(Show-OpenFiles "Таблица мощностей" "CSV (*.csv;*.txt)|*.csv;*.txt") | Select-Object -First 1
    if (-not $F) { return }
    $Lines = @([IO.File]::ReadAllLines($F, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() })
    if ($Lines.Count -lt 2) { Show-Toast "В файле нет строк" "warn"; return }
    $Sep = $(if (($Lines[0].Split(';')).Count -ge ($Lines[0].Split(',')).Count) { ';' } else { ',' })
    $Hd = @($Lines[0].Split($Sep) | ForEach-Object { $_.Trim().Trim('"').ToLower() })
    $Col = { param([string]$Re) for ($i = 0; $i -lt $Hd.Count; $i++) { if ($Hd[$i] -match $Re) { return $i } }; return -1 }
    $Ci = @{ Name = (& $Col '^точка|^name|^ap'); Mac = (& $Col 'mac'); Key = (& $Col '^ключ|^key'); P24 = (& $Col '^2[\.,]4.*(мощн|power|tx)'); P5 = (& $Col '^5.*(мощн|power|tx)') }
    if ($Ci.P24 -lt 0 -and $Ci.P5 -lt 0) { Show-Toast "Не нашёл столбцы мощности («2.4 мощность dBm», «5 мощность dBm»)" "warn"; return }
    $ByName = @{}; foreach ($R in @(Get-WhApRows)) { $ByName[$R.Name.ToLower()] = $R.Key }
    $N = 0; $Miss = @()
    foreach ($Ln in @($Lines | Select-Object -Skip 1)) {
        $V = @($Ln.Split($Sep) | ForEach-Object { $_.Trim().Trim('"') })
        $Get = { param($I) if ($I -ge 0 -and $I -lt $V.Count) { $V[$I] } else { "" } }
        $K = & $Get $Ci.Key
        if (-not $K -and (& $Get $Ci.Mac)) { $K = Get-WplanKey (& $Get $Ci.Mac) }
        if (-not $K -and (& $Get $Ci.Name)) { $K = $ByName[(& $Get $Ci.Name).ToLower()] }
        if (-not $K) { $Miss += (& $Get $Ci.Name); continue }
        if (-not $script:Wplan.Aps.ContainsKey($K)) { $script:Wplan.Aps[$K] = @{ Name = ""; Tx24 = ""; Tx5 = ""; Bssids = @() } }
        $A = $script:Wplan.Aps[$K]
        $T24 = "$(& $Get $Ci.P24)" -replace '[^\d]', ''; $T5 = "$(& $Get $Ci.P5)" -replace '[^\d]', ''
        if ($T24) { $A.Tx24 = $T24 }; if ($T5) { $A.Tx5 = $T5 }
        if ($T24 -or $T5) { $N++ }
    }
    $script:WplanLastReport = $null
    Save-Wplan; Update-WhPrep
    Show-Toast "Мощности загружены: $N точек$(if ($Miss.Count) { " · не опознаны: $($Miss -join ', ')" })" $(if ($Miss.Count) { "warn" } else { "info" })
}

# ---------------------------------------------------------------- exchange with the engineer's Omada agent
# NetKnife never talks to the controller. The engineer's own agent (MCP connector to Omada) reads/applies; the
# exchange is a JSON document «netknife-omada/1» (docs\OMADA-EXCHANGE.md): kind "state" comes from Omada,
# kind "plan" goes to Omada. Transport: clipboard (any chat agent) or a file in Documents\NetKnife\omada.

function Get-WhOmadaDir {
    $D = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "NetKnife\omada"
    if (-not (Test-Path $D)) { New-Item -ItemType Directory -Path $D -Force | Out-Null }
    return $D
}
function Get-WhOmadaFile { param([string]$Kind) return Join-Path (Get-WhOmadaDir) (("{0} — {1}.json" -f $script:Wplan.Site, $Kind) -replace '[\\/:*?"<>|]', '_') }
function ConvertTo-WhOmadaMac { param([string]$M) if (-not $M) { return "" }; return ($M.ToUpper() -replace '[:\.]', '-') }

function Get-WhOmadaPlan {
    $R = $script:WplanLastReport
    if (-not $R -or $R.Error) { Use-WplanSite; $R = Invoke-WplanCalc; $script:WplanLastReport = $R }
    if (-not $R -or $R.Error) { return $null }
    $Rows = @{}; foreach ($X in @(Get-WhApRows)) { $Rows[$X.Key] = $X }
    $Aps = [ordered]@{}
    foreach ($B in @("2.4", "5")) {
        if (-not $R.Bands.Contains($B)) { continue }
        $P = $R.Bands[$B]; $Rb = $(if ($B -eq "2.4") { "2g" } else { "5g" })
        foreach ($K in $P.Keys) {
            $A = $P.Aps[$K]; $Ap = $script:Wplan.Aps[$K]
            if (-not $Aps.Contains($K)) {
                $Mac = $(if ($Rows[$K] -and $Rows[$K].Mac) { $Rows[$K].Mac } elseif ($Ap -and $Ap.Mac) { $Ap.Mac } else { "" })
                $Aps[$K] = [ordered]@{ name = (Get-WplanApName $K); mac = (ConvertTo-WhOmadaMac $Mac); radios = [ordered]@{}; current = [ordered]@{} }
            }
            $Ch = $P.Channels.Assign[$K] | Select-Object -First 1
            $Aps[$K].radios[$Rb] = [ordered]@{ channel = $(if ($Ch) { [int]$Ch } else { $null }); width = $(if ($B -eq "2.4") { 20 } else { [int]$P.Channels.Width }); txPowerMode = $(if ($null -ne $A.Rec) { "custom" } else { $null }); txPower = $(if ($null -ne $A.Rec) { [int]$A.Rec } else { $null }) }
            $Cur = $(if ($Ap -and $Ap.Omada) { $Ap.Omada[$B] } else { $null }); $Air = $(if ($Ap -and $Ap.Air) { $Ap.Air[$B] } else { $null })
            $Aps[$K].current[$Rb] = [ordered]@{ channel = $(if ($Cur) { $Cur.Ch } elseif ($Air) { $Air.Ch } else { $null }); width = $(if ($Cur) { $Cur.W } elseif ($Air) { $Air.W } else { $null }); txPower = $(if ($null -ne $A.Cur) { [int]$A.Cur } else { $null }) }
        }
    }
    return [ordered]@{ format = "netknife-omada/1"; kind = "plan"; site = $script:Wplan.Site; omadaSite = "$($script:Wplan.OmadaSite)"; generated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz"); aps = @($Aps.Values) }
}

function Get-WhOmadaTaskText {
    param($Plan, [string]$PlanFile)
    $Site = $(if ($script:Wplan.OmadaSite) { $script:Wplan.OmadaSite } else { $script:Wplan.Site })
    $StateFile = Get-WhOmadaFile "state"; $BackupFile = Get-WhOmadaFile "backup"
    $Spec = ""; $Doc = Join-Path $PSScriptRoot "..\docs\OMADA-EXCHANGE.md"; if (Test-Path $Doc) { $Spec = Get-Content $Doc -Raw -Encoding UTF8 }
    return @"
ЗАДАЧА ДЛЯ АГЕНТА С MCP-КОННЕКТОРОМ OMADA · объект «$($script:Wplan.Site)» (сайт Omada: «$Site»)

Работаем в формате netknife-omada/1 (описание в конце). NetKnife к контроллеру не подключается — всё в Omada делаешь ты, по шагам ниже.

ШАГ 1. ВЫГРУЗКА ТЕКУЩИХ НАСТРОЕК (только чтение, ничего не менять)
Собери по всем точкам доступа сайта: name, mac (AA-BB-CC-DD-EE-FF), ip, model и для каждого радио (2g, 5g, 6g если есть): enabled, channel (число или "auto"), width (20/40/80/160 или "auto"), txPowerMode (low/medium/high/custom/auto), txPower (dBm). Добавь country сайта. Верни один JSON с "kind": "state" — если можешь писать файлы, сохрани в
  $StateFile
и в любом случае выведи JSON целиком одним блоком, чтобы я скопировал его в NetKnife («Загрузить из Omada»).

ШАГ 2. ПРИМЕНЕНИЕ ПЛАНА — ТОЛЬКО ПОСЛЕ МОЕГО ЯВНОГО «ДА»
План ниже (kind "plan"; файл: $PlanFile). Для каждой точки (сопоставляй по mac, если не нашёл — по name) сравни radios плана с текущими настройками в Omada и покажи таблицу «точка · диапазон · канал/ширина/мощность: было → станет». Ничего не меняй, пока я не подтвержу.
После подтверждения:
  а) сохрани текущие значения радио всех точек (как в шаге 1) в $BackupFile — это откат;
  б) выставляй только поля из radios плана: channel, width, мощность (режим Custom, значение txPower). Поле null или отсутствует — не трогай. SSID, настройки сайта, другие устройства — не менять;
  в) по одной точке; после каждой перечитай её настройки и сверь; при ошибке остановись и сообщи.

ШАГ 3. ПРОВЕРКА
После применения повтори шаг 1 (новый JSON "kind": "state"), чтобы NetKnife сверил результат.

ПЛАН (kind "plan"):
$($Plan | ConvertTo-Json -Depth 8)

ОПИСАНИЕ ФОРМАТА:
$Spec
"@
}

function Copy-WhOmadaTask {
    if (-not $script:Wplan) { return }
    $Plan = Get-WhOmadaPlan
    if (-not $Plan) { Show-Toast "Нет расчёта — сначала замеры (шаг «Прогулка до»)" "warn"; return }
    $F = Get-WhOmadaFile "plan"
    [IO.File]::WriteAllText($F, ($Plan | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Copy-Text (Get-WhOmadaTaskText $Plan $F) "задача для агента Omada (план внутри)"
    Show-Toast "Задача скопирована — вставь её агенту с MCP Omada. План также в файле: $F"
}

function Import-WhOmadaState {
    param([string]$Text = "")
    if (-not $script:Wplan) { return }
    $Txt = $Text
    if (-not $Txt) { try { if ([System.Windows.Clipboard]::ContainsText()) { $Txt = [System.Windows.Clipboard]::GetText() } } catch { } }
    if ($Txt -notmatch 'netknife-omada/1') {
        $Def = Get-WhOmadaFile "state"
        $D = New-Object Microsoft.Win32.OpenFileDialog; $D.Title = "Выгрузка из Omada (netknife-omada/1)"; $D.Filter = "JSON (*.json;*.txt)|*.json;*.txt"; $D.InitialDirectory = (Get-WhOmadaDir)
        if (Test-Path $Def) { $D.FileName = Split-Path $Def -Leaf }
        if (-not $D.ShowDialog($script:Win)) { return }
        $Txt = [IO.File]::ReadAllText($D.FileName, [Text.Encoding]::UTF8)
    }
    # the agent may wrap the JSON in prose or ```json fences
    $T = $Txt -replace '(?s)```(?:json)?\s*(.*?)```', '$1'
    $S = $T.IndexOf('{'); $E = $T.LastIndexOf('}')
    $J = $null; if ($S -ge 0 -and $E -gt $S) { try { $J = $T.Substring($S, $E - $S + 1) | ConvertFrom-Json -AsHashtable } catch { } }
    if (-not $J -or "$($J.format)" -ne "netknife-omada/1") { Show-Toast "Это не выгрузка netknife-omada/1 — попроси агента вернуть JSON по шагу 1 задачи" "warn"; return }
    if ("$($J.kind)" -ne "state") { Show-Toast "В файле kind «$($J.kind)», а нужен «state» — это выгрузка из Omada (шаг 1)" "warn"; return }
    $ByName = @{}; foreach ($X in @(Get-WhApRows)) { $ByName[$X.Name.ToLower()] = $X.Key }
    $N = 0; $NTx = 0; $Miss = @(); $Now = Get-Date -Format "yyyy-MM-dd HH:mm"
    foreach ($Ap in @($J.aps)) {
        $K = $(if ($Ap.mac) { Get-WplanKey "$($Ap.mac)" } else { "" })
        if (-not $K -or -not ($script:Wplan.Aps.ContainsKey($K) -or ($ByName.Values -contains $K))) { if ($Ap.name -and $ByName[("$($Ap.name)").ToLower()]) { $K = $ByName[("$($Ap.name)").ToLower()] } }
        if (-not $K) { $Miss += "$($Ap.name)"; continue }
        if (-not $script:Wplan.Aps.ContainsKey($K)) { $script:Wplan.Aps[$K] = @{ Name = ""; Tx24 = ""; Tx5 = ""; Bssids = @() } }
        $A = $script:Wplan.Aps[$K]
        if (-not $A.Name -and $Ap.name) { $A.Name = "$($Ap.name)" }
        if ($Ap.mac) { $A.Mac = ConvertTo-WhOmadaMac "$($Ap.mac)" }
        $A.Omada = @{ Model = "$($Ap.model)"; T = $Now }
        foreach ($Pair in @(@("2g", "2.4", "Tx24"), @("5g", "5", "Tx5"))) {
            $Rd = $(if ($Ap.radios) { $Ap.radios[$Pair[0]] } else { $null })
            if (-not $Rd) { continue }
            $A.Omada[$Pair[1]] = @{ Ch = "$($Rd.channel)"; W = "$($Rd.width)"; Mode = "$($Rd.txPowerMode)"; Tx = $Rd.txPower; On = $Rd.enabled }
            if ("$($Rd.txPower)" -match '^\d+$') { $A[$Pair[2]] = "$($Rd.txPower)"; $NTx++ }
        }
        $N++
    }
    if ($J.country) { $script:Wplan.OmadaCountry = "$($J.country)" }
    if ($J.omadaSite) { $script:Wplan.OmadaSite = "$($J.omadaSite)" }
    $script:WplanLastReport = $null
    Save-Wplan; Update-WhPrep
    Show-Toast ("Из Omada: точек {0}, мощностей {1}{2}{3}" -f $N, $NTx, $(if ($J.country) { ", страна $($J.country)" }), $(if ($Miss.Count) { " · не сопоставлены: $($Miss -join ', ')" })) $(if ($Miss.Count) { "warn" } else { "info" })
}

# air vs the calculated plan: channel and width per AP and band
function Start-WhVerify {
    $R = $script:WplanLastReport
    if (-not $R -or $R.Error) { Use-WplanSite; $R = Invoke-WplanCalc; $script:WplanLastReport = $R }
    if (-not $R -or $R.Error) { Show-Toast "Нет расчёта — сначала замеры" "warn"; return }
    $Ui.WhVerify.IsEnabled = $false
    $Ui.WhVerifyText.Visibility = "Visible"; $Ui.WhVerifyText.Foreground = Get-Brush "Sub"; $Ui.WhVerifyText.Text = "Читаю эфир (~12 с)…"
    Start-WhAirRead -Label "Сверяю эфир с планом" -Then {
        param($Seen)
        $Ui.WhVerify.IsEnabled = $true
        $R = $script:WplanLastReport
        $Ok = 0; $Bad = @(); $NotSeen = @()
        foreach ($B in @("2.4", "5")) {
            if (-not $R.Bands.Contains($B)) { continue }
            $P = $R.Bands[$B]
            foreach ($K in $P.Keys) {
                $Want = $P.Channels.Assign[$K] | Select-Object -First 1
                if (-not $Want) { continue }
                $A = $script:Wplan.Aps[$K]; $X = $(if ($A -and $A.Air) { $A.Air[$B] } else { $null })
                $Nm = Get-WplanApName $K
                if (-not $X -or $Seen -notcontains $K) { $NotSeen += "$Nm $B"; continue }
                $E = @()
                if ([int]$X.Ch -ne [int]$Want) { $E += "канал $($X.Ch), нужно $Want" }
                if ($B -eq "5" -and [int]$X.W -ne [int]$P.Channels.Width) { $E += "ширина $($X.W), нужно $($P.Channels.Width)" }
                if ($E.Count) { $Bad += "✖ $Nm $B ГГц: $($E -join '; ')" } else { $Ok++ }
            }
        }
        $T = @("✔ совпадает с планом: $Ok") + $Bad
        if ($NotSeen.Count) { $T += "· не видно отсюда (подойди ближе и проверь ещё раз): $($NotSeen -join ', ')" }
        $T += "Мощность в эфире не видна — её сверить нельзя, только по Omada."
        $Ui.WhVerifyText.Text = $T -join "`n"
        $Ui.WhVerifyText.Foreground = Get-Brush $(if ($Bad.Count) { "Warn" } else { "Ok" })
        if (-not $Bad.Count -and -not $NotSeen.Count -and $Ok) { (Get-WhState).Applied = $true; $Ui.WhApplied.IsChecked = $true; Save-Wplan; Update-WhStepper }
    }
}

# ---------------------------------------------------------------- roaming results per phase

function Get-WhRoamSummary {
    $R = $script:Roam
    if (-not $R -or -not $R.Count) { return $null }
    $Roams = @($R.Log | Where-Object { $_.Title -like "Роуминг*" } | Group-Object Time | ForEach-Object { $_.Group[-1] })
    $Aps = foreach ($St in @($R.Stats.Values)) {
        $V = Get-RoamApVerdict $St
        [ordered]@{ Name = (Get-RoamApName $St.Bssid); Bssid = $St.Bssid; Key = (Get-MtApKey $St.Bssid); Kind = $V.Kind; Msg = $(if ($V.Msgs.Count) { $V.Msgs[0] } else { "без замечаний" }); Loss = [Math]::Round($V.Loss, 1); RoamAvg = [Math]::Round($V.RoamAvg, 1) }
    }
    return [ordered]@{ Time = $R.Started.ToString("dd.MM HH:mm"); Minutes = [Math]::Round(([DateTime]::Now - $R.Started).TotalMinutes, 1); Roams = $Roams.Count
        Bad = @($Roams | Where-Object { $_.Kind -in @("warn", "fail") }).Count; Aps = @($Aps); Text = "$($script:RoamLastText)" }
}

function Save-WhRoamResult {
    if (-not $script:WhPhase -or -not $script:Wplan) { return }
    $S = Get-WhRoamSummary
    if (-not $S) { return }
    $W = Get-WhState
    if ($script:WhPhase -eq "before") { $W.RoamBefore = $S } else { $W.RoamAfter = $S }
    Save-Wplan
    Update-WhStepper
    Show-Toast "Роуминг «$(if ($script:WhPhase -eq 'before') { 'до' } else { 'после' })» сохранён в объект: переходов $($S.Roams), с потерей связи $($S.Bad)"
}

# ---------------------------------------------------------------- step 7: summary

function Update-WhSummary {
    if (-not $script:Wplan) { $Ui.WhSumText.Text = "Объект не выбран."; return }
    $W = Get-WhState
    $Out = [System.Text.StringBuilder]::new()
    [void]$Out.AppendLine("ИТОГ · $($script:Wplan.Site)")
    [void]$Out.AppendLine("")
    foreach ($N in 1..5) { [void]$Out.AppendLine(("  {0} {1}. {2}" -f $(if (Test-WhStepDone $N) { "✔" } else { "·" }), $N, $script:WhSteps[$N - 1].Title)) }
    [void]$Out.AppendLine("")
    [void]$Out.AppendLine("━━━ РОУМИНГ ━━━")
    $B = $W.RoamBefore; $A = $W.RoamAfter
    if ($B -and $A) {
        [void]$Out.AppendLine(("переходов с потерей связи: было {0} из {1} → стало {2} из {3}" -f $B.Bad, $B.Roams, $A.Bad, $A.Roams))
        $Keys = @(@($B.Aps) + @($A.Aps) | ForEach-Object { $_.Key } | Sort-Object -Unique)
        foreach ($K in $Keys) {
            $X = @($B.Aps) | Where-Object { $_.Key -eq $K } | Select-Object -First 1
            $Y = @($A.Aps) | Where-Object { $_.Key -eq $K } | Select-Object -First 1
            $Nm = $(if ($Y) { $Y.Name } else { $X.Name })
            $Mk = { param($Z) if (-not $Z) { "—" } else { switch ($Z.Kind) { "fail" { "✖" } "warn" { "▲" } default { "✔" } } } }
            [void]$Out.AppendLine(("  {0,-22} {1} → {2}   {3}" -f $Nm, (& $Mk $X), (& $Mk $Y), $(if ($Y) { $Y.Msg } else { "в тесте «после» не встречалась" })))
        }
    } elseif ($B) { [void]$Out.AppendLine("есть только тест «до» ($($B.Time)): переходов $($B.Roams), с потерей связи $($B.Bad). Пройди шаг 5.") }
    else { [void]$Out.AppendLine("тестов роуминга нет — шаги 3 и 5.") }
    [void]$Out.AppendLine("")
    [void]$Out.AppendLine("━━━ СИГНАЛ ПО МЕСТАМ ━━━")
    if ($W.AfterSeries) {
        $Keep = $script:Wplan.CurSeries
        $script:Wplan.CurSeries = $W.AfterSeries
        [void]$Out.AppendLine((Format-WplanCompare))
        $script:Wplan.CurSeries = $Keep
    } else { [void]$Out.AppendLine("проверочного обхода нет — шаг 5.") }
    # voice notes of both walks
    foreach ($Ph in @("before", "after")) {
        $Id = $(if ($Ph -eq "before") { $W.WalkBefore } else { $W.WalkAfter })
        $K = $(if ($Id) { Read-WalkFile $Id } else { $null })
        if ($K -and @($K.Notes).Count) {
            [void]$Out.AppendLine("")
            [void]$Out.AppendLine("━━━ ЗАМЕТКИ ПРОГУЛКИ «$(if ($Ph -eq 'before') { 'до' } else { 'после' })» ━━━")
            foreach ($N2 in @($K.Notes)) { [void]$Out.AppendLine(("  {0}  {1,-18} «{2}»" -f (Format-WalkTime $N2.T), $N2.Room, $N2.Text)) }
        }
    }
    $Ui.WhSumText.Text = $Out.ToString()
}

function Start-WhAi {
    if (-not $script:Wplan) { return }
    $Sys = "Ты инженер беспроводных сетей (TP-Link Omada, MikroTik). Дан итог настройки объекта: роуминг до/после по точкам (с диагнозами монитора), сравнение уровня сигнала по местам до/после правок мощностей и каналов. Оцени результат, назови что осталось плохим и что сделать дальше — по пунктам, по-русски, кратко."
    $Ui.WhSumAi.IsEnabled = $false
    $Ok = Start-AiRequest -Name "wh-ai" -System $Sys -UserText $Ui.WhSumText.Text -MaxTokens 2000 -OnResult {
        param($M)
        $Ui.WhSumAi.IsEnabled = $true
        if (-not $M.Ok) { Show-Toast "ИИ: $($M.Text)" "fail"; return }
        $Ui.WhSumText.Text = $Ui.WhSumText.Text + "`r`n━━━ СОВЕТ ИИ ━━━`r`n" + $M.Text
        $Ui.WhSumText.ScrollToEnd()
    }
    if (-not $Ok) { $Ui.WhSumAi.IsEnabled = $true }
}

# ---------------------------------------------------------------- wiring

function Show-WifiHub {
    if (-not $script:WhInit) { return }
    Set-WhStep $script:WhStep
    $W = $(if ($script:Wplan) { Get-WhState } else { $null })
    if ($W -and $W.RouterId -and -not $script:WhApsFresh) {
        $R = Get-MtRouter $W.RouterId
        if ($R -and $R.Ready) { $script:WhApsFresh = $true; Start-MtApRefresh $R { param($A) if ($script:WhStep -eq 1) { Update-WhPrep } } }
    }
}

function Initialize-WifiHub {
    # move the existing Wi-Fi panels into the wizard host
    foreach ($N in @("PageWifi", "PageWplan", "PageRoam")) {
        $P = $Ui[$N]
        if ($P.Parent -ne $Ui.WhHost) { $P.Parent.Children.Remove($P); [void]$Ui.WhHost.Children.Add($P) }
        $P.Margin = New-Object System.Windows.Thickness 0
        $P.Visibility = "Collapsed"
    }
    $Ui.WhPrev.Add_Click({ Set-WhStep ($script:WhStep - 1) })
    $Ui.WhNext.Add_Click({
        if ($script:WhStep -eq 1) {
            if (-not $script:Wplan) { Show-Toast "Укажи объект" "warn"; $Ui.WhSite.Focus(); return }
            if (-not (Get-WhState).RouterId -and -not (Show-Confirm "Без роутера?" "Роутер не выбран: тест роуминга не увидит пинг точек и DHCP, имена точек придётся вводить вручную. Продолжить без него?" "Продолжить")) { return }
        }
        Set-WhStep ($script:WhStep + 1)
    })
    $Ui.WhNoRtFind.Add_Click({ Start-MtDiscovery { param($T, $K) Set-MtStatus $T $K } })
    $Ui.WhNoRtAdd.Add_Click({ Show-MtConnectDialog $null; Update-WhPrep })
    $Ui.WhAir.Add_Click({ Show-WhAir })
    Add-PickMenu $Ui.WhSitePick $Ui.WhSite { @(Get-WplanSites | ForEach-Object { [pscustomobject]@{ Label = $_; Value = $_ } }) }
    $Ui.WhSite.Add_LostKeyboardFocus({ $S = $Ui.WhSite.Text.Trim(); if ($S -and (-not $script:Wplan -or $script:Wplan.Site -ne $S)) { Set-WhSite $S } })
    $Ui.WhSite.Add_TextChanged({ $S = $Ui.WhSite.Text.Trim(); if ($S -and (Test-Path (Get-WplanPath $S)) -and (-not $script:Wplan -or $script:Wplan.Site -ne $S)) { Set-WhSite $S } })
    $Ui.WhSsids.Add_LostKeyboardFocus({ if ($script:Wplan) { $Ui.WpSsids.Text = $Ui.WhSsids.Text; Use-WplanSite; Save-Wplan; $script:WplanLastReport = $null; Update-WhPrep } })
    $Ui.WhRouter.Add_SelectionChanged({ Set-WhRouter })
    $Ui.WhFind.Add_Click({ Start-MtDiscovery { param($T, $K) Set-MtStatus $T $K } })
    $Ui.WhPrepare.Add_Click({ $R = Get-MtRouter "$($Ui.WhRouter.SelectedValue)"; Show-MtConnectDialog $R; Update-WhPrep })
    $Ui.WhTest.Add_Click({ $R = Get-MtRouter "$($Ui.WhRouter.SelectedValue)"; if ($R) { Set-MtStatus "$($R.Name): подключаюсь…" "wait"; Test-MtRouter $R } else { Show-Toast "Выбери роутер" "warn" } })
    $Ui.WhApsRefresh.Add_Click({ $R = Get-MtRouter "$($Ui.WhRouter.SelectedValue)"; if ($R) { Start-MtApRefresh $R { param($A) Update-WhPrep } } else { Show-Toast "Выбери роутер" "warn" } })
    $Ui.WhAps.Add_MouseDoubleClick({ Open-WhApDialog })
    $Ui.WhReadAir.Add_Click({ Start-WhAirRead { param($S) Update-WhPrep } })
    $Ui.WhCsvOut.Add_Click({ Export-WhPowerCsv })
    $Ui.WhCsvIn.Add_Click({ Import-WhPowerCsv })
    $Ui.WhVerify.Add_Click({ Start-WhVerify })
    $Ui.WhOmadaIn.Add_Click({ Import-WhOmadaState })
    $Ui.WhOmadaTask.Add_Click({ Copy-WhOmadaTask })
    $Ui.WhCopySheet.Add_Click({ Use-WplanSite; $T = Get-WplanSheet; if ($T) { Copy-Text $T "лист для Omada" } else { Show-Toast "Нет расчёта — сначала замеры" "warn" } })
    $Ui.WhApplied.Add_Click({ if ($script:Wplan) { (Get-WhState).Applied = [bool]$Ui.WhApplied.IsChecked; Save-Wplan; Update-WhStepper } })
    $Ui.WhAdopt.Add_Click({
        $R = $script:WplanLastReport
        if (-not $R -or $R.Error) { Show-Toast "Нет расчёта" "warn"; return }
        $N = 0
        foreach ($B in $R.Bands.Keys) { foreach ($K in $R.Bands[$B].Aps.Keys) { $A = $R.Bands[$B].Aps[$K]; if ($null -ne $A.Rec -and $script:Wplan.Aps.ContainsKey($K)) { $script:Wplan.Aps[$K]["Tx" + ($B -replace '\.', '')] = "$($A.Rec)"; $N++ } } }
        $script:WplanLastReport = $null
        Save-Wplan; Refresh-Wplan
        Show-Toast "Принято как текущие: $N значений мощности"
    })
    $Ui.WhSumRefresh.Add_Click({ Update-WhSummary })
    $Ui.WhSumHtml.Add_Click({ Use-WplanSite; Export-WplanHtml })
    $Ui.WhSumCopy.Add_Click({ Copy-Text $Ui.WhSumText.Text "итог" })
    $Ui.WhSumAi.Add_Click({ Start-WhAi })
    Initialize-FloorPage
    Initialize-WalkPage
    $script:WhInit = $true
    if ($script:Wplan) { $script:WhStep = [int]$(if ((Get-WhState).Step) { (Get-WhState).Step } else { 1 }) }
}
