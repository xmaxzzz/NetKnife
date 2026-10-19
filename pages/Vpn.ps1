# Page: VPN. Profiles are vless:// / hysteria2:// share links (same format Happ/v2rayN use). One sing-box
# process runs the selected profile as a local mixed (SOCKS5+HTTP) proxy and NetKnife sets it as the
# Windows system proxy. sing-box is downloaded from the official GitHub release after confirmation.
# TUN mode (whole-system, needs admin + wintun) is a later step; the config builder already takes -Mode.

$script:VpnDir = Join-Path $script:DataDir "vpn"      # engine exes + generated configs + vpn.log
$script:VpnPidFile = Join-Path $script:DataDir "vpn.pid"
$script:VpnItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:Vpn = $null              # @{ P; Id; Started; Lines; ErrTask; Out; Error; Notified; Port }
$script:VpnPumpSw = [System.Diagnostics.Stopwatch]::StartNew()
$script:VpnWatchTick = 0
$script:VpnPending = $null       # profile id to connect once sing-box is installed
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
function ConvertFrom-ProxyLink {
    param([string]$Link)
    $Link = "$Link".Trim()
    if ($Link -notmatch '^(?i)(vless|hysteria2|hy2)://(.+)$') { return $null }
    $Type = $Matches[1].ToLower(); if ($Type -eq "hy2") { $Type = "hysteria2" }
    $Rest = $Matches[2]

    $Name = ""
    $Hash = $Rest.IndexOf('#')
    if ($Hash -ge 0) { $Name = [Uri]::UnescapeDataString($Rest.Substring($Hash + 1)); $Rest = $Rest.Substring(0, $Hash) }

    $Query = @{}
    $Qm = $Rest.IndexOf('?')
    if ($Qm -ge 0) {
        foreach ($Kv in ($Rest.Substring($Qm + 1) -split '&')) {
            if (-not $Kv) { continue }
            $Eq = $Kv.IndexOf('=')
            if ($Eq -lt 0) { $Query[$Kv] = ""; continue }
            $Query[$Kv.Substring(0, $Eq)] = [Uri]::UnescapeDataString($Kv.Substring($Eq + 1).Replace('+', '%2B'))
        }
        $Rest = $Rest.Substring(0, $Qm)
    }
    $Rest = $Rest.TrimEnd('/')

    $At = $Rest.LastIndexOf('@')
    if ($At -lt 0) { return $null }
    $Auth = [Uri]::UnescapeDataString($Rest.Substring(0, $At))
    $HostPort = $Rest.Substring($At + 1)
    if ($HostPort -notmatch '^(\[[^\]]+\]|[^:]+):(\d{1,5})$') { return $null }
    $Srv = $Matches[1].Trim('[', ']'); $Port = [int]$Matches[2]
    if (-not $Auth -or -not $Srv -or $Port -lt 1) { return $null }
    if (-not $Name) { $Name = "$Srv" }

    return [pscustomobject]@{ Type = $Type; Auth = $Auth; Server = $Srv; Port = $Port; Name = $Name; Query = $Query; Link = $Link }
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
    $Parts = @("udp/quic")
    if ($Q.obfs) { $Parts += "obfs" }
    if ($Q.insecure -eq "1") { $Parts += "insecure" }
    return ($Parts -join " · ")
}

# Throws with a readable message when the link needs something sing-box can't do.
function New-SingBoxConfig {
    param($P, [int]$Port, [string]$Mode = "proxy")
    $Q = $P.Query
    $Out = [ordered]@{ type = $P.Type; tag = "proxy"; server = $P.Server; server_port = $P.Port }

    if ($P.Type -eq "vless") {
        $Out.uuid = $P.Auth
        if ($Q.flow) { $Out.flow = $Q.flow }
        $Sec = "$($Q.security)".ToLower()
        if ($Sec -in @("tls", "reality")) {
            $Tls = [ordered]@{ enabled = $true }
            if ($Q.sni) { $Tls.server_name = $Q.sni } elseif ($Q.host) { $Tls.server_name = $Q.host }
            if ($Q.allowInsecure -eq "1" -or $Q.insecure -eq "1") { $Tls.insecure = $true }
            if ($Q.alpn) { $Tls.alpn = @($Q.alpn -split ',' | Where-Object { $_ }) }
            $Tls.utls = [ordered]@{ enabled = $true; fingerprint = $(if ($Q.fp) { $Q.fp } else { "chrome" }) }
            if ($Sec -eq "reality") {
                if (-not $Q.pbk) { throw "reality без pbk (public key) — ссылка неполная" }
                $Tls.reality = [ordered]@{ enabled = $true; public_key = $Q.pbk; short_id = "$($Q.sid)" }
            }
            $Out.tls = $Tls
        }
        $Net = $(if ($Q.type) { "$($Q.type)".ToLower() } else { "tcp" })
        switch ($Net) {
            "tcp"  { }
            "ws"   {
                $T = [ordered]@{ type = "ws"; path = $(if ($Q.path) { $Q.path } else { "/" }) }
                if ($Q.host) { $T.headers = [ordered]@{ Host = $Q.host } }
                $Out.transport = $T
            }
            "grpc" { $Out.transport = [ordered]@{ type = "grpc"; service_name = "$($Q.serviceName)" } }
            "httpupgrade" {
                $T = [ordered]@{ type = "httpupgrade"; path = $(if ($Q.path) { $Q.path } else { "/" }) }
                if ($Q.host) { $T.host = $Q.host }
                $Out.transport = $T
            }
            "h2" { $Out.transport = [ordered]@{ type = "http"; path = $(if ($Q.path) { $Q.path } else { "/" }) } }
            default { throw "транспорт «$Net» sing-box не умеет (xhttp/splithttp — только xray)" }
        }
    } else {
        $Out.password = $P.Auth
        $Tls = [ordered]@{ enabled = $true; alpn = @("h3") }
        if ($Q.sni) { $Tls.server_name = $Q.sni }
        if ($Q.insecure -eq "1") { $Tls.insecure = $true }
        $Out.tls = $Tls
        if ("$($Q.obfs)" -eq "salamander") { $Out.obfs = [ordered]@{ type = "salamander"; password = "$($Q.'obfs-password')" } }
        if ($Q.upmbps -match '^\d+$') { $Out.up_mbps = [int]$Q.upmbps }
        if ($Q.downmbps -match '^\d+$') { $Out.down_mbps = [int]$Q.downmbps }
    }

    $Inbound = if ($Mode -eq "tun") {
        [ordered]@{ type = "tun"; tag = "in"; address = @("172.19.0.1/30"); auto_route = $true; strict_route = $true; stack = "system" }
    } else {
        [ordered]@{ type = "mixed"; tag = "in"; listen = "127.0.0.1"; listen_port = $Port }
    }
    $Cfg = [ordered]@{
        log = [ordered]@{ level = "info"; timestamp = $true }
        inbounds = @($Inbound)
        outbounds = @($Out, [ordered]@{ type = "direct"; tag = "direct" })
        route = [ordered]@{
            rules = @([ordered]@{ ip_is_private = $true; outbound = "direct" })
            final = "proxy"; auto_detect_interface = $true
        }
    }
    return ($Cfg | ConvertTo-Json -Depth 8)
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
        $Mine = Get-CimInstance Win32_Process -Filter "Name = 'xray.exe' OR Name = 'mihomo.exe' OR Name = 'koala-mihomo.exe'" -ErrorAction SilentlyContinue |
            Where-Object { "$($_.CommandLine)" -like "*$($script:VpnDir)*" }
        foreach ($P in $Mine) { try { Stop-Process -Id $P.ProcessId -Force -ErrorAction Stop; Write-AppLog "vpn: killed engine pid $($P.ProcessId)" } catch { } }
    } catch { }
}

# ---------------------------------------------------------------- engines
# VLESS → xray-core (the only core that follows current REALITY; it's also what Happ ships — reused when found).
# Hysteria2 → mihomo (xray has no hysteria). Each is one exe in %APPDATA%\NetKnife\vpn or a known local install.

$script:VpnEngines = @{
    xray   = @{ Title = "xray";   Exe = "xray.exe";   Repo = "XTLS/Xray-core";   Asset = '^Xray-windows-64\.zip$';                       AssetArm = '^Xray-windows-arm64-v8a\.zip$';  ExeMatch = "xray.exe";    VerArgs = "version"; Cfg = "xray.json"
                Fallback = @("$env:ProgramFiles\FlyFrogLLC\Happ\core\xray.exe") }
    mihomo = @{ Title = "mihomo"; Exe = "mihomo.exe"; Repo = "MetaCubeX/mihomo"; Asset = '^mihomo-windows-amd64-compatible-v[\d.]+\.zip$'; AssetArm = '^mihomo-windows-arm64-v[\d.]+\.zip$'; ExeMatch = "mihomo*.exe"; VerArgs = "-v";      Cfg = "mihomo.yaml"
                Fallback = @("$env:ProgramFiles\Koala Clash\koala-mihomo.exe") }
}

function Get-VpnEngineFor { param([string]$Type) if ($Type -eq "vless") { return "xray" }; return "mihomo" }

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
    param($P, [int]$Port, [string]$Mode = "proxy")
    $Q = $P.Query
    $Y = [System.Text.StringBuilder]::new()
    [void]$Y.AppendLine("  - name: proxy")
    [void]$Y.AppendLine("    type: $($P.Type)")
    [void]$Y.AppendLine("    server: $(ConvertTo-YamlStr $P.Server)")
    [void]$Y.AppendLine("    port: $($P.Port)")
    [void]$Y.AppendLine("    udp: true")

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
    } else {
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

# ---------------------------------------------------------------- engine download

# step 1: ask GitHub which release is current (worker, so the UI stays alive on a slow network)
$script:VpnMetaBody = {
    param($Q, $Ctl, $Repo, $Pat)
    try {
        $Rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "NetKnife" } -TimeoutSec 25
        $Asset = @($Rel.assets | Where-Object { $_.name -match $Pat }) | Select-Object -First 1
        if (-not $Asset) { $Q.Enqueue(@{ Type = "vpnmeta"; Error = "в релизе $($Rel.tag_name) нет подходящей сборки для Windows" }); return }
        $Q.Enqueue(@{ Type = "vpnmeta"; Version = "$($Rel.tag_name)"; Url = "$($Asset.browser_download_url)"; Size = [long]$Asset.size; Name = "$($Asset.name)" })
    } catch { $Q.Enqueue(@{ Type = "vpnmeta"; Error = "GitHub не ответил: $($_.Exception.Message)" }) }
}

# step 2 (after the user confirmed): download the zip, pull the engine exe out of it
$script:VpnDownloadBody = {
    param($Q, $Ctl, $Url, $Dir, $ExeMatch, $Target)
    try {
        if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
        $Zip = Join-Path $Dir "download.zip"
        $Tmp = Join-Path $Dir "unpack"
        if (Test-Path $Tmp) { Remove-Item $Tmp -Recurse -Force }
        Invoke-WebRequest $Url -OutFile $Zip -Headers @{ "User-Agent" = "NetKnife" } -TimeoutSec 300
        Expand-Archive $Zip -DestinationPath $Tmp -Force
        $Exe = Get-ChildItem $Tmp -Recurse -Filter $ExeMatch | Select-Object -First 1
        if (-not $Exe) { $Q.Enqueue(@{ Type = "vpndl"; Error = "в архиве нет $ExeMatch" }); return }
        Copy-Item $Exe.FullName (Join-Path $Dir $Target) -Force
        Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $Zip -Force -ErrorAction SilentlyContinue
        $Q.Enqueue(@{ Type = "vpndl"; Ok = $true })
    } catch { $Q.Enqueue(@{ Type = "vpndl"; Error = "$($_.Exception.Message)" }) }
}

function Start-VpnInstall {
    param([string]$Engine = "xray")
    if ((Test-WorkerRunning "vpn-meta") -or (Test-WorkerRunning "vpn-dl")) { return }
    $E = $script:VpnEngines[$Engine]
    $Pat = if ("$env:PROCESSOR_ARCHITECTURE" -eq "ARM64") { $E.AssetArm } else { $E.Asset }
    Set-VpnBanner "wait" "Узнаю актуальную версию $($E.Title) на GitHub…"
    [void](Start-Worker -Name "vpn-meta" -Body $script:VpnMetaBody -ArgList @($E.Repo, $Pat) -OnMessage {
        param($M)
        if ($M.Type -ne "vpnmeta") { return }
        if ($M.Error) { Set-VpnBanner "fail" "$($E.Title) не скачать: $($M.Error)"; $script:VpnPending = $null; return }
        $script:VpnInstall = @{ Engine = $Engine; Version = $M.Version; Url = $M.Url; Size = $M.Size; Name = $M.Name }
        Set-VpnBanner "none" ""
        $Mb = "{0:N1} МБ" -f ($M.Size / 1MB)
        $Msg = "Движок VPN. Скачается официальный релиз $($E.Repo) $($M.Version) ($Mb) в $($script:VpnDir). Больше ничего не ставится и не меняется."
        if (-not (Show-Confirm "Скачать $($E.Title) $($M.Version)?" $Msg "Скачать" -Detail $M.Url)) { $script:VpnPending = $null; return }
        Set-VpnBanner "wait" "Скачиваю $($E.Title) $($M.Version) ($Mb)…"
        [void](Start-Worker -Name "vpn-dl" -Body $script:VpnDownloadBody -ArgList @($M.Url, $script:VpnDir, $E.ExeMatch, $E.Exe) -OnMessage {
            param($M2)
            if ($M2.Type -ne "vpndl") { return }
            if ($M2.Error) { Set-VpnBanner "fail" "Загрузка не удалась: $($M2.Error)"; $script:VpnPending = $null; return }
            Set-VpnBanner "none" ""
            Show-Toast "$($E.Title) $($script:VpnInstall.Version) установлен"
            [void](Get-VpnEngineVersion $Engine -Fresh)
            Refresh-Vpn
            if ($script:VpnPending) {
                $Pf = @(Get-VpnProfiles) | Where-Object { $_.Id -eq $script:VpnPending } | Select-Object -First 1
                $script:VpnPending = $null
                if ($Pf) { Start-Vpn $Pf }
            }
        })
    })
}

# ---------------------------------------------------------------- run / stop

function Test-VpnRunning { return [bool]($script:Vpn -and $script:Vpn.P -and -not $script:Vpn.P.HasExited) }

function Get-VpnActiveId { if (Test-VpnRunning) { return $script:Vpn.Id }; return $null }

function Save-VpnPid {
    try {
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir | Out-Null }
        if (Test-VpnRunning) { [IO.File]::WriteAllText($script:VpnPidFile, "$($script:Vpn.P.Id)") } elseif (Test-Path $script:VpnPidFile) { [IO.File]::Delete($script:VpnPidFile) }
    } catch { }
}

# after a hard crash: kill the orphaned sing-box and put the system proxy back
function Remove-StaleVpn {
    if (Test-Path $script:VpnPidFile) {
        $Line = (Get-Content $script:VpnPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($Line -match '^\d+$') {
            $P = Get-Process -Id ([int]$Line) -ErrorAction SilentlyContinue
            if ($P -and $P.ProcessName -in @("xray", "mihomo", "sing-box")) { try { $P.Kill(); Write-AppLog "stale $($P.ProcessName) killed: $Line" } catch { } }
        }
        try { [IO.File]::Delete($script:VpnPidFile) } catch { }
    }
    if ($script:Settings.VpnProxySet) {
        Write-AppLog "vpn: system proxy was left on — restoring"
        try { Set-SystemProxy "" } catch { }
    }
    [void](Repair-SystemProxy "startup")
}

function Start-Vpn {
    param($Pf)
    if (Test-VpnRunning) { Stop-Vpn -Quiet }

    $P = ConvertFrom-ProxyLink $Pf.Link
    if (-not $P) { Show-Toast "Ссылка профиля «$($Pf.Name)» не разбирается" "fail"; return }
    $Engine = Get-VpnEngineFor $P.Type
    $E = $script:VpnEngines[$Engine]
    $Exe = Get-VpnEngineExe $Engine
    if (-not $Exe) { $script:VpnPending = $Pf.Id; Start-VpnInstall $Engine; return }

    $Port = Get-VpnPort
    try { $Text = $(if ($Engine -eq "xray") { New-XrayConfig $P $Port } else { New-MihomoConfig $P $Port }) } catch { Show-Toast "«$($Pf.Name)»: $($_.Exception.Message)" "fail"; return }
    if (Test-LocalPortBusy $Port) { Show-Toast "Порт $Port занят на этом ПК — смени в настройках VPN" "warn"; return }

    if (-not (Test-Path $script:VpnDir)) { New-Item -ItemType Directory -Path $script:VpnDir | Out-Null }
    $Cfg = Join-Path $script:VpnDir $E.Cfg
    [IO.File]::WriteAllText($Cfg, $Text, [System.Text.UTF8Encoding]::new($false))

    # dry-run validates the config and fails fast with a readable reason instead of a dead process
    $ChkArgs = $(if ($Engine -eq "xray") { "run -test -c $(Quote-Arg $Cfg)" } else { "-t -f $(Quote-Arg $Cfg) -d $(Quote-Arg $script:VpnDir)" })
    $Chk = Invoke-SingBox $Exe $ChkArgs
    if ($Chk.Code -ne 0) {
        $script:Vpn = @{ P = $null; Id = $Pf.Id; Started = [DateTime]::Now; Error = "конфиг не прошёл проверку"; Notified = $true; Lines = [System.Collections.Generic.List[string]]::new() }
        Show-Confirm "$($E.Title) отверг конфиг" "Профиль «$($Pf.Name)». Ниже — вывод проверки." "Закрыть" -Detail $Chk.Out | Out-Null
        Refresh-Vpn
        return
    }

    $Psi = New-Object System.Diagnostics.ProcessStartInfo $Exe
    $Psi.Arguments = $(if ($Engine -eq "xray") { "run -c $(Quote-Arg $Cfg)" } else { "-f $(Quote-Arg $Cfg) -d $(Quote-Arg $script:VpnDir)" })
    $Psi.WorkingDirectory = $script:VpnDir
    $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardError = $true; $Psi.RedirectStandardOutput = $true
    try {
        $Proc = [System.Diagnostics.Process]::Start($Psi)
        Add-ProcessToJob $Proc
        # mihomo logs to stdout; keep stderr too for crashes
        $script:Vpn = @{ P = $Proc; Id = $Pf.Id; Engine = $Engine; Started = [DateTime]::Now; ErrTask = $Proc.StandardError.ReadLineAsync(); OutTask = $Proc.StandardOutput.ReadLineAsync(); Lines = [System.Collections.Generic.List[string]]::new(); Error = ""; Notified = $false; Port = $Port }
        Save-VpnPid
        Set-SystemProxy "127.0.0.1:$Port"
        $script:Settings.VpnLast = $Pf.Id; Save-Settings
        Show-Toast "VPN «$($Pf.Name)»: подключаюсь, системный прокси 127.0.0.1:$Port" "info"
        Start-VpnProbe $Pf $Port
        Start-VpnStats $Engine $Exe $Port $P.Server $P.Port
    } catch {
        # whatever failed after Start (proxy registry etc.) — don't leave sing-box running headless
        if ($Proc -and -not $Proc.HasExited) { try { $Proc.Kill($true) } catch { } }
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
    [void](Start-Worker -Name "vpn-probe" -Replace -Body $script:VpnProbeBody -ArgList @($Port) -OnMessage {
        param($M)
        if ($M.Type -ne "vpnprobe") { return }
        if (-not $script:Vpn -or $script:Vpn.Id -ne $Id -or -not (Test-VpnRunning)) { return }   # already stopped/switched
        if ($M.Ip) {
            $script:Vpn.Egress = $M.Ip
            Show-Toast "VPN работает · внешний IP $($M.Ip)" "ok"
            Show-TrayBalloon "VPN подключён" "$($Pf.Name) · выход $($M.Ip)" "Info"
            $script:VpnIpTimer.Stop(); $script:VpnIpTimer.Start()
        } else {
            $Tail = @($script:Vpn.Lines | Select-Object -Last 3) -join "`n"
            Stop-Vpn -Quiet
            $script:Vpn = @{ P = $null; Id = $Id; Started = [DateTime]::Now; Error = "туннель не отвечает — прокси возвращён"; Notified = $true; Lines = [System.Collections.Generic.List[string]]::new() }
            Show-Toast "VPN «$($Pf.Name)»: через туннель ничего не проходит — отключил, интернет как был" "fail"
            Write-AppLog "vpn probe failed for $($Pf.Name): $($M.Error)`n$Tail"
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

function Invoke-SingBox {
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
    $script:Vpn = $null
    Stop-VpnStats
    Save-VpnPid
    Stop-VpnEngineProcesses
    # unconditional: the VpnProxySet flag can be clobbered by a second NetKnife instance saving settings
    try { Set-SystemProxy "" } catch { Write-AppLog "vpn: proxy restore failed: $_" }
    [void](Repair-SystemProxy "after stop")
    if (-not $Quiet) { Show-Toast "VPN отключён$(if ($Name) { ": $Name" })" "info"; $script:VpnIpTimer.Stop(); $script:VpnIpTimer.Start() }
    if ($Ui) { Refresh-Vpn }
}

# Called from the main pump once a second: drain sing-box log, notice a crash, tick the uptime
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

    $Changed = $false
    foreach ($Key in @("OutTask", "ErrTask")) {
        $Stream = $(if ($Key -eq "OutTask") { $S.P.StandardOutput } else { $S.P.StandardError })
        while ($S[$Key] -and $S[$Key].IsCompleted) {
            $L = $null
            try { $L = $S[$Key].Result } catch { }
            if ($null -eq $L) { $S[$Key] = $null; break }
            $L = ($L -replace "\x1b\[[0-9;]*m", "").Trim()   # strip ANSI colors
            if ($L) {
                $S.Lines.Add($L); if ($S.Lines.Count -gt 200) { $S.Lines.RemoveAt(0) }; $Changed = $true
                try { Add-Content -Path (Join-Path $script:VpnDir "vpn.log") -Value $L -Encoding UTF8 } catch { }
            }
            $S[$Key] = $Stream.ReadLineAsync()
        }
    }
    if ($Changed -and $script:Page -eq "vpn") { Update-VpnLog }

    if ($S.P.HasExited -and -not $S.Notified) {
        $S.Notified = $true
        $Last = @($S.Lines | Where-Object { $_ -match 'level=(error|fatal)|FATAL|ERROR|\[Error\]|failed to' } | Select-Object -Last 1)
        $Err = if ($Last) { $Last[0] -replace '^.*msg="?', '' -replace '"$', '' -replace '^\S+ \S+ \[\w+\] ', '' } elseif ($S.Lines.Count) { $S.Lines[$S.Lines.Count - 1] } else { "$($S.Engine) завершился, код $($S.P.ExitCode)" }
        $S.Error = $Err
        try { Set-SystemProxy "" } catch { }
        Save-VpnPid
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
        TypeText = $(if ($Pf.Type -eq "vless") { "VLESS" } else { "Hysteria2" })
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
        Set-StatusPill $Ui.VpnStatePill $Ui.VpnState "ok" "подключён: $($Pf.Name) · $($script:Vpn.Engine) · прокси 127.0.0.1:$($script:Vpn.Port)$(if ($St) { "  ·  $St" })"
    } elseif ($script:Vpn -and $script:Vpn.Error) {
        Set-StatusPill $Ui.VpnStatePill $Ui.VpnState "fail" $script:Vpn.Error
    } else {
        Set-StatusPill $Ui.VpnStatePill $Ui.VpnState "none" "отключён"
    }
    $Xv = Get-VpnEngineVersion "xray"; $Mv = Get-VpnEngineVersion "mihomo"
    $Parts = @(
        $(if ($Xv) { "xray $Xv" } else { "xray: нет — скачается для VLESS (спрошу)" })
        $(if ($Mv) { "mihomo $Mv" } else { "mihomo: нет — скачается для Hysteria2 (спрошу)" })
    )
    $Ui.VpnEngine.Text = $Parts -join "   ·   "
    $Ui.VpnEngine.ToolTip = "xray: $(Get-VpnEngineExe 'xray')`nmihomo: $(Get-VpnEngineExe 'mihomo')"
    $Ui.VpnEngine.Foreground = $(if ($Xv -or $Mv) { Get-Brush "Faint" } else { Get-Brush "Warn" })
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
    if (-not $N) { return "VLESS и Hysteria2 через mihomo · вставь ссылку из Happ" }
    return "$(Get-Plural $N 'профиль' 'профиля' 'профилей') · отключён"
}

# ---------------------------------------------------------------- import

function Add-VpnLinks {
    param([string[]]$Lines, [switch]$Quiet)
    $List = @(Get-VpnProfiles)
    $Added = 0; $Dup = 0; $Bad = 0
    foreach ($Line in $Lines) {
        $L = "$Line".Trim()
        if (-not $L -or $L.StartsWith("#")) { continue }
        $P = ConvertFrom-ProxyLink $L
        if (-not $P) { $Bad++; continue }
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
        if ($Bad) { $Msg += " · не разобрал: $Bad" }
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
    <TextBlock Text="Вставь ссылки vless:// или hysteria2:// (одна на строку — в Happ: профиль → «Копировать ссылку»). Или адрес подписки https://… — скачаю и разберу." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,12" FontSize="12.5"/>
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
    try { $Clip = [System.Windows.Clipboard]::GetText(); if ($Clip -match '^(?i)(vless|hysteria2|hy2|https?)://') { $F.FText.Text = $Clip.Trim() } } catch { }
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
        (New-MenuItem "mihomo — для Hysteria2 (MetaCubeX/mihomo)" 0xE896 { Start-VpnInstall "mihomo" })
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
            $Eng = Get-VpnEngineFor $P.Type
            try { $J = $(if ($Eng -eq "xray") { New-XrayConfig $P (Get-VpnPort) } else { New-MihomoConfig $P (Get-VpnPort) }) } catch { $J = "ошибка: $($_.Exception.Message)" }
            Show-Confirm "$($script:VpnEngines[$Eng].Cfg) · $($Pf.Name)" "То, что получит $Eng для этого профиля." "Закрыть" -Detail $J | Out-Null
        })
        "-"
        (New-MenuItem "Удалить…" 0xE74D { $Pf = Get-SelectedVpn; if ($Pf) { Remove-VpnProfile $Pf } } "Del" "Fail")
    )
    Refresh-Vpn
}
