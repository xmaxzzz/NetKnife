# Pester 5: the app runs from any folder — no hard-coded install path, launch.vbs finds NetKnife.ps1 next to itself.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Files = @(Get-ChildItem $Root -Recurse -File -Force | Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.Extension -notin @(".ico", ".png", ".jpg", ".zip", ".exe", ".dll")
    })
    $script:Vbs = [IO.File]::ReadAllText((Join-Path $Root "launch.vbs"))
}

Describe "нет жёсткой папки установки" {
    It "ни один файл репо не упоминает старую папку D:\SCRIPTS" {
        # the needle is split so this file does not find itself
        $Needle = 'D:' + '\\{1,2}' + 'SCRIPTS'
        $Hits = foreach ($F in $Files) {
            $N = 0
            foreach ($L in [IO.File]::ReadAllLines($F.FullName)) {
                $N++
                if ($L -match $Needle -and $F.Name -ne "Portable.Tests.ps1") { "$($F.FullName.Substring($Root.Length + 1)):$N" }
            }
        }
        @($Hits) | Should -BeNullOrEmpty
    }
}

Describe "launch.vbs" {
    It "путь к NetKnife.ps1 — из папки самого скрипта" {
        $Vbs | Should -Match 'GetParentFolderName\(WScript\.ScriptFullName\)'
        $Vbs | Should -Match 'BuildPath\(appDir, "NetKnife\.ps1"\)'
    }
    It "нет абсолютных путей с буквой диска" {
        $Vbs | Should -Not -Match '[A-Za-z]:\\'
    }
    It "запуск как раньше: без консоли, -NoProfile -STA -ExecutionPolicy Bypass, вывод в nul" {
        $Vbs | Should -Match '-NoProfile -STA -ExecutionPolicy Bypass -File '
        $Vbs | Should -Match '> nul 2>&1""", 0, False'
    }
    It "только ASCII (WSH читает .vbs в ANSI-кодировке)" {
        [IO.File]::ReadAllBytes((Join-Path $Root "launch.vbs")) | Where-Object { $_ -gt 127 } | Should -BeNullOrEmpty
    }
    It "без pwsh — MsgBox «Нужен PowerShell 7: winget …»" {
        $Line = ($Vbs -split "`n" | Where-Object { $_ -match '^\s*MsgBox ' }) | Select-Object -First 1
        $Line | Should -Not -BeNullOrEmpty
        # decode the VBScript string expression: ChrW(n) & "literal" & …
        $Text = -join ([regex]::Matches(($Line -replace ', vbExclamation.*$', ''), 'ChrW\((\d+)\)|"([^"]*)"') | ForEach-Object {
            if ($_.Groups[1].Success) { [char][int]$_.Groups[1].Value } else { $_.Groups[2].Value }
        })
        $Text | Should -BeExactly "Нужен PowerShell 7: winget install --id Microsoft.PowerShell -e"
    }
}
