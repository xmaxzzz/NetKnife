# MikroTik routers (RouterOS 7, SSH). Registry in settings.Routers; NetKnife talks to them as a dedicated
# read-only user "netknife" (group netknife-ro) with its own key ~/.ssh/netknife_mt — created once by commands
# the user pastes into the router terminal (Show-MtConnectDialog); NetKnife never asks for admin credentials. A second group
# netknife-rw (no users) is prepared for future write integrations. Data comes as JSON via :serialize.
#
# Used by: the roaming monitor (DHCP lease/ARP of the laptop, router→AP pings, port counters, live log),
# AP names for the Wi-Fi planner/monitor (Omada APs register "MAC Name" as DHCP host-name).

$script:MtKey = Join-Path $env:USERPROFILE ".ssh\netknife_mt"
$script:MtUser = "butler-service"   # read account shared by NetKnife, the helpdesk and Claude (group butler-service-ro)
$script:MtRwUser = "butler-rw"        # write account, same keys (group butler-service-rw); used only for confirmed changes
$script:MtGroup = "butler-service"  # groups butler-service-ro (user) / butler-service-rw (reserved)
$script:MtKeyOwner = "netknife-mikrotik"   # comment of NetKnife's public key = key-owner on the router
$script:MtApPattern = '([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}'   # Omada AP DHCP host-name contains its MAC (renamed APs: "Имя (MAC)")

function Get-MtRouters { return @($script:Settings.Routers | Where-Object { $_ -and $_.Id }) }

# cached AP list of a router (from its last DHCP read); empty when never read
function Get-MtCachedAps { param([string]$Id) if ($script:Settings.MtAps -and $Id -and $script:Settings.MtAps.ContainsKey($Id)) { return @($script:Settings.MtAps[$Id]) }; return @() }

function Get-MtRouter { param([string]$Id) return @(Get-MtRouters) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }

function Resolve-MtPath { param([string]$P) if ($P -like "~*") { return Join-Path $env:USERPROFILE $P.Substring(1).TrimStart('\', '/') }; return $P }

# ssh argument list (ArgumentList → correct quoting of the RouterOS script)
function Get-MtSshArgs {
    param($R, [switch]$Admin, [switch]$Rw, [int]$Timeout = 6)
    $Adm = ($Admin -or -not $R.Ready)
    $Key = $(if ($Adm) { Resolve-MtPath "$($R.AdminKey)" } else { $script:MtKey })
    $User = $(if ($Adm) { "$($R.Admin)" } elseif ($Rw) { $script:MtRwUser } else { $script:MtUser })
    return @("-i", $Key, "-p", "$($R.Port)", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=$Timeout", "-o", "StrictHostKeyChecking=accept-new", "-o", "ServerAliveInterval=10", "$User@$($R.Host)")
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
        $Psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $Psi.StandardErrorEncoding = [Text.Encoding]::UTF8   # RouterOS sends raw UTF-8
        $P = [System.Diagnostics.Process]::Start($Psi)
        $O = $P.StandardOutput.ReadToEndAsync(); $E = $P.StandardError.ReadToEndAsync()
        if (-not $P.WaitForExit($TimeoutMs)) { try { $P.Kill() } catch { } }
        [void]$O.Wait(1000); [void]$E.Wait(1000)
        $Q.Enqueue(@{ Type = "mtx"; Code = $(if ($P.HasExited) { $P.ExitCode } else { -1 }); Out = ("$($O.Result)" -replace "`r", ""); Err = "$($E.Result)".Trim() })
    } catch { $Q.Enqueue(@{ Type = "mtx"; Code = -1; Out = ""; Err = "$($_.Exception.Message)" }) }
}

function Invoke-MtAsync {
    param($R, [string]$Script, [scriptblock]$OnResult, [switch]$Admin, [switch]$Rw, [int]$TimeoutMs = 20000, [string]$Name = "mt-exec")
    if (-not $script:MtCallbacks) { $script:MtCallbacks = @{} }
    $script:MtCallbacks[$Name] = $OnResult
    [void](Start-Worker -Name $Name -Replace -Body $script:MtExecBody -ArgList @(@(, [string[]](Get-MtSshArgs $R -Admin:$Admin -Rw:$Rw)) + @($Script, $TimeoutMs)) -State @{ Name = $Name } -OnMessage {
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
        # Omada name around the MAC in any form: "MAC Имя", "Имя (MAC)", "Имя(MAC)", "(Имя) MAC"
        $Name = (($Hn -replace $script:MtApPattern, '') -replace '\(\s*\)', '').Trim()
        if ($Name -match '^\((.*)\)$') { $Name = $Matches[1].Trim() }
        if (-not $Name -or $Name -match '^(\d+|нет)$') {
            # no real name in Omada: static lease comment ("AP Кабинет") or "AP B2:D8 (2)"
            $Cm = ("$($L.comment)" -replace '^AP\s+', '').Trim()
            $Name = $(if ($Cm) { $Cm } else { "AP $("$($L.'mac-address')".ToUpper().Substring(12))$(if ($Name) { " ($Name)" })" })
        }
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

function Repair-MtApCache {
    $Bad = '[╨╤][\u2500-\u257F\u0400-\u04FF]'
    $Ch = $false
    if ($script:Settings.MtApNames) { foreach ($K in @($script:Settings.MtApNames.Keys)) { if ("$($script:Settings.MtApNames[$K])" -match $Bad) { $script:Settings.MtApNames.Remove($K); $Ch = $true } } }
    if ($script:Settings.MtAps) { foreach ($Id in @($script:Settings.MtAps.Keys)) { foreach ($A in @($script:Settings.MtAps[$Id])) { if ($A -and "$($A.Name)" -match $Bad) { $A.Name = ""; $Ch = $true } } } }
    if ($Ch) { Save-Settings }
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
    if ($E -match 'Permission denied') { return "ключ не принят (Permission denied) — выполни на роутере команды подключения" }
    if ($E -match 'timed out|Connection refused|No route|Could not resolve') { return "роутер недоступен: $E" }
    if ($E) { return $E }
    return "код $($M.Code)"
}

# ---------------------------------------------------------------- connecting a router (commands pasted by the user)

# NetKnife never asks for admin credentials: it shows the exact commands, the user pastes them into the router's
# terminal (Winbox → New Terminal / WebFig → Terminal) and NetKnife then checks the logins as butler-service and butler-rw.

# Key registry: NetKnife's own key + public keys of other Butler systems (settings.MtExtraKeys, e.g. the helpdesk).
# Each key goes into BOTH accounts; the key comment (info, older key-owner) identifies whose key it is.
function Get-MtKeyRegistry {
    $L = @([pscustomobject]@{ Key = (Get-Content "$($script:MtKey).pub" -Raw).Trim(); Owner = $script:MtKeyOwner })
    foreach ($K in @($script:Settings.MtExtraKeys)) {
        $P = "$K".Trim() -split '\s+'
        if ($P.Count -ge 3 -and $P[0] -match '^ssh-(rsa|ed25519)$' -and $P[2] -ne $script:MtKeyOwner) { $L += [pscustomobject]@{ Key = "$K".Trim(); Owner = $P[2] } }
    }
    return $L
}

function Get-MtProvisionScript {
    param($Keys, [int]$EnableSshPort = 0)
    # read + test (ping) + ssh + api/rest-api for future REST; explicit denials for everything that changes state
    $Ro = "read,test,ssh,api,rest-api,!local,!telnet,!ftp,!reboot,!write,!policy,!password,!web,!sniff,!sensitive,!romon,!winbox"
    $Rw = "read,write,test,ssh,api,rest-api,!local,!telnet,!ftp,!reboot,!policy,!password,!web,!sniff,!sensitive,!romon,!winbox"
    $G = $script:MtGroup
    # random password generated ON the router (never leaves it, never in the clipboard); login is by key only.
    # :rndstr does not work on RouterOS 7.24 — :rndnum + :pick
    $Pw = ':local a "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"; :local p ""; :for i from=1 to=32 do={ :set p ($p . [:pick $a [:rndnum from=0 to=56]]) }'
    $Users = @(@{ U = $script:MtUser; G = "$G-ro"; C = "Butler service: read-only (NetKnife, helpdesk)" }, @{ U = $script:MtRwUser; G = "$G-rw"; C = "Butler service: write, key auth only" })
    $Out = @()
    if ($EnableSshPort) { $Out += "/ip service set ssh disabled=no port=$EnableSshPort" }
    $Out += ":if ([:len [/user group find name=`"$G-ro`"]] = 0) do={ /user group add name=$G-ro policy=$Ro comment=`"Butler service: diagnostics, read-only`" }"
    $Out += ":if ([:len [/user group find name=`"$G-rw`"]] = 0) do={ /user group add name=$G-rw policy=$Rw comment=`"Butler service: write integrations`" }"
    # an existing account keeps its group and password; other systems' keys stay (only the same key comment is replaced)
    foreach ($X in $Users) { $Out += ":if ([:len [/user find name=`"$($X.U)`"]] = 0) do={ $Pw; /user add name=$($X.U) group=$($X.G) password=`$p comment=`"$($X.C)`" }" }
    $I = 0
    $Files = @()
    foreach ($K in @($Keys)) { $I++; foreach ($X in $Users) { $F = "bk$I-$($X.U).pub"; $Files += @{ F = $F; U = $X.U; O = $K.Owner }; $Out += "/file add name=$F contents=`"$($K.Key)`"" } }
    $Out += ":delay 2s"
    foreach ($F in $Files) {
        # key comment is "info" on RouterOS 7.24 (older versions: "key-owner")
        $Out += ":do { /user ssh-keys remove [find user=`"$($F.U)`" info=`"$($F.O)`"] } on-error={ :do { /user ssh-keys remove [find user=`"$($F.U)`" key-owner=`"$($F.O)`"] } on-error={} }"
        $Out += "/user ssh-keys import public-key-file=$($F.F) user=$($F.U)"
    }
    $Out += ":do { /file remove [find name~`"^bk[0-9]+-`"] } on-error={}"
    $Out += ":put `"BUTLER-USERS-OK`""
    return $Out -join "`r`n"
}
function Initialize-MtKey {
    if (Test-Path "$($script:MtKey).pub") { return $true }
    $Dir = Split-Path $script:MtKey -Parent
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
    # RSA: ed25519 keys are not accepted on RouterOS 6 objects; keep one key type everywhere
    $P = Start-Process ssh-keygen.exe -ArgumentList @("-t", "rsa", "-b", "4096", "-N", '""', "-C", "netknife-mikrotik", "-f", (Quote-Arg $script:MtKey)) -NoNewWindow -Wait -PassThru
    return ($P.ExitCode -eq 0 -and (Test-Path "$($script:MtKey).pub"))
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
        Set-MtStatus "$($Rt.Name): $($J.id) · $($J.board) · RouterOS $($J.ver) · вход как $(if ($Rt.Ready) { 'butler-service (только чтение)' } else { "$($Rt.Admin) (админ — нажми «Команды подключения»)" })" "ok"
        Start-MtApRefresh $Rt
    }
}

# ---------------------------------------------------------------- changes on the router (butler-rw)

# Every write goes through here: the user sees the exact commands and the rollback, confirms; NetKnife saves
# /export under butler-service to %APPDATA%\NetKnife\mikrotik\<router>\export-before-<time>.rsc, then runs the
# script as butler-rw. $Script must be one line (RouterOS breaks do={} blocks of multi-line ssh arguments).
function Invoke-MtChange {
    param($R, [string]$Title, [string]$Script, [string]$Rollback = "", [scriptblock]$OnDone)
    if (-not $R.RwReady) { Show-Toast "$($R.Name): нет доступа butler-rw — выполни команды подключения" "warn"; return }
    $Detail = "Команды (под butler-rw):`n$Script$(if ($Rollback) { "`n`nОткат:`n$Rollback" })"
    if (-not (Show-Confirm $Title "Изменение на $($R.Name) ($($R.Host)). Перед ним NetKnife сохранит /export роутера." "Применить" -Detail $Detail)) { return }
    $script:MtChange = @{ R = $R; Title = $Title; Script = $Script; OnDone = $OnDone }
    Set-MtStatus "$($R.Name): сохраняю /export перед изменением…" "wait"
    Invoke-MtAsync $R "/export" -Name "mt-change" -TimeoutMs 60000 -OnResult {
        param($M)
        $X = $script:MtChange
        if ($M.Code -ne 0 -or $M.Out -notmatch '/system|/interface') { Set-MtStatus "$($X.R.Name): /export не получен — изменение не применено. $(Get-MtErrText $M)" "fail"; return }
        $Dir = Join-Path $env:APPDATA ("NetKnife\mikrotik\" + ($X.R.Name -replace '[\\/:*?"<>|]', '_'))
        if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
        $X.Export = Join-Path $Dir ("export-before-{0:yyyyMMdd-HHmmss}.rsc" -f (Get-Date))
        [IO.File]::WriteAllText($X.Export, $M.Out, [Text.UTF8Encoding]::new($false))
        Set-MtStatus "$($X.R.Name): применяю «$($X.Title)»…" "wait"
        Invoke-MtAsync $X.R $X.Script -Rw -Name "mt-change" -TimeoutMs 30000 -OnResult {
            param($M)
            $X = $script:MtChange
            $Ok = ($M.Code -eq 0 -and "$($M.Out)" -notmatch 'failure|error|expected|bad command|syntax')
            Set-MtStatus "$($X.R.Name): «$($X.Title)» — $(if ($Ok) { 'применено' } else { "ошибка: $(Get-MtErrText $M) $($M.Out.Trim())" }) · export до изменения: $($X.Export)" $(if ($Ok) { "ok" } else { "fail" })
            if ($X.OnDone) { & $X.OnDone $Ok $M }
        }
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
    $Psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $Psi.StandardErrorEncoding = [Text.Encoding]::UTF8
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

# Router card: name/address/port + the commands to paste into the router terminal + «Готово — проверить».
# $R: existing router, or a prefilled hashtable from discovery (SshOff = SSH service closed on the router).
function Show-MtConnectDialog {
    param($R)
    if (-not (Initialize-MtKey)) { Show-Toast "Не создал ключ $($script:MtKey)" "fail"; return }
    $D = New-Dialog "Подключить MikroTik" @"
<StackPanel>
    <TextBlock Text="Подключить MikroTik" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,14" FontSize="12.5" Text="Пароль админа не нужен. Открой терминал роутера (Winbox → New Terminal или WebFig → Terminal), вставь команды ниже (правый клик → Paste) и дождись строки BUTLER-USERS-OK. Затем «Готово — проверить». Команды создают два общих служебных пользователя (NetKnife, helpdesk, Claude): butler-service — только чтение, для диагностики; butler-rw — запись, только для изменений, которые ты подтверждаешь. Обоим добавляются ключи из реестра (этот ноутбук и ключи helpdesk из настроек); вход только по ключу. Существующих пользователей, их пароли и чужие ключи команды не меняют."/>
    <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="ОБЪЕКТ" Style="{StaticResource Caption}"/><TextBox x:Name="FName" Style="{StaticResource Field}" Tag="Алые Паруса 115"/></StackPanel>
        <StackPanel Grid.Column="2"><TextBlock Text="АДРЕС" Style="{StaticResource Caption}"/><TextBox x:Name="FHost" Style="{StaticResource MonoField}" Tag="192.168.115.1"/></StackPanel>
        <StackPanel Grid.Column="4"><TextBlock Text="SSH ПОРТ" Style="{StaticResource Caption}"/><TextBox x:Name="FPort" Style="{StaticResource MonoField}" Text="22"/></StackPanel>
    </Grid>
    <DockPanel Margin="0,14,0,6">
        <Button x:Name="FCopy" DockPanel.Dock="Right" Style="{StaticResource GhostBtn}" Padding="10,4"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8C8;" Style="{StaticResource Glyph}" FontSize="12"/><TextBlock Text="Копировать"/></StackPanel></Button>
        <TextBlock Text="КОМАНДЫ ДЛЯ ТЕРМИНАЛА РОУТЕРА" Style="{StaticResource Caption}" VerticalAlignment="Center"/>
    </DockPanel>
    <TextBox x:Name="FCode" Style="{StaticResource Code}" IsReadOnly="True" Height="190" FontSize="11.5" TextWrapping="NoWrap" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto"/>
    <TextBlock x:Name="FStatus" FontSize="12.5" TextWrapping="Wrap" Margin="2,10,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" MinWidth="170" Margin="8,0,0,0" IsDefault="True">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE73E;" Style="{StaticResource Glyph}"/><TextBlock Text="Готово — проверить"/></StackPanel>
        </Button>
    </StackPanel>
</StackPanel>
"@ 720
    $F = @{}; foreach ($N in @("FName", "FHost", "FPort", "FCopy", "FCode", "FStatus", "FOk")) { $F[$N] = $D.FindName($N) }
    $SshOff = [bool]($R -and $R.SshOff)
    if ($R) { $F.FName.Text = "$($R.Name)"; $F.FHost.Text = "$($R.Host)"; if ($R.Port) { $F.FPort.Text = "$($R.Port)" } }
    $script:MtConn = @{ D = $D; F = $F; R = $R; Keys = @(Get-MtKeyRegistry); SshOff = $SshOff; Router = $null; Done = $false }
    $Build = {
        $C = $script:MtConn
        $P = 0; [void][int]::TryParse($C.F.FPort.Text.Trim(), [ref]$P)
        $C.F.FCode.Text = Get-MtProvisionScript $C.Keys $(if ($C.SshOff -and $P) { $P } else { 0 })
    }
    & $Build
    $F.FPort.Add_TextChanged($Build)
    $F.FCopy.Add_Click({ Copy-Text $script:MtConn.F.FCode.Text "команды для роутера" })
    $SetSt = {
        param([string]$Text, [string]$Kind)
        $S = $script:MtConn.F.FStatus
        $S.Text = $Text; $S.Visibility = "Visible"
        $S.Foreground = Get-Brush $(switch ($Kind) { "ok" { "Ok" } "fail" { "Fail" } "wait" { "Warn" } default { "Sub" } })
    }
    $script:MtConn.SetSt = $SetSt
    # login check as butler-service; $Auto = silent first try when the card opens (the account may already exist on
    # the router — created by the helpdesk or another laptop — and already trust this key)
    $script:MtConn.Check = {
        param([bool]$Auto)
        $C = $script:MtConn
        if (-not $C.F.FName.Text.Trim() -or -not $C.F.FHost.Text.Trim()) { if (-not $Auto) { & $C.SetSt "Объект и адрес обязательны" "fail" }; return }
        if ($C.F.FPort.Text.Trim() -notmatch '^\d+$') { if (-not $Auto) { & $C.SetSt "Порт — число" "fail" }; return }
        $Old = $C.R
        # the account password belongs to the helpdesk (API logins); NetKnife works by key only and never stores it
        $C.Router = @{ Id = $(if ($Old -and $Old.Id) { $Old.Id } else { [guid]::NewGuid().ToString("N").Substring(0, 8) }); Name = $C.F.FName.Text.Trim(); Host = (Repair-TargetText $C.F.FHost); Port = [int]$C.F.FPort.Text.Trim()
            Admin = $(if ($Old) { "$($Old.Admin)" } else { "" }); AdminKey = $(if ($Old) { "$($Old.AdminKey)" } else { "" }); Ready = $true; RwReady = $false; PassEnc = "" }
        $C.Auto = $Auto
        $C.F.FOk.IsEnabled = $false
        & $C.SetSt $(if ($Auto) { "Проверяю, пускают ли уже butler-service и butler-rw с ключом этого ноутбука…" } else { "Вхожу на $($C.Router.Host):$($C.Router.Port) как butler-service…" }) "wait"
        Invoke-MtAsync $C.Router ':put ("##J" . [:serialize to=json ({"ver"=[/system resource get version]; "id"=[/system identity get name]; "board"=[/system resource get board-name]})])' -Name "mt-conn" -TimeoutMs 15000 -OnResult {
            param($M)
            $C = $script:MtConn
            if (-not $C -or -not $C.D.IsVisible) { return }
            $C.F.FOk.IsEnabled = $true
            if ($M.Code -ne 0) {
                $E = "$($M.Err)"
                if ($E -match 'Permission denied' -and $C.Auto) { & $C.SetSt "Доступа пока нет — выполни команды ниже в терминале роутера. Они сами проверяют пользователей: создадут butler-service и butler-rw, только если их нет, и добавят ключи." "sub"; return }
                $Why = $(if ($E -match 'Permission denied') { "вход как butler-service не принят: команды не выполнены или выполнены не полностью — в терминале должна появиться строка BUTLER-USERS-OK. Если вставлял частями — вставь заново целиком." }
                    elseif ($E -match 'refused') { "порт $($C.Router.Port) закрыт — проверь SSH-порт (IP → Services → ssh)" }
                    elseif ($E -match 'timed out|No route|Could not resolve') { "роутер недоступен: $E" }
                    else { Get-MtErrText $M })
                & $C.SetSt $Why "fail"; return
            }
            $J = ConvertFrom-MtJson $M.Out "##J"
            if (-not $J) { & $C.SetSt "Вход есть, но ответ не разобран — нужен RouterOS 7.13+ (:serialize)" "fail"; return }
            $C.Info = "$($J.id) · $($J.board) · RouterOS $($J.ver)"
            $C.F.FOk.IsEnabled = $false
            & $C.SetSt "butler-service — вход есть. Проверяю butler-rw…" "wait"
            Invoke-MtAsync $C.Router ':put "RW-OK"' -Rw -Name "mt-conn" -TimeoutMs 15000 -OnResult {
                param($M)
                $C = $script:MtConn
                if (-not $C -or -not $C.D.IsVisible) { return }
                $C.F.FOk.IsEnabled = $true
                if ($M.Code -ne 0 -or $M.Out -notmatch 'RW-OK') {
                    if ($C.Auto) { & $C.SetSt "butler-service пускает, butler-rw — нет: выполни команды ниже (существующее они не трогают, создадут butler-rw и добавят ключ)." "sub" }
                    else { & $C.SetSt "butler-rw не пускает: $(Get-MtErrText $M). Команды выполнены целиком? Должна появиться строка BUTLER-USERS-OK." "fail" }
                    return
                }
                $C.Router.RwReady = $true
                $C.Info += $(if ($C.Auto) { " · пользователи уже были" } else { "" })
                $C.Done = $true
                $C.D.DialogResult = $true
            }
        }
    }
    $F.FOk.Add_Click({ & $script:MtConn.Check $false })
    $D.Add_ContentRendered({
        if (-not $script:MtConn.F.FName.Text) { [void]$script:MtConn.F.FName.Focus() }
        if ($script:MtConn.F.FHost.Text.Trim()) { & $script:MtConn.Check $true }
    })
    [void]$D.ShowDialog()
    Stop-Worker "mt-conn"
    $C = $script:MtConn; $script:MtConn = $null
    if (-not $C.Done) { return }
    $New = $C.Router
    $script:Settings.Routers = @(Get-MtRouters | Where-Object { $_.Id -ne $New.Id }) + @($New)
    Save-Settings
    Refresh-MtList
    Set-MtStatus "$($New.Name): $($C.Info) · чтение butler-service, запись butler-rw (только с подтверждением)" "ok"
    Show-Toast "$($New.Name) подключён"
    Start-MtApRefresh $New { param($A) if ($script:WhInit) { try { Update-WhPrep } catch { } } }
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
    try { Repair-MtApCache } catch { Write-AppLog "mt cache repair: $_" }
    Refresh-MtList
    $Ui.SetMtAdd.Add_Click({ Show-MtConnectDialog $null })
    $Ui.SetMtFind.Add_Click({ Start-MtDiscovery })
    $Ui.SetMtKeys.Text = (@($script:Settings.MtExtraKeys) -join "`r`n")
    $Ui.SetMtKeys.Add_LostKeyboardFocus({
        $Bad = @(); $Ok = @()
        foreach ($Ln in ($Ui.SetMtKeys.Text -split "`r?`n")) {
            $Ln = $Ln.Trim(); if (-not $Ln) { continue }
            $P = $Ln -split '\s+'
            if ($P.Count -ge 3 -and $P[0] -match '^ssh-(rsa|ed25519)$' -and $P[2] -ne $script:MtKeyOwner) { $Ok += $Ln } else { $Bad += $Ln }
        }
        $script:Settings.MtExtraKeys = @($Ok); Save-Settings
        if ($Bad.Count) { Show-Toast "Пропущено строк: $($Bad.Count) — нужен формат «ssh-rsa AAAA… имя-системы»" "warn" } elseif ($Ok.Count) { Show-Toast "Ключей других систем: $($Ok.Count) — войдут в команды подключения" }
    })
    $Ui.SetMtEdit.Add_Click({ $R = Get-MtSelected; if ($R) { Show-MtConnectDialog $R } })
    $Ui.SetMtList.Add_MouseDoubleClick({ $R = Get-MtSelected; if ($R) { Show-MtConnectDialog $R } })
    $Ui.SetMtPrep.Add_Click({ $R = Get-MtSelected; if ($R) { Show-MtConnectDialog $R } })
    $Ui.SetMtTest.Add_Click({ $R = Get-MtSelected; if ($R) { Set-MtStatus "$($R.Name): подключаюсь…" "wait"; Test-MtRouter $R } })
    $Ui.SetMtAps.Add_Click({ $R = Get-MtSelected; if ($R) { Show-MtApsDialog $R } })
    $Ui.SetMtDel.Add_Click({
        $R = Get-MtSelected; if (-not $R) { return }
        if (-not (Show-Confirm "Убрать $($R.Name) из NetKnife?" "Удаляется только запись в NetKnife. Пользователи butler-service и butler-rw на роутере остаются (они общие с helpdesk)." "Убрать" -Danger)) { return }
        $script:Settings.Routers = @(Get-MtRouters | Where-Object { $_.Id -ne $R.Id }); Save-Settings; Refresh-MtList
    })
}
