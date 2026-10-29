# Pester 5: tools\Publish.ps1 with git/gh mocked — preflight stops before any change (dirty tree, HEAD behind/ahead of
# origin/main, tag already taken), a failed push leaves no release and rolls back locally, a good run goes
# commit → atomic push → release.

BeforeAll {
    $script:Src = Join-Path (Split-Path $PSScriptRoot -Parent) "tools\Publish.ps1"

    # fake repo state; every git/gh call is logged as one string
    function script:Reset-Fake {
        $global:NkFake = @{
            Branch = "main"; Status = @(); Ahead = 0; Behind = 0; LocalTags = @(); RemoteTags = @(); Releases = @()
            Auth = $true; PushFail = 0; PushReject = $false; ReleaseFail = $false; Head = "a1"
        }
        $global:NkCalls = [Collections.Generic.List[string]]::new()
    }
    function script:Invoke-FakeGit([object[]]$A) {
        $global:NkCalls.Add("git " + ($A -join " "))
        $global:LASTEXITCODE = 0
        switch ($A[0]) {
            "rev-parse" { if ($A[1] -eq "--abbrev-ref") { $NkFake.Branch } else { $NkFake.Head } }
            "status" { $NkFake.Status }
            "rev-list" { "$($NkFake.Ahead)`t$($NkFake.Behind)" }
            "tag" { if ($A[1] -eq "-l") { $NkFake.LocalTags | Where-Object { $_ -eq $A[2] } } }
            "ls-remote" {
                if ($A[1] -eq "--tags") { $NkFake.RemoteTags | ForEach-Object { "f00`trefs/tags/$_" } | Where-Object { $_ -like "*$($A[3])" } }
                else { if ($NkFake.PushReject) { "c9`trefs/heads/main" } else { "a1`trefs/heads/main" } }
            }
            "commit" { $NkFake.Head = "b2" }
            "push" {
                if ($NkFake.PushReject) { $global:LASTEXITCODE = 1; "! [rejected] main -> main (non-fast-forward)" }
                elseif ($NkFake.PushFail -gt 0) { $NkFake.PushFail--; $global:LASTEXITCODE = 128; "fatal: unable to access: Could not resolve host: github.com" }
            }
        }
    }
    function script:Invoke-FakeGh([object[]]$A) {
        $global:NkCalls.Add("gh " + ($A -join " "))
        $global:LASTEXITCODE = 0
        if ($A[0] -eq "auth") { if (-not $NkFake.Auth) { $global:LASTEXITCODE = 1; "You are not logged into any GitHub hosts." } }
        elseif ($A[0] -eq "release" -and $A[1] -eq "view") { if ($A[2] -notin $NkFake.Releases) { $global:LASTEXITCODE = 1; "release not found" } }
        elseif ($A[0] -eq "release" -and $A[1] -eq "create") { if ($NkFake.ReleaseFail) { $global:LASTEXITCODE = 1; "HTTP 502" } else { $NkFake.Releases += $A[2] } }
    }
    # what changed things: commit / tag creation / push / release create
    function script:Get-Mutations { $global:NkCalls | Where-Object { $_ -match '^git (add|commit|push|reset|checkout)|^git tag (?!-l)|^gh release create' } }

    # a copy of the script in a throwaway root, so Set-Location / VERSION / zip never touch the real tree
    function script:Invoke-Publish([hashtable]$PubArgs) {
        $script:Out = [Collections.Generic.List[string]]::new()
        $script:Err = $null
        try { & $script:Script @PubArgs | ForEach-Object { $script:Out.Add("$_") } }
        catch { $script:Err = $_.Exception.Message }
    }
}

AfterAll { Remove-Variable NkFake, NkCalls -Scope Global -ErrorAction SilentlyContinue }

Describe "tools/Publish.ps1" {
    BeforeEach {
        Reset-Fake
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("nk-pub-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $Root "tools") -Force | Out-Null
        Copy-Item $Src (Join-Path $Root "tools\Publish.ps1")
        Set-Content (Join-Path $Root "VERSION") "2026.10.15.36" -NoNewline
        Set-Content (Join-Path $Root "NetKnife.ps1") "#"
        $script:Script = Join-Path $Root "tools\Publish.ps1"
        Mock git { Invoke-FakeGit $args }
        Mock gh { Invoke-FakeGh $args }
        Mock Compress-Archive { Set-Content -Path $DestinationPath -Value "zip" }
        Mock Start-Sleep { }
        Push-Location $Root
    }
    AfterEach {
        Pop-Location
        Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "грязное дерево (изменённый и неотслеживаемый файл) → стоп без изменений" {
        $NkFake.Status = @(" M Main.xaml", "?? notes.txt")
        Invoke-Publish @{ Bump = $true; Notes = "x" }
        Write-Host "--- грязное дерево ---`n$Err"
        $Err | Should -Match "рабочее дерево не чистое \(2"
        $Err | Should -Match "Main.xaml"
        $Err | Should -Match "notes.txt"
        $Err | Should -Match "git stash -u"
        Get-Mutations | Should -BeNullOrEmpty
        Get-Content (Join-Path $Root "VERSION") | Should -Be "2026.10.15.36"
        Should -Invoke Compress-Archive -Times 0
        $NkCalls | Should -Contain "git status --porcelain --untracked-files=all"
    }

    It "HEAD позади origin/main → стоп без изменений" {
        $NkFake.Behind = 2
        Invoke-Publish @{ Bump = $true }
        Write-Host "--- HEAD позади ---`n$Err"
        $Err | Should -Match "main позади origin/main на 2"
        $Err | Should -Match "git pull --ff-only"
        Get-Mutations | Should -BeNullOrEmpty
        Get-Content (Join-Path $Root "VERSION") | Should -Be "2026.10.15.36"
        $NkCalls[1] | Should -Be "git fetch -q origin"
    }

    It "HEAD впереди origin/main → стоп без изменений" {
        $NkFake.Ahead = 1
        Invoke-Publish @{ Bump = $true }
        $Err | Should -Match "main впереди origin/main на 1"
        Get-Mutations | Should -BeNullOrEmpty
    }

    It "ветка не main → стоп" {
        $NkFake.Branch = "fix/x"
        Invoke-Publish @{ Bump = $true }
        $Err | Should -Match "текущая ветка 'fix/x'"
        Get-Mutations | Should -BeNullOrEmpty
    }

    It "тег уже есть на origin → стоп без изменений" {
        $NkFake.RemoteTags = @("v2026.10.15.37")
        Invoke-Publish @{ Bump = $true }
        $Err | Should -Match "тег v2026.10.15.37 уже есть на GitHub"
        Get-Mutations | Should -BeNullOrEmpty
        Get-Content (Join-Path $Root "VERSION") | Should -Be "2026.10.15.36"
    }

    It "тег уже есть локально → стоп" {
        $NkFake.LocalTags = @("v2026.10.15.37")
        Invoke-Publish @{ Bump = $true }
        $Err | Should -Match "тег v2026.10.15.37 уже есть локально"
        Get-Mutations | Should -BeNullOrEmpty
    }

    It "релиз с таким тегом уже есть → стоп" {
        $NkFake.Releases = @("v2026.10.15.37")
        Invoke-Publish @{ Bump = $true }
        $Err | Should -Match "релиз v2026.10.15.37 уже есть"
        Get-Mutations | Should -BeNullOrEmpty
    }

    It "gh не авторизован → стоп до fetch" {
        $NkFake.Auth = $false
        Invoke-Publish @{ Bump = $true }
        $Err | Should -Match "gh не авторизован"
        $NkCalls | Should -Not -Contain "git fetch -q origin"
    }

    It "push отклонён (origin/main ушёл вперёд) → нет релиза, локальный откат, без повтора" {
        $NkFake.PushReject = $true
        Invoke-Publish @{ Bump = $true }
        Write-Host "--- push отклонён ---`n$Err"
        $Err | Should -Match "не выпущен"
        $Err | Should -Match "origin/main ушёл вперёд"
        @($NkCalls | Where-Object { $_ -like "git push*" }).Count | Should -Be 1
        $NkCalls | Should -Contain "git tag -d v2026.10.15.37"
        $NkCalls | Should -Contain "git reset -q --hard a1"
        $NkCalls | Where-Object { $_ -like "gh release create*" } | Should -BeNullOrEmpty
    }

    It "push не прошёл по сети 3 раза → нет релиза, локальный откат" {
        $NkFake.PushFail = 3
        Invoke-Publish @{ Bump = $true }
        $Err | Should -Match "push не прошёл за 3 попытки"
        @($NkCalls | Where-Object { $_ -eq "git push --atomic origin main v2026.10.15.37" }).Count | Should -Be 3
        $NkCalls | Should -Contain "git reset -q --hard a1"
        $NkCalls | Where-Object { $_ -like "gh release create*" } | Should -BeNullOrEmpty
    }

    It "push со второй попытки (тот же атомарный набор) → релиз" {
        $NkFake.PushFail = 1
        Invoke-Publish @{ Bump = $true }
        $Err | Should -BeNullOrEmpty
        @($NkCalls | Where-Object { $_ -like "git push*" }) | Should -Be @("git push --atomic origin main v2026.10.15.37", "git push --atomic origin main v2026.10.15.37")
        $NkCalls | Should -Not -Contain "git reset -q --hard a1"
        $NkFake.Releases | Should -Contain "v2026.10.15.37"
    }

    It "успех: VERSION → commit только VERSION → tag → atomic push → release" {
        Invoke-Publish @{ Bump = $true; Notes = "что нового" }
        $Err | Should -BeNullOrEmpty
        Get-Content (Join-Path $Root "VERSION") | Should -Be "2026.10.15.37"
        $Order = @($NkCalls | Where-Object { $_ -match '^git (add|commit|tag v|push)|^gh release create' })
        $Order[0] | Should -Be "git add -- VERSION"
        $Order[1] | Should -Be "git commit -q -m release v2026.10.15.37 -- VERSION"
        $Order[2] | Should -Be "git tag v2026.10.15.37"
        $Order[3] | Should -Be "git push --atomic origin main v2026.10.15.37"
        $Order[4] | Should -BeLike "gh release create v2026.10.15.37 *NetKnife.zip --repo xmaxzzz/NetKnife --title NetKnife 2026.10.15.37 --notes что нового"
        $NkCalls | Where-Object { $_ -match '^git add (-A|\.)' } | Should -BeNullOrEmpty
        $Out[-1] | Should -Match "released v2026.10.15.37"
    }

    It "релиз не создался после push → сообщение, что тег и коммит уже на GitHub, без отката" {
        $NkFake.ReleaseFail = $true
        Invoke-Publish @{ Version = "2026.10.15.40" }
        $Err | Should -Match "тег v2026.10.15.40 уже на GitHub, но релиз не создан"
        $Err | Should -Match "gh release create v2026.10.15.40"
        $NkCalls | Should -Not -Contain "git reset -q --hard a1"
    }

    It "-DryRun: проверки и zip, без коммита/тега/push/релиза, VERSION возвращён" {
        Invoke-Publish @{ Bump = $true; DryRun = $true }
        $Err | Should -BeNullOrEmpty
        Should -Invoke Compress-Archive -Times 1
        Get-Mutations | Should -Be @("git checkout -q -- VERSION")
        ($Out -join "`n") | Should -Match "DryRun"
    }
}
