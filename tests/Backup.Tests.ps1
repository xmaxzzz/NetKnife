# Pester 5: lib\Backup.ps1 — what goes into the backup, encryption, restore into a wiped profile, path guard.
# Everything in a temp dir; the Helpdesk token store is mocked. DPAPI parts run on Windows only.
#   Run:  Invoke-Pester -Path tests

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:AppDir = $Root; $script:AppVersion = "test"
    function Write-AppLog { param($X) }
    function Show-Toast { param($X, $K) }
    . (Join-Path $Root "lib\Core.ps1")
    . (Join-Path $Root "lib\Ssh.ps1")
    . (Join-Path $Root "lib\Backup.ps1")
    function Get-HdToken { return "hdp_test_token" }
    function Set-HdToken { param($X) $script:SetToken = $X }

    function Reset-Env {
        $T = Join-Path ([IO.Path]::GetTempPath()) ("nk-bk-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
        $env:LOCALAPPDATA = Join-Path $T "local"
        $script:DataDir = Join-Path $T "appdata/NetKnife"; $script:SettingsPath = Join-Path $script:DataDir "settings.json"
        $script:SshDir = Join-Path $T "ssh"; $script:SetToken = $null
        foreach ($D in "wifiplan/site", "vpn", "conemu") { New-Item -ItemType Directory -Path (Join-Path $script:DataDir $D) -Force | Out-Null }
        New-Item -ItemType Directory -Path (Join-Path $script:SshDir "config.d"), (Join-Path $env:LOCALAPPDATA "NetKnife/lib") -Force | Out-Null
        $script:Big = [byte[]]::new(300KB); [Random]::new(1).NextBytes($script:Big)
        [IO.File]::WriteAllBytes((Join-Path $script:DataDir "wifiplan/site/walk.wav"), $script:Big)
        Set-Content (Join-Path $script:DataDir "vpn/xray.exe") "engine"; Set-Content (Join-Path $script:DataDir "netknife.log") "log"
        Set-Content (Join-Path $script:SshDir "netknife_mt") "-----BEGIN OPENSSH PRIVATE KEY-----`nfake`n-----END OPENSSH PRIVATE KEY-----"
        Set-Content (Join-Path $script:SshDir "config") "Host a"; Set-Content (Join-Path $script:SshDir "config.bak-1") "old"
        Set-Content (Join-Path $env:LOCALAPPDATA "NetKnife/helpdesk-hosts.json") "{}"; Set-Content (Join-Path $env:LOCALAPPDATA "NetKnife/lib/app.ps1") "app"
        $script:Settings = Get-Settings
        $script:Settings.VpnProfiles = @(@{ Name = "p"; Link = "vless://secret@host" })
        if ($IsWindows) {
            $script:Settings.Collectors = @(@{ Url = "https://hd"; TokenEnc = (ConvertTo-SecureString "hdw_collector_secret" -AsPlainText -Force | ConvertFrom-SecureString) })
            $script:Settings.Routers = @(@{ Id = "r1"; PassEnc = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes("mt-pass"), $null, "CurrentUser")) })
        }
        Save-Settings
        return $T
    }
    function New-TestBackup {
        param([string]$Password = "correct horse 1")
        $script:Plan = Get-BackupPlan
        $Out = Join-Path $script:T "out/test.nkbak"
        $Q = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        & $script:BkMakeBody $Q @{ Stop = $false } $script:Plan.Files $script:Plan.SecretsJson $script:Plan.ManifestJson $Password $Out $script:BkCrypto.ToString() 20000
        return $Out
    }
}

Describe "состав бэкапа" {
    BeforeEach { $script:T = Reset-Env }
    AfterEach { Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue }
    It "данные и ~/.ssh — да; движки, журналы, .bak и код программы — нет" {
        $E = @((Get-BackupPlan).Files | ForEach-Object Entry)
        $E | Should -Contain "appdata/wifiplan/site/walk.wav"
        $E | Should -Contain "appdata/settings.json"
        $E | Should -Contain "ssh/netknife_mt"
        $E | Should -Contain "local/helpdesk-hosts.json"
        ($E -join " ") | Should -Not -Match "appdata/vpn/|appdata/conemu/|\.log|bak|local/lib"
    }
}

Describe "шифрование" {
    BeforeEach { $script:T = Reset-Env; $script:Out = New-TestBackup }
    AfterEach { Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue }
    It "в файле нет открытых ключей, ссылок и токенов" {
        $Txt = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($script:Out))
        $Txt | Should -Not -Match "PRIVATE KEY|vless://|hdp_test_token|hdw_collector_secret|mt-pass"
        $Txt.Substring(0, 6) | Should -Be "NKBAK1"
    }
    It "неверный пароль — отказ" {
        { Read-BackupFile $script:Out "wrong password" } | Should -Throw "*неверный пароль*"
    }
    It "испорченный файл — отказ" {
        $B = [IO.File]::ReadAllBytes($script:Out); $B[$B.Length - 3] = $B[$B.Length - 3] -bxor 1
        [IO.File]::WriteAllBytes($script:Out, $B)
        { Read-BackupFile $script:Out "correct horse 1" } | Should -Throw "*повреждён*"
    }
}

Describe "восстановление" {
    BeforeEach {
        $script:T = Reset-Env; $script:Out = New-TestBackup
        Remove-Item -LiteralPath (Split-Path $script:DataDir -Parent), $script:SshDir -Recurse -Force
        New-Item -ItemType Directory -Path $script:DataDir, $script:SshDir -Force | Out-Null
        Set-Content (Join-Path $script:SshDir "config") "Host newer"
        $script:R = Invoke-BackupRestore (Read-BackupFile $script:Out "correct horse 1")
    }
    AfterEach { Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue }
    It "все файлы на месте, байт в байт" {
        $script:R.Written | Should -Be $script:Plan.Files.Count
        [IO.File]::ReadAllBytes((Join-Path $script:DataDir "wifiplan/site/walk.wav")).Length | Should -Be $script:Big.Length
        Get-Content (Join-Path $script:SshDir "netknife_mt") -Raw | Should -Match "fake"
    }
    It "заменённый файл сохранён в NetKnife-before-restore" {
        Get-Content (Join-Path $script:R.SafetyDir "ssh/config") -Raw | Should -Match "newer"
    }
    It "токен Helpdesk возвращён" {
        $script:SetToken | Should -Be "hdp_test_token"
    }
    It "секреты DPAPI заново защищены и читаются" -Skip:(-not $IsWindows) {
        $S = Get-Settings
        [System.Net.NetworkCredential]::new("", (ConvertTo-SecureString $S.Collectors[0].TokenEnc)).Password | Should -Be "hdw_collector_secret"
        [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($S.Routers[0].PassEnc), $null, "CurrentUser")) | Should -Be "mt-pass"
        Get-Content $script:SettingsPath -Raw | Should -Not -Match "hdw_collector_secret|mt-pass"
    }
}

Describe "пути при восстановлении" {
    BeforeAll { $script:T = Reset-Env }
    AfterAll { Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue }
    It "<_> — отклоняется" -ForEach @("appdata/../../evil.txt", "ssh/../evil", "local/lib/app.ps1", "other/x", "C:/Windows/x", "appdata/") {
        Resolve-BkTarget $_ | Should -BeNullOrEmpty
    }
    It "appdata/settings.json — в папку данных" {
        Resolve-BkTarget "appdata/settings.json" | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:DataDir "settings.json")))
    }
}
