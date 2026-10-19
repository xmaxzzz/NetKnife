# Page: Wi-Fi planner for Omada (or any) access points. Walk the site with the laptop, take a measurement in
# each room; the planner groups BSSIDs into physical APs, builds a room × AP coverage matrix per band and
# recommends transmit power, channels/width and roaming settings so that each room has one clearly dominant AP
# and neighbours are heard at the cell edge around −67 dBm. Values are entered into the controller by hand.
# One plan per site: %APPDATA%\NetKnife\wifiplan\<site>.json

$script:WplanDir = Join-Path $script:DataDir "wifiplan"
$script:Wplan = $null              # current plan (hashtable)
$script:WplanPointItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:WplanApItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:WplanBusy = $false
$script:WplanLastReport = $null    # structured result of the last calculation (for AI / sheet)

# Planning targets (dBm)
$script:WpEdge = @{ "5" = -67; "2.4" = -67 }      # weakest acceptable signal of the serving AP in its own room
$script:WpMargin = 8                               # in a foreign room a neighbour AP should be at least this many dB below the serving one
$script:WpTxMax = @{ "5" = 23; "2.4" = 20 }
$script:WpTxMin = 3

# ---------------------------------------------------------------- storage

function Get-WplanPath { param([string]$Site) return Join-Path $script:WplanDir ("{0}.json" -f ($Site -replace '[\\/:*?"<>|]', '_')) }

function Get-WplanSites {
    if (-not (Test-Path $script:WplanDir)) { return @() }
    return @(Get-ChildItem $script:WplanDir -Filter *.json | Sort-Object LastWriteTime -Descending | ForEach-Object { $_.BaseName })
}

function New-Wplan { param([string]$Site) return @{ Site = $Site; Ssids = @(); Aps = @{}; Merge = @{}; Points = @() } }

function Read-Wplan {
    param([string]$Site)
    $P = Get-WplanPath $Site
    if (Test-Path $P) {
        try {
            $W = Get-Content $P -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            foreach ($K in @("Ssids", "Points")) { if (-not $W[$K]) { $W[$K] = @() } }
            foreach ($K in @("Aps", "Merge")) { if (-not $W[$K]) { $W[$K] = @{} } }
            $W.Site = $Site
            return $W
        } catch { Write-AppLog "wplan read ${Site}: $_" }
    }
    return New-Wplan $Site
}

function Save-Wplan {
    if (-not $script:Wplan) { return }
    if (-not (Test-Path $script:WplanDir)) { New-Item -ItemType Directory -Path $script:WplanDir | Out-Null }
    $script:Wplan | ConvertTo-Json -Depth 8 | Set-Content -Path (Get-WplanPath $script:Wplan.Site) -Encoding UTF8
    $script:Settings.WplanSite = $script:Wplan.Site; Save-Settings
}

# ---------------------------------------------------------------- grouping BSSIDs into physical APs
# Omada: 2.4 GHz radio = base MAC, 5 GHz = base+1, extra SSIDs flip bits in the first octet. So the group key
# ignores the first octet and the 3 low bits of the last one. Manual merges (plan.Merge) override.

function Get-WplanKey {
    param([string]$Bssid)
    $O = $Bssid.ToUpper() -split '[:-]'
    if ($O.Count -ne 6) { return $Bssid }
    $Last = [Convert]::ToInt32($O[5], 16) -band 0xF8
    $K = "{0}:{1}:{2}:{3}:{4:X2}" -f $O[1], $O[2], $O[3], $O[4], $Last
    $M = $script:Wplan.Merge
    $Guard = 0
    while ($M -and $M.ContainsKey($K) -and $Guard -lt 8) { $K = $M[$K]; $Guard++ }
    return $K
}

function Test-WplanOurs {
    param($S)
    $Ss = @($script:Wplan.Ssids | Where-Object { $_ })
    if ($Ss.Count) { return ($Ss -contains $S.Ssid) }
    return ((Get-MacVendor $S.Bssid) -match 'TP-?Link|Omada')
}

function Get-WplanApName {
    param([string]$Key)
    $A = $script:Wplan.Aps[$Key]
    if ($A -and $A.Name) { return $A.Name }
    return "AP " + (($Key -split ':' | Select-Object -Last 2) -join ':')
}

# ---------------------------------------------------------------- scan worker

$script:WplanScanBody = {
    param($Q, $Ctl, $Rounds)
    $Acc = @{}
    for ($i = 1; $i -le $Rounds; $i++) {
        if ($Ctl.Stop) { return }
        try { $L = [NetKnife.Wlan]::Scan(3200) } catch { $Q.Enqueue(@{ Type = "wpscan"; Error = "$($_.Exception.Message)" }); return }
        foreach ($B in $L) {
            if (-not $Acc.ContainsKey($B.Bssid)) { $Acc[$B.Bssid] = @{ Bssid = $B.Bssid; Ssid = $B.Ssid; Ch = $B.Channel; Band = $B.Band; R = [System.Collections.Generic.List[int]]::new() } }
            $Acc[$B.Bssid].R.Add($B.Rssi)
        }
        $Q.Enqueue(@{ Type = "wpround"; N = $i; Total = $Rounds; Count = $Acc.Count })
    }
    $Out = foreach ($A in $Acc.Values) {
        $S = @($A.R | Sort-Object)
        @{ Bssid = $A.Bssid; Ssid = $A.Ssid; Ch = $A.Ch; Band = $A.Band; Rssi = $S[[int][Math]::Floor(($S.Count - 1) / 2)]; Seen = $S.Count }
    }
    $Q.Enqueue(@{ Type = "wpscan"; Samples = @($Out) })
}

function Start-WplanMeasure {
    if ($script:WplanBusy) { return }
    $Room = $Ui.WpRoom.Text.Trim()
    if (-not $Room) { Show-Toast "Назови место замера (комната)" "warn"; [void]$Ui.WpRoom.Focus(); return }
    Use-WplanSite
    $script:WplanBusy = $true
    $Ui.WpMeasure.IsEnabled = $false
    $Ui.WpStatus.Text = "Замер «$Room»: сканирую эфир (3 прохода, ~12 с) — не двигайся…"
    [void](Start-Worker -Name "wplan-scan" -Replace -Body $script:WplanScanBody -ArgList @(3) -State @{ Room = $Room } -OnMessage {
        param($M)
        switch ($M.Type) {
            "wpround" { $Ui.WpStatus.Text = "Замер «$($State.Room)»: проход $($M.N)/$($M.Total), видно BSSID: $($M.Count)" }
            "wpscan" {
                $script:WplanBusy = $false
                $Ui.WpMeasure.IsEnabled = $true
                if ($M.Error) { $Ui.WpStatus.Text = "Скан не удался: $($M.Error)"; Show-Toast "Wi-Fi скан: $($M.Error)" "fail"; return }
                $Pt = @{ Room = $State.Room; Time = (Get-Date -Format "yyyy-MM-dd HH:mm"); Samples = @($M.Samples) }
                $script:Wplan.Points = @($script:Wplan.Points) + @($Pt)
                Register-WplanAps @($M.Samples)
                Save-Wplan
                Refresh-Wplan
                $Ours = @($M.Samples | Where-Object { Test-WplanOurs $_ })
                $Best = $Ours | Sort-Object { $_.Rssi } -Descending | Select-Object -First 1
                $Ui.WpStatus.Text = "«$($State.Room)» записан: своих BSSID $($Ours.Count) из $(@($M.Samples).Count)" + $(if ($Best) { " · лучший $(Get-WplanApName (Get-WplanKey $Best.Bssid)) $($Best.Rssi) dBm ($($Best.Band) ГГц)" } else { " · своих точек не видно — проверь SSID объекта" })
                $Ui.WpRoom.Text = ""; [void]$Ui.WpRoom.Focus()
            }
        }
    })
}

# new physical APs seen in a measurement get an entry (name filled in by the user later)
function Register-WplanAps {
    param($Samples)
    foreach ($S in @($Samples)) {
        if (-not (Test-WplanOurs $S)) { continue }
        $K = Get-WplanKey $S.Bssid
        if (-not $script:Wplan.Aps.ContainsKey($K)) { $script:Wplan.Aps[$K] = @{ Name = ""; Tx24 = ""; Tx5 = ""; Bssids = @() } }
        $A = $script:Wplan.Aps[$K]
        if (@($A.Bssids) -notcontains $S.Bssid) { $A.Bssids = @($A.Bssids) + @($S.Bssid) }
    }
}

# ---------------------------------------------------------------- analysis

# room → band → apKey → averaged dBm (missing points count as −95 so a room is judged on all its points)
function Get-WplanMatrix {
    $Rooms = [ordered]@{}
    foreach ($P in @($script:Wplan.Points)) { if (-not $Rooms.Contains($P.Room)) { $Rooms[$P.Room] = [System.Collections.Generic.List[object]]::new() }; $Rooms[$P.Room].Add($P) }
    $M = @{ "2.4" = @{}; "5" = @{} }
    $Keys = [System.Collections.Generic.HashSet[string]]::new()
    $Chan = @{ "2.4" = @{}; "5" = @{} }       # apKey → observed channel
    $Foreign = @{ "2.4" = @{}; "5" = @{} }    # channel → strongest foreign dBm seen anywhere
    foreach ($R in $Rooms.Keys) {
        foreach ($B in @("2.4", "5")) {
            $Sum = @{}
            foreach ($P in $Rooms[$R]) {
                $Best = @{}
                foreach ($S in @($P.Samples)) {
                    if ($S.Band -ne $B) { continue }
                    if (-not (Test-WplanOurs $S)) {
                        $F = $Foreign[$B]; $C = [int]$S.Ch
                        if (-not $F.ContainsKey($C) -or $F[$C] -lt [int]$S.Rssi) { $F[$C] = [int]$S.Rssi }
                        continue
                    }
                    $K = Get-WplanKey $S.Bssid
                    [void]$Keys.Add($K)
                    $Chan[$B][$K] = [int]$S.Ch
                    if (-not $Best.ContainsKey($K) -or $Best[$K] -lt [int]$S.Rssi) { $Best[$K] = [int]$S.Rssi }
                }
                foreach ($K in $Best.Keys) { if (-not $Sum.ContainsKey($K)) { $Sum[$K] = [System.Collections.Generic.List[int]]::new() }; $Sum[$K].Add($Best[$K]) }
            }
            $Row = @{}
            $N = $Rooms[$R].Count
            foreach ($K in $Sum.Keys) {
                $V = $Sum[$K]; $Tot = 0; foreach ($X in $V) { $Tot += $X }
                $Tot += (-95) * ($N - $V.Count)
                $Avg = [int][Math]::Round($Tot / $N)
                if ($Avg -gt -90) { $Row[$K] = $Avg }
            }
            $M[$B][$R] = $Row
        }
    }
    return @{ Rooms = @($Rooms.Keys); Keys = @($Keys | Sort-Object { Get-WplanApName $_ }); S = $M; Chan = $Chan; Foreign = $Foreign }
}

function Get-WplanBandPlan {
    param($Mx, [string]$B)
    $S = $Mx.S[$B]
    $Keys = @($Mx.Keys | Where-Object { $K = $_; @($Mx.Rooms | Where-Object { $S[$_].ContainsKey($K) }).Count })
    $Res = [ordered]@{}
    $BestOf = @{}
    foreach ($R in $Mx.Rooms) {
        $Row = $S[$R]
        $Bk = $null; $Bv = -999
        foreach ($K in $Row.Keys) { if ($Row[$K] -gt $Bv) { $Bv = $Row[$K]; $Bk = $K } }
        $BestOf[$R] = @{ Key = $Bk; Val = $Bv }
    }
    foreach ($K in $Keys) {
        $Cell = @($Mx.Rooms | Where-Object { $BestOf[$_].Key -eq $K })
        $Edge = $null; foreach ($R in $Cell) { $V = $S[$R][$K]; if ($null -eq $Edge -or $V -lt $Edge) { $Edge = $V } }
        $Excess = 0; $ExRoom = ""
        foreach ($R in $Mx.Rooms) {
            if ($Cell -contains $R -or -not $S[$R].ContainsKey($K)) { continue }
            $Allowed = $BestOf[$R].Val - $script:WpMargin
            $E = $S[$R][$K] - $Allowed
            if ($E -gt $Excess) { $Excess = $E; $ExRoom = $R }
        }
        $Deficit = $(if ($null -ne $Edge -and $Edge -lt $script:WpEdge[$B]) { $script:WpEdge[$B] - $Edge } else { 0 })
        # never cut so much that the AP's own rooms drop below the edge target
        $Headroom = $(if ($null -ne $Edge) { [Math]::Max(0, $Edge - $script:WpEdge[$B]) } else { 10 })
        $Note = ""
        if (-not $Cell.Count) { $Delta = -[Math]::Max(3, $Excess); $Note = "нигде не лучшая — лишняя на этом диапазоне или стоит неудачно" }
        elseif ($Deficit -gt 0 -and $Excess -gt 0) { $Delta = [int][Math]::Round(($Deficit - $Excess) / 2); $Note = "конфликт: слабо в своей зоне и громко в «$ExRoom» — нужна точка между/перенос" }
        elseif ($Deficit -gt 0) { $Delta = [Math]::Min(6, $Deficit); $Note = "добавить: в своей зоне до $Edge dBm" }
        elseif ($Excess -gt 0 -and $Headroom -ge 1) {
            $Cut = [Math]::Min(10, [Math]::Min($Excess, $Headroom)); $Delta = -$Cut
            $Note = $(if ($Cut -lt $Excess) { "убавить, сколько позволяет своя зона; «$ExRoom» всё равно перекрыт — разведи каналами" } else { "убавить: перекрывает «$ExRoom»" })
        }
        elseif ($Excess -gt 0) { $Delta = 0; $Note = "громко в «$ExRoom», но убавлять некуда (край своей зоны $Edge dBm) — разведи каналами" }
        elseif ($Headroom -gt 8) { $Delta = -[Math]::Min(6, $Headroom - 8); $Note = "запас по мощности — можно тише" }
        else { $Delta = 0; $Note = "в норме" }
        $Cur = $script:Wplan.Aps[$K]["Tx" + ($B -replace '\.', '')]
        $Rec = $null
        if ("$Cur" -match '^\d+$') { $Rec = [Math]::Max($script:WpTxMin, [Math]::Min($script:WpTxMax[$B], [int]$Cur + $Delta)) }
        $Res[$K] = [ordered]@{ Key = $K; Name = (Get-WplanApName $K); Cell = $Cell; Edge = $Edge; Excess = $Excess; Delta = [int]$Delta; Cur = "$Cur"; Rec = $Rec; Note = $Note; Ch = $Mx.Chan[$B][$K] }
    }
    # 2.4 GHz a few dB under 5 GHz pushes dual-band clients to 5 GHz (band steering helps, power balance seals it)
    return @{ Aps = $Res; BestOf = $BestOf }
}

# Greedy channel assignment: conflict weight between two of our APs = how strongly both are heard in the same rooms;
# foreign networks on a channel add a penalty.
function Get-WplanChannels {
    param($Mx, [string]$B, [switch]$Dfs)
    $S = $Mx.S[$B]
    $Keys = @($Mx.Keys | Where-Object { $K = $_; @($Mx.Rooms | Where-Object { $S[$_].ContainsKey($K) }).Count })
    $N = $Keys.Count
    if ($B -eq "2.4") { $Opts = @(1, 6, 11); $Width = 20 }
    else {
        $Width = $(if ($N -le 2) { 80 } elseif ($N -le 6) { 40 } else { 20 })
        $Blocks = switch ($Width) {
            80 { @(@(36, 40, 44, 48), @(149, 153, 157, 161)) + $(if ($Dfs) { @(@(52, 56, 60, 64), @(100, 104, 108, 112), @(116, 120, 124, 128)) } else { @() }) }
            40 { @(@(36, 40), @(44, 48), @(149, 153), @(157, 161)) + $(if ($Dfs) { @(@(52, 56), @(60, 64), @(100, 104), @(108, 112), @(116, 120), @(124, 128), @(132, 136)) } else { @() }) }
            default { @(36, 40, 44, 48, 149, 153, 157, 161 | ForEach-Object { , @($_) }) + $(if ($Dfs) { @(52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128 | ForEach-Object { , @($_) }) } else { @() }) }
        }
        $Opts = @($Blocks | ForEach-Object { , $_ })
    }
    $W = @{}
    foreach ($A in $Keys) { foreach ($C in $Keys) {
        if ($A -eq $C) { continue }
        $Sum = 0
        foreach ($R in $Mx.Rooms) { if ($S[$R].ContainsKey($A) -and $S[$R].ContainsKey($C)) { $Sum += [Math]::Max(0, [Math]::Min($S[$R][$A], $S[$R][$C]) + 85) } }
        $W["$A|$C"] = $Sum
    } }
    $Deg = @{}; foreach ($A in $Keys) { $T = 0; foreach ($C in $Keys) { if ($A -ne $C) { $T += $W["$A|$C"] } }; $Deg[$A] = $T }
    $Assign = @{}
    foreach ($A in @($Keys | Sort-Object { -$Deg[$_] })) {
        $BestCost = [double]::MaxValue; $BestOpt = $null
        foreach ($O in $Opts) {
            $Chs = @($O)
            $Cost = 0
            foreach ($C in $Assign.Keys) { if (@($Assign[$C]) | Where-Object { $Chs -contains $_ }) { $Cost += $W["$A|$C"] + 0.5 } }   # +0.5: spread over free channels when nothing conflicts
            foreach ($Ch in $Chs) { if ($Mx.Foreign[$B].ContainsKey($Ch)) { $Cost += [Math]::Max(0, $Mx.Foreign[$B][$Ch] + 90) * 0.5 } }
            if ($B -eq "2.4") { foreach ($Ch in $Mx.Foreign[$B].Keys) { if ([Math]::Abs($Ch - $Chs[0]) -in 1..4) { $Cost += [Math]::Max(0, $Mx.Foreign[$B][$Ch] + 90) * 0.7 } } }   # partially overlapping foreign 2.4 channels hurt more
            if ($Cost -lt $BestCost) { $BestCost = $Cost; $BestOpt = $Chs }
        }
        $Assign[$A] = $BestOpt
    }
    return @{ Width = $Width; Assign = $Assign }
}

function Format-WplanDelta { param([int]$D) if ($D -gt 0) { return "+$D dB" } elseif ($D -lt 0) { return "$D dB" } else { return "0" } }

function Get-WplanReport {
    if (-not @($script:Wplan.Points).Count) { return "Нет замеров. Встань в комнату, введи её название и нажми «Замер здесь». Обойди все помещения, включая края зон (лестница, балкон, дальняя спальня)." }
    $Mx = Get-WplanMatrix
    if (-not $Mx.Keys.Count) { return "В замерах нет своих точек. Укажи SSID объекта (через запятую) — сейчас они определяются по SSID, а при пустом поле — по производителю TP-Link." }
    $Dfs = [bool]$Ui.WpDfs.IsChecked
    $Out = [System.Text.StringBuilder]::new()
    $Struct = [ordered]@{ Site = $script:Wplan.Site; Rooms = $Mx.Rooms; Bands = [ordered]@{} }
    [void]$Out.AppendLine("ОБЪЕКТ: $($script:Wplan.Site)   замеров: $(@($script:Wplan.Points).Count)   помещений: $($Mx.Rooms.Count)   точек: $($Mx.Keys.Count)")
    [void]$Out.AppendLine("Цели: в своей комнате ≥ $($script:WpEdge['5']) dBm; соседняя точка в чужой комнате — минимум на $($script:WpMargin) dB тише основной.")
    foreach ($B in @("5", "2.4")) {
        $Plan = Get-WplanBandPlan $Mx $B
        if (-not $Plan.Aps.Count) { continue }
        $Ch = Get-WplanChannels $Mx $B -Dfs:$Dfs
        $Struct.Bands[$B] = @{ Matrix = $Mx.S[$B]; Plan = $Plan.Aps; Channels = $Ch }
        [void]$Out.AppendLine("")
        [void]$Out.AppendLine("━━━ $B ГГц ━━━")
        $Keys = @($Plan.Aps.Keys)
        $W = [Math]::Max(14, (@($Mx.Rooms | ForEach-Object { $_.Length }) | Measure-Object -Maximum).Maximum + 2)
        $Hdr = "".PadRight($W) + (($Keys | ForEach-Object { $N = Get-WplanApName $_; if ($N.Length -gt 10) { $N = $N.Substring(0, 10) }; $N.PadLeft(11) }) -join "")
        [void]$Out.AppendLine($Hdr)
        foreach ($R in $Mx.Rooms) {
            $Line = $R.PadRight($W)
            $Bk = $Plan.BestOf[$R].Key
            foreach ($K in $Keys) {
                $V = $Mx.S[$B][$R][$K]
                $Cellv = $(if ($null -eq $V) { "·" } else { "$V$(if ($K -eq $Bk) { '*' } else { ' ' })" })
                $Line += $Cellv.PadLeft(11)
            }
            $BV = $Plan.BestOf[$R].Val
            if ($BV -lt -75) { $Line += "   ← дыра" } elseif ($BV -lt $script:WpEdge[$B]) { $Line += "   ← слабо" }
            [void]$Out.AppendLine($Line)
        }
        [void]$Out.AppendLine("(* — основная точка комнаты; · — не слышно)")
        [void]$Out.AppendLine("")
        foreach ($K in $Keys) {
            $A = $Plan.Aps[$K]
            $NewCh = ($Ch.Assign[$K] | Select-Object -First 1)
            $ChTxt = $(if ($B -eq "2.4") { "канал $NewCh" } else { "канал $NewCh / $($Ch.Width) МГц" })
            $Pw = $(if ($null -ne $A.Rec) { "мощность $($A.Cur) → $($A.Rec) dBm (Custom)" } else { "мощность $(Format-WplanDelta $A.Delta) от текущей (впиши текущую в карточку точки)" })
            [void]$Out.AppendLine(("{0,-14} {1}; {2}; сейчас кан. {3}" -f $A.Name, $ChTxt, $Pw, $(if ($A.Ch) { $A.Ch } else { "?" })))
            [void]$Out.AppendLine(("{0,-14}   зона: {1}; край {2} dBm — {3}" -f "", $(if ($A.Cell.Count) { $A.Cell -join ", " } else { "—" }), $(if ($null -ne $A.Edge) { $A.Edge } else { "—" }), $A.Note))
        }
        if ($B -eq "2.4") { [void]$Out.AppendLine("2.4 ГГц держи на 3–6 dB тише, чем 5 ГГц той же точки — двухдиапазонные клиенты уйдут на 5 ГГц.") }
    }
    [void]$Out.AppendLine("")
    [void]$Out.AppendLine("━━━ РОУМИНГ (Omada) ━━━")
    [void]$Out.AppendLine("Site Settings → Wireless Features: Band Steering — вкл. (Prefer 5GHz); Fast Roaming (802.11r) — вкл., если старых клиентов нет; AI Roaming / 802.11k/v — вкл.")
    [void]$Out.AppendLine("Devices → точка → Config → Advanced → Min RSSI: 2.4 ГГц −75 dBm, 5 ГГц −72 dBm (включать после правки мощностей, иначе клиенты на краю будут отваливаться).")
    [void]$Out.AppendLine("Channel Width 2.4 ГГц — 20 МГц всегда. Мощности и каналы ставь вручную (Auto у Omada часто выкручивает максимум).")
    $script:WplanLastReport = $Struct
    return $Out.ToString()
}

# One line per AP and band in the order the Omada radio screen shows the fields
function Get-WplanSheet {
    if (-not $script:WplanLastReport) { [void](Get-WplanReport) }
    $R = $script:WplanLastReport
    if (-not $R -or -not $R.Bands.Count) { return "" }
    $L = @("Точка`tДиапазон`tКанал`tШирина`tМощность (Custom dBm)`tИзменение`tПримечание")
    foreach ($B in @("2.4", "5")) {
        if (-not $R.Bands.Contains($B)) { continue }
        $P = $R.Bands[$B]
        foreach ($K in $P.Plan.Keys) {
            $A = $P.Plan[$K]
            $L += "{0}`t{1} ГГц`t{2}`t{3} МГц`t{4}`t{5}`t{6}" -f $A.Name, $B, ($P.Channels.Assign[$K] | Select-Object -First 1), $P.Channels.Width, $(if ($null -ne $A.Rec) { $A.Rec } else { "?" }), (Format-WplanDelta $A.Delta), $A.Note
        }
    }
    return ($L -join "`r`n")
}

function Start-WplanAi {
    if (-not $script:WplanLastReport) { $Ui.WpReport.Text = Get-WplanReport }
    $R = $script:WplanLastReport
    if (-not $R) { return }
    $Sys = "Ты инженер беспроводных сетей, настраиваешь точки TP-Link Omada под плавный роуминг. Тебе дают замеры RSSI (dBm) по помещениям, предварительный расчёт мощности и каналов. Проверь его, укажи на ошибки, предложи итоговые значения для каждой точки (канал, ширина, мощность в dBm) и настройки роуминга Omada. Пиши по-русски, кратко, по пунктам, без воды."
    $Names = @{}; foreach ($K in $script:Wplan.Aps.Keys) { $Names[$K] = Get-WplanApName $K }
    $Data = @{ Report = $R; ApNames = $Names; CurrentTx = $script:Wplan.Aps } | ConvertTo-Json -Depth 10 -Compress
    $Ui.WpAi.IsEnabled = $false
    $Ui.WpStatus.Text = "Спрашиваю Claude…"
    $Ok = Start-AiRequest -Name "wplan-ai" -System $Sys -UserText "Данные объекта:`n$Data" -MaxTokens 3000 -OnResult {
        param($M)
        $Ui.WpAi.IsEnabled = $true
        if (-not $M.Ok) { $Ui.WpStatus.Text = "ИИ: $($M.Text)"; Show-Toast "ИИ не ответил — подробности в строке статуса" "fail"; return }
        $Ui.WpReport.Text = $Ui.WpReport.Text + "`r`n`r`n━━━ СОВЕТ ИИ ━━━`r`n" + $M.Text
        $Ui.WpReport.ScrollToEnd()
        $Ui.WpStatus.Text = "Совет ИИ получен (токены: $($M.InTok) → $($M.OutTok))"
    }
    if (-not $Ok) { $Ui.WpAi.IsEnabled = $true }
}

# ---------------------------------------------------------------- UI

function Use-WplanSite {
    $Site = "$($Ui.WpSite.Text)".Trim()
    if (-not $Site) { $Site = "Объект"; $Ui.WpSite.Text = $Site }
    if (-not $script:Wplan -or $script:Wplan.Site -ne $Site) { $script:Wplan = Read-Wplan $Site }
    $script:Wplan.Ssids = @("$($Ui.WpSsids.Text)" -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Open-WplanSite {
    param([string]$Site)
    if (-not $Site) { return }
    $script:Wplan = Read-Wplan $Site
    $script:WplanLastReport = $null
    $Ui.WpSite.Text = $Site
    $Ui.WpSsids.Text = (@($script:Wplan.Ssids) -join ", ")
    if (-not $Ui.WpSsids.Text) {
        # new site: default to the SSID the laptop is on now
        try { $Cur = (Get-WlanInfo).Ssid; if ($Cur) { $Ui.WpSsids.Text = $Cur } } catch { }
    }
    $Ui.WpReport.Text = ""
    Refresh-Wplan
}

function Refresh-Wplan {
    $script:WplanPointItems.Clear()
    $script:WplanApItems.Clear()
    if (-not $script:Wplan) { return }
    $i = 0
    foreach ($P in @($script:Wplan.Points)) {
        $Ours = @($P.Samples | Where-Object { Test-WplanOurs $_ })
        $B = $Ours | Sort-Object { [int]$_.Rssi } -Descending | Select-Object -First 1
        $script:WplanPointItems.Add([pscustomobject]@{ Index = $i; Room = $P.Room; Time = $P.Time; Meta = "своих BSSID: $($Ours.Count)"; Best = $(if ($B) { "$(Get-WplanApName (Get-WplanKey $B.Bssid)) $($B.Rssi) dBm · $($B.Band)" } else { "—" }) })
        $i++
    }
    foreach ($K in @($script:Wplan.Aps.Keys | Sort-Object { Get-WplanApName $_ })) {
        $A = $script:Wplan.Aps[$K]
        $Tx = @(); if ("$($A.Tx24)") { $Tx += "2.4: $($A.Tx24) dBm" }; if ("$($A.Tx5)") { $Tx += "5: $($A.Tx5) dBm" }
        $script:WplanApItems.Add([pscustomobject]@{ Key = $K; Name = (Get-WplanApName $K); Named = [bool]$A.Name; Meta = "BSSID: $(@($A.Bssids).Count) · $K"; Tx = $(if ($Tx) { $Tx -join " · " } else { "мощность не указана" }) })
    }
    $Ui.WpPointsEmpty.Visibility = $(if ($script:WplanPointItems.Count) { "Collapsed" } else { "Visible" })
    Update-PageSub
}

function Get-WplanSub {
    if (-not $script:Wplan) { return "Замеры по комнатам → мощность, каналы и роуминг для точек Omada" }
    return "$($script:Wplan.Site) · замеров: $(@($script:Wplan.Points).Count) · точек: $($script:Wplan.Aps.Count)"
}

function Show-WplanApDialog {
    param([string]$Key)
    $A = $script:Wplan.Aps[$Key]
    if (-not $A) { return }
    $Others = @($script:Wplan.Aps.Keys | Where-Object { $_ -ne $Key })
    $D = New-Dialog "Точка доступа" @"
<StackPanel>
    <TextBlock Text="Точка доступа" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="Имя — как в контроллере Omada. Текущая мощность — со страницы точки (Config → Radios), тогда план даст точные значения в dBm." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,14" FontSize="12.5"/>
    <TextBlock Text="ИМЯ" Style="{StaticResource Caption}"/>
    <TextBox x:Name="FName" Style="{StaticResource Field}"/>
    <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="МОЩНОСТЬ 2.4 ГГЦ, DBM" Style="{StaticResource Caption}"/><TextBox x:Name="FTx24" Style="{StaticResource MonoField}" Tag="напр. 17"/></StackPanel>
        <StackPanel Grid.Column="2"><TextBlock Text="МОЩНОСТЬ 5 ГГЦ, DBM" Style="{StaticResource Caption}"/><TextBox x:Name="FTx5" Style="{StaticResource MonoField}" Tag="напр. 20"/></StackPanel>
    </Grid>
    <TextBlock Text="BSSID" Style="{StaticResource Caption}" Margin="2,12,0,6"/>
    <TextBox x:Name="FBssids" Style="{StaticResource Code}" MaxHeight="90"/>
    <TextBlock Text="ОБЪЕДИНИТЬ С ДРУГОЙ ТОЧКОЙ (если это одно устройство)" Style="{StaticResource Caption}" Margin="2,12,0,6"/>
    <ComboBox x:Name="FMerge"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="Сохранить" MinWidth="120" Margin="8,0,0,0" IsDefault="True"/>
    </StackPanel>
</StackPanel>
"@ 520
    $F = @{}; foreach ($N in @("FName", "FTx24", "FTx5", "FBssids", "FMerge", "FOk")) { $F[$N] = $D.FindName($N) }
    $F.FName.Text = "$($A.Name)"; $F.FTx24.Text = "$($A.Tx24)"; $F.FTx5.Text = "$($A.Tx5)"
    $F.FBssids.Text = (@($A.Bssids) -join "`r`n")
    $F.FMerge.ItemsSource = @(@([pscustomobject]@{ K = ""; L = "— не объединять —" }) + @($Others | ForEach-Object { [pscustomobject]@{ K = $_; L = "$(Get-WplanApName $_)   ($_)" } }))
    $F.FMerge.DisplayMemberPath = "L"; $F.FMerge.SelectedValuePath = "K"; $F.FMerge.SelectedIndex = 0
    $F.FOk.Add_Click({
        foreach ($T in @($F.FTx24, $F.FTx5)) { if ($T.Text.Trim() -and $T.Text.Trim() -notmatch '^\d{1,2}$') { $T.Focus(); return } }
        $D.DialogResult = $true
    })
    $D.Add_ContentRendered({ [void]$F.FName.Focus() })
    if (-not $D.ShowDialog()) { return }
    $A.Name = $F.FName.Text.Trim(); $A.Tx24 = $F.FTx24.Text.Trim(); $A.Tx5 = $F.FTx5.Text.Trim()
    $Into = "$($F.FMerge.SelectedValue)"
    if ($Into) {
        $T = $script:Wplan.Aps[$Into]
        $T.Bssids = @(@($T.Bssids) + @($A.Bssids) | Sort-Object -Unique)
        if (-not $T.Name -and $A.Name) { $T.Name = $A.Name }
        foreach ($Fld in @("Tx24", "Tx5")) { if (-not "$($T[$Fld])" -and "$($A[$Fld])") { $T[$Fld] = $A[$Fld] } }
        $script:Wplan.Merge[$Key] = $Into
        $script:Wplan.Aps.Remove($Key)
    }
    $script:WplanLastReport = $null
    Save-Wplan
    Refresh-Wplan
}

function Initialize-WifiPlanPage {
    $Ui.WpPoints.ItemsSource = $script:WplanPointItems
    $Ui.WpAps.ItemsSource = $script:WplanApItems
    Add-PickMenu $Ui.WpSitePick $Ui.WpSite { @(Get-WplanSites | ForEach-Object { [pscustomobject]@{ Label = $_; Value = $_ } }) }
    $Ui.WpSite.Add_LostKeyboardFocus({ $S = $Ui.WpSite.Text.Trim(); if ($S -and (-not $script:Wplan -or $script:Wplan.Site -ne $S)) { Open-WplanSite $S } })
    $Ui.WpSite.Add_TextChanged({ $S = $Ui.WpSite.Text.Trim(); if ($S -and (Test-Path (Get-WplanPath $S)) -and (-not $script:Wplan -or $script:Wplan.Site -ne $S)) { Open-WplanSite $S } })
    $Ui.WpSsids.Add_LostKeyboardFocus({ if ($script:Wplan) { Use-WplanSite; Save-Wplan; $script:WplanLastReport = $null; Refresh-Wplan } })
    $Ui.WpMeasure.Add_Click({ Start-WplanMeasure })
    $Ui.WpRoom.Add_KeyDown({ param($S, $E) if ("$($E.Key)" -eq "Return") { Start-WplanMeasure; $E.Handled = $true } })
    $Ui.WpCalc.Add_Click({ Use-WplanSite; $Ui.WpReport.Text = Get-WplanReport })
    $Ui.WpCopy.Add_Click({ if ($Ui.WpReport.Text) { Copy-Text $Ui.WpReport.Text "отчёт" } })
    $Ui.WpCopySheet.Add_Click({ $T = Get-WplanSheet; if ($T) { Copy-Text $T "лист для Omada (вставляется в Excel)" } else { Show-Toast "Сначала замеры и расчёт" "warn" } })
    $Ui.WpAi.Add_Click({ Start-WplanAi })
    $Ui.WpAps.Add_MouseDoubleClick({ $R = $Ui.WpAps.SelectedItem; if ($R) { Show-WplanApDialog $R.Key } })
    $Ui.WpAps.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Имя, мощность, объединить…" 0xE70F { $R = $Ui.WpAps.SelectedItem; if ($R) { Show-WplanApDialog $R.Key } } "2×клик")
        (New-MenuItem "Копировать BSSID" 0xE8C8 { $R = $Ui.WpAps.SelectedItem; if ($R) { Copy-Text (@($script:Wplan.Aps[$R.Key].Bssids) -join "`r`n") "BSSID" } })
    )
    $Ui.WpPoints.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Удалить замер" 0xE74D {
            $R = $Ui.WpPoints.SelectedItem; if (-not $R) { return }
            $L = [System.Collections.Generic.List[object]]::new(); $j = 0
            foreach ($P in @($script:Wplan.Points)) { if ($j -ne $R.Index) { $L.Add($P) }; $j++ }
            $script:Wplan.Points = @($L); $script:WplanLastReport = $null; Save-Wplan; Refresh-Wplan
        } "" "Fail")
    )
    $Last = "$($script:Settings.WplanSite)"
    if (-not $Last) { $Last = @(Get-WplanSites) | Select-Object -First 1 }
    if ($Last) { Open-WplanSite $Last } else { $Ui.WpSite.Text = ""; try { $Cur = (Get-WlanInfo).Ssid; if ($Cur) { $Ui.WpSsids.Text = $Cur } } catch { } }
}
