# Pester 5: lib\Update.ps1 without WPF, the app in a folder with spaces and Cyrillic — the start-up check uses the
# cache while it is fresh, the download is checked against the SHA256 digest, a broken zip is refused, the swap is
# handed to install.ps1 with this folder, and that install.ps1 really replaces the files in it.

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:Base = Join-Path ([IO.Path]::GetTempPath()) ("nk-upd-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    $script:AppDir = Join-Path $Base "Мои программы\Net Knife"
    $script:DataDir = Join-Path $Base "Roaming\NetKnife"
    New-Item -ItemType Directory -Path $AppDir, $DataDir -Force | Out-Null
    Set-Content (Join-Path $AppDir "VERSION") "2026.10.30.1" -NoNewline
    Set-Content (Join-Path $AppDir "NetKnife.ps1") "# old"
    Copy-Item (Join-Path $Repo "install.ps1") $AppDir

    $script:Ui = $null
    $script:Settings = @{ AutoUpdateCheck = $true; UpdateCheckedAt = 0; UpdateCache = $null }
    function Write-AppLog { param([string]$Text) }
    function Show-Toast { param([string]$Text, [string]$Kind) }
    function Save-Settings { }
    function Test-WorkerRunning { param([string]$Name) $false }
    function Start-Worker { param([string]$Name, [scriptblock]$Body, [object[]]$ArgList, [scriptblock]$OnMessage, [hashtable]$State) }
    function Quote-Arg { param([string]$Value) '"' + $Value.Replace('"', '\"') + '"' }
    . (Join-Path $Repo "lib\Update.ps1")

    # a release zip: VERSION + NetKnife.ps1 (+ install.ps1 from the repo)
    function script:New-Zip([string]$Ver, [switch]$NoInstaller) {
        $Dir = Join-Path $Base "pkg-$Ver"
        New-Item -ItemType Directory -Path (Join-Path $Dir "lib") -Force | Out-Null
        Set-Content (Join-Path $Dir "VERSION") $Ver -NoNewline
        Set-Content (Join-Path $Dir "NetKnife.ps1") "# $Ver"
        Set-Content (Join-Path $Dir "lib\Update.ps1") "# $Ver"
        if (-not $NoInstaller) { Copy-Item (Join-Path $Repo "install.ps1") $Dir }
        $Zip = Join-Path $Base "rel-$Ver.zip"
        Compress-Archive -Path (Join-Path $Dir "*") -DestinationPath $Zip -Force
        return $Zip
    }
    function script:Invoke-Download([string]$Zip, [string]$Sha) {
        $script:FakeZip = $Zip
        $Q = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        & $script:UpdateDownloadBody $Q @{ Stop = $false } "https://github.com/x/NetKnife.zip" $Sha (Join-Path $DataDir "update\dl")
        $M = $null; [void]$Q.TryDequeue([ref]$M); return $M
    }
}

AfterAll { Remove-Item $Base -Recurse -Force -ErrorAction SilentlyContinue }

Describe "lib/Update.ps1 в произвольной папке" {
    BeforeEach { Mock Invoke-WebRequest { Copy-Item $script:FakeZip $OutFile } }

    It "версия и папка обновлений — от папки приложения и %APPDATA%" {
        $script:AppVersion | Should -Be "2026.10.30.1"
        $script:UpdateTmp | Should -Be (Join-Path $DataDir "update\dl")
    }

    It "скачанный архив с верным SHA256 распакован" {
        $Zip = New-Zip "2026.10.30.2"
        $M = Invoke-Download $Zip (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToUpper()
        $M.Error | Should -BeNullOrEmpty
        Get-Content (Join-Path $M.Src "VERSION") | Should -Be "2026.10.30.2"
    }

    It "SHA256 не совпал → ошибка, zip удалён" {
        $M = Invoke-Download (New-Zip "2026.10.30.2") ("0" * 64)
        $M.Error | Should -Match "SHA256"
        $M.Src | Should -BeNullOrEmpty
        Test-Path (Join-Path $DataDir "update\dl\NetKnife.zip") | Should -BeFalse
    }

    It "нет SHA256 от GitHub → не ставим" {
        $M = Invoke-Download (New-Zip "2026.10.30.2") ""
        $M.Error | Should -Match "SHA256"
    }

    It "битый архив → ошибка распаковки, файлы приложения не тронуты" {
        $Bad = Join-Path $Base "bad.zip"; Set-Content $Bad "не zip"
        $M = Invoke-Download $Bad (Get-FileHash -Algorithm SHA256 $Bad).Hash
        $M.Error | Should -Match "не распаковался"
        Get-Content (Join-Path $AppDir "VERSION") | Should -Be "2026.10.30.1"
    }
}

Describe "проверка при запуске" {
    BeforeEach {
        Mock Start-Worker { }
        Mock Show-UpdateBanner { }
    }
    It "свежий кэш — без запроса к GitHub, плашка «Обновить»" {
        $script:Settings.UpdateCheckedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 600
        $script:Settings.UpdateCache = @{ Tag = "v2026.10.30.5"; Url = "u"; Size = 1MB; Sha256 = "ab"; Notes = "n" }
        Start-UpdateCheck
        Should -Invoke Start-Worker -Times 0
        Should -Invoke Show-UpdateBanner -Times 1 -ParameterFilter { $Button -eq "Обновить" -and $Text -match "v2026\.10\.30\.5" }
        $script:UpdateAvail.Sha256 | Should -Be "ab"
    }
    It "кэш с той же версией — плашки нет" {
        $script:Settings.UpdateCheckedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 600
        $script:Settings.UpdateCache = @{ Tag = "v2026.10.30.1"; Url = "u"; Size = 1; Sha256 = "ab"; Notes = "" }
        Start-UpdateCheck
        Should -Invoke Show-UpdateBanner -Times 0
        $script:UpdateAvail | Should -BeNullOrEmpty
    }
    It "кэш старше $($script:UpdateEveryHours) ч — идём в GitHub; «Проверить» — всегда" {
        $script:Settings.UpdateCheckedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 7 * 3600
        Start-UpdateCheck
        Should -Invoke Start-Worker -Times 1 -ParameterFilter { $Name -eq "upd-check" }
        $script:Settings.UpdateCheckedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Start-UpdateCheck -Manual
        Should -Invoke Start-Worker -Times 2
    }
}

Describe "передача замены install.ps1" {
    BeforeEach {
        $script:Win = [pscustomobject]@{ Closed = 0 } | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.Closed++ } -PassThru
        $script:ReallyExit = $false
        Mock Start-Process { $script:Started = @{ File = $FilePath; Args = $ArgumentList } }
    }

    It "install.ps1 нового пакета, -Path = папка приложения (пробелы, кириллица), -WaitPid, -Quiet; программа закрывается" {
        $Src = Join-Path $Base "pkg-2026.10.30.2"
        New-Zip "2026.10.30.2" | Out-Null
        Invoke-AppReplace $Src
        $A = "$($Started.Args)"
        $A | Should -BeLike "*-File `"$(Join-Path $Src 'install.ps1')`"*"
        $A | Should -BeLike "*-Path `"$AppDir`"*"
        $A | Should -BeLike "*-Source `"$Src`"*"
        $A | Should -BeLike "*-WaitPid $PID -Quiet -NoShortcuts*"
        $script:ReallyExit | Should -BeTrue
        $script:Win.Closed | Should -Be 1
    }

    It "в пакете нет install.ps1 → свой из папки приложения" {
        $Src = Join-Path $Base "pkg-2026.10.30.3"
        New-Zip "2026.10.30.3" -NoInstaller | Out-Null
        Invoke-AppReplace $Src
        "$($Started.Args)" | Should -BeLike "*-File `"$(Join-Path $AppDir 'install.ps1')`"*"
    }

    It "та же командная строка в отдельном pwsh заменяет файлы в папке приложения, %APPDATA% цел" {
        Set-Content (Join-Path $DataDir "settings.json") '{"Theme":"dark"}'
        $Src = Join-Path $Base "pkg-2026.10.30.4"
        New-Zip "2026.10.30.4" | Out-Null
        Invoke-AppReplace $Src
        $Line = "$($Started.Args)" -replace '-WindowStyle Hidden ', ''
        $Line = $Line -replace "-WaitPid $PID", "-WaitPid 999999"
        $Env = @{ APPDATA = $env:APPDATA }
        $env:APPDATA = Split-Path $DataDir -Parent
        try {
            # not Start-Process: it is mocked here
            $Proc = [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path, $Line + " -NoLaunch"))
            $Proc.WaitForExit()
        } finally { $env:APPDATA = $Env.APPDATA }
        Get-Content (Join-Path $AppDir "VERSION") | Should -Be "2026.10.30.4"
        Get-Content (Join-Path $AppDir "lib\Update.ps1") | Should -Be "# 2026.10.30.4"
        Get-Content (Join-Path $DataDir "settings.json") | Should -Be '{"Theme":"dark"}'
        Get-Content (Join-Path $DataDir "update\backup\VERSION") | Should -Be "2026.10.30.1"
        (Get-Content (Join-Path $DataDir "update\result.json") -Raw | ConvertFrom-Json).Ok | Should -BeTrue
    }
}

Describe "сигнал выхода и метка запуска" {
    It "Register-AppStarted пишет VERSION в update\started.txt" {
        Register-AppStarted
        Get-Content (Join-Path $DataDir "update\started.txt") | Should -Be "2026.10.30.1"
    }
    It "NetKnife.ps1 вызывает метку, сигнал выхода и итог обновления" {
        $Main = [IO.File]::ReadAllText((Join-Path $Repo "NetKnife.ps1"))
        $Main | Should -Match "Register-AppStarted\s+\`$Win\.Show\(\)"
        $Main | Should -Match "Test-QuitSignal"
        $Main | Should -Match "Show-UpdateResult"
        [IO.File]::ReadAllText((Join-Path $Repo "install.ps1")) | Should -Match ([regex]::Escape('"Local\NetKnife.Quit"'))
        [IO.File]::ReadAllText((Join-Path $Repo "lib\Update.ps1")) | Should -Match ([regex]::Escape('"Local\NetKnife.Quit"'))
    }
}
