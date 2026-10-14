# Page: network scanner (ping sweep + quick TCP ports + ARP + reverse DNS), CSV export, subnet calculator.

$script:ScanItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:ScanRows = @{}
$script:ScanInfo = @{ Total = 0; Done = 0; Started = $null; Range = ""; Ports = @() }

$script:ScanBody = {
    param($Q, $Ctl, $Ips, $Ports, $LocalNets, $DoNames, $UseBind)

    $Nets = if ($UseBind) { $LocalNets } else { @() }
    $Total = $Ips.Count
    $Done = 0
    $Alive = [System.Collections.Generic.List[string]]::new()
    $Batch = 96

    for ($i = 0; $i -lt $Total; $i += $Batch) {
        if ($Ctl.Stop) { break }
        $Chunk = $Ips[$i..([Math]::Min($i + $Batch, $Total) - 1)]

        $Targets = foreach ($Ip in $Chunk) { foreach ($P in $Ports) { [pscustomobject]@{ Ip = $Ip; Port = $P } } }
        $Rtt = Invoke-PingBatch $Chunk 900
        $Open = @()
        if ($Targets) { $Open = Test-TcpBatch @($Targets) 900 $Nets }

        $ByIp = @{}
        foreach ($O in $Open) { if (-not $ByIp[$O.Ip]) { $ByIp[$O.Ip] = @() }; $ByIp[$O.Ip] += [int]$O.Port }

        foreach ($Ip in $Chunk) {
            $Has = $Rtt.ContainsKey($Ip)
            if ($Has -or $ByIp.ContainsKey($Ip)) {
                $Alive.Add($Ip)
                $Q.Enqueue(@{ Type = "host"; Ip = $Ip; Rtt = $(if ($Has) { $Rtt[$Ip] } else { -1 }); Ports = [int[]]@($ByIp[$Ip]) })
            }
        }
        $Done += $Chunk.Count
        $Q.Enqueue(@{ Type = "progress"; Done = $Done; Total = $Total })
    }

    # MAC addresses from ARP cache (filled by the sweep)
    try {
        $Arp = @{}
        Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress -ne "00-00-00-00-00-00" -and $_.State -ne "Unreachable" } |
            ForEach-Object { $Arp[$_.IPAddress] = $_.LinkLayerAddress }
        foreach ($Ip in $Alive) { if ($Arp.ContainsKey($Ip)) { $Q.Enqueue(@{ Type = "mac"; Ip = $Ip; Mac = $Arp[$Ip] }) } }
        foreach ($N in $LocalNets) { if ($Alive.Contains($N.Ip)) { $Q.Enqueue(@{ Type = "self"; Ip = $N.Ip; Alias = $N.Alias }) } }
    } catch { }

    if ($DoNames -and -not $Ctl.Stop) {
        for ($i = 0; $i -lt $Alive.Count; $i += 32) {
            if ($Ctl.Stop) { break }
            $Chunk = $Alive[$i..([Math]::Min($i + 32, $Alive.Count) - 1)]
            $Tasks = foreach ($Ip in $Chunk) {
                $T = $null
                try { $T = [System.Net.Dns]::GetHostEntryAsync($Ip) } catch { }
                [pscustomobject]@{ Ip = $Ip; T = $T }
            }
            $Valid = [System.Threading.Tasks.Task[]]@($Tasks | Where-Object { $_.T } | ForEach-Object { $_.T })
            if ($Valid.Count) { try { [void][System.Threading.Tasks.Task]::WhenAll($Valid).Wait(2500) } catch { } }
            foreach ($X in $Tasks) {
                if ($X.T -and $X.T.Status -eq "RanToCompletion" -and $X.T.Result.HostName -and $X.T.Result.HostName -ne $X.Ip) {
                    $Q.Enqueue(@{ Type = "name"; Ip = $X.Ip; Name = $X.T.Result.HostName })
                }
            }
        }
    }
}

function New-ScanRow {
    param([hashtable]$D)

    $Ports = [int[]]@($D.Ports)
    $Alias = $script:IpToAlias[$D.Ip]
    if (-not $Alias) { $Alias = ($script:Hosts | Where-Object { $_.HostName -eq $D.Ip } | Select-Object -First 1).Alias }

    $Badges = @(New-PortBadges -Ip $D.Ip -Ports $Ports -SshAlias $Alias)
    $Probed = @($script:ScanInfo.Ports).Count
    if ($Probed -ge 4 -and $Ports.Count -eq $Probed) {
        $Badges = @([pscustomobject]@{ Text = "всё открыто — прокси?"; Kind = "warn"; Tag = "ports:$($D.Ip)"; Tip = "Все проверяемые порты «открыты»: так бывает, когда TCP перехватывает туннель/прокси. Проверь сканом портов с баннерами." }) + $Badges
    }
    if ($Alias) { $Badges = @([pscustomobject]@{ Text = "ssh: $Alias"; Kind = "ssh"; Tag = "host:$Alias"; Tip = "Есть в ~/.ssh/config" }) + $Badges }
    if ($D.Self) { $Badges = @([pscustomobject]@{ Text = "этот ПК"; Kind = ""; Tag = "copy:$($D.Ip)"; Tip = $D.Self }) + $Badges }

    $Mac = "$($D.Mac)"
    return [pscustomobject]@{
        Ip = $D.Ip; IpNum = (ConvertTo-IpUInt $D.Ip)
        Name = $(if ($D.Name) { $D.Name } elseif ($Alias) { $Alias } else { "" })
        Mac = $(if ($Mac) { $Mac.Replace("-", ":") } else { "" })
        Vendor = (Get-MacVendor $Mac)
        RttText = $(if ($D.Rtt -ge 0) { "$($D.Rtt) мс" } else { "нет ICMP" })
        Pingable = ($D.Rtt -ge 0)
        Ports = $Ports
        Badges = $Badges
        Data = $D
    }
}

function Set-ScanRow {
    param([hashtable]$D)

    $Row = New-ScanRow $D
    $Existing = $script:ScanRows[$D.Ip]
    if ($Existing) {
        $Idx = $script:ScanItems.IndexOf($Existing)
        $Sel = ($Ui.ScanList.SelectedItem -eq $Existing)
        $script:ScanItems[$Idx] = $Row
        if ($Sel) { $Ui.ScanList.SelectedItem = $Row }
    } else {
        $Idx = 0
        while ($Idx -lt $script:ScanItems.Count -and $script:ScanItems[$Idx].IpNum -lt $Row.IpNum) { $Idx++ }
        $script:ScanItems.Insert($Idx, $Row)
    }
    $script:ScanRows[$D.Ip] = $Row
}

function Get-ScanSub {
    $I = $script:ScanInfo
    if (-not $I.Total) { return "Ping + быстрые TCP-порты + MAC + имена. Клик по бейджу открывает сервис." }
    $S = "найдено $($script:ScanItems.Count) из $($I.Total)"
    if ($I.Started) {
        $Sec = ([DateTime]::Now - $I.Started).TotalSeconds
        if ($I.Finished) { $Sec = ($I.Finished - $I.Started).TotalSeconds }
        $S += " · {0:N1} с" -f $Sec
    }
    if ($I.Range) { $S += " · $($I.Range)" }
    return $S
}

# Which way a non-local range is reached: the route's interface/next hop plus the first few hops (TTL pings)
$script:ScanRouteBody = {
    param($Q, $Ctl, $Ip, $LocalNets)
    $Local = $null
    foreach ($N in $LocalNets) { if ($N.Prefix -ge 8 -and (Test-IpInNet $Ip $N.Net $N.Prefix)) { $Local = $N; break } }
    if ($Local -and -not $Local.Tunnel) { $Q.Enqueue(@{ Type = "route"; Local = $true; Alias = $Local.Alias }); return }

    $Alias = ""; $Next = ""; $Tun = $false; $Desc = ""
    try {
        $Rt = Find-NetRoute -RemoteIPAddress $Ip -ErrorAction Stop | Where-Object { $_.NextHop } | Select-Object -First 1
        if ($Rt) {
            $Alias = "$($Rt.InterfaceAlias)"; $Next = "$($Rt.NextHop)"
            $A = Get-NetAdapter -InterfaceIndex $Rt.InterfaceIndex -ErrorAction SilentlyContinue
            if ($A) { $Desc = "$($A.InterfaceDescription)" }
            $Tun = Test-TunnelAdapter "$Alias $Desc"
        }
    } catch { }

    # TTL-limited pings; .NET reports 0 ms for TtlExpired replies, so time them ourselves
    $Hops = @(); $Stars = 0
    $Png = New-Object System.Net.NetworkInformation.Ping
    $Buf = [byte[]]::new(32)
    for ($Ttl = 1; $Ttl -le 8; $Ttl++) {
        if ($Ctl.Stop) { break }
        $Opt = New-Object System.Net.NetworkInformation.PingOptions $Ttl, $true
        $Rp = $null; $Ms = -1
        foreach ($Try in 1..2) {   # one retry: routers rate-limit TTL-expired replies
            $Sw = [System.Diagnostics.Stopwatch]::StartNew()
            try { $Rp = $Png.Send($Ip, 900, $Buf, $Opt) } catch { $Rp = $null; break }
            $Ms = [int]$Sw.ElapsedMilliseconds
            if ($Rp.Status -in @("TtlExpired", "Success")) { break }
        }
        if (-not $Rp) { break }
        if ($Rp.Status -eq "TtlExpired") { $Hops += @{ Ip = "$($Rp.Address)"; Ms = $Ms; Reached = $false } }
        elseif ($Rp.Status -eq "Success") { $Hops += @{ Ip = "$($Rp.Address)"; Ms = $Ms; Reached = $true }; break }
        else { $Hops += @{ Ip = "*"; Ms = -1; Reached = $false }; $Stars++; if ($Stars -ge 2) { break } }
    }
    $Q.Enqueue(@{ Type = "route"; Local = $false; Alias = $Alias; NextHop = $Next; Tunnel = $Tun; Desc = $Desc; Hops = $Hops; Target = $Ip })
}

function Start-ScanRoute {
    param([string]$Ip)
    $Ui.ScanRouteBox.Visibility = "Collapsed"
    [void](Start-Worker -Name "scan-route" -Replace -Body $script:ScanRouteBody -ArgList @($Ip, $script:LocalNets) -OnMessage {
        param($M)
        if ($M.Type -ne "route" -or $M.Local) { return }
        Show-ScanRoute $M
    })
}

# One node of the hop chain: glyph on top, address, small caption below
function New-HopNode {
    param([string]$Glyph, [string]$Title, [string]$Sub, [string]$Tone = "none", [string]$Tip = "")
    $B = New-Object System.Windows.Controls.Border
    $B.CornerRadius = New-Object System.Windows.CornerRadius 10
    $B.Padding = New-Object System.Windows.Thickness 9, 5, 9, 5
    $B.BorderThickness = New-Object System.Windows.Thickness 1
    $B.VerticalAlignment = "Center"
    $B.Background = Get-Brush $(switch ($Tone) { "accent" { "AccentSoft" } "warn" { "WarnSoft" } "fail" { "FailSoft" } default { "Chip" } })
    $B.BorderBrush = $(if ($Tone -eq "none") { Get-Brush "Line" } else { $B.Background })
    if ($Tip) { $B.ToolTip = $Tip }
    $Fg = Get-Brush $(switch ($Tone) { "accent" { "Accent" } "warn" { "Warn" } "fail" { "Fail" } default { "Sub" } })

    $Sp = New-Object System.Windows.Controls.StackPanel
    $G = New-Object System.Windows.Controls.TextBlock
    $G.Text = [string][char][int]$Glyph; $G.FontFamily = $script:Win.FindResource("IconFont"); $G.FontSize = 12; $G.Foreground = $Fg; $G.HorizontalAlignment = "Center"
    $T = New-Object System.Windows.Controls.TextBlock
    $T.Text = $Title; $T.FontFamily = $script:Win.FindResource("MonoFont"); $T.FontSize = 11.5; $T.FontWeight = "SemiBold"; $T.Foreground = Get-Brush "Text"; $T.HorizontalAlignment = "Center"; $T.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
    $S = New-Object System.Windows.Controls.TextBlock
    $S.Text = $Sub; $S.FontSize = 10; $S.Foreground = $Fg; $S.HorizontalAlignment = "Center"
    [void]$Sp.Children.Add($G); [void]$Sp.Children.Add($T); if ($Sub) { [void]$Sp.Children.Add($S) }
    $B.Child = $Sp
    return $B
}

function New-HopArrow {
    param([string]$Label = "")
    $Sp = New-Object System.Windows.Controls.StackPanel
    $Sp.VerticalAlignment = "Center"; $Sp.Margin = New-Object System.Windows.Thickness 3, 0, 3, 0
    $A = New-Object System.Windows.Controls.TextBlock
    $A.Text = [string][char]0xE72A; $A.FontFamily = $script:Win.FindResource("IconFont"); $A.FontSize = 12; $A.Foreground = Get-Brush "Faint"; $A.HorizontalAlignment = "Center"
    [void]$Sp.Children.Add($A)
    if ($Label) {
        $L = New-Object System.Windows.Controls.TextBlock
        $L.Text = $Label; $L.FontSize = 10.5; $L.Foreground = Get-Brush "Faint"; $L.HorizontalAlignment = "Center"
        [void]$Sp.Children.Add($L)
    }
    return $Sp
}

function Show-ScanRoute {
    param($M)
    $P = $Ui.ScanHops
    $P.Children.Clear()

    # this PC + the interface the route leaves through
    $IfName = $(if ($M.Alias) { $M.Alias } else { "интерфейс?" })
    [void]$P.Children.Add((New-HopNode 0xE7F8 "этот ПК" $IfName $(if ($M.Tunnel) { "warn" } else { "accent" }) $M.Desc))

    $Hops = @($M.Hops)
    $Reached = $false
    for ($i = 0; $i -lt $Hops.Count; $i++) {
        $H = $Hops[$i]
        [void]$P.Children.Add((New-HopArrow $(if ($H.Ms -ge 0) { "$($H.Ms) мс" } else { "" })))
        if ($H.Ip -eq "*") { [void]$P.Children.Add((New-HopNode 0xE9CE "нет ответа" "хоп $($i + 1)" "none")); continue }
        $Sub = "хоп $($i + 1)"
        $Tone = "none"
        if ($i -eq 0 -and $M.NextHop -and $H.Ip -eq $M.NextHop) { $Sub = "шлюз" }
        $Alias = Get-ScanHopAlias $H.Ip
        if ($Alias) { $Sub = $Alias; $Tone = "accent" }
        if ($H.Reached) { $Sub = "цель · $Sub"; $Tone = "accent"; $Reached = $true }
        [void]$P.Children.Add((New-HopNode $(if ($Alias) { 0xE977 } else { 0xE968 }) $H.Ip $Sub $Tone))
    }
    if (-not $Reached) {
        [void]$P.Children.Add((New-HopArrow))
        [void]$P.Children.Add((New-HopNode 0xE774 $M.Target "целевая сеть" "none"))
    }
    $Ui.ScanRouteCap.Text = "МАРШРУТ ДО СЕТИ" + $(if ($M.Tunnel) { " · ЧЕРЕЗ VPN/ТУННЕЛЬ ($($M.Alias))" } else { "" })
    $Ui.ScanRouteBox.Visibility = "Visible"
}

function Get-ScanHopAlias {
    param([string]$Ip)
    $H = $script:Hosts | Where-Object { $_.HostName -eq $Ip } | Select-Object -First 1
    if ($H) { return $H.Alias }
    return ""
}

# "10.10.5.1 (ha.srv)" when a hop is one of the ssh hosts
function Get-ScanHopLabel {
    param([string]$Ip)
    $H = $script:Hosts | Where-Object { $_.HostName -eq $Ip } | Select-Object -First 1
    if ($H) { return "$Ip ($($H.Alias))" }
    return $Ip
}

function Start-NetScan {
    param([string]$Range)

    if ($Range) { $Ui.ScanRange.Text = $Range }
    $Range = Repair-TargetText $Ui.ScanRange
    if (-not $Range) { Show-Toast "Укажи диапазон" "warn"; [void]$Ui.ScanRange.Focus(); return }

    $Parsed = Expand-IpRange $Range
    if ($Parsed.Errors) { Show-Toast "Не понял: $($Parsed.Errors -join '; ')" "warn" }
    $Ips = $Parsed.Ips
    if (-not $Ips.Count) { return }
    if ($Ips.Count -gt 4096 -and -not (Show-Confirm "Большой диапазон" "$($Ips.Count) адресов — это займёт несколько минут. Продолжить?" "Сканировать")) { return }

    $Ports = Expand-PortSpec $Ui.ScanPorts.Text
    Add-History "ScanHistory" $Range
    Update-ScanChips
    Start-ScanRoute $Ips[0]

    $script:ScanItems.Clear()
    $script:ScanRows = @{}
    $script:ScanInfo = @{ Total = $Ips.Count; Done = 0; Started = [DateTime]::Now; Finished = $null; Range = $Range; Ports = $Ports }
    $Ui.ScanProgress.Value = 0
    $Ui.ScanStart.IsEnabled = $false
    $Ui.ScanStop.IsEnabled = $true
    Update-PageSub

    [void](Start-Worker -Name "scan" -Replace -Body $script:ScanBody `
        -ArgList @(@(, [string[]]$Ips) + @(, [int[]]$Ports) + @(, $script:LocalNets) + @([bool]$Ui.ScanNames.IsChecked) + @([bool]$Ui.ScanBind.IsChecked)) `
        -OnMessage {
            param($M)
            switch ($M.Type) {
                "host" { Set-ScanRow @{ Ip = $M.Ip; Rtt = $M.Rtt; Ports = $M.Ports } }
                "progress" {
                    $script:ScanInfo.Done = $M.Done
                    $Ui.ScanProgress.Value = [Math]::Round(100.0 * $M.Done / [Math]::Max(1, $M.Total))
                    Update-PageSub
                }
                { $_ -in @("mac", "name", "self") } {
                    $Row = $script:ScanRows[$M.Ip]
                    if ($Row) {
                        $D = $Row.Data.Clone()
                        if ($M.Type -eq "mac") { $D.Mac = $M.Mac }
                        if ($M.Type -eq "name") { $D.Name = $M.Name }
                        if ($M.Type -eq "self") { $D.Self = "адрес этого ПК ($($M.Alias))" }
                        Set-ScanRow $D
                    }
                }
            }
        } -OnDone {
            $script:ScanInfo.Finished = [DateTime]::Now
            $Ui.ScanProgress.Value = 100
            $Ui.ScanStart.IsEnabled = $true
            $Ui.ScanStop.IsEnabled = $false
            Update-PageSub
            Show-Toast "Сканирование: найдено $($script:ScanItems.Count) устройств"
        })
}

function Update-ScanChips {
    $Ui.ScanChips.Children.Clear()
    $Seen = @{}

    foreach ($N in $script:LocalNets) {
        if ($N.Prefix -lt 16) { continue }
        $Cidr = "$($N.Net)/$($N.Prefix)"
        if ($Seen[$Cidr]) { continue }
        $Seen[$Cidr] = $true
        $Name = ($N.Alias -replace '^vEthernet \((.+)\)$', '$1' -replace '\s*\[[0-9a-f]+\]$', '')
        [void]$Ui.ScanChips.Children.Add((New-RangeChip $Cidr $Name $(if ($N.Tunnel) { 0xE72E } else { 0xE839 })))
    }
    foreach ($H in @($script:Settings.ScanHistory)) {
        if (-not $H -or $Seen[$H]) { continue }
        $Seen[$H] = $true
        [void]$Ui.ScanChips.Children.Add((New-RangeChip $H "" 0xE81C))
    }
}

function New-RangeChip {
    param([string]$Range, [string]$Label, [int]$Glyph)
    $B = New-Object System.Windows.Controls.Button
    $B.Style = $script:Win.FindResource("ChipBtn")
    $Sp = New-Object System.Windows.Controls.StackPanel
    $Sp.Orientation = "Horizontal"
    $G = New-Glyph $Glyph "Faint"; $G.FontSize = 11; $G.Margin = "0,0,6,0"
    [void]$Sp.Children.Add($G)
    $T = New-Object System.Windows.Controls.TextBlock
    $T.Text = $Range
    $T.FontFamily = $script:Win.FindResource("MonoFont")
    [void]$Sp.Children.Add($T)
    if ($Label) {
        $L = New-Object System.Windows.Controls.TextBlock
        $L.Text = "  $Label"
        $L.Foreground = Get-Brush "Faint"
        [void]$Sp.Children.Add($L)
    }
    $B.Content = $Sp
    $B.Tag = "scan:$Range"
    $B.ToolTip = "Сканировать $Range (правый клик — только подставить)"
    $B.Add_MouseRightButtonUp({ param($S, $E) $Ui.ScanRange.Text = $S.Tag.Substring(5); $E.Handled = $true })
    return $B
}

function Send-WakeOnLan {
    param([string]$Mac)
    $Hex = $Mac -replace '[^0-9A-Fa-f]', ''
    if ($Hex.Length -ne 12) { Show-Toast "Нет MAC-адреса" "warn"; return }
    $MacBytes = for ($i = 0; $i -lt 12; $i += 2) { [Convert]::ToByte($Hex.Substring($i, 2), 16) }
    $Packet = [byte[]](@(0xFF) * 6 + ($MacBytes * 16))
    $U = New-Object System.Net.Sockets.UdpClient
    $U.EnableBroadcast = $true
    [void]$U.Send($Packet, $Packet.Length, "255.255.255.255", 9)
    $U.Close()
    Show-Toast "Magic packet → $Mac"
}

function Get-SelectedScan { return $Ui.ScanList.SelectedItem }

function Export-ScanList {
    if (-not $script:ScanItems.Count) { Show-Toast "Список пуст — сначала просканируй" "warn"; return }
    $Stamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $Safe = ($script:ScanInfo.Range -replace '[\\/:*?"<>|,\s]+', '_')
    $Path = Show-SaveFile "Сохранить список устройств" "CSV для Excel (*.csv)|*.csv|TSV (*.tsv)|*.tsv" "scan_${Safe}_$Stamp.csv"
    if (-not $Path) { return }
    try {
        $N = Write-ScanExport $Path @($script:ScanItems)
        Show-Toast "Сохранено: $([IO.Path]::GetFileName($Path)) · $N строк"
    } catch {
        Show-Toast "Не сохранил: $($_.Exception.Message)" "fail"
    }
}

# CSV with ';' + BOM opens in Russian Excel as columns; .tsv — plain tabs
function Write-ScanExport {
    param([string]$Path, [object[]]$Items)
    $Rows = foreach ($R in $Items) {
        [pscustomobject]@{
            IP = $R.Ip; "Имя" = $R.Name; MAC = $R.Mac; "Производитель" = $R.Vendor
            "Пинг" = $R.RttText; "Порты" = ($R.Ports -join " ")
            "Сервисы" = (@($R.Badges | ForEach-Object { $_.Text }) -join ", ")
        }
    }
    if ($Path -like "*.tsv") {
        $Lines = @(("IP", "Имя", "MAC", "Производитель", "Пинг", "Порты", "Сервисы") -join "`t")
        $Lines += @($Rows | ForEach-Object { ($_.IP, $_."Имя", $_.MAC, $_."Производитель", $_."Пинг", $_."Порты", $_."Сервисы") -join "`t" })
        [IO.File]::WriteAllLines($Path, $Lines, [Text.UTF8Encoding]::new($true))
    } else {
        $Rows | Export-Csv -Path $Path -Delimiter ';' -Encoding utf8BOM -NoTypeInformation -UseQuotes AsNeeded
    }
    return @($Rows).Count
}

function Show-SubnetCalc {
    param([string]$Prefill)

    $D = New-Dialog "Калькулятор подсетей" @"
<StackPanel>
    <TextBlock Text="Калькулятор подсетей" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="CIDR, адрес с маской или просто 192.168.5 — считается по мере ввода." Foreground="{StaticResource Sub}" Margin="0,6,0,14" FontSize="12.5"/>
    <TextBox x:Name="FIn" Style="{StaticResource MonoField}" Height="40" FontSize="14.5" Tag="192.168.1.0/24 · 10.0.0.1 255.255.0.0 · 192.168.5"/>
    <TextBox x:Name="FOut" Style="{StaticResource Code}" Margin="0,12,0,0" Height="250" FontSize="12.5"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button x:Name="FCopy" Style="{StaticResource Btn}" MinWidth="110">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8C8;" Style="{StaticResource Glyph}"/><TextBlock Text="Копировать"/></StackPanel>
        </Button>
        <Button x:Name="FClose" Style="{StaticResource Btn}" Content="Закрыть" MinWidth="96" IsCancel="True" Margin="8,0,0,0"/>
        <Button x:Name="FScan" Style="{StaticResource AccentBtn}" MinWidth="150" Margin="8,0,0,0" IsDefault="True">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE968;" Style="{StaticResource Glyph}"/><TextBlock Text="Сканировать сеть"/></StackPanel>
        </Button>
    </StackPanel>
</StackPanel>
"@ 520

    $FIn = $D.FindName("FIn"); $FOut = $D.FindName("FOut")
    $State = @{ Cidr = "" }
    $Calc = {
        try {
            $I = Get-SubnetInfo ($FIn.Text -replace '(?<![\d.])(\d{1,3}),(\d{1,3}),(\d{1,3}),(\d{1,3})(?![\d.])', '$1.$2.$3.$4')
            $State.Cidr = $I.Cidr
            $FOut.Text = (@(
                "Сеть:            $($I.Cidr)"
                "Маска:           $($I.Mask)   /$($I.Prefix)"
                "Биты маски:      $($I.MaskBits)"
                "Wildcard:        $($I.Wildcard)"
                ""
                "Адрес сети:      $($I.Network)"
                "Broadcast:       $($I.Broadcast)"
                "Хосты:           $($I.FirstHost) – $($I.LastHost)"
                "Всего хостов:    $($I.Hosts.ToString('N0'))"
                ""
                "Класс:           $($I.Class)"
                "Приватная:       $(if ($I.Private) { 'да (RFC 1918 / CGNAT / link-local)' } else { 'нет — публичный диапазон' })"
                "Для сканера:     $($I.Range)"
            ) -join "`r`n")
            $FOut.Foreground = $D.FindResource("Text")
        } catch {
            $State.Cidr = ""
            $FOut.Text = "$($_.Exception.Message)"
            $FOut.Foreground = $D.FindResource("Warn")
        }
    }
    $FIn.Add_TextChanged($Calc)
    $FIn.Text = $(if ($Prefill) { $Prefill } elseif ($script:LocalNets.Count) { $N = $script:LocalNets | Where-Object { -not $_.Tunnel } | Select-Object -First 1; "$($N.Ip)/$($N.Prefix)" } else { "192.168.1.0/24" })
    $D.FindName("FCopy").Add_Click({ Copy-Text $FOut.Text "расчёт подсети" })
    $D.FindName("FScan").Add_Click({ if ($State.Cidr) { $D.Tag = $State.Cidr; $D.DialogResult = $true } })
    $D.Add_ContentRendered({ [void]$FIn.Focus(); $FIn.SelectAll() })
    if ($D.ShowDialog() -and $D.Tag) { Start-NetScan $D.Tag }
}

function Initialize-ScannerPage {
    $Ui.ScanList.ItemsSource = $script:ScanItems
    $Ui.ScanStart.Add_Click({ Start-NetScan })
    $Ui.ScanStop.Add_Click({ Stop-Worker "scan"; $Ui.ScanStart.IsEnabled = $true; $Ui.ScanStop.IsEnabled = $false; $script:ScanInfo.Finished = [DateTime]::Now; Update-PageSub; Show-Toast "Остановлено" "info" })
    $Ui.ScanRange.Add_KeyDown({ param($S, $E) if ($E.Key -eq "Return") { Start-NetScan; $E.Handled = $true } })
    $Ui.ScanList.Add_MouseDoubleClick({ $R = Get-SelectedScan; if ($R) { Start-PortScanFor $R.Ip "std" } })
    $Ui.ScanExport.Add_Click({ Export-ScanList })
    $Ui.SubnetCalcBtn.Add_Click({ Show-SubnetCalc $(if ($Ui.ScanRange.Text.Trim()) { Repair-TargetText $Ui.ScanRange } else { "" }) })

    $Ui.ScanList.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Порты: стандарт" 0xE839 { $R = Get-SelectedScan; if ($R) { Start-PortScanFor $R.Ip "std" } } "2×клик")
        (New-MenuItem "Порты: расширенный (nmap)" 0xE839 { $R = Get-SelectedScan; if ($R) { Start-PortScanFor $R.Ip "ext" -Nmap } })
        (New-MenuItem "Порты: настроить…" 0xE713 { $R = Get-SelectedScan; if ($R) { Open-PortsFor $R.Ip } })
        "-"
        (New-MenuItem "Пинг" 0xE9D9 { $R = Get-SelectedScan; if ($R) { Start-PingFor $R.Ip } })
        (New-MenuItem "Трассировка" 0xE81E { $R = Get-SelectedScan; if ($R) { Start-PingFor $R.Ip -Trace } })
        (New-MenuItem "В монитор" 0xE9D2 { $R = Get-SelectedScan; if ($R) { Add-MonTarget $R.Ip $(if ($R.Name) { $R.Name } else { $R.Ip }) } })
        (New-MenuItem "Открыть http://" 0xE774 { $R = Get-SelectedScan; if ($R) { Start-Process "http://$($R.Ip)" } })
        (New-MenuItem "Открыть https://" 0xE774 { $R = Get-SelectedScan; if ($R) { Start-Process "https://$($R.Ip)" } })
        (New-MenuItem "SSH root@…" 0xE756 { $R = Get-SelectedScan; if ($R) { Start-Terminal "ssh root@$($R.Ip)" $R.Ip } })
        "-"
        (New-MenuItem "Копировать IP" 0xE8C8 { $R = Get-SelectedScan; if ($R) { Copy-Text $R.Ip $R.Ip } } "Ctrl+C")
        (New-MenuItem "Копировать MAC" 0xE8C8 { $R = Get-SelectedScan; if ($R) { Copy-Text $R.Mac "MAC" } })
        (New-MenuItem "Копировать весь список" 0xE8C8 {
            $Lines = $script:ScanItems | ForEach-Object { "{0}`t{1}`t{2}`t{3}`t{4}" -f $_.Ip, $_.Name, $_.Mac, $_.RttText, ($_.Ports -join ",") }
            Copy-Text ($Lines -join "`r`n") "$($script:ScanItems.Count) строк (TSV)"
        })
        (New-MenuItem "Сохранить в CSV / TSV…" 0xE74E { Export-ScanList })
        (New-MenuItem "Wake-on-LAN" 0xE7E8 { $R = Get-SelectedScan; if ($R) { Send-WakeOnLan $R.Mac } })
        (New-MenuItem "Добавить как SSH-сервер…" 0xE710 { $R = Get-SelectedScan; if ($R) { Show-NewServerDialog ([pscustomobject]@{ HostName = $R.Ip; Port = "22"; User = "root"; Alias = $(if ($R.Name) { ($R.Name -split '\.')[0] } else { $R.Ip.Replace('.', '-') }) }) -NewHost } })
    )
    Update-ScanChips
}
