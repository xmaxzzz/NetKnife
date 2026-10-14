# Pages: ping + traceroute, DNS compare; header network status.

$script:PingItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:TraceItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:DnsItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:PingSamples = [System.Collections.Generic.List[object]]::new()
$script:PingStats = @{ Sent = 0; Ok = 0; Min = $null; Max = $null; Sum = 0; Target = ""; Ip = "" }

# ---------------------------------------------------------------- ping

$script:PingBody = {
    param($Q, $Ctl, $Target, $IntervalMs)

    $Ip = $Target
    if ($Target -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        try {
            $Ip = ([System.Net.Dns]::GetHostAddresses($Target) | Where-Object { $_.AddressFamily -eq "InterNetwork" } | Select-Object -First 1).ToString()
        } catch { $Q.Enqueue(@{ Type = "error"; Text = "$Target не резолвится" }); return }
    }
    $Q.Enqueue(@{ Type = "resolved"; Ip = $Ip })

    $P = New-Object System.Net.NetworkInformation.Ping
    $Buf = [byte[]](1..32)
    $Seq = 0
    while (-not $Ctl.Stop) {
        $Seq++
        $Sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $R = $P.Send($Ip, 2000, $Buf)
            $Q.Enqueue(@{ Type = "reply"; Seq = $Seq; Ok = ($R.Status -eq "Success"); Rtt = [int]$R.RoundtripTime; Ttl = $(if ($R.Options) { $R.Options.Ttl } else { 0 }); Status = "$($R.Status)"; From = "$($R.Address)" })
        } catch {
            $Q.Enqueue(@{ Type = "reply"; Seq = $Seq; Ok = $false; Rtt = 0; Ttl = 0; Status = $_.Exception.InnerException.Message; From = "" })
        }
        $Wait = $IntervalMs - $Sw.ElapsedMilliseconds
        while ($Wait -gt 0 -and -not $Ctl.Stop) { Start-Sleep -Milliseconds ([Math]::Min(100, $Wait)); $Wait -= 100 }
    }
}

$script:TraceBody = {
    param($Q, $Ctl, $Target)

    $Ip = $Target
    if ($Target -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        try { $Ip = ([System.Net.Dns]::GetHostAddresses($Target) | Where-Object { $_.AddressFamily -eq "InterNetwork" } | Select-Object -First 1).ToString() }
        catch { $Q.Enqueue(@{ Type = "error"; Text = "$Target не резолвится" }); return }
    }
    $Q.Enqueue(@{ Type = "hop"; Text = "→ $Target [$Ip], до 30 прыжков"; Kind = "info" })
    $P = New-Object System.Net.NetworkInformation.Ping
    $Buf = [byte[]](1..32)

    $Miss = 0
    for ($Ttl = 1; $Ttl -le 30 -and -not $Ctl.Stop; $Ttl++) {
        $Opt = New-Object System.Net.NetworkInformation.PingOptions $Ttl, $true
        $Times = @(); $Addr = $null; $Reached = $false
        for ($Try = 0; $Try -lt 2; $Try++) {
            $Sw = [System.Diagnostics.Stopwatch]::StartNew()
            try { $R = $P.Send($Ip, 1500, $Buf, $Opt) } catch { $R = $null }
            $Sw.Stop()
            if ($R -and ($R.Status -eq "TtlExpired" -or $R.Status -eq "Success")) {
                $Addr = "$($R.Address)"
                $Times += [int]$Sw.ElapsedMilliseconds
                if ($R.Status -eq "Success") { $Reached = $true }
            }
        }
        if ($Addr) {
            $Name = ""
            try { $T = [System.Net.Dns]::GetHostEntryAsync($Addr); if ($T.Wait(800)) { $Name = $T.Result.HostName } } catch { }
            $Ms = ($Times | ForEach-Object { "$_ мс" }) -join "  "
            $Label = if ($Name -and $Name -ne $Addr) { "$Addr  $Name" } else { $Addr }
            $Miss = 0
            $Q.Enqueue(@{ Type = "hop"; Text = ("{0,2}  {1,-14} {2}" -f $Ttl, $Ms, $Label); Kind = "ok" })
        } else {
            $Miss++
            $Q.Enqueue(@{ Type = "hop"; Text = ("{0,2}  *              нет ответа" -f $Ttl); Kind = "warn" })
            if ($Miss -ge 6) { $Q.Enqueue(@{ Type = "hop"; Text = "6 хопов подряд молчат — дальше ICMP, видимо, режется"; Kind = "info" }); break }
        }
        if ($Reached) { $Q.Enqueue(@{ Type = "hop"; Text = "цель достигнута за $Ttl"; Kind = "info" }); break }
    }
}

function Get-PingSub {
    $S = $script:PingStats
    if (-not $S.Target) { return "Непрерывный ping с графиком задержек и трассировка маршрута" }
    $Txt = "$($S.Target)"
    if ($S.Ip -and $S.Ip -ne $S.Target) { $Txt += " [$($S.Ip)]" }
    $Txt += " · отправлено $($S.Sent)"
    if (Test-WorkerRunning "ping") { $Txt += " · идёт" }
    return $Txt
}

function Update-PingStats {
    $S = $script:PingStats
    $Last = $script:PingSamples | Select-Object -Last 1
    $Ui.PsLast.Text = $(if ($Last) { if ($Last.Ok) { "$($Last.Rtt) мс" } else { "×" } } else { "—" })
    $Ui.PsMin.Text = $(if ($null -ne $S.Min) { "$($S.Min) мс" } else { "—" })
    $Ui.PsMax.Text = $(if ($null -ne $S.Max) { "$($S.Max) мс" } else { "—" })
    $Ui.PsAvg.Text = $(if ($S.Ok) { "{0:N0} мс" -f ($S.Sum / $S.Ok) } else { "—" })
    $Loss = if ($S.Sent) { 100.0 * ($S.Sent - $S.Ok) / $S.Sent } else { 0 }
    $Ui.PsLoss.Text = $(if ($S.Sent) { "{0:N0}%" -f $Loss } else { "—" })
    $Ui.PsLoss.Foreground = $(if ($Loss -ge 20) { Get-Brush "Fail" } elseif ($Loss -gt 0) { Get-Brush "Warn" } else { Get-Brush "Text" })
    $Ui.PsLast.Foreground = $(if ($Last -and -not $Last.Ok) { Get-Brush "Fail" } else { Get-Brush "Text" })
}

function Update-PingChart {
    $C = $Ui.PingChart
    $C.Children.Clear()
    $W = $C.ActualWidth; $H = $C.ActualHeight
    if ($W -lt 20 -or $H -lt 20 -or $script:PingSamples.Count -eq 0) { return }
    $Ui.ChartHint.Visibility = "Collapsed"

    $N = 120
    $Data = @($script:PingSamples | Select-Object -Last $N)
    $Max = ($Data | Where-Object { $_.Ok } | Measure-Object -Property Rtt -Maximum).Maximum
    if (-not $Max -or $Max -lt 10) { $Max = 10 }
    $Max = [Math]::Ceiling($Max * 1.15)
    $Ui.ChartMax.Text = "$Max мс"
    $Step = $W / ($N - 1)
    $X0 = $W - ($Data.Count - 1) * $Step

    foreach ($Frac in @(0.25, 0.5, 0.75)) {
        $L = New-Object System.Windows.Shapes.Line
        $L.X1 = 0; $L.X2 = $W; $L.Y1 = $H * $Frac; $L.Y2 = $H * $Frac
        $L.Stroke = Get-Brush "Line"; $L.StrokeThickness = 1; $L.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse("3 4")
        [void]$C.Children.Add($L)
    }

    $Pts = New-Object System.Windows.Media.PointCollection
    $Fill = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt $Data.Count; $i++) {
        $X = $X0 + $i * $Step
        $D = $Data[$i]
        if ($D.Ok) {
            $Y = $H - ($D.Rtt / $Max) * $H
            $Pts.Add((New-Object System.Windows.Point $X, $Y))
        } else {
            $E = New-Object System.Windows.Shapes.Rectangle
            $E.Width = [Math]::Max(2, $Step - 1); $E.Height = $H; $E.Fill = Get-Brush "FailSoft"
            [System.Windows.Controls.Canvas]::SetLeft($E, $X - $E.Width / 2)
            [void]$C.Children.Add($E)
        }
    }
    if ($Pts.Count -ge 1) {
        $Fill.Add((New-Object System.Windows.Point $Pts[0].X, $H))
        foreach ($P in $Pts) { $Fill.Add($P) }
        $Fill.Add((New-Object System.Windows.Point $Pts[$Pts.Count - 1].X, $H))
        $Poly = New-Object System.Windows.Shapes.Polygon
        $Poly.Points = $Fill
        $Poly.Fill = Get-Brush "AccentSoft"
        [void]$C.Children.Add($Poly)
        $Line = New-Object System.Windows.Shapes.Polyline
        $Line.Points = $Pts
        $Line.Stroke = Get-Brush "Accent"; $Line.StrokeThickness = 2
        $Line.StrokeLineJoin = "Round"
        [void]$C.Children.Add($Line)
        $Last = $Pts[$Pts.Count - 1]
        $Dot = New-Object System.Windows.Shapes.Ellipse
        $Dot.Width = 8; $Dot.Height = 8; $Dot.Fill = Get-Brush "Accent"
        [System.Windows.Controls.Canvas]::SetLeft($Dot, $Last.X - 4); [System.Windows.Controls.Canvas]::SetTop($Dot, $Last.Y - 4)
        [void]$C.Children.Add($Dot)
    }
}

function Get-PingInterval {
    if ($Ui.PiFast.IsChecked) { return 200 }
    if ($Ui.PiSlow.IsChecked) { return 5000 }
    return 1000
}

function Set-PingButton {
    param([bool]$Running)
    $Ui.PingStartText.Text = $(if ($Running) { "Стоп" } else { "Пинг" })
    $Ui.PingStartGlyph.Text = $(if ($Running) { [string][char]0xE71A } else { [string][char]0xE768 })
}

function Start-Ping {
    $Target = Repair-TargetText $Ui.PingTarget
    if (-not $Target) { Show-Toast "Укажи адрес" "warn"; [void]$Ui.PingTarget.Focus(); return }
    Add-History "PingHistory" $Target
    $script:PingSamples.Clear()
    $script:PingItems.Clear()
    $script:PingStats = @{ Sent = 0; Ok = 0; Min = $null; Max = $null; Sum = 0; Target = $Target; Ip = "" }
    $Ui.ChartHint.Visibility = "Visible"
    $Ui.ChartHint.Text = "Жду ответы…"
    Update-PingStats
    Set-PingButton $true

    [void](Start-Worker -Name "ping" -Replace -Body $script:PingBody -ArgList @($Target, (Get-PingInterval)) -OnMessage {
        param($M)
        $S = $script:PingStats
        if ($M.Type -eq "resolved") { $S.Ip = $M.Ip; Update-PageSub; return }
        if ($M.Type -ne "reply") { return }
        $S.Sent++
        if ($M.Ok) {
            $S.Ok++; $S.Sum += $M.Rtt
            if ($null -eq $S.Min -or $M.Rtt -lt $S.Min) { $S.Min = $M.Rtt }
            if ($null -eq $S.Max -or $M.Rtt -gt $S.Max) { $S.Max = $M.Rtt }
        }
        $script:PingSamples.Add([pscustomobject]@{ Ok = $M.Ok; Rtt = $M.Rtt })
        if ($script:PingSamples.Count -gt 600) { $script:PingSamples.RemoveAt(0) }

        $Time = (Get-Date).ToString("HH:mm:ss")
        $Text = if ($M.Ok) { "{0}  #{1,-4} {2,5} мс   ttl={3}   {4}" -f $Time, $M.Seq, $M.Rtt, $M.Ttl, $M.From } else { "{0}  #{1,-4} {2}" -f $Time, $M.Seq, $(switch ($M.Status) { "TimedOut" { "таймаут" } "DestinationHostUnreachable" { "хост недоступен" } "DestinationNetworkUnreachable" { "сеть недоступна" } default { $M.Status } }) }
        $script:PingItems.Insert(0, [pscustomobject]@{ Text = $Text; Kind = $(if ($M.Ok) { "ok" } else { "fail" }) })
        if ($script:PingItems.Count -gt 400) { $script:PingItems.RemoveAt($script:PingItems.Count - 1) }

        Update-PingStats
        Update-PingChart
        Update-PageSub
    } -OnDone { Set-PingButton $false; Update-PageSub })
}

function Start-Trace {
    $Target = Repair-TargetText $Ui.PingTarget
    if (-not $Target) { Show-Toast "Укажи адрес" "warn"; return }
    $script:TraceItems.Clear()
    [void](Start-Worker -Name "trace" -Replace -Body $script:TraceBody -ArgList @($Target) -OnMessage {
        param($M)
        if ($M.Type -eq "hop") { $script:TraceItems.Add([pscustomobject]@{ Text = $M.Text; Kind = $M.Kind }) }
    } -OnDone { })
}

function Start-PingFor {
    param([string]$Target, [switch]$Trace)
    $Ui.PingTarget.Text = $Target
    Set-Page "ping"
    if ($Trace) { Start-Trace } else { Start-Ping }
}

# ---------------------------------------------------------------- DNS

$script:DnsBody = {
    param($Q, $Ctl, $Name, $Type, $Server, $Label)

    $Sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $P = @{ Name = $Name; Type = $Type; DnsOnly = $true; ErrorAction = "Stop" }
        if ($Server) { $P.Server = $Server; $P.QuickTimeout = $true }
        $R = Resolve-DnsName @P
        $Sw.Stop()
        $Ans = @($R | Where-Object { $_.Section -eq "Answer" })
        $Lines = foreach ($X in $Ans) {
            switch ("$($X.Type)") {
                "A"     { "A      $($X.IPAddress)" }
                "AAAA"  { "AAAA   $($X.IPAddress)" }
                "CNAME" { "CNAME  $($X.NameHost)" }
                "MX"    { "MX     $($X.Preference) $($X.NameExchange)" }
                "TXT"   { "TXT    $($X.Strings -join '')" }
                "NS"    { "NS     $($X.NameHost)" }
                "PTR"   { "PTR    $($X.NameHost)" }
                "SOA"   { "SOA    $($X.PrimaryServer) $($X.NameAdministrator) serial $($X.SerialNumber)" }
                default { "$($X.Type)  $($X.Name)" }
            }
        }
        $Lines = @($Lines | Sort-Object)
        if (-not $Lines) {
            $Soa = $R | Where-Object { $_.Type -eq "SOA" } | Select-Object -First 1
            $Lines = @("нет записей $Type" + $(if ($Soa) { " (зона $($Soa.Name))" } else { "" }))
        }
        $Fake = @($Ans | Where-Object { $_.IPAddress -and (Test-FakeIp "$($_.IPAddress)") }).Count -gt 0
        $Kind = if ($Fake) { "warn" } else { "ok" }
        $Meta = "$($Sw.ElapsedMilliseconds) мс" + $(if ($Fake) { " · fake-ip (прокси)" } else { "" }) + $(if ($Server) { " · $Server" } else { "" })
        $Q.Enqueue(@{ Type = "dns"; Label = $Label; Answer = ($Lines -join "`n"); Kind = $Kind; Meta = $Meta })
    } catch {
        $Sw.Stop()
        $Msg = $_.Exception.Message -replace '\s+', ' '
        $Q.Enqueue(@{ Type = "dns"; Label = $Label; Answer = $Msg; Kind = "fail"; Meta = "$($Sw.ElapsedMilliseconds) мс$(if ($Server) { " · $Server" })" })
    }
}

function Get-DnsServers {
    $List = @([pscustomobject]@{ Label = "Системный резолвер"; Server = "" })
    try {
        $Route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
        $Srv = (Get-DnsClientServerAddress -InterfaceIndex $Route.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses
        foreach ($S in $Srv) { $List += [pscustomobject]@{ Label = "DNS сети ($($Route.InterfaceAlias -replace '^vEthernet \((.+)\)$', '$1'))"; Server = $S } }
    } catch { }
    $List += [pscustomobject]@{ Label = "Cloudflare"; Server = "1.1.1.1" }
    $List += [pscustomobject]@{ Label = "Google"; Server = "8.8.8.8" }
    $List += [pscustomobject]@{ Label = "Яндекс"; Server = "77.88.8.8" }
    $List += [pscustomobject]@{ Label = "Quad9"; Server = "9.9.9.9" }
    $Extra = $Ui.DnsExtra.Text.Trim()
    if ($Extra) { $List += [pscustomobject]@{ Label = "Свой"; Server = $Extra } }
    return $List
}

function Start-DnsQuery {
    $Name = Repair-TargetText $Ui.DnsName
    if (-not $Name) { Show-Toast "Укажи имя" "warn"; [void]$Ui.DnsName.Focus(); return }
    $Type = ($Ui.DnsTypes.Children | Where-Object { $_.IsChecked } | Select-Object -First 1).Content
    if ($Name -match '^\d{1,3}(\.\d{1,3}){3}$' -and $Type -eq "A") { $Type = "PTR"; foreach ($R in $Ui.DnsTypes.Children) { if ($R.Content -eq "PTR") { $R.IsChecked = $true } } }
    Add-History "DnsHistory" $Name
    $script:DnsItems.Clear()
    $script:DnsQuery = "$Name · $Type"
    foreach ($S in Get-DnsServers) {
        $Id = $script:DnsItems.Count
        $script:DnsItems.Add([pscustomobject]@{ Server = $S.Label; Meta = $(if ($S.Server) { $S.Server } else { "как у Windows" }); Answer = "…"; Kind = "wait" })
        [void](Start-Worker -Name "dns-$Id" -Replace -Body $script:DnsBody -ArgList @($Name, $Type, $S.Server, "$Id") -OnMessage {
            param($M)
            if ($M.Type -ne "dns") { return }
            $i = [int]$M.Label
            if ($i -ge $script:DnsItems.Count) { return }
            $Old = $script:DnsItems[$i]
            $script:DnsItems[$i] = [pscustomobject]@{ Server = $Old.Server; Meta = $M.Meta; Answer = $M.Answer; Kind = $M.Kind }
            Update-PageSub
        })
    }
    Update-PageSub
}

function Get-DnsSub {
    if (-not $script:DnsQuery) { return "Сравнение ответов разных DNS-серверов" }
    $Done = @($script:DnsItems | Where-Object { $_.Kind -ne "wait" })
    $Distinct = @($Done | Where-Object { $_.Kind -ne "fail" } | ForEach-Object { $_.Answer } | Sort-Object -Unique).Count
    $S = "$($script:DnsQuery) · ответили $(@($Done | Where-Object { $_.Kind -ne 'fail' }).Count) из $($script:DnsItems.Count)"
    if ($Distinct -gt 1) { $S += " · ответы РАЗНЫЕ" }
    return $S
}

function Set-LoadPill {
    param($Pill, $Text, $Glyph, [int]$Pct, [int]$WarnAt, [int]$FailAt)
    # always tinted: green → yellow → red
    $Lvl = if ($Pct -ge $FailAt) { "Fail" } elseif ($Pct -ge $WarnAt) { "Warn" } else { "Ok" }
    $Pill.Background = Get-Brush "${Lvl}Soft"; $Pill.BorderBrush = $Pill.Background
    $Text.Foreground = Get-Brush $Lvl; $Glyph.Foreground = Get-Brush $Lvl
}

function Update-SystemLoad {
    $L = Get-SystemLoad
    if ($null -ne $L.Cpu) {
        $Ui.CpuText.Text = "CPU $($L.Cpu)%"
        Set-LoadPill $Ui.CpuPill $Ui.CpuText $Ui.CpuGlyph $L.Cpu 60 85
    }
    if ($null -ne $L.RamPct) {
        $Ui.RamText.Text = "RAM $($L.RamPct)%"
        Set-LoadPill $Ui.RamPill $Ui.RamText $Ui.RamGlyph $L.RamPct 75 90
        $Ui.RamPill.ToolTip = "Память: $($L.RamUsedGb) из $($L.RamTotalGb) ГБ ($($L.RamPct)%)"
    }
}

# ---------------------------------------------------------------- header status

$script:StatusBody = {
    param($Q, $Ctl)

    $R = @{ Type = "status" }

    # local network
    try {
        $Nets = Get-LocalNets
        $Route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
        $Main = $Nets | Where-Object { $_.IfIndex -eq $Route.ifIndex } | Select-Object -First 1
        $R.LanAlias = ($Route.InterfaceAlias -replace '^vEthernet \((.+)\)$', '$1')
        $R.LanIp = $(if ($Main) { "$($Main.Ip)/$($Main.Prefix)" } else { "" })
        $R.Gateway = $Route.NextHop
        $R.DefaultTunnel = [bool]($Main -and $Main.Tunnel)
        $R.Tunnels = @($Nets | Where-Object { $_.Tunnel } | ForEach-Object { ($_.Alias -replace '\s*\[[0-9a-f]+\]$', '') } | Sort-Object -Unique)
    } catch { }

    # DNS
    $Sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $D = Resolve-DnsName "ya.ru" -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq "A" } | Select-Object -First 1
        $R.DnsMs = $Sw.ElapsedMilliseconds
        $R.DnsIp = "$($D.IPAddress)"
        $R.DnsFake = Test-FakeIp $R.DnsIp
        $R.DnsOk = $true
    } catch {
        $R.DnsOk = $false
        $R.DnsErr = $_.Exception.Message
    }
    try {
        $Sw.Restart()
        $D2 = Resolve-DnsName "google.com" -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq "A" } | Select-Object -First 1
        $R.Dns2Ms = $Sw.ElapsedMilliseconds
        $R.Dns2Ip = "$($D2.IPAddress)"
    } catch { $R.Dns2Err = $_.Exception.Message }

    $R.Wlan = Get-WlanInfo

    # external IP: several sources, they may differ through split-routing proxies
    $R.Ext = @{}
    foreach ($Src in @(@("icanhazip", "https://icanhazip.com"), @("ipify", "https://api.ipify.org"))) {
        try {
            $V = (Invoke-RestMethod -Uri $Src[1] -TimeoutSec 6 -ErrorAction Stop).ToString().Trim()
            if ($V -match '^\d{1,3}(\.\d{1,3}){3}$') { $R.Ext[$Src[0]] = $V }
        } catch { }
    }
    $Primary = if ($R.Ext.icanhazip) { $R.Ext.icanhazip } else { $R.Ext.ipify }
    if ($Primary) {
        try {
            $Info = Invoke-RestMethod -Uri "https://ipinfo.io/$Primary/json" -TimeoutSec 6 -ErrorAction Stop
            $R.Country = $Info.country; $R.City = $Info.city; $R.Org = $Info.org
        } catch { }
    }
    $Q.Enqueue($R)
}

function Start-NetStatus {
    $Ui.IpText.Text = "внешний IP …"
    [void](Start-Worker -Name "status" -Replace -Body $script:StatusBody -OnMessage {
        param($M)
        if ($M.Type -ne "status") { return }
        $script:NetStatus = $M

        # external IP
        $A = $M.Ext.icanhazip; $B = $M.Ext.ipify
        $Ip = if ($A) { $A } else { $B }
        if ($Ip) {
            $Txt = $Ip
            if ($M.Country) { $Txt += " $($M.Country)" }
            if ($A -and $B -and $A -ne $B) {
                $Txt += "  ≠ $B"
                $Ui.IpPill.BorderBrush = Get-Brush "Warn"
            } else { $Ui.IpPill.BorderBrush = Get-Brush "Line" }
            $Ui.IpText.Text = $Txt
            $Tip = "Внешний IP (клик — копировать)`nicanhazip: $A`nipify: $B"
            if ($A -and $B -and $A -ne $B) { $Tip += "`n`nСервисы видят разные адреса: часть трафика идёт через прокси/VPN (раздельная маршрутизация)." }
            if ($M.Org) { $Tip += "`n`n$($M.Org)`n$($M.City) $($M.Country)" }
            $Ui.IpPill.ToolTip = $Tip
        } else {
            $Ui.IpText.Text = "нет интернета"
            $Ui.IpPill.BorderBrush = Get-Brush "Fail"
            $Ui.IpPill.ToolTip = "Ни icanhazip, ни ipify не ответили"
        }

        # DNS
        if ($M.DnsOk -and $M.DnsFake) {
            $Ui.DnsDot.Fill = Get-Brush "Warn"; $Ui.DnsText.Text = "DNS fake-ip"
            $Ui.DnsPill.ToolTip = "ya.ru → $($M.DnsIp): DNS отдаёт фиктивные адреса 198.18.x (прокси/туннель перехватывает DNS)"
        } elseif ($M.DnsOk) {
            $Ui.DnsDot.Fill = Get-Brush "Ok"; $Ui.DnsText.Text = "DNS $($M.DnsMs) мс"
            $Ui.DnsPill.ToolTip = "ya.ru → $($M.DnsIp) за $($M.DnsMs) мс`ngoogle.com → $(if ($M.Dns2Ip) { "$($M.Dns2Ip) за $($M.Dns2Ms) мс" } else { "ошибка: $($M.Dns2Err)" })"
        } else {
            $Ui.DnsDot.Fill = Get-Brush "Fail"; $Ui.DnsText.Text = "DNS не работает"
            $Ui.DnsPill.ToolTip = "Системный DNS не ответил: $($M.DnsErr)"
        }

        Update-WlanCard $M.Wlan

        # LAN / VPN
        if ($M.LanAlias) {
            $Ui.LanText.Text = "$($M.LanIp) → $($M.Gateway)"
            $Ui.LanPill.ToolTip = "$($M.LanAlias)`nIP $($M.LanIp)`nшлюз $($M.Gateway)"
        }
        if ($M.Tunnels.Count -or $M.DefaultTunnel) {
            $Ui.VpnPill.Visibility = "Visible"
            $Ui.VpnText.Text = ($M.Tunnels -join ", ")
            $Ui.VpnPill.ToolTip = "Активные туннели/VPN-адаптеры" + $(if ($M.DefaultTunnel) { "`nВЕСЬ трафик идёт через туннель (default route)" } else { "`ndefault route — не через туннель" })
            $Ui.VpnPill.BorderBrush = $(if ($M.DefaultTunnel) { Get-Brush "Warn" } else { Get-Brush "Line" })
        } else {
            $Ui.VpnPill.Visibility = "Collapsed"
        }
    })
}

function Initialize-ToolsPages {
    $Ui.PingLog.ItemsSource = $script:PingItems
    $Ui.TraceLog.ItemsSource = $script:TraceItems
    $Ui.DnsList.ItemsSource = $script:DnsItems

    $Ui.PingStart.Add_Click({ if (Test-WorkerRunning "ping") { Stop-Worker "ping"; Set-PingButton $false; Update-PageSub } else { Start-Ping } })
    $Ui.TraceStart.Add_Click({ Start-Trace })
    $Ui.PingTarget.Add_KeyDown({ param($S, $E) if ($E.Key -eq "Return") { Start-Ping; $E.Handled = $true } })
    $Ui.PingChart.Add_SizeChanged({ Update-PingChart })
    foreach ($R in @($Ui.PiFast, $Ui.PiNorm, $Ui.PiSlow)) { $R.Add_Checked({ if (Test-WorkerRunning "ping") { Start-Ping } }) }

    $Ui.DnsStart.Add_Click({ Start-DnsQuery })
    $Ui.DnsName.Add_KeyDown({ param($S, $E) if ($E.Key -eq "Return") { Start-DnsQuery; $E.Handled = $true } })
    $Ui.DnsList.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Копировать ответ" 0xE8C8 { $R = $Ui.DnsList.SelectedItem; if ($R) { Copy-Text $R.Answer "ответ DNS" } })
        (New-MenuItem "Копировать всё" 0xE8C8 { Copy-Text (($script:DnsItems | ForEach-Object { "[$($_.Server) · $($_.Meta)]`n$($_.Answer)" }) -join "`n`n") "все ответы" })
    )

    $Ui.QuickPing.Add_KeyDown({
        param($S, $E)
        if ($E.Key -eq "Return" -and $Ui.QuickPing.Text.Trim()) {
            Start-PingFor (Repair-TargetText $Ui.QuickPing)
            $Ui.QuickPing.Text = ""
            $E.Handled = $true
        }
    })
    $Ui.NetRefreshBtn.Add_Click({ Start-NetStatus })
    $Ui.IpPill.Add_MouseLeftButtonUp({
        $St = $script:NetStatus
        if ($St) { $Ip = if ($St.Ext.icanhazip) { $St.Ext.icanhazip } else { $St.Ext.ipify }; Copy-Text $Ip "внешний IP $Ip" }
    })
}
