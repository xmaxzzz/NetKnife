# Page: SSH tunnels (-L / -D / -R) kept alive as background `ssh -N` processes.

$script:TunnelItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:TunnelProcs = @{}      # id -> @{ P; Err; Started; Error; Notified }
$script:TunnelPumpSw = [System.Diagnostics.Stopwatch]::StartNew()

function Get-Tunnels { return @($script:Settings.Tunnels | Where-Object { $_ -and $_.Id }) }

function Get-TunnelMapping {
    param($T)
    switch ("$($T.Type)") {
        "D" { return "SOCKS5  localhost:$($T.Local)  через $($T.Host)" }
        "R" { return "$($T.Host):$($T.Local)  →  $($T.Remote)  (сюда)" }
        default { return "localhost:$($T.Local)  →  $($T.Remote)" }
    }
}

function Get-TunnelSshArgs {
    param($T)
    $A = @("-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "BatchMode=yes")
    switch ("$($T.Type)") {
        "D" { $A += @("-D", "$($T.Local)") }
        "R" { $A += @("-R", "$($T.Local):$($T.Remote)") }
        default { $A += @("-L", "$($T.Local):$($T.Remote)") }
    }
    $A += $T.Host
    return ($A -join " ")
}

function Test-TunnelRunning {
    param([string]$Id)
    $S = $script:TunnelProcs[$Id]
    return [bool]($S -and -not $S.P.HasExited)
}

function New-TunnelRow {
    param($T)
    $S = $script:TunnelProcs[$T.Id]
    $Running = Test-TunnelRunning $T.Id
    $Kind = "none"; $Status = "остановлен"
    if ($Running) {
        $Min = [int]([DateTime]::Now - $S.Started).TotalMinutes
        $Kind = if ($Min -lt 1 -and ([DateTime]::Now - $S.Started).TotalSeconds -lt 4) { "wait" } else { "ok" }
        $Status = if ($Kind -eq "wait") { "подключается…" } elseif ($Min -lt 60) { "работает · $Min мин" } else { "работает · $([Math]::Round($Min / 60.0, 1)) ч" }
        if ($S.Warn) { $Kind = "wait"; $Status = $S.Warn }
    } elseif ($S -and $S.Error) { $Kind = "fail"; $Status = $S.Error }

    return [pscustomobject]@{
        Id = $T.Id; Name = $T.Name; Host = $T.Host; Mapping = (Get-TunnelMapping $T)
        StatusText = $Status; Kind = $Kind; Auto = [bool]$T.Auto
        ToggleText = $(if ($Running) { "Стоп" } else { "Старт" })
        CanOpen = ($T.Type -eq "L" -and $Running)
        ToggleTag = "tun:toggle:$($T.Id)"; OpenTag = "tun:open:$($T.Id)"; EditTag = "tun:edit:$($T.Id)"; DelTag = "tun:del:$($T.Id)"
        Tunnel = $T
    }
}

function Refresh-Tunnels {
    $Sel = $null
    if ($Ui.TunnelList.SelectedItem) { $Sel = $Ui.TunnelList.SelectedItem.Id }
    $script:TunnelItems.Clear()
    foreach ($T in Get-Tunnels) { $script:TunnelItems.Add((New-TunnelRow $T)) }
    if ($Sel) { $Ui.TunnelList.SelectedItem = ($script:TunnelItems | Where-Object { $_.Id -eq $Sel } | Select-Object -First 1) }
    $Ui.TunnelEmpty.Visibility = $(if ($script:TunnelItems.Count) { "Collapsed" } else { "Visible" })
    $Running = @($script:TunnelProcs.Keys | Where-Object { Test-TunnelRunning $_ }).Count
    $Ui.NavTunnels.Tag = $(if ($Running) { "$Running" } else { $null })
    Update-PageSub
}

function Update-TunnelRow {
    param([string]$Id)
    for ($i = 0; $i -lt $script:TunnelItems.Count; $i++) {
        if ($script:TunnelItems[$i].Id -ne $Id) { continue }
        $Sel = ($Ui.TunnelList.SelectedItem -eq $script:TunnelItems[$i])
        $script:TunnelItems[$i] = New-TunnelRow $script:TunnelItems[$i].Tunnel
        if ($Sel) { $Ui.TunnelList.SelectedItem = $script:TunnelItems[$i] }
        break
    }
    $Running = @($script:TunnelProcs.Keys | Where-Object { Test-TunnelRunning $_ }).Count
    $Ui.NavTunnels.Tag = $(if ($Running) { "$Running" } else { $null })
    Update-TrayText
    Update-PageSub
}

function Get-TunnelsSub {
    $All = @(Get-Tunnels).Count
    if (-not $All) { return "Сохранённые пробросы портов, запускаются одной кнопкой" }
    $Running = @($script:TunnelProcs.Keys | Where-Object { Test-TunnelRunning $_ }).Count
    return "$(Get-Plural $All 'туннель' 'туннеля' 'туннелей') · работают $Running"
}

function Start-Tunnel {
    param($T)
    if (Test-TunnelRunning $T.Id) { return }
    if ($T.Type -ne "R" -and (Test-LocalPortBusy ([int]$T.Local))) {
        Show-Toast "Порт $($T.Local) уже занят на этом ПК" "warn"
        return
    }
    $Psi = New-Object System.Diagnostics.ProcessStartInfo "ssh.exe"
    $Psi.Arguments = Get-TunnelSshArgs $T
    $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardError = $true; $Psi.RedirectStandardOutput = $true
    try {
        $P = [System.Diagnostics.Process]::Start($Psi)
        Add-ProcessToJob $P
        $script:TunnelProcs[$T.Id] = @{ P = $P; ErrTask = $P.StandardError.ReadLineAsync(); Lines = [System.Collections.Generic.List[string]]::new(); Out = $P.StandardOutput.ReadToEndAsync(); Started = [DateTime]::Now; Error = ""; Warn = ""; Notified = $false }
        Save-TunnelPids
        Show-Toast "Туннель «$($T.Name)»: запуск" "info"
    } catch {
        $script:TunnelProcs[$T.Id] = @{ P = $null; Started = [DateTime]::Now; Error = "не запустился: $($_.Exception.Message)"; Notified = $true }
    }
    Update-TunnelRow $T.Id
}

function Stop-Tunnel {
    param($T, [switch]$Quiet)
    $S = $script:TunnelProcs[$T.Id]
    if ($S -and $S.P -and -not $S.P.HasExited) { try { $S.P.Kill($true) } catch { } }
    $script:TunnelProcs.Remove($T.Id)
    Save-TunnelPids
    if (-not $Quiet) { Show-Toast "Туннель «$($T.Name)» остановлен" "info" }
    Update-TunnelRow $T.Id
}

function Stop-AllTunnels {
    foreach ($Id in @($script:TunnelProcs.Keys)) {
        $S = $script:TunnelProcs[$Id]
        if ($S.P -and -not $S.P.HasExited) { try { $S.P.Kill($true) } catch { } }
    }
    $script:TunnelProcs = @{}
}

function Test-LocalPortBusy {
    param([int]$Port)
    try {
        $L = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $Port
        $L.Start(); $L.Stop()
        return $false
    } catch { return $true }
}

# Called from the main pump; cheap, throttled to once a second
function Invoke-TunnelPump {
    if ($script:TunnelPumpSw.ElapsedMilliseconds -lt 1000) { return }
    $script:TunnelPumpSw.Restart()
    $Tick = [int]([DateTime]::Now.TimeOfDay.TotalSeconds)
    foreach ($Id in @($script:TunnelProcs.Keys)) {
        $S = $script:TunnelProcs[$Id]
        if (-not $S.P) { continue }

        # drain stderr line by line without blocking: ssh reports forward failures here while staying alive
        $Changed = $false
        while ($S.ErrTask -and $S.ErrTask.IsCompleted) {
            $L = $null
            try { $L = $S.ErrTask.Result } catch { }
            if ($null -eq $L) { $S.ErrTask = $null; break }
            if ($L.Trim() -and $L -notmatch '^Warning: Permanently added') { $S.Lines.Add($L.Trim()); $Changed = $true }
            $S.ErrTask = $S.P.StandardError.ReadLineAsync()
        }
        if ($Changed -and -not $S.P.HasExited) {
            $Last = $S.Lines[$S.Lines.Count - 1]
            $S.Warn = if ($Last -match 'administratively prohibited') { "хост запрещает проброс (AllowTcpForwarding no)" }
                      elseif ($Last -match 'open failed|connect failed|Connection refused') { "цель недоступна с хоста: $Last" }
                      else { $Last }
            Update-TunnelRow $Id
        }

        if ($S.P.HasExited -and -not $S.Notified) {
            $S.Notified = $true
            $Err = if ($S.Lines.Count) { $S.Lines[$S.Lines.Count - 1] } else { "" }
            if (-not $Err) { $Err = "ssh завершился, код $($S.P.ExitCode)" }
            $S.Error = $Err
            $T = @(Get-Tunnels) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
            Show-Toast "Туннель «$($T.Name)» упал: $Err" "fail"
            Update-TunnelRow $Id
        } elseif (-not $S.P.HasExited -and $script:Page -eq "tunnels" -and ($Tick % 5 -eq 0 -or ([DateTime]::Now - $S.Started).TotalSeconds -lt 6)) {
            Update-TunnelRow $Id
        }
    }
}

function Start-AutoTunnels {
    foreach ($T in Get-Tunnels) { if ($T.Auto) { Start-Tunnel $T } }
}

# PID file: if NetKnife dies hard, the next start kills ssh tunnels left behind (they would hold the ports)
$script:TunnelPidFile = Join-Path $script:DataDir "tunnels.pid"

function Save-TunnelPids {
    try {
        $Pids = @($script:TunnelProcs.Values | Where-Object { $_.P -and -not $_.P.HasExited } | ForEach-Object { $_.P.Id })
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir | Out-Null }
        [IO.File]::WriteAllLines($script:TunnelPidFile, [string[]]$Pids)
    } catch { }
}

function Remove-StaleTunnels {
    if (-not (Test-Path $script:TunnelPidFile)) { return }
    $Killed = 0
    foreach ($Line in Get-Content $script:TunnelPidFile) {
        if ($Line -notmatch '^\d+$') { continue }
        $P = Get-Process -Id ([int]$Line) -ErrorAction SilentlyContinue
        if ($P -and $P.ProcessName -eq "ssh") { try { $P.Kill(); $Killed++ } catch { } }
    }
    try { [IO.File]::Delete($script:TunnelPidFile) } catch { }
    if ($Killed) { Write-AppLog "stale tunnels killed: $Killed" }
}

# ---------------------------------------------------------------- dialog

function Show-TunnelDialog {
    param($T)
    $IsNew = -not $T
    $Title = if ($IsNew) { "Новый туннель" } else { "Изменить · $($T.Name)" }

    $D = New-Dialog $Title @"
<StackPanel>
    <TextBlock Text="$([System.Security.SecurityElement]::Escape($Title))" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="Запускается как ssh -N с ExitOnForwardFailure — если порт занят или хост не пускает, туннель сразу покажет ошибку." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,16" FontSize="12.5"/>
    <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="НАЗВАНИЕ" Style="{StaticResource Caption}"/><TextBox x:Name="FName" Style="{StaticResource Field}" Tag="Proxmox дома"/></StackPanel>
        <StackPanel Grid.Column="2">
            <TextBlock Text="ЧЕРЕЗ ХОСТ (ALIAS)" Style="{StaticResource Caption}"/>
            <DockPanel><Button x:Name="FHostPick" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" Content="&#xE70D;" Width="30" Height="36" Margin="4,0,0,0"/><TextBox x:Name="FHost" Style="{StaticResource MonoField}" Tag="из ~/.ssh/config"/></DockPanel>
        </StackPanel>
    </Grid>
    <TextBlock Text="ТИП" Style="{StaticResource Caption}" Margin="2,14,0,6"/>
    <Border Style="{StaticResource SegBox}" HorizontalAlignment="Left">
        <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="FTypeL" Style="{StaticResource Seg}" GroupName="Tt" IsChecked="True" Content="-L локальный → удалённый"/>
            <RadioButton x:Name="FTypeD" Style="{StaticResource Seg}" GroupName="Tt" Content="-D SOCKS-прокси"/>
            <RadioButton x:Name="FTypeR" Style="{StaticResource Seg}" GroupName="Tt" Content="-R удалённый → сюда"/>
        </StackPanel>
    </Border>
    <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock x:Name="FLocalCap" Text="ЛОКАЛЬНЫЙ ПОРТ" Style="{StaticResource Caption}"/><TextBox x:Name="FLocal" Style="{StaticResource MonoField}" Tag="8006"/></StackPanel>
        <StackPanel x:Name="FRemoteBox" Grid.Column="2"><TextBlock x:Name="FRemoteCap" Text="КУДА (ХОСТ:ПОРТ, КАК ВИДИТ СЕРВЕР)" Style="{StaticResource Caption}"/><TextBox x:Name="FRemote" Style="{StaticResource MonoField}" Tag="192.168.200.30:8006 или localhost:5432"/></StackPanel>
    </Grid>
    <CheckBox x:Name="FAuto" Style="{StaticResource Switch}" Content="Запускать при старте NetKnife" Margin="2,16,0,0"/>
    <TextBlock x:Name="FError" Foreground="{StaticResource Fail}" FontSize="12" Margin="2,8,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button x:Name="FCancel" Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" MinWidth="130" Margin="8,0,0,0" IsDefault="True">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74E;" Style="{StaticResource Glyph}"/><TextBlock Text="Сохранить"/></StackPanel>
        </Button>
    </StackPanel>
</StackPanel>
"@ 560

    $F = @{}
    foreach ($N in @("FName", "FHost", "FHostPick", "FTypeL", "FTypeD", "FTypeR", "FLocal", "FLocalCap", "FRemote", "FRemoteBox", "FRemoteCap", "FAuto", "FError", "FOk")) { $F[$N] = $D.FindName($N) }
    Add-PickMenu $F.FHostPick $F.FHost { @($script:Hosts | ForEach-Object { [pscustomobject]@{ Label = "$($_.Alias)   $($_.HostName)"; Value = $_.Alias } }) }

    $SyncType = {
        $F.FRemoteBox.Visibility = $(if ($F.FTypeD.IsChecked) { "Hidden" } else { "Visible" })
        $F.FLocalCap.Text = $(if ($F.FTypeR.IsChecked) { "ПОРТ НА ХОСТЕ" } else { "ЛОКАЛЬНЫЙ ПОРТ" })
        $F.FRemoteCap.Text = $(if ($F.FTypeR.IsChecked) { "КУДА (ХОСТ:ПОРТ, КАК ВИДИТ ЭТОТ ПК)" } else { "КУДА (ХОСТ:ПОРТ, КАК ВИДИТ СЕРВЕР)" })
    }
    foreach ($R in @($F.FTypeL, $F.FTypeD, $F.FTypeR)) { $R.Add_Checked($SyncType) }

    if ($T) {
        $F.FName.Text = $T.Name; $F.FHost.Text = $T.Host; $F.FLocal.Text = "$($T.Local)"; $F.FRemote.Text = "$($T.Remote)"; $F.FAuto.IsChecked = [bool]$T.Auto
        switch ("$($T.Type)") { "D" { $F.FTypeD.IsChecked = $true } "R" { $F.FTypeR.IsChecked = $true } default { $F.FTypeL.IsChecked = $true } }
    } elseif ($script:Hosts.Count) {
        $H0 = Get-SelectedHost
        if ($H0) { $F.FHost.Text = $H0.Alias }
    }
    & $SyncType

    $F.FOk.Add_Click({
        $Type = if ($F.FTypeD.IsChecked) { "D" } elseif ($F.FTypeR.IsChecked) { "R" } else { "L" }
        $Name = $F.FName.Text.Trim(); $HostV = $F.FHost.Text.Trim(); $Local = $F.FLocal.Text.Trim(); $Remote = $F.FRemote.Text.Trim()
        $Err = $null
        if (-not $HostV) { $Err = "Укажи хост из config" }
        elseif ($Local -notmatch '^\d+$' -or [int]$Local -lt 1 -or [int]$Local -gt 65535) { $Err = "Порт — число 1–65535" }
        elseif ($Type -ne "D" -and $Remote -notmatch '^[^\s:]+:\d+$') { $Err = "Куда — в виде хост:порт" }
        if ($Err) { $F.FError.Text = $Err; $F.FError.Visibility = "Visible"; return }
        if (-not $Name) { $Name = switch ($Type) { "D" { "SOCKS :$Local через $HostV" } default { "$Local → $Remote" } } }
        $D.Tag = @{ Name = $Name; Host = $HostV; Type = $Type; Local = [int]$Local; Remote = $(if ($Type -eq "D") { "" } else { $Remote }); Auto = [bool]$F.FAuto.IsChecked }
        $D.DialogResult = $true
    })
    $D.Add_ContentRendered({ [void]$F.FName.Focus() })
    if (-not $D.ShowDialog()) { return $null }

    $R = $D.Tag
    $List = @(Get-Tunnels)
    if ($IsNew) {
        $R.Id = [guid]::NewGuid().ToString("N").Substring(0, 8)
        $List += $R
    } else {
        $R.Id = $T.Id
        $List = @($List | ForEach-Object { if ($_.Id -eq $T.Id) { $R } else { $_ } })
    }
    $script:Settings.Tunnels = $List
    Save-Settings
    Refresh-Tunnels
    return $R
}

function Remove-Tunnel {
    param($T)
    if (-not (Show-Confirm "Удалить туннель «$($T.Name)»?" (Get-TunnelMapping $T) "Удалить" -Danger)) { return }
    Stop-Tunnel $T -Quiet
    $script:Settings.Tunnels = @(Get-Tunnels | Where-Object { $_.Id -ne $T.Id })
    Save-Settings
    Refresh-Tunnels
    Show-Toast "Туннель удалён"
}

function Invoke-TunnelAction {
    param([string]$Spec)
    $Op, $Id = $Spec -split ':', 2
    $T = @(Get-Tunnels) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $T) { return }
    switch ($Op) {
        "toggle" { if (Test-TunnelRunning $T.Id) { Stop-Tunnel $T } else { Start-Tunnel $T } }
        "open"   { Start-Process "http://localhost:$($T.Local)" }
        "edit"   { [void](Show-TunnelDialog $T) }
        "del"    { Remove-Tunnel $T }
    }
}

function Get-SelectedTunnel {
    $R = $Ui.TunnelList.SelectedItem
    if ($R) { return $R.Tunnel }
    return $null
}

function Initialize-TunnelsPage {
    Remove-StaleTunnels
    $Ui.TunnelList.ItemsSource = $script:TunnelItems
    $Ui.TunnelAdd.Add_Click({ $T = Show-TunnelDialog; if ($T) { Start-Tunnel $T } })
    $Ui.TunnelList.Add_MouseDoubleClick({ $T = Get-SelectedTunnel; if ($T) { Invoke-TunnelAction "toggle:$($T.Id)" } })
    $Ui.TunnelList.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Запустить / остановить" 0xE768 { $T = Get-SelectedTunnel; if ($T) { Invoke-TunnelAction "toggle:$($T.Id)" } } "2×клик")
        (New-MenuItem "Открыть http://localhost:порт" 0xE774 { $T = Get-SelectedTunnel; if ($T) { Invoke-TunnelAction "open:$($T.Id)" } })
        (New-MenuItem "Открыть https://localhost:порт" 0xE774 { $T = Get-SelectedTunnel; if ($T) { Start-Process "https://localhost:$($T.Local)" } })
        "-"
        (New-MenuItem "Изменить…" 0xE70F { $T = Get-SelectedTunnel; if ($T) { Invoke-TunnelAction "edit:$($T.Id)" } })
        (New-MenuItem "Копировать команду ssh" 0xE8C8 { $T = Get-SelectedTunnel; if ($T) { Copy-Text "ssh $(Get-TunnelSshArgs $T)" "команда ssh" } })
        (New-MenuItem "Запустить в терминале (видно вывод)" 0xE756 { $T = Get-SelectedTunnel; if ($T) { Start-Terminal "ssh -v $((Get-TunnelSshArgs $T) -replace '-o BatchMode=yes ', '')" "tunnel: $($T.Name)" } })
        "-"
        (New-MenuItem "Удалить…" 0xE74D { $T = Get-SelectedTunnel; if ($T) { Remove-Tunnel $T } } "Del" "Fail")
    )
    Refresh-Tunnels
}
