# Page: port scanner (built-in TCP connect with banners, or nmap).

$script:PortItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:PortRows = @{}
$script:PortInfo = @{ Target = ""; Total = 0; Done = 0; Open = 0; Started = $null; Finished = $null; Engine = "" }
$script:Nmap = @(
    (Get-Command nmap.exe -ErrorAction SilentlyContinue).Source,
    "${env:ProgramFiles(x86)}\Nmap\nmap.exe",
    "$env:ProgramFiles\Nmap\nmap.exe",
    (Join-Path $script:AppDir "nmap\nmap.exe")
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

$script:PortScanBody = {
    param($Q, $Ctl, $Ip, $HostName, $Ports, $LocalNets)

    $Total = $Ports.Count
    $Done = 0
    $Open = [System.Collections.Generic.List[int]]::new()
    $Batch = 400

    for ($i = 0; $i -lt $Total; $i += $Batch) {
        if ($Ctl.Stop) { break }
        $Chunk = $Ports[$i..([Math]::Min($i + $Batch, $Total) - 1)]
        $Targets = foreach ($P in $Chunk) { [pscustomobject]@{ Ip = $Ip; Port = $P } }
        foreach ($O in (Test-TcpBatch @($Targets) 900 $LocalNets)) {
            $Open.Add([int]$O.Port)
            $Q.Enqueue(@{ Type = "port"; Host = $Ip; Port = [int]$O.Port; Service = (Get-ServiceName $O.Port); Info = "…" })
        }
        $Done += $Chunk.Count
        $Q.Enqueue(@{ Type = "progress"; Done = $Done; Total = $Total })
    }

    if ($Total -ge 20 -and $Open.Count -ge [Math]::Max(10, $Total * 0.5)) {
        $Q.Enqueue(@{ Type = "log"; Text = "ВНИМАНИЕ: открыто $($Open.Count) из $Total — похоже, TCP перехватывает прокси/туннель. Смотри баннеры: «без баннера» = ложное открытие." })
    }

    $N = 0
    foreach ($P in $Open) {
        if ($Ctl.Stop -or $N -ge 60) { break }
        $N++
        $B = Get-PortBanner -Ip $Ip -Port $P -HostName $HostName -LocalNets $LocalNets
        $Q.Enqueue(@{ Type = "port"; Host = $Ip; Port = $P; Service = (Get-ServiceName $P); Info = $B })
    }
}

$script:NmapBody = {
    param($Q, $Ctl, $Nmap, $ArgLine, $XmlPath)

    $Psi = New-Object System.Diagnostics.ProcessStartInfo $Nmap
    $Psi.Arguments = $ArgLine
    $Psi.RedirectStandardOutput = $true; $Psi.RedirectStandardError = $true
    $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true
    $Q.Enqueue(@{ Type = "log"; Text = "nmap $ArgLine" })
    $P = [System.Diagnostics.Process]::Start($Psi)
    $ErrTask = $P.StandardError.ReadToEndAsync()

    while ($true) {
        if ($Ctl.Stop) { try { $P.Kill($true) } catch { }; $Q.Enqueue(@{ Type = "log"; Text = "остановлено" }); return }
        $T = $P.StandardOutput.ReadLineAsync()
        while (-not $T.Wait(200)) {
            if ($Ctl.Stop) { try { $P.Kill($true) } catch { }; return }
        }
        $Line = $T.Result
        if ($null -eq $Line) { break }
        if ($Line -match 'Discovered open port (\d+)/tcp on (\S+)') {
            $Q.Enqueue(@{ Type = "port"; Host = $Matches[2]; Port = [int]$Matches[1]; Service = (Get-ServiceName ([int]$Matches[1])); Info = "…" })
        }
        if ($Line -match 'About ([\d.]+)% done') { $Q.Enqueue(@{ Type = "pct"; Pct = [double]$Matches[1] }) }
        if ($Line.Trim()) { $Q.Enqueue(@{ Type = "log"; Text = $Line }) }
    }
    $P.WaitForExit()
    $Err = $ErrTask.Result
    if ($Err) { foreach ($L in ($Err -split "`r?`n" | Where-Object { $_ })) { $Q.Enqueue(@{ Type = "log"; Text = "! $L" }) } }

    if (Test-Path $XmlPath) {
        try {
            [xml]$X = Get-Content $XmlPath -Raw
            foreach ($H in $X.nmaprun.host) {
                $Addr = ($H.address | Where-Object { $_.addrtype -eq "ipv4" } | Select-Object -First 1).addr
                foreach ($Pt in $H.ports.port) {
                    if ($Pt.state.state -ne "open") { continue }
                    $S = $Pt.service
                    $Info = (@($S.product, $S.version, $S.extrainfo) | Where-Object { $_ }) -join " "
                    $Scripts = @($Pt.script | Where-Object { $_ } | ForEach-Object { "$($_.id): $($_.output.Trim())" })
                    if ($Scripts) { $Info = (@($Info) + $Scripts | Where-Object { $_ }) -join " · " }
                    if (-not $Info) { $Info = "$($Pt.state.reason)" }
                    $Q.Enqueue(@{ Type = "port"; Host = $Addr; Port = [int]$Pt.portid; Service = "$($S.name)"; Info = ($Info -replace '\s+', ' ') })
                }
            }
        } catch { $Q.Enqueue(@{ Type = "log"; Text = "XML: $($_.Exception.Message)" }) }
        Remove-Item $XmlPath -ErrorAction SilentlyContinue
    }
}

function Add-PortLog {
    param([string]$Text)
    $Ui.PortLog.AppendText("$Text`r`n")
    if ($Ui.PortLog.LineCount -gt 3000) { $Ui.PortLog.Text = ($Ui.PortLog.Text -split "`r`n" | Select-Object -Last 2000) -join "`r`n" }
    $Ui.PortLog.ScrollToEnd()
}

function Set-PortRow {
    param([hashtable]$M)
    $Key = "$($M.Host):$($M.Port)"
    $Multi = $script:PortInfo.Multi
    $Badges = @(New-PortBadges -Ip $M.Host -Ports @($M.Port) -HostName $script:PortInfo.HostName | Where-Object { $_.Kind -ne "" -or $_.Tag -match '^(rdp|smb):' })
    $HostNum = 0
    if ($M.Host -match '^\d{1,3}(\.\d{1,3}){3}$') { $HostNum = [double](ConvertTo-IpUInt $M.Host) }
    $Row = [pscustomobject]@{
        Key = $Key; Host = $M.Host; Port = $M.Port; Sort = $HostNum * 65536 + $M.Port
        Service = $(if ($M.Service) { $M.Service } else { "—" })
        Info = $(if ($Multi) { "$($M.Host) · $($M.Info)" } else { $M.Info })
        Badges = $Badges
    }
    $Old = $script:PortRows[$Key]
    if ($Old) {
        if ($M.Info -eq "…" -and $Old.Info -ne "…") { return }
        $script:PortItems[$script:PortItems.IndexOf($Old)] = $Row
    } else {
        $Idx = 0
        while ($Idx -lt $script:PortItems.Count -and $script:PortItems[$Idx].Sort -lt $Row.Sort) { $Idx++ }
        $script:PortItems.Insert($Idx, $Row)
        $script:PortInfo.Open++
    }
    $script:PortRows[$Key] = $Row
}

function Get-PortMode {
    if ($Ui.PmExt.IsChecked) { return "ext" }
    if ($Ui.PmAll.IsChecked) { return "all" }
    if ($Ui.PmCustom.IsChecked) { return "custom" }
    return "std"
}

function Get-PortsSub {
    $I = $script:PortInfo
    if (-not $I.Target) {
        $N = if ($script:Nmap) { "nmap найден: $($script:Nmap)" } else { "nmap не найден — работает встроенный сканер" }
        return "Стандарт / расширенный / свой диапазон · $N"
    }
    $S = "$($I.Target) · открыто $($I.Open)"
    if ($I.Total) { $S += " · проверено $($I.Done) из $($I.Total)" }
    if ($I.Started) {
        $End = if ($I.Finished) { $I.Finished } else { [DateTime]::Now }
        $S += " · {0:N1} с" -f ($End - $I.Started).TotalSeconds
    }
    $S += " · $($I.Engine)"
    return $S
}

function Open-PortsFor {
    param([string]$Target)
    $Ui.PortTarget.Text = $Target
    Set-Page "ports"
    [void]$Ui.PortTarget.Focus()
}

function Start-PortScanFor {
    param([string]$Target, [string]$Mode = "std", [switch]$Nmap)
    $Ui.PortTarget.Text = $Target
    switch ($Mode) { "ext" { $Ui.PmExt.IsChecked = $true } "all" { $Ui.PmAll.IsChecked = $true } default { $Ui.PmStd.IsChecked = $true } }
    if ($Nmap -and $script:Nmap) { $Ui.PortUseNmap.IsChecked = $true } elseif (-not $Nmap) { $Ui.PortUseNmap.IsChecked = $false }
    Set-Page "ports"
    Start-PortScan
}

function Start-PortScan {
    $Target = Repair-TargetText $Ui.PortTarget
    if (-not $Target) { Show-Toast "Укажи хост" "warn"; [void]$Ui.PortTarget.Focus(); return }
    $Mode = Get-PortMode
    $UseNmap = [bool]$Ui.PortUseNmap.IsChecked
    if ($UseNmap -and -not $script:Nmap) { Show-Toast "nmap не найден — встроенный сканер" "warn"; $UseNmap = $false }

    $Parsed = $null
    $IsRange = $Target -match '[/*,\s]|\d-\d'
    if (-not $UseNmap) {
        $Parsed = Expand-IpRange $Target 2
        if ($Parsed.Errors -or -not $Parsed.Ips.Count) { Show-Toast "Не резолвится: $Target" "fail"; return }
        if ($IsRange -or $Parsed.Ips.Count -gt 1) {
            if ($script:Nmap) { $UseNmap = $true; $Ui.PortUseNmap.IsChecked = $true; Show-Toast "Диапазон адресов — включил nmap" "info" }
            else { Show-Toast "Для диапазона адресов нужен nmap" "warn"; return }
        }
    }

    $Ports = switch ($Mode) {
        "ext"    { Get-ExtendedPorts }
        "all"    { 1..65535 }
        "custom" { Expand-PortSpec $Ui.PortRange.Text }
        default  { $script:StandardPorts }
    }
    if (-not $Ports.Count) { Show-Toast "Пустой список портов" "warn"; return }

    Add-History "PortHistory" $Target
    $script:PortItems.Clear()
    $script:PortRows = @{}
    $Ui.PortLog.Clear()
    $Ui.PortProgress.Value = 0
    $Ui.PortStart.IsEnabled = $false
    $Ui.PortStop.IsEnabled = $true

    $HostName = if ($Target -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -and -not $IsRange) { $Target } else { "" }
    $script:PortInfo = @{ Target = $Target; Total = 0; Done = 0; Open = 0; Started = [DateTime]::Now; Finished = $null; Engine = ""; Multi = $IsRange; HostName = $HostName }

    $OnMsg = {
        param($M)
        switch ($M.Type) {
            "port" { Set-PortRow $M; Update-PageSub }
            "progress" { $script:PortInfo.Done = $M.Done; $script:PortInfo.Total = $M.Total; $Ui.PortProgress.Value = [Math]::Round(100.0 * $M.Done / [Math]::Max(1, $M.Total)); Update-PageSub }
            "pct" { $Ui.PortProgress.Value = $M.Pct }
            "log" { Add-PortLog $M.Text }
        }
    }
    $OnDone = {
        $script:PortInfo.Finished = [DateTime]::Now
        $Ui.PortProgress.Value = 100
        $Ui.PortStart.IsEnabled = $true
        $Ui.PortStop.IsEnabled = $false
        Update-PageSub
        Add-PortLog "готово: открыто $($script:PortInfo.Open)"
        Show-Toast "$($script:PortInfo.Target): открыто $($script:PortInfo.Open)"
    }

    if ($UseNmap) {
        $Xml = Join-Path $env:TEMP "netknife-nmap-$([guid]::NewGuid()).xml"
        $A = @("-sT", "-T4", "-v", "--stats-every", "2s", "--open")
        if ($Ui.PortNoPing.IsChecked) { $A += "-Pn" }
        if ($Ui.PortVersions.IsChecked) { $A += "-sV" }
        switch ($Mode) {
            "ext"    { $A += @("--top-ports", "1000") }
            "all"    { $A += "-p-" }
            "custom" { $A += @("-p", ($Ui.PortRange.Text -replace '\s', '')) }
            default  { $A += @("-p", ($script:StandardPorts -join ",")) }
        }
        if ($Ui.NmapArgs.Text.Trim()) { $A += $Ui.NmapArgs.Text.Trim() }
        $A += @("-oX", (Quote-Arg $Xml), $Target)
        $script:PortInfo.Engine = "nmap"
        [void](Start-Worker -Name "ports" -Replace -Body $script:NmapBody -ArgList @($script:Nmap, ($A -join " "), $Xml) -OnMessage $OnMsg -OnDone $OnDone)
    } else {
        $Ip = $Parsed.Ips[0]
        $script:PortInfo.Engine = "встроенный TCP connect"
        $script:PortInfo.Total = $Ports.Count
        Add-PortLog "TCP connect → $Target ($Ip), портов: $($Ports.Count)"
        if (Find-BindIp $Ip $script:LocalNets) { Add-PortLog "LAN-цель: привязка к $(Find-BindIp $Ip $script:LocalNets) (мимо туннеля)" }
        if (Test-FakeIp $Ip) { Add-PortLog "ВНИМАНИЕ: $Ip — fake-ip от прокси-DNS, результаты покажут прокси, а не сервер" }
        [void](Start-Worker -Name "ports" -Replace -Body $script:PortScanBody -ArgList @($Ip, $HostName, [int[]]$Ports, $script:LocalNets) -OnMessage $OnMsg -OnDone $OnDone)
    }
    Update-PageSub
}

function Initialize-PortsPage {
    $Ui.PortList.ItemsSource = $script:PortItems
    $Ui.PortStart.Add_Click({ Start-PortScan })
    $Ui.PortStop.Add_Click({ Stop-Worker "ports"; $Ui.PortStart.IsEnabled = $true; $Ui.PortStop.IsEnabled = $false; $script:PortInfo.Finished = [DateTime]::Now; Update-PageSub; Show-Toast "Остановлено" "info" })
    $Ui.PortTarget.Add_KeyDown({ param($S, $E) if ($E.Key -eq "Return") { Start-PortScan; $E.Handled = $true } })
    $Ui.PortRange.Add_KeyDown({ param($S, $E) if ($E.Key -eq "Return") { Start-PortScan; $E.Handled = $true } })
    foreach ($R in @($Ui.PmStd, $Ui.PmExt, $Ui.PmAll, $Ui.PmCustom)) {
        $R.Add_Checked({ $Ui.PortRange.Visibility = $(if ($Ui.PmCustom.IsChecked) { "Visible" } else { "Collapsed" }) })
    }
    if (-not $script:Nmap) {
        foreach ($C in @($Ui.PortUseNmap, $Ui.PortVersions, $Ui.NmapArgs)) { $C.IsEnabled = $false }
        $Ui.PortUseNmap.ToolTip = "nmap не найден (ставится с nmap.org или в папку NetKnife\nmap)"
    }
    $Ui.PortList.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Копировать host:port" 0xE8C8 { $R = $Ui.PortList.SelectedItem; if ($R) { Copy-Text "$($R.Host):$($R.Port)" "$($R.Host):$($R.Port)" } })
        (New-MenuItem "Копировать все открытые" 0xE8C8 { Copy-Text (($script:PortItems | ForEach-Object { "$($_.Host):$($_.Port)`t$($_.Service)`t$($_.Info)" }) -join "`r`n") "список портов" })
        (New-MenuItem "Открыть http://" 0xE774 { $R = $Ui.PortList.SelectedItem; if ($R) { Start-Process "http://$($R.Host):$($R.Port)" } })
        (New-MenuItem "Открыть https://" 0xE774 { $R = $Ui.PortList.SelectedItem; if ($R) { Start-Process "https://$($R.Host):$($R.Port)" } })
        (New-MenuItem "Проверить порт заново" 0xE72C { $R = $Ui.PortList.SelectedItem; if ($R) { $Ui.PmCustom.IsChecked = $true; $Ui.PortRange.Text = "$($R.Port)"; $Ui.PortUseNmap.IsChecked = $false; $Ui.PortTarget.Text = $R.Host; Start-PortScan } })
    )
}
