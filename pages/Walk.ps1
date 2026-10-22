# Voice-annotated Wi-Fi walk (wizard steps «Прогулка до / после»). One «Старт» runs three things at once:
#   • microphone → WAV (lib\Mic.ps1); the engineer names rooms aloud while walking («кухня», «коридор спальни»)
#     and says what is wrong («тут пропало»); «Отметка» marks a bad spot without words;
#   • the roaming monitor (pages\Roam.ps1): connected AP, RSSI, gateway/internet/DNS probes every 0.5 s, roams;
#   • a background Wi-Fi scan every ~8 s (all BSSIDs with RSSI) — probes during a scan are not counted as loss.
# Clicks on the floor plan mark where the engineer stands. After «Стоп»: whisper.cpp transcribes the recording
# locally, phrases are matched to room names → a room timeline → survey points for the planner (replacing manual
# «Замер здесь»), a map (route, signal along it, roams/drops, notes) and a text report; «Разбор ИИ» sends the map
# picture and the data to Claude. Walk files: wifiplan\<site>.walk-<id>.json / .wav.

$script:Walk = $null

$script:WalkScanBody = {
    param($Q, $Ctl, $EveryMs)
    while (-not $Ctl.Stop) {
        $Q.Enqueue(@{ Type = "ws0" })
        $L = @()
        try { $L = [NetKnife.Wlan]::Scan(3200) } catch { $Q.Enqueue(@{ Type = "wserr"; Error = "$($_.Exception.Message)" }) }
        $S = @(foreach ($B in $L) { @{ Bssid = $B.Bssid; Ssid = $B.Ssid; Ch = $B.Channel; Band = $B.Band; Rssi = $B.Rssi } })
        $Q.Enqueue(@{ Type = "ws"; Time = [DateTime]::Now; Samples = $S })
        $Left = $EveryMs
        while ($Left -gt 0 -and -not $Ctl.Stop) { Start-Sleep -Milliseconds 100; $Left -= 100 }
    }
}

function Get-WalkSec { param([DateTime]$T) return [Math]::Round(($T - $script:Walk.Started).TotalSeconds, 1) }
function Format-WalkTime { param([double]$S) return "{0:00}:{1:00}" -f [Math]::Floor($S / 60), [Math]::Floor($S % 60) }

# ---------------------------------------------------------------- start / stop

function Start-Walk {
    param([ValidateSet("before", "after")][string]$Phase)
    if ($script:Walk -and $script:Walk.Running) { return }
    if (-not $script:Wplan) { Show-Toast "Сначала выбери объект (шаг 1)" "warn"; return }
    $W = Get-WhState
    $Series = $(if ($Phase -eq "before") { $script:WplanBaseSeries } else { $W.AfterSeries })
    $Id = Get-Date -Format "yyyyMMdd-HHmmss"
    $Base = [IO.Path]::ChangeExtension((Get-WplanPath $script:Wplan.Site "walk-$Id.json"), $null).TrimEnd('.')
    if (-not (Test-Path $script:WplanDir)) { New-Item -ItemType Directory -Path $script:WplanDir | Out-Null }
    $script:Walk = @{ Id = $Id; Phase = $Phase; Series = $Series; Running = $true; Started = [DateTime]::Now; Base = $Base; Wav = ""; Mic = $null
        Clicks = [System.Collections.Generic.List[object]]::new(); Scans = [System.Collections.Generic.List[object]]::new(); Conn = [System.Collections.Generic.List[object]]::new()
        Marks = [System.Collections.Generic.List[object]]::new(); Events = @(); Words = @(); Phrases = @(); Timeline = @(); Notes = @(); ScanUntil = [DateTime]::MinValue; ScanErr = ""; CpNext = 0 }
    # microphone
    $Mic = [NetKnife.MicRec]::new()
    if ($Mic.Start("$Base.wav")) { $script:Walk.Mic = $Mic; $script:Walk.Wav = "$Base.wav"; $script:Walk.Started = $Mic.Started }
    else {
        $Why = $(if ($Mic.Error -match 'waveInOpen 1') { "Windows не дал открыть микрофон (код 1). Проверь: Параметры → Конфиденциальность → Микрофон → «Разрешить классическим приложениям»; микрофон не занят другой программой (Телемост, диктовка)." } else { "Микрофон: $($Mic.Error)." })
        if (-not (Show-Confirm "Без голоса?" "$Why Продолжить прогулку без записи — место отмечать кликами по плану?" "Без голоса")) { $script:Walk = $null; return }
    }
    # roaming monitor (router of the site, if chosen in step 1)
    if ($W.RouterId -and $Ui.RoamRouter) { $Ui.RoamRouter.SelectedValue = $W.RouterId }
    Start-RoamMonitor
    [void](Start-Worker -Name "walk-scan" -Replace -Body $script:WalkScanBody -ArgList @(8000) -OnMessage {
        param($M)
        $K = $script:Walk; if (-not $K -or -not $K.Running) { return }
        switch ($M.Type) {
            "ws0" { $K.ScanUntil = [DateTime]::Now.AddSeconds(4.5) }
            "ws" {
                $K.ScanUntil = [DateTime]::Now.AddSeconds(0.5)
                if (@($M.Samples).Count) { $K.Scans.Add(@{ T = (Get-WalkSec $M.Time.AddSeconds(-1.5)); Samples = @($M.Samples) }); Register-WplanAps @($M.Samples) }
            }
            "wserr" { $K.ScanErr = $M.Error }
        }
    })
    $Ui.WkStart.IsEnabled = $false; $Ui.WkStop.IsEnabled = $true; $Ui.WkMark.IsEnabled = $true
    Update-WalkCheckButton
    $Ui.WkResult.Text = ""
    if (-not $script:WalkTimer) {
        $script:WalkTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:WalkTimer.Interval = [TimeSpan]::FromMilliseconds(300)
        $script:WalkTimer.Add_Tick({ Update-WalkLive })
    }
    $script:WalkTimer.Start()
    Update-WalkView
    Update-PageSub
}

# called from the roaming monitor for every 0.5 s sample
function Add-WalkConn {
    param($M)
    $K = $script:Walk
    if (-not $K -or -not $K.Running) { return }
    $K.Conn.Add(@{ T = (Get-WalkSec $M.Time); Bssid = $M.Bssid; Rssi = $M.Rssi; Ch = $M.Ch; Gw = $M.GwMs; Net = $M.NetMs; Conn = [bool]($M.State -eq 1 -and $M.Bssid); Scan = (Test-WalkScanning $M.Time) })
}

# probes that fall into a background scan window are not loss (the adapter leaves the channel for a moment)
function Test-WalkScanning { param([DateTime]$T) return ($script:Walk -and $script:Walk.Running -and $T -le $script:Walk.ScanUntil) }

function Add-WalkMark {
    $K = $script:Walk; if (-not $K -or -not $K.Running) { return }
    $T = Get-WalkSec ([DateTime]::Now)
    $K.Marks.Add(@{ T = $T; Text = "отметка «тут плохо»" })
    Show-Toast "Отметка $(Format-WalkTime $T)"
}

# «Дошёл до N»: the engineer is at the next route checkpoint — an exact position at this moment
function Add-WalkCheckpoint {
    $K = $script:Walk; if (-not $K -or -not $K.Running) { return }
    $L = @((Get-Floor).Route)
    if ($K.CpNext -ge $L.Count) { return }
    $Cp = $L[$K.CpNext]
    $K.Clicks.Add(@{ T = (Get-WalkSec ([DateTime]::Now)); X = [double]$Cp.X; Y = [double]$Cp.Y; Cp = $K.CpNext })
    $K.CpNext++
    Update-WalkCheckButton
    Update-WalkView
}

function Update-WalkCheckButton {
    $K = $script:Walk
    $L = @((Get-Floor).Route)
    $Ui.WkCheck.Visibility = $(if ($L.Count) { "Visible" } else { "Collapsed" })
    if (-not $L.Count) { return }
    $Run = [bool]($K -and $K.Running)
    $N = $(if ($Run) { [int]$K.CpNext } else { 0 })
    $Ui.WkCheck.IsEnabled = ($Run -and $N -lt $L.Count)
    $Ui.WkCheckText.Text = $(if ($N -lt $L.Count) { "Дошёл до $(Get-FloorCpName $L[$N] $N)" } else { "Маршрут пройден" })
}

function Add-WalkClick {
    param([double]$X, [double]$Y)
    $K = $script:Walk; if (-not $K -or -not $K.Running) { return }
    $K.Clicks.Add(@{ T = (Get-WalkSec ([DateTime]::Now)); X = [Math]::Round($X, 4); Y = [Math]::Round($Y, 4) })
    Update-WalkView
}

function Stop-Walk {
    $K = $script:Walk
    if (-not $K -or -not $K.Running) { return }
    $K.Running = $false
    if ($script:WalkTimer) { $script:WalkTimer.Stop() }
    Stop-Worker "walk-scan"
    if ($K.Mic) { try { $K.Mic.Stop() } catch { Write-AppLog "mic stop: $_" } }
    $K.Duration = Get-WalkSec ([DateTime]::Now)
    Stop-RoamMonitor
    # monitor log → events on the walk clock
    $Ev = @(foreach ($L in @($script:Roam.Log)) {
        $T = [DateTime]::Parse($L.Time)
        @{ T = (Get-WalkSec $T); Kind = $L.Kind; Title = $L.Title; Detail = $L.Detail }
    })
    $K.Events = @($Ev | Group-Object { "$($_.T)|$($_.Title)" } | ForEach-Object { $_.Group[-1] })   # a roam event is logged twice (wait → result)
    $Ui.WkStart.IsEnabled = $true; $Ui.WkStop.IsEnabled = $false; $Ui.WkMark.IsEnabled = $false
    Update-WalkCheckButton
    Save-WalkFile
    if ($K.Wav -and (Test-Path $K.Wav)) {
        if (Test-WhisperReady) { Start-WalkTranscribe }
        else {
            Complete-Walk
            $Ui.WkWhisper.Text = "Голос записан, но не расшифрован — нужен Whisper (кнопка «Установить»)."
            Install-Whisper { param($T, $Kd) Set-WalkWhisperStatus $T $Kd } { Start-WalkTranscribe }
        }
    } else { Complete-Walk }
}

function Start-WalkTranscribe {
    $K = $script:Walk
    if (-not $K -or -not $K.Wav -or -not (Test-Path $K.Wav)) { return }
    Set-WalkWhisperStatus "Расшифровываю запись ($(Format-WalkTime $K.Duration))…" "wait"
    $Ui.WkRetx.IsEnabled = $false
    Start-WhisperTranscribe $K.Wav (Get-WalkPrompt) { param($P) Set-WalkWhisperStatus "Расшифровка: $P%" "wait" } {
        param($X)
        $Ui.WkRetx.IsEnabled = $true
        if ($X.Error) { Set-WalkWhisperStatus "Расшифровка не удалась: $($X.Error)" "fail"; Complete-Walk; return }
        $script:Walk.Words = @($X.Words)
        $script:Walk.Phrases = @(ConvertTo-WhisperPhrases $X.Words)
        Set-WalkWhisperStatus "Расшифровано фраз: $(@($script:Walk.Phrases).Count)" "ok"
        Complete-Walk
    }
}

# timeline → survey points → map → report
function Complete-Walk {
    $K = $script:Walk
    Build-WalkTimeline
    $N = Add-WalkPoints
    Save-WalkFile
    $W = Get-WhState
    if (-not $W.Walks) { $W.Walks = @() }
    $W.Walks = @(@($W.Walks | Where-Object { $_.Id -ne $K.Id }) + @(@{ Id = $K.Id; Phase = $K.Phase; Series = $K.Series; Minutes = [Math]::Round($K.Duration / 60, 1); Points = $N; Rooms = @($K.Timeline | ForEach-Object { $_.Room } | Sort-Object -Unique).Count }))
    if ($K.Phase -eq "before") { $W.WalkBefore = $K.Id } else { $W.WalkAfter = $K.Id }
    Save-Wplan
    $script:WplanLastReport = $null
    Update-WalkView
    $Ui.WkResult.Text = Get-WalkReport
    Update-WhStepper
    Show-Toast "Прогулка обработана: помещений $(@($K.Timeline | ForEach-Object { $_.Room } | Sort-Object -Unique).Count), замеров $N"
}

# ---------------------------------------------------------------- persistence

function Save-WalkFile {
    $K = $script:Walk; if (-not $K) { return }
    $O = [ordered]@{ Id = $K.Id; Site = $script:Wplan.Site; Phase = $K.Phase; Series = $K.Series; Started = $K.Started.ToString("o"); Duration = $K.Duration; Wav = $(if ($K.Wav) { Split-Path $K.Wav -Leaf } else { "" })
        Clicks = @($K.Clicks); Marks = @($K.Marks); Conn = @($K.Conn); Scans = @($K.Scans); Events = @($K.Events); Words = @($K.Words); Phrases = @($K.Phrases); Timeline = @($K.Timeline); Notes = @($K.Notes) }
    try { $O | ConvertTo-Json -Depth 8 -Compress | Set-Content -Path "$($K.Base).json" -Encoding UTF8 } catch { Write-AppLog "walk save: $_" }
}

function Read-WalkFile {
    param([string]$Id)
    $P = Get-WplanPath $script:Wplan.Site "walk-$Id.json"
    if (-not (Test-Path $P)) { return $null }
    try {
        $J = Get-Content $P -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        $Base = [IO.Path]::ChangeExtension($P, $null).TrimEnd('.')
        # ConvertFrom-Json already turns ISO strings into DateTime
        $St = $(if ($J.Started -is [DateTime]) { $J.Started } else { [DateTime]::Parse("$($J.Started)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) })
        $K = @{ Id = $J.Id; Phase = $J.Phase; Series = $J.Series; Running = $false; Started = $St; Duration = [double]$J.Duration; Base = $Base
            Wav = $(if ($J.Wav) { Join-Path $script:WplanDir $J.Wav } else { "" }); Mic = $null
            Clicks = [System.Collections.Generic.List[object]]::new(); Scans = [System.Collections.Generic.List[object]]::new(); Conn = [System.Collections.Generic.List[object]]::new(); Marks = [System.Collections.Generic.List[object]]::new()
            Events = @($J.Events); Words = @($J.Words); Phrases = @($J.Phrases); Timeline = @($J.Timeline); Notes = @($J.Notes) }
        foreach ($N in @("Clicks", "Scans", "Conn", "Marks")) { foreach ($X in @($J[$N])) { if ($X) { $K[$N].Add($X) } } }
        $Cps = @($K.Clicks | Where-Object { $null -ne $_.Cp } | ForEach-Object { [int]$_.Cp })
        $K.CpNext = $(if ($Cps.Count) { ($Cps | Measure-Object -Maximum).Maximum + 1 } else { 0 })   # reached checkpoints on the map
        return $K
    } catch { Write-AppLog "walk read ${Id}: $_"; return $null }
}

# ---------------------------------------------------------------- rooms from speech and clicks

function Get-WalkRoomNames {
    $L = [System.Collections.Generic.List[string]]::new()
    $F = Get-Floor
    if ($F) { foreach ($R in @($F.Rooms)) { if ($R.Name -and -not $L.Contains($R.Name)) { $L.Add($R.Name) } } }
    foreach ($P in @($script:Wplan.Points)) { if ($P.Room -and $P.Kind -ne "trans" -and -not $L.Contains($P.Room)) { $L.Add($P.Room) } }
    return @($L)
}

# whisper initial prompt: the room vocabulary biases recognition toward these words
function Get-WalkPrompt {
    $R = @(Get-WalkRoomNames)
    $T = "Обход объекта, помещения: " + ($R -join ", ") + ". Точка доступа, связь пропала, плохо."
    if ($T.Length -gt 600) { $T = $T.Substring(0, 600) }
    return $T
}

function ConvertTo-WalkTokens {
    param([string]$S)
    $S = $S.ToLower().Replace("ё", "е")
    $Num = @{ "один" = "1"; "одна" = "1"; "первая" = "1"; "первую" = "1"; "первой" = "1"; "первый" = "1"; "два" = "2"; "две" = "2"; "вторая" = "2"; "вторую" = "2"; "второй" = "2"
        "три" = "3"; "третья" = "3"; "третью" = "3"; "третьей" = "3"; "четыре" = "4"; "четвертая" = "4"; "четвертую" = "4" }
    return @(([regex]::Matches($S, '[a-zа-я0-9]+') | ForEach-Object { $V = $_.Value; if ($Num.ContainsKey($V)) { $Num[$V] } else { $V } }))
}

function Get-WalkLev {
    param([string]$A, [string]$B)
    $D = New-Object 'int[,]' ($A.Length + 1), ($B.Length + 1)
    for ($i = 0; $i -le $A.Length; $i++) { $D[$i, 0] = $i }
    for ($j = 0; $j -le $B.Length; $j++) { $D[0, $j] = $j }
    for ($i = 1; $i -le $A.Length; $i++) { for ($j = 1; $j -le $B.Length; $j++) {
        $C = $(if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 })
        $D[$i, $j] = [Math]::Min([Math]::Min($D[($i - 1), $j] + 1, $D[$i, ($j - 1)] + 1), $D[($i - 1), ($j - 1)] + $C)
    } }
    return $D[$A.Length, $B.Length]
}

# a spoken word matches a name word by its stem (Russian cases: кухня/кухне, гостиная/гостиную), tolerating one typo
function Test-WalkWord {
    param([string]$Spoken, [string]$Name)
    if ($Name -match '^\d+$') { return ($Spoken -eq $Name) }
    $Stem = $(if ($Name.Length -le 4) { $Name } else { $Name.Substring(0, [Math]::Max(4, $Name.Length - 2)) })
    if ($Spoken.StartsWith($Stem)) { return $true }
    if ($Stem.Length -ge 5 -and $Spoken.Length -ge $Stem.Length - 1) {
        # one missing/extra/wrong letter, also across the stem border («коридор» ↔ «корридор»)
        foreach ($L in @(($Stem.Length - 1), $Stem.Length, ($Stem.Length + 1))) { if ($L -le $Spoken.Length -and (Get-WalkLev $Spoken.Substring(0, $L) $Stem) -le 1) { return $true } }
    }
    return $false
}

function Find-WalkRoom {
    param([string]$Text, $Names)
    $Sp = @(ConvertTo-WalkTokens $Text)
    if (-not $Sp.Count) { return "" }
    $Best = ""; $BestN = 0; $BestLen = 0
    foreach ($N in $Names) {
        $Nt = @(ConvertTo-WalkTokens $N)
        if (-not $Nt.Count) { continue }
        $All = $true
        foreach ($T in $Nt) { if (-not ($Sp | Where-Object { Test-WalkWord $_ $T })) { $All = $false; break } }
        # the most specific name wins: «холл спальни» over «холл», «мастер спальня» over «спальня»
        if ($All -and ($Nt.Count -gt $BestN -or ($Nt.Count -eq $BestN -and $N.Length -gt $BestLen))) { $Best = $N; $BestN = $Nt.Count; $BestLen = $N.Length }
    }
    return $Best
}

function Build-WalkTimeline {
    $K = $script:Walk
    $Names = @(Get-WalkRoomNames)
    $Ev = [System.Collections.Generic.List[object]]::new()
    $Notes = [System.Collections.Generic.List[object]]::new()
    foreach ($P in @($K.Phrases)) {
        $R = Find-WalkRoom $P.Text $Names
        if ($R) {
            $Ev.Add(@{ T = [double]$P.T0; Room = $R; Src = "voice" })
            # anything said beyond the room name is a note («кухня, тут медленно»)
            $Rest = @(ConvertTo-WalkTokens $P.Text).Count - @(ConvertTo-WalkTokens $R).Count
            if ($Rest -ge 3) { $Notes.Add(@{ T = [double]$P.T0; Text = $P.Text }) }
        } elseif (@(ConvertTo-WalkTokens $P.Text).Count -ge 2) { $Notes.Add(@{ T = [double]$P.T0; Text = $P.Text }) }
    }
    foreach ($C in @($K.Clicks)) { $Rm = Get-FloorRoomAt $C.X $C.Y; if ($Rm) { $Ev.Add(@{ T = [double]$C.T; Room = $Rm.Name; Src = "click" }) } }
    foreach ($M in @($K.Marks)) { $Notes.Add(@{ T = [double]$M.T; Text = $M.Text }) }
    $Sorted = @($Ev | Sort-Object { $_.T })
    $Tl = [System.Collections.Generic.List[object]]::new()
    foreach ($E in $Sorted) {
        if ($Tl.Count -and $Tl[$Tl.Count - 1].Room -eq $E.Room) { continue }
        if ($Tl.Count) { $Tl[$Tl.Count - 1].T1 = $E.T }
        $Tl.Add(@{ Room = $E.Room; T0 = $E.T; T1 = [double]$K.Duration; Src = $E.Src })
    }
    $K.Timeline = @($Tl)
    foreach ($N in $Notes) { $N.Room = (Get-WalkRoomAtTime $N.T) }
    $K.Notes = @($Notes | Sort-Object { $_.T })
}

function Get-WalkRoomAtTime {
    param([double]$T, $K = $script:Walk)
    $R = @($K.Timeline | Where-Object { $T -ge $_.T0 -and $T -lt $_.T1 }) | Select-Object -First 1
    if ($R) { return $R.Room } else { return "" }
}

# scans of every room interval → planner points (series of the phase); a long stay → several points
function Add-WalkPoints {
    $K = $script:Walk
    $Keep = @($script:Wplan.Points | Where-Object { $_.WalkId -ne $K.Id })
    $New = @()
    foreach ($I in @($K.Timeline)) {
        $Span = $I.T1 - $I.T0
        $Chunks = [Math]::Max(1, [Math]::Floor($Span / 20))
        for ($c = 0; $c -lt $Chunks; $c++) {
            $A = $I.T0 + 2 + $c * ($Span / $Chunks); $B = $I.T0 + ($c + 1) * ($Span / $Chunks)
            $Sc = @($K.Scans | Where-Object { $_.T -ge $A -and $_.T -le $B })
            if (-not $Sc.Count) { continue }
            $Acc = @{}
            foreach ($S in $Sc) { foreach ($X in @($S.Samples)) {
                if (-not $Acc.ContainsKey($X.Bssid)) { $Acc[$X.Bssid] = @{ Bssid = $X.Bssid; Ssid = $X.Ssid; Ch = $X.Ch; Band = $X.Band; R = [System.Collections.Generic.List[int]]::new() } }
                $Acc[$X.Bssid].R.Add([int]$X.Rssi)
            } }
            $Samples = @(foreach ($X in $Acc.Values) { $Srt = @($X.R | Sort-Object); @{ Bssid = $X.Bssid; Ssid = $X.Ssid; Ch = $X.Ch; Band = $X.Band; Rssi = $Srt[[int][Math]::Floor(($Srt.Count - 1) / 2)]; Seen = $Srt.Count } })
            $New += @{ Room = $I.Room; Kind = "room"; Series = $K.Series; Time = $K.Started.AddSeconds($A).ToString("yyyy-MM-dd HH:mm"); Samples = $Samples; Src = "walk"; WalkId = $K.Id }
        }
    }
    $script:Wplan.Points = @($Keep) + @($New)
    return $New.Count
}

# ---------------------------------------------------------------- positions for the map

# known positions over time: clicks; without clicks — centres of the named rooms
function Get-WalkAnchors {
    param($K)
    if (@($K.Clicks).Count) { return @($K.Clicks | Sort-Object { $_.T } | ForEach-Object { @{ T = [double]$_.T; X = [double]$_.X; Y = [double]$_.Y } }) }
    return @(foreach ($I in @($K.Timeline)) { $C = Get-FloorRoomCenter $I.Room; if ($C) { @{ T = [double]$I.T0 + 1; X = $C.X; Y = $C.Y }; @{ T = [double]$I.T1 - 1; X = $C.X; Y = $C.Y } } })
}

function Get-WalkPosAt {
    param($Anchors, [double]$T)
    if (-not @($Anchors).Count) { return $null }
    if ($T -le $Anchors[0].T) { return $Anchors[0] }
    for ($i = 1; $i -lt $Anchors.Count; $i++) {
        if ($T -le $Anchors[$i].T) {
            $A = $Anchors[$i - 1]; $B = $Anchors[$i]; $D = [Math]::Max(0.001, $B.T - $A.T); $F = ($T - $A.T) / $D
            return @{ X = $A.X + ($B.X - $A.X) * $F; Y = $A.Y + ($B.Y - $A.Y) * $F }
        }
    }
    return $Anchors[$Anchors.Count - 1]
}

function Get-WalkTrack { param($K) return @(Get-WalkAnchors $K) }

function Get-WalkSignalDots {
    param($K)
    $An = @(Get-WalkAnchors $K)
    if (-not $An.Count) { return @() }
    $Last = -10
    return @(foreach ($C in @($K.Conn)) {
        if (-not $C.Conn -or $C.T - $Last -lt 1.5) { continue }
        $Last = $C.T
        $P = Get-WalkPosAt $An $C.T
        @{ X = $P.X; Y = $P.Y; Rssi = [int]$C.Rssi; Tip = "$(Format-WalkTime $C.T) · $(Get-RoamApName $C.Bssid) · $($C.Rssi) dBm · кан. $($C.Ch)" }
    })
}

function Get-WalkEventMarks {
    param($K)
    $An = @(Get-WalkAnchors $K)
    if (-not $An.Count) { return @() }
    $L = @()
    foreach ($E in @($K.Events)) {
        if ($E.Title -notmatch '^(Роуминг|Пропал|Wi-Fi отключился|Нет IP|Сменилась|MAC шлюза)') { continue }
        $P = Get-WalkPosAt $An $E.T
        $L += @{ X = $P.X; Y = $P.Y; Kind = $(if ($E.Title -like "Роуминг*" -and $E.Kind -eq "ok") { "ok" } else { $E.Kind }); Tip = "$(Format-WalkTime $E.T) · $($E.Title) · $($E.Detail)" }
    }
    foreach ($N in @($K.Notes)) { $P = Get-WalkPosAt $An $N.T; $L += @{ X = $P.X; Y = $P.Y; Kind = "note"; Tip = "$(Format-WalkTime $N.T) · «$($N.Text)»" } }
    return $L
}

# where the engineer was during a room interval: clicks (middle of the stay) or the room centre
function Get-WalkIntervalPos {
    param($K, $I)
    # clicks made while in the room → their average; else the room centre; else the route at mid-stay
    $In = @($K.Clicks | Where-Object { [double]$_.T -ge [double]$I.T0 -and [double]$_.T -lt [double]$I.T1 })
    if ($In.Count) { return @{ X = ($In | Measure-Object -Property X -Average).Average; Y = ($In | Measure-Object -Property Y -Average).Average } }
    $C = Get-FloorRoomCenter $I.Room
    if ($C) { return $C }
    $An = @(Get-WalkAnchors $K)
    if ($An.Count) { return Get-WalkPosAt $An (([double]$I.T0 + [double]$I.T1) / 2) }
    return $null
}

# AP position on the plan by BSSID (group key), or $null
function Get-WalkApPos {
    param([string]$Bssid)
    $F = Get-Floor
    if (-not $F -or -not $Bssid) { return $null }
    $Ky = Get-WplanKey $Bssid
    if ($F.Aps.ContainsKey($Ky)) { return $F.Aps[$Ky] }
    return $null
}

# measured vs free space: expected = EIRP − FSPL(d) − client loss; excess = what walls/floors took (dB).
# Client loss ≈ 10 dB (laptop antennas, body, polarisation) so a room in line of sight lands near 0.
$script:WalkClientLoss = 10
function Get-WalkWallLoss {
    param([string]$Key, [string]$Band, [int]$Ch, [int]$Rssi, $Pos)
    $F = Get-Floor
    if (-not $Pos -or -not $F.Aps.ContainsKey($Key)) { return $null }
    $D = Get-FloorDist $Pos $F.Aps[$Key]
    if ($null -eq $D) { return $null }
    $A = $script:Wplan.Aps[$Key]
    $Tx = $(if ($A) { "$(if ($Band -eq '5') { $A.Tx5 } else { $A.Tx24 })" } else { "" })
    if ($Tx -notmatch '^\d+$') { return @{ D = $D } }
    $Exp = [int]$Tx - (Get-FloorFspl $D $Ch) - $script:WalkClientLoss
    return @{ D = $D; Exp = [int][Math]::Round($Exp); Loss = [int][Math]::Round($Exp - $Rssi) }
}

# ---------------------------------------------------------------- report

function Get-WalkReport {
    param($K = $script:Walk)
    if (-not $K) { return "" }
    $Out = [System.Text.StringBuilder]::new()
    $Roams = @($K.Events | Where-Object { $_.Title -like "Роуминг*" })
    $Bad = @($Roams | Where-Object { $_.Kind -in @("warn", "fail") })
    $Rooms = @($K.Timeline | ForEach-Object { $_.Room } | Sort-Object -Unique)
    [void]$Out.AppendLine(("ПРОГУЛКА «{0}» · {1} · {2:N1} мин · помещений {3} · переходов {4}, с потерей связи {5}" -f $(if ($K.Phase -eq "before") { "до" } else { "после" }), $K.Started.ToString("dd.MM HH:mm"), ($K.Duration / 60), $Rooms.Count, $Roams.Count, $Bad.Count))
    if (-not @($K.Timeline).Count) { [void]$Out.AppendLine("Помещения не определены: ни одно название не распознано в речи и нет кликов по помещениям на плане. Проверь названия помещений на шаге «План».") }
    [void]$Out.AppendLine("")
    [void]$Out.AppendLine("ПО ПОМЕЩЕНИЯМ (подключение ноутбука; dBm ноутбука)")
    foreach ($I in @($K.Timeline)) {
        $C = @($K.Conn | Where-Object { $_.T -ge $I.T0 -and $_.T -lt $I.T1 })
        $Cn = @($C | Where-Object { $_.Conn })
        $Ap = ($Cn | Group-Object { $_.Bssid } | Sort-Object Count -Descending | Select-Object -First 1)
        $Rs = @($Cn | ForEach-Object { [int]$_.Rssi } | Sort-Object)
        $Gw = @($C | Where-Object { $_.Conn -and -not $_.Scan })
        $Loss = $(if ($Gw.Count) { 100.0 * @($Gw | Where-Object { [int]$_.Gw -lt 0 }).Count / $Gw.Count } else { 0 })
        $Ev = @($K.Events | Where-Object { $_.T -ge $I.T0 -and $_.T -lt $I.T1 -and $_.Kind -in @("warn", "fail") -and $_.Title -notlike "Windows*" })
        $Dist = $(if ($Ap) { Get-FloorDist (Get-WalkIntervalPos $K $I) (Get-WalkApPos $Ap.Name) } else { $null })
        [void]$Out.AppendLine(("  {0}  {1,-22} {2,5}  {3}{4}{5}" -f (Format-WalkTime $I.T0), $I.Room, (Format-WalkTime ($I.T1 - $I.T0)),
            $(if ($Ap) { "$(Get-RoamApName $Ap.Name) $(if ($Rs.Count) { "$($Rs[[int][Math]::Floor(($Rs.Count - 1) / 2)]) (мин $($Rs[0]))" }) dBm$(if ($null -ne $Dist) { ", до точки $(Format-FloorM $Dist)" })" } else { "нет подключения" }),
            $(if ($Loss -ge 2) { (" · потери до шлюза {0:N0}%" -f $Loss) } else { "" }),
            $(if ($Ev.Count) { " · " + (@($Ev | ForEach-Object { $_.Title }) -join "; ") } else { "" })))
    }
    if (@($K.Notes).Count) {
        [void]$Out.AppendLine("")
        [void]$Out.AppendLine("ЗАМЕТКИ ГОЛОСОМ И ОТМЕТКИ")
        foreach ($N in @($K.Notes)) { [void]$Out.AppendLine(("  {0}  {1,-18} «{2}»" -f (Format-WalkTime $N.T), $N.Room, $N.Text)) }
    }
    if (@($Roams).Count) {
        [void]$Out.AppendLine("")
        [void]$Out.AppendLine("ПЕРЕХОДЫ МЕЖДУ ТОЧКАМИ")
        foreach ($E in $Roams) { [void]$Out.AppendLine(("  {0}  {1,-18} {2} {3} · {4}" -f (Format-WalkTime $E.T), (Get-WalkRoomAtTime $E.T $K), $(switch ($E.Kind) { "fail" { "✖" } "warn" { "▲" } default { "✔" } }), ($E.Title -replace '^Роуминг\s*', ''), $E.Detail)) }
    }
    $Un = @($K.Phrases | Where-Object { -not (Find-WalkRoom $_.Text (Get-WalkRoomNames)) } | Select-Object -First 12)
    if ($Un.Count) {
        [void]$Out.AppendLine("")
        [void]$Out.AppendLine("НЕ СОПОСТАВЛЕНО С ПОМЕЩЕНИЯМИ (если это помещение — добавь его на плане с таким названием и нажми «Пересобрать»)")
        foreach ($P in $Un) { [void]$Out.AppendLine(("  {0}  «{1}»" -f (Format-WalkTime $P.T0), $P.Text)) }
    }
    if ($K.ScanErr) { [void]$Out.AppendLine(""); [void]$Out.AppendLine("Скан эфира: $($K.ScanErr)") }
    return $Out.ToString()
}

# picture of the current walk map for the AI (route and signal on the plan)
function Get-WalkMapB64 {
    $V = $script:WalkView
    if (-not $V -or -not $V.W) { return "" }
    $K = 1568.0 / [Math]::Max($V.W, $V.H); if ($K -gt 1) { $K = 1 }
    $Wd = [int]($V.W * $K); $Ht = [int]($V.H * $K)
    $Dv = New-Object System.Windows.Media.DrawingVisual
    $Dc = $Dv.RenderOpen()
    $Rc = New-Object System.Windows.Rect 0, 0, $Wd, $Ht
    $Dc.DrawRectangle([System.Windows.Media.Brushes]::White, $null, $Rc)
    $Dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush $V.Canvas), $null, $Rc)
    $Dc.Close()
    $Rt = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($Wd, $Ht, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $Rt.Render($Dv)
    $Enc = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder; $Enc.QualityLevel = 85
    $Enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Rt))
    $Ms = New-Object IO.MemoryStream; $Enc.Save($Ms)
    return [Convert]::ToBase64String($Ms.ToArray())
}

function Get-WalkAiData {
    $K = $script:Walk
    $F = Get-Floor
    $Out = [System.Text.StringBuilder]::new()
    [void]$Out.AppendLine("ОБЪЕКТ: $($script:Wplan.Site); SSID: $(@($script:Wplan.Ssids) -join ', ')")
    $Kpx = Get-FloorMPerPx
    if ($Kpx) { [void]$Out.AppendLine(("МАСШТАБ: план {0:N1}×{1:N1} м; координаты ниже — метры от левого верхнего угла плана." -f ($F.W * $Kpx), ($F.H * $Kpx))) }
    [void]$Out.AppendLine("ТОЧКИ ДОСТУПА (положение на плане; помещение; текущая мощность EIRP из Omada):")
    $Keys = @(@($script:Wplan.Aps.Keys) + @($F.Aps.Keys) | Sort-Object -Unique)
    foreach ($Ky in $Keys) {
        $A = $script:Wplan.Aps[$Ky]; $P = $F.Aps[$Ky]
        $Rm = $(if ($P) { (Get-FloorRoomAt $P.X $P.Y).Name } else { "" })
        [void]$Out.AppendLine(("  {0}: {1}{2}; 2.4 ГГц {3} dBm, 5 ГГц {4} dBm" -f (Get-WplanApName $Ky), $(if (-not $P) { "не отмечена на плане" } elseif ($Kpx) { "x={0:N1} м y={1:N1} м" -f ($P.X * $F.W * $Kpx), ($P.Y * $F.H * $Kpx) } else { "x={0:N2} y={1:N2} (доли)" -f $P.X, $P.Y }), $(if ($Rm) { " ($Rm)" } else { "" }), $(if ($A -and "$($A.Tx24)") { $A.Tx24 } else { "?" }), $(if ($A -and "$($A.Tx5)") { $A.Tx5 } else { "?" })))
    }
    if ($Kpx -and $F.Aps.Count -ge 2) {
        [void]$Out.AppendLine("РАССТОЯНИЕ ДО БЛИЖАЙШЕЙ ТОЧКИ:")
        foreach ($Ky in @($F.Aps.Keys)) {
            $Nb = @($F.Aps.Keys | Where-Object { $_ -ne $Ky } | ForEach-Object { @{ K = $_; D = (Get-FloorDist $F.Aps[$Ky] $F.Aps[$_]) } } | Sort-Object { $_.D }) | Select-Object -First 1
            if ($Nb) { [void]$Out.AppendLine(("  {0} → {1}: {2}" -f (Get-WplanApName $Ky), (Get-WplanApName $Nb.K), (Format-FloorM $Nb.D))) }
        }
    }
    if (@($F.Rooms).Count) {
        [void]$Out.AppendLine($(if ($Kpx) { "ПОМЕЩЕНИЯ (левый верхний угол x,y и размер, м):" } else { "ПОМЕЩЕНИЯ (прямоугольники x,y,w,h в долях):" }))
        foreach ($R in @($F.Rooms)) {
            if ($Kpx) { [void]$Out.AppendLine(("  {0}: {1:N1},{2:N1} · {3}" -f $R.Name, ($R.X * $F.W * $Kpx), ($R.Y * $F.H * $Kpx), (Get-FloorRoomSize $R))) }
            else { [void]$Out.AppendLine(("  {0}: {1:N2},{2:N2},{3:N2},{4:N2}" -f $R.Name, $R.X, $R.Y, $R.W, $R.H)) }
        }
    }
    [void]$Out.AppendLine("")
    [void]$Out.AppendLine((Get-WalkReport))
    # what the laptop heard in each room (best 3 APs per band from the scans)
    [void]$Out.AppendLine("ЭФИР ПО ПОМЕЩЕНИЯМ (медиана, dBm ноутбука; лучшие 3 своих точки на диапазон$(if ($Kpx) { '; в скобках расстояние до точки и сколько dB «съели» стены/перекрытия против свободного пространства (EIRP − FSPL)' })):")
    foreach ($I in @($K.Timeline)) {
        $Sc = @($K.Scans | Where-Object { $_.T -ge $I.T0 -and $_.T -le $I.T1 })
        if (-not $Sc.Count) { continue }
        $Line = "  $($I.Room):"
        foreach ($B in @("5", "2.4")) {
            $Acc = @{}
            foreach ($S in $Sc) { foreach ($X in @($S.Samples)) { if ($X.Band -ne $B -or -not (Test-WplanOurs $X)) { continue }; $Ky = Get-WplanKey $X.Bssid; if (-not $Acc.ContainsKey($Ky)) { $Acc[$Ky] = @{ R = [System.Collections.Generic.List[int]]::new(); Ch = [int]$X.Ch } }; $Acc[$Ky].R.Add([int]$X.Rssi) } }
            $Top = @($Acc.Keys | ForEach-Object { $L = @($Acc[$_].R | Sort-Object); @{ K = $_; R = $L[[int][Math]::Floor(($L.Count - 1) / 2)]; Ch = $Acc[$_].Ch } } | Sort-Object { -$_.R } | Select-Object -First 3)
            $Pos = Get-WalkIntervalPos $K $I
            $Line += " $B ГГц: " + $(if ($Top.Count) { (@($Top | ForEach-Object {
                $Wl = Get-WalkWallLoss $_.K $B $_.Ch $_.R $Pos
                "$(Get-WplanApName $_.K) $($_.R)$(if ($Wl) { " ($(Format-FloorM $Wl.D)$(if ($null -ne $Wl.Loss) { ", стены ≈$($Wl.Loss) dB" }))" })"
            }) -join ", ") } else { "—" }) + ";"
        }
        [void]$Out.AppendLine($Line)
    }
    return $Out.ToString()
}

function Start-WalkAi {
    if (-not $script:Walk) { Show-Toast "Нет прогулки" "warn"; return }
    $Sys = "Ты инженер беспроводных сетей (TP-Link Omada, точки EAP, роутер MikroTik). Дан план объекта с отмеченными точками доступа (синие кружки), масштабной линией (оранжевая, если задана), маршрутом обхода (линия), уровнем сигнала подключения по пути (зелёный ≥-60, жёлто-зелёный ≥-67, жёлтый ≥-72, оранжевый ≥-78, красный хуже; dBm ноутбука, телефон примерно на 6 dB хуже), событиями (синий — бесшовный переход, оранжевый — переход с паузой, красный — обрыв, фиолетовый — голосовая заметка инженера) и данные обхода. Если есть масштаб — пользуйся метрами и оценкой «стены ≈ N dB» (замер против свободного пространства, поправка клиента 10 dB уже учтена; оценка грубая ±5 dB, сравнивай помещения между собой): большая цифра на коротком расстоянии — капитальная стена/перекрытие между точкой и помещением, малая на длинном — просто далеко. Разбери: где покрытие слабое и почему (стены, расстояние до точки), где клиенты «липнут» к дальней точке, где проблемы не радио (потери до шлюза при хорошем сигнале — кабель/порт/PoE). Дай конкретные действия по пунктам: мощность и канал по точкам, перенос или добавление точки (куда, на плане; с масштабом — в метрах), настройки Omada. Учитывай голосовые заметки. По-русски, кратко, без воды."
    $Ui.WkAi.IsEnabled = $false
    $Ui.WkResult.Text = (Get-WalkReport) + "`r`n━━━ РАЗБОР ИИ ━━━`r`nотправляю план, карту и данные обхода ($((Get-AiConf).Title))…"
    $Ok = Start-AiRequest -Name "walk-ai" -System $Sys -UserText (Get-WalkAiData) -MaxTokens 3000 -ImageB64 (Get-WalkMapB64) -OnResult {
        param($M)
        $Ui.WkAi.IsEnabled = $true
        if (-not $M.Ok) { Show-Toast "ИИ: $($M.Text)" "fail"; $Ui.WkResult.Text = Get-WalkReport; return }
        $script:Walk.Ai = $M.Text
        $Ui.WkResult.Text = (Get-WalkReport) + "`r`n━━━ РАЗБОР ИИ ━━━`r`n" + $(if ($M.NoImage) { "(провайдер не принял картинку карты — разбор только по данным обхода)`r`n" } else { "" }) + $M.Text
    }
    if (-not $Ok) { $Ui.WkAi.IsEnabled = $true }
}

# ---------------------------------------------------------------- UI

function Set-WalkWhisperStatus {
    param([string]$Text, [string]$Kind)
    $Ui.WkWhisper.Text = $Text
    $Ui.WkWhisper.Foreground = Get-Brush $(switch ($Kind) { "ok" { "Ok" } "fail" { "Fail" } "wait" { "Warn" } default { "Sub" } })
    $Ui.WkInstall.Visibility = $(if (Test-WhisperReady) { "Collapsed" } else { "Visible" })
}

function Update-WalkView {
    if (-not $script:WalkView) { return }
    Update-FloorView $script:WalkView -Walk $script:Walk
    # live marker: where I am now (last click)
    $K = $script:Walk
    if ($K -and $K.Running -and $K.Clicks.Count -and $script:WalkView.W) {
        $C = $K.Clicks[$K.Clicks.Count - 1]; $U = $script:WalkView.W / 1000
        [void](Add-FloorDot $script:WalkView.Canvas ($C.X * $script:WalkView.W) ($C.Y * $script:WalkView.H) (26 * $U) (ConvertTo-Brush "#3B82F6") ([System.Windows.Media.Brushes]::White) (5 * $U) "я здесь")
    }
}

function Update-WalkLive {
    $K = $script:Walk
    if (-not $K -or -not $K.Running) { return }
    $S = ([DateTime]::Now - $K.Started).TotalSeconds
    $Ui.WkTime.Text = Format-WalkTime $S
    $Lv = $(if ($K.Mic) { [Math]::Min(1.0, $K.Mic.Peak / 12000.0) } else { 0 })
    $Ui.WkLevel.Width = [Math]::Max(2.0, $Lv * $Ui.WkLevelBox.ActualWidth)
    $Ui.WkLevel.Background = Get-Brush $(if (-not $K.Mic) { "Faint" } elseif ($Lv -gt 0.05) { "Ok" } else { "Sub" })
    $L = $(if ($script:Roam) { $script:Roam.Last } else { $null })
    $Room = $(if ($K.Clicks.Count) { $Rm = Get-FloorRoomAt $K.Clicks[$K.Clicks.Count - 1].X $K.Clicks[$K.Clicks.Count - 1].Y; if ($Rm) { $Rm.Name } else { "" } } else { "" })
    $Ui.WkNow.Text = $(if ($L -and $L.State -eq 1 -and $L.Bssid) { "$(Get-RoamApName $L.Bssid) · $($L.Rssi) dBm · кан. $($L.Ch) ($(Get-RoamBand $L.Ch) ГГц)" } else { "нет подключения к Wi-Fi" }) + $(if ($Room) { "`n$Room (по клику)" } else { "" })
    $Ui.WkStats.Text = "$(if ($K.Mic) { "запись голоса $(Format-WalkTime $K.Mic.Seconds)" } else { 'без голоса' }) · сканов эфира $($K.Scans.Count) · кликов $($K.Clicks.Count) · отметок $($K.Marks.Count)"
}

function Show-WalkStep {
    param([string]$Phase)
    $script:WalkPhase = $Phase
    # the last walk of this phase is shown until a new one starts
    $W = Get-WhState
    $Id = $(if ($Phase -eq "before") { $W.WalkBefore } else { $W.WalkAfter })
    if (-not ($script:Walk -and $script:Walk.Running)) {
        $script:Walk = $(if ($Id) { Read-WalkFile $Id } else { $null })
        $Ui.WkResult.Text = $(if ($script:Walk) { Get-WalkReport } else { "" })
        $Ui.WkTime.Text = $(if ($script:Walk) { Format-WalkTime $script:Walk.Duration } else { "00:00" })
        $Ui.WkStats.Text = $(if ($script:Walk) { "прогулка $($script:Walk.Started.ToString('dd.MM HH:mm')) · фраз $(@($script:Walk.Phrases).Count) · сканов $($script:Walk.Scans.Count)" } else { "" })
        $Ui.WkNow.Text = ""
    }
    $Ui.WkStart.IsEnabled = -not ($script:Walk -and $script:Walk.Running)
    $Ui.WkStop.IsEnabled = [bool]($script:Walk -and $script:Walk.Running)
    $Ui.WkMark.IsEnabled = $Ui.WkStop.IsEnabled
    $Ui.WkAi.IsEnabled = [bool]($script:Walk -and -not $script:Walk.Running)
    $Ui.WkRetx.IsEnabled = [bool]($script:Walk -and -not $script:Walk.Running -and $script:Walk.Wav -and (Test-Path $script:Walk.Wav))
    Update-WalkCheckButton
    Set-WalkWhisperStatus $(if (Test-WhisperReady) { "Распознавание речи готово (Whisper, $(Get-WhisperModel), офлайн)" } else { "Распознавание речи не установлено — голос запишется, расшифровка после установки" }) $(if (Test-WhisperReady) { "ok" } else { "sub" })
    Update-WalkView
}

function Initialize-WalkPage {
    $script:WalkView = New-FloorView "walk"
    $script:WalkView.Placeholder.Text = "План не загружен — место определяется по голосу (названия помещений).`nЗагрузи план на шаге «План», чтобы видеть маршрут и сигнал на карте."
    Set-FloorViewHost $script:WalkView $Ui.WkHost
    $Ui.WkEvents.ItemsSource = $script:RoamEvents
    $Ui.WkStart.Add_Click({ Start-Walk $script:WalkPhase })
    $Ui.WkStop.Add_Click({ Stop-Walk })
    $Ui.WkMark.Add_Click({ Add-WalkMark })
    $Ui.WkCheck.Add_Click({ Add-WalkCheckpoint })
    # Space = «Дошёл» while walking (hands busy with the laptop)
    $script:Win.Add_PreviewKeyDown({
        param($S, $E)
        if ($E.Key -ne "Space" -or -not ($script:Walk -and $script:Walk.Running) -or -not $Ui.PageWalk.IsVisible) { return }
        if ([System.Windows.Input.Keyboard]::FocusedElement -is [System.Windows.Controls.TextBox]) { return }
        if (@((Get-Floor).Route).Count) { Add-WalkCheckpoint } else { Add-WalkMark }
        $E.Handled = $true
    })
    $Ui.WkAi.Add_Click({ Start-WalkAi })
    $Ui.WkRetx.Add_Click({ if (Test-WhisperReady) { Start-WalkTranscribe } else { Install-Whisper { param($T, $Kd) Set-WalkWhisperStatus $T $Kd } { Start-WalkTranscribe } } })
    $Ui.WkRebuild.Add_Click({ if ($script:Walk -and -not $script:Walk.Running) { Complete-Walk } })
    $Ui.WkInstall.Add_Click({ Install-Whisper { param($T, $Kd) Set-WalkWhisperStatus $T $Kd } { Set-WalkWhisperStatus "Распознавание речи готово" "ok" } })
    $Ui.WkCopy.Add_Click({ Copy-Text $Ui.WkResult.Text "отчёт прогулки" })
    $Ui.WkManual.Add_Click({ Show-WhManualSurvey })
    $Ui.WkRoamDetail.Add_Click({ Show-WhPanel "PageRoam"; $Ui.WhText.Text = "Монитор роуминга — подробности этой прогулки. Вернуться — кнопка шага сверху." })
    $script:WalkView.Canvas.Add_MouseLeftButtonDown({
        param($S, $E)
        $V = $script:WalkView; if (-not $V.W) { return }
        if (-not ($script:Walk -and $script:Walk.Running)) { Show-Toast "Клики по плану записываются во время прогулки — нажми «Старт»" "info"; return }
        $P = $E.GetPosition($V.Canvas)
        Add-WalkClick ($P.X / $V.W) ($P.Y / $V.H)
    })
}
