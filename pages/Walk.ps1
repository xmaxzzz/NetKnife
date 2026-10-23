# Wi-Fi walk for HelpDesk (page «Wi-Fi обход»). One «Старт» runs three things at once:
#   • microphone → WAV (lib\Mic.ps1); the engineer names rooms aloud while walking («кухня», «коридор спальни»)
#     and says what is wrong («тут пропало»); «Отметка» marks a bad spot without words;
#   • the roaming monitor (pages\Roam.ps1): connected AP, RSSI, gateway/internet/DNS probes every 0.5 s, roams;
#   • a background Wi-Fi scan every ~8 s (all BSSIDs with RSSI) — probes during a scan are not counted as loss.
# Clicks on the plan, «Дошёл до N» and «Я в: …» mark where the engineer is. «Стоп» puts the walk into the outbox
# (lib\Collector.ps1): the server recognises the voice, builds the room timeline, the track and the report.
# Walk files: wifiplan\<site>.walk-<id>.json / .wav (+ .meta.json — object, plan, series; .json.partial every 30 s).

$script:WplanDir = Join-Path $script:DataDir "wifiplan"   # the old folder name stays: old walks and plans live there
$script:Walk = $null

$script:WalkScanBody = {
    param($Q, $Ctl, $EveryMs)
    while (-not $Ctl.Stop) {
        $Q.Enqueue(@{ Type = "ws0" })
        $L = @()
        try { $L = [NetKnife.Wlan]::Scan(3200) } catch { $Q.Enqueue(@{ Type = "wserr"; Error = "$($_.Exception.Message)" }) }
        $S = @(foreach ($B in $L) { @{ Bssid = $B.Bssid; Ssid = $B.Ssid; Ch = $B.Channel; Band = $B.Band; Rssi = $B.Rssi; W = $B.Width; K = $B.K; V = $B.V; R = $B.R; Sec = $B.Sec; Cc = $B.Country } })
        $Q.Enqueue(@{ Type = "ws"; Time = [DateTime]::Now; Samples = $S })
        $Left = $EveryMs
        while ($Left -gt 0 -and -not $Ctl.Stop) { Start-Sleep -Milliseconds 100; $Left -= 100 }
    }
}

function Get-WalkSec { param([DateTime]$T) return [Math]::Round(($T - $script:Walk.Started).TotalSeconds, 1) }
function Format-WalkTime { param([double]$S) return "{0:00}:{1:00}" -f [Math]::Floor($S / 60), [Math]::Floor($S % 60) }

# the plan the walk runs on (fixed at «Старт»), otherwise the one selected on the page
function Get-SurveyPlan { if ($script:Walk -and $script:Walk.Plan) { return $script:Walk.Plan }; return $script:SvSel.Plan }

# ---------------------------------------------------------------- start / stop

function Start-Walk {
    if ($script:Walk -and $script:Walk.Running) { return }
    $T = Get-SurveyTarget
    if (-not $T) { return }
    $Id = New-CollectorWalkId
    if (-not (Test-Path $script:WplanDir)) { New-Item -ItemType Directory -Path $script:WplanDir | Out-Null }
    $Base = Join-Path $script:WplanDir ("{0}.walk-{1}" -f (ConvertTo-OutboxName $T.Site), $Id)
    Write-CollectorFile "$Base.meta.json" ($T | ConvertTo-Json -Depth 4)
    $script:Walk = @{ Id = $Id; Phase = $T.Phase; Series = $T.SeriesLabel; Running = $true; Started = [DateTime]::Now; Base = $Base; Wav = ""; Mic = $null
        Target = $T; Plan = $script:SvSel.Plan
        Clicks = [System.Collections.Generic.List[object]]::new(); Scans = [System.Collections.Generic.List[object]]::new(); Conn = [System.Collections.Generic.List[object]]::new()
        Marks = [System.Collections.Generic.List[object]]::new(); Rooms = [System.Collections.Generic.List[object]]::new(); Events = @(); ScanUntil = [DateTime]::MinValue; ScanErr = ""; CpNext = 0 }
    # microphone
    $Mic = [NetKnife.MicProc]::new($script:MicHelper)
    $script:Win.Cursor = [System.Windows.Input.Cursors]::Wait
    $MicOk = $Mic.Start("$Base.wav")
    $script:Win.Cursor = $null
    if ($MicOk) { $script:Walk.Mic = $Mic; $script:Walk.Wav = "$Base.wav"; $script:Walk.Started = $Mic.Started }
    else {
        $Why = "Микрофон не запустился: $($Mic.Error). Проверь: Параметры → Конфиденциальность → Микрофон → «Разрешить классическим приложениям»; микрофон не занят другой программой."
        if (-not (Show-Confirm "Без голоса?" "$Why Продолжить обход без записи — место отмечать кликами по плану и выбором «Я в: …»?" "Без голоса")) { $script:Walk = $null; Remove-Item "$Base.meta.json" -ErrorAction SilentlyContinue; return }
    }
    Start-RoamMonitor
    [void](Start-Worker -Name "walk-scan" -Replace -Body $script:WalkScanBody -ArgList @(8000) -OnMessage {
        param($M)
        $K = $script:Walk; if (-not $K -or -not $K.Running) { return }
        switch ($M.Type) {
            "ws0" { $K.ScanUntil = [DateTime]::Now.AddSeconds(4.5) }
            "ws" {
                $K.ScanUntil = [DateTime]::Now.AddSeconds(0.5)
                if (@($M.Samples).Count) { $K.Scans.Add(@{ T = [Math]::Max(0.0, (Get-WalkSec $M.Time.AddSeconds(-1.5))); Samples = @($M.Samples) }) }
            }
            "wserr" { $K.ScanErr = $M.Error }
        }
    })
    $Ui.WkRoom.SelectedIndex = -1
    if (-not $script:WalkTimer) {
        $script:WalkTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:WalkTimer.Interval = [TimeSpan]::FromMilliseconds(300)
        $script:WalkTimer.Add_Tick({ Update-WalkLive })
        # a crash or a closed laptop must not lose the walk: <Base>.json.partial every 30 s
        $script:WalkSaveTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:WalkSaveTimer.Interval = [TimeSpan]::FromSeconds(30)
        $script:WalkSaveTimer.Add_Tick({ if ($script:Walk -and $script:Walk.Running) { Save-WalkFile -Partial } })
    }
    $script:WalkTimer.Start(); $script:WalkSaveTimer.Start()
    Update-WalkPanel
    Update-PageSub
}

# called from the roaming monitor for every 0.5 s sample
function Add-WalkConn {
    param($M)
    $K = $script:Walk
    if (-not $K -or -not $K.Running) { return }
    $K.Conn.Add(@{ T = [Math]::Max(0.0, (Get-WalkSec $M.Time)); Bssid = $M.Bssid; Rssi = $M.Rssi; Ch = $M.Ch; Gw = $M.GwMs; Net = $M.NetMs; Conn = [bool]($M.State -eq 1 -and $M.Bssid); Scan = (Test-WalkScanning $M.Time)
        Ip = $M.Ip; Pfx = $M.Pfx; GwIp = $M.Gw; GwMac = $M.GwMac; Dns = $M.DnsMs; Ssid = $M.Ssid })
}

# probes that fall into a background scan window are not loss (the adapter leaves the channel for a moment)
function Test-WalkScanning { param([DateTime]$T) return ($script:Walk -and $script:Walk.Running -and $T -le $script:Walk.ScanUntil) }

# the live list «what will go to the server»: our own marks next to the monitor events (not into Events[])
function Add-WalkFeed {
    param([string]$Title, [string]$Detail = "", [string]$Kind = "wait")
    $Now = [DateTime]::Now
    $script:RoamEvents.Insert(0, [pscustomobject]@{ Time = $Now.ToString("HH:mm:ss"); Kind = $Kind; Title = $Title; Detail = $Detail; Raw = $Now })
}

function Add-WalkMark {
    $K = $script:Walk; if (-not $K -or -not $K.Running) { return }
    $T = Get-WalkSec ([DateTime]::Now)
    $K.Marks.Add(@{ T = $T; Text = "отметка «тут плохо»" })
    Add-WalkFeed "Отметка «тут плохо»" (Format-WalkTime $T)
    Show-Toast "Отметка $(Format-WalkTime $T)"
}

# «Дошёл до N»: the engineer is at the next route checkpoint — an exact position at this moment
function Add-WalkCheckpoint {
    $K = $script:Walk; if (-not $K -or -not $K.Running) { return }
    $L = @(Get-PlanRoute $K.Plan)
    if ($K.CpNext -ge $L.Count) { return }
    $Cp = $L[$K.CpNext]
    $K.Clicks.Add(@{ T = (Get-WalkSec ([DateTime]::Now)); X = [double](Get-PlanVal $Cp "X"); Y = [double](Get-PlanVal $Cp "Y"); Cp = $K.CpNext })
    Add-WalkFeed "Дошёл до $(Get-PlanCpName $K.Plan $Cp $K.CpNext)"
    $K.CpNext++
    Update-WalkCheckButton
    Update-WalkView
}

function Update-WalkCheckButton {
    $K = $script:Walk
    $L = @(Get-PlanRoute (Get-SurveyPlan))
    $Ui.WkCheck.Visibility = $(if ($L.Count) { "Visible" } else { "Collapsed" })
    if (-not $L.Count) { return }
    $Run = [bool]($K -and $K.Running)
    $N = $(if ($Run) { [int]$K.CpNext } else { 0 })
    $Ui.WkCheck.IsEnabled = ($Run -and $N -lt $L.Count)
    $Ui.WkCheckText.Text = $(if ($N -lt $L.Count) { "Дошёл до $(Get-PlanCpName (Get-SurveyPlan) $L[$N] $N)" } else { "Маршрут пройден" })
}

function Add-WalkClick {
    param([double]$X, [double]$Y)
    $K = $script:Walk; if (-not $K -or -not $K.Running) { return }
    $K.Clicks.Add(@{ T = (Get-WalkSec ([DateTime]::Now)); X = [Math]::Round($X, 4); Y = [Math]::Round($Y, 4) })
    $Rm = Get-PlanRoomAt $K.Plan $X $Y
    Add-WalkFeed $(if ($Rm) { "Клик: $($Rm.Name)" } else { "Клик по плану" }) ("x {0:N2} · y {1:N2}" -f $X, $Y)
    Update-WalkView
}

# «Я в: …» — a room from the server list goes to Rooms[] (the server puts it into the timeline, src: room)
function Add-WalkRoom {
    param([string]$Room)
    $K = $script:Walk; if (-not $K -or -not $K.Running -or -not $Room) { return }
    $K.Rooms.Add(@{ T = (Get-WalkSec ([DateTime]::Now)); Room = $Room })
    Add-WalkFeed "Я в: $Room"
}

# monitor log → events on the walk clock: T ≥ 0, Title ≤ 300, Detail ≤ 1000 (§4.4). A monitor started before the
# walk (tab «Монитор») keeps its older events in the log — those are not part of the walk.
function Get-WalkEvents {
    $From = $script:Walk.Started.AddSeconds(-5)
    $Ev = @(foreach ($L in @($script:Roam.Log)) {
        $Tm = [DateTime]::Parse($L.Time, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if ($Tm -lt $From) { continue }
        $Ti = "$($L.Title)"; if ($Ti.Length -gt 300) { $Ti = $Ti.Substring(0, 299) + "…" }
        $De = "$($L.Detail)"; if ($De.Length -gt 1000) { $De = $De.Substring(0, 999) + "…" }
        @{ T = [Math]::Max(0.0, (Get-WalkSec $Tm)); Kind = $L.Kind; Title = $Ti; Detail = $De }
    })
    return @($Ev | Group-Object { "$($_.T)|$($_.Title)" } | ForEach-Object { $_.Group[-1] })   # a roam event is logged twice (wait → result)
}

# $Closing: the window is closing — no questions, save and queue
function Stop-Walk {
    param([switch]$Closing)
    $K = $script:Walk
    if (-not $K -or -not $K.Running) { return }
    $K.Running = $false
    if ($script:WalkTimer) { $script:WalkTimer.Stop(); $script:WalkSaveTimer.Stop() }
    Stop-Worker "walk-scan"
    if ($K.Mic) { try { $K.Mic.Stop() } catch { Write-AppLog "mic stop: $_" } }
    $K.Duration = [Math]::Max(0.1, (Get-WalkSec ([DateTime]::Now)))
    Stop-RoamMonitor -Quiet:$Closing
    $K.Events = @(Get-WalkEvents)
    Save-WalkFile
    if (-not $Closing) { $Ui.WkStart.IsEnabled = $true; $Ui.WkStop.IsEnabled = $false; $Ui.WkMark.IsEnabled = $false; Update-WalkCheckButton }
    $Q = Add-SurveyOutbox "$($K.Base).json" $K.Wav $K.Target
    if ($Q.Ok) {
        Remove-Item "$($K.Base).json.partial" -ErrorAction SilentlyContinue
        if (-not $Closing) { Show-Toast "Обход $(Format-WalkTime $K.Duration) в очереди отправки"; Start-SurveySend -Now }
    } else { Write-AppLog "walk queue: $($Q.Error)"; if (-not $Closing) { Show-Toast "Обход сохранён, но не поставлен в очередь: $($Q.Error)" "fail" } }
    if (-not $Closing) { Update-WalkPanel; Update-SurveyQueue; Update-PageSub }
}

# ---------------------------------------------------------------- persistence

# the walk file of §4.1 (no Words/Phrases/Timeline/Notes — the server builds them); written atomically
function Save-WalkFile {
    param([switch]$Partial)
    $K = $script:Walk; if (-not $K) { return }
    $Dur = $(if ($Partial) { [Math]::Max(0.1, (Get-WalkSec ([DateTime]::Now))) } else { $K.Duration })
    # no $( … ) here: it would unroll a single event into an object and the server wants an array
    $Ev = if ($Partial) { @(Get-WalkEvents) } else { @($K.Events) }
    $O = [ordered]@{ Id = $K.Id; Site = $K.Target.Site; Phase = $K.Phase; Series = $K.Series; Started = $K.Started.ToString("o"); Duration = $Dur; Wav = $(if ($K.Wav) { Split-Path $K.Wav -Leaf } else { "" })
        Clicks = @($K.Clicks); Marks = @($K.Marks); Conn = @($K.Conn); Scans = @($K.Scans); Events = @($Ev); Rooms = @($K.Rooms) }
    $P = $(if ($Partial) { "$($K.Base).json.partial" } else { "$($K.Base).json" })
    try { Write-CollectorFile $P ($O | ConvertTo-Json -Depth 8 -Compress) } catch { Write-AppLog "walk save: $_" }
}

# ---------------------------------------------------------------- UI

function Update-WalkView {
    if (-not $script:WalkView) { return }
    Update-PlanView $script:WalkView (Get-SurveyPlan) $(if ($script:Walk -and $script:Walk.Running) { $script:Walk.Target.ImagePath } else { $script:SvSel.ImagePath }) $script:Walk
}

function Update-WalkLive {
    $K = $script:Walk
    if (-not $K -or -not $K.Running) { return }
    $S = ([DateTime]::Now - $K.Started).TotalSeconds
    $Ui.WkTime.Text = Format-WalkTime $S
    $Lv = $(if ($K.Mic) { [Math]::Min(1.0, $K.Mic.Peak / 3000.0) } else { 0 })   # laptop mic arrays are quiet
    $Ui.WkLevel.Width = [Math]::Max(2.0, $Lv * $Ui.WkLevelBox.ActualWidth)
    $Ui.WkLevel.Background = Get-Brush $(if (-not $K.Mic) { "Faint" } elseif ($Lv -gt 0.05) { "Ok" } else { "Sub" })
    $L = $(if ($script:Roam) { $script:Roam.Last } else { $null })
    $Room = ""
    $LastC = $(if ($K.Clicks.Count) { $K.Clicks[$K.Clicks.Count - 1] } else { $null })
    $LastR = $(if ($K.Rooms.Count) { $K.Rooms[$K.Rooms.Count - 1] } else { $null })
    if ($LastR -and (-not $LastC -or $LastR.T -ge $LastC.T)) { $Room = "$($LastR.Room) (из списка)" }
    elseif ($LastC) { $Rm = Get-PlanRoomAt $K.Plan $LastC.X $LastC.Y; if ($Rm) { $Room = "$($Rm.Name) (по клику)" } }
    $Ui.WkNow.Text = $(if ($L -and $L.State -eq 1 -and $L.Bssid) { "$(Get-RoamApName $L.Bssid) · $($L.Rssi) dBm · кан. $($L.Ch) ($(Get-RoamBand $L.Ch) ГГц)" } else { "нет подключения к Wi-Fi" }) + $(if ($Room) { "`n$Room" } else { "" })
    $Ui.WkStats.Text = "$(if ($K.Mic) { "запись голоса $(Format-WalkTime $K.Mic.Seconds)" } else { 'без голоса' }) · сканов эфира $($K.Scans.Count) · кликов $($K.Clicks.Count) · отметок $($K.Marks.Count) · выбрано помещений $($K.Rooms.Count)"
}

# buttons, the room list and the plan for the current selection
function Update-WalkPanel {
    $Run = [bool]($script:Walk -and $script:Walk.Running)
    $Ui.WkStart.IsEnabled = (-not $Run) -and [bool](Test-SurveyCanStart)
    $Ui.WkStop.IsEnabled = $Run
    $Ui.WkMark.IsEnabled = $Run
    $Ui.SvSite.IsEnabled = -not $Run; $Ui.SvPlan.IsEnabled = -not $Run; $Ui.SvSeries.IsEnabled = -not $Run
    $Rooms = @(Get-PlanVal (Get-SurveyPlan) "rooms" | Where-Object { $_ })
    $Cur = @($Ui.WkRoom.ItemsSource)
    if (($Cur -join "|") -ne ($Rooms -join "|")) { $Ui.WkRoom.ItemsSource = @($Rooms) }
    $Ui.WkRoomBox.Visibility = $(if ($Rooms.Count) { "Visible" } else { "Collapsed" })
    $Ui.WkRoom.IsEnabled = $Run
    if (-not $Run) {
        $Ui.WkTime.Text = "00:00"; $Ui.WkNow.Text = ""
        $Ui.WkStats.Text = $(if ($Rooms.Count) { "Помещений в списке плана: $($Rooms.Count)" } else { "" })
    }
    Update-WalkCheckButton
    Update-WalkView
}

function Initialize-WalkPage {
    $script:WalkView = New-PlanView "walk"
    $script:WalkView.Placeholder.Text = "У плана в Helpdesk нет картинки — место отмечай голосом (названия помещений) и списком «Я в: …».`nПлан и помещения правятся в вебе: Объект → Инструменты → Wi-Fi."
    Set-PlanViewHost $script:WalkView $Ui.WkHost
    $Ui.WkEvents.ItemsSource = $script:RoamEvents
    $Ui.WkStart.Add_Click({ Start-Walk })
    $Ui.WkStop.Add_Click({ Stop-Walk })
    $Ui.WkMark.Add_Click({ Add-WalkMark })
    $Ui.WkCheck.Add_Click({ Add-WalkCheckpoint })
    # the choice is recorded and the box cleared, so the same room can be picked again later («Я в» shows in WkNow)
    $Ui.WkRoom.Add_SelectionChanged({ if ($script:Walk -and $script:Walk.Running -and $Ui.WkRoom.SelectedItem) { Add-WalkRoom "$($Ui.WkRoom.SelectedItem)"; $Ui.WkRoom.SelectedIndex = -1 } })
    # Space = «Дошёл» (or «Отметка» without a route) while walking — hands busy with the laptop
    $script:Win.Add_PreviewKeyDown({
        param($S, $E)
        if ($E.Key -ne "Space" -or -not ($script:Walk -and $script:Walk.Running) -or -not $Ui.PageWalk.IsVisible) { return }
        if ([System.Windows.Input.Keyboard]::FocusedElement -is [System.Windows.Controls.TextBox]) { return }
        if (@(Get-PlanRoute $script:Walk.Plan).Count) { Add-WalkCheckpoint } else { Add-WalkMark }
        $E.Handled = $true
    })
    $script:WalkView.Canvas.Add_MouseLeftButtonDown({
        param($S, $E)
        $V = $script:WalkView; if (-not $V.W) { return }
        if (-not ($script:Walk -and $script:Walk.Running)) { Show-Toast "Клики по плану записываются во время обхода — нажми «Старт»" "info"; return }
        $P = $E.GetPosition($V.Canvas)
        Add-WalkClick ($P.X / $V.W) ($P.Y / $V.H)
    })
}
