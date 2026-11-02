# Pester 5: lib\Helpdesk.ps1 — registry → hosts (validation), answers 200/304/401/offline → cache, ssh config files,
# MikroTik routers from Helpdesk. Everything in a temp dir; the token store (Windows Credential Manager) is mocked.
#   Run:  Invoke-Pester -Path tests

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:AppDir = $Root
    $script:Settings = @{}
    function Write-AppLog { param($T) $script:Log += "$T`n" }
    function Show-Toast { param($T, $K) }
    . (Join-Path $Root "lib\Ssh.ps1")
    . (Join-Path $Root "lib\MikroTik.ps1")
    . (Join-Path $Root "lib\Helpdesk.ps1")
    function Get-HdToken { return $script:TestToken }

    $script:K1 = "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7testkeytesttesttest"
    function Reset-Env {
        $D = Join-Path ([IO.Path]::GetTempPath()) ("nk-hd-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $D "ssh") | Out-Null
        $script:SshDir = Join-Path $D "ssh"; $script:ConfigPath = Join-Path $D "ssh/config"
        $script:HdCachePath = Join-Path $D "cache/helpdesk-hosts.json"; $script:MtKey = Join-Path $D "ssh/netknife_mt"
        $script:HdHosts = $null; $script:Log = ""; $script:Settings = @{}; $script:TestToken = "hdn_secret_token"
        [IO.File]::WriteAllText($script:ConfigPath, "Host myserver`n    HostName 10.0.0.5`n`nHost ap-router`n    HostName 1.2.3.4`n")
        return $D
    }
    function New-Registry {
        return @{
            sites = @(@{ slug = "alye-parusa"; name = "Алые паруса" }, @{ slug = "gorki"; name = "Горки`nProxyCommand x" })
            hosts = @(
                @{ site = "alye-parusa"; alias = "ap-router"; kind = "mikrotik"; host = "192.168.115.1"; port = 10322; users = @(@{ role = "ro"; name = "butler-service" }, @{ role = "rw"; name = "butler-rw" }); route = "direct"; known_hosts = @("ap-router,[192.168.115.1]:10322 ssh-rsa $K1", "@cert-authority * ssh-rsa $K1"); status = "ok" }
                @{ site = "gorki"; alias = "lm"; kind = "lm"; host = "10.10.5.2"; port = 22; users = @(@{ role = "ro"; name = "admin" }); route = "agent"; known_hosts = @("lm,10.10.5.2 ssh-ed25519 $K1"); status = "ok" }
                @{ site = "gorki"; alias = "lm"; kind = "linux"; host = "10.10.5.3"; users = @(@{ role = "other"; name = "backup" }) }
                @{ site = "gorki"; alias = "evil`n    ProxyCommand x"; host = "1.1.1.1" }
                @{ site = "gorki"; alias = "evil2"; host = "1.1.1.1 -oProxyCommand=x" }
                @{ site = "gorki"; alias = "evil3"; host = "1.1.1.1"; port = 99999 }
                @{ site = "gorki"; alias = "evil4"; host = "1.1.1.1"; users = @(@{ role = "ro"; name = "a b" }) }
                @{ id = 99; site = "gorki"; alias = "gone"; deleted = $true }
            )
        }
    }
    function New-Answer { param([int]$Code, $Data = $null, [string]$ETag = '"v1"') return @{ Type = "hd"; Code = $Code; ETag = $ETag; Body = $(if ($Data) { $Data | ConvertTo-Json -Depth 8 } else { "" }) } }
}

Describe "реестр → хосты" {
    BeforeEach { $script:D = Reset-Env }
    It "отбрасывает хосты с недопустимыми полями (инъекции в ssh config)" {
        $H = @(ConvertTo-HdHosts (New-Registry) @())
        $H.Count | Should -Be 3
        ($H | ForEach-Object Alias) -join "," | Should -Not -Match "evil"
    }
    It "алиас, занятый ручным хостом или повторённый, получает .<объект>" {
        $H = @(ConvertTo-HdHosts (New-Registry) @("myserver", "ap-router"))
        $H[0].Alias | Should -Be "ap-router.alye-parusa"
        $H[1].Alias | Should -Be "lm.gorki"
        $H[2].Alias | Should -Be "lm.gorki-2"
    }
    It "ключ хоста привязан к своим alias,[host]:port; @cert-authority и чужой хост не принимаются" {
        $R = New-Registry; $R.hosts[0].known_hosts += "* ssh-rsa $K1"
        $H = @(ConvertTo-HdHosts $R @())
        @($H[0].KnownHosts) | Should -Be @("ap-router,[192.168.115.1]:10322 ssh-rsa $K1")
        @($H[1].KnownHosts) | Should -Be @("lm,10.10.5.2 ssh-ed25519 $K1")
        @($H[2].KnownHosts).Count | Should -Be 0
    }
    It "в имени объекта нет управляющих символов" {
        $H = @(ConvertTo-HdHosts (New-Registry) @())
        $H[1].SiteName | Should -Not -Match "[\r\n]"
    }
    It "users[] по ролям: ro/rw берутся, other — нет; без ключа или ro — не в ssh config" {
        $H = @(ConvertTo-HdHosts (New-Registry) @())
        $H[0].User | Should -Be "butler-service"; $H[0].RwUser | Should -Be "butler-rw"; $H[0].Skip | Should -BeNullOrEmpty
        $H[1].Skip | Should -BeNullOrEmpty
        $H[2].User | Should -BeNullOrEmpty; $H[2].Skip | Should -Match "ключа"
        $R = New-Registry; $R.hosts[1].users = @(@{ role = "other"; name = "x" })
        (@(ConvertTo-HdHosts $R @()))[1].Skip | Should -Match "ro-пользователя"
    }
    It "tombstone (deleted) не попадает в список" {
        @(ConvertTo-HdHosts (New-Registry) @() | Where-Object { $_.RawAlias -eq "gone" }).Count | Should -Be 0
    }
}

Describe "ответы сервера → кэш" {
    BeforeEach { $script:D = Reset-Env }
    It "200 сохраняет данные и ETag, токена в кэше нет" {
        $R = Receive-HdSync (New-Answer 200 (New-Registry)) "https://hd.test"
        $R.Kind | Should -Be "ok"
        (Read-HdCache).ETag | Should -Be '"v1"'
        [IO.File]::ReadAllText($script:HdCachePath) | Should -Not -Match "hdn_secret_token"
    }
    It "слабый ETag сохраняется как есть" {
        [void](Receive-HdSync (New-Answer 200 (New-Registry) 'W/"412.5f2a9c01b7e4.ro"') "https://hd.test")
        (Read-HdCache).ETag | Should -Be 'W/"412.5f2a9c01b7e4.ro"'
    }
    It "коды ошибок контракта — понятный текст" {
        $Cases = @{ token_expired = "истёк"; token_revoked = "отозван"; token_scope = "не для NetKnife"; forbidden = "access.hosts.view" }
        foreach ($K in $Cases.Keys) {
            $Code = $(if ($K -in @("token_expired", "token_revoked")) { 401 } else { 403 })
            (Receive-HdSync @{ Type = "hd"; Code = $Code; Body = (@{ code = $K; detail = "x" } | ConvertTo-Json) } "https://hd.test").Text | Should -Match $Cases[$K]
        }
        (Receive-HdSync @{ Type = "hd"; Code = 429; RetryAfter = "30"; Body = '{"code":"rate_limited"}' } "https://hd.test").Text | Should -Match "30 с"
    }
    It "304 — без изменений, данные остаются" {
        [void](Receive-HdSync (New-Answer 200 (New-Registry)) "https://hd.test")
        $R = Receive-HdSync (New-Answer 304) "https://hd.test"
        $R.Kind | Should -Be "same"
        @((Read-HdCache).Data.hosts).Count | Should -Be 8
    }
    It "401 — ошибка про токен, копия остаётся" {
        [void](Receive-HdSync (New-Answer 200 (New-Registry)) "https://hd.test")
        $R = Receive-HdSync (New-Answer 401) "https://hd.test"
        $R.Kind | Should -Be "fail"; $R.Text | Should -Match "токен"
        (Read-HdCache).Data | Should -Not -BeNullOrEmpty
    }
    It "нет связи — работа по копии" {
        [void](Receive-HdSync (New-Answer 200 (New-Registry)) "https://hd.test")
        $R = Receive-HdSync @{ Type = "hd"; Code = 0; Error = "timeout" } "https://hd.test"
        $R.Kind | Should -Be "offline"; $R.Text | Should -Match "копии от"
    }
    It "ответ без hosts не портит копию" {
        [void](Receive-HdSync (New-Answer 200 (New-Registry)) "https://hd.test")
        $R = Receive-HdSync @{ Type = "hd"; Code = 200; Body = '{"oops":1}' } "https://hd.test"
        $R.Kind | Should -Be "fail"
        @((Read-HdCache).Data.hosts).Count | Should -Be 8
    }
    It "копия другого сервера не используется" {
        [void](Receive-HdSync (New-Answer 200 (New-Registry)) "https://hd.test")
        (Receive-HdSync (New-Answer 304) "https://other.test").Kind | Should -Be "fail"
    }
}

Describe "файлы ssh" {
    BeforeEach {
        $script:D = Reset-Env
        [void](Receive-HdSync (New-Answer 200 (New-Registry)) "https://hd.test")
        Update-HdHosts @("myserver", "ap-router")
    }
    It "Include — первой строкой, с бэкапом; старое содержимое на месте" {
        $W = Write-HdSshFiles
        $Main = [IO.File]::ReadAllText($script:ConfigPath)
        $Main | Should -Match "(?m)^Include config.d/butler-helpdesk.conf"
        $Main.IndexOf("Include") | Should -BeLessThan $Main.IndexOf("Host myserver")
        $W.Backup | Should -Not -BeNullOrEmpty
        Test-Path $W.Backup | Should -BeTrue
    }
    It "повторная запись ничего не меняет и второй Include не добавляет" {
        [void](Write-HdSshFiles)
        $W = Write-HdSshFiles
        $W.Changed | Should -BeFalse; $W.Backup | Should -BeNullOrEmpty
        [regex]::Matches([IO.File]::ReadAllText($script:ConfigPath), "Include").Count | Should -Be 1
    }
    It "конфиг: строгая проверка ключа, ключ NetKnife, без ProxyCommand и токена" {
        [void](Write-HdSshFiles)
        $C = [IO.File]::ReadAllText((Get-HdConfPath))
        $C | Should -Match "(?m)^Host ap-router\.alye-parusa$"
        $C | Should -Match "(?m)^    StrictHostKeyChecking yes$"
        $C | Should -Match "(?m)^    IdentitiesOnly yes$"
        $C | Should -Match "(?m)^    HostKeyAlias ap-router$"
        $C | Should -Not -Match "(?m)^Host lm\.gorki-2$"
        $C | Should -Match "# Не вошли: lm\.gorki-2"
        $C | Should -Match ([regex]::Escape("IdentityFile $([IO.Path]::GetFullPath($script:MtKey).Replace('\', '/'))"))
        $C | Should -Not -Match "(?m)^\s*ProxyCommand"
        $C | Should -Not -Match "hdn_secret_token"
    }
    It "known_hosts — только подтверждённые ключи" {
        [void](Write-HdSshFiles)
        [IO.File]::ReadAllText((Get-HdKnownHostsPath)).Trim() | Should -Be "ap-router,[192.168.115.1]:10322 ssh-rsa $K1`nlm,10.10.5.2 ssh-ed25519 $K1"
    }
    It "журнал без токена" {
        [void](Write-HdSshFiles)
        "$script:Log" | Should -Not -Match "hdn_secret_token"
    }
}

Describe "роутеры MikroTik" {
    BeforeEach {
        $script:D = Reset-Env
        [void](Receive-HdSync (New-Answer 200 (New-Registry)) "https://hd.test")
        Update-HdHosts @()
    }
    It "роутер из Helpdesk — строгая проверка ключа по его known_hosts" {
        $R = @(Get-MtRouters)[0]
        $R.Source | Should -Be "helpdesk"
        $A = (Get-MtSshArgs $R) -join " "
        $A | Should -Match "StrictHostKeyChecking=yes"
        $A | Should -Match ([regex]::Escape("UserKnownHostsFile=$(Get-HdKnownHostsPath)"))
        (Get-MtSshArgs $R)[-1] | Should -Be "butler-service@192.168.115.1"
        (Get-MtSshArgs $R -Rw)[-1] | Should -Be "butler-rw@192.168.115.1"
    }
    It "ручной роутер с тем же адресом скрыт, остальные остаются и не сохраняются как Helpdesk" {
        $script:Settings.Routers = @(@{ Id = "x1"; Name = "m"; Host = "192.168.115.1"; Port = 10322; Ready = $true }, @{ Id = "x2"; Name = "o"; Host = "10.0.0.1"; Port = 22; Ready = $true })
        @(Get-MtRouters).Count | Should -Be 2
        @(Get-MtLocalRouters | ForEach-Object Id) | Should -Be @("x1", "x2")
        ((Get-MtSshArgs (Get-MtRouter "x2")) -join " ") | Should -Match "accept-new"
    }
}
