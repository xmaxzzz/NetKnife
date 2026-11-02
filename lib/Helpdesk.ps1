# Helpdesk (help.butlerdc.ae) is the single source of site hosts: routers, servers, Proxmox, LM. NetKnife pulls the
# public part of its registry (sites, hosts, users, confirmed host keys) with the user's personal token (client type
# "netknife") and builds from it:
#   • the host list of the Hosts page — a group per site; hosts written by hand in ~/.ssh/config are «Локальные»;
#   • MikroTik routers for the roaming monitor and the Settings card (manual routers stay in settings.Routers);
#   • ~/.ssh/config.d/butler-helpdesk.conf + .known_hosts, included from ~/.ssh/config: plain `ssh <alias>` (and Claude
#     Code on this laptop) log in with NetKnife's key netknife_mt and strict host-key checking.
# No new keys. The token lives in Windows Credential Manager; it never reaches a file, a log or the generated config.
# Sync: at start, every 15 min and on demand, with ETag (304 = unchanged); the last answer is cached on disk, so the
# list works on site without internet. Contract: helpdesk docs/NETKNIFE_SYNC.md.

$script:HdDefaultUrl = "https://help.butlerdc.ae"
$script:HdApi = "/api/v1/access/ssh-hosts"
$script:HdCredTarget = "NetKnife/helpdesk"
$script:HdCachePath = Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }) "NetKnife\helpdesk-hosts.json"
$script:HdSyncMinutes = 15
$script:HdNameRe = '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$'
$script:HdHosts = $null      # normalized hosts of the cache (aliases already unique); $null = not built yet
$script:HdLast = @{ Kind = "none"; Text = "" }   # result of the last sync attempt (this session)

if (-not ("NetKnife.Cred" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace NetKnife {
public static class Cred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
        public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredWriteW(ref CREDENTIAL c, int flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredReadW(string target, int type, int flags, out IntPtr c);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredDeleteW(string target, int type, int flags);
    [DllImport("advapi32.dll")] static extern void CredFree(IntPtr p);
    const int Generic = 1, PersistLocalMachine = 2;
    public static void Write(string target, string user, string secret) {
        byte[] b = Encoding.Unicode.GetBytes(secret);
        var c = new CREDENTIAL { Type = Generic, TargetName = target, UserName = user, Persist = PersistLocalMachine, CredentialBlobSize = b.Length, CredentialBlob = Marshal.AllocHGlobal(b.Length) };
        try {
            Marshal.Copy(b, 0, c.CredentialBlob, b.Length);
            if (!CredWriteW(ref c, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.FreeHGlobal(c.CredentialBlob); Array.Clear(b, 0, b.Length); }
    }
    public static string Read(string target) {
        IntPtr p;
        if (!CredReadW(target, Generic, 0, out p)) return null;
        try {
            var c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            if (c.CredentialBlobSize == 0) return "";
            byte[] b = new byte[c.CredentialBlobSize];
            Marshal.Copy(c.CredentialBlob, b, 0, b.Length);
            return Encoding.Unicode.GetString(b);
        } finally { CredFree(p); }
    }
    public static void Delete(string target) { CredDeleteW(target, Generic, 0); }
}
}
'@
}

# ---------------------------------------------------------------- settings, token, cache

function Get-HdSettings {
    if (-not ($script:Settings.Helpdesk -is [System.Collections.IDictionary])) { $script:Settings.Helpdesk = @{ Url = $script:HdDefaultUrl } }
    return $script:Settings.Helpdesk
}
function Get-HdUrl { $U = "$((Get-HdSettings).Url)".Trim().TrimEnd('/'); if ($U) { return $U }; return $script:HdDefaultUrl }

function Get-HdToken { try { return [NetKnife.Cred]::Read($script:HdCredTarget) } catch { return $null } }
function Set-HdToken { param([string]$Token) [NetKnife.Cred]::Write($script:HdCredTarget, "netknife", $Token) }
function Remove-HdToken { try { [NetKnife.Cred]::Delete($script:HdCredTarget) } catch { } }

function Write-HdLog { param([string]$Text) if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) { Write-AppLog "helpdesk: $Text" } }

function Read-HdCache {
    if (-not (Test-Path -LiteralPath $script:HdCachePath)) { return $null }
    try { return (Get-Content -LiteralPath $script:HdCachePath -Raw | ConvertFrom-Json -AsHashtable) } catch { return $null }
}

function Save-HdCache {
    param([hashtable]$Cache)
    $Dir = Split-Path $script:HdCachePath -Parent
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $Tmp = "$($script:HdCachePath).$PID.tmp"
    [IO.File]::WriteAllText($Tmp, ($Cache | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($Tmp, $script:HdCachePath, $true)
}

# ConvertFrom-Json turns ISO strings into DateTime by itself — accept both
function ConvertTo-HdDate {
    param($V)
    if ($V -is [DateTime]) { return $V.ToLocalTime() }
    $D = [DateTime]::MinValue
    if ([DateTime]::TryParse("$V", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$D)) { return $D.ToLocalTime() }
    return $null
}

function Format-HdTime {
    param($V, [switch]$Full)
    $D = ConvertTo-HdDate $V
    if (-not $D) { return "?" }
    if ($Full) { return $D.ToString("yyyy-MM-dd HH:mm") }
    if ($D.Date -eq [DateTime]::Today) { return $D.ToString("HH:mm") }
    return $D.ToString("dd.MM HH:mm")
}

# ---------------------------------------------------------------- registry → hosts (everything validated)

function Get-HdConfPath { return Join-Path (Join-Path $script:SshDir "config.d") "butler-helpdesk.conf" }
function Get-HdKnownHostsPath { return Join-Path (Join-Path $script:SshDir "config.d") "butler-helpdesk.known_hosts" }

function Test-HdHostName { param([string]$H) return ($H -match '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$' -or $H -match '^[0-9A-Fa-f:]{2,39}$') }

# Server text ends up in ssh config: one value per line, no control characters
function Get-HdCleanText { param([string]$S) return ("$S" -replace '[\x00-\x1F\x7F]', ' ').Trim() }

# Only "type base64" is taken from the server's line; the host part is ours ("alias,[host]:port" of this very entry —
# the config pins it with HostKeyAlias), so a line with "*" or another host can never vouch for something else.
# @cert-authority / @revoked are not accepted.
function ConvertTo-HdHostKeyLine {
    param([string]$Line, [string]$Spec)
    if ("$Line" -match '[\r\n]') { return $null }
    $P = @("$Line".Trim() -split '\s+')
    if ($P.Count -lt 2 -or $P[0].StartsWith("@")) { return $null }
    for ($i = 0; $i -lt $P.Count - 1; $i++) {
        if ($P[$i] -match '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)$' -and $P[$i + 1] -match '^[A-Za-z0-9+/]{16,}={0,2}$') {
            return "$Spec $($P[$i]) $($P[$i + 1])"
        }
    }
    return $null
}

# $Taken: aliases already used by hand-written hosts. ssh aliases are global: a name used twice (two sites, or a host
# in ~/.ssh/config) gets ".<site>" appended — the hand-written host keeps its name.
function ConvertTo-HdHosts {
    param($Data, [string[]]$Taken = @())
    if (-not ($Data -is [System.Collections.IDictionary])) { return @() }
    $Sites = @{}
    foreach ($S in @($Data['sites'] | Where-Object { $_ -is [System.Collections.IDictionary] })) { $Sites["$($S['slug'])"] = Get-HdCleanText $S['name'] }
    $Raw = @()
    foreach ($X in @($Data['hosts'] | Where-Object { $_ -is [System.Collections.IDictionary] })) {
        if ($X['deleted'] -eq $true) { continue }   # tombstone (only in answers with since=)
        $Alias = "$($X['alias'])"; $Addr = "$($X['host'])"; $Site = "$($X['site'])"; $Kind = "$($X['kind'])"
        $Port = 22
        if ($null -ne $X['port'] -and "$($X['port'])" -ne "" -and -not [int]::TryParse("$($X['port'])", [ref]$Port)) { $Port = -1 }
        # users: [{role: ro|rw|other, name}]; "other" (e.g. the backup engine's login) is not ours to use
        $Ro = ""; $Rw = ""
        foreach ($U in @($X['users'] | Where-Object { $_ -is [System.Collections.IDictionary] })) {
            if ("$($U['role'])" -eq "ro" -and -not $Ro) { $Ro = "$($U['name'])" }
            if ("$($U['role'])" -eq "rw" -and -not $Rw) { $Rw = "$($U['name'])" }
        }
        $Why = $(if ($Alias -notmatch $script:HdNameRe) { "alias" }
            elseif (-not (Test-HdHostName $Addr)) { "host" }
            elseif ($Port -lt 1 -or $Port -gt 65535) { "port" }
            elseif ($Ro -and $Ro -notmatch $script:HdNameRe) { "users.ro" }
            elseif ($Rw -and $Rw -notmatch $script:HdNameRe) { "users.rw" }
            elseif ($Site -and $Site -notmatch $script:HdNameRe) { "site" }
            elseif ($Kind -and $Kind -notmatch $script:HdNameRe) { "kind" })
        if ($Why) { Write-HdLog "хост «$(Get-HdCleanText $Alias)» пропущен: поле $Why не прошло проверку"; continue }
        $Spec = "$Alias," + $(if ($Port -eq 22) { $Addr } else { "[$Addr]:$Port" })
        $Keys = @(@($X['known_hosts']) | Where-Object { $_ } | ForEach-Object { ConvertTo-HdHostKeyLine "$_" $Spec } | Where-Object { $_ } | Select-Object -Unique)
        $Raw += [pscustomobject]@{
            Alias = $Alias; RawAlias = $Alias; Site = $Site
            SiteName = $(if ($Sites[$Site]) { $Sites[$Site] } elseif ($Site) { $Site } else { "Helpdesk" })
            Kind = $Kind; HostName = $Addr; Port = $Port; User = $Ro; RwUser = $Rw
            Route = $(if ("$($X['route'])" -match '^[a-z_]{1,20}$') { "$($X['route'])" } else { "" })
            KnownHosts = $Keys; Owners = @(@($X['expected_key_owners']) | Where-Object { "$_" -match $script:HdNameRe } | ForEach-Object { "$_" })
            Status = $(if ("$($X['status'])" -match '^[a-z_]{1,24}$') { "$($X['status'])" } else { "" }); LastCheck = $X['updated_at']
            # the contract: no confirmed host key or no ro user — listed, but not in ssh config
            Skip = $(if (-not $Keys.Count) { "нет подтверждённого ключа хоста" } elseif (-not $Ro) { "нет ro-пользователя" } else { "" })
        }
    }
    $Count = @{}
    foreach ($H in $Raw) { $Count[$H.Alias] = 1 + [int]$Count[$H.Alias] }
    $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($T in $Taken) { if ($T) { [void]$Seen.Add($T) } }
    $Out = foreach ($H in $Raw) {
        if (($Count[$H.Alias] -gt 1 -or $Seen.Contains($H.Alias)) -and $H.Site) { $H.Alias = "$($H.Alias).$($H.Site)" }
        $Base = $H.Alias; $N = 2
        while (-not $Seen.Add($H.Alias)) { $H.Alias = "$Base-$N"; $N++ }
        $H
    }
    return @($Out)
}

# rebuilds $script:HdHosts from the cache; hand-written aliases come from ~/.ssh/config
function Update-HdHosts {
    param([string[]]$LocalAliases)
    $C = Read-HdCache
    if (-not $C -or -not $C.Data) { $script:HdHosts = @(); return }
    if ($null -eq $LocalAliases) { $LocalAliases = @(Get-SshHosts | ForEach-Object Alias) }
    $script:HdHosts = @(ConvertTo-HdHosts $C.Data $LocalAliases)
}

function Get-HdHostList { if ($null -eq $script:HdHosts) { Update-HdHosts }; return @($script:HdHosts) }

# ---------------------------------------------------------------- ~/.ssh/config.d/butler-helpdesk.conf

# absolute path with forward slashes: valid for ssh no matter which file includes the config
function Get-HdSshValue { param([string]$Path) $V = [IO.Path]::GetFullPath($Path).Replace("\", "/"); if ($V -match '\s') { return "`"$V`"" }; return $V }

function Get-HdSshConfigText {
    param($Hosts, [string]$Url, [string]$Synced)
    $Key = Get-HdSshValue $script:MtKey
    $Kh = Get-HdSshValue (Get-HdKnownHostsPath)
    $L = @(
        "# NetKnife: хосты объектов из Helpdesk $(Get-HdCleanText $Url) — данные от $(Get-HdCleanText $Synced)."
        "# Файл перезаписывается синхронизацией NetKnife: хосты правятся в Helpdesk, не здесь."
        "# Вход — ключом netknife-mikrotik этого ноутбука, ключи хостов — только подтверждённые в Helpdesk."
        "# Пользователь — для диагностики (только чтение); изменения — только через NetKnife с подтверждением."
        ""
    )
    foreach ($H in @($Hosts | Where-Object { -not $_.Skip })) {
        $Note = @($H.SiteName, $H.Kind) | Where-Object { $_ }
        if ($H.Route -and $H.Route -ne "direct") { $Note += "маршрут $($H.Route) — напрямую может быть недоступен" }
        $L += "Host $($H.Alias)"
        $L += "    # $($Note -join ' · ')"
        $L += "    HostName $($H.HostName)"
        if ($H.Port -ne 22) { $L += "    Port $($H.Port)" }
        $L += "    User $($H.User)"
        $L += "    IdentityFile $Key"
        $L += "    IdentitiesOnly yes"
        $L += "    HostKeyAlias $($H.RawAlias)"
        $L += "    StrictHostKeyChecking yes"
        $L += "    UserKnownHostsFile $Kh"
        $L += ""
    }
    $Off = @($Hosts | Where-Object { $_.Skip })
    if ($Off.Count) { $L += "# Не вошли: " + (($Off | ForEach-Object { "$($_.Alias) — $($_.Skip)" }) -join "; ") }
    return ($L -join "`n")
}

function Write-HdTextIfChanged {
    param([string]$Path, [string]$Text)
    if ((Test-Path -LiteralPath $Path) -and [IO.File]::ReadAllText($Path) -ceq $Text) { return $false }
    $Dir = Split-Path $Path -Parent
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
    return $true
}

# "Include config.d/butler-helpdesk.conf" at the very top of ~/.ssh/config (inside a Host block it would apply only to
# that block). Returns the backup path when the main config was changed, "" when the line was already there.
function Add-HdInclude {
    $Text = $(if (Test-Path -LiteralPath $script:ConfigPath) { [IO.File]::ReadAllText($script:ConfigPath) } else { "" })
    if ($Text -match '(?mi)^[ \t]*Include[ \t=]+\S*butler-helpdesk\.conf') { return "" }
    $Backup = $(if (Test-Path -LiteralPath $script:ConfigPath) { Backup-Config } else { "(config не было)" })
    $Nl = $(if ($Text -match "`r`n") { "`r`n" } else { "`n" })
    $New = "# NetKnife: хосты объектов из Helpdesk (файл обновляет синхронизация)$($Nl)Include config.d/$(Split-Path (Get-HdConfPath) -Leaf)$Nl$Nl" + $Text
    if (-not (Test-Path $script:SshDir)) { New-Item -ItemType Directory -Path $script:SshDir -Force | Out-Null }
    [IO.File]::WriteAllText($script:ConfigPath, $New, [Text.UTF8Encoding]::new($false))
    return $Backup
}

# Writes both files from the cache (only when the text changed) and makes sure the main config includes them.
function Write-HdSshFiles {
    $C = Read-HdCache
    if (-not $C -or -not $C.Data) { return $null }
    $Hosts = @(Get-HdHostList)
    $Kh = @($Hosts | ForEach-Object { $_.KnownHosts } | Where-Object { $_ } | Select-Object -Unique)
    $A = Write-HdTextIfChanged (Get-HdKnownHostsPath) ((@($Kh) -join "`n") + "`n")
    $B = Write-HdTextIfChanged (Get-HdConfPath) (Get-HdSshConfigText $Hosts $C.Url (Format-HdTime $C.DataAt -Full))
    return @{ Hosts = $Hosts.Count; Changed = ($A -or $B); Backup = (Add-HdInclude) }
}

function Remove-HdSshFiles {
    foreach ($P in @((Get-HdConfPath), (Get-HdKnownHostsPath))) { if (Test-Path -LiteralPath $P) { Remove-Item -LiteralPath $P -Force } }
}

# ---------------------------------------------------------------- sync

# thread job: only the request, the rest runs on the UI thread (Receive-HdSync)
$script:HdSyncBody = {
    param($Q, $Ctl, $Uri, $Token, $ETag, $Version)
    $H = @{ Authorization = "Bearer $Token"; "User-Agent" = "NetKnife/$Version"; Accept = "application/json" }
    if ($ETag) { $H["If-None-Match"] = $ETag }
    try {
        $R = Invoke-WebRequest -Uri $Uri -Headers $H -TimeoutSec 20 -SkipHttpErrorCheck -ErrorAction Stop
        $Txt = $(if ($R.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($R.Content) } else { "$($R.Content)" })
        $Q.Enqueue(@{ Type = "hd"; Code = [int]$R.StatusCode; ETag = "$(@($R.Headers['ETag']) | Select-Object -First 1)"; RetryAfter = "$(@($R.Headers['Retry-After']) | Select-Object -First 1)"; Body = $Txt })
    } catch { $Q.Enqueue(@{ Type = "hd"; Code = 0; Error = "$($_.Exception.Message)" }) }
}

# Applies one answer to the cache. Returns @{ Kind = ok|same|fail|offline; Text; Changed }.
function Receive-HdSync {
    param($M, [string]$Url)
    $Now = [DateTime]::UtcNow.ToString("o")
    $C = Read-HdCache
    if ($C -and "$($C.Url)" -ne $Url) { $C = $null }   # another server: its copy is not ours
    $Copy = $(if ($C -and $C.Synced) { "работаю по копии от $(Format-HdTime $C.Synced)" } else { "копии данных нет" })
    switch ([int]$M.Code) {
        200 {
            try { $J = $M.Body | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $J = $null }
            if (-not ($J -is [System.Collections.IDictionary]) -or -not ($J.ContainsKey('hosts'))) { return @{ Kind = "fail"; Text = "ответ сервера не разобран (нет hosts) — $Copy" } }
            $ETag = "$($M.ETag)"
            Save-HdCache @{ Url = $Url; ETag = $ETag; Synced = $Now; DataAt = $Now; Data = $J }
            return @{ Kind = "ok"; Text = "синхронизировано"; Changed = $true }
        }
        304 {
            if (-not $C) { return @{ Kind = "fail"; Text = "сервер ответил 304, а копии нет — нажми «Проверить»" } }
            $C.Synced = $Now; Save-HdCache $C
            return @{ Kind = "same"; Text = "без изменений"; Changed = $false }
        }
        0 { return @{ Kind = "offline"; Text = "нет связи с Helpdesk — $Copy" } }
    }
    # errors come as {"code": "...", "detail": "...", "fields": {...}}
    $Code = ""
    try { $E = $M.Body | ConvertFrom-Json -AsHashtable -ErrorAction Stop; if ($E -is [System.Collections.IDictionary]) { $Code = "$($E['code'])" } } catch { }
    $New = "выпусти новый: Helpdesk → профиль → «Мои устройства» → тип NetKnife"
    $Why = switch ($Code) {
        "token_expired" { "срок токена истёк — $New" }
        "token_revoked" { "токен отозван — $New" }
        "token_scope" { "это токен не для NetKnife — $New" }
        "forbidden" { "у владельца токена нет права access.hosts.view ни на одном объекте" }
        "rate_limited" { "слишком частые запросы — повтор через $(if ($M.RetryAfter) { "$($M.RetryAfter) с" } else { 'минуту' })" }
        default {
            switch ([int]$M.Code) {
                401 { "токен не принят — $New" }
                403 { "доступ запрещён" }
                404 { "на сервере нет API синхронизации хостов" }
                429 { "слишком частые запросы — повтор позже" }
                default { "ошибка сервера" }
            }
        }
    }
    return @{ Kind = "fail"; Text = "$Why (HTTP $($M.Code)$(if ($Code) { ", $Code" })) — $Copy" }
}

function Test-HdConnected { return [bool](Get-HdToken) }

function Start-HdSync {
    param([switch]$Full, [switch]$Manual)
    $Token = Get-HdToken
    if (-not $Token) { if ($Manual) { Show-Toast "Helpdesk: сначала сохрани токен (Настройки → Helpdesk)" "warn" }; return }
    if (Test-WorkerRunning "hd-sync") { return }
    $Url = Get-HdUrl
    $C = Read-HdCache
    $ETag = $(if (-not $Full -and $C -and "$($C.Url)" -eq $Url -and $C.Data) { "$($C.ETag)" } else { "" })
    $script:HdLast = @{ Kind = "wait"; Text = "синхронизирую…" }
    Update-HdStatus
    [void](Start-Worker -Name "hd-sync" -Body $script:HdSyncBody -ArgList @("$Url$script:HdApi", $Token, $ETag, $script:AppVersion) -State @{ Url = $Url; Manual = [bool]$Manual } -OnMessage {
        param($M)
        if ($M.Type -ne "hd") { return }
        if ($M.Code -eq 0) { Write-HdLog "нет связи: $($M.Error)" } elseif ($M.Code -ge 400) { Write-HdLog "HTTP $($M.Code)" }
        $R = Receive-HdSync $M $State.Url
        $script:HdLast = $R
        if ($R.Kind -in @("ok", "same")) { Update-HdApply -Quiet:(-not $State.Manual) }
        Update-HdStatus
        if ($State.Manual) {
            $N = @(Get-HdHostList).Count
            Show-Toast "Helpdesk: $($R.Text)$(if ($R.Kind -in @('ok', 'same')) { " · хостов $N" })" $(if ($R.Kind -in @("ok", "same")) { "info" } else { "warn" })
        }
    })
}

# after new data: hosts, routers, ssh files
function Update-HdApply {
    param([switch]$Quiet)
    $script:HdHosts = $null
    if (Get-Command Refresh-Ssh -ErrorAction SilentlyContinue) { try { Refresh-Ssh } catch { Write-HdLog "refresh: $_" } }
    else { try { $W = Write-HdSshFiles; if ($W -and $W.Backup) { Write-HdLog "Include добавлен в ~/.ssh/config, бэкап $($W.Backup)" } } catch { Write-HdLog "ssh files: $_" } }
    if (Get-Command Refresh-MtList -ErrorAction SilentlyContinue) { try { Refresh-MtList } catch { } }
}

function Get-HdStatusText {
    $C = Read-HdCache
    $Has = [bool](Get-HdToken)
    if (-not $Has -and -not $C) { return @{ Kind = "none"; Text = "не подключён — нужен токен" } }
    $Data = $(if ($C -and $C.Synced) { "данные синхронизированы $(Format-HdTime $C.Synced) · объектов $(@($C.Data['sites']).Count) · хостов $(@(Get-HdHostList).Count)" } else { "данных ещё нет" })
    if (-not $Has) { return @{ Kind = "fail"; Text = "токена нет — $Data" } }
    switch ($script:HdLast.Kind) {
        "wait"    { return @{ Kind = "wait"; Text = "синхронизирую… · $Data" } }
        "offline" { return @{ Kind = "wait"; Text = $script:HdLast.Text } }
        "fail"    { return @{ Kind = "fail"; Text = $script:HdLast.Text } }
    }
    return @{ Kind = $(if ($C) { "ok" } else { "none" }); Text = $Data }
}

# one short line for the Hosts page subtitle
function Get-HdSubText {
    $C = Read-HdCache
    if (-not $C -or -not $C.Synced) { return "" }
    if ($script:HdLast.Kind -in @("offline", "fail")) { return "Helpdesk: копия от $(Format-HdTime $C.Synced)" }
    return "Helpdesk: синхр. $(Format-HdTime $C.Synced)"
}

function Start-HdTimer {
    if ($script:HdTimer) { return }
    $script:HdTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:HdTimer.Interval = [TimeSpan]::FromMinutes($script:HdSyncMinutes)
    $script:HdTimer.Add_Tick({ try { Start-HdSync } catch { Write-HdLog "timer: $_" } })
    $script:HdTimer.Start()
    # files from the offline copy (e.g. they were deleted by hand), then a fresh sync
    try { if (Read-HdCache) { [void](Write-HdSshFiles) } } catch { Write-HdLog "ssh files: $_" }
    Start-HdSync
}

# ---------------------------------------------------------------- items for the Hosts page and MikroTik

function Get-HdSshItems {
    foreach ($H in Get-HdHostList) {
        [pscustomobject]@{
            Alias = $H.Alias; HostName = $H.HostName; User = $H.User; Port = "$($H.Port)"; IdentityFile = $script:MtKey; ProxyJump = ""
            Shared = $false; Source = "helpdesk"; Group = $H.SiteName; Hd = $H
        }
    }
}

# tail of the address line in the host card
function Get-HdHostNote {
    param($H)
    if (-not $H) { return "" }
    $P = @($H.SiteName, $H.Kind) | Where-Object { $_ }
    if ($H.Status) { $P += "статус $($H.Status)$(if ($H.LastCheck) { " ($(Format-HdTime $H.LastCheck))" })" }
    if ($H.Route -and $H.Route -ne "direct") { $P += "маршрут $($H.Route)" }
    if ($H.Skip) { $P += "нет в ssh config: $($H.Skip)" }
    return "`n Helpdesk: $($P -join ' · ')"
}

function Get-HdRouters {
    foreach ($H in @(Get-HdHostList | Where-Object { $_.Kind -eq "mikrotik" })) {
        @{
            Id = "hd:$($H.Site)/$($H.RawAlias)"; Name = "$($H.SiteName) · $($H.Alias)"; Host = $H.HostName; Port = $H.Port
            Ready = $true; RwReady = [bool]$H.RwUser; Admin = ""; AdminKey = ""; PassEnc = ""
            Source = "helpdesk"; Alias = $H.Alias; User = $H.User; RwUser = $H.RwUser; KnownHostsFile = (Get-HdKnownHostsPath)
        }
    }
}

function Show-HdManaged {
    param([string]$What)
    Show-Toast "$What — из Helpdesk: правится в Helpdesk, NetKnife подтянет при синхронизации" "warn"
}

# a router prepared by hand is not in the registry yet — the API for adding hosts is not there, so open Helpdesk
function Request-HdAddHost {
    param($R)
    if (-not (Test-HdConnected)) { return }
    if (@(Get-HdHostList | Where-Object { $_.HostName -eq "$($R.Host)" -and $_.Port -eq [int]$R.Port }).Count) { return }
    if (Show-Confirm "Добавить $($R.Name) в Helpdesk?" "Хостов объектов NetKnife сам не заводит: доступы живут в Helpdesk. Открою Helpdesk — заведи там хост $($R.Host):$($R.Port) (пользователи butler-service / butler-rw уже созданы). После синхронизации он появится в NetKnife." "Открыть Helpdesk") {
        Start-Process (Get-HdUrl)
    }
}

# ---------------------------------------------------------------- Settings card

function Update-HdStatus {
    if (-not $Ui -or -not $Ui.SetHdStatus) { return }
    $S = Get-HdStatusText
    $Ui.SetHdStatus.Text = $S.Text
    $Ui.SetHdStatus.Foreground = Get-Brush $(switch ($S.Kind) { "ok" { "Ok" } "fail" { "Fail" } "wait" { "Warn" } default { "Sub" } })
    $Has = [bool](Get-HdToken)
    $Ui.SetHdTokenState.Text = $(if ($Has) { "токен сохранён в диспетчере учётных данных Windows" } else { "токена нет" })
    $Ui.SetHdForget.Visibility = $(if ($Has -or (Read-HdCache)) { "Visible" } else { "Collapsed" })
    if ($script:Page -eq "hosts") { Update-PageSub }
}

function Initialize-HdSettings {
    if (-not $Ui.SetHdUrl) { return }
    $Ui.SetHdUrl.Text = Get-HdUrl
    $Ui.SetHdUrl.Add_LostKeyboardFocus({
        $U = $Ui.SetHdUrl.Text.Trim().TrimEnd('/')
        if (-not $U) { $U = $script:HdDefaultUrl }
        if ($U -notmatch '^https://[A-Za-z0-9.-]+(:\d+)?$') { Show-Toast "Адрес Helpdesk — https://имя-сервера" "warn"; $Ui.SetHdUrl.Text = Get-HdUrl; return }
        if ($U -ne (Get-HdUrl)) { (Get-HdSettings).Url = $U; Save-Settings; Update-HdStatus }
    })
    $Ui.SetHdSave.Add_Click({
        $T = $Ui.SetHdToken.Password.Trim()
        if (-not $T) { Show-Toast "Вставь токен из Helpdesk → профиль → «Мои устройства»" "warn"; return }
        if ($T -match '\s') { Show-Toast "В токене не должно быть пробелов" "warn"; return }
        try { Set-HdToken $T } catch { Show-Toast "Не сохранил токен: $($_.Exception.Message)" "fail"; return }
        $Ui.SetHdToken.Clear()
        Update-HdStatus
        Start-HdSync -Full -Manual
    })
    $Ui.SetHdCheck.Add_Click({ Start-HdSync -Full -Manual })
    $Ui.SetHdSync.Add_Click({ Start-HdSync -Manual })
    $Ui.SetHdOpen.Add_Click({ Start-Process (Get-HdUrl) })
    $Ui.SetHdForget.Add_Click({
        if (-not (Show-Confirm "Отключить Helpdesk?" "Удалятся токен из диспетчера учётных данных, копия списка хостов и файлы ~/.ssh/config.d/butler-helpdesk.*. Строка Include в ~/.ssh/config останется (без файла она ничего не делает). На роутерах и в Helpdesk ничего не меняется." "Отключить" -Danger)) { return }
        Stop-Worker "hd-sync"
        Remove-HdToken
        if (Test-Path -LiteralPath $script:HdCachePath) { Remove-Item -LiteralPath $script:HdCachePath -Force }
        Remove-HdSshFiles
        $script:HdLast = @{ Kind = "none"; Text = "" }
        Update-HdApply
        Update-HdStatus
        Show-Toast "Helpdesk отключён"
    })
    Update-HdStatus
}
