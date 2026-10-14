# Page: embedded terminal via ConEmu. ConEmu's own "-InsideWnd <hwnd>" mode docks it into a WinForms panel we host
# in WPF — the one way to embed a real console on Win11 without writing a ConPTY terminal. The portable pack
# (Maximus5/ConEmu, ConEmuPack.*.7z) is fetched on first start into %APPDATA%\NetKnife\conemu and unpacked with
# Windows' built-in tar (bsdtar reads 7z); 7-Zip is used instead when present.

$script:ConEmuDir = Join-Path $script:DataDir "conemu"
$script:ConEmuExe = Join-Path $script:ConEmuDir $(if ([Environment]::Is64BitOperatingSystem) { "ConEmu64.exe" } else { "ConEmu.exe" })
$script:TermHost = $null          # WindowsFormsHost
$script:TermPanel = $null         # WinForms Panel (ConEmu parent)
$script:TermProc = $null          # ConEmu process
$script:TermLabel = ""
$script:TermWanted = $null        # @{ Cmd; Label } to start once ConEmu is downloaded

function Test-ConEmuReady { return (Test-Path $script:ConEmuExe) }

# A Nerd Font if one is installed (oh-my-posh / starship prompts draw icons from it), else Cascadia Mono
function Get-TermFont {
    try {
        $Names = (New-Object System.Drawing.Text.InstalledFontCollection).Families.Name
        foreach ($Want in @("CaskaydiaCove Nerd Font Mono", "CaskaydiaCove NF", "CaskaydiaCove Nerd Font", "JetBrainsMono Nerd Font Mono", "JetBrainsMono NF", "JetBrainsMono Nerd Font", "FiraCode Nerd Font Mono", "FiraCode NF", "MesloLGS NF", "MesloLGS Nerd Font Mono", "Hack Nerd Font Mono", "Cascadia Code NF", "Cascadia Mono NF")) {
            if ($Names -contains $Want) { return $Want }
        }
        $Any = $Names | Where-Object { $_ -match 'Nerd Font Mono$|\bNF$' } | Select-Object -First 1
        if ($Any) { return $Any }
    } catch { }
    return "Cascadia Mono"
}

# Settings file next to the exe. A minimal file makes ConEmu pop its modal "fast configuration" wizard, so the
# template in assets\ConEmu.xml is a complete config ConEmu itself saved; we only swap the font and pin a few
# values. Written once per config version (settings.ConEmuCfgVer) — ConEmu rewrites the file when the user
# saves its Settings dialog, and those edits must survive.
$script:ConEmuCfgVer = 3
function Initialize-ConEmuConfig {
    $Xml = Join-Path $script:ConEmuDir "ConEmu.xml"
    if ((Test-Path $Xml) -and ([int]"0$($script:Settings.ConEmuCfgVer)" -ge $script:ConEmuCfgVer)) { return }
    $Tpl = Join-Path $script:AppDir "assets\ConEmu.xml"
    if (-not (Test-Path $Tpl)) { Write-AppLog "conemu: template missing $Tpl"; return }
    $T = [IO.File]::ReadAllText($Tpl)
    $Pin = @{
        "FontName" = @("string", [System.Security.SecurityElement]::Escape((Get-TermFont)))
        "FontSize" = @("ulong", "15")
        "Update.CheckOnStartup" = @("hex", "00"); "Update.CheckHourly" = @("hex", "00")
        "ColorTable00" = @("dword", "000c0c0c"); "ColorTable07" = @("dword", "00cccccc"); "ColorTable15" = @("dword", "00f2f2f2")
        "StatusBar.Show" = @("hex", "00"); "Tabs" = @("hex", "02")
        "ClipboardConfirmEnter" = @("hex", "00"); "Multi.NewConfirm" = @("hex", "00"); "Multi.CloseConfirmFlags" = @("hex", "00")
    }
    $Extra = ""
    foreach ($K in $Pin.Keys) {
        $Line = "<value name=`"$K`" type=`"$($Pin[$K][0])`" data=`"$($Pin[$K][1])`"/>"
        $Rx = "<value name=`"$([regex]::Escape($K))`" type=`"[^`"]*`" data=`"[^`"]*`"\s*/>"
        if ($T -match $Rx) { $T = [regex]::Replace($T, $Rx, $Line, 1) } else { $Extra += "`t`t`t$Line`r`n" }
    }
    if ($Extra) { $T = $T -replace '(?=\s*</key>\s*</key>\s*</key>\s*$)', "`r`n$Extra" }
    [IO.File]::WriteAllText($Xml, $T, [System.Text.UTF8Encoding]::new($false))
    $script:Settings.ConEmuCfgVer = $script:ConEmuCfgVer
    Save-Settings
}

# ---------------------------------------------------------------- download (first start)

$script:ConEmuDownloadBody = {
    param($Q, $Ctl, $Dir, $SevenZip)
    try {
        $Rel = Invoke-RestMethod "https://api.github.com/repos/Maximus5/ConEmu/releases/latest" -Headers @{ "User-Agent" = "NetKnife" } -TimeoutSec 25
        $Asset = @($Rel.assets | Where-Object { $_.name -match '^ConEmuPack\.\d+\.7z$' }) | Select-Object -First 1
        if (-not $Asset) { $Q.Enqueue(@{ Type = "conemu"; Error = "в релизе $($Rel.tag_name) нет ConEmuPack.7z" }); return }
        $Q.Enqueue(@{ Type = "conemu"; Stage = "dl"; Version = "$($Rel.tag_name)"; Size = [long]$Asset.size })
        if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
        $Pack = Join-Path $Dir "pack.7z"
        Invoke-WebRequest $Asset.browser_download_url -OutFile $Pack -Headers @{ "User-Agent" = "NetKnife" } -TimeoutSec 300
        $Tar = Join-Path $env:WINDIR "System32\tar.exe"
        $Ok = $false
        if (Test-Path $Tar) { & $Tar -xf $Pack -C $Dir 2>$null; $Ok = (Test-Path (Join-Path $Dir "ConEmu64.exe")) }
        if (-not $Ok -and $SevenZip) { & $SevenZip x -y "-o$Dir" $Pack | Out-Null; $Ok = (Test-Path (Join-Path $Dir "ConEmu64.exe")) }
        Remove-Item $Pack -Force -ErrorAction SilentlyContinue
        if (-not $Ok) { $Q.Enqueue(@{ Type = "conemu"; Error = "не распаковался (нет tar с поддержкой 7z и нет 7-Zip)" }); return }
        $Q.Enqueue(@{ Type = "conemu"; Stage = "done"; Version = "$($Rel.tag_name)" })
    } catch { $Q.Enqueue(@{ Type = "conemu"; Error = "$($_.Exception.Message)" }) }
}

function Start-ConEmuDownload {
    if (Test-WorkerRunning "conemu-dl") { return }
    $SevenZip = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    Set-TermHint "wait" "Скачиваю ConEmu (встроенный терминал) с GitHub…"
    Write-AppLog "conemu: downloading"
    [void](Start-Worker -Name "conemu-dl" -Body $script:ConEmuDownloadBody -ArgList @($script:ConEmuDir, "$SevenZip") -OnMessage {
        param($M)
        if ($M.Type -ne "conemu") { return }
        if ($M.Error) { Set-TermHint "fail" "ConEmu не скачался: $($M.Error). Кнопка «Скачать ConEmu» повторит."; Write-AppLog "conemu: $($M.Error)"; return }
        if ($M.Stage -eq "dl") { Set-TermHint "wait" ("Скачиваю ConEmu $($M.Version) ({0:N1} МБ)…" -f ($M.Size / 1MB)); return }
        if ($M.Stage -eq "done") {
            Set-TermHint "none" ""
            Show-Toast "ConEmu $($M.Version) установлен — терминал встроен"
            Write-AppLog "conemu: installed $($M.Version)"
            if ($script:TermWanted) { $W = $script:TermWanted; $script:TermWanted = $null; New-TermSession $W.Cmd $W.Label }
            Update-PageSub
        }
    })
}

function Set-TermHint {
    param([string]$Kind, [string]$Text)
    if (-not $Text) { $Ui.TermHint.Visibility = "Collapsed"; return }
    $Ui.TermHint.Visibility = "Visible"
    $Ui.TermHintText.Text = $Text
    $Color = switch ($Kind) { "fail" { "Fail" } "ok" { "Ok" } default { "Warn" } }
    $Ui.TermHint.Background = Get-Brush "${Color}Soft"; $Ui.TermHint.BorderBrush = $Ui.TermHint.Background
    $Ui.TermHintText.Foreground = Get-Brush $Color; $Ui.TermHintGlyph.Foreground = Get-Brush $Color
}

# ---------------------------------------------------------------- session

function Stop-TermSession {
    if ($script:TermProc -and -not $script:TermProc.HasExited) { try { $script:TermProc.Kill($true) } catch { } }
    $script:TermProc = $null
}

function New-TermSession {
    param([string]$ChildCmd, [string]$Label)
    if (-not $script:TermPanel) { return }
    if (-not (Test-ConEmuReady)) {
        $script:TermWanted = @{ Cmd = $ChildCmd; Label = $Label }
        $Ui.TermStatus.Text = "жду ConEmu…"
        Start-ConEmuDownload
        return
    }
    Stop-TermSession
    Initialize-ConEmuConfig
    $script:TermLabel = $Label
    $Ui.TermStatus.Text = "запуск: $Label"

    $Hwnd = $script:TermPanel.Handle
    $Psi = New-Object System.Diagnostics.ProcessStartInfo $script:ConEmuExe
    # -InsideWnd docks ConEmu into our panel; -NoSingle keeps it away from any other ConEmu instance
    $Psi.Arguments = "-NoUpdate -NoSingle -LoadCfgFile $(Quote-Arg (Join-Path $script:ConEmuDir 'ConEmu.xml')) -InsideWnd 0x$($Hwnd.ToInt64().ToString('X')) -run $ChildCmd -cur_console:n"
    $Psi.WorkingDirectory = $env:USERPROFILE
    $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true
    try { $P = [System.Diagnostics.Process]::Start($Psi) } catch { $Ui.TermStatus.Text = "не запустилось: $($_.Exception.Message)"; return }
    $script:TermProc = $P
    Add-ProcessToJob $P
    $Ui.TermStatus.Text = $Label
    Update-PageSub
}

function Get-TerminalSub {
    if ($script:TermProc -and -not $script:TermProc.HasExited) { return "ConEmu · $($script:TermLabel)" }
    if (-not (Test-ConEmuReady)) { return "ConEmu ещё не скачан" }
    return "Консоль PowerShell или SSH прямо в окне (ConEmu)"
}

function Show-TermSshMenu {
    param($Target)
    $Items = foreach ($H in ($script:Hosts | Sort-Object Alias)) {
        $I = New-MenuItem "$($H.Alias)   $($H.HostName)" 0xE977
        $I.Tag = $H.Alias
        $I.Add_Click({ param($S, $E) New-TermSession "ssh.exe $($S.Tag)" "ssh $($S.Tag)" })
        $I
    }
    if ($Items) { Show-Menu $Target $Items }
}

function Show-TerminalPage {
    # lazy-create the host on first open so the panel handle exists
    if (-not $script:TermHost) {
        $script:TermPanel = New-Object System.Windows.Forms.Panel
        $script:TermPanel.BackColor = [System.Drawing.Color]::FromArgb(12, 12, 12)
        $script:TermHost = New-Object System.Windows.Forms.Integration.WindowsFormsHost
        $script:TermHost.Child = $script:TermPanel
        $Ui.TermHostArea.Child = $script:TermHost
    }
    if (-not $script:TermProc -or $script:TermProc.HasExited) {
        $script:Win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ New-TermSession "pwsh.exe -NoLogo" "PowerShell" }) | Out-Null
    }
}

function Initialize-TerminalPage {
    $Ui.TermPwsh.Add_Click({ New-TermSession "pwsh.exe -NoLogo" "PowerShell" })
    $Ui.TermCmd.Add_Click({ New-TermSession "cmd.exe" "cmd" })
    $Ui.TermRestart.Add_Click({ New-TermSession "pwsh.exe -NoLogo" "PowerShell" })
    $Ui.TermSsh.Add_Click({ param($S, $E) Show-TermSshMenu $S })
    $Ui.TermExternal.Add_Click({ Start-Terminal "" "" })
    $Ui.TermGet.Add_Click({ Start-ConEmuDownload })
    # separate ConEmu instance with just the settings dialog; writes the same ConEmu.xml the embedded one loads
    $Ui.TermSettings.Add_Click({
        if (-not (Test-ConEmuReady)) { Show-Toast "ConEmu ещё не скачан" "warn"; return }
        Initialize-ConEmuConfig
        Start-Process $script:ConEmuExe -ArgumentList "-NoUpdate -NoSingle -LoadCfgFile $(Quote-Arg (Join-Path $script:ConEmuDir 'ConEmu.xml')) -Settings"
        Show-Toast "Сохрани настройки в ConEmu и нажми «Перезапустить»" "info"
    })
    # first start: fetch ConEmu in the background so the page is ready when opened
    if (-not (Test-ConEmuReady)) { Start-ConEmuDownload }
}
