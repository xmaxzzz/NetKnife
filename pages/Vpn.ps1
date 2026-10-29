# Page: VPN. Profiles are vless:// / hysteria2:// / mierus:// / naive+https:// share links. One engine process
# (xray or mihomo; for NaïveProxy naive.exe + mihomo in front of it) runs the selected profile as a local
# mixed (SOCKS5+HTTP) proxy and NetKnife sets it as the Windows system proxy. Engines are downloaded from
# pinned official GitHub releases (SHA256 checked) after confirmation.
# TUN mode (whole-system, needs admin + wintun) is a later step; the mihomo config builder already takes -Mode.

$script:VpnDir = Join-Path $script:DataDir "vpn"      # engine exes + generated configs + vpn.log
$script:VpnPidFile = Join-Path $script:DataDir "vpn.pid"
$script:VpnItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:Vpn = $null              # @{ P; Id; Started; Lines; ErrTask; Out; Error; Notified; Port }
$script:VpnPumpSw = [System.Diagnostics.Stopwatch]::StartNew()
$script:VpnWatchTick = 0
$script:VpnPending = $null       # profile id to connect once its engine is installed
$script:VpnInstall = $null       # @{ Version; Url; Size } while a download is offered/running

if (-not ("NetKnife.WinInet" -as [type])) {
    Add-Type -Namespace NetKnife -Name WinInet -MemberDefinition @"
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
"@
}

# ---------------------------------------------------------------- profiles

function Get-VpnProfiles { return @($script:Settings.VpnProfiles | Where-Object { $_ -and $_.Id -and $_.Link }) }

function Get-VpnPort {
    $P = 0
    try { $P = [int]$script:Settings.VpnPort } catch { }
    if ($P -lt 1 -or $P -gt 65535) { $P = 2080 }
    return $P
}

# vless://uuid@host:port?security=reality&pbk=..&sni=..&fp=..&sid=..&type=tcp&flow=xtls-rprx-vision#name
# hysteria2://password@host:port?sni=..&insecure=1&obfs=salamander&obfs-password=..#name   (hy2:// alias)
# mierus://user:pass@host?port=6666&protocol=TCP&port=9998-9999&protocol=UDP&multiplexing=MULTIPLEXING_HIGH&profile=default#name
#   (`mieru export` URL: port/protocol come in pairs; mihomo takes one binding per proxy — the first TCP one, else the first)
# naive+https://user:pass@host[:443]#name · naive+quic://…   (parsed only: no engine runs NaïveProxy yet)
# A link that isn't one of these, or misses a required part, gives $null; Get-ProxyLinkError says why.
function ConvertFrom-ProxyLink {
    param([string]$Link)
    $R = ConvertFrom-ProxyLinkCore $Link
    if ($R -is [string]) { return $null }
    return $R
}

function Get-ProxyLinkError {
    param([string]$Link)
    $R = ConvertFrom-ProxyLinkCore $Link
    if ($R -is [string]) { return $R }
    return ""
}

# Returns the parsed profile, or a Russian reason string. Reasons never quote the link (it holds the password).
function ConvertFrom-ProxyLinkCore {
    param([string]$Link)
    $Link = "$Link".Trim()
    if ($Link -notmatch '^(?i)(vless|hysteria2|hy2|mierus|naive\+https|naive\+quic)://(.+)$') { return "не ссылка vless://, hysteria2://, mierus:// или naive+https://" }
    $Scheme = $Matches[1].ToLower(); $Rest = $Matches[2]
    $Type = switch ($Scheme) { "hy2" { "hysteria2" } "mierus" { "mieru" } { $_ -like "naive+*" } { "naive" } default { $Scheme } }

    $Name = ""
    $Hash = $Rest.IndexOf('#')
    if ($Hash -ge 0) { $Name = [Uri]::UnescapeDataString($Rest.Substring($Hash + 1)); $Rest = $Rest.Substring(0, $Hash) }

    $Query = @{}
    $Pairs = [System.Collections.Generic.List[object]]::new()   # in link order, repeats kept (mieru port/protocol)
    $Qm = $Rest.IndexOf('?')
    if ($Qm -ge 0) {
        foreach ($Kv in ($Rest.Substring($Qm + 1) -split '&')) {
            if (-not $Kv) { continue }
            $Eq = $Kv.IndexOf('=')
            if ($Eq -lt 0) { $Query[$Kv] = ""; continue }
            $K = $Kv.Substring(0, $Eq); $V = [Uri]::UnescapeDataString($Kv.Substring($Eq + 1).Replace('+', '%2B'))
            $Query[$K] = $V; $Pairs.Add(@($K, $V))
        }
        $Rest = $Rest.Substring(0, $Qm)
    }
    $Rest = $Rest.TrimEnd('/')

    $At = $Rest.LastIndexOf('@')
    if ($At -lt 0) { return "нет части «логин@сервер»" }
    $RawAuth = $Rest.Substring(0, $At)
    $HostPort = $Rest.Substring($At + 1)
    $User = ""; $Pass = ""
    if ($Type -in @("mieru", "naive")) {
        # split before unescaping: an escaped ':' (%3A) belongs to the name or password
        $C = $RawAuth.IndexOf(':')
        if ($C -lt 0) { return "нет пароля: нужно «пользователь:пароль@сервер»" }
        $User = [Uri]::UnescapeDataString($RawAuth.Substring(0, $C)); $Pass = [Uri]::UnescapeDataString($RawAuth.Substring($C + 1))
        if (-not $User) { return "пустое имя пользователя" }
        if (-not $Pass) { return "пустой пароль" }
        $Auth = $User
    } else {
        $Auth = [Uri]::UnescapeDataString($RawAuth)
        if (-not $Auth) { return $(if ($Type -eq "vless") { "пустой UUID" } else { "пустой пароль" }) }
    }

    # mieru carries ports in the query; naive defaults to 443
    if ($HostPort -match '^(\[[^\]]+\]|[^:\[\]]+)(?::(\d{1,5}))?$') { $Srv = $Matches[1].Trim('[', ']'); $PortStr = $Matches[2] } else { return "адрес сервера не разбирается" }
    if (-not $Srv) { return "пустой адрес сервера" }
    $Transport = ""; $PortRange = ""; $Proto = ""
    switch ($Type) {
        "mieru" {
            $Ports = @($Pairs | Where-Object { $_[0] -eq "port" } | ForEach-Object { $_[1] })
            $Protos = @($Pairs | Where-Object { $_[0] -eq "protocol" } | ForEach-Object { "$($_[1])".ToUpper() })
            if (-not $Ports.Count) { return "нет параметра port" }
            if ($Protos.Count -and $Protos.Count -ne $Ports.Count) { return "параметров port ($($Ports.Count)) и protocol ($($Protos.Count)) должно быть поровну" }
            $Binds = @(for ($i = 0; $i -lt $Ports.Count; $i++) { [pscustomobject]@{ Port = $Ports[$i]; Proto = $(if ($Protos.Count) { $Protos[$i] } else { "TCP" }) } })
            foreach ($B in $Binds) {
                if ($B.Proto -notin @("TCP", "UDP")) { return "protocol «$($B.Proto)»: ожидаю TCP или UDP" }
                if ($B.Port -notmatch '^(\d{1,5})(?:-(\d{1,5}))?$') { return "port «$($B.Port)»: ожидаю число или диапазон 1000-2000" }
                $Lo = [int]$Matches[1]; $Hi = $(if ($Matches[2]) { [int]$Matches[2] } else { $Lo })
                if ($Lo -lt 1 -or $Hi -gt 65535 -or $Lo -gt $Hi) { return "port «$($B.Port)» вне 1–65535" }
            }
            $B = @($Binds | Where-Object { $_.Proto -eq "TCP" }) + @($Binds) | Select-Object -First 1
            $Transport = $B.Proto
            if ($B.Port -match '-') { $PortRange = $B.Port }
            $Port = [int]($B.Port -replace '-.*$', '')
        }
        "naive" {
            $Proto = $Scheme.Substring(6)   # https | quic
            $Port = $(if ($PortStr) { [int]$PortStr } else { 443 })
        }
        default {
            if (-not $PortStr) { return "нет порта: нужно «сервер:порт»" }
            $Port = [int]$PortStr
        }
    }
    if ($Port -lt 1 -or $Port -gt 65535) { return "порт $Port вне 1–65535" }
    if (-not $Name) { $Name = "$Srv" }

    return [pscustomobject]@{ Type = $Type; Auth = $Auth; Server = $Srv; Port = $Port; Name = $Name; Query = $Query; Link = $Link
        User = $User; Password = $Pass; Transport = $Transport; PortRange = $PortRange; Proto = $Proto }
}

function Get-VpnExtra {
    param($P)
    $Q = $P.Query
    if ($P.Type -eq "vless") {
        $Parts = @()
        if ($Q.security) { $Parts += $Q.security }
        $Parts += $(if ($Q.type) { $Q.type } else { "tcp" })
        if ($Q.flow) { $Parts += ($Q.flow -replace '^xtls-rprx-', '') }
        return ($Parts -join " · ")
    }
    if ($P.Type -eq "mieru") {
        $Parts = @("$($P.Transport)".ToLower())
        if ($P.PortRange) { $Parts += "порты $($P.PortRange)" }
        if ($Q.multiplexing -match '^MULTIPLEXING_(OFF|LOW|MIDDLE|HIGH)$') { $Parts += "mux $($Matches[1].ToLower())" }
        if ($Q.'handshake-mode' -eq "HANDSHAKE_NO_WAIT") { $Parts += "0-RTT" }
        return ($Parts -join " · ")
    }
    if ($P.Type -eq "naive") { return "$($P.Proto) · naive → mihomo" }
    $Parts = @("udp/quic")
    if ($Q.obfs) { $Parts += "obfs" }
    if ($Q.insecure -eq "1") { $Parts += "insecure" }
    return ($Parts -join " · ")
}

# ---------------------------------------------------------------- system proxy

$script:ProxyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

function Set-SystemProxy {
    param([string]$Server)   # "" = restore what was there before we touched it
    $K = $script:ProxyKey
    if ($Server) {
        if (-not $script:Settings.VpnProxyBackup) {
            # Get-ItemPropertyValue throws on a missing value even with -ErrorAction; Get-ItemProperty just yields $null
            $Cur = Get-ItemProperty $K -ErrorAction SilentlyContinue
            $script:Settings.VpnProxyBackup = @{
                Enable = [int]$(if ($Cur -and $null -ne $Cur.ProxyEnable) { $Cur.ProxyEnable } else { 0 })
                Server = "$(if ($Cur) { $Cur.ProxyServer })"
                Override = "$(if ($Cur) { $Cur.ProxyOverride })"
            }
        }
        Set-ItemProperty $K ProxyEnable 1 -Type DWord
        Set-ItemProperty $K ProxyServer $Server
        Set-ItemProperty $K ProxyOverride "<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.2?.*;172.30.*;172.31.*;192.168.*;*.local"
        $script:Settings.VpnProxySet = $true
    } else {
        # Restore. A backup that itself points at our proxy (left by a crashed run) is garbage — fall back to "off".
        $B = $script:Settings.VpnProxyBackup
        if ($B -and (Test-ProxyIsOurs "$($B.Server)")) { $B = $null }
        $WantEnable = $(if ($B -and $B.Enable -and $B.Server) { 1 } else { 0 })
        foreach ($Try in 1..3) {
            Set-ItemProperty $K ProxyEnable $WantEnable -Type DWord
            if ($B -and $B.Server) { Set-ItemProperty $K ProxyServer $B.Server } else { Remove-ItemProperty $K ProxyServer -ErrorAction SilentlyContinue }
            if ($B -and $B.Override) { Set-ItemProperty $K ProxyOverride $B.Override } else { Remove-ItemProperty $K ProxyOverride -ErrorAction SilentlyContinue }
            $Cur = Get-ItemProperty $K -ErrorAction SilentlyContinue
            $Ok = ([int]"0$($Cur.ProxyEnable)" -eq $WantEnable) -and -not (Test-ProxyIsOurs "$($Cur.ProxyServer)")
            if ($Ok) { break }
            Write-AppLog "vpn: proxy restore readback mismatch (try $Try): enable=$($Cur.ProxyEnable) server=$($Cur.ProxyServer)"
            Start-Sleep -Milliseconds 150
        }
        $script:Settings.VpnProxySet = $false
        $script:Settings.VpnProxyBackup = $null
    }
    Save-Settings
    # tell WinINET (browsers, .NET) the settings changed
    [void][NetKnife.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)   # INTERNET_OPTION_SETTINGS_CHANGED
    [void][NetKnife.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)   # INTERNET_OPTION_REFRESH
}

# Our proxy = 127.0.0.1:<VpnPort> (any scheme prefix)
function Test-ProxyIsOurs {
    param([string]$Server)
    if (-not $Server) { return $false }
    return ($Server -match "(^|=|;)(https?=)?127\.0\.0\.1:$(Get-VpnPort)(;|$)")
}

# System proxy still pointing at us while no engine runs → switch it off. Safe to call any time.
function Repair-SystemProxy {
    param([string]$Reason = "")
    try {
        $Cur = Get-ItemProperty $script:ProxyKey -ErrorAction SilentlyContinue
        if ($Cur -and [int]"0$($Cur.ProxyEnable)" -eq 1 -and (Test-ProxyIsOurs "$($Cur.ProxyServer)")) {
            Write-AppLog "vpn: system proxy still ours ($Reason) — switching off"
            Set-SystemProxy ""
            return $true
        }
    } catch { Write-AppLog "vpn: Repair-SystemProxy: $_" }
    return $false
}

# Engine processes started from our folder (also orphans from a crashed run): kill by command line
function Stop-VpnEngineProcesses {
    try {
        $Mine = Get-CimInstance Win32_Process -Filter "Name = 'xray.exe' OR Name = 'mihomo.exe' OR Name = 'koala-mihomo.exe' OR Name = 'naive.exe'" -ErrorAction SilentlyContinue |
            Where-Object { "$($_.CommandLine)" -like "*$($script:VpnDir)*" }
        foreach ($P in $Mine) { try { Stop-Process -Id $P.ProcessId -Force -ErrorAction Stop; Write-AppLog "vpn: killed engine pid $($P.ProcessId)" } catch { } }
    } catch { }
}

# ---------------------------------------------------------------- engines
# VLESS → xray-core (the only core that follows current REALITY; it's also what Happ ships — reused when found).
# Hysteria2, mieru → mihomo (xray has neither). Each is one exe in %APPDATA%\NetKnife\vpn or a known local install.
# NaïveProxy → naive.exe (mihomo has no naive outbound) behind mihomo, so the port, system proxy and stats stay the same.
# Downloads are pinned: Tag + exact asset + Size + Sha256 from the official GitHub release (the API "digest" field;
# for xray it also matches the release's .dgst file). Bumping a version = updating all four here.

$script:VpnEngines = @{
    xray   = @{ Title = "xray";   Exe = "xray.exe";   Repo = "XTLS/Xray-core";   Tag = "v26.10.21"; ExeMatch = "xray.exe";    VerArgs = "version"; Cfg = "xray.json"
                Asset    = @{ Name = "Xray-windows-64.zip";        Size = 15029603; Sha256 = "fc58c39ee2f2717b4c54d28d374362389e5319b20ae44aea76ea45a5243ec827" }
                AssetArm = @{ Name = "Xray-windows-arm64-v8a.zip"; Size = 13355256; Sha256 = "bb44af3380c9975f951ce7645c04d56ab600040e68f23974a2806e08e0a3f872" }
                Fallback = @("$env:ProgramFiles\FlyFrogLLC\Happ\core\xray.exe") }
    mihomo = @{ Title = "mihomo"; Exe = "mihomo.exe"; Repo = "MetaCubeX/mihomo"; Tag = "v1.19.33"; ExeMatch = "mihomo*.exe"; VerArgs = "-v";      Cfg = "mihomo.yaml"
                Asset    = @{ Name = "mihomo-windows-amd64-compatible-v1.19.33.zip"; Size = 22543546; Sha256 = "7aaf636a4f2172dcd8ec34ac4f52797b059195e5afd6409508c963e545f8864d" }
                AssetArm = @{ Name = "mihomo-windows-arm64-v1.19.33.zip";            Size = 20212418; Sha256 = "a2a26869a14634c49f3fbcecc593b498ed8591fbdd7616b24475b3d60b148da3" }
                Fallback = @("$env:ProgramFiles\Koala Clash\koala-mihomo.exe") }
    # NaïveProxy client: listens SOCKS on an inner port, mihomo chains to it (socks5 outbound) — see Start-Vpn
    naive  = @{ Title = "naive";  Exe = "naive.exe";  Repo = "klzgrad/naiveproxy"; Tag = "v154.0.8037.49-5"; ExeMatch = "naive.exe"; VerArgs = "--version"; Cfg = "naive.json"
                Asset    = @{ Name = "naiveproxy-v154.0.8037.49-5-win-x64.zip";   Size = 5273913; Sha256 = "36d14c117ed052c8d04d10a30db083423ad4e423c012c2ef2ca7286ec06afbbc" }
                AssetArm = @{ Name = "naiveproxy-v154.0.8037.49-5-win-arm64.zip"; Size = 4599867; Sha256 = "68a7378ce6414df325f8d9d38fd8792906d63a601ae0b2f1c76d263bd917af5d" }
                Fallback = @() }
}

# Enum names mihomo accepts for mieru (mieru appctlpb MultiplexingLevel / HandshakeMode)
$script:MieruEnums = @{
    Multiplexing = @("MULTIPLEXING_DEFAULT", "MULTIPLEXING_OFF", "MULTIPLEXING_LOW", "MULTIPLEXING_MIDDLE", "MULTIPLEXING_HIGH")
    Handshake    = @("HANDSHAKE_DEFAULT", "HANDSHAKE_STANDARD", "HANDSHAKE_NO_WAIT")
}

function Get-VpnEngineFor {
    param([string]$Type)
    switch ($Type) {
        "vless"     { return "xray" }
        "hysteria2" { return "mihomo" }
        "mieru"     { return "mihomo" }
        "naive"     { return "naive" }
    }
    return $null
}

# Oldest engine version that runs this profile (mihomo release notes / adapter/outbound/mieru.go per tag); "" = any.
function Get-VpnMinVersion {
    param($P)
    if ($P.Type -ne "mieru") { return "" }
    $Q = $P.Query
    $Min = [version]"1.19.0"                                                            # type: mieru, transport TCP
    if ($Q.multiplexing) { $Min = [version]"1.19.1" }
    if ($Q.'handshake-mode' -and $Min -lt [version]"1.19.13") { $Min = [version]"1.19.13" }
    if ($P.Transport -eq "UDP" -and $Min -lt [version]"1.19.17") { $Min = [version]"1.19.17" }
    if ($Q.'traffic-pattern' -and $Min -lt [version]"1.19.21") { $Min = [version]"1.19.21" }
    return "$Min"
}

# "" when the installed engine is new enough (or its version can't be read — the config test will say), else a reason
function Test-VpnEngineVersion {
    param($P, [string]$Version)
    $Min = Get-VpnMinVersion $P
    if (-not $Min -or $Version -notmatch '^\d+\.\d+\.\d+$') { return "" }
    if ([version]$Version -ge [version]$Min) { return "" }
    $Eng = Get-VpnEngineFor $P.Type
    return "$Eng $Version слишком старый для $($P.Type) (нужен $Min или новее) — скачай $($script:VpnEngines[$Eng].Tag): меню «Скачать движок»"
}

function Get-VpnEngineExe {
    param([string]$Engine)
    $E = $script:VpnEngines[$Engine]
    $Own = Join-Path $script:VpnDir $E.Exe
    if (Test-Path $Own) { return $Own }
    foreach ($C in $E.Fallback) { if (Test-Path $C) { return $C } }
    return $null
}

$script:VpnVer = @{}   # engine → version; spawning the exe each refresh would be too slow
function Get-VpnEngineVersion {
    param([string]$Engine, [switch]$Fresh)
    if (-not $Fresh -and $script:VpnVer.ContainsKey($Engine)) { return $script:VpnVer[$Engine] }
    $Exe = Get-VpnEngineExe $Engine
    $V = ""
    if ($Exe) {
        try {
            $Out = (& $Exe $script:VpnEngines[$Engine].VerArgs 2>$null | Select-Object -First 1)
            $V = $(if ($Out -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { "?" })
        } catch { $V = "?" }
    }
    $script:VpnVer[$Engine] = $V
    return $V
}

# ---------------------------------------------------------------- xray config (JSON)

function New-XrayConfig {
    param($P, [int]$Port)
    $Q = $P.Query
    if ($P.Type -ne "vless") { throw "xray здесь только для VLESS" }
    $Net = $(if ($Q.type) { "$($Q.type)".ToLower() } else { "tcp" })
    if ($Net -eq "splithttp") { $Net = "xhttp" }
    if ($Net -eq "h2") { $Net = "http" }
    if ($Net -notin @("tcp", "ws", "grpc", "http", "httpupgrade", "xhttp", "kcp")) { throw "транспорт «$Net» не поддерживается" }
    $Sec = "$($Q.security)".ToLower(); if ($Sec -notin @("tls", "reality")) { $Sec = "none" }

    $User = [ordered]@{ id = $P.Auth; encryption = $(if ($Q.encryption) { $Q.encryption } else { "none" }) }
    if ($Q.flow) { $User.flow = $Q.flow }

    $Stream = [ordered]@{ network = $Net; security = $Sec }
    $Fp = $(if ($Q.fp) { $Q.fp } else { "chrome" })
    $Sni = $(if ($Q.sni) { $Q.sni } elseif ($Q.host) { $Q.host } else { "" })
    if ($Sec -eq "tls") {
        $T = [ordered]@{ fingerprint = $Fp }
        if ($Sni) { $T.serverName = $Sni }
        if ($Q.alpn) { $T.alpn = @($Q.alpn -split ',' | Where-Object { $_ }) }
        if ($Q.allowInsecure -eq "1" -or $Q.insecure -eq "1") { $T.allowInsecure = $true }
        $Stream.tlsSettings = $T
    } elseif ($Sec -eq "reality") {
        if (-not $Q.pbk) { throw "reality без pbk (public key) — ссылка неполная" }
        $R = [ordered]@{ fingerprint = $Fp; publicKey = $Q.pbk; shortId = "$($Q.sid)"; spiderX = $(if ($Q.spx) { $Q.spx } else { "/" }) }
        if ($Sni) { $R.serverName = $Sni }
        if ($Q.pqv) { $R.mldsa65Verify = $Q.pqv }
        $Stream.realitySettings = $R
    }
    $Path = $(if ($Q.path) { $Q.path } else { "/" })
    switch ($Net) {
        "ws"          { $W = [ordered]@{ path = $Path }; if ($Q.host) { $W.host = $Q.host }; $Stream.wsSettings = $W }
        "grpc"        { $Stream.grpcSettings = [ordered]@{ serviceName = "$($Q.serviceName)"; multiMode = ("$($Q.mode)" -eq "multi") } }
        "http"        { $H = [ordered]@{ path = $Path }; if ($Q.host) { $H.host = @($Q.host -split ',') }; $Stream.httpSettings = $H }
        "httpupgrade" { $H = [ordered]@{ path = $Path }; if ($Q.host) { $H.host = $Q.host }; $Stream.httpupgradeSettings = $H }
        "xhttp"       { $X = [ordered]@{ path = $Path; mode = $(if ($Q.mode) { $Q.mode } else { "auto" }) }; if ($Q.host) { $X.host = $Q.host }; $Stream.xhttpSettings = $X }
        "kcp"         { $K = [ordered]@{ header = [ordered]@{ type = $(if ($Q.headerType) { $Q.headerType } else { "none" }) } }; if ($Q.seed) { $K.seed = $Q.seed }; $Stream.kcpSettings = $K }
    }

    $Cfg = [ordered]@{
        log = [ordered]@{ loglevel = "warning" }
        # stats api on Port+2: `xray api statsquery` gives per-outbound byte counters for the traffic indicator
        stats = [ordered]@{}
        api = [ordered]@{ tag = "api"; services = @("StatsService") }
        policy = [ordered]@{ system = [ordered]@{ statsOutboundUplink = $true; statsOutboundDownlink = $true } }
        inbounds = @(
            [ordered]@{ tag = "http";  listen = "127.0.0.1"; port = $Port;       protocol = "http" }
            [ordered]@{ tag = "socks"; listen = "127.0.0.1"; port = ($Port + 1); protocol = "socks"; settings = [ordered]@{ udp = $true; auth = "noauth" } }
            [ordered]@{ tag = "api";   listen = "127.0.0.1"; port = ($Port + 2); protocol = "dokodemo-door"; settings = [ordered]@{ address = "127.0.0.1" } }
        )
        outbounds = @(
            [ordered]@{ tag = "proxy"; protocol = "vless"; settings = [ordered]@{ vnext = @([ordered]@{ address = $P.Server; port = $P.Port; users = @($User) }) }; streamSettings = $Stream }
            [ordered]@{ tag = "direct"; protocol = "freedom" }
        )
        # LAN straight out (no geoip.dat needed with literal CIDRs); system ProxyOverride does the same at the OS level
        routing = [ordered]@{ domainStrategy = "AsIs"; rules = @(
            [ordered]@{ type = "field"; inboundTag = @("api"); outboundTag = "api" }
            [ordered]@{ type = "field"; ip = @("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "100.64.0.0/10"); outboundTag = "direct" }
        ) }
    }
    return ($Cfg | ConvertTo-Json -Depth 10)
}

# ---------------------------------------------------------------- mihomo config (YAML)

function ConvertTo-YamlStr { param([string]$S) return "'" + ($S -replace "'", "''") + "'" }

# Throws with a readable message when the link needs something mihomo can't do.
function New-MihomoConfig {
    param($P, [int]$Port, [string]$Mode = "proxy", [int]$InnerPort = 0)
    $Q = $P.Query
    $Y = [System.Text.StringBuilder]::new()
    [void]$Y.AppendLine("  - name: proxy")
    if ($P.Type -eq "naive") {
        # naive.exe holds the server and the password and listens SOCKS on 127.0.0.1:InnerPort; mihomo only chains to it.
        # naive's SOCKS has no UDP.
        if ($InnerPort -lt 1) { throw "naive: не задан внутренний порт" }
        [void]$Y.AppendLine("    type: socks5")
        [void]$Y.AppendLine("    server: '127.0.0.1'")
        [void]$Y.AppendLine("    port: $InnerPort")
        [void]$Y.AppendLine("    udp: false")
    } else {
        [void]$Y.AppendLine("    type: $($P.Type)")
        [void]$Y.AppendLine("    server: $(ConvertTo-YamlStr $P.Server)")
        if ($P.Type -ne "mieru") { [void]$Y.AppendLine("    port: $($P.Port)") }   # mieru: port or port-range, below
        [void]$Y.AppendLine("    udp: true")
    }

    if ($P.Type -eq "vless") {
        [void]$Y.AppendLine("    uuid: $(ConvertTo-YamlStr $P.Auth)")
        $Net = $(if ($Q.type) { "$($Q.type)".ToLower() } else { "tcp" })
        $Sec = "$($Q.security)".ToLower()
        if ($Net -in @("xhttp", "splithttp")) { throw "транспорт «$Net» умеет только xray — mihomo/Happ-ядро его не поддерживает" }
        if ($Net -eq "h2") { $Net = "http" }
        if ($Net -notin @("tcp", "ws", "grpc", "http", "httpupgrade")) { throw "транспорт «$Net» не поддерживается" }
        [void]$Y.AppendLine("    network: $Net")
        if ($Q.flow) { [void]$Y.AppendLine("    flow: $(ConvertTo-YamlStr $Q.flow)") }
        if ($Sec -in @("tls", "reality")) {
            [void]$Y.AppendLine("    tls: true")
            $Sni = $(if ($Q.sni) { $Q.sni } elseif ($Q.host) { $Q.host } else { "" })
            if ($Sni) { [void]$Y.AppendLine("    servername: $(ConvertTo-YamlStr $Sni)") }
            if ($Q.allowInsecure -eq "1" -or $Q.insecure -eq "1") { [void]$Y.AppendLine("    skip-cert-verify: true") }
            [void]$Y.AppendLine("    client-fingerprint: $(ConvertTo-YamlStr $(if ($Q.fp -and $Q.fp -ne 'random') { $Q.fp } else { 'chrome' }))")
            if ($Q.alpn) { [void]$Y.AppendLine("    alpn: [$((($Q.alpn -split ',') | Where-Object { $_ } | ForEach-Object { ConvertTo-YamlStr $_ }) -join ', ')]") }
            if ($Sec -eq "reality") {
                if (-not $Q.pbk) { throw "reality без pbk (public key) — ссылка неполная" }
                [void]$Y.AppendLine("    reality-opts:")
                [void]$Y.AppendLine("      public-key: $(ConvertTo-YamlStr $Q.pbk)")
                [void]$Y.AppendLine("      short-id: $(ConvertTo-YamlStr "$($Q.sid)")")
            }
        }
        switch ($Net) {
            "ws" {
                [void]$Y.AppendLine("    ws-opts:")
                [void]$Y.AppendLine("      path: $(ConvertTo-YamlStr $(if ($Q.path) { $Q.path } else { '/' }))")
                if ($Q.host) { [void]$Y.AppendLine("      headers:"); [void]$Y.AppendLine("        Host: $(ConvertTo-YamlStr $Q.host)") }
            }
            "grpc" {
                [void]$Y.AppendLine("    grpc-opts:")
                [void]$Y.AppendLine("      grpc-service-name: $(ConvertTo-YamlStr "$($Q.serviceName)")")
            }
            "http" {
                [void]$Y.AppendLine("    http-opts:")
                [void]$Y.AppendLine("      path: [$(ConvertTo-YamlStr $(if ($Q.path) { $Q.path } else { '/' }))]")
                if ($Q.host) { [void]$Y.AppendLine("      headers:"); [void]$Y.AppendLine("        Host: [$(ConvertTo-YamlStr $Q.host)]") }
            }
            "httpupgrade" {
                [void]$Y.AppendLine("    ws-opts:")
                [void]$Y.AppendLine("      path: $(ConvertTo-YamlStr $(if ($Q.path) { $Q.path } else { '/' }))")
                [void]$Y.AppendLine("      v2ray-http-upgrade: true")
                if ($Q.host) { [void]$Y.AppendLine("      headers:"); [void]$Y.AppendLine("        Host: $(ConvertTo-YamlStr $Q.host)") }
            }
        }
    } elseif ($P.Type -eq "mieru") {
        if ($P.PortRange) { [void]$Y.AppendLine("    port-range: $(ConvertTo-YamlStr $P.PortRange)") } else { [void]$Y.AppendLine("    port: $($P.Port)") }
        [void]$Y.AppendLine("    transport: $($P.Transport)")
        [void]$Y.AppendLine("    username: $(ConvertTo-YamlStr $P.User)")
        [void]$Y.AppendLine("    password: $(ConvertTo-YamlStr $P.Password)")
        $Mux = "$($Q.multiplexing)"
        if ($Mux) {
            if ($Mux -notin $script:MieruEnums.Multiplexing) { throw "multiplexing «$Mux» не знаю — ожидаю $($script:MieruEnums.Multiplexing -join ', ')" }
            [void]$Y.AppendLine("    multiplexing: $Mux")
        }
        $Hs = "$($Q.'handshake-mode')"
        if ($Hs) {
            if ($Hs -notin $script:MieruEnums.Handshake) { throw "handshake-mode «$Hs» не знаю — ожидаю $($script:MieruEnums.Handshake -join ', ')" }
            [void]$Y.AppendLine("    handshake-mode: $Hs")
        }
        if ($Q.'traffic-pattern') { [void]$Y.AppendLine("    traffic-pattern: $(ConvertTo-YamlStr $Q.'traffic-pattern')") }
    } elseif ($P.Type -eq "hysteria2") {
        [void]$Y.AppendLine("    password: $(ConvertTo-YamlStr $P.Auth)")
        if ($Q.sni) { [void]$Y.AppendLine("    sni: $(ConvertTo-YamlStr $Q.sni)") }
        if ($Q.insecure -eq "1") { [void]$Y.AppendLine("    skip-cert-verify: true") }
        [void]$Y.AppendLine("    alpn: ['h3']")
        if ("$($Q.obfs)" -eq "salamander") {
            [void]$Y.AppendLine("    obfs: salamander")
            [void]$Y.AppendLine("    obfs-password: $(ConvertTo-YamlStr "$($Q.'obfs-password')")")
        }
        if ($Q.upmbps -match '^\d+$') { [void]$Y.AppendLine("    up: $($Q.upmbps)") }
        if ($Q.downmbps -match '^\d+$') { [void]$Y.AppendLine("    down: $($Q.downmbps)") }
    } elseif ($P.Type -eq "naive") {
    } else {
        throw "$($P.Type): mihomo этот протокол не умеет"
    }

    $Head = @(
        "# generated by NetKnife — edits are overwritten on every connect"
        "mixed-port: $Port"
        "bind-address: '127.0.0.1'"
        "allow-lan: false"
        "mode: rule"
        "log-level: info"
        "ipv6: false"
        "unified-delay: true"
        "tcp-concurrent: true"
        "external-controller: '127.0.0.1:$($Port + 2)'"   # /connections → byte counters for the traffic indicator
        "secret: ''"
    )
    if ($Mode -eq "tun") {
        $Head += @("tun:", "  enable: true", "  stack: system", "  auto-route: true", "  auto-detect-interface: true", "  dns-hijack: ['any:53']")
        $Head += @("dns:", "  enable: true", "  enhanced-mode: fake-ip", "  nameserver: ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query']")
    }
    $Tail = @(
        "proxies:"
        $Y.ToString().TrimEnd()
        "rules:"
        "  - MATCH,proxy"
    )
    return (($Head + $Tail) -join "`n") + "`n"
}

# ---------------------------------------------------------------- naive config (JSON)

# naive.exe reads server + login from this file, so the password never shows up in a process command line.
# -Mask gives the same text with the password replaced, for the "show config" dialog.
function New-NaiveConfig {
    param($P, [int]$InnerPort, [switch]$Mask)
    if ($P.Type -ne "naive") { throw "naive.json только для NaïveProxy" }
    $Srv = $(if ($P.Server -match ':') { "[$($P.Server)]" } else { $P.Server })
    $Pass = $(if ($Mask) { "***" } else { [Uri]::EscapeDataString($P.Password) })
    $Cfg = [ordered]@{
        listen = "socks://127.0.0.1:$InnerPort"
        proxy  = "$($P.Proto)://$([Uri]::EscapeDataString($P.User)):$Pass@${Srv}:$($P.Port)"
        log    = ""   # "" = to the console, which NetKnife reads (masked) into the VPN log
    }
    return ($Cfg | ConvertTo-Json)
}

# Port for naive's SOCKS listener: next to the main one, but never Port (mihomo), Port+1/Port+2 (xray socks / stats API)
function Get-VpnInnerPort {
    param([int]$Port)
    for ($I = 3; $I -le 20; $I++) {
        $C = $Port + $I
        if ($C -gt 65535) { break }
        if (-not (Test-LocalPortBusy $C)) { return $C }
    }
    return 0
}

# Engine log line → safe to show and save: "scheme://user:pass@" and bare "user:pass@" become "***@"
function Hide-ProxySecret {
    param([string]$Line)
    $L = $Line -replace '(?i)(\b[a-z][a-z0-9+.-]*://)[^\s/@"'']+@', '$1***@'
    return ($L -replace '(?<![\w*])[^\s/@:"''=]+:[^\s/@"'']+@(?=[\w\[])', '***@')
}

# ---------------------------------------------------------------- engine download

# The pinned asset of an engine for this CPU, with its download URL by tag, not the moving "latest"
function Get-VpnEngineAsset {
    param([string]$Engine, [string]$Arch = "$env:PROCESSOR_ARCHITECTURE")
    $E = $script:VpnEngines[$Engine]
    $A = $(if ($Arch -eq "ARM64") { $E.AssetArm } else { $E.Asset })
    return @{ Name = $A.Name; Size = [long]$A.Size; Sha256 = $A.Sha256.ToLower(); Url = "https://github.com/$($E.Repo)/releases/download/$($E.Tag)/$($A.Name)" }
}

# worker: download the zip, check its SHA256 against the pinned one, pull the engine exe out of it
$script:VpnDownloadBody = {
    param($Q, $Ctl, $Url, $Dir, $ExeMatch, $Target, $Sha256)
    $Zip = Join-Path $Dir "download.zip"
    $Tmp = Join-Path $Dir "unpack"
    try {
        if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
        if (Test-Path $Tmp) { Remove-Item $Tmp -Recurse -Force }
        Invoke-WebRequest $Url -OutFile $Zip -Headers @{ "User-Agent" = "NetKnife" } -TimeoutSec 300
        $Got = (Get-FileHash $Zip -Algorithm SHA256).Hash.ToLower()
        if ($Got -ne "$Sha256".ToLower()) {
            Remove-Item $Zip -Force -ErrorAction SilentlyContinue
            $Q.Enqueue(@{ Type = "vpndl"; Error = "контрольная сумма не совпала (SHA256 $($Got.Substring(0, 12))…, ждал $("$Sha256".Substring(0, 12))…) — файл удалён, ничего не установлено" }); return
        }
        Expand-Archive $Zip -DestinationPath $Tmp -Force
        $Exe = Get-ChildItem $Tmp -Recurse -Filter $ExeMatch | Select-Object -First 1
        if (-not $Exe) { $Q.Enqueue(@{ Type = "vpndl"; Error = "в архиве нет $ExeMatch" }); return }
        Copy-Item $Exe.FullName (Join-Path $Dir $Target) -Force
        $Q.Enqueue(@{ Type = "vpndl"; Ok = $true })
    } catch { $Q.Enqueue(@{ Type = "vpndl"; Error = "$($_.Exception.Message)" }) }
    finally {
        Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $Zip -Force -ErrorAction SilentlyContinue
    }
}

function Start-VpnInstall {
    param([string]$Engine = "xray")
    if (Test-WorkerRunning "vpn-dl") { return }
    $E = $script:VpnEngines[$Engine]
    $A = Get-VpnEngineAsset $Engine
    $script:VpnInstall = @{ Engine = $Engine; Version = $E.Tag; Url = $A.Url; Size = $A.Size; Name = $A.Name }
    $Mb = "{0:N1} МБ" -f ($A.Size / 1MB)
    $Msg = "Движок VPN. Скачается официальный релиз $($E.Repo) $($E.Tag) ($Mb) в $($script:VpnDir), SHA256 сверяется с записанным в NetKnife. Больше ничего не ставится и не меняется."
    if (-not (Show-Confirm "Скачать $($E.Title) $($E.Tag)?" $Msg "Скачать" -Detail "$($A.Url)`nSHA256 $($A.Sha256)")) { $script:VpnPending = $null; return }
    Set-VpnBanner "wait" "Скачиваю $($E.Title) $($E.Tag) ($Mb)…"
    [void](Start-Worker -Name "vpn-dl" -Body $script:VpnDownloadBody -ArgList @($A.Url, $script:VpnDir, $E.ExeMatch, $E.Exe, $A.Sha256) -State @{ E = $E; Engine = $Engine } -OnMessage {
        param($M2)
        $E = $State.E; $Engine = $State.Engine
        if ($M2.Type -ne "vpndl") { return }
        if ($M2.Error) { Set-VpnBanner "fail" "$($E.Title) не установлен: $($M2.Error)"; Write-AppLog "vpn: $($E.Title) $($E.Tag) download failed: $($M2.Error)"; $script:VpnPending = $null; return }
        Set-VpnBanner "none" ""
        Show-Toast "$($E.Title) $($E.Tag) установлен"
        [void](Get-VpnEngineVersion $Engine -Fresh)
        Refresh-Vpn
        if ($script:VpnPending) {
            $Pf = @(Get-VpnProfiles) | Where-Object { $_.Id -eq $script:VpnPending } | Select-Object -First 1
            $script:VpnPending = $null
            if ($Pf) { Start-Vpn $Pf }
        }
    })
}

# ---------------------------------------------------------------- run / stop

# Running = the main engine is alive, and so is naive.exe behind it when the profile is NaïveProxy
function Test-VpnRunning {
    if (-not ($script:Vpn -and $script:Vpn.P -and -not $script:Vpn.P.HasExited)) { return $false }
    if ($script:Vpn.Aux -and $script:Vpn.Aux.P.HasExited) { return $false }
    return $true
}

function Get-VpnActiveId { if (Test-VpnRunning) { return $script:Vpn.Id }; return $null }

# one PID per line: the main engine, then naive.exe when there is one
function Save-VpnPid {
    try {
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir | Out-Null }
        $Ids = @()
        if ($script:Vpn -and $script:Vpn.P -and -not $script:Vpn.P.HasExited) { $Ids += $script:Vpn.P.Id }
        if ($script:Vpn -and $script:Vpn.Aux -and -not $script:Vpn.Aux.P.HasExited) { $Ids += $script:Vpn.Aux.P.Id }
        if ($Ids) { [IO.File]::WriteAllText($script:VpnPidFile, ($Ids -join "`n")) } elseif (Test-Path $script:VpnPidFile) { [IO.File]::Delete($script:VpnPidFile) }
    } catch { }
}

# after a hard crash: kill the orphaned engines and put the system proxy back
function Remove-StaleVpn {
    if (Test-Path $script:VpnPidFile) {
        foreach ($Line in @(Get-Content $script:VpnPidFile -ErrorAction SilentlyContinue)) {
            if ($Line -notmatch '^\d+$') { continue }
            $P = Get-Process -Id ([int]$Line) -ErrorAction SilentlyContinue
            if ($P -and $P.ProcessName -in @("xray", "mihomo", "koala-mihomo", "naive")) { try { $P.Kill(); Write-AppLog "stale $($P.ProcessName) killed: $Line" } catch { } }
        }
        try { [IO.File]::Delete($script:VpnPidFile) } catch { }
    }
    Remove-NaiveConfig
    if ($script:Settings.VpnProxySet) {
        Write-AppLog "vpn: system proxy was left on — restoring"
        try { Set-SystemProxy "" } catch { }
    }
    [void](Repair-SystemProxy "startup")
}

# naive.json holds the password: it lives only while naive.exe starts up
function Remove-NaiveConfig {
    try { $F = Join-Path $script:VpnDir $script:VpnEngines.naive.Cfg; if (Test-Path $F) { [IO.File]::Delete($F) } } catch { }
}

# Engine process with stdout/stderr redirected (read line by line in Invoke-VpnPump), tied to our job object
function Start-VpnProcess {
    param([string]$Exe, [string]$CmdArgs)
    $Psi = New-Object System.Diagnostics.ProcessStartInfo $Exe
    $Psi.Arguments = $CmdArgs
    $Psi.WorkingDirectory = $script:VpnDir
    $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardError = $true; $Psi.RedirectStandardOutput = $true
    $Proc = [System.Diagnostics.Process]::Start($Psi)
    Add-ProcessToJob $Proc
    return $Proc
}

# Wait until something accepts TCP on 127.0.0.1:Port; "" when it does, else why not
function Wait-VpnListen {
    param($Proc, [int]$Port, [int]$TimeoutMs = 5000)
    $Sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($Proc.HasExited) { return "завершился сразу, код $($Proc.ExitCode)" }
        $T = New-Object System.Net.Sockets.TcpClient
        try {
            $A = $T.BeginConnect("127.0.0.1", $Port, $null, $null)
            if ($A.AsyncWaitHandle.WaitOne(250) -and $T.Connected) { return "" }
        } catch { } finally { $T.Close() }
        Start-Sleep -Milliseconds 100
    }
    return "не начал слушать 127.0.0.1:$Port за $([int]($TimeoutMs / 1000)) с"
}

# Everything an engine printed so far (non-blocking), masked — for an error shown before the pump takes over
function Read-VpnProcessOutput {
    param($Proc)
    $Out = @()
    try {
        if (-not $Proc.HasExited) { $Proc.Kill($true); [void]$Proc.WaitForExit(2000) }
        $Out = @(("$($Proc.StandardOutput.ReadToEnd())`n$($Proc.StandardError.ReadToEnd())" -split "`r?`n") | ForEach-Object { Hide-ProxySecret ($_ -replace "\x1b\[[0-9;]*m", "").Trim() } | Where-Object { $_ })
    } catch { }
    return $Out
}

function Start-Vpn {
    param($Pf)
    if (Test-VpnRunning) { Stop-Vpn -Quiet }

    $P = ConvertFrom-ProxyLink $Pf.Link
    if (-not $P) { Show-Toast "Ссылка профиля «$($Pf.Name)» не разбирается" "fail"; return }
    $Kind = Get-VpnEngineFor $P.Type
    if (-not $Kind) { Show-Toast "«$($Pf.Name)»: $($P.Type) не поддерживается — нет движка" "warn"; return }
    # NaïveProxy = naive.exe (holds the server) + mihomo in front of it (port, system proxy, stats)
    $Engine = $(if ($Kind -eq "naive") { "mihomo" } else { $Kind })
    foreach ($Need in @($Kind, $Engine) | Select-Object -Unique) {
        if (-not (Get-VpnEngineExe $Need)) { $script:VpnPending = $Pf.Id; Start-VpnInstall $Need; return }   # Start-Vpn runs again once it's in
    }
    $E = $script:VpnEngines[$Engine]
    $Exe = Get-VpnEngineExe $Engine
    $Old = Test-VpnEngineVersion $P (Get-VpnEngineVersion $Engine)
    if ($Old) { Show-Toast "«$($Pf.Name)»: $Old" "warn"; return }

    $Port = Get-VpnPort
    $Inner = 0
    if ($Kind -eq "naive") {
        $Inner = Get-VpnInnerPort $Port
        if (-not $Inner) { Show-Toast "Нет свободного порта для naive рядом с $Port — смени порт в настройках VPN" "warn"; return }
    }
    try { $Text = $(if ($Engine -eq "xray") { New-XrayConfig $P $Port } else { New-MihomoConfig $P $Port -InnerPort $Inner }) } catch { Show-Toast "«$($Pf.Name)»: $($_.Exception.Message)" "fail"; return }
    if (Test-LocalPortBusy $Port) { Show-Toast "Порт $Port занят на этом ПК — смени в настройках VPN" "warn"; return }

    if (-not (Test-Path $script:VpnDir)) { New-Item -ItemType Directory -Path $script:VpnDir | Out-Null }
    $Cfg = Join-Path $script:VpnDir $E.Cfg
    [IO.File]::WriteAllText($Cfg, $Text, [System.Text.UTF8Encoding]::new($false))

    # dry-run validates the config and fails fast with a readable reason instead of a dead process
    # (before naive starts: a rejected mihomo config shouldn't leave naive.exe and its naive.json behind)
    $ChkArgs = $(if ($Engine -eq "xray") { "run -test -c $(Quote-Arg $Cfg)" } else { "-t -f $(Quote-Arg $Cfg) -d $(Quote-Arg $script:VpnDir)" })
    $Chk = Invoke-VpnEngineCheck $Exe $ChkArgs
    if ($Chk.Code -ne 0) {
        $script:Vpn = @{ P = $null; Id = $Pf.Id; Started = [DateTime]::Now; Error = "конфиг не прошёл проверку"; Notified = $true; Lines = [System.Collections.Generic.List[string]]::new() }
        Show-Confirm "$($E.Title) отверг конфиг" "Профиль «$($Pf.Name)». Ниже — вывод проверки." "Закрыть" -Detail (Hide-ProxySecret $Chk.Out) | Out-Null
        Refresh-Vpn
        return
    }

    $Aux = $null
    if ($Kind -eq "naive") {
        $NCfg = Join-Path $script:VpnDir $script:VpnEngines.naive.Cfg
        try {
            [IO.File]::WriteAllText($NCfg, (New-NaiveConfig $P $Inner), [System.Text.UTF8Encoding]::new($false))
            $NProc = Start-VpnProcess (Get-VpnEngineExe "naive") (Quote-Arg $NCfg)
        } catch {
            Remove-NaiveConfig
            $script:Vpn = @{ P = $null; Id = $Pf.Id; Started = [DateTime]::Now; Error = "naive не запустился: $($_.Exception.Message)"; Notified = $true; Lines = [System.Collections.Generic.List[string]]::new() }
            Refresh-Vpn; return
        }
        $Why = Wait-VpnListen $NProc $Inner
        Remove-NaiveConfig   # read by now (or naive is dead) — the password stays on disk only for these seconds
        if ($Why) {
            $Lines = [System.Collections.Generic.List[string]]::new()
            foreach ($L in (Read-VpnProcessOutput $NProc)) { $Lines.Add("naive: $L") }
            $script:Vpn = @{ P = $null; Id = $Pf.Id; Started = [DateTime]::Now; Error = "naive $Why"; Notified = $true; Lines = $Lines }
            Write-AppLog "vpn: naive $Why`n$(@($Lines | Select-Object -Last 5) -join "`n")"
            Show-Toast "VPN «$($Pf.Name)»: naive $Why" "fail"
            Refresh-Vpn; return
        }
        $Aux = @{ P = $NProc; Name = "naive"; ErrTask = $NProc.StandardError.ReadLineAsync(); OutTask = $NProc.StandardOutput.ReadLineAsync() }
    }

    try {
        $Proc = Start-VpnProcess $Exe $(if ($Engine -eq "xray") { "run -c $(Quote-Arg $Cfg)" } else { "-f $(Quote-Arg $Cfg) -d $(Quote-Arg $script:VpnDir)" })
        # mihomo logs to stdout; keep stderr too for crashes
        $script:Vpn = @{ P = $Proc; Aux = $Aux; Id = $Pf.Id; Engine = $Engine; Kind = $Kind; Started = [DateTime]::Now; ErrTask = $Proc.StandardError.ReadLineAsync(); OutTask = $Proc.StandardOutput.ReadLineAsync(); Lines = [System.Collections.Generic.List[string]]::new(); Error = ""; Notified = $false; Port = $Port }
        Save-VpnPid
        Set-SystemProxy "127.0.0.1:$Port"
        $script:Settings.VpnLast = $Pf.Id; Save-Settings
        Show-Toast "VPN «$($Pf.Name)»: подключаюсь, системный прокси 127.0.0.1:$Port" "info"
        Start-VpnProbe $Pf $Port
        Start-VpnStats $Engine $Exe $Port $P.Server $P.Port
    } catch {
        # whatever failed after Start (proxy registry etc.) — don't leave engines running headless
        if ($Proc -and -not $Proc.HasExited) { try { $Proc.Kill($true) } catch { } }
        if ($Aux -and -not $Aux.P.HasExited) { try { $Aux.P.Kill($true) } catch { } }
        if ($script:Settings.VpnProxySet) { try { Set-SystemProxy "" } catch { } }
        $script:Vpn = @{ P = $null; Id = $Pf.Id; Started = [DateTime]::Now; Error = "не запустился: $($_.Exception.Message)"; Notified = $true; Lines = [System.Collections.Generic.List[string]]::new() }
        Save-VpnPid
    }
    Refresh-Vpn
}

# After connect: fetch the egress IP THROUGH the local proxy. Dead tunnel → roll back immediately,
# otherwise the system proxy points into a black hole and the whole PC loses internet.
$script:VpnProbeBody = {
    param($Q, $Ctl, $Port)
    $Ip = ""; $Err = ""
    foreach ($Url in @("https://icanhazip.com", "https://api.ipify.org")) {
        if ($Ctl.Stop) { return }
        try {
            $R = Invoke-WebRequest $Url -Proxy "http://127.0.0.1:$Port" -TimeoutSec 12 -UseBasicParsing
            $Ip = "$($R.Content)".Trim()
            if ($Ip -match '^\d{1,3}(\.\d{1,3}){3}$') { break }
            $Ip = ""
        } catch { $Err = "$($_.Exception.Message)" }
    }
    $Q.Enqueue(@{ Type = "vpnprobe"; Ip = $Ip; Error = $Err })
}

function Start-VpnProbe {
    param($Pf, [int]$Port)
    $Id = $Pf.Id
    [void](Start-Worker -Name "vpn-probe" -Replace -Body $script:VpnProbeBody -ArgList @($Port) -State @{ Id = $Id; Pf = $Pf } -OnMessage {
        param($M)
        if ($M.Type -ne "vpnprobe") { return }
        if (-not $script:Vpn -or $script:Vpn.Id -ne $State.Id -or -not (Test-VpnRunning)) { return }   # already stopped/switched
        if ($M.Ip) {
            $script:Vpn.Egress = $M.Ip
            Show-Toast "VPN работает · внешний IP $($M.Ip)" "ok"
            Show-TrayBalloon "VPN подключён" "$($State.Pf.Name) · выход $($M.Ip)" "Info"
            $script:VpnIpTimer.Stop(); $script:VpnIpTimer.Start()
        } else {
            $Tail = @($script:Vpn.Lines | Select-Object -Last 3) -join "`n"
            Stop-Vpn -Quiet
            $script:Vpn = @{ P = $null; Id = $State.Id; Started = [DateTime]::Now; Error = "туннель не отвечает — прокси возвращён"; Notified = $true; Lines = [System.Collections.Generic.List[string]]::new() }
            Show-Toast "VPN «$($State.Pf.Name)»: через туннель ничего не проходит — отключил, интернет как был" "fail"
            Write-AppLog "vpn probe failed for $($State.Pf.Name): $($M.Error)`n$Tail"
            Refresh-Vpn
        }
    })
}

# Live indicator while connected: TCP round-trip to the server + bytes through the proxy outbound (every 3 s)
$script:VpnStat = $null
$script:VpnStatsBody = {
    param($Q, $Ctl, $Engine, $Exe, $Port, $Server, $ServerPort)
    while (-not $Ctl.Stop) {
        $Rtt = -1
        try {
            $Sw = [System.Diagnostics.Stopwatch]::StartNew()
            $T = New-Object System.Net.Sockets.TcpClient
            $A = $T.BeginConnect($Server, [int]$ServerPort, $null, $null)
            if ($A.AsyncWaitHandle.WaitOne(3000) -and $T.Connected) { $Rtt = [int]$Sw.ElapsedMilliseconds }
            $T.Close()
        } catch { }
        $Up = -1; $Down = -1
        try {
            if ($Engine -eq "xray") {
                $Psi = New-Object System.Diagnostics.ProcessStartInfo $Exe
                $Psi.Arguments = "api statsquery --server=127.0.0.1:$($Port + 2)"
                $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true; $Psi.RedirectStandardOutput = $true; $Psi.RedirectStandardError = $true
                $Pr = [System.Diagnostics.Process]::Start($Psi)
                $Out = $Pr.StandardOutput.ReadToEnd(); [void]$Pr.WaitForExit(5000)
                $Up = 0; $Down = 0   # xray omits counters that are still zero
                $J = $Out | ConvertFrom-Json
                foreach ($St in @($J.stat)) {
                    if ($St.name -eq "outbound>>>proxy>>>traffic>>>uplink") { $Up = [long]$St.value }
                    if ($St.name -eq "outbound>>>proxy>>>traffic>>>downlink") { $Down = [long]$St.value }
                }
            } else {
                $R = Invoke-RestMethod "http://127.0.0.1:$($Port + 2)/connections" -NoProxy -TimeoutSec 4
                $Up = [long]$R.uploadTotal; $Down = [long]$R.downloadTotal
            }
        } catch { }
        $Q.Enqueue(@{ Type = "vpnstats"; Rtt = $Rtt; Up = $Up; Down = $Down })
        foreach ($i in 1..15) { if ($Ctl.Stop) { break }; Start-Sleep -Milliseconds 200 }
    }
}

function Start-VpnStats {
    param([string]$Engine, [string]$Exe, [int]$Port, [string]$Server, [int]$ServerPort)
    $script:VpnStat = @{ Rtt = -1; Up = 0; Down = 0; PrevUp = 0; PrevDown = 0; PrevAt = [DateTime]::Now; UpRate = 0.0; DownRate = 0.0; Seen = $false }
    [void](Start-Worker -Name "vpn-stats" -Replace -Body $script:VpnStatsBody -ArgList @($Engine, $Exe, $Port, $Server, $ServerPort) -OnMessage {
        param($M)
        if ($M.Type -ne "vpnstats" -or -not $script:VpnStat) { return }
        $S = $script:VpnStat
        $S.Rtt = $M.Rtt
        if ($M.Up -ge 0) {
            $Now = [DateTime]::Now; $Dt = ($Now - $S.PrevAt).TotalSeconds
            if ($S.Seen -and $Dt -gt 0.5) { $S.UpRate = [Math]::Max(0, ($M.Up - $S.PrevUp) / $Dt); $S.DownRate = [Math]::Max(0, ($M.Down - $S.PrevDown) / $Dt) }
            $S.PrevUp = $M.Up; $S.PrevDown = $M.Down; $S.PrevAt = $Now; $S.Up = $M.Up; $S.Down = $M.Down; $S.Seen = $true
        }
        if (Test-VpnRunning) { Refresh-Vpn }
    })
}

function Stop-VpnStats { Stop-Worker "vpn-stats"; $script:VpnStat = $null }

function Format-VpnBytes {
    param([double]$B)
    if ($B -ge 1GB) { return ("{0:N2} ГБ" -f ($B / 1GB)) }
    if ($B -ge 1MB) { return ("{0:N1} МБ" -f ($B / 1MB)) }
    if ($B -ge 1KB) { return ("{0:N0} КБ" -f ($B / 1KB)) }
    return ("{0:N0} Б" -f $B)
}

function Get-VpnStatText {
    param([switch]$Short)
    $S = $script:VpnStat
    if (-not $S) { return "" }
    $Parts = @()
    $Parts += $(if ($S.Rtt -ge 0) { "$($S.Rtt) мс" } else { "сервер не отвечает" })
    if ($S.Seen) {
        $Parts += "↓ $(Format-VpnBytes $S.Down)  ↑ $(Format-VpnBytes $S.Up)"
        if (-not $Short) { $Parts += "сейчас ↓ $(Format-VpnBytes $S.DownRate)/с  ↑ $(Format-VpnBytes $S.UpRate)/с" }
    }
    return ($Parts -join " · ")
}

function Invoke-VpnEngineCheck {
    param([string]$Exe, [string]$CmdArgs)
    $Psi = New-Object System.Diagnostics.ProcessStartInfo $Exe
    $Psi.Arguments = $CmdArgs
    $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardError = $true; $Psi.RedirectStandardOutput = $true
    $P = [System.Diagnostics.Process]::Start($Psi)
    $Out = $P.StandardOutput.ReadToEndAsync(); $Err = $P.StandardError.ReadToEndAsync()
    if (-not $P.WaitForExit(8000)) { try { $P.Kill() } catch { } }
    [void]$Out.Wait(1000); [void]$Err.Wait(1000)
    return @{ Code = $P.ExitCode; Out = "$($Out.Result)$($Err.Result)".Trim() }
}

function Stop-Vpn {
    param([switch]$Quiet)
    $Name = ""
    if ($script:Vpn) { $Pf = @(Get-VpnProfiles) | Where-Object { $_.Id -eq $script:Vpn.Id } | Select-Object -First 1; if ($Pf) { $Name = $Pf.Name } }
    if ($script:Vpn -and $script:Vpn.P -and -not $script:Vpn.P.HasExited) { try { $script:Vpn.P.Kill($true); [void]$script:Vpn.P.WaitForExit(3000) } catch { } }
    if ($script:Vpn -and $script:Vpn.Aux -and -not $script:Vpn.Aux.P.HasExited) { try { $script:Vpn.Aux.P.Kill($true); [void]$script:Vpn.Aux.P.WaitForExit(3000) } catch { } }
    $script:Vpn = $null
    Remove-NaiveConfig
    Stop-VpnStats
    Save-VpnPid
    Stop-VpnEngineProcesses
    # unconditional: the VpnProxySet flag can be clobbered by a second NetKnife instance saving settings
    try { Set-SystemProxy "" } catch { Write-AppLog "vpn: proxy restore failed: $_" }
    [void](Repair-SystemProxy "after stop")
    if (-not $Quiet) { Show-Toast "VPN отключён$(if ($Name) { ": $Name" })" "info"; $script:VpnIpTimer.Stop(); $script:VpnIpTimer.Start() }
    if ($Ui) { Refresh-Vpn }
}

# Called from the main pump once a second: drain the engine logs, notice a crash, tick the uptime
function Invoke-VpnPump {
    if ($script:VpnPumpSw.ElapsedMilliseconds -lt 1000) { return }
    $script:VpnPumpSw.Restart()
    $S = $script:Vpn
    if (-not $S -or -not $S.P) {
        # watchdog: nothing running, but the system proxy still points at us (killed app, second instance, ...)
        $script:VpnWatchTick = ($script:VpnWatchTick + 1) % 10
        if ($script:VpnWatchTick -eq 0 -and (Repair-SystemProxy "watchdog")) { Show-Toast "Системный прокси указывал на выключенный VPN — отключил" "warn"; Refresh-Vpn }
        return
    }

    # main engine, then naive.exe behind it; every line masked before it reaches the UI or vpn.log
    $Changed = $false
    foreach ($Src in @(@{ T = $S; Prefix = "" }, $(if ($S.Aux) { @{ T = $S.Aux; Prefix = "naive: " } })) | Where-Object { $_ }) {
        $T = $Src.T
        foreach ($Key in @("OutTask", "ErrTask")) {
            $Stream = $(if ($Key -eq "OutTask") { $T.P.StandardOutput } else { $T.P.StandardError })
            while ($T[$Key] -and $T[$Key].IsCompleted) {
                $L = $null
                try { $L = $T[$Key].Result } catch { }
                if ($null -eq $L) { $T[$Key] = $null; break }
                $L = Hide-ProxySecret ($L -replace "\x1b\[[0-9;]*m", "").Trim()   # strip ANSI colors
                if ($L) {
                    $L = "$($Src.Prefix)$L"
                    $S.Lines.Add($L); if ($S.Lines.Count -gt 200) { $S.Lines.RemoveAt(0) }; $Changed = $true
                    try { Add-Content -Path (Join-Path $script:VpnDir "vpn.log") -Value $L -Encoding UTF8 } catch { }
                }
                $T[$Key] = $Stream.ReadLineAsync()
            }
        }
    }
    if ($Changed -and $script:Page -eq "vpn") { Update-VpnLog }

    # either process gone = the tunnel is gone: stop the other one too
    $AuxDead = [bool]($S.Aux -and $S.Aux.P.HasExited)
    if (($S.P.HasExited -or $AuxDead) -and -not $S.Notified) {
        $S.Notified = $true
        foreach ($Pr in @($S.P, $(if ($S.Aux) { $S.Aux.P }))) { if ($Pr -and -not $Pr.HasExited) { try { $Pr.Kill($true); [void]$Pr.WaitForExit(2000) } catch { } } }
        $Who = $(if ($AuxDead) { "naive" } else { $S.Engine })
        $Pool = @($S.Lines | Where-Object { -not $AuxDead -or $_ -like "naive: *" })
        $Last = @($Pool | Where-Object { $_ -match 'level=(error|fatal)|FATAL|ERROR|\[Error\]|failed to' } | Select-Object -Last 1)
        $Err = if ($Last) { $Last[0] -replace '^naive: ', '' -replace '^.*msg="?', '' -replace '"$', '' -replace '^\S+ \S+ \[\w+\] ', '' } elseif ($Pool.Count) { $Pool[$Pool.Count - 1] } else { "$Who завершился, код $(if ($AuxDead) { $S.Aux.P.ExitCode } else { $S.P.ExitCode })" }
        if ($AuxDead -and $Err -notlike "naive*") { $Err = "naive: $Err" }
        $S.Error = $Err
        try { Set-SystemProxy "" } catch { }
        Save-VpnPid
        Stop-VpnStats
        Write-AppLog "vpn: $Who exited: $Err"
        Show-Toast "VPN упал: $Err" "fail"
        Refresh-Vpn
    } elseif (-not $S.P.HasExited -and $script:Page -eq "vpn") {
        $Secs = ([DateTime]::Now - $S.Started).TotalSeconds
        if ($Secs -lt 10 -or ([int]$Secs % 15 -eq 0)) { Refresh-Vpn }
    }
}

# ---------------------------------------------------------------- rows / page

function New-VpnRow {
    param($Pf)
    $Active = ($Pf.Id -eq (Get-VpnActiveId))
    $Kind = "none"; $Status = ""
    if ($Active) {
        $Secs = ([DateTime]::Now - $script:Vpn.Started).TotalSeconds
        $Min = [int]($Secs / 60)
        $Kind = if ($Secs -lt 4) { "wait" } else { "ok" }
        $Status = if ($Kind -eq "wait") { "подключается…" } elseif ($Min -lt 60) { "подключён · $Min мин" } else { "подключён · $([Math]::Round($Min / 60.0, 1)) ч" }
        $St = Get-VpnStatText -Short
        if ($St) { $Status += " · $St" }
    } elseif ($script:Vpn -and $script:Vpn.Id -eq $Pf.Id -and $script:Vpn.Error) { $Kind = "fail"; $Status = $script:Vpn.Error }

    $P = ConvertFrom-ProxyLink $Pf.Link
    return [pscustomobject]@{
        Id = $Pf.Id; Name = $Pf.Name
        TypeText = $(switch ($Pf.Type) { "vless" { "VLESS" } "mieru" { "mieru" } "naive" { "NaïveProxy" } default { "Hysteria2" } })
        Server = "$($Pf.Server):$($Pf.Port)"
        Extra = $(if ($P) { Get-VpnExtra $P } else { "ссылка не разбирается" })
        StatusText = $Status; Kind = $Kind; Active = $Active
        ToggleText = $(if ($Active) { "Отключить" } else { "Подключить" })
        ToggleTag = "vpn:toggle:$($Pf.Id)"; CopyTag = "vpn:copy:$($Pf.Id)"; EditTag = "vpn:edit:$($Pf.Id)"; DelTag = "vpn:del:$($Pf.Id)"
        Profile = $Pf
    }
}

function Refresh-Vpn {
    $Sel = $null
    if ($Ui.VpnList.SelectedItem) { $Sel = $Ui.VpnList.SelectedItem.Id }
    $script:VpnItems.Clear()
    foreach ($Pf in Get-VpnProfiles) { $script:VpnItems.Add((New-VpnRow $Pf)) }
    if ($Sel) { $Ui.VpnList.SelectedItem = ($script:VpnItems | Where-Object { $_.Id -eq $Sel } | Select-Object -First 1) }
    $Ui.VpnEmpty.Visibility = $(if ($script:VpnItems.Count) { "Collapsed" } else { "Visible" })

    $Running = Test-VpnRunning
    $Ui.NavVpn.Tag = $(if ($Running) { "on" } else { $null })
    $Ui.VpnDisconnect.Visibility = $(if ($Running) { "Visible" } else { "Collapsed" })
    if ($Running) {
        $Pf = @(Get-VpnProfiles) | Where-Object { $_.Id -eq $script:Vpn.Id } | Select-Object -First 1
        $St = Get-VpnStatText
        Set-StatusPill $Ui.VpnStatePill $Ui.VpnState "ok" "подключён: $($Pf.Name) · $(if ($script:Vpn.Aux) { "naive + $($script:Vpn.Engine)" } else { $script:Vpn.Engine }) · прокси 127.0.0.1:$($script:Vpn.Port)$(if ($St) { "  ·  $St" })"
    } elseif ($script:Vpn -and $script:Vpn.Error) {
        Set-StatusPill $Ui.VpnStatePill $Ui.VpnState "fail" $script:Vpn.Error
    } else {
        Set-StatusPill $Ui.VpnStatePill $Ui.VpnState "none" "отключён"
    }
    $Xv = Get-VpnEngineVersion "xray"; $Mv = Get-VpnEngineVersion "mihomo"; $Nv = Get-VpnEngineVersion "naive"
    $Parts = @(
        $(if ($Xv) { "xray $Xv" } else { "xray: нет — скачается для VLESS (спрошу)" })
        $(if ($Mv) { "mihomo $Mv" } else { "mihomo: нет — скачается для Hysteria2, mieru и NaïveProxy (спрошу)" })
        $(if ($Nv) { "naive $Nv" } else { "naive: нет — скачается для NaïveProxy (спрошу)" })
    )
    $Ui.VpnEngine.Text = $Parts -join "   ·   "
    $Ui.VpnEngine.ToolTip = "xray: $(Get-VpnEngineExe 'xray')`nmihomo: $(Get-VpnEngineExe 'mihomo')`nnaive: $(Get-VpnEngineExe 'naive')"
    $Ui.VpnEngine.Foreground = $(if ($Xv -or $Mv -or $Nv) { Get-Brush "Faint" } else { Get-Brush "Warn" })
    Update-VpnLog
    Update-PageSub
    try { Update-TrayVpn } catch { }
}

function Update-VpnLog {
    if (-not $script:Vpn -or -not $script:Vpn.Lines -or -not $script:Vpn.Lines.Count) { $Ui.VpnLogBox.Visibility = "Collapsed"; return }
    $Ui.VpnLogBox.Visibility = "Visible"
    $Take = [Math]::Min(12, $script:Vpn.Lines.Count)
    $Ui.VpnLog.Text = (($script:Vpn.Lines | Select-Object -Last $Take) -join "`r`n")
}

function Set-VpnBanner {
    param([string]$Kind, [string]$Text)
    if (-not $Text) { $Ui.VpnBanner.Visibility = "Collapsed"; return }
    $Ui.VpnBanner.Visibility = "Visible"
    $Ui.VpnBannerText.Text = $Text
    $Color = switch ($Kind) { "fail" { "Fail" } "ok" { "Ok" } default { "Warn" } }
    $Ui.VpnBanner.Background = Get-Brush "${Color}Soft"; $Ui.VpnBanner.BorderBrush = $Ui.VpnBanner.Background
    $Ui.VpnBannerText.Foreground = Get-Brush $Color; $Ui.VpnBannerGlyph.Foreground = Get-Brush $Color
}

function Get-VpnSub {
    $N = @(Get-VpnProfiles).Count
    if (Test-VpnRunning) { $Pf = @(Get-VpnProfiles) | Where-Object { $_.Id -eq $script:Vpn.Id } | Select-Object -First 1; return "Подключён через «$($Pf.Name)» · системный прокси · $(Get-Plural $N 'профиль' 'профиля' 'профилей')" }
    if (-not $N) { return "VLESS через xray, Hysteria2 и mieru через mihomo, NaïveProxy через naive · вставь ссылку из Happ" }
    return "$(Get-Plural $N 'профиль' 'профиля' 'профилей') · отключён"
}

# ---------------------------------------------------------------- import

function Add-VpnLinks {
    param([string[]]$Lines, [switch]$Quiet)
    $List = @(Get-VpnProfiles)
    $Added = 0; $Dup = 0; $Bad = 0; $Why = ""
    foreach ($Line in $Lines) {
        $L = "$Line".Trim()
        if (-not $L -or $L.StartsWith("#")) { continue }
        $P = ConvertFrom-ProxyLink $L
        if (-not $P) { $Bad++; if (-not $Why) { $Why = Get-ProxyLinkError $L }; continue }
        if ($List | Where-Object { $_.Link -eq $P.Link }) { $Dup++; continue }
        $List += @{ Id = [guid]::NewGuid().ToString("N").Substring(0, 8); Name = $P.Name; Type = $P.Type; Server = $P.Server; Port = $P.Port; Link = $P.Link }
        $Added++
    }
    $script:Settings.VpnProfiles = $List
    Save-Settings
    Refresh-Vpn
    if (-not $Quiet) {
        $Msg = "Добавлено: $Added"
        if ($Dup) { $Msg += " · уже были: $Dup" }
        if ($Bad) { $Msg += " · не разобрал: $Bad ($Why)" }
        Show-Toast $Msg $(if ($Added) { "ok" } elseif ($Bad) { "warn" } else { "info" })
    }
    return $Added
}

# subscription: a URL returning base64 (or plain) list of links
$script:VpnSubBody = {
    param($Q, $Ctl, $Url)
    try {
        $R = Invoke-WebRequest $Url -Headers @{ "User-Agent" = "Happ/NetKnife" } -TimeoutSec 30 -UseBasicParsing
        $Text = "$($R.Content)".Trim()
        if ($Text -notmatch '://') {
            $B = $Text -replace '\s', ''
            $B = $B.Replace('-', '+').Replace('_', '/')
            while ($B.Length % 4) { $B += "=" }
            $Text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B))
        }
        $Q.Enqueue(@{ Type = "vpnsub"; Lines = @($Text -split "`r?`n") })
    } catch { $Q.Enqueue(@{ Type = "vpnsub"; Error = "$($_.Exception.Message)" }) }
}

function Show-VpnAddDialog {
    $D = New-Dialog "Добавить VPN-профиль" @"
<StackPanel>
    <TextBlock Text="Добавить профиль" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="Вставь ссылки vless://, hysteria2://, mierus:// или naive+https:// (одна на строку — в Happ: профиль → «Копировать ссылку»). Или адрес подписки https://… — скачаю и разберу." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,12" FontSize="12.5"/>
    <TextBox x:Name="FText" Style="{StaticResource Code}" IsReadOnly="False" AcceptsReturn="True" Height="180" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" HorizontalScrollBarVisibility="Auto"/>
    <TextBlock x:Name="FError" Foreground="{StaticResource Fail}" FontSize="12" Margin="2,6,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button x:Name="FPaste" Style="{StaticResource Btn}" MinWidth="110" Margin="0,0,8,0">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE77F;" Style="{StaticResource Glyph}"/><TextBlock Text="Из буфера"/></StackPanel>
        </Button>
        <Button x:Name="FCancel" Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="Добавить" MinWidth="120" Margin="8,0,0,0"/>
    </StackPanel>
</StackPanel>
"@ 620
    $F = @{}
    foreach ($N in @("FText", "FError", "FPaste", "FOk")) { $F[$N] = $D.FindName($N) }
    try { $Clip = [System.Windows.Clipboard]::GetText(); if ($Clip -match '^(?i)(vless|hysteria2|hy2|mierus|naive\+https|naive\+quic|https?)://') { $F.FText.Text = $Clip.Trim() } } catch { }
    $F.FPaste.Add_Click({ try { $F.FText.Text = [System.Windows.Clipboard]::GetText() } catch { } })
    $F.FOk.Add_Click({
        $Lines = @($F.FText.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $Lines) { $F.FError.Text = "Пусто"; $F.FError.Visibility = "Visible"; return }
        $D.Tag = $Lines
        $D.DialogResult = $true
    })
    $D.Add_ContentRendered({ [void]$F.FText.Focus() })
    if (-not $D.ShowDialog()) { return }

    $Lines = @($D.Tag)
    $Urls = @($Lines | Where-Object { $_ -match '^(?i)https?://' })
    $Direct = @($Lines | Where-Object { $_ -notmatch '^(?i)https?://' })
    if ($Direct) { [void](Add-VpnLinks $Direct) }
    foreach ($U in $Urls) {
        Set-VpnBanner "wait" "Скачиваю подписку $U…"
        [void](Start-Worker -Name "vpn-sub-$([guid]::NewGuid())" -Body $script:VpnSubBody -ArgList @($U) -OnMessage {
            param($M)
            if ($M.Type -ne "vpnsub") { return }
            Set-VpnBanner "none" ""
            if ($M.Error) { Show-Toast "Подписка не скачалась: $($M.Error)" "fail"; return }
            [void](Add-VpnLinks @($M.Lines))
        })
    }
}

function Show-VpnRenameDialog {
    param($Pf)
    $D = New-Dialog "Переименовать" @"
<StackPanel>
    <TextBlock Text="Название профиля" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBox x:Name="FName" Style="{StaticResource Field}" Margin="0,14,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="Сохранить" MinWidth="120" Margin="8,0,0,0" IsDefault="True"/>
    </StackPanel>
</StackPanel>
"@ 440
    $FName = $D.FindName("FName"); $FName.Text = $Pf.Name
    $D.FindName("FOk").Add_Click({ if ($FName.Text.Trim()) { $D.DialogResult = $true } })
    $D.Add_ContentRendered({ [void]$FName.Focus(); $FName.SelectAll() })
    if (-not $D.ShowDialog()) { return }
    $script:Settings.VpnProfiles = @(Get-VpnProfiles | ForEach-Object { if ($_.Id -eq $Pf.Id) { $_.Name = $FName.Text.Trim() }; $_ })
    Save-Settings
    Refresh-Vpn
}

function Remove-VpnProfile {
    param($Pf)
    if (-not (Show-Confirm "Удалить профиль «$($Pf.Name)»?" "$($Pf.Server):$($Pf.Port) · ссылка уйдёт из настроек NetKnife." "Удалить" -Danger)) { return }
    if ($Pf.Id -eq (Get-VpnActiveId)) { Stop-Vpn -Quiet }
    $script:Settings.VpnProfiles = @(Get-VpnProfiles | Where-Object { $_.Id -ne $Pf.Id })
    Save-Settings
    Refresh-Vpn
    Show-Toast "Профиль удалён"
}

function Invoke-VpnAction {
    param([string]$Spec)
    $Op, $Id = $Spec -split ':', 2
    $Pf = @(Get-VpnProfiles) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $Pf) { return }
    switch ($Op) {
        "toggle" { if ($Pf.Id -eq (Get-VpnActiveId)) { Stop-Vpn } else { Start-Vpn $Pf } }
        "copy"   { Copy-Text $Pf.Link "ссылка «$($Pf.Name)»" }
        "edit"   { Show-VpnRenameDialog $Pf }
        "del"    { Remove-VpnProfile $Pf }
    }
}

function Get-SelectedVpn {
    $R = $Ui.VpnList.SelectedItem
    if ($R) { return $R.Profile }
    return $null
}

function Show-VpnPortDialog {
    $D = New-Dialog "Порт прокси" @"
<StackPanel>
    <TextBlock Text="Локальный порт прокси" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="mihomo слушает SOCKS5 и HTTP на 127.0.0.1:порт; этот адрес ставится системным прокси Windows. Меняется при следующем подключении." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,12" FontSize="12.5"/>
    <TextBox x:Name="FPort" Style="{StaticResource MonoField}" Width="140" HorizontalAlignment="Left"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="Сохранить" MinWidth="120" Margin="8,0,0,0" IsDefault="True"/>
    </StackPanel>
</StackPanel>
"@ 460
    $FPort = $D.FindName("FPort"); $FPort.Text = "$(Get-VpnPort)"
    $D.FindName("FOk").Add_Click({ if ($FPort.Text -match '^\d+$' -and [int]$FPort.Text -ge 1 -and [int]$FPort.Text -le 65535) { $D.DialogResult = $true } })
    if (-not $D.ShowDialog()) { return }
    $script:Settings.VpnPort = [int]$FPort.Text
    Save-Settings
    Show-Toast "Порт прокси: $($FPort.Text)"
}

function Initialize-VpnPage {
    Remove-StaleVpn
    $Ui.VpnList.ItemsSource = $script:VpnItems

    # one-shot: refresh the header external-IP pill a few seconds after connect/disconnect
    $script:VpnIpTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:VpnIpTimer.Interval = [TimeSpan]::FromSeconds(3)
    $script:VpnIpTimer.Add_Tick({ $script:VpnIpTimer.Stop(); try { Start-NetStatus } catch { } })

    $Ui.VpnAdd.Add_Click({ Show-VpnAddDialog })
    $Ui.VpnDisconnect.Add_Click({ Stop-Vpn })
    $Ui.VpnPortBtn.Add_Click({ Show-VpnPortDialog })
    $Ui.VpnInstallBtn.Add_Click({ param($S, $E) Show-Menu $S @(
        (New-MenuItem "xray — для VLESS (XTLS/Xray-core)" 0xE896 { Start-VpnInstall "xray" })
        (New-MenuItem "mihomo — для Hysteria2 и mieru (MetaCubeX/mihomo)" 0xE896 { Start-VpnInstall "mihomo" })
        (New-MenuItem "naive — для NaïveProxy (klzgrad/naiveproxy)" 0xE896 { Start-VpnInstall "naive" })
    ) })
    $Ui.VpnFolderBtn.Add_Click({ if (-not (Test-Path $script:VpnDir)) { New-Item -ItemType Directory -Path $script:VpnDir | Out-Null }; Start-Process explorer.exe -ArgumentList (Quote-Arg $script:VpnDir) })
    $Ui.VpnList.Add_MouseDoubleClick({ $Pf = Get-SelectedVpn; if ($Pf) { Invoke-VpnAction "toggle:$($Pf.Id)" } })
    $Ui.VpnList.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Подключить / отключить" 0xE768 { $Pf = Get-SelectedVpn; if ($Pf) { Invoke-VpnAction "toggle:$($Pf.Id)" } } "2×клик")
        "-"
        (New-MenuItem "Переименовать…" 0xE70F { $Pf = Get-SelectedVpn; if ($Pf) { Invoke-VpnAction "edit:$($Pf.Id)" } })
        (New-MenuItem "Копировать ссылку" 0xE8C8 { $Pf = Get-SelectedVpn; if ($Pf) { Invoke-VpnAction "copy:$($Pf.Id)" } })
        (New-MenuItem "Копировать адрес сервера" 0xE8C8 { $Pf = Get-SelectedVpn; if ($Pf) { Copy-Text $Pf.Server $Pf.Server } })
        (New-MenuItem "Пинг сервера" 0xE9D9 { $Pf = Get-SelectedVpn; if ($Pf) { Start-PingFor $Pf.Server } })
        (New-MenuItem "Показать конфиг движка" 0xE943 {
            $Pf = Get-SelectedVpn; if (-not $Pf) { return }
            $P = ConvertFrom-ProxyLink $Pf.Link
            $Eng = $(if ($P) { Get-VpnEngineFor $P.Type })
            if (-not $Eng) { Show-Toast "Для этого профиля нет движка" "warn"; return }
            $Port = Get-VpnPort; $Inner = $(if ($Eng -eq "naive") { $Port + 3 } else { 0 })   # the real inner port is picked on connect
            try {
                $J = $(if ($Eng -eq "xray") { New-XrayConfig $P $Port } else { New-MihomoConfig $P $Port -InnerPort $Inner })
                if ($Eng -eq "naive") { $J = "# naive.json (пароль скрыт)`n$(New-NaiveConfig $P $Inner -Mask)`n`n# mihomo.yaml`n$J" }
            } catch { $J = "ошибка: $($_.Exception.Message)" }
            Show-Confirm "$($script:VpnEngines[$Eng].Cfg) · $($Pf.Name)" "То, что получит $Eng для этого профиля." "Закрыть" -Detail $J | Out-Null
        })
        "-"
        (New-MenuItem "Удалить…" 0xE74D { $Pf = Get-SelectedVpn; if ($Pf) { Remove-VpnProfile $Pf } } "Del" "Fail")
    )
    Refresh-Vpn
}
