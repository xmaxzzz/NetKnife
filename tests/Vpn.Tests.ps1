# Pester 5: pages\Vpn.ps1 without WPF — share-link parsing (vless/hy2/mieru/naive), mihomo YAML for mieru,
# engine choice and minimum versions, pinned engine downloads with SHA256 check.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:DataDir = Join-Path ([IO.Path]::GetTempPath()) ("nk-vpn-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $DataDir | Out-Null
    function Write-AppLog { param([string]$Text) }
    . (Join-Path $Root "pages\Vpn.ps1")

    $script:MieruDoc = "mierus://baozi:manlianpenfen@1.2.3.4?handshake-mode=HANDSHAKE_NO_WAIT&mtu=1400&multiplexing=MULTIPLEXING_HIGH&port=6666&port=9998-9999&port=6489&port=4896&profile=default&protocol=TCP&protocol=TCP&protocol=UDP&protocol=UDP"
}

AfterAll { Remove-Item $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue }

Describe "старые ссылки разбираются как раньше" {
    It "vless" {
        $P = ConvertFrom-ProxyLink "vless://11111111-2222-3333-4444-555555555555@ex.com:443?security=reality&pbk=K&sni=a.com&type=tcp#Мой"
        $P.Type | Should -Be "vless"; $P.Auth | Should -Be "11111111-2222-3333-4444-555555555555"
        $P.Server | Should -Be "ex.com"; $P.Port | Should -Be 443; $P.Name | Should -Be "Мой"; $P.Query.pbk | Should -Be "K"
    }
    It "hy2 → hysteria2, IPv6 в скобках" {
        $P = ConvertFrom-ProxyLink "hy2://pw@[2001:db8::1]:8443?sni=x"
        $P.Type | Should -Be "hysteria2"; $P.Server | Should -Be "2001:db8::1"; $P.Port | Should -Be 8443; $P.Auth | Should -Be "pw"
    }
    It "vless без порта и без UUID — нет" {
        ConvertFrom-ProxyLink "vless://uuid@ex.com" | Should -BeNullOrEmpty
        Get-ProxyLinkError "vless://uuid@ex.com" | Should -Match "нет порта"
        Get-ProxyLinkError "vless://@ex.com:443" | Should -Be "пустой UUID"
    }
    It "чужая схема" {
        ConvertFrom-ProxyLink "ss://abc@h:1" | Should -BeNullOrEmpty
        Get-ProxyLinkError "trojan://x@h:1" | Should -Match "^не ссылка"
    }
}

Describe "mierus://" {
    It "пример из документации mieru: первая TCP-пара, логин и пароль раздельно" {
        $P = ConvertFrom-ProxyLink $MieruDoc
        $P.Type | Should -Be "mieru"
        $P.User | Should -Be "baozi"; $P.Password | Should -Be "manlianpenfen"
        $P.Server | Should -Be "1.2.3.4"; $P.Port | Should -Be 6666; $P.PortRange | Should -Be ""; $P.Transport | Should -Be "TCP"
        $P.Name | Should -Be "1.2.3.4"
        Get-ProxyLinkError $MieruDoc | Should -Be ""
    }
    It "диапазон портов, имя из #, экранированный пароль с : и @" {
        $P = ConvertFrom-ProxyLink "mierus://u%3Ax:p%40ss%3Aw@srv.example?port=2090-2099&protocol=tcp#%D0%94%D0%BE%D0%BC"
        $P.User | Should -Be "u:x"; $P.Password | Should -Be "p@ss:w"
        $P.PortRange | Should -Be "2090-2099"; $P.Port | Should -Be 2090; $P.Transport | Should -Be "TCP"; $P.Name | Should -Be "Дом"
    }
    It "только UDP-привязки — берётся первая UDP" {
        $P = ConvertFrom-ProxyLink "mierus://u:p@h?port=7000&protocol=UDP&port=7001&protocol=UDP"
        $P.Transport | Should -Be "UDP"; $P.Port | Should -Be 7000
    }
    It "без protocol — TCP" {
        (ConvertFrom-ProxyLink "mierus://u:p@h?port=7000").Transport | Should -Be "TCP"
    }
    It "<Why>" -ForEach @(
        @{ L = "mierus://u:p@h?protocol=TCP"; Why = "нет параметра port" }
        @{ L = "mierus://u:p@h?port=1&port=2&protocol=TCP"; Why = "поровну" }
        @{ L = "mierus://u:p@h?port=1&protocol=QUIC"; Why = "ожидаю TCP или UDP" }
        @{ L = "mierus://u:p@h?port=abc&protocol=TCP"; Why = "ожидаю число или диапазон" }
        @{ L = "mierus://u:p@h?port=70000&protocol=TCP"; Why = "вне 1–65535" }
        @{ L = "mierus://u:p@h?port=3000-2000&protocol=TCP"; Why = "вне 1–65535" }
        @{ L = "mierus://u@h?port=1"; Why = "нет пароля" }
        @{ L = "mierus://:p@h?port=1"; Why = "пустое имя пользователя" }
        @{ L = "mierus://u:@h?port=1"; Why = "пустой пароль" }
        @{ L = "mierus://h?port=1"; Why = "логин@сервер" }
    ) {
        ConvertFrom-ProxyLink $L | Should -BeNullOrEmpty
        Get-ProxyLinkError $L | Should -Match ([regex]::Escape($Why))
    }
    It "ошибки разбора не содержат пароль" {
        Get-ProxyLinkError "mierus://user:S3cretPw@h?port=bad" | Should -Not -Match "S3cretPw"
    }
}

Describe "naive+https:// и naive+quic://" {
    It "https с портом и именем" {
        $P = ConvertFrom-ProxyLink "naive+https://alice:pa%3Ass@np.example.com:8443#Naive%20RU"
        $P.Type | Should -Be "naive"; $P.Proto | Should -Be "https"
        $P.User | Should -Be "alice"; $P.Password | Should -Be "pa:ss"
        $P.Server | Should -Be "np.example.com"; $P.Port | Should -Be 8443; $P.Name | Should -Be "Naive RU"
    }
    It "quic без порта — 443" {
        $P = ConvertFrom-ProxyLink "naive+quic://bob:pw@np.example.com"
        $P.Proto | Should -Be "quic"; $P.Port | Should -Be 443
    }
    It "<Why>" -ForEach @(
        @{ L = "naive+https://alice@np.example.com"; Why = "нет пароля" }
        @{ L = "naive+https://alice:pw@np.example.com:0"; Why = "вне 1–65535" }
        @{ L = "naive+http://alice:pw@np.example.com"; Why = "не ссылка" }
        @{ L = "naive://alice:pw@np.example.com"; Why = "не ссылка" }
    ) {
        ConvertFrom-ProxyLink $L | Should -BeNullOrEmpty
        Get-ProxyLinkError $L | Should -Match ([regex]::Escape($Why))
    }
    It "движка нет, mihomo-конфиг не строится" {
        $P = ConvertFrom-ProxyLink "naive+https://a:b@h"
        Get-VpnEngineFor $P.Type | Should -BeNullOrEmpty
        { New-MihomoConfig $P 2080 } | Should -Throw "*не умеет*"
    }
}

Describe "Get-VpnEngineFor" {
    It "<T> → <E>" -ForEach @(
        @{ T = "vless"; E = "xray" }, @{ T = "hysteria2"; E = "mihomo" }, @{ T = "mieru"; E = "mihomo" }
    ) { Get-VpnEngineFor $T | Should -Be $E }
    It "naive и неизвестное — нет движка" {
        Get-VpnEngineFor "naive" | Should -BeNullOrEmpty
        Get-VpnEngineFor "trojan" | Should -BeNullOrEmpty
    }
}

Describe "mihomo YAML для mieru" {
    It "снапшот: пример из документации" {
        $Y = New-MihomoConfig (ConvertFrom-ProxyLink $MieruDoc) 2080
        $Proxies = $Y.Substring($Y.IndexOf("proxies:")).TrimEnd()
        $Proxies | Should -Be (@(
            "proxies:"
            "  - name: proxy"
            "    type: mieru"
            "    server: '1.2.3.4'"
            "    udp: true"
            "    port: 6666"
            "    transport: TCP"
            "    username: 'baozi'"
            "    password: 'manlianpenfen'"
            "    multiplexing: MULTIPLEXING_HIGH"
            "    handshake-mode: HANDSHAKE_NO_WAIT"
            "rules:"
            "  - MATCH,proxy"
        ) -join "`n")
        $Y | Should -Match "(?m)^mixed-port: 2080$"
        $Y | Should -Not -Match "mtu|profile"
    }
    It "диапазон портов → port-range без port; кавычки в пароле экранируются" {
        $Y = New-MihomoConfig (ConvertFrom-ProxyLink "mierus://u:it%27s@h?port=2090-2099&protocol=UDP&traffic-pattern=CAEQAQ%3D%3D") 2080
        $Y | Should -Match "(?m)^    port-range: '2090-2099'$"
        $Y | Should -Not -Match "(?m)^    port: "
        $Y | Should -Match "(?m)^    transport: UDP$"
        $Y | Should -Match "(?m)^    password: 'it''s'$"
        $Y | Should -Match "(?m)^    traffic-pattern: 'CAEQAQ=='$"
    }
    It "неизвестный multiplexing / handshake-mode — понятная ошибка без пароля" {
        { New-MihomoConfig (ConvertFrom-ProxyLink "mierus://u:Secret1@h?port=1&multiplexing=TURBO") 2080 } | Should -Throw "multiplexing «TURBO» не знаю*"
        { New-MihomoConfig (ConvertFrom-ProxyLink "mierus://u:Secret1@h?port=1&handshake-mode=FAST") 2080 } | Should -Throw "handshake-mode «FAST» не знаю*"
        try { New-MihomoConfig (ConvertFrom-ProxyLink "mierus://u:Secret1@h?port=1&multiplexing=TURBO") 2080 } catch { "$_" | Should -Not -Match "Secret1" }
    }
    It "hysteria2 по-прежнему с port и password" {
        $Y = New-MihomoConfig (ConvertFrom-ProxyLink "hysteria2://pw@h:443?sni=s") 2080
        $Y | Should -Match "(?m)^    type: hysteria2$"; $Y | Should -Match "(?m)^    port: 443$"; $Y | Should -Match "(?m)^    password: 'pw'$"
    }
}

Describe "минимальная версия mihomo для mieru" {
    It "<L> → <Min>" -ForEach @(
        @{ L = "mierus://u:p@h?port=1&protocol=TCP"; Min = "1.19.0" }
        @{ L = "mierus://u:p@h?port=1&multiplexing=MULTIPLEXING_LOW"; Min = "1.19.1" }
        @{ L = "mierus://u:p@h?port=1&handshake-mode=HANDSHAKE_NO_WAIT"; Min = "1.19.13" }
        @{ L = "mierus://u:p@h?port=1&protocol=UDP&multiplexing=MULTIPLEXING_LOW"; Min = "1.19.17" }
        @{ L = "mierus://u:p@h?port=1&traffic-pattern=x&protocol=UDP"; Min = "1.19.21" }
    ) { Get-VpnMinVersion (ConvertFrom-ProxyLink $L) | Should -Be $Min }
    It "для vless/hy2 ограничения нет" {
        Get-VpnMinVersion (ConvertFrom-ProxyLink "hy2://p@h:1") | Should -Be ""
    }
    It "старый mihomo — сообщение с нужной версией; новый, неизвестный и «?» — пропуск" {
        $P = ConvertFrom-ProxyLink "mierus://u:p@h?port=1&protocol=UDP"
        Test-VpnEngineVersion $P "1.18.10" | Should -Match "mihomo 1\.18\.10 слишком старый для mieru \(нужен 1\.19\.17 или новее\).*v1\.19\.33"
        Test-VpnEngineVersion $P "1.19.16" | Should -Match "нужен 1\.19\.17"
        Test-VpnEngineVersion $P "1.19.17" | Should -Be ""
        Test-VpnEngineVersion $P "1.19.33" | Should -Be ""
        Test-VpnEngineVersion $P "?" | Should -Be ""
        Test-VpnEngineVersion $P "" | Should -Be ""
    }
    It "закреплённый mihomo сам проходит все проверки" {
        $Tag = $script:VpnEngines.mihomo.Tag.TrimStart('v')
        Test-VpnEngineVersion (ConvertFrom-ProxyLink "mierus://u:p@h?port=1&protocol=UDP&traffic-pattern=x&handshake-mode=HANDSHAKE_NO_WAIT") $Tag | Should -Be ""
    }
}

Describe "закреплённые движки" {
    It "<_>: тег, ассеты amd64/arm64 с размером и SHA256, ссылка на тег, не latest" -ForEach @("xray", "mihomo") {
        $E = $script:VpnEngines[$_]
        $E.Tag | Should -Match '^v\d+\.\d+\.\d+$'
        foreach ($Arch in "AMD64", "ARM64") {
            $A = Get-VpnEngineAsset $_ $Arch
            $A.Sha256 | Should -Match '^[0-9a-f]{64}$'
            $A.Size | Should -BeGreaterThan 1MB
            $A.Url | Should -Be "https://github.com/$($E.Repo)/releases/download/$($E.Tag)/$($A.Name)"
            $A.Url | Should -Not -Match "latest"
        }
        (Get-VpnEngineAsset $_ "ARM64").Name | Should -Match "arm64"
        (Get-VpnEngineAsset $_ "AMD64").Name | Should -Not -Match "arm64"
    }
    It "в имени ассета mihomo — тот же тег" {
        $E = $script:VpnEngines.mihomo
        $E.Asset.Name | Should -Match ([regex]::Escape($E.Tag))
        $E.AssetArm.Name | Should -Match ([regex]::Escape($E.Tag))
    }
    It "в Vpn.ps1 нет releases/latest" {
        [IO.File]::ReadAllText((Join-Path $Root "pages\Vpn.ps1")) | Should -Not -Match "releases/latest" -Because "скачивание только по закреплённому тегу"
    }
}

Describe "скачивание движка: SHA256" {
    BeforeAll {
        # a real zip with a fake engine exe inside; the "download" copies it
        $script:Src = Join-Path $DataDir "src"
        New-Item -ItemType Directory -Path (Join-Path $Src "in") -Force | Out-Null
        Set-Content (Join-Path $Src "in\mihomo-windows-amd64.exe") "fake engine" -NoNewline
        $script:FakeZip = Join-Path $Src "fake.zip"
        Compress-Archive (Join-Path $Src "in\*") $FakeZip -Force
        $script:FakeSha = (Get-FileHash $FakeZip -Algorithm SHA256).Hash.ToLower()
        Mock Invoke-WebRequest { Copy-Item $script:FakeZip $OutFile -Force }
        function Invoke-Dl { param([string]$Dir, [string]$Sha)
            $Q = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
            & $script:VpnDownloadBody $Q @{ Stop = $false } "https://example.invalid/x.zip" $Dir "mihomo*.exe" "mihomo.exe" $Sha
            $M = $null; [void]$Q.TryDequeue([ref]$M); return $M
        }
    }
    It "хэш совпал — exe на месте, zip и распаковка убраны" {
        $Dir = Join-Path $DataDir "ok"
        $M = Invoke-Dl $Dir $FakeSha.ToUpper()
        $M.Ok | Should -BeTrue; $M.Error | Should -BeNullOrEmpty
        Get-Content (Join-Path $Dir "mihomo.exe") -Raw | Should -Be "fake engine"
        Test-Path (Join-Path $Dir "download.zip") | Should -BeFalse
        Test-Path (Join-Path $Dir "unpack") | Should -BeFalse
    }
    It "хэш не совпал — файл удалён, exe не появился, ошибка по-русски" {
        $Dir = Join-Path $DataDir "bad"
        $M = Invoke-Dl $Dir ("0" * 64)
        $M.Ok | Should -BeNullOrEmpty
        $M.Error | Should -Match "контрольная сумма не совпала.*файл удалён"
        Test-Path (Join-Path $Dir "download.zip") | Should -BeFalse
        Test-Path (Join-Path $Dir "mihomo.exe") | Should -BeFalse
    }
}
