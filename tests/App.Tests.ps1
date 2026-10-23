# Pester 5: static checks of the whole app — what can be verified without Windows/WPF.
#   • the removed modules (Wi-Fi planner, floor editor, local speech, PDF helper, AI) are gone and not referenced;
#   • every script parses; every called function is defined (or is a known cmdlet);
#   • every $Ui.<Name> used by the scripts exists in Main.xaml; Main.xaml is well-formed;
#   • the grep of §9 (stage 2) finds only what is kept on purpose.

BeforeDiscovery {
    $script:Removed = @("pages\Floor.ps1", "pages\WifiPlan.ps1", "pages\WifiHub.ps1", "lib\Whisper.ps1", "lib\PdfPage.ps1", "lib\Ai.ps1")
}

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Scripts = @(Get-ChildItem $Root -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '[\\/](\.git|tests|tools)[\\/]' })
    $script:AppScripts = @($Scripts | Where-Object { $_.Name -notin @("Make-Icon.ps1", "ssh-key.ps1", "MicRec.ps1") })
    $script:Main = [IO.File]::ReadAllText((Join-Path $Root "NetKnife.ps1"))
    $script:Xaml = [IO.File]::ReadAllText((Join-Path $Root "Main.xaml"))
}

Describe "удалённые модули" {
    It "<_> — файла нет и NetKnife.ps1 его не подключает" -ForEach $Removed {
        Test-Path (Join-Path $Root $_) | Should -BeFalse
        $Main | Should -Not -Match ([regex]::Escape((Split-Path $_ -Leaf)))
    }
    It "их функции нигде не вызываются" {
        $Gone = @("Get-WplanKey", "Read-Wplan", "Save-Wplan", "Register-WplanAps", "Get-Floor", "Update-FloorView", "New-FloorView", "Initialize-FloorPage", "Initialize-WifiPlanPage",
            "Initialize-WifiHub", "Set-WhStep", "Get-WhSub", "Update-WhPrep", "Start-WhisperTranscribe", "Install-Whisper", "Test-WhisperReady", "Start-AiRequest", "Show-AiKeyDialog",
            "Get-AiStatusText", "Get-RoamApVerdict", "Get-RoamDiagnosis", "Start-RoamAi", "Save-RoamSession", "Save-WhRoamResult", "Build-WalkTimeline", "Complete-Walk", "Get-WalkReport", "Start-WalkAi")
        foreach ($F in $Scripts) {
            $T = [IO.File]::ReadAllText($F.FullName)
            foreach ($G in $Gone) { $T | Should -Not -Match "(?<![\w-])$([regex]::Escape($G))(?![\w-])" -Because "$($F.Name) вызывает $G" }
        }
    }
    It "в Main.xaml нет панелей PageFloor, PageWplan и мастера" {
        foreach ($N in @("PageFloor", "PageWplan", "PageWifiHub", "WhPrep", "WhSummary", "WhSteps", "SetAiSetup", "WkAi", "WkWhisper", "RoamDiag", "RoamAi")) { $Xaml | Should -Not -Match "x:Name=`"$N`"" }
    }
}

Describe "целостность" {
    It "все скрипты разбираются без ошибок" {
        foreach ($F in $Scripts) {
            $E = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($F.FullName, [ref]$null, [ref]$E)
            @($E).Count | Should -Be 0 -Because "$($F.Name): $(@($E | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')"
        }
    }
    It "Main.xaml — корректный XML" {
        { [xml]$Xaml } | Should -Not -Throw
    }
    It "каждая вызываемая функция определена или это известный cmdlet" {
        $Defined = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $Calls = @()
        foreach ($F in $AppScripts) {
            $Ast = [System.Management.Automation.Language.Parser]::ParseFile($F.FullName, [ref]$null, [ref]$null)
            foreach ($D in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { [void]$Defined.Add(($D.Name -replace '^script:', '')) }
            foreach ($C in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) { $N = $C.GetCommandName(); if ($N -and $N -match '^[A-Za-z]+-[A-Za-z]+$') { $Calls += @{ N = $N; F = $F.Name } } }
        }
        # Windows-only cmdlets and modules that are not on a Linux test box
        $WinOnly = @("Get-WinEvent", "Find-NetRoute", "Get-NetAdapter", "Get-NetIPConfiguration", "Get-NetConnectionProfile", "Get-NetTCPConnection", "Get-NetUDPEndpoint", "Get-DnsClientServerAddress",
            "Resolve-DnsName", "Test-NetConnection", "Get-NetRoute", "Get-NetIPAddress", "Get-NetNeighbor", "Get-CimInstance", "Get-WmiObject", "Get-Counter", "Get-ItemPropertyValue", "Start-ThreadJob",
            "Get-NetIPInterface", "Get-NetFirewallRule", "New-NetFirewallRule", "Get-Service", "Clear-DnsClientCache", "Get-Clipboard", "Set-Clipboard", "Get-DnsClientCache", "Get-PnpDevice", "Unblock-File", "Get-NetAdapterAdvancedProperty")
        $Missing = @($Calls | Where-Object { -not $Defined.Contains($_.N) -and $_.N -notin $WinOnly -and -not (Get-Command $_.N -ErrorAction SilentlyContinue) } | ForEach-Object { "$($_.F): $($_.N)" } | Sort-Object -Unique)
        $Missing | Should -BeNullOrEmpty
    }
    It "каждый `$Ui.<Name> из скриптов есть в Main.xaml" {
        $Names = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($M in [regex]::Matches($Xaml, 'x:Name="([^"]+)"')) { [void]$Names.Add($M.Groups[1].Value) }
        $Bad = @()
        foreach ($F in $AppScripts) {
            $T = [IO.File]::ReadAllText($F.FullName)
            foreach ($M in [regex]::Matches($T, '\$Ui\.([A-Za-z][A-Za-z0-9]+)')) { if (-not $Names.Contains($M.Groups[1].Value)) { $Bad += "$($F.Name): $($M.Groups[1].Value)" } }
        }
        foreach ($P in [regex]::Matches($Main, '(Panel|Nav|Focus) = "([A-Za-z]+)"')) { if (-not $Names.Contains($P.Groups[2].Value)) { $Bad += "NetKnife.ps1: $($P.Groups[2].Value)" } }
        @($Bad | Sort-Object -Unique) | Should -BeNullOrEmpty
    }
    It "шаблоны строк, на которые ссылается разметка, определены" {
        foreach ($M in [regex]::Matches($Xaml, 'ItemTemplate="\{StaticResource (\w+)\}"')) { $Xaml | Should -Match "x:Key=`"$($M.Groups[1].Value)`"" }
    }
}

Describe "grep §9 (этап 2)" {
    It "находит только то, что оставлено намеренно" {
        Push-Location $Root
        try { $Hits = @(Select-String -Path *.ps1, lib\*.ps1, pages\*.ps1 -Pattern 'Wplan|Get-Floor|Whisper|Get-Wh|Start-.*Ai\b') } finally { Pop-Location }
        # $script:WplanDir — the folder of walks and old plans (contract §6); "wplan" — old StartupPage value mapped to
        # the Wi-Fi page; "whisper" — the one-off offer to delete %APPDATA%\NetKnife\whisper\
        $Allowed = '\$script:WplanDir|@\("wplan", "roam"\)|Join-Path \$script:DataDir "whisper"'
        @($Hits | Where-Object { $_.Line -notmatch $Allowed } | ForEach-Object { "$($_.Filename):$($_.LineNumber): $($_.Line.Trim())" }) | Should -BeNullOrEmpty
    }
}
