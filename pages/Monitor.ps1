# Page: monitor (background ping of chosen hosts with sparklines), Wi-Fi card, speed test.

$script:MonItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:MonState = @{}        # id -> @{ Hist = List[int] (-1 = loss); Up = $null/bool; Since; Sent; Lost; Sum; Ok; Fails }
$script:MonIntervalMs = 5000

function Get-MonTargets { return @($script:Settings.Monitor | Where-Object { $_ -and $_.Id -and $_.Target }) }

$script:MonBody = {
    param($Q, $Ctl, $Targets, $IntervalMs)
    $Resolved = @{}
    $Cycle = 0
    while (-not $Ctl.Stop) {
        $Cycle++
        # resolve names (cached, retried every 12 cycles)
        foreach ($T in $Targets) {
            if ($Resolved[$T.Id] -and ($Cycle % 12) -ne 0) { continue }
            if ($T.Target -match '^\d{1,3}(\.\d{1,3}){3}$') { $Resolved[$T.Id] = $T.Target; continue }
            try {
                $Task = [System.Net.Dns]::GetHostAddressesAsync($T.Target)
                if ($Task.Wait(2500)) { $A = $Task.Result | Where-Object { $_.AddressFamily -eq "InterNetwork" } | Select-Object -First 1; if ($A) { $Resolved[$T.Id] = $A.ToString() } }
            } catch { }
        }
        $Ips = @($Resolved.Values | Select-Object -Unique)
        $Rtt = @{}
        if ($Ips) { $Rtt = Invoke-PingBatch $Ips 1500 }
        foreach ($T in $Targets) {
            $Ip = $Resolved[$T.Id]
            if (-not $Ip) { $Q.Enqueue(@{ Type = "mon"; Id = $T.Id; Ok = $false; Rtt = -1; Ip = ""; Err = "имя не резолвится" }); continue }
            $Ok = $Rtt.ContainsKey($Ip)
            $Q.Enqueue(@{ Type = "mon"; Id = $T.Id; Ok = $Ok; Rtt = $(if ($Ok) { $Rtt[$Ip] } else { -1 }); Ip = $Ip })
        }
        if ($Cycle % 3 -eq 1) { $Q.Enqueue(@{ Type = "wlan"; W = (Get-WlanInfo) }) }
        $Wait = $IntervalMs
        while ($Wait -gt 0 -and -not $Ctl.Stop) { Start-Sleep -Milliseconds ([Math]::Min(200, $Wait)); $Wait -= 200 }
    }
}

function Get-SparkPaths {
    param($Hist)
    $N = 60; $W = 120; $H = 26
    $Data = @($Hist | Select-Object -Last $N)
    if (-not $Data.Count) { return @("", "") }
    $Max = ($Data | Where-Object { $_ -ge 0 } | Measure-Object -Maximum).Maximum
    if (-not $Max -or $Max -lt 10) { $Max = 10 }
    $Step = $W / ($N - 1)
    $X0 = $W - ($Data.Count - 1) * $Step
    $Line = New-Object System.Text.StringBuilder
    $Loss = New-Object System.Text.StringBuilder
    $Pen = $false
    for ($i = 0; $i -lt $Data.Count; $i++) {
        $X = [Math]::Round($X0 + $i * $Step, 1)
        if ($Data[$i] -lt 0) {
            [void]$Loss.Append("M$X,2 L$X,$($H - 2) ")
            $Pen = $false
        } else {
            $Y = [Math]::Round($H - 2 - ($Data[$i] / $Max) * ($H - 6), 1)
            [void]$Line.Append($(if ($Pen) { "L" } else { "M" }) + "$X,$Y ")
            $Pen = $true
        }
    }
    return @($Line.ToString().Trim(), $Loss.ToString().Trim())
}

function New-MonRow {
    param($T)
    $S = $script:MonState[$T.Id]
    if (-not $S) { $S = @{ Hist = [System.Collections.Generic.List[int]]::new(); Up = $null; Since = $null; Sent = 0; Lost = 0; Sum = 0; Ok = 0; Fails = 0; Ip = "" }; $script:MonState[$T.Id] = $S }
    $Paths = Get-SparkPaths $S.Hist
    $Last = if ($S.Hist.Count) { $S.Hist[$S.Hist.Count - 1] } else { $null }
    $Kind = "none"; $Status = "ждём…"
    if ($null -ne $S.Up) {
        if ($S.Up) { $Kind = if ($Last -lt 0) { "wait" } else { "ok" }; $Status = if ($Last -ge 0) { "$Last мс" } else { "потеря" } }
        else { $Kind = "fail"; $Status = $(if ($S.Err) { $S.Err } else { "недоступен" }) }
    }
    $Stats = ""
    if ($S.Sent) {
        $LossPct = [Math]::Round(100.0 * $S.Lost / $S.Sent)
        $Avg = if ($S.Ok) { [Math]::Round($S.Sum / $S.Ok) } else { 0 }
        $Stats = "ср. $Avg мс · потери $LossPct% · $($S.Sent) проб"
    }
    $Since = ""
    if ($S.Since) {
        $Span = [DateTime]::Now - $S.Since
        $Txt = if ($Span.TotalMinutes -lt 1) { "только что" } elseif ($Span.TotalHours -lt 1) { "$([int]$Span.TotalMinutes) мин" } elseif ($Span.TotalDays -lt 1) { "$([int]$Span.TotalHours) ч" } else { "$([int]$Span.TotalDays) д" }
        $Since = $(if ($S.Up) { "в сети " } else { "лежит " }) + $Txt
    }
    return [pscustomobject]@{
        Id = $T.Id; Name = $T.Name; Target = $(if ($S.Ip -and $S.Ip -ne $T.Target) { "$($T.Target)  $($S.Ip)" } else { $T.Target })
        Kind = $Kind; StatusText = $Status; Stats = $Stats; Since = $Since
        Spark = $Paths[0]; LossPath = $Paths[1]; DelTag = "mon:del:$($T.Id)"; Mon = $T
    }
}

function Refresh-Monitor {
    $script:MonItems.Clear()
    foreach ($T in Get-MonTargets) { $script:MonItems.Add((New-MonRow $T)) }
    $Ui.MonEmpty.Visibility = $(if ($script:MonItems.Count) { "Collapsed" } else { "Visible" })
    $Down = @($script:MonState.Values | Where-Object { $_.Up -eq $false }).Count
    $Ui.NavMonitor.Tag = $(if ($Down) { "$Down" } else { $null })
    Update-PageSub
}

function Update-MonRow {
    param([string]$Id)
    for ($i = 0; $i -lt $script:MonItems.Count; $i++) {
        if ($script:MonItems[$i].Id -ne $Id) { continue }
        $Sel = ($Ui.MonList.SelectedItem -eq $script:MonItems[$i])
        $script:MonItems[$i] = New-MonRow $script:MonItems[$i].Mon
        if ($Sel) { $Ui.MonList.SelectedItem = $script:MonItems[$i] }
        break
    }
}

function Get-MonitorSub {
    $All = @(Get-MonTargets).Count
    if (-not $All) { return "Фоновый пинг выбранных хостов, Wi-Fi и тест скорости" }
    $Up = @($script:MonState.Values | Where-Object { $_.Up -eq $true }).Count
    $Down = @($script:MonState.Values | Where-Object { $_.Up -eq $false }).Count
    return "$(Get-Plural $All 'цель' 'цели' 'целей') · в сети $Up · лежат $Down · интервал $($script:MonIntervalMs / 1000) с"
}

function Start-Monitor {
    $Targets = @(Get-MonTargets)
    if (-not $Targets.Count) { Stop-Worker "monitor"; Refresh-Monitor; return }
    $Plain = @($Targets | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Target = $_.Target } })
    [void](Start-Worker -Name "monitor" -Replace -Body $script:MonBody -ArgList @(@(, $Plain) + @($script:MonIntervalMs)) -OnMessage {
        param($M)
        if ($M.Type -eq "wlan") { Update-WlanCard $M.W; return }
        if ($M.Type -ne "mon") { return }
        $S = $script:MonState[$M.Id]
        if (-not $S) { return }
        $S.Sent++; $S.Ip = $M.Ip; $S.Err = $M.Err
        if ($M.Ok) { $S.Ok++; $S.Sum += $M.Rtt; $S.Fails = 0; $S.Hist.Add([int]$M.Rtt) } else { $S.Lost++; $S.Fails++; $S.Hist.Add(-1) }
        if ($S.Hist.Count -gt 240) { $S.Hist.RemoveAt(0) }

        $NewUp = $S.Up
        if ($M.Ok) { $NewUp = $true } elseif ($S.Fails -ge 3 -or $null -eq $S.Up) { $NewUp = $false }
        if ($NewUp -ne $S.Up) {
            $First = ($null -eq $S.Up)
            $S.Up = $NewUp; $S.Since = [DateTime]::Now
            $T = Get-MonTargets | Where-Object { $_.Id -eq $M.Id } | Select-Object -First 1
            if (-not $First) {
                if ($NewUp) { Show-Toast "$($T.Name) снова в сети" "ok" } else { Show-Toast "$($T.Name) недоступен" "fail"; if ($Ui.MonNotify.IsChecked) { [System.Media.SystemSounds]::Hand.Play() } }
                Show-TrayBalloon $(if ($NewUp) { "$($T.Name) снова в сети" } else { "$($T.Name) недоступен" }) $T.Target $(if ($NewUp) { "Info" } else { "Warning" })
            }
        }
        Update-MonRow $M.Id
        $Down = @($script:MonState.Values | Where-Object { $_.Up -eq $false }).Count
        $Ui.NavMonitor.Tag = $(if ($Down) { "$Down" } else { $null })
        Update-TrayText
        if ($script:Page -eq "monitor") { Update-PageSub }
    })
}

function Add-MonTarget {
    param([string]$Target, [string]$Name)
    $Target = $Target.Trim()
    if (-not $Target) { return }
    # alias from config → its HostName
    $H = $script:Hosts | Where-Object { $_.Alias -eq $Target } | Select-Object -First 1
    if ($H) { if (-not $Name) { $Name = $H.Alias }; $Target = $H.HostName }
    if (-not $Name) { $Name = $Target }
    if (Get-MonTargets | Where-Object { $_.Target -eq $Target }) { Show-Toast "$Target уже в мониторе" "warn"; return }
    $script:Settings.Monitor = @(Get-MonTargets) + @(@{ Id = [guid]::NewGuid().ToString("N").Substring(0, 8); Name = $Name; Target = $Target })
    Save-Settings
    Refresh-Monitor
    Start-Monitor
    Show-Toast "Слежу: $Name" "info"
}

function Remove-MonTarget {
    param([string]$Id)
    $T = Get-MonTargets | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    $script:Settings.Monitor = @(Get-MonTargets | Where-Object { $_.Id -ne $Id })
    $script:MonState.Remove($Id)
    Save-Settings
    Refresh-Monitor
    Start-Monitor
    if ($T) { Show-Toast "Убран из монитора: $($T.Name)" "info" }
}

function Invoke-MonAction {
    param([string]$Spec)
    $Op, $Id = $Spec -split ':', 2
    if ($Op -eq "del") { Remove-MonTarget $Id }
}

# ---------------------------------------------------------------- Wi-Fi card + header pill

function Update-WlanCard {
    param($W)
    $script:Wlan = $W
    if (-not $W -or -not $W.Connected) {
        $Ui.WlanSsid.Text = "—"
        $Ui.WlanMeta.Text = $(if ($W) { "$($W.Adapter): $($W.State)" } else { "нет Wi-Fi адаптера" })
        $Ui.WlanSignal.Text = ""; $Ui.WlanRssi.Text = ""; $Ui.WlanRates.Text = ""; $Ui.WlanBar.Width = 0
        $Ui.WifiPill.Visibility = "Collapsed"
        return
    }
    $Ui.WlanSsid.Text = $W.Ssid
    $Ui.WlanMeta.Text = "$($W.Band) · канал $($W.Channel) · $($W.Radio) · $($W.Auth) · BSSID $($W.Bssid)"
    $Ui.WlanSignal.Text = "$($W.Signal)%"
    $Ui.WlanRssi.Text = "RSSI $($W.Rssi) дБм"
    $Ui.WlanRates.Text = "↓ $($W.Rx) Мбит/с   ↑ $($W.Tx) Мбит/с   $($W.Adapter)"
    $Color = if ($W.Signal -ge 70) { "Ok" } elseif ($W.Signal -ge 45) { "Warn" } else { "Fail" }
    $Ui.WlanBar.Background = Get-Brush $Color
    $Ui.WlanSignal.Foreground = Get-Brush $Color
    $Parent = $Ui.WlanBar.Parent
    $Ui.WlanBar.Width = [Math]::Max(0, ($Parent.ActualWidth) * $W.Signal / 100.0)

    $Ui.WifiPill.Visibility = "Visible"
    $Ui.WifiText.Text = "$($W.Ssid) $($W.Signal)%"
    $Ui.WifiPill.ToolTip = "$($W.Band), канал $($W.Channel), $($W.Radio)`n↓ $($W.Rx) / ↑ $($W.Tx) Мбит/с, RSSI $($W.Rssi)`nBSSID $($W.Bssid)"
    $Ui.WifiPill.BorderBrush = $(if ($W.Signal -lt 45) { Get-Brush "Warn" } else { Get-Brush "Line" })
}

# ---------------------------------------------------------------- speed test

$script:SpeedBody = {
    param($Q, $Ctl, $Url)
    $H = [System.Net.Http.HttpClient]::new()
    $H.Timeout = [TimeSpan]::FromSeconds(40)
    [void]$H.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "NetKnife speed test")
    $IsCf = $Url -like "*speed.cloudflare.com*"
    $Base = ($Url -split '\?')[0]

    # latency: small requests
    $Lat = @()
    for ($i = 0; $i -lt 5 -and -not $Ctl.Stop; $i++) {
        $Sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $U = if ($IsCf) { "$Base`?bytes=0" } else { $Url }
            $Req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $U)
            if ($IsCf) { $Req.Method = [System.Net.Http.HttpMethod]::Get }
            $R = $H.SendAsync($Req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
            $Sw.Stop(); if ($i -gt 0) { $Lat += $Sw.ElapsedMilliseconds }
            $R.Dispose()
        } catch { $Sw.Stop() }
    }
    $LatMs = if ($Lat) { [int](($Lat | Measure-Object -Average).Average) } else { -1 }
    $Q.Enqueue(@{ Type = "speed"; Phase = "lat"; Lat = $LatMs })

    # download: repeat requests (25 MB chunks on Cloudflare, which rejects >50 MB) for up to 12 s
    $Down = 0.0
    try {
        $DlUrl = if ($IsCf) { "$Base`?bytes=25000000" } else { $Url }
        $Buf = New-Object byte[] 262144
        $Total = [long]0; $Sw = [System.Diagnostics.Stopwatch]::StartNew(); $LastReport = 0
        while (-not $Ctl.Stop -and $Sw.ElapsedMilliseconds -lt 12000) {
            $Resp = $H.GetAsync($DlUrl, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
            if (-not $Resp.IsSuccessStatusCode) { throw "HTTP $([int]$Resp.StatusCode) от $DlUrl" }
            $Stream = $Resp.Content.ReadAsStreamAsync().Result
            while (-not $Ctl.Stop) {
                $N = $Stream.Read($Buf, 0, $Buf.Length)
                if ($N -le 0) { break }
                $Total += $N
                if ($Sw.ElapsedMilliseconds - $LastReport -ge 400) {
                    $LastReport = $Sw.ElapsedMilliseconds
                    $Q.Enqueue(@{ Type = "speed"; Phase = "down"; Mbps = [Math]::Round($Total * 8 / 1e6 / ($Sw.ElapsedMilliseconds / 1000.0), 1); Pct = [Math]::Min(100, $Sw.ElapsedMilliseconds / 120) })
                }
                if ($Sw.ElapsedMilliseconds -gt 12000) { break }
            }
            $Stream.Dispose(); $Resp.Dispose()
            if ($Total -lt 100000) { break }   # tiny file: no point looping
        }
        $Sw.Stop()
        if ($Sw.ElapsedMilliseconds -gt 300 -and $Total -gt 0) { $Down = [Math]::Round($Total * 8 / 1e6 / ($Sw.ElapsedMilliseconds / 1000.0), 1) }
    } catch { $Q.Enqueue(@{ Type = "speed"; Phase = "err"; Text = "загрузка: $($_.Exception.InnerException.Message ?? $_.Exception.Message)" }) }

    # upload (Cloudflare endpoint only), up to 5 × 2 MB
    $Up = 0.0
    if ($IsCf -and -not $Ctl.Stop) {
        try {
            $Chunk = New-Object byte[] 2097152
            [System.Random]::new().NextBytes($Chunk)
            $Sent = [long]0; $Sw = [System.Diagnostics.Stopwatch]::StartNew()
            for ($i = 0; $i -lt 5 -and -not $Ctl.Stop -and $Sw.ElapsedMilliseconds -lt 12000; $i++) {
                $C = [System.Net.Http.ByteArrayContent]::new($Chunk)
                $R = $H.PostAsync("https://speed.cloudflare.com/__up", $C).Result
                $R.Dispose()
                $Sent += $Chunk.Length
                $Q.Enqueue(@{ Type = "speed"; Phase = "up"; Mbps = [Math]::Round($Sent * 8 / 1e6 / ($Sw.ElapsedMilliseconds / 1000.0), 1); Pct = [Math]::Min(100, 20 * ($i + 1)) })
            }
            $Sw.Stop()
            if ($Sw.ElapsedMilliseconds -gt 200) { $Up = [Math]::Round($Sent * 8 / 1e6 / ($Sw.ElapsedMilliseconds / 1000.0), 1) }
        } catch { $Q.Enqueue(@{ Type = "speed"; Phase = "err"; Text = "отдача: $($_.Exception.InnerException.Message ?? $_.Exception.Message)" }) }
    }
    $Q.Enqueue(@{ Type = "speed"; Phase = "done"; Down = $Down; Up = $Up; Lat = $LatMs; UpSkipped = (-not $IsCf) })
}

function Set-SpeedButton {
    param([bool]$Running)
    $Ui.SpeedStartText.Text = $(if ($Running) { "Стоп" } else { "Запустить" })
    $Ui.SpeedStartGlyph.Text = $(if ($Running) { [string][char]0xE71A } else { [string][char]0xE768 })
}

function Start-SpeedTest {
    if (Test-WorkerRunning "speed") { Stop-Worker "speed"; Set-SpeedButton $false; $Ui.SpeedStatus.Text = "остановлен"; return }
    $Url = $Ui.SpeedUrl.Text.Trim()
    if (-not $Url) { $Url = "https://speed.cloudflare.com/__down?bytes=25000000" }
    $Ui.SpeedDown.Text = "…"; $Ui.SpeedUp.Text = "…"; $Ui.SpeedLat.Text = "…"
    $Ui.SpeedProgress.Value = 0; $Ui.SpeedStatus.Text = "задержка…"; $script:SpeedErr = ""
    Set-SpeedButton $true
    [void](Start-Worker -Name "speed" -Replace -Body $script:SpeedBody -ArgList @($Url) -OnMessage {
        param($M)
        if ($M.Type -ne "speed") { return }
        switch ($M.Phase) {
            "lat"  { $Ui.SpeedLat.Text = $(if ($M.Lat -ge 0) { "$($M.Lat)" } else { "—" }); $Ui.SpeedStatus.Text = "загрузка…" }
            "down" { $Ui.SpeedDown.Text = "$($M.Mbps)"; $Ui.SpeedProgress.Value = $M.Pct / 2 }
            "up"   { $Ui.SpeedUp.Text = "$($M.Mbps)"; $Ui.SpeedStatus.Text = "отдача…"; $Ui.SpeedProgress.Value = 50 + $M.Pct / 2 }
            "err"  { $Ui.SpeedStatus.Text = $M.Text; $script:SpeedErr = $M.Text; Show-Toast $M.Text "fail" }
            "done" {
                $Ui.SpeedDown.Text = $(if ($M.Down) { "$($M.Down)" } else { "—" })
                $Ui.SpeedUp.Text = $(if ($M.Up) { "$($M.Up)" } elseif ($M.UpSkipped) { "н/д" } else { "—" })
                $Ui.SpeedLat.Text = $(if ($M.Lat -ge 0) { "$($M.Lat)" } else { "—" })
                $Ui.SpeedProgress.Value = 100
                $Ui.SpeedStatus.Text = $(if ($script:SpeedErr) { $script:SpeedErr } else { "готово · $(Get-Date -Format 'HH:mm')" + $(if ($M.UpSkipped) { " · отдача только через Cloudflare" } else { "" }) })
                Show-Toast "Скорость: ↓ $($M.Down) ↑ $(if ($M.Up) { $M.Up } else { '—' }) Мбит/с · $($M.Lat) мс"
            }
        }
    } -OnDone { Set-SpeedButton $false })
}

# ---------------------------------------------------------------- wiring

function Get-MonInterval {
    if ($Ui.MiFast.IsChecked) { return 2000 }
    if ($Ui.MiSlow.IsChecked) { return 30000 }
    return 5000
}

function Initialize-MonitorPage {
    $Ui.MonList.ItemsSource = $script:MonItems
    $Ui.MonAdd.Add_Click({ Add-MonTarget (Repair-TargetText $Ui.MonTarget); $Ui.MonTarget.Text = "" })
    $Ui.MonTarget.Add_KeyDown({ param($S, $E) if ($E.Key -eq "Return") { Add-MonTarget (Repair-TargetText $Ui.MonTarget); $Ui.MonTarget.Text = ""; $E.Handled = $true } })
    foreach ($R in @($Ui.MiFast, $Ui.MiNorm, $Ui.MiSlow)) { $R.Add_Checked({ $script:MonIntervalMs = Get-MonInterval; Start-Monitor; Update-PageSub }) }
    $Ui.SpeedStart.Add_Click({ Start-SpeedTest })
    $Ui.SpeedUrl.Add_KeyDown({ param($S, $E) if ($E.Key -eq "Return") { Start-SpeedTest; $E.Handled = $true } })
    $Ui.WifiPill.Add_MouseLeftButtonUp({ Set-Page "monitor" })
    $Ui.MonList.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Пинг (подробно)" 0xE9D9 { $R = $Ui.MonList.SelectedItem; if ($R) { Start-PingFor $R.Mon.Target } })
        (New-MenuItem "Трассировка" 0xE81E { $R = $Ui.MonList.SelectedItem; if ($R) { Start-PingFor $R.Mon.Target -Trace } })
        (New-MenuItem "Копировать адрес" 0xE8C8 { $R = $Ui.MonList.SelectedItem; if ($R) { Copy-Text $R.Mon.Target $R.Mon.Target } })
        (New-MenuItem "Сбросить статистику" 0xE72C { $R = $Ui.MonList.SelectedItem; if ($R) { $script:MonState.Remove($R.Id); Update-MonRow $R.Id } })
        "-"
        (New-MenuItem "Убрать из монитора" 0xE74D { $R = $Ui.MonList.SelectedItem; if ($R) { Remove-MonTarget $R.Id } } "Del" "Fail")
    )
    Refresh-Monitor
    Start-Monitor
}
