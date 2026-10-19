# MikroTik routers (RouterOS 7, SSH). Registry in settings.Routers; NetKnife talks to them as a dedicated
# read-only user "netknife" (group netknife-ro) with its own key ~/.ssh/netknife_mt — created once by
# Initialize-MtUser through the site's admin access, after showing the exact script. A second group
# netknife-rw (no users) is prepared for future write integrations. Data comes as JSON via :serialize.
#
# Used by: the roaming monitor (DHCP lease/ARP of the laptop, router→AP pings, port counters, live log),
# AP names for the Wi-Fi planner/monitor (Omada APs register "MAC Name" as DHCP host-name).

$script:MtKey = Join-Path $env:USERPROFILE ".ssh\netknife_mt"
$script:MtUser = "netknife"
$script:MtApPattern = '^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}'   # Omada AP DHCP host-name starts with its MAC

function Get-MtRouters { return @($script:Settings.Routers | Where-Object { $_ -and $_.Id }) }

# cached AP list of a router (from its last DHCP read); empty when never read
function Get-MtCachedAps { param([string]$Id) if ($script:Settings.MtAps -and $Id -and $script:Settings.MtAps.ContainsKey($Id)) { return @($script:Settings.MtAps[$Id]) }; return @() }

function Get-MtRouter { param([string]$Id) return @(Get-MtRouters) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }

function Resolve-MtPath { param([string]$P) if ($P -like "~*") { return Join-Path $env:USERPROFILE $P.Substring(1).TrimStart('\', '/') }; return $P }

# ssh argument list (ArgumentList → correct quoting of the RouterOS script)
function Get-MtSshArgs {
    param($R, [switch]$Admin, [int]$Timeout = 6)
    $Key = $(if ($Admin -or -not $R.Ready) { Resolve-MtPath "$($R.AdminKey)" } else { $script:MtKey })
    $User = $(if ($Admin -or -not $R.Ready) { "$($R.Admin)" } else { $script:MtUser })
    return @("-i", $Key, "-p", "$($R.Port)", "-o", "BatchMode=yes", "-o", "ConnectTimeout=$Timeout", "-o", "StrictHostKeyChecking=accept-new", "-o", "ServerAliveInterval=10", "$User@$($R.Host)")
}

# one-shot command in a worker (UI stays responsive); OnResult gets @{ Code; Out; Err }
$script:MtExecBody = {
    param($Q, $Ctl, $SshArgs, $Script, $TimeoutMs)
    try {
        $Psi = New-Object System.Diagnostics.ProcessStartInfo "ssh.exe"
        foreach ($A in $SshArgs) { $Psi.ArgumentList.Add($A) }
        $Psi.ArgumentList.Add($Script)
        $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true
        $Psi.RedirectStandardOutput = $true; $Psi.RedirectStandardError = $true
        $P = [System.Diagnostics.Process]::Start($Psi)
        $O = $P.StandardOutput.ReadToEndAsync(); $E = $P.StandardError.ReadToEndAsync()
        if (-not $P.WaitForExit($TimeoutMs)) { try { $P.Kill() } catch { } }
        [void]$O.Wait(1000); [void]$E.Wait(1000)
        $Q.Enqueue(@{ Type = "mtx"; Code = $(if ($P.HasExited) { $P.ExitCode } else { -1 }); Out = ("$($O.Result)" -replace "`r", ""); Err = "$($E.Result)".Trim() })
    } catch { $Q.Enqueue(@{ Type = "mtx"; Code = -1; Out = ""; Err = "$($_.Exception.Message)" }) }
}

function Invoke-MtAsync {
    param($R, [string]$Script, [scriptblock]$OnResult, [switch]$Admin, [int]$TimeoutMs = 20000, [string]$Name = "mt-exec")
    if (-not $script:MtCallbacks) { $script:MtCallbacks = @{} }
    $script:MtCallbacks[$Name] = $OnResult
    [void](Start-Worker -Name $Name -Replace -Body $script:MtExecBody -ArgList @(@(, [string[]](Get-MtSshArgs $R -Admin:$Admin)) + @($Script, $TimeoutMs)) -State @{ Name = $Name } -OnMessage {
        param($M)
        if ($M.Type -ne "mtx") { return }
        & $script:MtCallbacks[$State.Name] $M
    })
}

function ConvertFrom-MtJson {
    param([string]$Text, [string]$Marker = "")
    foreach ($L in ($Text -split "`n")) {
        $L = $L.Trim()
        if ($Marker) { if (-not $L.StartsWith($Marker)) { continue }; $L = $L.Substring($Marker.Length) }
        if ($L.StartsWith("[") -or $L.StartsWith("{")) { try { return ($L | ConvertFrom-Json -AsHashtable) } catch { } }
    }
    return $null
}

# ---------------------------------------------------------------- AP list from DHCP (Omada APs register "MAC Name")

function Get-MtApKey {
    param([string]$Mac)
    $O = $Mac.ToUpper() -split '[:-]'
    if ($O.Count -ne 6) { return $Mac }
    return "{0}:{1}:{2}:{3}:{4:X2}" -f $O[1], $O[2], $O[3], $O[4], ([Convert]::ToInt32($O[5], 16) -band 0xF8)
}

function ConvertFrom-MtLeases {
    param($Leases)
    $Aps = @()
    foreach ($L in @($Leases)) {
        $Hn = "$($L.'host-name')"
        if ($Hn -notmatch $script:MtApPattern) { continue }
        $Name = ($Hn -replace $script:MtApPattern, '').Trim()
        $Aps += [ordered]@{ Mac = "$($L.'mac-address')".ToUpper(); Ip = "$($L.address)"; Name = $(if ($Name) { $Name } else { "" }); Status = "$($L.status)"; LastSeen = "$($L.'last-seen')"; Server = "$($L.server)"; Key = (Get-MtApKey "$($L.'mac-address')") }
    }
    return $Aps
}

# names cache (persisted): AP group key → name; feeds the Wi-Fi planner and the roaming monitor
function Update-MtApNames {
    param($Aps, $R)
    if (-not $script:Settings.MtApNames) { $script:Settings.MtApNames = @{} }
    $N = 0
    foreach ($A in @($Aps)) { if ($A.Name) { $script:Settings.MtApNames[$A.Key] = $A.Name; $N++ } }
    if (-not $script:Settings.MtAps) { $script:Settings.MtAps = @{} }
    $script:Settings.MtAps[$R.Id] = @($Aps)
    Save-Settings
    return $N
}

function Get-MtApName {
    param([string]$Bssid)
    $Nm = $script:Settings.MtApNames
    if (-not $Nm) { return "" }
    $K = Get-MtApKey $Bssid
    if ($Nm[$K]) { return "$($Nm[$K])" }
    return ""
}

function Start-MtApRefresh {
    param($R, [scriptblock]$Then)
    $script:MtThen = $Then
    Invoke-MtAsync $R ":put [:serialize to=json [/ip dhcp-server lease print as-value]]" -Name "mt-aps" -OnResult {
        param($M)
        $Rt = Get-MtRouter $script:MtApsRouterId
        if ($M.Code -ne 0) { Set-MtStatus "Не прочитал аренды: $(Get-MtErrText $M)" "fail"; return }
        $Leases = ConvertFrom-MtJson $M.Out
        $Aps = @(ConvertFrom-MtLeases $Leases)
        $Named = Update-MtApNames $Aps $Rt
        Set-MtStatus "$($Rt.Name): точек Omada в DHCP — $($Aps.Count), с именами — $Named" "ok"
        if ($script:MtThen) { & $script:MtThen $Aps }
    }
    $script:MtApsRouterId = $R.Id
}

function Get-MtErrText {
    param($M)
    $E = "$($M.Err)"
    if ($E -match 'Permission denied') { return "ключ не принят (Permission denied) — подготовь пользователя netknife или проверь ключ админа" }
    if ($E -match 'timed out|Connection refused|No route|Could not resolve') { return "роутер недоступен: $E" }
    if ($E) { return $E }
    return "код $($M.Code)"
}

# ---------------------------------------------------------------- provisioning (admin access → read-only user)

function New-MtPassword {
    $B = [byte[]]::new(18); [System.Security.Cryptography.RandomNumberGenerator]::Fill($B)
    return ([Convert]::ToBase64String($B) -replace '[+/=]', 'x')
}

function Get-MtProvisionScript {
    param([string]$PubKey, [string]$Password)
    # read + test (ping) + ssh + api/rest-api for future REST; explicit denials for everything that changes state
    $Ro = "read,test,ssh,api,rest-api,!local,!telnet,!ftp,!reboot,!write,!policy,!password,!web,!sniff,!sensitive,!romon,!winbox"
    $Rw = "read,write,test,ssh,api,rest-api,!local,!telnet,!ftp,!reboot,!policy,!password,!web,!sniff,!sensitive,!romon,!winbox"
    return @(
        ":if ([:len [/user group find name=`"netknife-ro`"]] = 0) do={ /user group add name=netknife-ro policy=$Ro comment=`"NetKnife: diagnostics, read-only`" } else={ /user group set [find name=`"netknife-ro`"] policy=$Ro }"
        ":if ([:len [/user group find name=`"netknife-rw`"]] = 0) do={ /user group add name=netknife-rw policy=$Rw comment=`"NetKnife: reserved for future write integrations, no users`" }"
        ":if ([:len [/user find name=`"$($script:MtUser)`"]] = 0) do={ /user add name=$($script:MtUser) group=netknife-ro password=`"$Password`" comment=`"NetKnife diagnostics (read-only)`" } else={ /user set [find name=`"$($script:MtUser)`"] group=netknife-ro }"
        "/file add name=netknife.pub contents=`"$PubKey`""
        ":delay 1s"
        "/user ssh-keys remove [find user=`"$($script:MtUser)`"]"
        "/user ssh-keys import public-key-file=netknife.pub user=$($script:MtUser)"
        ":put `"NETKNIFE-OK`""
    ) -join "; "
}

function Initialize-MtKey {
    if (Test-Path "$($script:MtKey).pub") { return $true }
    $Dir = Split-Path $script:MtKey -Parent
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
    # RSA: ed25519 keys are not accepted on RouterOS 6 objects; keep one key type everywhere
    $P = Start-Process ssh-keygen.exe -ArgumentList @("-t", "rsa", "-b", "4096", "-N", '""', "-C", "netknife-mikrotik", "-f", (Quote-Arg $script:MtKey)) -NoNewWindow -Wait -PassThru
    return ($P.ExitCode -eq 0 -and (Test-Path "$($script:MtKey).pub"))
}

function Initialize-MtUser {
    param($R)
    if (-not (Initialize-MtKey)) { Show-Toast "Не создал ключ $($script:MtKey)" "fail"; return }
    $Pub = (Get-Content "$($script:MtKey).pub" -Raw).Trim()
    $Pw = New-MtPassword
    $Script = Get-MtProvisionScript $Pub $Pw
    $Shown = $Script.Replace($Pw, "••••••").Replace($Pub, "<ключ netknife_mt.pub>") -replace '; ', "`n"
    $Msg = "На $($R.Name) ($($R.Host)) под «$($R.Admin)» будут созданы группы netknife-ro (только чтение + ping) и netknife-rw (пустая, на будущее) и пользователь netknife с ключом $([IO.Path]::GetFileName($script:MtKey)). Ничего другого не меняется."
    if (-not (Show-Confirm "Подготовить $($R.Name)?" $Msg "Выполнить" -Detail $Shown)) { return }
    Set-MtStatus "$($R.Name): создаю пользователя netknife…" "wait"
    $script:MtProvision = @{ Id = $R.Id; PassEnc = (Protect-MtSecret $Pw) }
    Invoke-MtAsync $R $Script -Admin -Name "mt-prov" -OnResult {
        param($M)
        $Rt = Get-MtRouter $script:MtProvision.Id
        if ($M.Code -ne 0 -or $M.Out -notmatch 'NETKNIFE-OK') { Set-MtStatus "$($Rt.Name): не получилось — $(Get-MtErrText $M) $($M.Out.Trim())" "fail"; return }
        $Rt.Ready = $true; $Rt.PassEnc = $script:MtProvision.PassEnc
        Save-Settings
        Refresh-MtList
        Set-MtStatus "$($Rt.Name): пользователь netknife готов — проверяю вход…" "wait"
        Test-MtRouter $Rt
    }
}

function Protect-MtSecret { param([string]$S) return [Convert]::ToBase64String([System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($S), $null, "CurrentUser")) }

function Test-MtRouter {
    param($R)
    $script:MtTestId = $R.Id
    Invoke-MtAsync $R ':put ("##J" . [:serialize to=json ({"ver"=[/system resource get version]; "id"=[/system identity get name]; "board"=[/system resource get board-name]; "uptime"=[/system resource get uptime]})])' -Name "mt-test" -OnResult {
        param($M)
        $Rt = Get-MtRouter $script:MtTestId
        if ($M.Code -ne 0) { Set-MtStatus "$($Rt.Name): $(Get-MtErrText $M)" "fail"; return }
        $J = ConvertFrom-MtJson $M.Out "##J"
        if (-not $J) { Set-MtStatus "$($Rt.Name): ответ не разобран — нужен RouterOS 7.13+ (:serialize)" "fail"; return }
        Set-MtStatus "$($Rt.Name): $($J.id) · $($J.board) · RouterOS $($J.ver) · вход как $(if ($Rt.Ready) { 'netknife (только чтение)' } else { "$($Rt.Admin) (админ — подготовь netknife)" })" "ok"
        Start-MtApRefresh $Rt
        # right after adding a found router: propose creating the read-only user straight away
        if ($script:MtOfferPrep -and -not $Rt.Ready) { $script:MtOfferPrep = $false; Initialize-MtUser $Rt }
    }
}

# ---------------------------------------------------------------- live feed for the roaming monitor

# Poll loop runs ON the router in one SSH session: every 2 s laptop ARP + DHCP lease, every 10 s AP pings and
# ether counters. Lines start with ##J / ##P / ##I; anything else (ping tables) is ignored.
function Get-MtPollScript {
    param([string]$Ip)
    $Pat = $script:MtApPattern
    $J = ":put (`"##J`" . [:serialize to=json ({`"t`"=[/system clock get time]; `"arp`"=[/ip arp print as-value where address=`$ip]; `"lease`"=[/ip dhcp-server lease print as-value where address=`$ip or (mac-address=`$m and `$m!=`"`")]})])"
    $P = ":local res ({}); :foreach a in=[/ip dhcp-server lease find where host-name~`"$Pat`" and status=`"bound`"] do={ :local adr [/ip dhcp-server lease get `$a address]; :set (`$res->`$adr) [/ping address=`$adr count=1 interval=200ms] }; :put (`"##P`" . [:serialize to=json `$res])"
    $I = ":put (`"##I`" . [:serialize to=json [/interface print stats as-value where type=`"ether`" or type=`"vlan`" or type=`"bridge`"]])"
    $Arp = ":do { :set m [/ip arp get [find address=`$ip] mac-address] } on-error={ :set m `"`" }"
    return ":local ip `"$Ip`"; :local m `"`"; :local n 0; :while (true) do={ $Arp; $J; :if ((`$n % 5) = 0) do={ $P; $I }; :set n (`$n + 1); :delay 2s }"
}

$script:MtStreamBody = {
    param($Q, $Ctl, $SshArgs, $Script, $Kind)
    $Psi = New-Object System.Diagnostics.ProcessStartInfo "ssh.exe"
    foreach ($A in $SshArgs) { $Psi.ArgumentList.Add($A) }
    $Psi.ArgumentList.Add($Script)
    $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardOutput = $true; $Psi.RedirectStandardError = $true; $Psi.RedirectStandardInput = $true
    try { $P = [System.Diagnostics.Process]::Start($Psi) } catch { $Q.Enqueue(@{ Type = "mts"; Kind = $Kind; Error = "$($_.Exception.Message)" }); return }
    $ErrTask = $P.StandardError.ReadToEndAsync()
    $LineTask = $P.StandardOutput.ReadLineAsync()
    while (-not $Ctl.Stop) {
        if ($LineTask.Wait(300)) {
            $L = $LineTask.Result
            if ($null -eq $L) { break }
            $L = $L.TrimEnd("`r")
            if ($Kind -eq "poll") {
                if ($L.StartsWith("##")) { $Q.Enqueue(@{ Type = "mts"; Kind = $Kind; Tag = $L.Substring(2, 1); Json = $L.Substring(3) }) }
            } elseif ($L.Trim()) { $Q.Enqueue(@{ Type = "mts"; Kind = $Kind; Line = $L.Trim() }) }
            $LineTask = $P.StandardOutput.ReadLineAsync()
        } elseif ($P.HasExited) { break }
    }
    try { if (-not $P.HasExited) { $P.Kill() } } catch { }
    [void]$ErrTask.Wait(1000)
    if (-not $Ctl.Stop) { $Q.Enqueue(@{ Type = "mts"; Kind = $Kind; Error = "соединение с роутером закрылось: $("$($ErrTask.Result)".Trim())" }) }
}

function Start-MtFeed {
    param($R, [string]$Ip, [scriptblock]$OnMsg)
    $script:MtFeedCb = $OnMsg
    $SshA = [string[]](Get-MtSshArgs $R)
    [void](Start-Worker -Name "roam-mt" -Replace -Body $script:MtStreamBody -ArgList @(@(, $SshA) + @((Get-MtPollScript $Ip), "poll")) -OnMessage { param($M) if ($M.Type -eq "mts") { & $script:MtFeedCb $M } })
    $LogScript = '/log print follow-only without-paging where topics~"dhcp|interface|bridge|stp|critical|error|warning"'
    if (-not (Test-WorkerRunning "roam-mtlog")) {
        [void](Start-Worker -Name "roam-mtlog" -Replace -Body $script:MtStreamBody -ArgList @(@(, $SshA) + @($LogScript, "log")) -OnMessage { param($M) if ($M.Type -eq "mts") { & $script:MtFeedCb $M } })
    }
}

function Stop-MtFeed { Stop-Worker "roam-mt"; Stop-Worker "roam-mtlog" }

# ---------------------------------------------------------------- Settings card

function Set-MtStatus {
    param([string]$Text, [string]$Kind = "info")
    $Br = Get-Brush $(switch ($Kind) { "ok" { "Ok" } "fail" { "Fail" } "wait" { "Warn" } default { "Sub" } })
    foreach ($T in @($Ui.SetMtStatus, $Ui.WhRouterStatus)) { if ($T) { $T.Text = $Text; $T.Foreground = $Br } }
    if ($Ui.WhAps -and $script:WhInit -and $Kind -eq "ok") { try { Update-WhPrep } catch { } }
}

function Refresh-MtList {
    if (-not $Ui.SetMtList) { return }
    $Sel = $(if ($Ui.SetMtList.SelectedItem) { $Ui.SetMtList.SelectedItem.Id } else { $null })
    $Items = @(Get-MtRouters | ForEach-Object {
        $Aps = @(Get-MtCachedAps $_.Id).Count
        [pscustomobject]@{ Id = $_.Id; Label = "$($_.Name)   $($_.Host):$($_.Port)   ·   $(if ($_.Ready) { 'netknife ✓' } else { "через $($_.Admin) — не подготовлен" })$(if ($Aps) { "   ·   точек: $Aps" })" }
    })
    $Ui.SetMtList.ItemsSource = $Items
    $Ui.SetMtList.DisplayMemberPath = "Label"
    if ($Sel) { $Ui.SetMtList.SelectedItem = ($Items | Where-Object { $_.Id -eq $Sel } | Select-Object -First 1) }
    elseif ($Items.Count) { $Ui.SetMtList.SelectedIndex = 0 }
    if ($Ui.RoamRouter) { Update-RoamRouterList }
}

function Get-MtSelected {
    $S = $Ui.SetMtList.SelectedItem
    if (-not $S) { Show-Toast "Выбери роутер" "warn"; return $null }
    return Get-MtRouter $S.Id
}

function Show-MtRouterDialog {
    param($R)
    $D = New-Dialog "Роутер MikroTik" @"
<StackPanel>
    <TextBlock Text="Роутер MikroTik" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="Админ-доступ нужен один раз — чтобы создать пользователя netknife только на чтение. Дальше NetKnife ходит только им." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,14" FontSize="12.5"/>
    <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="ОБЪЕКТ" Style="{StaticResource Caption}"/><TextBox x:Name="FName" Style="{StaticResource Field}" Tag="Алые Паруса 115"/></StackPanel>
        <StackPanel Grid.Column="2"><TextBlock Text="АДРЕС" Style="{StaticResource Caption}"/><TextBox x:Name="FHost" Style="{StaticResource MonoField}" Tag="192.168.115.1"/></StackPanel>
        <StackPanel Grid.Column="4"><TextBlock Text="SSH ПОРТ" Style="{StaticResource Caption}"/><TextBox x:Name="FPort" Style="{StaticResource MonoField}" Text="10322"/></StackPanel>
    </Grid>
    <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="2*"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="АДМИН" Style="{StaticResource Caption}"/><TextBox x:Name="FAdmin" Style="{StaticResource MonoField}" Text="butler"/></StackPanel>
        <StackPanel Grid.Column="2"><TextBlock Text="КЛЮЧ АДМИНА" Style="{StaticResource Caption}"/><TextBox x:Name="FKey" Style="{StaticResource MonoField}" Text="~/.ssh/mikrotik_rsa"/></StackPanel>
    </Grid>
    <TextBlock x:Name="FError" Foreground="{StaticResource Fail}" FontSize="12" Margin="2,8,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="Сохранить" MinWidth="120" Margin="8,0,0,0" IsDefault="True"/>
    </StackPanel>
</StackPanel>
"@ 600
    $F = @{}; foreach ($N in @("FName", "FHost", "FPort", "FAdmin", "FKey", "FError", "FOk")) { $F[$N] = $D.FindName($N) }
    if ($R) { $F.FName.Text = $R.Name; $F.FHost.Text = $R.Host; $F.FPort.Text = "$($R.Port)"; $F.FAdmin.Text = $R.Admin; $F.FKey.Text = $R.AdminKey }
    $F.FOk.Add_Click({
        $Err = $null
        if (-not $F.FName.Text.Trim() -or -not $F.FHost.Text.Trim()) { $Err = "Объект и адрес обязательны" }
        elseif ($F.FPort.Text.Trim() -notmatch '^\d+$') { $Err = "Порт — число" }
        if ($Err) { $F.FError.Text = $Err; $F.FError.Visibility = "Visible"; return }
        $D.DialogResult = $true
    })
    $D.Add_ContentRendered({ [void]$F.FName.Focus() })
    if (-not $D.ShowDialog()) { return }
    $New = @{ Id = $(if ($R -and $R.Id) { $R.Id } else { [guid]::NewGuid().ToString("N").Substring(0, 8) }); Name = $F.FName.Text.Trim(); Host = (Repair-TargetText $F.FHost); Port = [int]$F.FPort.Text.Trim()
        Admin = $F.FAdmin.Text.Trim(); AdminKey = $F.FKey.Text.Trim(); Ready = $(if ($R) { [bool]$R.Ready } else { $false }); PassEnc = $(if ($R) { "$($R.PassEnc)" } else { "" }) }
    $L = @(Get-MtRouters | Where-Object { $_.Id -ne $New.Id }) + @($New)
    $script:Settings.Routers = $L
    Save-Settings
    Refresh-MtList
    Test-MtRouter $New
}

function Show-MtApsDialog {
    param($R)
    $Aps = @(Get-MtCachedAps $R.Id)
    if (-not $Aps.Count) { Show-Toast "Сначала «Проверить» — список точек читается из DHCP роутера" "warn"; return }
    $Lines = @("{0,-24} {1,-18} {2,-16} {3,-8} {4}" -f "Имя (из Omada)", "MAC", "IP", "статус", "последний раз")
    $Lines += $Aps | Sort-Object { $_.Name } | ForEach-Object { "{0,-24} {1,-18} {2,-16} {3,-8} {4}" -f $(if ($_.Name) { $_.Name } else { "—" }), $_.Mac, $_.Ip, $_.Status, $_.LastSeen }
    $Text = $Lines -join "`n"
    Show-Confirm "Точки Omada · $($R.Name)" "Из аренд DHCP: каждая точка регистрирует MAC и имя из контроллера. Имена подставляются в Wi-Fi план и монитор роуминга." "Закрыть" -Detail $Text | Out-Null
}

function Initialize-MtSettings {
    if (-not $Ui.SetMtList) { return }
    Refresh-MtList
    $Ui.SetMtAdd.Add_Click({ Show-MtRouterDialog $null })
    $Ui.SetMtFind.Add_Click({ Start-MtDiscovery })
    $Ui.SetMtEdit.Add_Click({ $R = Get-MtSelected; if ($R) { Show-MtRouterDialog $R } })
    $Ui.SetMtList.Add_MouseDoubleClick({ $R = Get-MtSelected; if ($R) { Show-MtRouterDialog $R } })
    $Ui.SetMtPrep.Add_Click({ $R = Get-MtSelected; if ($R) { Initialize-MtUser $R } })
    $Ui.SetMtTest.Add_Click({ $R = Get-MtSelected; if ($R) { Set-MtStatus "$($R.Name): подключаюсь…" "wait"; Test-MtRouter $R } })
    $Ui.SetMtAps.Add_Click({ $R = Get-MtSelected; if ($R) { Show-MtApsDialog $R } })
    $Ui.SetMtDel.Add_Click({
        $R = Get-MtSelected; if (-not $R) { return }
        if (-not (Show-Confirm "Убрать $($R.Name) из NetKnife?" "Удаляется только запись в NetKnife. Пользователь netknife на роутере остаётся (удалить: /user remove netknife)." "Убрать" -Danger)) { return }
        $script:Settings.Routers = @(Get-MtRouters | Where-Object { $_.Id -ne $R.Id }); Save-Settings; Refresh-MtList
    })
}
