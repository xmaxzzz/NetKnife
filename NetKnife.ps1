# NetKnife — SSH hosts, keys, tunnels + network toolbox (scanner, ports, ping/trace, DNS, monitor, speed test).
# Run: pwsh -STA -File NetKnife.ps1   (shortcut uses conhost --headless to hide the console)
#
# Global: Ctrl+Alt+N show/hide window (tray icon; close button hides to tray, exit via tray menu)
# Hotkeys: Ctrl+1..8 pages · Ctrl+F search/field · Ctrl+L quick ping · F5 refresh/run
#          Hosts: Enter connect · Ctrl+C copy key · Ctrl+T test · Ctrl+E edit · Ctrl+B favorite · Del remove
#          Drag files from Explorer onto a host row → scp dialog
# Data: %APPDATA%\NetKnife\settings.json (favorites, snippets, tunnels, monitor), netknife.log, tunnels.pid

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, Microsoft.VisualBasic, System.Windows.Forms, WindowsFormsIntegration

. (Join-Path $PSScriptRoot "lib\Core.ps1")
. (Join-Path $PSScriptRoot "lib\Net.ps1")
. (Join-Path $PSScriptRoot "lib\Jobs.ps1")
. (Join-Path $PSScriptRoot "lib\Ssh.ps1")

$script:LogPath = Join-Path $script:DataDir "netknife.log"
function Write-AppLog {
    param([string]$Text)
    try {
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir | Out-Null }
        Add-Content -Path $script:LogPath -Value "$(Get-Date -Format 's') $Text" -Encoding UTF8
    } catch { }
}

. (Join-Path $PSScriptRoot "lib\Tray.ps1")
. (Join-Path $PSScriptRoot "lib\Update.ps1")
. (Join-Path $PSScriptRoot "pages\Hosts.ps1")
. (Join-Path $PSScriptRoot "pages\Tunnels.ps1")
. (Join-Path $PSScriptRoot "pages\Vpn.ps1")
. (Join-Path $PSScriptRoot "pages\Conns.ps1")
. (Join-Path $PSScriptRoot "lib\WlanApi.ps1")
. (Join-Path $PSScriptRoot "lib\Ai.ps1")
. (Join-Path $PSScriptRoot "pages\WifiPlan.ps1")
. (Join-Path $PSScriptRoot "pages\Roam.ps1")
. (Join-Path $PSScriptRoot "pages\Monitor.ps1")
. (Join-Path $PSScriptRoot "pages\Wifi.ps1")
. (Join-Path $PSScriptRoot "pages\Terminal.ps1")
. (Join-Path $PSScriptRoot "pages\Scanner.ps1")
. (Join-Path $PSScriptRoot "pages\Ports.ps1")
. (Join-Path $PSScriptRoot "pages\Tools.ps1")
. (Join-Path $PSScriptRoot "pages\Settings.ps1")

# ---------------------------------------------------------------- theme + window

$script:Settings = Get-Settings
$script:ThemeName = "$($script:Settings.Theme)"
if (-not $script:Themes.Contains($script:ThemeName)) { $script:ThemeName = "system" }
if ($script:ThemeName -eq "system") { $script:ThemeName = $(if (Test-SystemDark) { "dark" } else { "light" }) }
if ($script:ThemeName -like "glass*" -and [Environment]::OSVersion.Version.Build -lt 22621) { $script:ThemeName = "dark" }   # acrylic needs Win11 22H2
$script:IsGlass = ($script:ThemeName -like "glass*")
$script:IsDark = ($script:ThemeName -ne "light")
$script:Palette = Get-Palette $script:ThemeName

if ($script:NativeOk) { [void][NetKnife.Native]::SetCurrentProcessExplicitAppUserModelID("Max.NetKnife") }

$MainXaml = Expand-ThemeXaml ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "Main.xaml")))
$script:Win = [System.Windows.Markup.XamlReader]::Parse($MainXaml)
$Win = $script:Win
$Win.Background = $Win.FindResource("WindowBg")
$Win.Foreground = $Win.FindResource("Text")

$script:Ui = @{}
foreach ($M in [regex]::Matches($MainXaml, 'x:Name="([^"]+)"')) {
    $N = $M.Groups[1].Value
    if (-not $script:Ui.ContainsKey($N)) {
        $El = $Win.FindName($N)
        if ($El) { $script:Ui[$N] = $El }
    }
}
$Ui = $script:Ui

$IconPath = Join-Path $PSScriptRoot "NetKnife.ico"
if (Test-Path $IconPath) {
    try {
        $Win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$IconPath)
        $Dec = New-Object System.Windows.Media.Imaging.IconBitmapDecoder ([Uri]$IconPath), "None", "OnLoad"
        $Ui.LogoImg.Source = ($Dec.Frames | Sort-Object PixelWidth | Where-Object { $_.PixelWidth -ge 64 } | Select-Object -First 1)
    } catch { Write-AppLog "icon: $_" }
}

$Win.Add_SourceInitialized({
    $Mica = [Environment]::OSVersion.Version.Build -ge 22621
    try { Set-WindowChrome $Win $Mica } catch { Write-AppLog "chrome: $_" }
})

$Win.Dispatcher.Add_UnhandledException({
    param($S, $E)
    Write-AppLog "unhandled: $($E.Exception)"
    try { Show-Toast "Ошибка: $($E.Exception.Message)" "fail" } catch { }
    $E.Handled = $true
})

# ---------------------------------------------------------------- navigation

# order = sidebar order = Ctrl+1..8
$script:Pages = [ordered]@{
    scan  = @{ Panel = "PageScan";  Nav = "NavScan";  Title = "Сканер сети";        Sub = { Get-ScanSub };  Focus = "ScanRange" }
    ports = @{ Panel = "PagePorts"; Nav = "NavPorts"; Title = "Порты";              Sub = { Get-PortsSub }; Focus = "PortTarget" }
    ping  = @{ Panel = "PagePing";  Nav = "NavPing";  Title = "Пинг и трассировка"; Sub = { Get-PingSub };  Focus = "PingTarget" }
    dns   = @{ Panel = "PageDns";   Nav = "NavDns";   Title = "DNS";                Sub = { Get-DnsSub };   Focus = "DnsName" }
    wifi  = @{ Panel = "PageWifi";  Nav = "NavWifi";  Title = "Wi-Fi";              Sub = { Get-WifiSub };  Focus = "WifiScan" }
    wplan = @{ Panel = "PageWplan"; Nav = "NavWplan"; Title = "Wi-Fi план";         Sub = { Get-WplanSub }; Focus = "WpRoom" }
    roam  = @{ Panel = "PageRoam";  Nav = "NavRoam";  Title = "Монитор роуминга";   Sub = { Get-RoamSub };  Focus = "RoamStart" }
    monitor = @{ Panel = "PageMonitor"; Nav = "NavMonitor"; Title = "Монитор";      Sub = { Get-MonitorSub }; Focus = "MonTarget" }
    vpn   = @{ Panel = "PageVpn";   Nav = "NavVpn";   Title = "VPN";                Sub = { Get-VpnSub };   Focus = "VpnList" }
    conns = @{ Panel = "PageConns"; Nav = "NavConns"; Title = "Соединения программ"; Sub = { Get-ConnsSub }; Focus = "ConnProc" }
    hosts = @{ Panel = "PageHosts"; Nav = "NavHosts"; Title = "Хосты";              Sub = { Get-HostsSub }; Focus = "HostSearch" }
    keys  = @{ Panel = "PageKeys";  Nav = "NavKeys";  Title = "Ключи";              Sub = { Get-KeysSub };  Focus = "KeySearch" }
    tunnels = @{ Panel = "PageTunnels"; Nav = "NavTunnels"; Title = "Туннели";      Sub = { Get-TunnelsSub }; Focus = "TunnelList" }
    terminal = @{ Panel = "PageTerminal"; Nav = "NavTerminal"; Title = "Терминал";  Sub = { Get-TerminalSub }; Focus = "TermPwsh" }
    settings = @{ Panel = "PageSettings"; Nav = "NavSettings"; Title = "Настройки"; Sub = { "Поведение приложения и данные" }; Focus = "SetStartupPage" }
}
$script:Page = "hosts"
$script:Navigating = $false

function Set-Page {
    param([string]$Name)
    if (-not $script:Pages.Contains($Name)) { return }
    $script:Page = $Name
    foreach ($K in $script:Pages.get_Keys()) {
        $Ui[$script:Pages[$K].Panel].Visibility = $(if ($K -eq $Name) { "Visible" } else { "Collapsed" })
    }
    $Ui.HostsTools.Visibility = $(if ($Name -eq "hosts") { "Visible" } else { "Collapsed" })
    $Ui.KeysTools.Visibility = $(if ($Name -eq "keys") { "Visible" } else { "Collapsed" })
    $Ui.PageTitle.Text = $script:Pages[$Name].Title
    if ($Name -eq "terminal") { Show-TerminalPage }
    $script:Navigating = $true
    $Ui[$script:Pages[$Name].Nav].IsChecked = $true
    $script:Navigating = $false
    Update-PageSub
}

function Update-PageSub {
    try { $Ui.PageSub.Text = & $script:Pages[$script:Page].Sub } catch { $Ui.PageSub.Text = "" }
}

foreach ($K in $script:Pages.get_Keys()) {
    $Nav = $Ui[$script:Pages[$K].Nav]
    $Nav.Tag = $null
    $Nav.Resources["PageKey"] = $K
    $Nav.Add_Checked({
        param($S, $E)
        if (-not $script:Navigating) { Set-Page $S.Resources["PageKey"] }
    })
}

# ---------------------------------------------------------------- tag actions (badges, chips)

function Invoke-TagAction {
    param([string]$Tag)
    if ($Tag -notmatch '^(\w+):(.*)$') { return $false }
    $Kind = $Matches[1]; $Val = $Matches[2]
    switch ($Kind) {
        "url"   { Start-Process $Val; Show-Toast "Открываю $Val" "info" }
        "ssh"   { Connect-Host $Val }
        "sship" { $P = $Val -split ':'; $Port = if ($P[1] -and $P[1] -ne "22") { " -p $($P[1])" } else { "" }; Start-Terminal "ssh$Port root@$($P[0])" $P[0] }
        "rdp"   { Start-Process mstsc.exe -ArgumentList "/v:$Val" }
        "smb"   { Start-Process explorer.exe -ArgumentList "\\$Val" }
        "copy"  { Copy-Text $Val $Val }
        "ports" { Start-PortScanFor $Val "std" }
        "scan"  { Start-NetScan $Val }
        "tun"   { Invoke-TunnelAction $Val }
        "vpn"   { Invoke-VpnAction $Val }
        "mon"   { Invoke-MonAction $Val }
        "host"  {
            Set-Page "hosts"
            $Ui.HostSearch.Text = ""
            $R = $script:HostItems | Where-Object { $_.Alias -eq $Val } | Select-Object -First 1
            if ($R) { $Ui.HostList.SelectedItem = $R; $Ui.HostList.ScrollIntoView($R) }
        }
        default { return $false }
    }
    return $true
}

$Win.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($S, $E)
    $Src = $E.OriginalSource
    if ($Src -is [System.Windows.Controls.Button] -and $Src.Tag -is [string] -and $Src.Tag) {
        if (Invoke-TagAction $Src.Tag) { $E.Handled = $true }
    }
})

# ---------------------------------------------------------------- hotkeys

$Win.Add_PreviewKeyDown({
    param($S, $E)
    $Ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $Key = "$($E.Key)"
    $InText = [System.Windows.Input.Keyboard]::FocusedElement -is [System.Windows.Controls.TextBox]

    if ($Ctrl -and $Key -match '^D([1-9])$') { $Idx = [int]$Matches[1] - 1; $Ks = @($script:Pages.get_Keys()); if ($Idx -lt $Ks.Count) { Set-Page $Ks[$Idx] }; $E.Handled = $true; return }
    if ($Ctrl -and $Key -eq "F") { $T = $Ui[$script:Pages[$script:Page].Focus]; [void]$T.Focus(); if ($T -is [System.Windows.Controls.TextBox]) { $T.SelectAll() }; $E.Handled = $true; return }
    if ($Ctrl -and $Key -eq "L") { [void]$Ui.QuickPing.Focus(); $E.Handled = $true; return }
    if ($Key -eq "F5") {
        switch ($script:Page) { "hosts" { Refresh-Ssh; Show-Toast "Перечитано" } "keys" { Refresh-Ssh; Show-Toast "Перечитано" } "tunnels" { Refresh-Tunnels } "vpn" { Refresh-Vpn } "monitor" { Start-Monitor; Show-Toast "Монитор перезапущен" "info" } "wifi" { Start-WifiScan } "scan" { Start-NetScan } "ports" { Start-PortScan } "ping" { Start-Ping } "dns" { Start-DnsQuery } }
        $E.Handled = $true; return
    }
    if ($Key -eq "Escape" -and $InText) {
        $F = [System.Windows.Input.Keyboard]::FocusedElement
        if ($F -eq $Ui.HostSearch -or $F -eq $Ui.KeySearch -or $F -eq $Ui.QuickPing) { $F.Text = ""; $E.Handled = $true }
        return
    }
    if ($InText) {
        if (($Key -eq "Down") -and ([System.Windows.Input.Keyboard]::FocusedElement -eq $Ui.HostSearch)) { [void]$Ui.HostList.Focus(); $E.Handled = $true }
        return
    }

    switch ($script:Page) {
        "hosts" {
            $H = Get-SelectedHost
            if (-not $H) { return }
            if ($Key -eq "Return") { Connect-Host $H.Alias; $E.Handled = $true }
            elseif ($Ctrl -and $Key -eq "C") { $Kk = Find-KeyForHost $H; Copy-Text $Kk.PubText "ключ $($Kk.Name)"; $E.Handled = $true }
            elseif ($Ctrl -and $Key -eq "T") { Start-SshTest (Get-SelectedAliases); $E.Handled = $true }
            elseif ($Ctrl -and $Key -eq "E") { Show-EditHostDialog $H; $E.Handled = $true }
            elseif ($Ctrl -and $Key -eq "B") { Toggle-Favorite $H.Alias; $E.Handled = $true }
            elseif ($Key -eq "Delete") { Remove-HostBlock $H; $E.Handled = $true }
        }
        "keys" {
            $Kk = Get-SelectedKey
            if (-not $Kk) { return }
            if ($Key -eq "Return" -or ($Ctrl -and $Key -eq "C")) { Copy-Text $Kk.PubText "ключ $($Kk.Name)"; $E.Handled = $true }
            elseif ($Key -eq "Delete") { Remove-KeyFiles $Kk; $E.Handled = $true }
        }
        "scan" {
            $R = Get-SelectedScan
            if (-not $R) { return }
            if ($Key -eq "Return") { Start-PortScanFor $R.Ip "std"; $E.Handled = $true }
            elseif ($Ctrl -and $Key -eq "C") { Copy-Text $R.Ip $R.Ip; $E.Handled = $true }
        }
        "tunnels" {
            $T = Get-SelectedTunnel
            if (-not $T) { return }
            if ($Key -eq "Return") { Invoke-TunnelAction "toggle:$($T.Id)"; $E.Handled = $true }
            elseif ($Key -eq "Delete") { Remove-Tunnel $T; $E.Handled = $true }
        }
        "monitor" {
            $R = $Ui.MonList.SelectedItem
            if ($R -and $Key -eq "Delete") { Remove-MonTarget $R.Id; $E.Handled = $true }
        }
    }
})

# ---------------------------------------------------------------- theme switch

# footer button: pick a theme from the full list (same as Settings)
$Ui.ThemeBtn.Add_Click({
    param($S, $E)
    $Items = foreach ($K in $script:Themes.Keys) {
        $I = New-MenuItem $script:Themes[$K] $(if ($K -eq "$($script:Settings.Theme)") { 0xE73E } else { 0xE790 })
        $I.Tag = $K
        $I.Add_Click({ param($S2, $E2) if ("$($script:Settings.Theme)" -ne $S2.Tag) { $script:Settings.Theme = $S2.Tag; Save-Settings; Restart-App } })
        $I
    }
    Show-Menu $S $Items
})
$Ui.ThemeBtn.ToolTip = "Тема: $($script:Themes["$($script:Settings.Theme)"]) — клик открывает список"

# ---------------------------------------------------------------- init

$script:LocalNets = @(Get-LocalNets)

Initialize-HostsPage
Initialize-TunnelsPage
Initialize-VpnPage
Initialize-ConnsPage
Initialize-WifiPlanPage
Initialize-RoamPage
Initialize-TerminalPage
Initialize-MonitorPage
Initialize-WifiPage
Initialize-ScannerPage
Initialize-PortsPage
Initialize-ToolsPages
Initialize-SettingsPage

$Pump = New-Object System.Windows.Threading.DispatcherTimer
$Pump.Interval = [TimeSpan]::FromMilliseconds(120)
$Pump.Add_Tick({
    try { Invoke-WorkerPump } catch { Write-AppLog "pump: $_ $($_.ScriptStackTrace)" }
    try { Invoke-TunnelPump } catch { Write-AppLog "tunnel pump: $_ $($_.ScriptStackTrace)" }
    try { Invoke-VpnPump } catch { Write-AppLog "vpn pump: $_ $($_.ScriptStackTrace)" }
    try { Invoke-WifiPump } catch { Write-AppLog "wifi pump: $_ $($_.ScriptStackTrace)" }
    foreach ($P in @($script:EngineProcs)) {
        if ($P.HasExited) {
            $script:EngineProcs.Remove($P) | Out-Null
            Refresh-Ssh
            Show-Toast "Окно ssh-key.ps1 закрыто — список обновлён" "info"
        }
    }
})

$StatusTimer = New-Object System.Windows.Threading.DispatcherTimer
$StatusTimer.Interval = [TimeSpan]::FromSeconds(90)
$StatusTimer.Add_Tick({ Start-NetStatus })

$PerfTimer = New-Object System.Windows.Threading.DispatcherTimer
$PerfTimer.Interval = [TimeSpan]::FromSeconds(2)
$PerfTimer.Add_Tick({ try { Update-SystemLoad } catch { } })

$Win.Add_ContentRendered({
    try {
        Refresh-Ssh
        $Start = "$($script:Settings.StartupPage)"
        if (-not $script:Pages.Contains($Start)) { $Start = "hosts" }
        Set-Page $Start
        $Pump.Start()
        $StatusTimer.Start()
        Update-SystemLoad; $PerfTimer.Start()
        Start-NetStatus
        Start-WebProbe
        Start-AutoTunnels
        try { Initialize-Tray; if ($script:Settings.HotKey) { Register-AppHotKey } } catch { Write-AppLog "tray: $_" }
        if ($script:Settings.AutoUpdateCheck) { try { Start-UpdateCheck } catch { Write-AppLog "update: $_" } }
        [void]$Ui.HostList.Focus()
    } catch {
        Write-AppLog "startup: $_ $($_.ScriptStackTrace)"
        Show-Toast "Ошибка запуска: $_" "fail"
    }
})

$Win.Add_Closing({
    param($S, $E)
    if ($script:Settings.MinimizeToTray -and -not $script:ReallyExit -and $script:Tray) {
        $E.Cancel = $true
        Hide-MainWindow
        return
    }
    $Pump.Stop(); $StatusTimer.Stop(); $PerfTimer.Stop()
    foreach ($W in @($script:Workers)) { $W.Ctl.Stop = $true }
    Stop-AllTunnels
    Stop-Vpn -Quiet
    Stop-Worker "conns"
    try { Stop-RoamMonitor -Quiet } catch { }
    Stop-TermSession
    Stop-ChildJob
    Save-TunnelPids
})

# Show + Dispatcher.Run instead of ShowDialog: hiding to tray must not end the message loop
$Win.Add_Closed({ try { $script:Win.Dispatcher.InvokeShutdown() } catch { } })
$Win.Show()
[System.Windows.Threading.Dispatcher]::Run()
Remove-Tray
Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
