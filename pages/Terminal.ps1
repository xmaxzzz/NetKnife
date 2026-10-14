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
# "#AARRGGBB" (palette) → ConEmu dword "00bbggrr"
function ConvertTo-ConEmuColor {
    param([string]$Hex)
    $H = $Hex.TrimStart('#'); if ($H.Length -eq 8) { $H = $H.Substring(2) }
    return "00" + $H.Substring(4, 2) + $H.Substring(2, 2) + $H.Substring(0, 2)
}

$script:ConEmuCfgVer = 5
function Initialize-ConEmuConfig {
    $Xml = Join-Path $script:ConEmuDir "ConEmu.xml"
    if ((Test-Path $Xml) -and ([int]"0$($script:Settings.ConEmuCfgVer)" -ge $script:ConEmuCfgVer)) { return }
    $Tpl = Join-Path $script:AppDir "assets\ConEmu.xml"
    if (-not (Test-Path $Tpl)) { Write-AppLog "conemu: template missing $Tpl"; return }
    $T = [IO.File]::ReadAllText($Tpl)
    # terminal background = page background unless the user picked a palette; native tabs and scrollbar hidden
    $PalName = "$($script:Settings.TermPalette)"
    $Bg = $(if ($PalName -and $PalName -ne "Под фон приложения" -and $script:TermPalettes[$PalName]) { $script:TermPalettes[$PalName][0] } else { ConvertTo-ConEmuColor $script:Palette["TermBg"] })
    $Pin = @{
        "FontName" = @("string", [System.Security.SecurityElement]::Escape((Get-TermFont)))
        "FontSize" = @("ulong", "15")
        "Update.CheckOnStartup" = @("hex", "00"); "Update.CheckHourly" = @("hex", "00")
        "ColorTable00" = @("dword", $Bg); "ColorTable07" = @("dword", "00cccccc"); "ColorTable15" = @("dword", "00f2f2f2")
        "StatusBar.Show" = @("hex", "00"); "Tabs" = @("hex", "00"); "Scrollbar" = @("hex", "00")
        # 16 = "auto": console attributes map straight onto ColorTable (otherwise cmd came out light-on-dark inverted)
        "TextColorIdx" = @("hex", "10"); "BackColorIdx" = @("hex", "10"); "PopTextColorIdx" = @("hex", "10"); "PopBackColorIdx" = @("hex", "10")
        "ClipboardConfirmEnter" = @("hex", "00"); "Multi.NewConfirm" = @("hex", "00"); "Multi.CloseConfirmFlags" = @("hex", "00")
    }
    $Extra = ""
    foreach ($K in $Pin.Keys) {
        $Line = "<value name=`"$K`" type=`"$($Pin[$K][0])`" data=`"$($Pin[$K][1])`"/>"
        $Rx = "<value name=`"$([regex]::Escape($K))`" type=`"[^`"]*`" data=`"[^`"]*`"\s*/>"
        if ($T -match $Rx) { $T = [regex]::Replace($T, $Rx, $Line, 1) } else { $Extra += "`t`t`t$Line`r`n" }
    }
    if ($Extra) { $T = [regex]::Replace($T, '(\s*</key>\s*</key>\s*</key>\s*)$', "`r`n$Extra`$1") }   # anchored: one insert, not one per whitespace char
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

# ---------------------------------------------------------------- color presets
# ConEmu ColorTableNN is a dword "00bbggrr". 0 = background, 7 = text, 1-6 = blue/green/cyan/red/magenta/yellow,
# 8-15 = bright variants. Presets list only the slots they change; the rest stays as in the current file.
$script:TermPalettes = [ordered]@{
    "Тёмный (NetKnife)" = @{ 0 = "000c0c0c"; 7 = "00cccccc"; 8 = "00767676"; 15 = "00f2f2f2" }
    "Под фон приложения" = @{ 0 = "0026201e"; 7 = "00d6d2cc"; 8 = "00858080"; 15 = "00f8f4f2" }   # = Surface #1E2026, terminal blends into the page
    "Чёрный"            = @{ 0 = "00000000"; 7 = "00c0c0c0"; 8 = "00808080"; 15 = "00ffffff" }
    "Dracula"           = @{ 0 = "00362a28"; 1 = "00f993bd"; 2 = "007bfa50"; 3 = "00fde98b"; 4 = "005555ff"; 5 = "00c679ff"; 6 = "008cfaf1"; 7 = "00f2f8f8"; 8 = "00a47262"; 9 = "00f993bd"; 10 = "007bfa50"; 11 = "00fde98b"; 12 = "005555ff"; 13 = "00c679ff"; 14 = "008cfaf1"; 15 = "00ffffff" }
    "Solarized Dark"    = @{ 0 = "00362b00"; 1 = "00d28b26"; 2 = "00009985"; 3 = "0098a12a"; 4 = "002f32dc"; 5 = "008236d3"; 6 = "000089b5"; 7 = "00969483"; 8 = "00756e58"; 9 = "00d28b26"; 10 = "00009985"; 11 = "0098a12a"; 12 = "002f32dc"; 13 = "008236d3"; 14 = "000089b5"; 15 = "00e3f6fd" }
    "One Half Dark"     = @{ 0 = "00342c28"; 1 = "00efaf61"; 2 = "0079c398"; 3 = "00c2b656"; 4 = "00756ce0"; 5 = "00dd78c6"; 6 = "007bc0e5"; 7 = "00e4dfdc"; 8 = "0074635a"; 9 = "00efaf61"; 10 = "0079c398"; 11 = "00c2b656"; 12 = "00756ce0"; 13 = "00dd78c6"; 14 = "007bc0e5"; 15 = "00ffffff" }
}

function Set-TermPalette {
    param([string]$Name)
    $Pal = $script:TermPalettes[$Name]
    if (-not $Pal) { return }
    if ($Name -eq "Под фон приложения") { $Pal = $Pal.Clone(); $Pal[0] = ConvertTo-ConEmuColor $script:Palette["TermBg"] }
    Initialize-ConEmuConfig
    $Xml = Join-Path $script:ConEmuDir "ConEmu.xml"
    if (-not (Test-Path $Xml)) { Show-Toast "ConEmu ещё не скачан" "warn"; return }
    $T = [IO.File]::ReadAllText($Xml)
    foreach ($I in $Pal.Keys) {
        $K = "ColorTable{0:D2}" -f [int]$I
        $Line = "<value name=`"$K`" type=`"dword`" data=`"$($Pal[$I])`"/>"
        $Rx = "<value name=`"$K`" type=`"[^`"]*`" data=`"[^`"]*`"\s*/>"
        if ($T -match $Rx) { $T = [regex]::Replace($T, $Rx, $Line, 1) }
        else { $T = [regex]::Replace($T, '(\s*</key>\s*</key>\s*</key>\s*)$', "`r`n`t`t`t$Line`$1") }
    }
    [IO.File]::WriteAllText($Xml, $T, [System.Text.UTF8Encoding]::new($false))
    $script:Settings.TermPalette = $Name; Save-Settings
    # the panel behind ConEmu shows through for a moment on restart — match it to the new background
    $Bgr = [Convert]::ToInt32($Pal[0], 16)
    if ($script:TermPanel) { $script:TermPanel.BackColor = [System.Drawing.Color]::FromArgb(($Bgr -band 0xFF), (($Bgr -shr 8) -band 0xFF), (($Bgr -shr 16) -band 0xFF)) }
    if ($script:TermProc -and -not $script:TermProc.HasExited) { New-TermSession "pwsh.exe -NoLogo" "PowerShell" }
    Show-Toast "Тема терминала: $Name"
}

# ---------------------------------------------------------------- tabs (ours; ConEmu's bar is hidden)
# ConEmu numbers consoles 1..N in creation order and renumbers on close; we mirror that list.
$script:TermTabList = [System.Collections.Generic.List[object]]::new()
$script:TermTabActive = 0

function Invoke-ConEmuMacro {
    param([string]$Macro)
    if (-not ($script:TermProc -and -not $script:TermProc.HasExited)) { return $false }
    $C = Join-Path $script:ConEmuDir "ConEmu\ConEmuC64.exe"
    if (-not (Test-Path $C)) { $C = Join-Path $script:ConEmuDir "ConEmu\ConEmuC.exe" }
    $Psi = New-Object System.Diagnostics.ProcessStartInfo $C
    $Psi.Arguments = "-GuiMacro:$($script:TermProc.Id) $Macro"
    $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true
    try { [void][System.Diagnostics.Process]::Start($Psi); return $true } catch { return $false }
}

function Update-TermTabs {
    $P = $Ui.TermTabs
    $P.Children.Clear()
    $Ui.TermTabBar.Visibility = $(if ($script:TermTabList.Count) { "Visible" } else { "Collapsed" })
    for ($i = 0; $i -lt $script:TermTabList.Count; $i++) {
        $T = $script:TermTabList[$i]
        $Sel = ($i -eq $script:TermTabActive)
        $B = New-Object System.Windows.Controls.Border
        $B.CornerRadius = New-Object System.Windows.CornerRadius 8
        $B.Padding = New-Object System.Windows.Thickness 10, 4, 6, 4
        $B.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
        $B.Background = Get-Brush $(if ($Sel) { "AccentSoft" } else { "Chip" })
        $B.BorderThickness = New-Object System.Windows.Thickness 1
        $B.BorderBrush = $(if ($Sel) { Get-Brush "Accent" } else { Get-Brush "Line" })
        $B.Cursor = [System.Windows.Input.Cursors]::Hand
        $B.Tag = $i
        $Sp = New-Object System.Windows.Controls.StackPanel; $Sp.Orientation = "Horizontal"
        $G = New-Object System.Windows.Controls.TextBlock
        $G.Text = [string][char][int]$T.Glyph; $G.FontFamily = $script:Win.FindResource("IconFont"); $G.FontSize = 12; $G.VerticalAlignment = "Center"; $G.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
        $G.Foreground = Get-Brush $(if ($Sel) { "Accent" } else { "Sub" })
        $L = New-Object System.Windows.Controls.TextBlock
        $L.Text = $T.Label; $L.FontSize = 12.5; $L.VerticalAlignment = "Center"; $L.Foreground = Get-Brush $(if ($Sel) { "Text" } else { "Sub" })
        $X = New-Object System.Windows.Controls.Button
        $X.Style = $script:Win.FindResource("IconBtn"); $X.Width = 20; $X.Height = 20; $X.FontSize = 9; $X.Content = [string][char]0xE711; $X.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0; $X.ToolTip = "Закрыть вкладку"
        $X.Tag = $i
        $X.Add_Click({ param($S, $E) $E.Handled = $true; Close-TermTab ([int]$S.Tag) })
        [void]$Sp.Children.Add($G); [void]$Sp.Children.Add($L); [void]$Sp.Children.Add($X)
        $B.Child = $Sp
        $B.Add_MouseLeftButtonUp({ param($S, $E) Select-TermTab ([int]$S.Tag) })
        [void]$P.Children.Add($B)
    }
}

function Add-TermTab {
    param([string]$Label, [int]$Glyph)
    $script:TermTabList.Add(@{ Label = $Label; Glyph = $Glyph })
    $script:TermTabActive = $script:TermTabList.Count - 1
    Update-TermTabs
}

function Select-TermTab {
    param([int]$Index)
    if ($Index -lt 0 -or $Index -ge $script:TermTabList.Count) { return }
    if (Invoke-ConEmuMacro "Tab(7,$($Index + 1))") { $script:TermTabActive = $Index; Update-TermTabs }
}

function Close-TermTab {
    param([int]$Index)
    if ($Index -lt 0 -or $Index -ge $script:TermTabList.Count) { return }
    if ($script:TermTabList.Count -le 1) { Stop-TermSession; $script:TermTabList.Clear(); Update-TermTabs; $Ui.TermStatus.Text = "закрыто"; Update-PageSub; return }
    [void](Invoke-ConEmuMacro "Tab(7,$($Index + 1))")
    Start-Sleep -Milliseconds 150
    [void](Invoke-ConEmuMacro "Close(1,1)")
    $script:TermTabList.RemoveAt($Index)
    $script:TermTabActive = [Math]::Max(0, [Math]::Min($Index, $script:TermTabList.Count - 1))
    Start-Sleep -Milliseconds 150
    [void](Invoke-ConEmuMacro "Tab(7,$($script:TermTabActive + 1))")
    Update-TermTabs
}

function Show-TermThemeMenu {
    param($Target)
    $Cur = "$($script:Settings.TermPalette)"
    $Items = foreach ($N in $script:TermPalettes.Keys) {
        $I = New-MenuItem $N $(if ($N -eq $Cur) { 0xE73E } else { 0xE790 })
        $I.Tag = $N
        $I.Add_Click({ param($S, $E) Set-TermPalette $S.Tag })
        $I
    }
    $Items += "-"
    $Items += (New-MenuItem "Все настройки ConEmu…" 0xE713 { $Ui.TermSettings.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent))) })
    Show-Menu $Target $Items
}

# ---------------------------------------------------------------- session

function Stop-TermSession {
    if ($script:TermProc -and -not $script:TermProc.HasExited) { try { $script:TermProc.Kill($true) } catch { } }
    $script:TermProc = $null
    $script:TermTabList.Clear()
    if ($Ui -and $Ui.TermTabs) { Update-TermTabs }
}

function New-TermSession {
    param([string]$ChildCmd, [string]$Label, [int]$Glyph = 0xE756)
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
    $script:TermTabList.Clear(); $script:TermTabList.Add(@{ Label = $Label; Glyph = $Glyph }); $script:TermTabActive = 0
    Update-TermTabs
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

# New console inside the running ConEmu (GuiMacro); falls back to a fresh session when nothing runs.
function Open-TermTab {
    param([string]$Exe, [string]$ExeArgs, [string]$Label, [int]$Glyph = 0xE756)
    if (-not ($script:TermProc -and -not $script:TermProc.HasExited)) { New-TermSession "$Exe $ExeArgs".Trim() $Label $Glyph; return }
    if (Invoke-ConEmuMacro "Shell(`"new_console`", `"$Exe`", `"$ExeArgs`")") { Add-TermTab $Label $Glyph; $Ui.TermStatus.Text = "+ $Label" }
    else { New-TermSession "$Exe $ExeArgs".Trim() $Label $Glyph }
}

function Show-TermSshMenu {
    param($Target)
    $Items = foreach ($H in ($script:Hosts | Sort-Object Alias)) {
        $I = New-MenuItem "$($H.Alias)   $($H.HostName)" 0xE977
        $I.Tag = $H.Alias
        $I.Add_Click({ param($S, $E) Open-TermTab "ssh.exe" "$($S.Tag)" "$($S.Tag)" 0xE977 })
        $I
    }
    if ($Items) { Show-Menu $Target $Items }
}

function Show-TerminalPage {
    # lazy-create the host on first open so the panel handle exists
    if (-not $script:TermHost) {
        $script:TermPanel = New-Object System.Windows.Forms.Panel
        $Bg = [System.Windows.Media.ColorConverter]::ConvertFromString($script:Palette["TermBg"])
        $script:TermPanel.BackColor = [System.Drawing.Color]::FromArgb($Bg.R, $Bg.G, $Bg.B)
        $Ui.TermHostArea.Background = ConvertTo-Brush $script:Palette["TermBg"]
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
    $Ui.TermCmd.Add_Click({ Open-TermTab "cmd.exe" "/T:07" "cmd" 0xE756 })   # /T:07 — ignore HKCU\Console's light default attributes
    $Ui.TermNewTab.Add_Click({ Open-TermTab "pwsh.exe" "-NoLogo" "PowerShell" 0xE756 })
    $Ui.TermTabAdd.Add_Click({ Open-TermTab "pwsh.exe" "-NoLogo" "PowerShell" 0xE756 })
    $Ui.TermRestart.Add_Click({ New-TermSession "pwsh.exe -NoLogo" "PowerShell" })
    $Ui.TermSsh.Add_Click({ param($S, $E) Show-TermSshMenu $S })
    $Ui.TermExternal.Add_Click({ Start-Terminal "" "" })
    $Ui.TermGet.Add_Click({ Start-ConEmuDownload })
    $Ui.TermTheme.Add_Click({ param($S, $E) Show-TermThemeMenu $S })
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
