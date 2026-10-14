# Tray icon (WinForms NotifyIcon inside the WPF app), hide-to-tray on close, global hotkey.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$script:ReallyExit = $false
$script:Tray = $null

# WM_HOTKEY needs a window hook; a tiny C# shim keeps the ref-parameter delegate out of PowerShell
try {
    if (-not ("NetKnifeHotKey" -as [type])) {
        Add-Type -ReferencedAssemblies @([System.Windows.Interop.HwndSource].Assembly.Location, [System.Windows.DependencyObject].Assembly.Location) -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;
public static class NetKnifeHotKey {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    const int ID = 0x4E4B;
    public static Action Pressed;
    static HwndSource src; static IntPtr hwnd;
    public static bool Attach(IntPtr handle, uint mod, uint vk) {
        hwnd = handle; src = HwndSource.FromHwnd(handle);
        if (src == null) return false;
        src.AddHook(Hook);
        return RegisterHotKey(handle, ID, mod, vk);
    }
    public static void Detach() { if (src != null) { src.RemoveHook(Hook); UnregisterHotKey(hwnd, ID); src = null; } }
    static IntPtr Hook(IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) {
        if (msg == 0x0312 && (int)w == ID) { var p = Pressed; if (p != null) p(); handled = true; }
        return IntPtr.Zero;
    }
}
'@ -ErrorAction Stop
    }
    $script:HotKeyOk = $true
} catch {
    $script:HotKeyOk = $false
    Write-AppLog "hotkey shim: $_"
}

function Show-MainWindow {
    $Win = $script:Win
    if (-not $Win.IsVisible) { $Win.Show() }
    if ($Win.WindowState -eq "Minimized") { $Win.WindowState = "Normal" }
    [void]$Win.Activate()
    $Win.Topmost = $true; $Win.Topmost = $false
    [void]$Win.Focus()
}

function Hide-MainWindow {
    $script:Win.Hide()
    if (-not $script:Settings.TrayHintShown) {
        $script:Settings.TrayHintShown = $true; Save-Settings
        Show-TrayBalloon "NetKnife работает в трее" "Клик по иконке или $(Get-HotKeyText) — показать окно. Выход — через меню иконки." "Info"
    }
}

function Switch-MainWindow {
    $Win = $script:Win
    if ($Win.IsVisible -and $Win.WindowState -ne "Minimized" -and $Win.IsActive) { Hide-MainWindow } else { Show-MainWindow }
}

function Get-HotKeyText { return "Ctrl+Alt+N" }

function Show-TrayBalloon {
    param([string]$Title, [string]$Text, [string]$Kind = "Info")
    if (-not $script:Tray) { return }
    try { $script:Tray.ShowBalloonTip(5000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]$Kind) } catch { }
}

function Update-TrayText {
    if (-not $script:Tray) { return }
    $Parts = @("NetKnife")
    if (Test-VpnRunning) {
        $Pf = @(Get-VpnProfiles) | Where-Object { $_.Id -eq $script:Vpn.Id } | Select-Object -First 1
        $Parts += "VPN: $($Pf.Name)$(if ($script:Vpn.Egress) { " · $($script:Vpn.Egress)" })"
    }
    $Tun = @($script:TunnelProcs.Keys | Where-Object { Test-TunnelRunning $_ }).Count
    if ($Tun) { $Parts += "туннелей: $Tun" }
    $Down = @($script:MonState.Values | Where-Object { $_.Up -eq $false }).Count
    if ($Down) { $Parts += "лежат: $Down" }
    $T = $Parts -join " · "
    if ($T.Length -gt 63) { $T = $T.Substring(0, 63) }
    $script:Tray.Text = $T
}

# ---------------------------------------------------------------- VPN in the tray: submenu + animated icon

$script:TrayBaseIcon = $null
$script:TrayFrames = @()        # pre-rendered icons: ring rotating around the base icon
$script:TrayFrame = 0
$script:TrayAnim = $null        # DispatcherTimer
$script:TrayVpnMenu = $null

# Base icon + a 270° arc in the given color, rotated by $Angle. Frames are built once; swapping Icon objects is cheap.
function New-TrayFrame {
    param([System.Drawing.Bitmap]$Base, [int]$Angle, [System.Drawing.Color]$Color)
    $Bmp = New-Object System.Drawing.Bitmap 32, 32
    $G = [System.Drawing.Graphics]::FromImage($Bmp)
    $G.SmoothingMode = "AntiAlias"; $G.InterpolationMode = "HighQualityBicubic"
    $G.DrawImage($Base, 4, 4, 24, 24)                       # base shrunk a bit to leave room for the ring
    $Pen = New-Object System.Drawing.Pen $Color, 3
    $Pen.StartCap = "Round"; $Pen.EndCap = "Round"
    $G.DrawArc($Pen, 2, 2, 28, 28, $Angle, 270)
    $Pen.Dispose(); $G.Dispose()
    $H = $Bmp.GetHicon()
    $Icon = [System.Drawing.Icon]::FromHandle($H).Clone()   # Clone owns its handle; free the original
    [NetKnife.Native]::DestroyIcon($H) | Out-Null
    $Bmp.Dispose()
    return $Icon
}

function Initialize-TrayFrames {
    if (-not $script:TrayBaseIcon) { return }
    $Base = $script:TrayBaseIcon.ToBitmap()
    $Ok = [System.Drawing.Color]::FromArgb(255, 52, 211, 153)
    $Wait = [System.Drawing.Color]::FromArgb(255, 251, 191, 36)
    $script:TrayFrames = @{ ok = @(); wait = @() }
    for ($i = 0; $i -lt 12; $i++) {
        $script:TrayFrames.ok += New-TrayFrame $Base ($i * 30) $Ok
        $script:TrayFrames.wait += New-TrayFrame $Base ($i * 30) $Wait
    }
    $Base.Dispose()
}

# Called whenever VPN state changes: spin the ring while connected, plain icon otherwise
function Update-TrayVpn {
    if (-not $script:Tray) { return }
    $Running = Test-VpnRunning
    if ($Running -and -not $script:TrayAnim) {
        if (-not $script:TrayFrames.Count) { Initialize-TrayFrames }
        $script:TrayAnim = New-Object System.Windows.Threading.DispatcherTimer
        $script:TrayAnim.Interval = [TimeSpan]::FromMilliseconds(110)
        $script:TrayAnim.Add_Tick({
            if (-not $script:Tray -or -not $script:TrayFrames.Count) { return }
            $Set = $(if ($script:Vpn -and ([DateTime]::Now - $script:Vpn.Started).TotalSeconds -lt 4) { "wait" } else { "ok" })
            $script:TrayFrame = ($script:TrayFrame + 1) % 12
            $script:Tray.Icon = $script:TrayFrames[$Set][$script:TrayFrame]
        })
        $script:TrayAnim.Start()
    } elseif (-not $Running -and $script:TrayAnim) {
        $script:TrayAnim.Stop(); $script:TrayAnim = $null
        $script:Tray.Icon = $script:TrayBaseIcon
    }
    Update-TrayText
}

# Last used profile (settings.VpnLast), else the first one
function Get-VpnQuickProfile {
    $Pfs = @(Get-VpnProfiles)
    $Pf = $Pfs | Where-Object { $_.Id -eq "$($script:Settings.VpnLast)" } | Select-Object -First 1
    if (-not $Pf -and $Pfs.Count) { $Pf = $Pfs[0] }
    return $Pf
}

function Invoke-VpnQuickToggle {
    if (Test-VpnRunning) { Stop-Vpn; return }
    $Pf = Get-VpnQuickProfile
    if ($Pf) { Start-Vpn $Pf } else { Show-MainWindow; Set-Page "vpn"; Show-Toast "Сначала добавь VPN-профиль" "warn" }
}

# Rebuilt every time the menu opens: current profiles, the active one checked, "disconnect" when connected
function Update-TrayVpnMenu {
    if ($script:TrayVpnQuick) {
        if (Test-VpnRunning) {
            $Cur = @(Get-VpnProfiles) | Where-Object { $_.Id -eq $script:Vpn.Id } | Select-Object -First 1
            $script:TrayVpnQuick.Text = "VPN: выключить ($($Cur.Name))"
        } else {
            $Pf = Get-VpnQuickProfile
            $script:TrayVpnQuick.Text = $(if ($Pf) { "VPN: включить ($($Pf.Name))" } else { "VPN: нет профилей" })
        }
    }
    $M = $script:TrayVpnMenu
    if (-not $M) { return }
    $M.DropDownItems.Clear()
    $Active = Get-VpnActiveId
    $Pfs = @(Get-VpnProfiles)
    $M.Text = $(if ($Active) { "VPN · подключён" } else { "VPN" })
    if ($Active) {
        $Off = $M.DropDownItems.Add("Отключить")
        $Off.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $Off.Add_Click({ Stop-Vpn })
        [void]$M.DropDownItems.Add("-")
    }
    foreach ($Pf in $Pfs) {
        $I = $M.DropDownItems.Add($Pf.Name)
        $I.Tag = $Pf.Id
        $I.Checked = ($Pf.Id -eq $Active)
        $I.Add_Click({ param($S, $E) $P2 = @(Get-VpnProfiles) | Where-Object { $_.Id -eq $S.Tag } | Select-Object -First 1; if ($P2) { if ($P2.Id -eq (Get-VpnActiveId)) { Stop-Vpn } else { Start-Vpn $P2 } } })
    }
    if (-not $Pfs.Count) { $N = $M.DropDownItems.Add("Нет профилей — добавь на странице VPN"); $N.Enabled = $false }
    [void]$M.DropDownItems.Add("-")
    $Pg = $M.DropDownItems.Add("Открыть страницу VPN")
    $Pg.Add_Click({ Show-MainWindow; Set-Page "vpn" })
}

function Initialize-Tray {
    $Tray = New-Object System.Windows.Forms.NotifyIcon
    $IconPath = Join-Path $script:AppDir "NetKnife.ico"
    if (Test-Path $IconPath) { $Tray.Icon = New-Object System.Drawing.Icon $IconPath, 32, 32 } else { $Tray.Icon = [System.Drawing.SystemIcons]::Application }
    $script:TrayBaseIcon = $Tray.Icon
    $Tray.Text = "NetKnife"

    $Menu = New-Object System.Windows.Forms.ContextMenuStrip
    $Menu.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    # top item: one click toggles the last used profile
    $script:TrayVpnQuick = $Menu.Items.Add("VPN: включить")
    $script:TrayVpnQuick.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
    $script:TrayVpnQuick.Add_Click({ Invoke-VpnQuickToggle })
    [void]$Menu.Items.Add("-")
    $Show = $Menu.Items.Add("Показать NetKnife")
    $Show.Add_Click({ Show-MainWindow })
    $Menu.Add_Opening({ Update-TrayVpnMenu })   # refreshes the VPN item text (profile name / state)
    [void]$Menu.Items.Add("-")
    $Exit = $Menu.Items.Add("Выход")
    $Exit.Add_Click({ $script:ReallyExit = $true; $script:Win.Close() })
    $Tray.ContextMenuStrip = $Menu

    $Tray.Add_MouseClick({ param($S, $E) if ($E.Button -eq "Left") { Switch-MainWindow } })
    $Tray.Add_BalloonTipClicked({ Show-MainWindow })
    $Tray.Visible = $true
    $script:Tray = $Tray
}

function Register-AppHotKey {
    if (-not $script:HotKeyOk) { return }
    $Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $script:Win).Handle
    [NetKnifeHotKey]::Pressed = [Action]{ Switch-MainWindow }
    $Ok = [NetKnifeHotKey]::Attach($Hwnd, 3, 0x4E)   # MOD_ALT|MOD_CONTROL + N
    Write-AppLog "hotkey registered: $Ok (hwnd $Hwnd)"
    if (-not $Ok) { Show-Toast "Не удалось занять $(Get-HotKeyText) — комбинация занята другой программой" "warn" }
}

function Unregister-AppHotKey {
    if ($script:HotKeyOk) { try { [NetKnifeHotKey]::Detach() } catch { } }
}

function Remove-Tray {
    if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose(); $script:Tray = $null }
    Unregister-AppHotKey
}
