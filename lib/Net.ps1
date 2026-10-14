# Network helpers. Pure functions: loaded both in UI and inside thread jobs.

# ---------------------------------------------------------------- IPv4 math

function ConvertTo-IpUInt {
    param([string]$Ip)
    $B = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
    return [uint32](([uint64]$B[0] -shl 24) -bor ([uint64]$B[1] -shl 16) -bor ([uint64]$B[2] -shl 8) -bor [uint64]$B[3])
}

function ConvertFrom-IpUInt {
    param([uint32]$N)
    return "{0}.{1}.{2}.{3}" -f (($N -shr 24) -band 255), (($N -shr 16) -band 255), (($N -shr 8) -band 255), ($N -band 255)
}

function Get-IpMask {
    param([int]$Prefix)
    if ($Prefix -le 0) { return [uint32]0 }
    return [uint32]([uint32]::MaxValue - ([uint32]([Math]::Pow(2, 32 - $Prefix)) - 1))
}

function Test-IpInNet {
    param([string]$Ip, [string]$Net, [int]$Prefix)
    if ($Prefix -le 0) { return $true }
    $Mask = Get-IpMask $Prefix
    return (((ConvertTo-IpUInt $Ip) -band $Mask) -eq ((ConvertTo-IpUInt $Net) -band $Mask))
}

function Test-PrivateIp {
    param([string]$Ip)
    return ($Ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)')
}

function Test-FakeIp {
    param([string]$Ip)
    return ($Ip -match '^198\.(18|19)\.')
}

# Range syntax: 192.168.1.0/24 | 10.0.0.1-50 | 10.0.0.1-10.0.1.20 | 192.168.5.* | 192.168.5 | single IP; comma/space separated
function Expand-IpRange {
    param([string]$Text, [int]$Limit = 65536)

    $Out = [System.Collections.Generic.List[string]]::new()
    $Seen = [System.Collections.Generic.HashSet[string]]::new()
    $Errors = @()

    foreach ($Tok in ($Text -split '[,;\s]+' | Where-Object { $_ })) {
        $Tok = $Tok.Trim()
        $From = $null; $To = $null

        try {
            if ($Tok -match '^(\d{1,3}(\.\d{1,3}){3})/(\d{1,2})$') {
                $Prefix = [int]$Matches[3]
                if ($Prefix -lt 8 -or $Prefix -gt 32) { throw "маска /$Prefix" }
                $Mask = Get-IpMask $Prefix
                $Net = [uint32]((ConvertTo-IpUInt $Matches[1]) -band $Mask)
                $Bcast = [uint32]($Net -bor ([uint32]::MaxValue -bxor $Mask))
                if ($Prefix -le 30) { $From = $Net + 1; $To = $Bcast - 1 } else { $From = $Net; $To = $Bcast }
            }
            elseif ($Tok -match '^(\d{1,3}(\.\d{1,3}){3})-(\d{1,3}(\.\d{1,3}){3})$') {
                $From = ConvertTo-IpUInt $Matches[1]; $To = ConvertTo-IpUInt $Matches[3]
            }
            elseif ($Tok -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.(\d{1,3})-(\d{1,3})$') {
                $From = ConvertTo-IpUInt "$($Matches[1]).$($Matches[2])"; $To = ConvertTo-IpUInt "$($Matches[1]).$($Matches[3])"
            }
            elseif ($Tok -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})(\.\*)?$') {
                $From = ConvertTo-IpUInt "$($Matches[1]).1"; $To = ConvertTo-IpUInt "$($Matches[1]).254"
            }
            elseif ($Tok -match '^(\d{1,3}\.\d{1,3})\.\*\.\*$') {
                $From = ConvertTo-IpUInt "$($Matches[1]).0.1"; $To = ConvertTo-IpUInt "$($Matches[1]).255.254"
            }
            elseif ($Tok -match '^\d{1,3}(\.\d{1,3}){3}$') {
                $From = ConvertTo-IpUInt $Tok; $To = $From
            }
            else {
                $Addr = [System.Net.Dns]::GetHostAddresses($Tok) | Where-Object { $_.AddressFamily -eq "InterNetwork" } | Select-Object -First 1
                if (-not $Addr) { throw "не резолвится" }
                $From = ConvertTo-IpUInt $Addr.ToString(); $To = $From
            }

            if ($To -lt $From) { $T = $From; $From = $To; $To = $T }
            for ($N = [uint64]$From; $N -le $To; $N++) {
                $Ip = ConvertFrom-IpUInt ([uint32]$N)
                if ($Seen.Add($Ip)) { $Out.Add($Ip) }
                if ($Out.Count -ge $Limit) { break }
            }
        } catch {
            $Errors += "$Tok — $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{ Ips = $Out.ToArray(); Errors = $Errors }
}

# Subnet math for "192.168.1.0/24", "192.168.1.10 255.255.255.0", "10.0.0.5" (assumes /24), "192.168.5" (/24), "10" (/8)
function Get-SubnetInfo {
    param([string]$Text)

    $Text = $Text.Trim()
    $Ip = $null; $Prefix = $null
    if ($Text -match '^(\d{1,3}(\.\d{1,3}){3})\s*/\s*(\d{1,2})$') {
        $Ip = $Matches[1]; $Prefix = [int]$Matches[3]
    } elseif ($Text -match '^(\d{1,3}(\.\d{1,3}){3})[\s,]+(\d{1,3}(\.\d{1,3}){3})$') {
        $Ip = $Matches[1]
        $Bits = [Convert]::ToString((ConvertTo-IpUInt $Matches[3]), 2).PadLeft(32, '0')
        if ($Bits -notmatch '^1*0*$') { throw "маска не непрерывная: $($Matches[3])" }
        $Prefix = ($Bits.ToCharArray() | Where-Object { $_ -eq '1' }).Count
    } elseif ($Text -match '^\d{1,3}(\.\d{1,3}){0,3}$') {
        $Parts = @($Text -split '\.')
        $Prefix = [Math]::Min(24, 8 * $Parts.Count)
        while ($Parts.Count -lt 4) { $Parts += "0" }
        $Ip = $Parts -join '.'
    } else {
        throw "формат: 192.168.1.0/24, 192.168.1.0 255.255.255.0 или 192.168.1"
    }
    if ($Prefix -lt 0 -or $Prefix -gt 32) { throw "префикс 0–32" }

    $Mask = Get-IpMask $Prefix
    $N = ConvertTo-IpUInt $Ip
    $Net = [uint32]($N -band $Mask)
    $Bcast = [uint32]($Net -bor ([uint32]::MaxValue -bxor $Mask))
    $Small = $Prefix -ge 31
    $First = [uint32]$(if ($Small) { $Net } else { $Net + 1 })
    $Last = [uint32]$(if ($Small) { $Bcast } else { $Bcast - 1 })
    $Count = [int64][Math]::Pow(2, 32 - $Prefix) - $(if ($Small) { 0 } else { 2 })
    $MaskBits = [Convert]::ToString($Mask, 2).PadLeft(32, '0')
    $FirstOctet = [int]($Ip -split '\.')[0]
    $Class = if ($FirstOctet -lt 128) { "A" } elseif ($FirstOctet -lt 192) { "B" } elseif ($FirstOctet -lt 224) { "C" } elseif ($FirstOctet -lt 240) { "D (multicast)" } else { "E" }

    return [ordered]@{
        Ip = $Ip; Prefix = $Prefix
        Cidr = "$(ConvertFrom-IpUInt $Net)/$Prefix"
        Mask = (ConvertFrom-IpUInt $Mask)
        MaskBits = (($MaskBits -split '(.{8})' | Where-Object { $_ }) -join '.')
        Wildcard = (ConvertFrom-IpUInt ([uint32]([uint32]::MaxValue -bxor $Mask)))
        Network = (ConvertFrom-IpUInt $Net); Broadcast = (ConvertFrom-IpUInt $Bcast)
        FirstHost = (ConvertFrom-IpUInt $First); LastHost = (ConvertFrom-IpUInt $Last)
        Hosts = $Count; Class = $Class; Private = (Test-PrivateIp $Ip)
        Range = "$(ConvertFrom-IpUInt $First)-$(ConvertFrom-IpUInt $Last)"
    }
}

# "22,80,8000-8100" -> int[]
function Expand-PortSpec {
    param([string]$Text)
    $Set = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($Tok in ($Text -split '[,;\s]+' | Where-Object { $_ })) {
        if ($Tok -match '^(\d+)-(\d+)$') {
            $A = [int]$Matches[1]; $B = [int]$Matches[2]
            if ($A -gt $B) { $T = $A; $A = $B; $B = $T }
            for ($P = [Math]::Max(1, $A); $P -le [Math]::Min(65535, $B); $P++) { [void]$Set.Add($P) }
        } elseif ($Tok -match '^\d+$' -and [int]$Tok -ge 1 -and [int]$Tok -le 65535) {
            [void]$Set.Add([int]$Tok)
        }
    }
    return [int[]]@($Set)
}

# ---------------------------------------------------------------- ports & services

$script:ServiceNames = @{
    20 = "ftp-data"; 21 = "ftp"; 22 = "ssh"; 23 = "telnet"; 25 = "smtp"; 53 = "dns"; 67 = "dhcp"; 69 = "tftp"
    80 = "http"; 81 = "http-alt"; 88 = "kerberos"; 110 = "pop3"; 111 = "rpcbind"; 123 = "ntp"; 135 = "msrpc"
    139 = "netbios"; 143 = "imap"; 161 = "snmp"; 389 = "ldap"; 443 = "https"; 445 = "smb"; 465 = "smtps"
    500 = "ipsec"; 514 = "syslog"; 515 = "printer"; 548 = "afp"; 554 = "rtsp"; 587 = "submission"; 631 = "ipp"
    636 = "ldaps"; 853 = "dns-tls"; 873 = "rsync"; 993 = "imaps"; 995 = "pop3s"; 1080 = "socks"; 1194 = "openvpn"
    1433 = "mssql"; 1521 = "oracle"; 1723 = "pptp"; 1883 = "mqtt"; 1900 = "upnp"; 2049 = "nfs"; 2082 = "cpanel"
    2083 = "cpanel-ssl"; 2222 = "ssh-alt"; 2375 = "docker"; 2376 = "docker-tls"; 3000 = "http-dev"; 3128 = "squid"
    3306 = "mysql"; 3389 = "rdp"; 3478 = "stun"; 4443 = "https-alt"; 5000 = "http-alt"; 5001 = "synology"
    5060 = "sip"; 5222 = "xmpp"; 5353 = "mdns"; 5432 = "postgres"; 5555 = "adb"; 5672 = "amqp"; 5678 = "n8n"
    5900 = "vnc"; 5938 = "teamviewer"; 6379 = "redis"; 6443 = "kube-api"; 6881 = "bittorrent"; 7000 = "http-alt"
    7681 = "ttyd"; 8000 = "http-alt"; 8006 = "proxmox"; 8008 = "http-alt"; 8080 = "http-proxy"; 8081 = "http-alt"
    8086 = "influxdb"; 8088 = "http-alt"; 8123 = "home-assistant"; 8200 = "vault"; 8291 = "winbox"
    8443 = "https-alt"; 8728 = "mikrotik-api"; 8729 = "mikrotik-api-ssl"; 8883 = "mqtts"; 8888 = "http-alt"
    9000 = "portainer"; 9001 = "http-alt"; 9090 = "prometheus"; 9091 = "transmission"; 9100 = "node-exporter"
    9200 = "elastic"; 9443 = "portainer-ssl"; 10000 = "webmin"; 11211 = "memcached"; 25565 = "minecraft"
    27017 = "mongodb"; 32400 = "plex"; 51820 = "wireguard"
}

$script:StandardPorts = @(21, 22, 23, 25, 53, 80, 81, 110, 111, 135, 139, 143, 443, 445, 465, 587, 993, 995, 1433, 1723, 1883,
    2222, 3000, 3306, 3389, 5000, 5432, 5678, 5900, 6379, 8000, 8006, 8080, 8123, 8291, 8443, 8728, 8888, 9000, 9090, 9100, 9443, 10000, 27017)

$script:WebPlainPorts = @(80, 81, 3000, 5000, 5678, 7000, 7681, 8000, 8008, 8080, 8081, 8088, 8123, 8888, 9000, 9001, 9090, 9091, 10000, 32400)
$script:WebTlsPorts = @(443, 2083, 4443, 5001, 8006, 8443, 9443)

function Get-ExtendedPorts {
    $L = [System.Collections.Generic.SortedSet[int]]::new()
    1..1024 | ForEach-Object { [void]$L.Add($_) }
    foreach ($P in $script:ServiceNames.Keys) { [void]$L.Add([int]$P) }
    foreach ($P in $script:StandardPorts) { [void]$L.Add([int]$P) }
    return [int[]]@($L)
}

function Get-ServiceName {
    param([int]$Port)
    if ($script:ServiceNames.ContainsKey($Port)) { return $script:ServiceNames[$Port] }
    return ""
}

# ---------------------------------------------------------------- local networks

function Get-LocalNets {
    $Result = @()
    try {
        $Ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.AddressState -eq "Preferred" }
        $Adapters = @{}
        Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { $Adapters[$_.ifIndex] = $_ }
        foreach ($I in $Ips) {
            $A = $Adapters[$I.InterfaceIndex]
            $Net = ConvertFrom-IpUInt ([uint32]((ConvertTo-IpUInt $I.IPAddress) -band (Get-IpMask $I.PrefixLength)))
            $Result += [pscustomobject]@{
                Ip = $I.IPAddress; Prefix = [int]$I.PrefixLength; Net = $Net; Alias = $I.InterfaceAlias
                Description = $(if ($A) { $A.InterfaceDescription } else { "" })
                IfIndex = $I.InterfaceIndex
                Tunnel = (Test-TunnelAdapter "$($I.InterfaceAlias) $(if ($A) { $A.InterfaceDescription })")
            }
        }
    } catch { }
    return $Result
}

function Test-TunnelAdapter {
    param([string]$Text)
    return ($Text -match '(?i)tap|tun\b|wintun|wireguard|zerotier|openvpn|tailscale|xray|happ|sing-?box|clash|mihomo|v2ray|hiddify|nekoray|outline|amnezia|vpn')
}

# Local IP to bind to when target sits in a directly connected subnet (bypasses tunnel interception)
function Find-BindIp {
    param([string]$Ip, $LocalNets)
    foreach ($N in $LocalNets) {
        if ($N.Tunnel) { continue }
        if ($N.Prefix -ge 8 -and (Test-IpInNet $Ip $N.Net $N.Prefix)) { return $N.Ip }
    }
    return $null
}

# ---------------------------------------------------------------- Wi-Fi (netsh wlan)

function Get-WlanInfo {
    # Raw bytes from netsh: UTF-8 when the host has no console, OEM (cp866) otherwise; labels follow the UI language.
    try {
        $Psi = New-Object System.Diagnostics.ProcessStartInfo "netsh.exe"
        $Psi.Arguments = "wlan show interfaces"
        $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true; $Psi.RedirectStandardOutput = $true
        $P = [System.Diagnostics.Process]::Start($Psi)
        $Ms = New-Object System.IO.MemoryStream
        $P.StandardOutput.BaseStream.CopyTo($Ms)
        $P.WaitForExit(5000) | Out-Null
        $Bytes = $Ms.ToArray()
        $Text = [System.Text.Encoding]::UTF8.GetString($Bytes)
        if ($Text.Contains([char]0xFFFD)) {
            try { $Text = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage).GetString($Bytes) } catch { }
        }
        $Lines = $Text -split "`r?`n"
    } catch { return $null }
    if (-not $Lines) { return $null }
    $W = @{}
    foreach ($L in $Lines) {
        if ($L -notmatch '^\s*([^:]+?)\s*:\s*(.*)$') { continue }
        $K = $Matches[1].Trim(); $V = $Matches[2].Trim()
        switch -Regex ($K) {
            '^(Description|Описание)'                     { $W.Adapter = $V }
            '^(State|Состояние)'                          { $W.State = $V }
            '^SSID\b'                                      { $W.Ssid = $V }
            'BSSID'                                        { $W.Bssid = $V }
            '^(Band|Диапазон)'                            { $W.Band = $V }
            '^(Channel|Канал)'                            { $W.Channel = $V }
            '^(Radio type|Тип радио)'                     { $W.Radio = $V }
            '^(Authentication|Проверка подлинности)'      { $W.Auth = $V }
            '^(Receive rate|Скорость приема|Скорость приёма)' { $W.Rx = $V }
            '^(Transmit rate|Скорость передачи)'          { $W.Tx = $V }
            '^(Signal|Сигнал)'                            { $W.Signal = [int]($V -replace '[^\d]', '') }
            '^Rssi'                                        { $W.Rssi = $V }
        }
    }
    if (-not $W.Adapter) { return $null }
    if ($W.State -notmatch 'connected|подключ') { return @{ Adapter = $W.Adapter; State = $W.State; Connected = $false } }
    $W.Connected = $true
    return $W
}

function Invoke-NetshBytes {
    param([string]$NetshArgs)
    try {
        $Psi = New-Object System.Diagnostics.ProcessStartInfo "netsh.exe"
        $Psi.Arguments = $NetshArgs
        $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true; $Psi.RedirectStandardOutput = $true
        $P = [System.Diagnostics.Process]::Start($Psi)
        $Ms = New-Object System.IO.MemoryStream
        $P.StandardOutput.BaseStream.CopyTo($Ms)
        $P.WaitForExit(8000) | Out-Null
        $Bytes = $Ms.ToArray()
        $Text = [System.Text.Encoding]::UTF8.GetString($Bytes)
        if ($Text.Contains([char]0xFFFD)) {
            try { $Text = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage).GetString($Bytes) } catch { }
        }
        return ($Text -split "`r?`n")
    } catch { return @() }
}

# Nearby access points: netsh wlan show networks mode=bssid → one row per BSSID, sorted by signal.
function Get-WlanNetworks {
    $Lines = Invoke-NetshBytes "wlan show networks mode=bssid"
    $Nets = [System.Collections.Generic.List[object]]::new()
    $Cur = $null; $Ap = $null
    foreach ($L in $Lines) {
        if ($L -notmatch '^\s*([^:]+?)\s*:\s*(.*)$') { continue }
        $K = $Matches[1].Trim(); $V = $Matches[2].Trim()
        switch -Regex ($K) {
            '^SSID\s+\d+$' { $Cur = @{ Ssid = $(if ($V) { $V } else { "(скрытая сеть)" }); Auth = ""; Enc = "" }; $Ap = $null }
            '^(Authentication|Проверка подлинности)' { if ($Cur) { $Cur.Auth = $V } }
            '^(Encryption|Шифрование)'               { if ($Cur) { $Cur.Enc = $V } }
            '^BSSID\s+\d+$' {
                if (-not $Cur) { continue }
                $Ap = @{ Ssid = $Cur.Ssid; Auth = $Cur.Auth; Enc = $Cur.Enc; Bssid = $V.ToUpper(); Vendor = (Get-MacVendor $V); Signal = 0; Radio = ""; Band = ""; Channel = "" }
                $Nets.Add($Ap)
            }
            '^(Signal|Сигнал)'        { if ($Ap) { $Ap.Signal = [int]($V -replace '[^\d]', '') } }
            '^(Radio type|Тип радио)' { if ($Ap) { $Ap.Radio = $V } }
            '^(Band|Диапазон)'        { if ($Ap) { $Ap.Band = $V } }
            '^(Channel|Канал)'        { if ($Ap) { $Ap.Channel = $V } }
        }
    }
    return @($Nets | Sort-Object -Property @{ Expression = { $_.Signal }; Descending = $true })
}
# ---------------------------------------------------------------- probes

# Targets: objects with Ip, Port. Returns the subset that connected.
function Test-TcpBatch {
    param([object[]]$Targets, [int]$TimeoutMs = 700, $LocalNets = @())

    $Items = foreach ($T in $Targets) {
        $C = New-Object System.Net.Sockets.TcpClient ([System.Net.Sockets.AddressFamily]::InterNetwork)
        $Task = $null
        try {
            $Bind = Find-BindIp $T.Ip $LocalNets
            if ($Bind) { $C.Client.Bind((New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($Bind)), 0)) }
            $Task = $C.ConnectAsync($T.Ip, [int]$T.Port)
        } catch { }
        [pscustomobject]@{ T = $T; C = $C; Task = $Task }
    }

    $Tasks = [System.Threading.Tasks.Task[]]@($Items | Where-Object { $_.Task } | ForEach-Object { $_.Task })
    if ($Tasks.Count -gt 0) {
        try { [void][System.Threading.Tasks.Task]::WhenAll($Tasks).Wait($TimeoutMs) } catch { }
    }

    $Open = foreach ($I in $Items) {
        if ($I.Task -and $I.Task.Status -eq "RanToCompletion" -and $I.C.Connected) { $I.T }
        try { $I.C.Close() } catch { }
    }
    return @($Open)
}

function Invoke-PingBatch {
    param([string[]]$Ips, [int]$TimeoutMs = 800)

    $Items = foreach ($Ip in $Ips) {
        $P = New-Object System.Net.NetworkInformation.Ping
        [pscustomobject]@{ Ip = $Ip; P = $P; Task = $P.SendPingAsync($Ip, $TimeoutMs) }
    }
    try { [void][System.Threading.Tasks.Task]::WhenAll([System.Threading.Tasks.Task[]]@($Items.Task)).Wait($TimeoutMs + 600) } catch { }

    $Out = @{}
    foreach ($I in $Items) {
        if ($I.Task.Status -eq "RanToCompletion" -and $I.Task.Result.Status -eq "Success") {
            $Out[$I.Ip] = [int]$I.Task.Result.RoundtripTime
        }
        $I.P.Dispose()
    }
    return $Out
}

function Get-PortBanner {
    param([string]$Ip, [int]$Port, [string]$HostName = "", $LocalNets = @(), [int]$TimeoutMs = 1200)

    $Name = if ($HostName) { $HostName } else { $Ip }
    $C = New-Object System.Net.Sockets.TcpClient ([System.Net.Sockets.AddressFamily]::InterNetwork)
    try {
        $Bind = Find-BindIp $Ip $LocalNets
        if ($Bind) { $C.Client.Bind((New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($Bind)), 0)) }
        if (-not $C.ConnectAsync($Ip, $Port).Wait($TimeoutMs)) { return "" }
        $C.ReceiveTimeout = $TimeoutMs; $C.SendTimeout = $TimeoutMs
        $Stream = $C.GetStream()

        $IsTls = $script:WebTlsPorts -contains $Port -or $Port -in @(465, 636, 853, 993, 995, 8729, 8883)
        $IsHttp = $script:WebPlainPorts -contains $Port -or $script:WebTlsPorts -contains $Port
        $Cert = ""

        if ($IsTls) {
            $Ssl = New-Object System.Net.Security.SslStream($Stream, $false, ({ $true } -as [System.Net.Security.RemoteCertificateValidationCallback]))
            $Ssl.ReadTimeout = $TimeoutMs
            $Ssl.AuthenticateAsClient($Name)
            $X = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $Ssl.RemoteCertificate
            $Cn = ($X.Subject -replace '^.*?CN=([^,]+).*$', '$1')
            $Cert = "TLS $Cn до $($X.NotAfter.ToString('yyyy-MM-dd'))"
            $Stream = $Ssl
        }

        if ($IsHttp) {
            $Req = [Text.Encoding]::ASCII.GetBytes("HEAD / HTTP/1.0`r`nHost: $Name`r`nUser-Agent: NetKnife`r`n`r`n")
            $Stream.Write($Req, 0, $Req.Length)
        }

        $Buf = New-Object byte[] 2048
        $Read = 0
        try { $Read = $Stream.Read($Buf, 0, $Buf.Length) } catch { }
        $Text = if ($Read -gt 0) { [Text.Encoding]::ASCII.GetString($Buf, 0, $Read) } else { "" }

        $Info = ""
        if ($Text -match '^HTTP/[\d.]+ (\d{3}[^\r\n]*)') {
            $Info = "HTTP $($Matches[1])"
            if ($Text -match '(?im)^Server:\s*([^\r\n]+)') { $Info += " · $($Matches[1])" }
            if ($Text -match '(?im)^Location:\s*([^\r\n]+)') { $Info += " → $($Matches[1])" }
        } elseif ($Text) {
            $Info = ($Text -split "`n")[0].Trim() -replace '[^\x20-\x7E]', ''
            if ($Info.Length -gt 90) { $Info = $Info.Substring(0, 90) + "…" }
        } elseif (-not $Cert) {
            $Info = "открыт, без баннера"
        }

        return (@($Cert, $Info) | Where-Object { $_ }) -join " · "
    } catch {
        return "открыт · $($_.Exception.InnerException.Message ?? $_.Exception.Message)" -replace '\s+', ' '
    } finally {
        try { $C.Close() } catch { }
    }
}

# ---------------------------------------------------------------- MAC vendors (small offline list)

$script:OuiMap = @{
    "000C29" = "VMware"; "005056" = "VMware"; "000569" = "VMware"; "00155D" = "Hyper-V"; "525400" = "QEMU/KVM"; "BC2411" = "Proxmox VM"
    "080027" = "VirtualBox"; "001C42" = "Parallels"; "00163E" = "Xen"
    "4C5E0C" = "MikroTik"; "6C3B6B" = "MikroTik"; "B869F4" = "MikroTik"; "CC2DE0" = "MikroTik"; "D4CA6D" = "MikroTik"; "E48D8C" = "MikroTik"
    "2CC81B" = "MikroTik"; "48A98A" = "MikroTik"; "64D154" = "MikroTik"; "744D28" = "MikroTik"; "08559D" = "MikroTik"; "18FD74" = "MikroTik"
    "DC2C6E" = "MikroTik"; "C4AD34" = "MikroTik"
    "245A4C" = "Ubiquiti"; "24A43C" = "Ubiquiti"; "44D9E7" = "Ubiquiti"; "687251" = "Ubiquiti"; "788A20" = "Ubiquiti"; "802AA8" = "Ubiquiti"
    "B4FBE4" = "Ubiquiti"; "DC9FDB" = "Ubiquiti"; "E063DA" = "Ubiquiti"; "F09FC2" = "Ubiquiti"; "FCECDA" = "Ubiquiti"; "74ACB9" = "Ubiquiti"; "18E829" = "Ubiquiti"
    "B827EB" = "Raspberry Pi"; "DCA632" = "Raspberry Pi"; "E45F01" = "Raspberry Pi"; "2CCF67" = "Raspberry Pi"; "D83ADD" = "Raspberry Pi"
    "240AC4" = "Espressif"; "246F28" = "Espressif"; "30AEA4" = "Espressif"; "3C71BF" = "Espressif"; "807D3A" = "Espressif"; "84CCA8" = "Espressif"
    "A4CF12" = "Espressif"; "BCDDC2" = "Espressif"; "C44F33" = "Espressif"; "CC50E3" = "Espressif"; "DC4F22" = "Espressif"; "ECFABC" = "Espressif"
    "001132" = "Synology"; "9009D0" = "Synology"; "001788" = "Philips Hue"; "ECB5FA" = "Philips Hue"; "000E58" = "Sonos"; "5CAAFD" = "Sonos"
    "00000C" = "Cisco"
}
function Get-MacVendor {
    param([string]$Mac)
    if (-not $Mac) { return "" }
    $Hex = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($Hex.Length -lt 6) { return "" }
    $Prefix = $Hex.Substring(0, 6)
    if ($script:OuiMap.ContainsKey($Prefix)) { return $script:OuiMap[$Prefix] }
    $Second = [Convert]::ToInt32($Hex.Substring(1, 1), 16)
    if ($Second -band 2) { return "случайный MAC (приватный)" }
    return ""
}

# ---------------------------------------------------------------- badges

function New-PortBadges {
    param([string]$Ip, [int[]]$Ports, [string]$SshAlias = "", [string]$HostName = "")

    $Name = if ($HostName) { $HostName } else { $Ip }
    $Badges = @()
    foreach ($P in ($Ports | Sort-Object)) {
        $Svc = Get-ServiceName $P
        if ($P -eq 22 -or $Svc -eq "ssh-alt") {
            $Tag = if ($SshAlias) { "ssh:$SshAlias" } else { "sship:$Ip`:$P" }
            $Badges += [pscustomobject]@{ Text = "SSH"; Kind = "ssh"; Tag = $Tag; Tip = "ssh $(if ($SshAlias) { $SshAlias } else { "root@$Ip" })" }
        } elseif ($script:WebTlsPorts -contains $P) {
            $Url = if ($P -eq 443) { "https://$Name" } else { "https://$Name`:$P" }
            $Label = if ($P -eq 443) { "HTTPS" } elseif ($P -eq 8006) { "Proxmox" } else { "HTTPS :$P" }
            $Badges += [pscustomobject]@{ Text = $Label; Kind = "web"; Tag = "url:$Url"; Tip = $Url }
        } elseif ($script:WebPlainPorts -contains $P) {
            $Url = if ($P -eq 80) { "http://$Name" } else { "http://$Name`:$P" }
            $Label = if ($P -eq 80) { "HTTP" } elseif ($P -eq 8123) { "Home Assistant" } elseif ($P -eq 5678) { "n8n" } else { "HTTP :$P" }
            $Badges += [pscustomobject]@{ Text = $Label; Kind = "web"; Tag = "url:$Url"; Tip = $Url }
        } elseif ($P -eq 3389) {
            $Badges += [pscustomobject]@{ Text = "RDP"; Kind = ""; Tag = "rdp:$Ip"; Tip = "mstsc /v:$Ip" }
        } elseif ($P -eq 445) {
            $Badges += [pscustomobject]@{ Text = "SMB"; Kind = ""; Tag = "smb:$Ip"; Tip = "\\$Ip" }
        } elseif ($P -eq 8291) {
            $Badges += [pscustomobject]@{ Text = "Winbox"; Kind = ""; Tag = "copy:$Ip"; Tip = "MikroTik Winbox — копировать IP" }
        } else {
            $Label = if ($Svc) { "$Svc" } else { ":$P" }
            $Badges += [pscustomobject]@{ Text = $Label; Kind = ""; Tag = "ports:$Ip"; Tip = "порт $P — подробнее" }
        }
    }
    return $Badges
}
