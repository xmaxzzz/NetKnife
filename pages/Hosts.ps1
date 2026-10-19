# Pages: SSH hosts + keys.

$script:Hosts = @()
$script:Keys = @()
$script:Status = @{}       # alias -> @{ Kind; Text; Detail }
$script:Web = @{}          # alias -> @{ Ip; Ports; Fake }
$script:IpToAlias = @{}
$script:HostItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:KeyItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:EngineProcs = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

# ---------------------------------------------------------------- rows

function Get-AvatarText {
    param([string]$Name)
    if ($Name -match '^\d') { return $null }
    $Parts = @($Name -split '[-._@]' | Where-Object { $_ })
    if ($Parts.Count -ge 2) { return ($Parts[0].Substring(0, 1) + $Parts[1].Substring(0, 1)).ToUpper() }
    return $Name.Substring(0, 1).ToUpper()
}

function New-HostRow {
    param($H)

    $Addr = $H.HostName
    if ($H.User) { $Addr = "$($H.User)@$Addr" }
    if ($H.Port -and $H.Port -ne "22") { $Addr += ":$($H.Port)" }

    $KeyName = "id_ed25519"; $Missing = $false
    if ($H.IdentityFile) {
        $KeyName = [System.IO.Path]::GetFileName($H.IdentityFile)
        $Missing = -not (Test-Path $H.IdentityFile)
    }

    $Av = Get-AvatarText $H.Alias
    $Brushes = Get-AvatarBrushes $H.Alias
    $St = $script:Status[$H.Alias]

    $Badges = @()
    $W = $script:Web[$H.Alias]
    if ($W) {
        $Badges = @(New-PortBadges -Ip $W.Ip -Ports $W.Ports -HostName $H.HostName)
        if ($W.Fake) { $Badges += [pscustomobject]@{ Text = "fake-ip"; Kind = "warn"; Tag = "copy:$($W.Ip)"; Tip = "DNS вернул fake-ip $($W.Ip): порты отвечает прокси/туннель, а не сервер" } }
    }

    return [pscustomobject]@{
        Alias = $H.Alias; Address = $Addr; KeyName = $KeyName; KeyMissing = $Missing
        Jump = $H.ProxyJump; HasJump = [bool]$H.ProxyJump
        Avatar = $(if ($Av) { $Av } else { [string][char]0xE968 })
        AvatarFont = $(if ($Av) { "Segoe UI Variable Display" } else { "Segoe Fluent Icons" })
        AvatarBg = $Brushes[0]; AvatarFg = $Brushes[1]
        StatusKind = $(if ($St) { $St.Kind } else { "none" })
        StatusText = $(if ($St) { $St.Text } else { "" })
        Fav = (@($script:Settings.Favorites) -contains $H.Alias)
        Badges = $Badges
        Host = $H
    }
}

function New-KeyRow {
    param($K)
    $Brushes = Get-AvatarBrushes $K.Name
    $UsedCount = @($K.UsedBy).Count
    return [pscustomobject]@{
        Name = $K.Name
        Sub = $(if ($K.Comment) { $K.Comment } else { $K.Path })
        TypeText = $(if ($K.Type) { $K.Type } else { "?" })
        UsedText = $(if ($UsedCount) { Get-Plural $UsedCount "хост" "хоста" "хостов" } else { "не используется" })
        Unused = ($UsedCount -eq 0)
        Problem = ($K.Problems -join ", "); HasProblem = (@($K.Problems).Count -gt 0)
        AvatarBg = $Brushes[0]; AvatarFg = $Brushes[1]
        Key = $K
    }
}

function Update-HostRow {
    param([string]$Alias)
    for ($i = 0; $i -lt $script:HostItems.Count; $i++) {
        $Old = $script:HostItems[$i]
        if ($Old.Alias -ne $Alias) { continue }
        $WasSelected = $Ui.HostList.SelectedItems.Contains($Old)
        $New = New-HostRow $Old.Host
        $script:HostItems[$i] = $New
        if ($WasSelected) {
            [void]$Ui.HostList.SelectedItems.Add($New)
            if ($Ui.HostList.SelectedItems.Count -eq 1) { $Ui.HostList.SelectedItem = $New }
            Update-HostDetails
        }
        return
    }
}

# ---------------------------------------------------------------- load

function Refresh-Ssh {
    $SelHost = $null; $SelKey = $null
    if ($Ui.HostList.SelectedItem) { $SelHost = $Ui.HostList.SelectedItem.Alias }
    if ($Ui.KeyList.SelectedItem) { $SelKey = $Ui.KeyList.SelectedItem.Key.Path }

    $script:Hosts = @(Get-SshHosts)
    $script:Keys = @(Get-SshKeys $script:Hosts)

    $script:HostItems.Clear()
    $Favs = @($script:Settings.Favorites)
    $Ordered = @($script:Hosts | Where-Object { $Favs -contains $_.Alias }) + @($script:Hosts | Where-Object { $Favs -notcontains $_.Alias })
    foreach ($H in $Ordered) { $script:HostItems.Add((New-HostRow $H)) }
    $script:KeyItems.Clear()
    foreach ($K in $script:Keys) { $script:KeyItems.Add((New-KeyRow $K)) }

    $Ui.NavHosts.Tag = "$($script:Hosts.Count)"
    $Ui.NavKeys.Tag = "$($script:Keys.Count)"

    $H = $script:HostItems | Where-Object { $_.Alias -eq $SelHost } | Select-Object -First 1
    if (-not $H -and $script:HostItems.Count) { $H = $script:HostItems[0] }
    $Ui.HostList.SelectedItem = $H
    $K = $script:KeyItems | Where-Object { $_.Key.Path -eq $SelKey } | Select-Object -First 1
    if (-not $K -and $script:KeyItems.Count) { $K = $script:KeyItems[0] }
    $Ui.KeyList.SelectedItem = $K

    Update-HostDetails
    Update-KeyDetails
    Update-PageSub
}

function Get-HostsSub {
    $Ok = @($script:Status.Values | Where-Object { $_.Kind -eq "ok" }).Count
    $Fail = @($script:Status.Values | Where-Object { $_.Kind -eq "fail" }).Count
    $S = Get-Plural $script:Hosts.Count "хост" "хоста" "хостов"
    if ($Ok -or $Fail) { $S += " · $Ok доступны · $Fail с ошибкой" }
    $Missing = @($script:HostItems | Where-Object { $_.KeyMissing }).Count
    if ($Missing) { $S += " · $Missing без файла ключа" }
    return $S
}

function Get-KeysSub {
    $Unused = @($script:KeyItems | Where-Object { $_.Unused }).Count
    $S = Get-Plural $script:Keys.Count "ключ" "ключа" "ключей"
    if ($Unused) { $S += " · $Unused не используются" }
    return "$S · $($script:SshDir)"
}

# ---------------------------------------------------------------- details

function Get-SelectedHost {
    $R = $Ui.HostList.SelectedItem
    if ($R) { return $R.Host }
    return $null
}

function Get-FirstInView {
    param($View)
    foreach ($X in $View) { return $X }
    return $null
}

function Get-SelectedAliases {
    return @($Ui.HostList.SelectedItems | ForEach-Object { $_.Alias })
}

function Get-SelectedKey {
    $R = $Ui.KeyList.SelectedItem
    if ($R) { return $R.Key }
    return $null
}

function Set-StatusPill {
    param($Pill, $TextBlock, [string]$Kind, [string]$Text)
    $TextBlock.Text = $Text
    switch ($Kind) {
        "ok"   { $Pill.Background = Get-Brush "OkSoft";   $Pill.BorderBrush = $Pill.Background; $TextBlock.Foreground = Get-Brush "Ok" }
        "fail" { $Pill.Background = Get-Brush "FailSoft"; $Pill.BorderBrush = $Pill.Background; $TextBlock.Foreground = Get-Brush "Fail" }
        "wait" { $Pill.Background = Get-Brush "WarnSoft"; $Pill.BorderBrush = $Pill.Background; $TextBlock.Foreground = Get-Brush "Warn" }
        default { $Pill.Background = Get-Brush "Chip";    $Pill.BorderBrush = Get-Brush "Line"; $TextBlock.Foreground = Get-Brush "Sub" }
    }
}

function Update-HostDetails {
    $Row = $Ui.HostList.SelectedItem
    $Ui.HostDetails.Visibility = $(if ($Row) { "Visible" } else { "Hidden" })
    if (-not $Row) { return }
    $H = $Row.Host
    $K = Find-KeyForHost $H

    $Ui.HdAvatarBg.Background = ConvertTo-Brush $Row.AvatarBg
    $Ui.HdAvatar.Text = $Row.Avatar
    $Ui.HdAvatar.FontFamily = New-Object System.Windows.Media.FontFamily $Row.AvatarFont
    $Ui.HdAvatar.Foreground = ConvertTo-Brush $Row.AvatarFg
    $Ui.HdAlias.Text = $H.Alias
    $Ui.HdAddress.Text = $Row.Address + $(if ($H.ProxyJump) { "  через $($H.ProxyJump)" } else { "" })

    $St = $script:Status[$H.Alias]
    if ($St) { Set-StatusPill $Ui.HdStatusPill $Ui.HdStatus $St.Kind $(if ($St.Kind -eq "ok") { "SSH работает · $($St.Text)" } elseif ($St.Kind -eq "fail") { "SSH: $($St.Text)" } else { "проверка…" }) }
    else { Set-StatusPill $Ui.HdStatusPill $Ui.HdStatus "none" "не проверялся" }
    $Ui.HdBadges.ItemsSource = $Row.Badges

    $Mark = ""
    if (-not (Test-Path $K.Path)) { $Mark = "   — файла нет!" } elseif (-not $H.IdentityFile) { $Mark = "   (по умолчанию)" }
    $Ui.HdKeyPath.Text = "$($K.Path)$Mark"
    $Ui.HdKeyPath.Foreground = $(if ($Mark -like "*нет*") { Get-Brush "Fail" } else { Get-Brush "Text" })
    $Ui.HdFp.Text = $(if ($K.Fingerprint) { $K.Fingerprint } else { "—" })
    $Ui.HdPub.Text = $(if ($K.PubText) { $K.PubText } else { "нет .pub файла" })
    $Ui.HdCfg.Text = "$(Get-ConfigBlock $H.Alias)" -replace "`r?`n", "`r`n"

    if ($St -and $St.Kind -eq "fail" -and $St.Detail) {
        $Ui.HdFailBox.Visibility = "Visible"
        $Ui.HdFail.Text = $St.Detail
        $Ui.HdFixKey.Visibility = $(if (Test-HostKeyChanged $St) { "Visible" } else { "Collapsed" })
    } else {
        $Ui.HdFailBox.Visibility = "Collapsed"
    }
}

function Test-HostKeyChanged {
    param($St)
    return [bool]($St -and $St.Kind -eq "fail" -and $St.Text -eq "ключ хоста изменился")
}

# ---------------------------------------------------------------- favorites / edit / host key

function Toggle-Favorite {
    param([string]$Alias)
    $Favs = @($script:Settings.Favorites | Where-Object { $_ })
    if ($Favs -contains $Alias) { $Favs = @($Favs | Where-Object { $_ -ne $Alias }); $Msg = "$Alias убран из избранного" }
    else { $Favs = @($Favs) + @($Alias); $Msg = "$Alias в избранном" }
    $script:Settings.Favorites = $Favs
    Save-Settings
    Refresh-Ssh
    Show-Toast $Msg "info"
}

function Repair-HostKey {
    param($H)
    $St = $script:Status[$H.Alias]
    $Old = @(Get-KnownHostFingerprints $H)
    $New = ""; $Extra = @()
    if ($St -and $St.Detail -match '(?s)fingerprint for the (\S+) key sent by the remote host is\s*(SHA256:\S+?)\.?\s') { $New = "$($Matches[1])  $($Matches[2])" }
    if ($St -and $St.Detail -match "IP address '([^']+)'") { $Extra += $Matches[1] }

    $Detail = "Сейчас в known_hosts:`n" + $(if ($Old) { ($Old | ForEach-Object { "  $_" }) -join "`n" } else { "  (записей для $($H.HostName) нет)" })
    $Detail += "`n`nСервер прислал:`n  " + $(if ($New) { $New } else { "(не удалось разобрать из вывода ssh)" })
    $Msg = "Если сервер переустанавливали или менял ключ сам — это нормально. Если нет, кто-то может подменять соединение. Старая запись удалится, новый ключ примется при следующей проверке."
    if (-not (Show-Confirm "Новый ключ хоста · $($H.Alias)" $Msg "Принять новый ключ" -Danger -Detail $Detail)) { return }

    $N = Remove-KnownHostEntries $H $Extra
    Show-Toast "known_hosts: удалено записей — $N. Проверяю заново…" "info"
    Start-SshTest @($H.Alias)
}

function Show-EditHostDialog {
    param($H)
    if ($H.Shared) { Show-Toast "Host-строка с несколькими алиасами — правь config вручную" "warn"; return }

    $D = New-Dialog "Изменить · $($H.Alias)" @"
<StackPanel>
    <TextBlock Text="Изменить $($H.Alias)" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="Меняются только эти поля; остальные опции блока (LocalForward, IdentitiesOnly…) остаются. Перед записью — бэкап config." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,16" FontSize="12.5"/>
    <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="ХОСТ / IP" Style="{StaticResource Caption}"/><TextBox x:Name="FHost" Style="{StaticResource MonoField}"/></StackPanel>
        <StackPanel Grid.Column="2"><TextBlock Text="ПОРТ" Style="{StaticResource Caption}"/><TextBox x:Name="FPort" Style="{StaticResource MonoField}"/></StackPanel>
    </Grid>
    <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="ПОЛЬЗОВАТЕЛЬ" Style="{StaticResource Caption}"/><TextBox x:Name="FUser" Style="{StaticResource MonoField}"/></StackPanel>
        <StackPanel Grid.Column="2">
            <TextBlock Text="PROXYJUMP" Style="{StaticResource Caption}"/>
            <DockPanel><Button x:Name="FJumpPick" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" Content="&#xE70D;" Width="30" Height="36" Margin="4,0,0,0"/><TextBox x:Name="FJump" Style="{StaticResource MonoField}" Tag="пусто — напрямую"/></DockPanel>
        </StackPanel>
    </Grid>
    <TextBlock Text="КЛЮЧ (IDENTITYFILE)" Style="{StaticResource Caption}" Margin="2,12,0,6"/>
    <DockPanel><Button x:Name="FKeyPick" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" Content="&#xE70D;" Width="30" Height="36" Margin="4,0,0,0"/><TextBox x:Name="FKey" Style="{StaticResource MonoField}" Tag="пусто — ключ по умолчанию (id_ed25519)"/></DockPanel>
    <TextBlock x:Name="FError" Foreground="{StaticResource Fail}" FontSize="12" Margin="2,6,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button x:Name="FCancel" Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" MinWidth="130" Margin="8,0,0,0" IsDefault="True">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74E;" Style="{StaticResource Glyph}"/><TextBlock Text="Сохранить"/></StackPanel>
        </Button>
    </StackPanel>
</StackPanel>
"@ 520

    $F = @{}
    foreach ($N in @("FHost", "FPort", "FUser", "FJump", "FJumpPick", "FKey", "FKeyPick", "FError", "FOk")) { $F[$N] = $D.FindName($N) }
    $F.FHost.Text = $H.HostName
    $F.FPort.Text = $H.Port
    $F.FUser.Text = $H.User
    $F.FJump.Text = $H.ProxyJump
    if ($H.IdentityFile) {
        $F.FKey.Text = $(if ($H.IdentityFile.StartsWith($script:SshDir, [StringComparison]::OrdinalIgnoreCase)) { [IO.Path]::GetFileName($H.IdentityFile) } else { $H.IdentityFile })
    }

    $Alias = $H.Alias
    Add-PickMenu $F.FKeyPick $F.FKey { @([pscustomobject]@{ Label = "по умолчанию (id_ed25519)"; Value = "" }) + @($script:Keys | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Label = "$($_.Name)   $($_.Comment)"; Value = $_.Name } }) }
    Add-PickMenu $F.FJumpPick $F.FJump { @([pscustomobject]@{ Label = "напрямую"; Value = "" }) + @($script:Hosts | Where-Object { $_.Alias -ne $Alias } | ForEach-Object { [pscustomobject]@{ Label = "$($_.Alias)   $($_.HostName)"; Value = $_.Alias } }) }

    $F.FOk.Add_Click({
        $HostV = $F.FHost.Text.Trim(); $PortV = $F.FPort.Text.Trim(); $KeyV = $F.FKey.Text.Trim()
        $Err = $null
        if (-not $HostV) { $Err = "Хост пустой" }
        elseif ($PortV -and $PortV -notmatch '^\d+$') { $Err = "Порт — число" }
        if ($Err) { $F.FError.Text = $Err; $F.FError.Visibility = "Visible"; return }
        if ($KeyV -and $KeyV -notmatch '[\\/]') { $KeyV = Join-Path $script:SshDir $KeyV }
        if ($KeyV -and -not (Test-Path (Resolve-SshPath $KeyV))) {
            if (-not (Show-Confirm "Файла ключа нет" "$KeyV не найден. Записать всё равно?" "Записать")) { return }
        }
        $D.Tag = @{
            HostName = $HostV; User = $F.FUser.Text.Trim()
            Port = $(if ($PortV -and $PortV -ne "22") { $PortV } else { "" })
            ProxyJump = $F.FJump.Text.Trim()
            IdentityFile = (Get-IdentityFileValue $KeyV)
        }
        $D.DialogResult = $true
    })
    $D.Add_ContentRendered({ [void]$F.FHost.Focus(); $F.FHost.SelectAll() })
    if (-not $D.ShowDialog()) { return }

    try {
        $Backup = Set-HostConfigOptions $H.Alias $D.Tag
        Refresh-Ssh
        Show-Toast "$($H.Alias) обновлён · бэкап $([IO.Path]::GetFileName($Backup))"
    } catch {
        Show-Toast "Не записал: $($_.Exception.Message)" "fail"
    }
}

function Update-KeyDetails {
    $Row = $Ui.KeyList.SelectedItem
    $Ui.KeyDetails.Visibility = $(if ($Row) { "Visible" } else { "Hidden" })
    if (-not $Row) { return }
    $K = $Row.Key

    $Ui.KdAvatarBg.Background = ConvertTo-Brush $Row.AvatarBg
    $Ui.KdAvatar.Foreground = ConvertTo-Brush $Row.AvatarFg
    $Ui.KdName.Text = $K.Name
    $Ui.KdType.Text = (@($K.Type, $K.Comment) | Where-Object { $_ }) -join "  ·  "
    $Ui.KdFiles.Text = "$($K.Path)$(if (-not (Test-Path $K.Path)) { '  — нет' })`n$($K.PubPath)$(if (-not (Test-Path $K.PubPath)) { '  — нет' })"
    $Ui.KdFpText.Text = $(if ($K.Fingerprint) { $K.Fingerprint } else { "—" })
    $Ui.KdPub.Text = $(if ($K.PubText) { $K.PubText } else { "нет .pub — «Ещё» → восстановить из приватного" })

    $Ui.KdHosts.Children.Clear()
    foreach ($A in @($K.UsedBy)) {
        $B = New-Object System.Windows.Controls.Button
        $B.Style = $script:Win.FindResource("ChipBtn")
        $B.Content = $A
        $B.Tag = "host:$A"
        [void]$Ui.KdHosts.Children.Add($B)
    }
    $Ui.KdNoHosts.Visibility = $(if (@($K.UsedBy).Count) { "Collapsed" } else { "Visible" })
}

# ---------------------------------------------------------------- actions

function Get-SshFailReason {
    param([string]$Text)
    switch -Regex ($Text) {
        'Host key verification failed|REMOTE HOST IDENTIFICATION' { return "ключ хоста изменился" }
        'Permission denied'                    { return "нет доступа по ключу" }
        'timed out'                            { return "таймаут" }
        'Connection refused'                   { return "порт закрыт" }
        'Could not resolve|Name or service'    { return "имя не резолвится" }
        'No route|unreachable'                 { return "нет маршрута" }
        'banner exchange|kex_exchange|Connection closed|reset by peer' { return "SSH не ответил" }
        'Too many authentication'              { return "много ключей" }
        "Identity file .* not accessible|no such identity" { return "нет файла ключа" }
    }
    return "ошибка"
}

$script:SshTestBody = {
    param($Q, $Ctl, $Aliases)
    $Queue = [System.Collections.Queue]::new()
    foreach ($A in $Aliases) { $Queue.Enqueue($A) }
    $Running = @{}
    while (($Queue.Count -gt 0 -or $Running.Count -gt 0) -and -not $Ctl.Stop) {
        while ($Running.Count -lt 12 -and $Queue.Count -gt 0) {
            $A = $Queue.Dequeue()
            $Psi = New-Object System.Diagnostics.ProcessStartInfo "ssh.exe"
            $Psi.Arguments = "-o BatchMode=yes -o ConnectTimeout=7 -o StrictHostKeyChecking=accept-new `"$A`" `"echo SSH_TEST_OK`""
            $Psi.RedirectStandardOutput = $true; $Psi.RedirectStandardError = $true
            $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true
            $P = [System.Diagnostics.Process]::Start($Psi)
            $Running[$A] = @{ P = $P; Out = $P.StandardOutput.ReadToEndAsync(); Err = $P.StandardError.ReadToEndAsync(); Sw = [System.Diagnostics.Stopwatch]::StartNew() }
        }
        foreach ($A in @($Running.Keys)) {
            $R = $Running[$A]
            if (-not $R.P.HasExited -and $R.Sw.ElapsedMilliseconds -lt 20000) { continue }
            if (-not $R.P.HasExited) { try { $R.P.Kill() } catch { } }
            [void]$R.Out.Wait(1000); [void]$R.Err.Wait(1000)
            $Text = "$($R.Out.Result)$($R.Err.Result)".Trim()
            $Q.Enqueue(@{ Type = "ssh"; Alias = $A; Code = $R.P.ExitCode; Ms = $R.Sw.ElapsedMilliseconds; Out = $Text })
            $Running.Remove($A)
        }
        Start-Sleep -Milliseconds 60
    }
}

function Start-SshTest {
    param([string[]]$Aliases)
    if (-not $Aliases) { return }
    foreach ($A in $Aliases) {
        $script:Status[$A] = @{ Kind = "wait"; Text = "…"; Detail = "" }
        Update-HostRow $A
    }
    [void](Start-Worker -Name "ssh-$([guid]::NewGuid())" -Body $script:SshTestBody -ArgList @(, $Aliases) -OnMessage {
        param($M)
        if ($M.Type -ne "ssh") { return }
        if ($M.Code -eq 0 -and $M.Out -match "SSH_TEST_OK") {
            $script:Status[$M.Alias] = @{ Kind = "ok"; Text = "$($M.Ms) мс"; Detail = "" }
        } else {
            $script:Status[$M.Alias] = @{ Kind = "fail"; Text = (Get-SshFailReason $M.Out); Detail = $M.Out }
        }
        Update-HostRow $M.Alias
        Update-PageSub
    } -OnDone {
        if (-not ($script:Status.Values | Where-Object { $_.Kind -eq "wait" })) {
            $Ok = @($script:Status.Values | Where-Object { $_.Kind -eq "ok" }).Count
            Show-Toast "Проверка SSH завершена: $Ok из $($script:Status.Count) доступны"
        }
    })
}

$script:WebProbeBody = {
    param($Q, $Ctl, $Targets, $LocalNets)
    $Resolved = @()
    foreach ($T in $Targets) {
        if ($Ctl.Stop) { return }
        $Ip = $null
        if ($T.HostName -match '^\d{1,3}(\.\d{1,3}){3}$') { $Ip = $T.HostName }
        else {
            try {
                $Task = [System.Net.Dns]::GetHostAddressesAsync($T.HostName)
                if ($Task.Wait(2500)) { $Ip = ($Task.Result | Where-Object { $_.AddressFamily -eq "InterNetwork" } | Select-Object -First 1).ToString() }
            } catch { }
        }
        if ($Ip) { $Resolved += [pscustomobject]@{ Alias = $T.Alias; Ip = $Ip } }
    }
    $Probe = foreach ($R in $Resolved) { foreach ($P in @(80, 443)) { [pscustomobject]@{ Ip = $R.Ip; Port = $P; Alias = $R.Alias } } }
    $Open = @()
    if ($Probe) { $Open = Test-TcpBatch @($Probe) 1800 $LocalNets }
    foreach ($R in $Resolved) {
        $Ports = @($Open | Where-Object { $_.Alias -eq $R.Alias } | ForEach-Object { [int]$_.Port })
        $Q.Enqueue(@{ Type = "web"; Alias = $R.Alias; Ip = $R.Ip; Ports = $Ports; Fake = (Test-FakeIp $R.Ip) })
    }
}

function Start-WebProbe {
    $Targets = @($script:Hosts | Where-Object { -not $_.ProxyJump } | ForEach-Object { [pscustomobject]@{ Alias = $_.Alias; HostName = $_.HostName } })
    [void](Start-Worker -Name "web" -Replace -Body $script:WebProbeBody -ArgList @(@(, $Targets) + @(, $script:LocalNets)) -OnMessage {
        param($M)
        if ($M.Type -ne "web") { return }
        $script:Web[$M.Alias] = @{ Ip = $M.Ip; Ports = [int[]]@($M.Ports); Fake = $M.Fake }
        $script:IpToAlias[$M.Ip] = $M.Alias
        Update-HostRow $M.Alias
    } -OnDone {
        $N = @($script:Web.Values | Where-Object { $_.Ports.Count }).Count
        if ($script:WebProbeManual) { Show-Toast "Web-проверка: у $N хостов открыт HTTP/HTTPS" }
        $script:WebProbeManual = $false
    })
}

function Remove-HostBlock {
    param($H)
    if ($H.Shared) { Show-Toast "Host-строка с несколькими алиасами — правь config вручную" "warn"; return }
    $Block = Get-ConfigBlock $H.Alias
    if (-not $Block) { return }
    if (-not (Show-Confirm "Удалить $($H.Alias)?" "Блок уйдёт из ~/.ssh/config, перед этим сделаю бэкап. Ключ не удаляется." "Удалить" -Danger -Detail $Block)) { return }
    $Backup = Backup-Config
    $Config = Get-Content $script:ConfigPath -Raw
    $Pattern = "(?ms)^Host\s+$([regex]::Escape($H.Alias))\s*\r?\n.*?(?=^Host\s+|^Match\s+|\z)"
    $Config = [regex]::new($Pattern).Replace($Config, "", 1)
    Set-Content -Path $script:ConfigPath -Value $Config -Encoding UTF8 -NoNewline
    Refresh-Ssh
    Show-Toast "Удалён $($H.Alias) · бэкап $([IO.Path]::GetFileName($Backup))"
}

function Remove-KeyFiles {
    param($K)
    $Msg = "Файлы ключа и .pub уйдут в корзину."
    if (@($K.UsedBy).Count) { $Msg += " Внимание: ключ используется хостами — $($K.UsedBy -join ', ')." }
    if (-not (Show-Confirm "Удалить ключ $($K.Name)?" $Msg "В корзину" -Danger)) { return }
    foreach ($P in @($K.Path, $K.PubPath)) {
        if (Test-Path $P) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($P, "OnlyErrorDialogs", "SendToRecycleBin") }
    }
    Refresh-Ssh
    Show-Toast "Ключ $($K.Name) в корзине"
}

function Restore-PubKey {
    param($K)
    if (-not (Test-Path $K.Path)) { Show-Toast "Нет приватного ключа" "fail"; return }
    $Out = & ssh-keygen.exe -y -P "" -f $K.Path 2>&1
    if ($LASTEXITCODE -ne 0) { Show-Toast "ssh-keygen -y не смог (ключ с паролем?)" "fail"; return }
    [System.IO.File]::WriteAllText($K.PubPath, "$("$($Out -join '')".Trim()) $($K.Name)`n")
    Refresh-Ssh
    Show-Toast "Восстановлен $([IO.Path]::GetFileName($K.PubPath))"
}

function Show-GoodiesMenu {
    param($Target)
    $H = Get-SelectedHost
    if (-not $H) { return }
    $Items = foreach ($G in @(@("1", "micro"), @("2", "micro + редактор по умолчанию"), @("3", "zsh + oh-my-zsh + p10k + плагины"), @("4", "всё сразу"))) {
        $I = New-MenuItem $G[1] 0xE90F {
            param($S, $E)
            $H2 = Get-SelectedHost
            if ($H2) { Start-Engine -Title "goodies → $($H2.Alias)" -EngineArgs @("-Mode", "4", "-Alias", $H2.Alias, "-Goodies", $S.Tag) }
        }
        $I.Tag = $G[0]
        $I
    }
    Show-Menu $Target $Items
}

function Get-HostMenuItems {
    $H0 = Get-SelectedHost
    $IsFav = $H0 -and (@($script:Settings.Favorites) -contains $H0.Alias)
    $KeyChanged = $H0 -and (Test-HostKeyChanged $script:Status[$H0.Alias])
    $Items = @(
        (New-MenuItem "Подключиться" 0xE756 { $H = Get-SelectedHost; if ($H) { Connect-Host $H.Alias } } "Enter")
        (New-MenuItem "Проверить SSH" 0xE73E { Start-SshTest (Get-SelectedAliases) } "Ctrl+T")
        (New-MenuItem "Пинг" 0xE9D9 { $H = Get-SelectedHost; if ($H) { Start-PingFor $H.HostName } })
        (New-MenuItem "В монитор" 0xE9D2 { foreach ($A in Get-SelectedAliases) { Add-MonTarget $A } })
    )
    if ($KeyChanged) { $Items += (New-MenuItem "Принять новый ключ хоста…" 0xE8D7 { $H = Get-SelectedHost; if ($H) { Repair-HostKey $H } } "" "Warn") }
    $Items += @(
        "-"
        (New-MenuItem "Изменить…" 0xE70F { $H = Get-SelectedHost; if ($H) { Show-EditHostDialog $H } } "Ctrl+E")
        (New-MenuItem $(if ($IsFav) { "Убрать из избранного" } else { "В избранное" }) $(if ($IsFav) { 0xE734 } else { 0xE735 }) { $H = Get-SelectedHost; if ($H) { Toggle-Favorite $H.Alias } } "Ctrl+B")
        "-"
        (New-MenuItem "Порты: стандарт" 0xE839 { $H = Get-SelectedHost; if ($H) { Start-PortScanFor $H.HostName "std" } })
        (New-MenuItem "Порты: расширенный (nmap)" 0xE839 { $H = Get-SelectedHost; if ($H) { Start-PortScanFor $H.HostName "ext" -Nmap } })
        (New-MenuItem "Порты: настроить…" 0xE713 { $H = Get-SelectedHost; if ($H) { Open-PortsFor $H.HostName } })
        "-"
        (New-MenuItem "Копировать публичный ключ" 0xE8C8 { $H = Get-SelectedHost; if ($H) { $K = Find-KeyForHost $H; Copy-Text $K.PubText "ключ $($K.Name)" } } "Ctrl+C")
        (New-MenuItem "Копировать команду установки" 0xE943 { $H = Get-SelectedHost; if ($H) { Copy-Text (Get-InstallCommand (Find-KeyForHost $H).PubText) "команда установки" } })
        (New-MenuItem "Копировать ssh-copy-id (PowerShell)" 0xE943 { $H = Get-SelectedHost; if ($H) { Copy-Text (Get-CopyIdCommand $H (Find-KeyForHost $H)) "ssh-copy-id" } })
        (New-MenuItem "Копировать адрес" 0xE8C8 { $H = Get-SelectedHost; if ($H) { Copy-Text $H.HostName $H.HostName } })
        "-"
        (New-MenuItem "Отправить файлы (scp)…" 0xE898 { $H = Get-SelectedHost; if ($H) { Show-SendFilesDialog $H } })
        (New-MenuItem "Туннель через этот хост…" 0xE8AB { $T = Show-TunnelDialog; if ($T) { Set-Page "tunnels"; Start-Tunnel $T } })
        "-"
        (New-MenuItem "Новый сервер…" 0xE710 { Show-NewServerDialog })
        (New-MenuItem "Установить ключ по паролю…" 0xE72E { $H = Get-SelectedHost; if ($H) { Show-NewServerDialog $H } })
        (New-MenuItem "Удалить из config…" 0xE74D { $H = Get-SelectedHost; if ($H) { Remove-HostBlock $H } } "Del" "Fail")
    )
    return $Items
}

function Set-DynamicContextMenu {
    param($List, [scriptblock]$GetItems)
    $M = New-ContextMenu @()
    $List.ContextMenu = $M
    $List.Add_ContextMenuOpening({
        $M.Items.Clear()
        foreach ($I in @(& $GetItems)) {
            if ($I -eq "-") { [void]$M.Items.Add((New-Object System.Windows.Controls.Separator)) } else { [void]$M.Items.Add($I) }
        }
    })
}

function Get-KeyMenuItems {
    return @(
        (New-MenuItem "Копировать публичный ключ" 0xE8C8 { $K = Get-SelectedKey; if ($K) { Copy-Text $K.PubText "ключ $($K.Name)" } } "Ctrl+C")
        (New-MenuItem "Команда для OpenSSH" 0xE943 { $K = Get-SelectedKey; if ($K) { Copy-Text (Get-InstallCommand $K.PubText) "команда OpenSSH" } })
        (New-MenuItem "Команда для Dropbear / OpenWrt" 0xE943 { $K = Get-SelectedKey; if ($K) { Copy-Text (Get-InstallCommand $K.PubText "dropbear") "команда Dropbear" } })
        (New-MenuItem "Копировать fingerprint" 0xE928 { $K = Get-SelectedKey; if ($K) { Copy-Text $K.Fingerprint "fingerprint" } })
        (New-MenuItem "Копировать путь" 0xE8B7 { $K = Get-SelectedKey; if ($K) { Copy-Text $K.Path "путь" } })
        "-"
        (New-MenuItem "Восстановить .pub из приватного" 0xE777 { $K = Get-SelectedKey; if ($K) { Restore-PubKey $K } })
        (New-MenuItem "Показать в проводнике" 0xE838 { $K = Get-SelectedKey; if ($K) { Start-Process explorer.exe -ArgumentList "/select,$(Quote-Arg $K.Path)" } })
        "-"
        (New-MenuItem "Удалить ключ (в корзину)…" 0xE74D { $K = Get-SelectedKey; if ($K) { Remove-KeyFiles $K } } "Del" "Fail")
    )
}

function New-ContextMenu {
    param([object[]]$Items)
    $M = New-Object System.Windows.Controls.ContextMenu
    foreach ($I in $Items) {
        if ($I -eq "-") { [void]$M.Items.Add((New-Object System.Windows.Controls.Separator)) } else { [void]$M.Items.Add($I) }
    }
    return $M
}

# ---------------------------------------------------------------- new server dialog

function Show-NewServerDialog {
    param($Prefill, [switch]$NewHost)

    $Title = if ($Prefill -and -not $NewHost) { "Ключ по паролю · $($Prefill.Alias)" } else { "Новый сервер" }
    $D = New-Dialog $Title @"
<StackPanel>
    <TextBlock Text="$Title" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="Ключ ~/.ssh/&lt;алиас&gt; создаётся, ставится на сервер и записывается в config. ProxyJump и прочие опции существующего блока сохраняются." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,16" FontSize="12.5"/>
    <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="ХОСТ / IP" Style="{StaticResource Caption}"/><TextBox x:Name="FHost" Style="{StaticResource MonoField}" Tag="192.168.1.10 или srv.example.com"/></StackPanel>
        <StackPanel Grid.Column="2"><TextBlock Text="ПОРТ" Style="{StaticResource Caption}"/><TextBox x:Name="FPort" Style="{StaticResource MonoField}" Text="22"/></StackPanel>
    </Grid>
    <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="ПОЛЬЗОВАТЕЛЬ" Style="{StaticResource Caption}"/><TextBox x:Name="FUser" Style="{StaticResource MonoField}" Text="root"/></StackPanel>
        <StackPanel Grid.Column="2"><TextBlock Text="АЛИАС" Style="{StaticResource Caption}"/><TextBox x:Name="FAlias" Style="{StaticResource MonoField}" Tag="как будет ssh &lt;алиас&gt;"/></StackPanel>
    </Grid>
    <TextBlock Text="СПОСОБ" Style="{StaticResource Caption}" Margin="2,16,0,6"/>
    <RadioButton x:Name="FPassword" Style="{StaticResource Option}" GroupName="M" IsChecked="True" Content="По паролю" Tag="Откроется окно, спросит пароль один раз и поставит ключ сам (Posh-SSH)."/>
    <RadioButton x:Name="FManual" Style="{StaticResource Option}" GroupName="M" Content="Вручную" Tag="Ключ попадёт в буфер обмена — вставишь на сервер сам, потом проверка."/>
    <TextBlock x:Name="FError" Foreground="{StaticResource Fail}" FontSize="12" Margin="2,4,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Button x:Name="FCancel" Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" MinWidth="130" Margin="8,0,0,0" IsDefault="True">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE768;" Style="{StaticResource Glyph}"/><TextBlock Text="Запустить"/></StackPanel>
        </Button>
    </StackPanel>
</StackPanel>
"@ 500

    $F = @{}
    foreach ($N in @("FHost", "FPort", "FUser", "FAlias", "FPassword", "FManual", "FError", "FOk")) { $F[$N] = $D.FindName($N) }
    $State = @{ Touched = $false }
    $Existing = @($script:Hosts | ForEach-Object Alias)

    $F.FAlias.Add_PreviewKeyDown({ $State.Touched = $true })
    $F.FHost.Add_TextChanged({ if (-not $State.Touched) { $F.FAlias.Text = $F.FHost.Text.Trim() } })

    if ($Prefill) {
        $F.FHost.Text = $Prefill.HostName
        $F.FPort.Text = $Prefill.Port
        $F.FUser.Text = $(if ($Prefill.User) { $Prefill.User } else { "root" })
        $F.FAlias.Text = $Prefill.Alias
        $F.FAlias.IsReadOnly = -not $NewHost
        $State.Touched = $true
    }

    $F.FOk.Add_Click({
        $Err = $null
        $HostV = $F.FHost.Text.Trim(); $UserV = $F.FUser.Text.Trim(); $PortV = $F.FPort.Text.Trim(); $AliasV = $F.FAlias.Text.Trim()
        if (-not $HostV -or -not $UserV -or -not $AliasV) { $Err = "Заполни хост, пользователя и алиас" }
        elseif ($PortV -notmatch '^\d+$') { $Err = "Порт — число" }
        elseif ($AliasV -match '[\s*?!]') { $Err = "Алиас без пробелов и * ? !" }
        if ($Err) { $F.FError.Text = $Err; $F.FError.Visibility = "Visible"; return }
        if (-not $F.FAlias.IsReadOnly -and ($Existing -contains $AliasV)) {
            if (-not (Show-Confirm "Алиас $AliasV уже есть" "Обновить существующий блок в config новым ключом и адресом?" "Обновить")) { return }
        }
        $D.Tag = @{ Host = $HostV; User = $UserV; Port = $PortV; Alias = $AliasV; Mode = $(if ($F.FPassword.IsChecked) { "1" } else { "2" }) }
        $D.DialogResult = $true
    })

    $D.Add_ContentRendered({ [void]$F.FHost.Focus() })
    if (-not $D.ShowDialog()) { return }
    $R = $D.Tag
    Start-Engine -Title "$($R.Alias)" -EngineArgs @("-Mode", $R.Mode, "-HostName", $R.Host, "-UserName", $R.User, "-Port", $R.Port, "-Alias", $R.Alias)
}

# ---------------------------------------------------------------- snippets (saved commands)

$script:DefaultSnippets = @(
    @{ Name = "Диски"; Cmd = "df -h" }
    @{ Name = "Память и нагрузка"; Cmd = "free -h; echo; uptime" }
    @{ Name = "Docker"; Cmd = "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" }
    @{ Name = "Открытые порты"; Cmd = "ss -tulpn" }
    @{ Name = "Логи системы (100 строк)"; Cmd = "journalctl -n 100 --no-pager" }
    @{ Name = "Обновить систему"; Cmd = "apt update && apt upgrade -y" }
    @{ Name = "Перезагрузить"; Cmd = "reboot" }
)

function Get-Snippets {
    $L = @($script:Settings.Snippets | Where-Object { $_ -and $_.Name -and $_.Cmd })
    if ($L.Count) { return $L }
    return $script:DefaultSnippets
}

function Invoke-Snippet {
    param($S, [string[]]$Aliases)
    foreach ($A in $Aliases) {
        $Ps = "Write-Host $(ConvertTo-PsLiteral "▶ $A › $($S.Cmd)") -ForegroundColor Cyan; " +
              "ssh -t $(ConvertTo-PsLiteral $A) $(ConvertTo-PsLiteral $S.Cmd); " +
              "Write-Host ''; Write-Host ('--- {0}: готово, код {1} ---' -f $(ConvertTo-PsLiteral $S.Name), `$LASTEXITCODE) -ForegroundColor DarkGray"
        Start-TerminalPwsh $Ps "$A › $($S.Name)"
    }
    Show-Toast "«$($S.Name)» → $($Aliases -join ', ')" "info"
}

function Show-SnippetsMenu {
    param($Target)
    $Aliases = Get-SelectedAliases
    if (-not $Aliases) { return }
    $Items = foreach ($S in Get-Snippets) {
        $I = New-MenuItem $S.Name 0xE756
        $I.Tag = @{ S = $S; A = $Aliases }
        $I.ToolTip = $S.Cmd
        $I.Add_Click({ param($S2, $E2) Invoke-Snippet $S2.Tag.S $S2.Tag.A })
        $I
    }
    $Items += "-"
    $Items += (New-MenuItem "Изменить список…" 0xE70F { Show-SnippetsEditor })
    Show-Menu $Target $Items
}

function Show-SnippetsEditor {
    $D = New-Dialog "Команды" @"
<StackPanel>
    <TextBlock Text="Сохранённые команды" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="Одна строка — одна команда: «Название = команда». Строки с # пропускаются. Пустой список вернёт набор по умолчанию." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,12" FontSize="12.5"/>
    <TextBox x:Name="FText" Style="{StaticResource Code}" IsReadOnly="False" AcceptsReturn="True" AcceptsTab="True" Height="300" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" HorizontalScrollBarVisibility="Auto"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button x:Name="FCancel" Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="Сохранить" MinWidth="120" Margin="8,0,0,0"/>
    </StackPanel>
</StackPanel>
"@ 640
    $FText = $D.FindName("FText")
    $FText.Text = ((Get-Snippets | ForEach-Object { "$($_.Name) = $($_.Cmd)" }) -join "`r`n")
    $D.FindName("FOk").Add_Click({
        $List = foreach ($Line in ($FText.Text -split "`r?`n")) {
            $Line = $Line.Trim()
            if (-not $Line -or $Line.StartsWith("#")) { continue }
            if ($Line -match '^([^=]+?)\s*=\s*(.+)$') { @{ Name = $Matches[1].Trim(); Cmd = $Matches[2].Trim() } }
        }
        $script:Settings.Snippets = @($List)
        Save-Settings
        $D.DialogResult = $true
    })
    if ($D.ShowDialog()) { Show-Toast "Команды сохранены: $((Get-Snippets).Count)" }
}

# ---------------------------------------------------------------- send files (scp)

function Show-SendFilesDialog {
    param($H, [string[]]$Files)
    if (-not $Files) { $Files = Show-OpenFiles "Файлы для $($H.Alias)" }
    if (-not $Files) { return }

    $ListText = ($Files | ForEach-Object { $Size = ""; if (Test-Path $_ -PathType Leaf) { $Size = "  ({0:N1} МБ)" -f ((Get-Item $_).Length / 1MB) } elseif (Test-Path $_ -PathType Container) { $Size = "  (папка)" }; "$_$Size" }) -join "`n"
    $Esc = [System.Security.SecurityElement]::Escape($ListText) -replace "`n", "&#10;"
    $D = New-Dialog "Отправить на $($H.Alias)" @"
<StackPanel>
    <TextBlock Text="Отправить на $([System.Security.SecurityElement]::Escape($H.Alias))" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="scp -r в новой вкладке терминала — прогресс и ошибки будут видны там." Foreground="{StaticResource Sub}" Margin="0,6,0,12" FontSize="12.5"/>
    <TextBlock Text="ФАЙЛЫ" Style="{StaticResource Caption}"/>
    <TextBox Style="{StaticResource Code}" Text="$Esc" MaxHeight="160" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto"/>
    <TextBlock Text="КУДА НА СЕРВЕРЕ" Style="{StaticResource Caption}" Margin="2,12,0,6"/>
    <DockPanel><Button x:Name="FDirPick" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" Content="&#xE70D;" Width="30" Height="36" Margin="4,0,0,0"/><TextBox x:Name="FDir" Style="{StaticResource MonoField}" Text="~/"/></DockPanel>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button x:Name="FCancel" Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" MinWidth="130" Margin="8,0,0,0" IsDefault="True">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE898;" Style="{StaticResource Glyph}"/><TextBlock Text="Отправить"/></StackPanel>
        </Button>
    </StackPanel>
</StackPanel>
"@ 560
    $FDir = $D.FindName("FDir")
    Add-PickMenu $D.FindName("FDirPick") $FDir { @("~/", "/tmp/", "/root/", "/opt/", "/etc/", "/var/www/", "/srv/") | ForEach-Object { [pscustomobject]@{ Label = $_; Value = $_ } } }
    $D.FindName("FOk").Add_Click({ if ($FDir.Text.Trim()) { $D.DialogResult = $true } })
    if (-not $D.ShowDialog()) { return }

    $Dir = $FDir.Text.Trim()
    $Args = ($Files | ForEach-Object { ConvertTo-PsLiteral $_ }) -join " "
    $Ps = "Write-Host $(ConvertTo-PsLiteral "▶ scp → $($H.Alias):$Dir") -ForegroundColor Cyan; " +
          "scp -r $Args $(ConvertTo-PsLiteral "$($H.Alias):$Dir"); " +
          "if (`$LASTEXITCODE -eq 0) { Write-Host '--- готово ---' -ForegroundColor Green } else { Write-Host ('--- scp завершился с кодом {0} ---' -f `$LASTEXITCODE) -ForegroundColor Red }"
    Start-TerminalPwsh $Ps "scp → $($H.Alias)"
    Show-Toast "scp: $($Files.Count) → $($H.Alias):$Dir" "info"
}

# ---------------------------------------------------------------- wiring

function Initialize-HostsPage {
    $Ui.HostList.ItemsSource = $script:HostItems
    $Ui.KeyList.ItemsSource = $script:KeyItems

    $script:HostView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:HostItems)
    $script:HostView.Filter = [Predicate[object]]{
        param($R)
        $Q = $Ui.HostSearch.Text.Trim()
        if (-not $Q) { return $true }
        return ("$($R.Alias) $($R.Address) $($R.KeyName) $($R.Jump)" -like "*$Q*")
    }
    $script:KeyView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:KeyItems)
    $script:KeyView.Filter = [Predicate[object]]{
        param($R)
        $Q = $Ui.KeySearch.Text.Trim()
        if (-not $Q) { return $true }
        return ("$($R.Name) $($R.Sub) $($R.Key.UsedBy -join ' ') $($R.Key.Fingerprint)" -like "*$Q*")
    }

    # when the filter hides the selected row, jump to the first visible one
    # Refresh() drops a selection the filter hides, so remember it first and fall back to the first visible row
    $Ui.HostSearch.Add_TextChanged({
        $Sel = $Ui.HostList.SelectedItem
        $script:HostView.Refresh()
        if (-not $Ui.HostList.SelectedItem) {
            if ($Sel -and $script:HostView.Contains($Sel)) { $Ui.HostList.SelectedItem = $Sel }
            else { $Ui.HostList.SelectedItem = Get-FirstInView $script:HostView }
        }
    })
    $Ui.KeySearch.Add_TextChanged({
        $Sel = $Ui.KeyList.SelectedItem
        $script:KeyView.Refresh()
        if (-not $Ui.KeyList.SelectedItem) {
            if ($Sel -and $script:KeyView.Contains($Sel)) { $Ui.KeyList.SelectedItem = $Sel }
            else { $Ui.KeyList.SelectedItem = Get-FirstInView $script:KeyView }
        }
    })

    $Ui.HostList.Add_SelectionChanged({ Update-HostDetails })
    $Ui.KeyList.Add_SelectionChanged({ Update-KeyDetails })
    $Ui.HostList.Add_MouseDoubleClick({ $H = Get-SelectedHost; if ($H) { Connect-Host $H.Alias } })
    $Ui.KeyList.Add_MouseDoubleClick({ $K = Get-SelectedKey; if ($K) { Copy-Text $K.PubText "ключ $($K.Name)" } })

    Set-DynamicContextMenu $Ui.HostList { Get-HostMenuItems }
    $Ui.KeyList.ContextMenu = New-ContextMenu (Get-KeyMenuItems)
    $Ui.HdFixKey.Add_Click({ $H = Get-SelectedHost; if ($H) { Repair-HostKey $H } })

    $Ui.TestAllBtn.Add_Click({ Start-SshTest @($script:Hosts | ForEach-Object Alias) })
    $Ui.WebProbeBtn.Add_Click({ $script:WebProbeManual = $true; Start-WebProbe; Show-Toast "Проверяю HTTP/HTTPS…" "info" })
    $Ui.RefreshBtn.Add_Click({ Refresh-Ssh; Show-Toast "Перечитано" })

    $Ui.HdKeyToggle.Add_Click({
        $On = ($Ui.HdKeyCard.Visibility -ne "Visible")
        $Vis = $(if ($On) { "Visible" } else { "Collapsed" })
        $Ui.HdKeyCard.Visibility = $Vis
        $Ui.HdCfgCard.Visibility = $Vis
        $Ui.HdKeyChevron.Text = $(if ($On) { [char]0xE70D } else { [char]0xE76C })  # chevron down / right
    })

    $Ui.HdConnect.Add_Click({ $H = Get-SelectedHost; if ($H) { Connect-Host $H.Alias } })
    $Ui.HdTest.Add_Click({ Start-SshTest (Get-SelectedAliases) })
    $Ui.HdPorts.Add_Click({ $H = Get-SelectedHost; if ($H) { Open-PortsFor $H.HostName } })
    $Ui.HdPing.Add_Click({ $H = Get-SelectedHost; if ($H) { Start-PingFor $H.HostName } })
    $Ui.HdCopyKey.Add_Click({ $H = Get-SelectedHost; if ($H) { $K = Find-KeyForHost $H; Copy-Text $K.PubText "ключ $($K.Name)" } })
    $Ui.HdCopyPub2.Add_Click({ $H = Get-SelectedHost; if ($H) { $K = Find-KeyForHost $H; Copy-Text $K.PubText "ключ $($K.Name)" } })
    $Ui.HdCopyCfg.Add_Click({ $H = Get-SelectedHost; if ($H) { Copy-Text (Get-ConfigBlock $H.Alias) "блок config" } })
    $Ui.HdInstall.Add_Click({ $H = Get-SelectedHost; if ($H) { Copy-Text (Get-InstallCommand (Find-KeyForHost $H).PubText) "команда установки" } })
    $Ui.HdPassword.Add_Click({ $H = Get-SelectedHost; if ($H) { Show-NewServerDialog $H } })
    $Ui.HdGoodies.Add_Click({ param($S, $E) Show-GoodiesMenu $S })
    $Ui.HdMore.Add_Click({ param($S, $E) Show-Menu $S (Get-HostMenuItems) })
    $Ui.HdSnippets.Add_Click({ param($S, $E) Show-SnippetsMenu $S })
    $Ui.HdSend.Add_Click({ $H = Get-SelectedHost; if ($H) { Show-SendFilesDialog $H } })

    # drag files from Explorer onto a host row → scp
    $Ui.HostList.AllowDrop = $true
    $Ui.HostList.Add_DragOver({
        param($S, $E)
        $E.Effects = $(if ($E.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { "Copy" } else { "None" })
        $E.Handled = $true
    })
    $Ui.HostList.Add_Drop({
        param($S, $E)
        if (-not $E.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
        $Files = @($E.Data.GetData([System.Windows.DataFormats]::FileDrop))
        $H = $null
        $C = [System.Windows.Controls.ItemsControl]::ContainerFromElement($Ui.HostList, $E.OriginalSource)
        if ($C -and $C.Content) { $Ui.HostList.SelectedItem = $C.Content; $H = $C.Content.Host }
        if (-not $H) { $H = Get-SelectedHost }
        if ($H -and $Files) { Show-SendFilesDialog $H $Files }
    })

    $Ui.KdCopy.Add_Click({ $K = Get-SelectedKey; if ($K) { Copy-Text $K.PubText "ключ $($K.Name)" } })
    $Ui.KdInstall.Add_Click({ $K = Get-SelectedKey; if ($K) { Copy-Text (Get-InstallCommand $K.PubText) "команда OpenSSH" } })
    $Ui.KdDropbear.Add_Click({ $K = Get-SelectedKey; if ($K) { Copy-Text (Get-InstallCommand $K.PubText "dropbear") "команда Dropbear" } })
    $Ui.KdFp.Add_Click({ $K = Get-SelectedKey; if ($K) { Copy-Text $K.Fingerprint "fingerprint" } })
    $Ui.KdPath.Add_Click({ $K = Get-SelectedKey; if ($K) { Copy-Text $K.Path "путь" } })
    $Ui.KdExplorer.Add_Click({ $K = Get-SelectedKey; if ($K) { Start-Process explorer.exe -ArgumentList "/select,$(Quote-Arg $K.Path)" } })
    $Ui.KdMore.Add_Click({ param($S, $E) Show-Menu $S (Get-KeyMenuItems) })

    $Ui.ConfigBtn.Add_Click({
        $Code = (Get-Command code.cmd -ErrorAction SilentlyContinue).Source
        if ($Code) { Start-Process $Code -ArgumentList (Quote-Arg $script:ConfigPath) -WindowStyle Hidden } else { Start-Process notepad.exe -ArgumentList (Quote-Arg $script:ConfigPath) }
    })
    $Ui.SshDirBtn.Add_Click({ Start-Process explorer.exe -ArgumentList (Quote-Arg $script:SshDir) })
    $Ui.ConsoleBtn.Add_Click({ Start-Engine -Title "ssh-key.ps1" -EngineArgs @() })
    $Ui.TerminalBtn.Add_Click({ Start-Terminal "" "" })
}
