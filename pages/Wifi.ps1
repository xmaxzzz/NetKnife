# Page: nearby Wi-Fi access points (netsh wlan show networks mode=bssid).

$script:WifiItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:WifiInfo = @{ Count = 0; Nets = 0; Stamp = $null }
$script:WifiScanning = $false

$script:WifiBody = {
    param($Q, $Ctl)
    $Aps = Get-WlanNetworks
    $Cur = Get-WlanInfo
    $Q.Enqueue(@{ Type = "wifi"; Aps = $Aps; MyBssid = $(if ($Cur -and $Cur.Connected) { "$($Cur.Bssid)".ToUpper() } else { "" }) })
}

function New-WifiRow {
    param($A, [string]$MyBssid)
    $Lvl = if ($A.Signal -ge 65) { "high" } elseif ($A.Signal -ge 40) { "mid" } else { "low" }
    $BandCh = (@($A.Band, $(if ($A.Channel) { "ch $($A.Channel)" } else { "" })) | Where-Object { $_ }) -join " · "
    return [pscustomobject]@{
        Ssid = $A.Ssid; Auth = $(if ($A.Auth) { "$($A.Auth) · $($A.Enc)" -replace ' · $','' } else { "—" })
        SignalText = "$($A.Signal)%"; BarWidth = [Math]::Round(40.0 * $A.Signal / 100); Level = $Lvl
        BandCh = $(if ($BandCh) { $BandCh } else { "—" }); Radio = $A.Radio
        Bssid = $A.Bssid; Vendor = $(if ($A.Vendor) { $A.Vendor } else { "—" })
        IsMine = ($MyBssid -and $A.Bssid -eq $MyBssid)
        IsOpen = ($A.Auth -match 'Open|Открыт' -or -not $A.Auth)
        CopyTag = "copy:$($A.Bssid)"; Ap = $A
    }
}

function Get-WifiSub {
    if (-not $script:WifiInfo.Stamp) { return "Соседние точки доступа и их параметры" }
    $Bands = @($script:WifiItems | ForEach-Object { $_.Ap.Band } | Where-Object { $_ } | Sort-Object -Unique)
    $S = "$(Get-Plural $script:WifiInfo.Nets 'сеть' 'сети' 'сетей') · $($script:WifiInfo.Count) BSSID"
    if ($Bands) { $S += " · $($Bands -join ', ')" }
    $S += " · $($script:WifiInfo.Stamp.ToString('HH:mm:ss'))"
    return $S
}

function Set-WifiScanning {
    param([bool]$On)
    $script:WifiScanning = $On
    $Ui.WifiScan.IsEnabled = -not $On
    $Ui.WifiScanGlyph.Text = $(if ($On) { [string][char]0xE72C } else { [string][char]0xE72C })
}

function Start-WifiScan {
    if ($script:WifiScanning) { return }
    Set-WifiScanning $true
    if (-not $script:WifiItems.Count) { $Ui.WifiEmpty.Text = "Сканирую эфир…" }
    [void](Start-Worker -Name "wifi" -Replace -Body $script:WifiBody -OnMessage {
        param($M)
        if ($M.Type -ne "wifi") { return }
        $Sel = $Ui.WifiList.SelectedItem.Bssid
        $script:WifiItems.Clear()
        foreach ($A in $M.Aps) { $script:WifiItems.Add((New-WifiRow $A $M.MyBssid)) }
        $script:WifiInfo = @{ Count = @($M.Aps).Count; Nets = @($M.Aps | ForEach-Object { $_.Ssid } | Sort-Object -Unique).Count; Stamp = [DateTime]::Now }
        $Ui.WifiEmpty.Visibility = $(if ($script:WifiItems.Count) { "Collapsed" } else { "Visible" })
        if (-not $script:WifiItems.Count) { $Ui.WifiEmpty.Text = "Сети не найдены. Если список всегда пустой — включи службу «Определение местоположения» Windows (netsh её требует для перечисления сетей)." }
        if ($Sel) { $Ui.WifiList.SelectedItem = ($script:WifiItems | Where-Object { $_.Bssid -eq $Sel } | Select-Object -First 1) }
        $C = Get-WlanInfo
        if ($C -and $C.Connected) { $Ui.WifiConn.Text = "Подключено: $($C.Ssid)"; $Ui.WifiConnMeta.Text = "$($C.Band) · канал $($C.Channel) · $($C.Radio) · сигнал $($C.Signal)% · BSSID $($C.Bssid)" }
        else { $Ui.WifiConn.Text = "Wi-Fi не подключён"; $Ui.WifiConnMeta.Text = "Соседние точки доступа: сигнал, диапазон, канал, шифрование, производитель по BSSID." }
        Update-PageSub
    } -OnDone { Set-WifiScanning $false })
}

function Initialize-WifiPage {
    $Ui.WifiList.ItemsSource = $script:WifiItems
    $Ui.WifiScan.Add_Click({ Start-WifiScan })
    $Ui.WifiAuto.Add_Checked({ $script:WifiAutoOn = $true; Start-WifiScan })
    $Ui.WifiAuto.Add_Unchecked({ $script:WifiAutoOn = $false })
    $Ui.WifiList.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Копировать BSSID" 0xE8C8 { $R = $Ui.WifiList.SelectedItem; if ($R) { Copy-Text $R.Bssid "BSSID" } } "Ctrl+C")
        (New-MenuItem "Копировать всё (TSV)" 0xE8C8 {
            $Lines = @("SSID`tСигнал`tДиапазон`tКанал`tШифрование`tBSSID`tПроизводитель")
            $Lines += $script:WifiItems | ForEach-Object { "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $_.Ssid, $_.SignalText, $_.Ap.Band, $_.Ap.Channel, $_.Auth, $_.Bssid, $_.Vendor }
            Copy-Text ($Lines -join "`r`n") "$($script:WifiItems.Count) строк"
        })
    )
}

# auto-rescan hook, called from the main pump
$script:WifiAutoSw = [System.Diagnostics.Stopwatch]::StartNew()
function Invoke-WifiPump {
    if (-not $script:WifiAutoOn) { return }
    if ($script:WifiAutoSw.ElapsedMilliseconds -lt 10000) { return }
    $script:WifiAutoSw.Restart()
    if (-not $script:WifiScanning) { Start-WifiScan }
}
