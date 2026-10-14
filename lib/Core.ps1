# Core: settings, theme, toasts, dialogs, small helpers. Dot-sourced by NetKnife.ps1.

$script:AppDir      = Split-Path $PSScriptRoot -Parent
$script:DataDir     = Join-Path $env:APPDATA "NetKnife"
$script:SettingsPath = Join-Path $script:DataDir "settings.json"

# ---------------------------------------------------------------- settings

function Get-Settings {
    $Default = [ordered]@{
        Theme = "system"; ScanHistory = @(); PingHistory = @(); PortHistory = @(); DnsHistory = @()
        Favorites = @(); Snippets = @(); Tunnels = @(); Monitor = @()
        MinimizeToTray = $true; HotKey = $true; TrayHintShown = $false
        StartupPage = "hosts"; AutoUpdateCheck = $true
        VpnProfiles = @(); VpnPort = 2080; VpnProxySet = $false; VpnProxyBackup = $null; VpnLast = ""
    }
    try {
        if (Test-Path $script:SettingsPath) {
            $Loaded = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json -AsHashtable
            foreach ($K in $Loaded.Keys) { $Default[$K] = $Loaded[$K] }
        }
    } catch { }
    return $Default
}

function Save-Settings {
    try {
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir | Out-Null }
        $script:Settings | ConvertTo-Json -Depth 5 | Set-Content -Path $script:SettingsPath -Encoding UTF8
    } catch { }
}

function Add-History {
    param([string]$Key, [string]$Value, [int]$Max = 8)
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $List = @($script:Settings[$Key] | Where-Object { $_ -and $_ -ne $Value })
    $script:Settings[$Key] = @($Value) + $List | Select-Object -First $Max
    Save-Settings
}

# ---------------------------------------------------------------- theme

function Test-SystemDark {
    try {
        $V = Get-ItemPropertyValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" "AppsUseLightTheme" -ErrorAction Stop
        return ($V -eq 0)
    } catch { return $true }
}

# Theme catalogue: key → label (Settings dropdown). "system" follows Windows (dark/light).
$script:Themes = [ordered]@{
    "system"        = "Как в системе"
    "dark"          = "Тёмная"
    "dark-blue"     = "Тёмная · синяя"
    "midnight"      = "Полночь (чёрная)"
    "glass"         = "Стекло"
    "glass-dark"    = "Стекло · темнее"
    "glass-blue"    = "Стекло · синее"
    "glass-purple"  = "Стекло · фиолетовое"
    "glass-emerald" = "Стекло · изумруд"
    "light"         = "Светлая"
}

function Get-Palette {
    param([string]$Name = "dark")

    # "glass": the window itself is transparent and Windows draws an acrylic blur behind it (Set-WindowChrome);
    # surfaces are tinted glass over that. DialogBg is opaque (dialogs have no backdrop); TermBg is the opaque
    # colour the embedded terminal paints so it blends with the page.
    if ($Name -like "glass*") {
        # glass-dark: denser tint (less desktop bleeding through), darker cards
        $Tint = switch ($Name) { "glass-dark" { "#A60B0C10" } "glass-blue" { "#5C0F1830" } "glass-purple" { "#5C1A1230" } "glass-emerald" { "#5C0E201C" } default { "#5C14161C" } }
        $Acc  = switch ($Name) { "glass-purple" { "#FFA78BFA" } "glass-emerald" { "#FF34D399" } default { "#FF6E9BFF" } }
        $AccS = switch ($Name) { "glass-purple" { "#4DA78BFA" } "glass-emerald" { "#4D34D399" } default { "#4D5B8CFF" } }
        $Term = switch ($Name) { "glass-dark" { "#FF0E0F13" } "glass-blue" { "#FF151B2A" } "glass-purple" { "#FF1B1626" } "glass-emerald" { "#FF13201C" } default { "#FF1A1C22" } }
        $Card = $(if ($Name -eq "glass-dark") { "#8C1A1C22" } else { "#5A262931" })
        $CardH = $(if ($Name -eq "glass-dark") { "#A6222530" } else { "#7A2C3039" })
        return [ordered]@{
            WindowBg = "#00000000"; Surface = $Tint; Card = $Card; CardHover = $CardH
            Selected = "#8027324A"; Line = "#2AFFFFFF"; Text = "#FFF2F4F8"; Sub = "#FFB4BCCA"; Faint = "#FF8A92A2"
            Accent = $Acc; AccentSoft = $AccS; Chip = "#5A30343E"; CodeBg = "#9916181D"
            Ok = "#FF4CC95E"; OkSoft = "#3A3FB950"; Fail = "#FFFF7B71"; FailSoft = "#3DF85149"
            Warn = "#FFE8BD4F"; WarnSoft = "#3AE3B341"; HoverOverlay = "#18FFFFFF"; NavHover = "#18FFFFFF"; NavSel = "#2AFFFFFF"
            DialogBg = "#FF1E2026"; TermBg = $Term
        }
    }

    if ($Name -eq "midnight") {
        return [ordered]@{
            WindowBg = "#FF000000"; Surface = "#FF0A0A0C"; Card = "#FF141418"; CardHover = "#FF1C1C22"
            Selected = "#FF1B2438"; Line = "#FF222228"; Text = "#FFEDEEF2"; Sub = "#FF9DA4B2"; Faint = "#FF666C78"
            Accent = "#FF5B8CFF"; AccentSoft = "#405B8CFF"; Chip = "#FF1E1E24"; CodeBg = "#FF070708"
            Ok = "#FF3FB950"; OkSoft = "#2E3FB950"; Fail = "#FFFF6B61"; FailSoft = "#33F85149"
            Warn = "#FFE3B341"; WarnSoft = "#30E3B341"; HoverOverlay = "#14FFFFFF"; NavHover = "#14FFFFFF"; NavSel = "#22FFFFFF"
            DialogBg = "#FF0E0E11"; TermBg = "#FF0A0A0C"
        }
    }

    if ($Name -eq "dark-blue") {
        return [ordered]@{
            WindowBg = "#FF151A26"; Surface = "#F2191F2E"; Card = "#FF222A3C"; CardHover = "#FF283145"
            Selected = "#FF263556"; Line = "#FF30394E"; Text = "#FFECEFF6"; Sub = "#FFA6AFC4"; Faint = "#FF6F788E"
            Accent = "#FF6E9BFF"; AccentSoft = "#405B8CFF"; Chip = "#FF2C3448"; CodeBg = "#FF121724"
            Ok = "#FF3FB950"; OkSoft = "#2E3FB950"; Fail = "#FFFF6B61"; FailSoft = "#33F85149"
            Warn = "#FFE3B341"; WarnSoft = "#30E3B341"; HoverOverlay = "#14FFFFFF"; NavHover = "#14FFFFFF"; NavSel = "#22FFFFFF"
            DialogBg = "#FF191F2E"; TermBg = "#FF191F2E"
        }
    }

    if ($Name -ne "light") {
        return [ordered]@{
            WindowBg = "#FF1A1B20"; Surface = "#F21E2026"; Card = "#FF262931"; CardHover = "#FF2C3039"
            Selected = "#FF27324A"; Line = "#FF333743"; Text = "#FFECEEF3"; Sub = "#FFA3ABBA"; Faint = "#FF6E7685"
            Accent = "#FF5B8CFF"; AccentSoft = "#405B8CFF"; Chip = "#FF30343E"; CodeBg = "#FF16181D"
            Ok = "#FF3FB950"; OkSoft = "#2E3FB950"; Fail = "#FFFF6B61"; FailSoft = "#33F85149"
            Warn = "#FFE3B341"; WarnSoft = "#30E3B341"; HoverOverlay = "#14FFFFFF"; NavHover = "#14FFFFFF"; NavSel = "#22FFFFFF"
            DialogBg = "#FF1E2026"; TermBg = "#FF1E2026"
        }
    }

    return [ordered]@{
        DialogBg = "#FFFBFBFD"; TermBg = "#FFFBFBFD"
        WindowBg = "#FFF3F4F7"; Surface = "#F5FBFBFD"; Card = "#FFFFFFFF"; CardHover = "#FFF2F4F8"
        Selected = "#FFE7EEFF"; Line = "#FFE1E5EC"; Text = "#FF1B1F27"; Sub = "#FF586172"; Faint = "#FF8B94A3"
        Accent = "#FF2F6BFF"; AccentSoft = "#302F6BFF"; Chip = "#FFEEF1F6"; CodeBg = "#FFF3F5F9"
        Ok = "#FF1A7F37"; OkSoft = "#251A7F37"; Fail = "#FFCF222E"; FailSoft = "#22CF222E"
        Warn = "#FF9A6700"; WarnSoft = "#289A6700"; HoverOverlay = "#0D000000"; NavHover = "#0D000000"; NavSel = "#16000000"
    }
}

function Expand-ThemeXaml {
    param([string]$Xaml)

    $Theme = [IO.File]::ReadAllText((Join-Path $script:AppDir "Theme.xaml"))
    foreach ($K in $script:Palette.Keys) { $Theme = $Theme.Replace("{{$K}}", $script:Palette[$K]) }
    return $Xaml.Replace("<!--THEME-->", $Theme)
}

function Get-Brush {
    param([string]$Key)
    return $script:Win.FindResource($Key)
}

$script:AvatarColors = @("#5B8CFF", "#A371F7", "#3FB950", "#F778BA", "#E3B341", "#39C5CF", "#FF7B72", "#79C0FF", "#56D364", "#D2A8FF")
# Returns @(bgHex, fgHex): strings bind cleanly through PSObject (brushes do not)
function Get-AvatarBrushes {
    param([string]$Seed)
    $Sum = 0
    foreach ($Ch in $Seed.ToCharArray()) { $Sum = ($Sum * 31 + [int]$Ch) % 100003 }
    $Hex = $script:AvatarColors[$Sum % $script:AvatarColors.Count].TrimStart("#")
    $Alpha = if ($script:IsDark) { "33" } else { "26" }
    return @("#$Alpha$Hex", "#FF$Hex")
}

function ConvertTo-Brush {
    param([string]$Hex)
    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
}
# ---------------------------------------------------------------- native: dark title, Mica, AppUserModelID

try {
    Add-Type -Namespace NetKnife -Name Native -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins m);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
[StructLayout(LayoutKind.Sequential)] public struct Margins { public int Left, Right, Top, Bottom; }
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr CreateJobObject(IntPtr a, string name);
[DllImport("kernel32.dll")] public static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint size);
[DllImport("kernel32.dll")] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
[DllImport("kernel32.dll")] public static extern bool TerminateJobObject(IntPtr job, uint code);
[StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_BASIC_LIMIT_INFORMATION { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
[StructLayout(LayoutKind.Sequential)] public struct IO_COUNTERS { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
[StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION { public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);
[StructLayout(LayoutKind.Sequential)] public struct MEMORYSTATUSEX { public uint Length; public uint MemoryLoad; public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtendedVirtual; }
[DllImport("user32.dll")] public static extern bool SetParent(IntPtr child, IntPtr parent);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int t, bool repaint);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool SetFocus(IntPtr h);
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
'@ -ErrorAction Stop
    $script:NativeOk = $true
} catch {
    $script:NativeOk = $false
}

# ---------------------------------------------------------------- CPU / RAM sampling (cheap, no WMI)

$script:CpuPrev = $null
function Get-SystemLoad {
    $R = [ordered]@{ Cpu = $null; RamPct = $null; RamUsedGb = $null; RamTotalGb = $null }
    if (-not $script:NativeOk) { return $R }
    try {
        $idle = 0L; $kern = 0L; $usr = 0L
        if ([NetKnife.Native]::GetSystemTimes([ref]$idle, [ref]$kern, [ref]$usr)) {
            if ($script:CpuPrev) {
                $dIdle = $idle - $script:CpuPrev.Idle
                $dTotal = ($kern - $script:CpuPrev.Kernel) + ($usr - $script:CpuPrev.User)   # kernel includes idle
                if ($dTotal -gt 0) { $R.Cpu = [Math]::Round(100.0 * ($dTotal - $dIdle) / $dTotal) }
            }
            $script:CpuPrev = @{ Idle = $idle; Kernel = $kern; User = $usr }
        }
        $M = New-Object NetKnife.Native+MEMORYSTATUSEX
        $M.Length = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($M)
        if ([NetKnife.Native]::GlobalMemoryStatusEx([ref]$M)) {
            $R.RamPct = [int]$M.MemoryLoad
            $R.RamTotalGb = [Math]::Round($M.TotalPhys / 1GB, 1)
            $R.RamUsedGb = [Math]::Round(($M.TotalPhys - $M.AvailPhys) / 1GB, 1)
        }
    } catch { }
    return $R
}

# Child processes (tunnels) are put into a job with KILL_ON_JOB_CLOSE: when NetKnife dies, they die too — no orphan ssh holding ports.
$script:ChildJob = [IntPtr]::Zero
function Add-ProcessToJob {
    param([System.Diagnostics.Process]$Process)
    if (-not $script:NativeOk) { return }
    try {
        if ($script:ChildJob -eq [IntPtr]::Zero) {
            $Job = [NetKnife.Native]::CreateJobObject([IntPtr]::Zero, $null)
            $Info = New-Object NetKnife.Native+JOBOBJECT_EXTENDED_LIMIT_INFORMATION
            $Info.BasicLimitInformation.LimitFlags = 0x2000   # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            $Size = [System.Runtime.InteropServices.Marshal]::SizeOf($Info)
            $Ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($Size)
            [System.Runtime.InteropServices.Marshal]::StructureToPtr($Info, $Ptr, $false)
            [void][NetKnife.Native]::SetInformationJobObject($Job, 9, $Ptr, [uint32]$Size)   # JobObjectExtendedLimitInformation
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($Ptr)
            $script:ChildJob = $Job
        }
        [void][NetKnife.Native]::AssignProcessToJobObject($script:ChildJob, $Process.Handle)
    } catch { }
}

# Kill-on-close does not fire when the host itself already lives in a job (nested), so terminate explicitly on exit.
function Stop-ChildJob {
    if ($script:NativeOk -and $script:ChildJob -ne [IntPtr]::Zero) {
        try { [void][NetKnife.Native]::TerminateJobObject($script:ChildJob, 0) } catch { }
    }
}

# Relaunch (theme change): the whole XAML is built from the palette at startup
function Restart-App {
    $script:ReallyExit = $true
    $Vbs = Join-Path $script:AppDir "launch.vbs"
    if (Test-Path $Vbs) { Start-Process "$env:WINDIR\System32\wscript.exe" -ArgumentList (Quote-Arg $Vbs) }
    else { Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File $(Quote-Arg (Join-Path $script:AppDir 'NetKnife.ps1'))" -WindowStyle Hidden }
    $script:Win.Close()
}

function Set-WindowChrome {
    param($Window, [bool]$Mica)

    if (-not $script:NativeOk) { return }
    $Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle

    $Dark = [int]$script:IsDark
    [void][NetKnife.Native]::DwmSetWindowAttribute($Hwnd, 20, [ref]$Dark, 4)

    if ($Mica) {
        # DWMSBT_MAINWINDOW (2) = Mica; DWMSBT_TRANSIENTWINDOW (3) = Acrylic blur — the "liquid glass" look
        $Backdrop = $(if ($script:IsGlass) { 3 } else { 2 })
        $R = [NetKnife.Native]::DwmSetWindowAttribute($Hwnd, 38, [ref]$Backdrop, 4)
        if ($R -eq 0) {
            $M = New-Object NetKnife.Native+Margins
            $M.Left = -1; $M.Right = -1; $M.Top = -1; $M.Bottom = -1
            [void][NetKnife.Native]::DwmExtendFrameIntoClientArea($Hwnd, [ref]$M)
            $Src = [System.Windows.Interop.HwndSource]::FromHwnd($Hwnd)
            $Src.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
            $Window.Background = [System.Windows.Media.Brushes]::Transparent
        }
    }
}

# ---------------------------------------------------------------- feedback

function Show-Toast {
    param([string]$Text, [string]$Kind = "ok")

    $Ui.ToastText.Text = $Text
    switch ($Kind) {
        "fail" { $Ui.ToastGlyph.Text = [string][char]0xE783; $Ui.ToastGlyph.Foreground = Get-Brush "Fail" }
        "warn" { $Ui.ToastGlyph.Text = [string][char]0xE7BA; $Ui.ToastGlyph.Foreground = Get-Brush "Warn" }
        "info" { $Ui.ToastGlyph.Text = [string][char]0xE946; $Ui.ToastGlyph.Foreground = Get-Brush "Accent" }
        default { $Ui.ToastGlyph.Text = [string][char]0xE73E; $Ui.ToastGlyph.Foreground = Get-Brush "Ok" }
    }

    $Anim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $Kf = $Anim.KeyFrames
    [void]$Kf.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame 0, ([TimeSpan]::FromMilliseconds(0))))
    [void]$Kf.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame 1, ([TimeSpan]::FromMilliseconds(140))))
    [void]$Kf.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame 1, ([TimeSpan]::FromMilliseconds(2200))))
    [void]$Kf.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame 0, ([TimeSpan]::FromMilliseconds(2600))))
    $Ui.Toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $Anim)
}

# "192,168,5,10" (numpad comma on a Russian layout) → "192.168.5.10"; "192,168,5" alone → "192.168.5".
# Only when every group is ≤ 255, so port lists like "22,80,443" stay untouched. Writes the fix back into the box.
function Repair-TargetText {
    param($Box)
    $T = $Box.Text.Trim()
    $Octets = { param($M) $Ok = $true; for ($i = 1; $i -lt $M.Groups.Count; $i++) { if ([int]$M.Groups[$i].Value -gt 255) { $Ok = $false } }; if ($Ok) { (1..($M.Groups.Count - 1) | ForEach-Object { $M.Groups[$_].Value }) -join '.' } else { $M.Value } }
    $Fixed = [regex]::new('(?<![\d.])(\d{1,3}),(\d{1,3}),(\d{1,3}),(\d{1,3})(?![\d.])').Replace($T, $Octets)
    $Fixed = [regex]::new('^(\d{1,3}),(\d{1,3}),(\d{1,3})$').Replace($Fixed, $Octets)
    if ($Fixed -ne $T) {
        $Box.Text = $Fixed
        $Box.CaretIndex = $Fixed.Length
        Show-Toast "Исправил адрес: $T → $Fixed" "info"
    }
    return $Fixed
}
# Tray balloon; replaced by the real implementation when the tray icon is initialized
function Show-TrayBalloon { param([string]$Title, [string]$Text, [string]$Kind = "Info") }

function Copy-Text {
    param([string]$Text, [string]$What)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        Show-Toast "Нечего копировать: $What" "warn"
        return
    }
    try {
        [System.Windows.Clipboard]::SetText($Text)
        Show-Toast "Скопировано: $What"
    } catch {
        Show-Toast "Буфер обмена занят, попробуй ещё раз" "fail"
    }
}

function Get-Plural {
    param([int]$N, [string]$One, [string]$Few, [string]$Many)
    $M10 = $N % 10; $M100 = $N % 100
    if ($M10 -eq 1 -and $M100 -ne 11) { return "$N $One" }
    if ($M10 -ge 2 -and $M10 -le 4 -and ($M100 -lt 12 -or $M100 -gt 14)) { return "$N $Few" }
    return "$N $Many"
}

function Quote-Arg {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function New-Glyph {
    param([int]$Code, [string]$BrushKey = "Sub")
    $T = New-Object System.Windows.Controls.TextBlock
    $T.Text = [string][char]$Code
    $T.FontFamily = $script:Win.FindResource("IconFont")
    $T.FontSize = 13
    $T.Foreground = Get-Brush $BrushKey
    $T.VerticalAlignment = "Center"
    return $T
}

function New-MenuItem {
    param([string]$Header, [int]$Glyph = 0, [scriptblock]$OnClick, [string]$Gesture = "", [string]$GlyphBrush = "Sub")
    $I = New-Object System.Windows.Controls.MenuItem
    $I.Header = $Header
    if ($Glyph) { $I.Icon = New-Glyph $Glyph $GlyphBrush }
    if ($Gesture) { $I.InputGestureText = $Gesture }
    if ($OnClick) { $I.Add_Click($OnClick) }
    return $I
}

function Show-Menu {
    param($Target, [object[]]$Items)
    $M = New-Object System.Windows.Controls.ContextMenu
    foreach ($I in $Items) {
        if ($I -eq "-") { [void]$M.Items.Add((New-Object System.Windows.Controls.Separator)) }
        else { [void]$M.Items.Add($I) }
    }
    $M.PlacementTarget = $Target
    $M.Placement = "Bottom"
    $M.IsOpen = $true
}

# ---------------------------------------------------------------- dialogs

function New-Dialog {
    param([string]$Title, [string]$BodyXaml, [int]$Width = 460)

    $Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$([System.Security.SecurityElement]::Escape($Title))" Width="$Width" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" UseLayoutRounding="True">
    <Window.Resources><!--THEME--></Window.Resources>
    <Border x:Name="DlgRoot" Padding="22,18,22,18">
        $BodyXaml
    </Border>
</Window>
"@
    $D = [System.Windows.Markup.XamlReader]::Parse((Expand-ThemeXaml $Xaml))
    $D.Owner = $script:Win
    $D.Background = ConvertTo-Brush $script:Palette["DialogBg"]   # dialogs have no acrylic backdrop → opaque
    $D.Foreground = $D.FindResource("Text")
    $D.Add_SourceInitialized({ param($S, $E) Set-WindowChrome $S $false })
    return $D
}

function Show-Confirm {
    param([string]$Title, [string]$Message, [string]$Ok = "OK", [switch]$Danger, [string]$Detail = "")

    $Esc = { param($S) [System.Security.SecurityElement]::Escape($S) }
    $DetailXaml = ""
    if ($Detail) {
        # newlines inside an XML attribute collapse to spaces — keep them as entities
        $DetailText = (& $Esc ($Detail -replace "`r`n", "`n")) -replace "`n", "&#10;"
        $DetailXaml = "<TextBox Style=`"{StaticResource Code}`" Text=`"$DetailText`" Margin=`"0,12,0,0`" MaxHeight=`"260`" TextWrapping=`"Wrap`" VerticalScrollBarVisibility=`"Auto`"/>"
    }
    $OkStyle = "AccentBtn"

    $D = New-Dialog $Title -Width 540 @"
<StackPanel>
    <TextBlock Text="$(& $Esc $Title)" FontFamily="{StaticResource DisplayFont}" FontSize="18" FontWeight="SemiBold"/>
    <TextBlock Text="$(& $Esc $Message)" TextWrapping="Wrap" Foreground="{StaticResource Sub}" Margin="0,8,0,0"/>
    $DetailXaml
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
        <Button x:Name="NoBtn" Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="YesBtn" Style="{StaticResource $OkStyle}" Content="$(& $Esc $Ok)" MinWidth="110" Margin="8,0,0,0" IsDefault="True"/>
    </StackPanel>
</StackPanel>
"@
    if ($Danger) {
        $Yes = $D.FindName("YesBtn")
        $Yes.Background = $D.FindResource("Fail")
        $Yes.BorderBrush = $D.FindResource("Fail")
    }
    $D.FindName("YesBtn").Add_Click({ $D.DialogResult = $true })
    return [bool]$D.ShowDialog()
}

function Show-SaveFile {
    param([string]$Title, [string]$Filter, [string]$FileName)
    $D = New-Object Microsoft.Win32.SaveFileDialog
    $D.Title = $Title; $D.Filter = $Filter; $D.FileName = $FileName
    $D.InitialDirectory = [Environment]::GetFolderPath("MyDocuments")
    if ($D.ShowDialog($script:Win)) { return $D.FileName }
    return $null
}

function Show-OpenFiles {
    param([string]$Title, [string]$Filter = "Все файлы (*.*)|*.*")
    $D = New-Object Microsoft.Win32.OpenFileDialog
    $D.Title = $Title; $D.Filter = $Filter; $D.Multiselect = $true
    if ($D.ShowDialog($script:Win)) { return @($D.FileNames) }
    return @()
}

# Simple picker: button next to a TextBox shows a menu of values.
# Event handlers do not capture locals, so the state travels in Tag.
function Add-PickMenu {
    param($Button, $TextBox, [scriptblock]$GetItems)
    $Button.Tag = @{ Box = $TextBox; Get = $GetItems }
    $Button.Add_Click({
        param($S, $E)
        $St = $S.Tag
        $Items = foreach ($V in @(& $St.Get)) {
            $I = New-MenuItem $V.Label 0
            $I.Tag = @{ Box = $St.Box; Value = "$($V.Value)" }
            $I.Add_Click({ param($S2, $E2) $B = $S2.Tag.Box; $B.Text = $S2.Tag.Value; [void]$B.Focus(); $B.CaretIndex = $B.Text.Length })
            $I
        }
        if ($Items) { Show-Menu $S $Items }
    })
}
