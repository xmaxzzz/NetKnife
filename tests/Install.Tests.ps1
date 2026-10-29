# Pester 5: install.ps1 with the network, processes and shortcuts mocked — SHA256 mismatch stops before any change,
# a repeat install is an update that keeps %APPDATA%\NetKnife, a failed copy or a new version that does not start
# rolls back, a broken zip leaves the old install alone, -Uninstall removes the app and shortcuts but not the data.

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:Base = Join-Path ([IO.Path]::GetTempPath()) ("nk-inst-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    $script:OldEnv = @{ APPDATA = $env:APPDATA; LOCALAPPDATA = $env:LOCALAPPDATA }
    $env:NETKNIFE_INSTALL_LIB = "1"
    . (Join-Path $Repo "install.ps1")
    Remove-Item Env:\NETKNIFE_INSTALL_LIB

    # a package folder + its zip; Extra = file names only this version has
    function script:New-FakePackage([string]$Ver, [string[]]$Extra = @()) {
        $Dir = Join-Path $Base "pkg-$Ver"
        New-Item -ItemType Directory -Path (Join-Path $Dir "lib") -Force | Out-Null
        Set-Content (Join-Path $Dir "VERSION") $Ver -NoNewline
        Set-Content (Join-Path $Dir "NetKnife.ps1") "# NetKnife $Ver"
        Set-Content (Join-Path $Dir "launch.vbs") "' $Ver"
        Set-Content (Join-Path $Dir "lib\Core.ps1") "# core $Ver"
        foreach ($E in $Extra) { Set-Content (Join-Path $Dir $E) $Ver }
        $Zip = Join-Path $Base "NetKnife-$Ver.zip"
        Compress-Archive -Path (Join-Path $Dir "*") -DestinationPath $Zip -Force
        return [pscustomobject]@{ Dir = $Dir; Zip = $Zip; Sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Zip).Hash.ToLower(); Ver = $Ver }
    }
    # Get-NkRelease answers with this package; Invoke-WebRequest "downloads" its zip
    function script:Set-FakeRelease($Pkg, [string]$Sha = $Pkg.Sha) {
        $script:FakeRel = [pscustomobject]@{ Tag = "v$($Pkg.Ver)"; Url = "https://github.com/x/NetKnife.zip"; Sha256 = $Sha; Size = 1000; Zip = $Pkg.Zip }
    }
    function script:Read-Result { Get-Content (Join-Path $env:APPDATA "NetKnife\update\result.json") -Raw | ConvertFrom-Json }
}

AfterAll {
    $env:APPDATA = $OldEnv.APPDATA; $env:LOCALAPPDATA = $OldEnv.LOCALAPPDATA
    Remove-Item $Base -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "install.ps1" {
    BeforeEach {
        Remove-Item $Base -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $Base | Out-Null
        $env:APPDATA = Join-Path $Base "Roaming"; $env:LOCALAPPDATA = Join-Path $Base "Local"
        # the user's data — must survive every install/update
        New-Item -ItemType Directory -Path (Join-Path $env:APPDATA "NetKnife\outbox") -Force | Out-Null
        Set-Content (Join-Path $env:APPDATA "NetKnife\settings.json") '{"Theme":"glass"}'
        Set-Content (Join-Path $env:APPDATA "NetKnife\outbox\walk.json") "w"
        $script:Dest = Join-Path $Base "Мои программы\NetKnife"
        $script:P1 = New-FakePackage "2026.10.30.1"
        $script:P2 = New-FakePackage "2026.10.30.2" -Extra @("install.ps1")
        Set-FakeRelease $P1

        Mock Find-NkPwsh { "pwsh" }
        Mock Get-NkRelease { $script:FakeRel }
        Mock Invoke-WebRequest { Copy-Item $script:FakeRel.Zip $OutFile }
        Mock Get-NkAppProcess { @() }
        Mock Set-NkShortcuts { }
        Mock Remove-NkShortcuts { }
        Mock Start-Sleep { }
        # a healthy app: started.txt gets the VERSION of what is installed
        Mock Start-NkApp { Set-Content (Join-Path $env:APPDATA "NetKnife\update\started.txt") (Get-NkVersion $Path) }
    }

    It "первая установка: файлы, ярлыки, запуск; данные не тронуты" {
        Install-NetKnife -Path $Dest -Quiet
        Get-NkVersion $Dest | Should -Be $P1.Ver
        Test-Path (Join-Path $Dest "lib\Core.ps1") | Should -BeTrue
        Should -Invoke Set-NkShortcuts -Times 1 -ParameterFilter { $Path -eq $Dest }
        Should -Invoke Start-NkApp -Times 1
        Get-Content (Join-Path $env:APPDATA "NetKnife\settings.json") | Should -Be '{"Theme":"glass"}'
        (Read-Result).Ok | Should -BeTrue
    }

    It "по умолчанию — %LOCALAPPDATA%\NetKnife" {
        Install-NetKnife -Quiet -NoLaunch -NoShortcuts
        Get-NkVersion (Join-Path $env:LOCALAPPDATA "NetKnife") | Should -Be $P1.Ver
    }

    It "SHA256 не совпал → стоп: zip удалён, папка не создана" {
        Set-FakeRelease $P1 ("0" * 64)
        { Install-NetKnife -Path $Dest -Quiet } | Should -Throw "*SHA256*не совпал*"
        Test-Path $Dest | Should -BeFalse
        Should -Invoke Start-NkApp -Times 0
        $Out = Join-Path $Base "dl.zip"
        { Save-NkPackage -Release $FakeRel -OutFile $Out } | Should -Throw "*SHA256*"
        Test-Path $Out | Should -BeFalse
    }

    It "повторный запуск = обновление: новые файлы, %APPDATA% на месте, бэкап прежней версии" {
        Install-NetKnife -Path $Dest -Quiet
        Set-FakeRelease $P2
        Install-NetKnife -Path $Dest -Quiet
        Get-NkVersion $Dest | Should -Be $P2.Ver
        Get-Content (Join-Path $Dest "lib\Core.ps1") | Should -Be "# core $($P2.Ver)"
        Test-Path (Join-Path $Dest "install.ps1") | Should -BeTrue
        Get-Content (Join-Path $env:APPDATA "NetKnife\settings.json") | Should -Be '{"Theme":"glass"}'
        Get-Content (Join-Path $env:APPDATA "NetKnife\outbox\walk.json") | Should -Be "w"
        Get-NkVersion (Join-Path $env:APPDATA "NetKnife\update\backup") | Should -Be $P1.Ver
        $R = Read-Result
        $R.Ok | Should -BeTrue; $R.From | Should -Be $P1.Ver; $R.Version | Should -Be $P2.Ver
    }

    It "запущенную программу просят закрыться до замены файлов" {
        Install-NetKnife -Path $Dest -Quiet -NoLaunch
        $script:Running = $true
        Mock Get-NkAppProcess { if ($script:Running) { @(4242) } else { @() } }
        Mock Send-NkQuit { $script:Running = $false; $true }
        Mock Wait-NkExit { -not $script:Running }
        Mock Stop-Process { }
        Set-FakeRelease $P2
        Install-NetKnife -Path $Dest -Quiet -NoLaunch
        Should -Invoke Send-NkQuit -Times 1
        Should -Invoke Stop-Process -Times 0
        Get-NkVersion $Dest | Should -Be $P2.Ver
    }

    It "ошибка при копировании → откат к прежним файлам, новое удалено" {
        Install-NetKnife -Path $Dest -Quiet
        Set-FakeRelease $P2
        $script:Copied = 0
        Mock Copy-NkItem { $script:Copied++; if ($script:Copied -ge 3) { throw "диск полон" }; Copy-Item -LiteralPath $Item -Destination $Dest -Recurse -Force }
        { Install-NetKnife -Path $Dest -Quiet } | Should -Throw "*диск полон*возвращены прежние*"
        Get-NkVersion $Dest | Should -Be $P1.Ver
        Get-Content (Join-Path $Dest "NetKnife.ps1") | Should -Be "# NetKnife $($P1.Ver)"
        Get-Content (Join-Path $Dest "lib\Core.ps1") | Should -Be "# core $($P1.Ver)"
        Test-Path (Join-Path $Dest "install.ps1") | Should -BeFalse
        $R = Read-Result
        $R.Ok | Should -BeFalse; $R.Error | Should -Match "диск полон"
    }

    It "новая версия не запустилась → откат и запуск прежней" {
        Install-NetKnife -Path $Dest -Quiet
        Set-FakeRelease $P2
        Mock Start-NkApp { if ((Get-NkVersion $Path) -ne $P2.Ver) { Set-Content (Join-Path $env:APPDATA "NetKnife\update\started.txt") (Get-NkVersion $Path) } }
        { Install-NetKnife -Path $Dest -Quiet } | Should -Throw "*не запустился*возвращена $($P1.Ver)*"
        Get-NkVersion $Dest | Should -Be $P1.Ver
        Test-Path (Join-Path $Dest "install.ps1") | Should -BeFalse
        Should -Invoke Start-NkApp -Times 3   # first install, the failed new one, the restored old one
        (Read-Result).Ok | Should -BeFalse
    }

    It "битый архив (SHA256 сходится) → ошибка распаковки, установленная версия не тронута" {
        Install-NetKnife -Path $Dest -Quiet
        $Bad = Join-Path $Base "bad.zip"
        Set-Content $Bad "это не zip"
        $script:FakeRel = [pscustomobject]@{ Tag = "v9"; Url = "u"; Sha256 = (Get-FileHash -Algorithm SHA256 $Bad).Hash.ToLower(); Size = 10; Zip = $Bad }
        { Install-NetKnife -Path $Dest -Quiet } | Should -Throw "*не распаковался*"
        Get-NkVersion $Dest | Should -Be $P1.Ver
        Get-Content (Join-Path $Dest "lib\Core.ps1") | Should -Be "# core $($P1.Ver)"
    }

    It "чужая непустая папка → стоп" {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
        Set-Content (Join-Path $Dest "мои.txt") "x"
        { Install-NetKnife -Path $Dest -Quiet } | Should -Throw "*не пустая*"
        Get-Content (Join-Path $Dest "мои.txt") | Should -Be "x"
    }

    It "-Uninstall: программа и ярлыки удалены, данные остались" {
        Install-NetKnife -Path $Dest -Quiet
        Mock Read-NkYes { $true }
        Uninstall-NetKnife -Path $Dest
        Test-Path $Dest | Should -BeFalse
        Should -Invoke Remove-NkShortcuts -Times 1 -ParameterFilter { $Path -eq $Dest }
        Should -Invoke Read-NkYes -Times 0
        Test-Path (Join-Path $env:APPDATA "NetKnife\settings.json") | Should -BeTrue
    }

    It "-Uninstall -RemoveData: спрашивает; «нет» — данные остались, «да» — удалены" {
        Install-NetKnife -Path $Dest -Quiet
        Mock Read-NkYes { $false }
        Uninstall-NetKnife -Path $Dest -RemoveData
        Should -Invoke Read-NkYes -Times 1
        Test-Path (Join-Path $env:APPDATA "NetKnife\settings.json") | Should -BeTrue
        Mock Read-NkYes { $true }
        Uninstall-NetKnife -Path $Dest -RemoveData
        Test-Path (Join-Path $env:APPDATA "NetKnife") | Should -BeFalse
    }

    It "-Uninstall не трогает git-клон" {
        New-Item -ItemType Directory -Path (Join-Path $Dest ".git") -Force | Out-Null
        Set-Content (Join-Path $Dest "NetKnife.ps1") "#"
        { Uninstall-NetKnife -Path $Dest } | Should -Throw "*git-клон*"
        Test-Path (Join-Path $Dest "NetKnife.ps1") | Should -BeTrue
    }
}

Describe "install.ps1: релиз из GitHub API" {
    It "SHA256 берётся из digest ассета" {
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = "v1"; assets = @([pscustomobject]@{ name = "NetKnife.zip"; browser_download_url = "u"; size = 1; digest = "sha256:" + ("AB" * 32) }) } }
        (Get-NkRelease).Sha256 | Should -Be ("ab" * 32)
    }
    It "нет digest → стоп" {
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = "v1"; assets = @([pscustomobject]@{ name = "NetKnife.zip"; browser_download_url = "u"; size = 1; digest = $null }) } }
        { Get-NkRelease } | Should -Throw "*не отдал SHA256*"
        ConvertFrom-NkDigest "md5:abc" | Should -Be ""
    }
    It "нет NetKnife.zip в релизе → стоп" {
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = "v1"; assets = @() } }
        { Get-NkRelease } | Should -Throw "*нет NetKnife.zip*"
    }
}
