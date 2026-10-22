# Page: Wi-Fi planner for Omada (or any) access points, laptop-based site survey.
# Walk the site, take a measurement in each room and doorway ("transition"); BSSIDs are grouped into physical APs,
# a room × AP matrix is built per band (in "phone dBm" = laptop − client offset), and a joint optimiser picks the
# power of all APs together (coverage ≥ edge, neighbours ≥ margin below the serving AP, transitions keep a roam
# target, minimal power). Channels are then assigned on the predicted matrix. Measurements are grouped in series
# ("Исходная", "После правок 1"…) so a verification walk can be compared with the original. Values are entered
# into the controller by hand; the planner never talks to the controller.
# One plan per site: %APPDATA%\NetKnife\wifiplan\<site>.json  (+ <site>.html report)

$script:WplanDir = Join-Path $script:DataDir "wifiplan"
$script:Wplan = $null
$script:WplanPointItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:WplanApItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:WplanBusy = $false
$script:WplanLastReport = $null     # structured result of the last calculation (sheet / HTML / AI)
$script:WplanBaseSeries = "Исходная"

# Planning targets in phone dBm
$script:WpEdge = -67          # serving AP in its own room must be at least this
$script:WpAim = 3             # optimiser aims this many dB above the edge (safety for scan noise)
$script:WpMargin = 8          # in a foreign room a neighbour AP should be at least this many dB below the serving one
$script:WpRoamFloor = -78     # in a transition the second-best AP must be at least this, or there is nothing to roam to
$script:WpTxMin = 3

if (-not ("NetKnife.WpOpt" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
namespace NetKnife {
    // Joint power optimiser. s[row, ap] = phone dBm at current power (NaN = not heard); d[ap] = change in dB.
    public static class WpOpt {
        public static double Cost(double[,] s, bool[] trans, int[] d, double edge, double margin, double roamFloor) {
            int R = s.GetLength(0), K = s.GetLength(1); double pen = 0;
            for (int r = 0; r < R; r++) {
                double b = -200, b2 = -200; int bk = -1;
                for (int k = 0; k < K; k++) {
                    if (double.IsNaN(s[r, k])) continue;
                    double v = s[r, k] + d[k];
                    if (v > b) { b2 = b; b = v; bk = k; } else if (v > b2) b2 = v;
                }
                if (bk < 0) continue;
                if (b < edge) pen += 100 * (edge - b);
                if (trans[r]) { if (b2 < roamFloor) pen += 30 * (roamFloor - Math.Max(b2, -100)); }
                else {
                    for (int k = 0; k < K; k++) {
                        if (k == bk || double.IsNaN(s[r, k])) continue;
                        double ex = s[r, k] + d[k] - (b - margin);
                        if (ex > 0) pen += 20 * ex;
                    }
                }
            }
            for (int k = 0; k < K; k++) pen += d[k] * 1.0 + Math.Abs(d[k]) * 0.3;   // prefer less power, fewer changes
            return pen;
        }

        public static int[] Optimize(double[,] s, bool[] trans, int[] lo, int[] hi, double edge, double margin, double roamFloor) {
            int K = s.GetLength(1);
            int[] best = new int[K]; double bestCost = double.MaxValue;
            foreach (int start in new int[] { 0, -6, 3 }) {
                int[] d = new int[K];
                for (int k = 0; k < K; k++) d[k] = Math.Max(lo[k], Math.Min(hi[k], start));
                double cur = Cost(s, trans, d, edge, margin, roamFloor);
                for (int pass = 0; pass < 50; pass++) {
                    bool improved = false;
                    for (int k = 0; k < K; k++) {
                        int keep = d[k], bv = keep; double bc = cur;
                        for (int v = lo[k]; v <= hi[k]; v++) {
                            d[k] = v;
                            double c = Cost(s, trans, d, edge, margin, roamFloor);
                            if (c < bc - 1e-9) { bc = c; bv = v; }
                        }
                        d[k] = bv;
                        if (bv != keep) { cur = bc; improved = true; }
                    }
                    if (!improved) break;
                }
                if (cur < bestCost) { bestCost = cur; best = (int[])d.Clone(); }
            }
            return best;
        }
    }
}
'@
}

# ---------------------------------------------------------------- storage

function Get-WplanPath { param([string]$Site, [string]$Ext = "json") return Join-Path $script:WplanDir ("{0}.{1}" -f ($Site -replace '[\\/:*?"<>|]', '_'), $Ext) }

function Get-WplanSites {
    if (-not (Test-Path $script:WplanDir)) { return @() }
    return @(Get-ChildItem $script:WplanDir -Filter *.json | Sort-Object LastWriteTime -Descending | ForEach-Object { $_.BaseName })
}

function New-WplanOpt { return @{ Offset = 6; Cap5 = 20; Cap24 = 17 } }

function New-Wplan { param([string]$Site) return @{ Site = $Site; Ssids = @(); Aps = @{}; Merge = @{}; Points = @(); CurSeries = $script:WplanBaseSeries; Opt = (New-WplanOpt); KeyV = 2 } }

function Read-Wplan {
    param([string]$Site)
    $P = Get-WplanPath $Site
    if (Test-Path $P) {
        try {
            $W = Get-Content $P -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            foreach ($K in @("Ssids", "Points")) { if (-not $W[$K]) { $W[$K] = @() } }
            foreach ($K in @("Aps", "Merge")) { if (-not $W[$K]) { $W[$K] = @{} } }
            if (-not $W.CurSeries) { $W.CurSeries = $script:WplanBaseSeries }
            $O = New-WplanOpt
            if ($W.Opt) { foreach ($K in @($W.Opt.Keys)) { $O[$K] = $W.Opt[$K] } }
            $W.Opt = $O
            foreach ($P2 in @($W.Points)) { if (-not $P2.Series) { $P2.Series = $script:WplanBaseSeries }; if (-not $P2.Kind) { $P2.Kind = "room" } }
            $W.Site = $Site
            if (-not $W.KeyV -or $W.KeyV -lt 2) { try { Convert-WplanKeysV2 $W } catch { Write-AppLog "wplan keys v2 ${Site}: $_" } }
            return $W
        } catch { Write-AppLog "wplan read ${Site}: $_" }
    }
    return New-Wplan $Site
}

# v1 → v2 AP keys: an old group may hold several APs — split it by BSSID; the stored name, power and plan
# position go to the AP whose router (DHCP) name matches, the others start fresh (names come from the router)
function Convert-WplanKeysV2 {
    param($W)
    $Old = $W.Aps; $New = @{}; $Moved = @{}
    $RouterName = @{}
    if ($script:Settings.MtAps) { foreach ($Id in @($script:Settings.MtAps.Keys)) { foreach ($A in @($script:Settings.MtAps[$Id] | Where-Object { $_ })) { if ($A.Mac -and $A.Name) { $RouterName[(Get-MtApKey "$($A.Mac)")] = "$($A.Name)" } } } }
    $W.Merge = @{}   # manual merges were made on old keys
    foreach ($K in @($Old.Keys)) {
        $A = $Old[$K]
        $Groups = [ordered]@{}
        foreach ($B in @($A.Bssids | Where-Object { $_ })) {
            $O = "$B".ToUpper() -split '[:-]'
            if ($O.Count -ne 6) { continue }
            $Nk = "{0}:{1}:{2}:{3}:{4:X2}" -f $O[1], $O[2], $O[3], $O[4], ([Convert]::ToInt32($O[5], 16) -band 0xFE)
            if (-not $Groups.Contains($Nk)) { $Groups[$Nk] = [System.Collections.Generic.List[string]]::new() }
            $Groups[$Nk].Add("$B")
        }
        if (-not $Groups.Count) { $New[$K] = $A; continue }
        $Keys = @($Groups.Keys)
        $Main = @($Keys | Where-Object { $A.Name -and $RouterName[$_] -and "$($RouterName[$_])".ToLower() -eq "$($A.Name)".ToLower() }) | Select-Object -First 1
        if (-not $Main) { $Main = @($Keys | Sort-Object { -$Groups[$_].Count }, { $_ }) | Select-Object -First 1 }
        foreach ($Nk in $Keys) {
            if ($Nk -eq $Main) { $A.Bssids = @($Groups[$Nk]); $New[$Nk] = $A }
            elseif (-not $New.ContainsKey($Nk)) { $New[$Nk] = @{ Name = ""; Tx24 = ""; Tx5 = ""; Bssids = @($Groups[$Nk]) } }
        }
        $Moved[$K] = $Main
    }
    $W.Aps = $New
    if ($W.Floor -and $W.Floor.Aps) {
        $Fa = @{}
        foreach ($K in @($W.Floor.Aps.Keys)) { $Nk = $(if ($Moved.ContainsKey($K)) { $Moved[$K] } else { $K }); if (-not $Fa.ContainsKey($Nk)) { $Fa[$Nk] = $W.Floor.Aps[$K] } }
        $W.Floor.Aps = $Fa
    }
    $W.KeyV = 2
    $script:WplanKeysMigrated = $W.Site
}

function Save-Wplan {
    if (-not $script:Wplan) { return }
    if (-not (Test-Path $script:WplanDir)) { New-Item -ItemType Directory -Path $script:WplanDir | Out-Null }
    $script:Wplan | ConvertTo-Json -Depth 8 | Set-Content -Path (Get-WplanPath $script:Wplan.Site) -Encoding UTF8
    $script:Settings.WplanSite = $script:Wplan.Site; Save-Settings
}

function Get-WplanSeriesList {
    $L = [System.Collections.Generic.List[string]]::new()
    $L.Add($script:WplanBaseSeries)
    foreach ($P in @($script:Wplan.Points)) { if ($P.Series -and -not $L.Contains($P.Series)) { $L.Add($P.Series) } }
    if ($script:Wplan.CurSeries -and -not $L.Contains($script:Wplan.CurSeries)) { $L.Add($script:Wplan.CurSeries) }
    return @($L)
}

# ---------------------------------------------------------------- grouping BSSIDs into physical APs
# Omada: 2.4 GHz radio = base MAC, 5 GHz = base+1, extra SSIDs flip bits in the first octet. So the group key
# ignores the first octet and the lowest bit of the last one (v1 masked 3 bits and merged neighbouring APs).
# Manual merges (plan.Merge) override.

function Get-WplanKey {
    param([string]$Bssid)
    $O = $Bssid.ToUpper() -split '[:-]'
    if ($O.Count -ne 6) { return $Bssid }
    $Last = [Convert]::ToInt32($O[5], 16) -band 0xFE   # only the lowest bit: 5 GHz = MAC + 1 (see Get-MtApKey)
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
    $Mt = $(if ($script:Settings.MtApNames) { "$($script:Settings.MtApNames[$Key])" } else { "" })
    if ($Mt) { return $Mt }
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
    if (-not $Room) { Show-Toast "Назови место замера (комната или переход «Кухня ↔ Холл»)" "warn"; [void]$Ui.WpRoom.Focus(); return }
    Use-WplanSite
    $Kind = $(if ($Ui.WpTrans.IsChecked) { "trans" } else { "room" })
    $script:WplanBusy = $true
    $Ui.WpMeasure.IsEnabled = $false
    $Ui.WpStatus.Text = "Замер «$Room» ($(if ($Kind -eq 'trans') { 'переход' } else { 'комната' }), серия «$($script:Wplan.CurSeries)»): сканирую эфир (3 прохода, ~12 с) — не двигайся…"
    [void](Start-Worker -Name "wplan-scan" -Replace -Body $script:WplanScanBody -ArgList @(3) -State @{ Room = $Room; Kind = $Kind; Series = $script:Wplan.CurSeries } -OnMessage {
        param($M)
        switch ($M.Type) {
            "wpround" { $Ui.WpStatus.Text = "Замер «$($State.Room)»: проход $($M.N)/$($M.Total), видно BSSID: $($M.Count)" }
            "wpscan" {
                $script:WplanBusy = $false
                $Ui.WpMeasure.IsEnabled = $true
                if ($M.Error) { $Ui.WpStatus.Text = "Скан не удался: $($M.Error)"; Show-Toast "Wi-Fi скан: $($M.Error)" "fail"; return }
                $Pt = @{ Room = $State.Room; Kind = $State.Kind; Series = $State.Series; Time = (Get-Date -Format "yyyy-MM-dd HH:mm"); Samples = @($M.Samples) }
                $script:Wplan.Points = @($script:Wplan.Points) + @($Pt)
                Register-WplanAps @($M.Samples)
                $script:WplanLastReport = $null
                Save-Wplan
                Refresh-Wplan
                $Ours = @($M.Samples | Where-Object { Test-WplanOurs $_ })
                $Best = $Ours | Sort-Object { $_.Rssi } -Descending | Select-Object -First 1
                $N = @($script:Wplan.Points | Where-Object { $_.Room -eq $State.Room -and $_.Series -eq $State.Series }).Count
                $Ui.WpStatus.Text = "«$($State.Room)» записан ($N-й замер здесь): своих BSSID $($Ours.Count) из $(@($M.Samples).Count)" +
                    $(if ($Best) { " · лучший $(Get-WplanApName (Get-WplanKey $Best.Bssid)) $($Best.Rssi) dBm ($($Best.Band) ГГц)" } else { " · своих точек не видно — проверь SSID объекта" }) +
                    $(if ($N -eq 1 -and $State.Kind -eq "room") { ". Совет: второй замер у двери этой комнаты" } else { "" })
                $Ui.WpRoom.Text = ""; [void]$Ui.WpRoom.Focus()
            }
        }
    })
}

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

# rows (rooms + transitions of one series) → band → apKey → averaged LAPTOP dBm (missing counts as −95)
function Get-WplanMatrix {
    param([string]$Series)
    $Rows = [ordered]@{}
    foreach ($P in @($script:Wplan.Points)) {
        if ("$($P.Series)" -ne $Series) { continue }
        if (-not $Rows.Contains($P.Room)) { $Rows[$P.Room] = @{ Name = $P.Room; Trans = ($P.Kind -eq "trans"); Pts = [System.Collections.Generic.List[object]]::new() } }
        $Rows[$P.Room].Pts.Add($P)
    }
    $M = @{ "2.4" = @{}; "5" = @{} }
    $Keys = [System.Collections.Generic.HashSet[string]]::new()
    $Chan = @{ "2.4" = @{}; "5" = @{} }
    $Foreign = @{ "2.4" = @{}; "5" = @{} }
    foreach ($R in $Rows.Keys) {
        foreach ($B in @("2.4", "5")) {
            $Sum = @{}
            foreach ($P in $Rows[$R].Pts) {
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
            $N = $Rows[$R].Pts.Count
            foreach ($K in $Sum.Keys) {
                $Tot = 0; foreach ($X in $Sum[$K]) { $Tot += $X }
                $Tot += (-95) * ($N - $Sum[$K].Count)
                $Avg = [int][Math]::Round($Tot / $N)
                if ($Avg -gt -90) { $Row[$K] = $Avg }
            }
            $M[$B][$R] = $Row
        }
    }
    return @{ Rows = @($Rows.Values | ForEach-Object { @{ Name = $_.Name; Trans = $_.Trans } }); Keys = @($Keys | Sort-Object { Get-WplanApName $_ }); S = $M; Chan = $Chan; Foreign = $Foreign }
}

# best and second-best AP of one row in a {apKey → dBm} map
function Get-WplanTop {
    param($Row)
    $B = $null; $Bv = -999; $Sv = -999
    foreach ($K in $Row.Keys) { $V = $Row[$K]; if ($V -gt $Bv) { $Sv = $Bv; $Bv = $V; $B = $K } elseif ($V -gt $Sv) { $Sv = $V } }
    return @{ Key = $B; Val = $Bv; Second = $Sv }
}

function Get-WplanBandPlan {
    param($Mx, [string]$B, $Plan5)
    $Opt = $script:Wplan.Opt
    $Off = [int]$Opt.Offset
    $Rows = @($Mx.Rows)
    $Keys = @($Mx.Keys | Where-Object { $K = $_; @($Rows | Where-Object { $Mx.S[$B][$_.Name].ContainsKey($K) }).Count })
    if (-not $Keys.Count) { return $null }
    $Fld = "Tx" + ($B -replace '\.', '')
    $Cap = [int]$(if ($B -eq "5") { $Opt.Cap5 } else { $Opt.Cap24 })

    # phone-dBm matrix at current power
    $Before = @{}
    $Sm = [double[,]]::new($Rows.Count, $Keys.Count)
    $Tr = [bool[]]::new($Rows.Count)
    for ($r = 0; $r -lt $Rows.Count; $r++) {
        $Name = $Rows[$r].Name; $Tr[$r] = [bool]$Rows[$r].Trans
        $Before[$Name] = @{}
        for ($ki = 0; $ki -lt $Keys.Count; $ki++) {
            $V = $Mx.S[$B][$Name][$Keys[$ki]]
            if ($null -eq $V) { $Sm[$r, $ki] = [double]::NaN } else { $Sm[$r, $ki] = $V - $Off; $Before[$Name][$Keys[$ki]] = $V - $Off }
        }
    }

    # bounds per AP
    $Lo = [int[]]::new($Keys.Count); $Hi = [int[]]::new($Keys.Count); $Known = @{}
    for ($ki = 0; $ki -lt $Keys.Count; $ki++) {
        $Cur = "$($script:Wplan.Aps[$Keys[$ki]][$Fld])"
        $CapK = $Cap; $FloorK = $script:WpTxMin
        # 2.4 GHz follows the same AP's 5 GHz: 3..8 dB below it, so both bands cover the same zone
        if ($B -eq "2.4" -and $Plan5 -and $Plan5.Aps.Contains($Keys[$ki]) -and $null -ne $Plan5.Aps[$Keys[$ki]].Rec) {
            $CapK = [Math]::Min($Cap, [int]$Plan5.Aps[$Keys[$ki]].Rec - 3)
            $FloorK = [Math]::Max($FloorK, [int]$Plan5.Aps[$Keys[$ki]].Rec - 8)
        }
        if ($Cur -match '^\d+$') {
            $Known[$Keys[$ki]] = [int]$Cur
            $Lo[$ki] = [Math]::Max($FloorK - [int]$Cur, -10); $Hi[$ki] = $CapK - [int]$Cur   # at most −10 dB per round
            if ($Hi[$ki] -lt $Lo[$ki]) { $Lo[$ki] = $Hi[$ki] }
        } else { $Lo[$ki] = -10; $Hi[$ki] = 3 }
    }

    # an AP that serves none of the measured rooms covers rooms we have not walked yet — leave it alone
    $Unsurveyed = @{}
    for ($ki = 0; $ki -lt $Keys.Count; $ki++) {
        $Serves = @($Rows | Where-Object { -not $_.Trans -and (Get-WplanTop $Before[$_.Name]).Key -eq $Keys[$ki] }).Count
        if (-not $Serves) { $Unsurveyed[$Keys[$ki]] = $true; $Lo[$ki] = 0; $Hi[$ki] = 0 }
    }

    $D = [NetKnife.WpOpt]::Optimize($Sm, $Tr, $Lo, $Hi, [double]($script:WpEdge + $script:WpAim), [double]$script:WpMargin, [double]$script:WpRoamFloor)
    # changes under 2 dB are scan noise — drop them if the bounds allow
    for ($ki = 0; $ki -lt $D.Count; $ki++) { if ([Math]::Abs($D[$ki]) -lt 2 -and 0 -ge $Lo[$ki] -and 0 -le $Hi[$ki]) { $D[$ki] = 0 } }

    $After = @{}
    foreach ($Rw in $Rows) {
        $After[$Rw.Name] = @{}
        for ($ki = 0; $ki -lt $Keys.Count; $ki++) { if ($Before[$Rw.Name].ContainsKey($Keys[$ki])) { $After[$Rw.Name][$Keys[$ki]] = $Before[$Rw.Name][$Keys[$ki]] + $D[$ki] } }
    }
    $TopB = @{}; $TopA = @{}
    foreach ($Rw in $Rows) { $TopB[$Rw.Name] = Get-WplanTop $Before[$Rw.Name]; $TopA[$Rw.Name] = Get-WplanTop $After[$Rw.Name] }

    $Aps = [ordered]@{}
    for ($ki = 0; $ki -lt $Keys.Count; $ki++) {
        $K = $Keys[$ki]
        $Cell = @($Rows | Where-Object { -not $_.Trans -and $TopA[$_.Name].Key -eq $K } | ForEach-Object { $_.Name })
        $Edge = $null; foreach ($R in $Cell) { $V = $After[$R][$K]; if ($null -eq $Edge -or $V -lt $Edge) { $Edge = $V } }
        $Ex = 0; $ExRoom = ""
        foreach ($Rw in $Rows) {
            if ($Rw.Trans -or $TopA[$Rw.Name].Key -eq $K -or -not $After[$Rw.Name].ContainsKey($K)) { continue }
            $E = $After[$Rw.Name][$K] - ($TopA[$Rw.Name].Val - $script:WpMargin)
            if ($E -gt $Ex) { $Ex = $E; $ExRoom = $Rw.Name }
        }
        $Notes = @()
        if ($Unsurveyed.ContainsKey($K)) { $Notes += "нет замеров в её зоне — не меняю; обойди комнаты рядом с ней" }
        elseif (-not $Cell.Count) { $Notes += "после правок нигде не основная — проверь, нужна ли на $B ГГц" }
        if ($null -ne $Edge -and $Edge -lt $script:WpEdge) {
            $Notes += $(if ($Known.ContainsKey($K)) { "край зоны $Edge dBm — не дотягивается даже на потолке мощности, нужна точка ближе" } else { "край зоны $Edge dBm — прибавь, сколько позволяет точка (впиши текущую мощность — посчитаю точно)" })
        }
        if ($Ex -gt 0) { $Notes += "в «$ExRoom» громче нормы на $Ex dB — разведи каналами" }
        if (-not $Known.ContainsKey($K)) { $Notes += "текущая мощность не указана — значение относительное" }
        if (-not $Notes.Count) { $Notes += "в норме" }
        $Rec = $(if ($Known.ContainsKey($K)) { $Known[$K] + $D[$ki] } else { $null })
        $Aps[$K] = [ordered]@{ Key = $K; Name = (Get-WplanApName $K); Delta = [int]$D[$ki]; Cur = $(if ($Known.ContainsKey($K)) { $Known[$K] } else { $null }); Rec = $Rec
            Cell = $Cell; Edge = $Edge; Note = ($Notes -join "; "); Ch = $Mx.Chan[$B][$K] }
    }
    return @{ Band = $B; Keys = $Keys; Rows = $Rows; Before = $Before; After = $After; TopB = $TopB; TopA = $TopA; Aps = $Aps }
}

# Greedy channel assignment on the PREDICTED matrix: conflict = how strongly two of our APs are heard in the same rows;
# foreign networks on a channel add a penalty; +0.5 per reuse spreads APs over free channels.
function Get-WplanChannels {
    param($Plan, $Foreign, [switch]$Dfs)
    $B = $Plan.Band; $S = $Plan.After; $Keys = $Plan.Keys; $N = $Keys.Count
    if ($B -eq "2.4") { $Opts = @(@(1), @(6), @(11)); $Width = 20 }
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
        foreach ($Rw in $Plan.Rows) { $R = $Rw.Name; if ($S[$R].ContainsKey($A) -and $S[$R].ContainsKey($C)) { $Sum += [Math]::Max(0, [Math]::Min($S[$R][$A], $S[$R][$C]) + 85) } }
        $W["$A|$C"] = $Sum
    } }
    $Deg = @{}; foreach ($A in $Keys) { $T = 0; foreach ($C in $Keys) { if ($A -ne $C) { $T += $W["$A|$C"] } }; $Deg[$A] = $T }
    $Assign = @{}
    foreach ($A in @($Keys | Sort-Object { -$Deg[$_] })) {
        $BestCost = [double]::MaxValue; $BestOpt = $null
        foreach ($O in $Opts) {
            $Chs = @($O); $Cost = 0
            foreach ($C in $Assign.Keys) { if (@($Assign[$C]) | Where-Object { $Chs -contains $_ }) { $Cost += $W["$A|$C"] + 0.5 } }
            foreach ($Ch in $Chs) { if ($Foreign[$B].ContainsKey($Ch)) { $Cost += [Math]::Max(0, $Foreign[$B][$Ch] + 90) * 0.5 } }
            if ($B -eq "2.4") { foreach ($Ch in $Foreign[$B].Keys) { if ([Math]::Abs($Ch - $Chs[0]) -in 1..4) { $Cost += [Math]::Max(0, $Foreign[$B][$Ch] + 90) * 0.7 } } }
            if ($Cost -lt $BestCost) { $BestCost = $Cost; $BestOpt = $Chs }
        }
        $Assign[$A] = $BestOpt
    }
    return @{ Width = $Width; Assign = $Assign }
}

function Format-WplanDelta { param([int]$D) if ($D -gt 0) { return "+$D dB" } elseif ($D -lt 0) { return "$D dB" } else { return "0" } }

function Get-WplanRowMark {
    param($Top, [bool]$Trans)
    if ($null -eq $Top.Key) { return "нет сигнала" }
    if ($Top.Val -lt -75) { return "дыра" }
    if ($Top.Val -lt $script:WpEdge) { return "слабо" }
    if ($Trans -and $Top.Second -lt $script:WpRoamFloor) { return "роумиться некуда" }
    return ""
}

# One structured calculation for the current series; text report, sheet, HTML and AI all read this
function Invoke-WplanCalc {
    $Ser = $script:Wplan.CurSeries
    $Mx = Get-WplanMatrix $Ser
    $R = [ordered]@{ Site = $script:Wplan.Site; Series = $Ser; Opt = $script:Wplan.Opt; Rows = $Mx.Rows; Points = @($script:Wplan.Points | Where-Object { $_.Series -eq $Ser }).Count; Bands = [ordered]@{}; Error = "" }
    if (-not $Mx.Rows.Count) { $R.Error = "В серии «$Ser» нет замеров."; return $R }
    if (-not $Mx.Keys.Count) { $R.Error = "В замерах нет своих точек. Укажи SSID объекта (через запятую) — при пустом поле точки определяются по производителю TP-Link."; return $R }
    $P5 = Get-WplanBandPlan $Mx "5" $null
    $P24 = Get-WplanBandPlan $Mx "2.4" $P5
    foreach ($P in @($P5, $P24)) {
        if (-not $P) { continue }
        $P.Channels = Get-WplanChannels $P $Mx.Foreign -Dfs:([bool]$Ui.WpDfs.IsChecked)
        $R.Bands[$P.Band] = $P
    }
    $script:WplanLastReport = $R
    return $R
}

function Format-WplanMatrix {
    param($Plan, $Map, $Tops, [string]$Title)
    $Out = [System.Text.StringBuilder]::new()
    $Keys = $Plan.Keys
    $W = [Math]::Max(16, (@($Plan.Rows | ForEach-Object { $_.Name.Length + 2 }) | Measure-Object -Maximum).Maximum + 1)
    [void]$Out.AppendLine($Title)
    [void]$Out.AppendLine("".PadRight($W) + (($Keys | ForEach-Object { $N = Get-WplanApName $_; if ($N.Length -gt 10) { $N = $N.Substring(0, 10) }; $N.PadLeft(11) }) -join ""))
    foreach ($Rw in $Plan.Rows) {
        $Name = $(if ($Rw.Trans) { "↔ $($Rw.Name)" } else { $Rw.Name })
        $Line = $Name.PadRight($W)
        $Bk = $Tops[$Rw.Name].Key
        foreach ($K in $Keys) {
            $V = $Map[$Rw.Name][$K]
            $Line += $(if ($null -eq $V) { "·" } else { "$V$(if ($K -eq $Bk) { '*' } else { ' ' })" }).PadLeft(11)
        }
        $Mk = Get-WplanRowMark $Tops[$Rw.Name] ([bool]$Rw.Trans)
        if ($Mk) { $Line += "   ← $Mk" }
        [void]$Out.AppendLine($Line)
    }
    return $Out.ToString()
}

function Get-WplanReport {
    if (-not @($script:Wplan.Points).Count) { return "Нет замеров. Встань в комнату, введи её название и нажми «Замер здесь». Обойди все помещения; в дверях и коридорах между зонами точек — замер с галкой «переход»." }
    $R = Invoke-WplanCalc
    if ($R.Error) { return $R.Error }
    $O = $R.Opt
    $Out = [System.Text.StringBuilder]::new()
    [void]$Out.AppendLine("ОБЪЕКТ: $($R.Site)   серия: $($R.Series)   замеров: $($R.Points)   мест: $($R.Rows.Count) (переходов: $(@($R.Rows | Where-Object { $_.Trans }).Count))")
    [void]$Out.AppendLine("Всё в dBm «глазами телефона» (замер ноутбука − $($O.Offset) dB). Цель: основная точка ≥ $($script:WpEdge), сосед в чужой комнате ≥ $($script:WpMargin) dB тише, в переходе вторая точка ≥ $($script:WpRoamFloor).")
    [void]$Out.AppendLine("Потолок мощности: 5 ГГц $($O.Cap5) dBm, 2.4 ГГц $($O.Cap24) dBm (и на 3 dB ниже 5 ГГц той же точки) — чтобы телефон мог ответить точке.")
    $NAps = @($R.Bands.Values | ForEach-Object { $_.Keys } | Sort-Object -Unique).Count
    if ($R.Rows.Count -lt 2 * $NAps) { [void]$Out.AppendLine("⚠ МАЛО ЗАМЕРОВ: $($R.Rows.Count) мест на $NAps точек. План предварительный — снижать мощность по нему рано; обойди все комнаты (минимум по 2 на точку, включая дальние).") }
    foreach ($B in @("5", "2.4")) {
        if (-not $R.Bands.Contains($B)) { continue }
        $P = $R.Bands[$B]
        [void]$Out.AppendLine("")
        [void]$Out.AppendLine("━━━ $B ГГц ━━━")
        [void]$Out.Append((Format-WplanMatrix $P $P.Before $P.TopB "СЕЙЧАС"))
        [void]$Out.AppendLine("")
        [void]$Out.Append((Format-WplanMatrix $P $P.After $P.TopA "ПРОГНОЗ после правок"))
        [void]$Out.AppendLine("(* — основная точка; · — не слышно; ↔ — переход)")
        $Fixed = @($P.Rows | Where-Object { (Get-WplanRowMark $P.TopB[$_.Name] ([bool]$_.Trans)) -and -not (Get-WplanRowMark $P.TopA[$_.Name] ([bool]$_.Trans)) } | ForEach-Object { $_.Name })
        $Worse = @($P.Rows | Where-Object { -not (Get-WplanRowMark $P.TopB[$_.Name] ([bool]$_.Trans)) -and (Get-WplanRowMark $P.TopA[$_.Name] ([bool]$_.Trans)) } | ForEach-Object { $_.Name })
        if ($Fixed.Count) { [void]$Out.AppendLine("Исправится: $($Fixed -join ', ')") }
        if ($Worse.Count) { [void]$Out.AppendLine("Станет хуже (компромисс): $($Worse -join ', ')") }
        [void]$Out.AppendLine("")
        foreach ($K in $P.Keys) {
            $A = $P.Aps[$K]
            $Ch = $P.Channels.Assign[$K] | Select-Object -First 1
            $ChTxt = $(if ($B -eq "2.4") { "канал $Ch" } else { "канал $Ch / $($P.Channels.Width) МГц" })
            $Pw = $(if ($null -ne $A.Rec) { "мощность $($A.Cur) → $($A.Rec) dBm (Custom)" } else { "мощность $(Format-WplanDelta $A.Delta) от текущей" })
            [void]$Out.AppendLine(("{0,-14} {1}; {2}; сейчас кан. {3}" -f $A.Name, $ChTxt, $Pw, $(if ($A.Ch) { $A.Ch } else { "?" })))
            [void]$Out.AppendLine(("{0,-14}   зона: {1}; край {2} dBm — {3}" -f "", $(if ($A.Cell.Count) { $A.Cell -join ", " } else { "—" }), $(if ($null -ne $A.Edge) { $A.Edge } else { "—" }), $A.Note))
        }
        $Trs = @($P.Rows | Where-Object { $_.Trans })
        if ($Trs.Count) {
            [void]$Out.AppendLine("")
            [void]$Out.AppendLine("Переходы (прогноз):")
            foreach ($T in $Trs) {
                $Tp = $P.TopA[$T.Name]
                $Ok = ($Tp.Val -ge $script:WpEdge -and $Tp.Second -ge $script:WpRoamFloor)
                [void]$Out.AppendLine(("  {0,-24} основная {1} dBm, запасная {2} dBm — {3}" -f $T.Name, $Tp.Val, $(if ($Tp.Second -gt -999) { $Tp.Second } else { "нет" }), $(if ($Ok) { "роуминг пройдёт" } elseif ($Tp.Val -lt $script:WpEdge) { "слабо на переходе" } else { "вторая точка не слышна — клиент будет держаться до обрыва" })))
            }
        }
    }
    [void]$Out.AppendLine("")
    [void]$Out.AppendLine("━━━ РОУМИНГ (Omada) ━━━")
    [void]$Out.AppendLine("Site Settings → Wireless Features: Band Steering — вкл. (Prefer 5GHz); Fast Roaming (802.11r) — вкл., если старых клиентов нет; AI Roaming / 802.11k/v — вкл.")
    [void]$Out.AppendLine("Devices → точка → Config → Advanced → Min RSSI: 2.4 ГГц −75 dBm, 5 ГГц −72 dBm (после правки мощностей, иначе клиенты на краю будут отваливаться).")
    [void]$Out.AppendLine("Ширина 2.4 ГГц — 20 МГц всегда. Мощность и канал — вручную (Auto у Omada часто выкручивает максимум).")
    [void]$Out.AppendLine("После внесения: новая серия «После правок N» → обойди те же места → «Сравнить серии».")
    return $Out.ToString()
}

function Get-WplanSheet {
    $R = $script:WplanLastReport
    if (-not $R) { $R = Invoke-WplanCalc }
    if ($R.Error -or -not $R.Bands.Count) { return "" }
    $L = @("Точка`tДиапазон`tКанал`tШирина`tМощность сейчас`tМощность (Custom dBm)`tИзменение`tПримечание")
    foreach ($B in @("2.4", "5")) {
        if (-not $R.Bands.Contains($B)) { continue }
        $P = $R.Bands[$B]
        foreach ($K in $P.Keys) {
            $A = $P.Aps[$K]
            $L += "{0}`t{1} ГГц`t{2}`t{3} МГц`t{4}`t{5}`t{6}`t{7}" -f $A.Name, $B, ($P.Channels.Assign[$K] | Select-Object -First 1), $P.Channels.Width, $(if ($null -ne $A.Cur) { $A.Cur } else { "?" }), $(if ($null -ne $A.Rec) { $A.Rec } else { "?" }), (Format-WplanDelta $A.Delta), $A.Note
        }
    }
    return ($L -join "`r`n")
}

# ---------------------------------------------------------------- compare series (verification walk)

function Get-WplanCompare {
    $List = Get-WplanSeriesList
    $Base = $List[0]; $Cur = $script:Wplan.CurSeries
    if ($Base -eq $Cur) { return @{ Error = "Текущая серия — исходная. Создай серию «После правок 1», обойди те же места и сравни." } }
    $Off = [int]$script:Wplan.Opt.Offset
    $MB = Get-WplanMatrix $Base; $MC = Get-WplanMatrix $Cur
    $Res = @{ Base = $Base; Cur = $Cur; Bands = [ordered]@{}; Error = "" }
    foreach ($B in @("5", "2.4")) {
        $Lines = @()
        foreach ($Rw in $MC.Rows) {
            $Ob = $MB.S[$B][$Rw.Name]; $Oc = $MC.S[$B][$Rw.Name]
            if ($null -eq $Ob -or -not $Ob.Count -or $null -eq $Oc -or -not $Oc.Count) { continue }
            $Tb = Get-WplanTop $Ob; $Tc = Get-WplanTop $Oc
            $Vb = $Tb.Val - $Off; $Vc = $Tc.Val - $Off
            $MarkB = Get-WplanRowMark @{ Key = $Tb.Key; Val = $Vb; Second = $Tb.Second - $Off } ([bool]$Rw.Trans)
            $MarkC = Get-WplanRowMark @{ Key = $Tc.Key; Val = $Vc; Second = $Tc.Second - $Off } ([bool]$Rw.Trans)
            $Verdict = $(if ($MarkB -and -not $MarkC) { "исправлено" } elseif (-not $MarkB -and $MarkC) { "СТАЛО ХУЖЕ: $MarkC" } elseif ($MarkC) { "осталось: $MarkC" } else { "ок" })
            $Lines += [ordered]@{ Row = $Rw.Name; Trans = [bool]$Rw.Trans; Before = $Vb; After = $Vc; Delta = $Vc - $Vb; ApBefore = (Get-WplanApName $Tb.Key); ApAfter = (Get-WplanApName $Tc.Key); Verdict = $Verdict }
        }
        if ($Lines.Count) { $Res.Bands[$B] = $Lines }
    }
    if (-not $Res.Bands.Count) { $Res.Error = "Нет общих мест между «$Base» и «$Cur» — замеряй те же места под теми же названиями." }
    return $Res
}

function Format-WplanCompare {
    $C = Get-WplanCompare
    if ($C.Error) { return $C.Error }
    $Out = [System.Text.StringBuilder]::new()
    [void]$Out.AppendLine("СРАВНЕНИЕ: «$($C.Base)» → «$($C.Cur)»  (лучшая точка, dBm глазами телефона)")
    foreach ($B in $C.Bands.Keys) {
        [void]$Out.AppendLine("")
        [void]$Out.AppendLine("━━━ $B ГГц ━━━")
        foreach ($L in $C.Bands[$B]) {
            $Name = $(if ($L.Trans) { "↔ $($L.Row)" } else { $L.Row })
            $Ap = $(if ($L.ApBefore -ne $L.ApAfter) { "  ($($L.ApBefore) → $($L.ApAfter))" } else { "" })
            [void]$Out.AppendLine(("{0,-26} {1,5} → {2,5}  {3,6}  {4}{5}" -f $Name, $L.Before, $L.After, (Format-WplanDelta $L.Delta), $L.Verdict, $Ap))
        }
        $Bad = @($C.Bands[$B] | Where-Object { $_.Verdict -like "СТАЛО ХУЖЕ*" }).Count
        $Fix = @($C.Bands[$B] | Where-Object { $_.Verdict -eq "исправлено" }).Count
        [void]$Out.AppendLine("Итог: исправлено $Fix, стало хуже $Bad, мест $(@($C.Bands[$B]).Count)")
    }
    $script:WplanLastCompare = $C
    return $Out.ToString()
}

# ---------------------------------------------------------------- HTML report

function ConvertTo-WplanHtmlText { param([string]$S) return [System.Net.WebUtility]::HtmlEncode("$S") }

function Get-WplanCellClass {
    param($V)
    if ($null -eq $V) { return "na" }
    if ($V -ge -60) { return "g2" } elseif ($V -ge $script:WpEdge) { return "g1" } elseif ($V -ge -75) { return "y" } else { return "r" }
}

function Get-WplanHtmlMatrix {
    param($P, $Map, $Tops, [string]$Title)
    $H = [System.Text.StringBuilder]::new()
    [void]$H.Append("<h4>$(ConvertTo-WplanHtmlText $Title)</h4><table class='mx'><tr><th></th>")
    foreach ($K in $P.Keys) { [void]$H.Append("<th>$(ConvertTo-WplanHtmlText (Get-WplanApName $K))</th>") }
    [void]$H.Append("<th></th></tr>")
    foreach ($Rw in $P.Rows) {
        [void]$H.Append("<tr><td class='rn'>$(if ($Rw.Trans) { '↔ ' })$(ConvertTo-WplanHtmlText $Rw.Name)</td>")
        foreach ($K in $P.Keys) {
            $V = $Map[$Rw.Name][$K]
            $Best = ($Tops[$Rw.Name].Key -eq $K)
            [void]$H.Append("<td class='$(Get-WplanCellClass $V)$(if ($Best) { ' best' })'>$(if ($null -ne $V) { $V } else { '·' })</td>")
        }
        $Mk = Get-WplanRowMark $Tops[$Rw.Name] ([bool]$Rw.Trans)
        [void]$H.Append("<td class='mk'>$(ConvertTo-WplanHtmlText $Mk)</td></tr>")
    }
    [void]$H.Append("</table>")
    return $H.ToString()
}

function Export-WplanHtml {
    $R = Invoke-WplanCalc
    if ($R.Error) { Show-Toast $R.Error "warn"; return }
    $C = Get-WplanCompare
    $H = [System.Text.StringBuilder]::new()
    [void]$H.Append(@"
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wi-Fi план — $(ConvertTo-WplanHtmlText $R.Site)</title>
<style>
body{font:14px/1.45 "Segoe UI",system-ui,sans-serif;margin:0;background:#f6f7f9;color:#1b1f27}
main{max-width:1100px;margin:0 auto;padding:28px 20px 60px}
h1{font-size:26px;margin:0 0 4px} h2{font-size:19px;margin:34px 0 10px;border-bottom:1px solid #dde1e8;padding-bottom:6px} h4{margin:18px 0 6px;font-size:14px;color:#586172}
.sub{color:#586172} table{border-collapse:collapse;margin:4px 0 8px;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 2px rgba(0,0,0,.06)}
th,td{padding:6px 10px;border-bottom:1px solid #eef0f4;text-align:center;white-space:nowrap} th{background:#eef1f6;font-weight:600}
td.rn{text-align:left;font-weight:600} td.mk{color:#cf222e;text-align:left} .best{font-weight:700;outline:2px solid #2f6bff;outline-offset:-2px}
.g2{background:#d8f5df} .g1{background:#eefaf0} .y{background:#fff4d6} .r{background:#ffe1df} .na{color:#aab}
.ap td{text-align:left} .note{color:#586172;white-space:normal} .ok{color:#1a7f37} .bad{color:#cf222e;font-weight:600}
.legend span{display:inline-block;padding:2px 8px;margin-right:6px;border-radius:4px}
@media print{body{background:#fff} main{padding:0}}
</style></head><body><main>
<h1>Wi-Fi план · $(ConvertTo-WplanHtmlText $R.Site)</h1>
<div class="sub">Серия «$(ConvertTo-WplanHtmlText $R.Series)» · замеров: $($R.Points) · мест: $($R.Rows.Count) · $(Get-Date -Format "dd.MM.yyyy HH:mm") · NetKnife</div>
<p class="sub">Значения — dBm «глазами телефона» (замер ноутбука − $($R.Opt.Offset) dB). Цель: основная точка ≥ $($script:WpEdge) dBm; соседняя в чужой комнате ≥ $($script:WpMargin) dB тише; в переходе запасная точка ≥ $($script:WpRoamFloor) dBm. Потолок мощности: 5 ГГц $($R.Opt.Cap5), 2.4 ГГц $($R.Opt.Cap24) dBm.</p>
<p class="legend"><span class="g2">≥ −60</span><span class="g1">≥ $($script:WpEdge)</span><span class="y">≥ −75</span><span class="r">&lt; −75</span> рамка — основная точка, ↔ — переход</p>
"@)
    foreach ($B in @("5", "2.4")) {
        if (-not $R.Bands.Contains($B)) { continue }
        $P = $R.Bands[$B]
        [void]$H.Append("<h2>$B ГГц</h2>")
        [void]$H.Append((Get-WplanHtmlMatrix $P $P.Before $P.TopB "Сейчас"))
        [void]$H.Append((Get-WplanHtmlMatrix $P $P.After $P.TopA "Прогноз после правок"))
        [void]$H.Append("<h4>Настройки точек</h4><table class='ap'><tr><th>Точка</th><th>Канал</th><th>Ширина</th><th>Мощность сейчас</th><th>Рекомендуемая</th><th>Изменение</th><th>Зона</th><th>Примечание</th></tr>")
        foreach ($K in $P.Keys) {
            $A = $P.Aps[$K]
            [void]$H.Append("<tr><td><b>$(ConvertTo-WplanHtmlText $A.Name)</b></td><td>$($P.Channels.Assign[$K] | Select-Object -First 1)</td><td>$($P.Channels.Width) МГц</td><td>$(if ($null -ne $A.Cur) { "$($A.Cur) dBm" } else { '?' })</td><td><b>$(if ($null -ne $A.Rec) { "$($A.Rec) dBm" } else { '?' })</b></td><td>$(Format-WplanDelta $A.Delta)</td><td class='note'>$(ConvertTo-WplanHtmlText ($A.Cell -join ', '))</td><td class='note'>$(ConvertTo-WplanHtmlText $A.Note)</td></tr>")
        }
        [void]$H.Append("</table>")
    }
    if (-not $C.Error) {
        [void]$H.Append("<h2>Проверочный обход: «$(ConvertTo-WplanHtmlText $C.Base)» → «$(ConvertTo-WplanHtmlText $C.Cur)»</h2>")
        foreach ($B in $C.Bands.Keys) {
            [void]$H.Append("<h4>$B ГГц</h4><table class='ap'><tr><th>Место</th><th>Было</th><th>Стало</th><th>Δ</th><th>Точка</th><th>Итог</th></tr>")
            foreach ($L in $C.Bands[$B]) {
                $Cls = $(if ($L.Verdict -like "СТАЛО ХУЖЕ*") { "bad" } elseif ($L.Verdict -eq "исправлено" -or $L.Verdict -eq "ок") { "ok" } else { "note" })
                [void]$H.Append("<tr><td><b>$(if ($L.Trans) { '↔ ' })$(ConvertTo-WplanHtmlText $L.Row)</b></td><td class='$(Get-WplanCellClass $L.Before)'>$($L.Before)</td><td class='$(Get-WplanCellClass $L.After)'>$($L.After)</td><td>$(Format-WplanDelta $L.Delta)</td><td>$(ConvertTo-WplanHtmlText $L.ApBefore)$(if ($L.ApBefore -ne $L.ApAfter) { ' → ' + (ConvertTo-WplanHtmlText $L.ApAfter) })</td><td class='$Cls'>$(ConvertTo-WplanHtmlText $L.Verdict)</td></tr>")
            }
            [void]$H.Append("</table>")
        }
    }
    [void]$H.Append(@"
<h2>Роуминг (Omada)</h2>
<ul>
<li>Site Settings → Wireless Features: <b>Band Steering</b> — вкл. (Prefer 5GHz); <b>Fast Roaming (802.11r)</b> — вкл., если нет старых клиентов; <b>AI Roaming / 802.11k/v</b> — вкл.</li>
<li>Devices → точка → Config → Advanced → <b>Min RSSI</b>: 2.4 ГГц −75 dBm, 5 ГГц −72 dBm — после правки мощностей.</li>
<li>Ширина 2.4 ГГц — 20 МГц. Мощность и канал — вручную, не Auto.</li>
</ul>
</main></body></html>
"@)
    if (-not (Test-Path $script:WplanDir)) { New-Item -ItemType Directory -Path $script:WplanDir | Out-Null }
    $File = Get-WplanPath $R.Site "html"
    [IO.File]::WriteAllText($File, $H.ToString(), [System.Text.UTF8Encoding]::new($false))
    Start-Process $File
    Show-Toast "Отчёт: $([IO.Path]::GetFileName($File))"
}

# ---------------------------------------------------------------- AI review

function Start-WplanAi {
    $R = Invoke-WplanCalc
    if ($R.Error) { Show-Toast $R.Error "warn"; return }
    $C = Get-WplanCompare
    $Sys = "Ты инженер беспроводных сетей, настраиваешь точки TP-Link Omada под плавный роуминг. Даны замеры RSSI (dBm глазами телефона) по помещениям и переходам, текущие мощности, расчёт совместного подбора мощностей (матрица «сейчас» и «прогноз»), каналы и, если есть, сравнение исходного и проверочного обхода. Проверь план, укажи на ошибки и риски, предложи итоговые значения для каждой точки (канал, ширина, мощность dBm) и настройки роуминга Omada. Пиши по-русски, кратко, по пунктам."
    $Bands = [ordered]@{}
    foreach ($B in $R.Bands.Keys) {
        $P = $R.Bands[$B]
        $Bands[$B] = [ordered]@{ Before = $P.Before; Forecast = $P.After; Aps = $P.Aps; Channels = @{ Width = $P.Channels.Width; Assign = $P.Channels.Assign } }
    }
    $Names = @{}; foreach ($K in $script:Wplan.Aps.Keys) { $Names[$K] = Get-WplanApName $K }
    $Data = [ordered]@{ Site = $R.Site; Series = $R.Series; Settings = $R.Opt; Rows = $R.Rows; ApNames = $Names; Bands = $Bands; Compare = $(if ($C.Error) { $null } else { $C.Bands }) } | ConvertTo-Json -Depth 10 -Compress
    $Ui.WpAi.IsEnabled = $false
    $Ui.WpStatus.Text = "Спрашиваю ИИ ($((Get-AiConf).Title))…"
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

function Read-WplanOptFields {
    if (-not $script:Wplan) { return }
    $O = $script:Wplan.Opt
    foreach ($Pair in @(@($Ui.WpOffset, "Offset", 0, 20), @($Ui.WpCap5, "Cap5", 5, 30), @($Ui.WpCap24, "Cap24", 5, 30))) {
        $T = "$($Pair[0].Text)".Trim()
        if ($T -match '^\d{1,2}$' -and [int]$T -ge $Pair[2] -and [int]$T -le $Pair[3]) { $O[$Pair[1]] = [int]$T } else { $Pair[0].Text = "$($O[$Pair[1]])" }
    }
}

function Use-WplanSite {
    $Site = "$($Ui.WpSite.Text)".Trim()
    if (-not $Site) { $Site = "Объект"; $Ui.WpSite.Text = $Site }
    if (-not $script:Wplan -or $script:Wplan.Site -ne $Site) { $script:Wplan = Read-Wplan $Site }
    $script:Wplan.Ssids = @("$($Ui.WpSsids.Text)" -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $Ser = "$($Ui.WpSeries.Text)".Trim()
    if ($Ser) { $script:Wplan.CurSeries = $Ser } else { $Ui.WpSeries.Text = $script:Wplan.CurSeries }
    Read-WplanOptFields
}

function Open-WplanSite {
    param([string]$Site)
    if (-not $Site) { return }
    $script:Wplan = Read-Wplan $Site
    $script:WplanLastReport = $null
    $Ui.WpSite.Text = $Site
    $Ui.WpSsids.Text = (@($script:Wplan.Ssids) -join ", ")
    if (-not $Ui.WpSsids.Text) { try { $Cur = (Get-WlanInfo).Ssid; if ($Cur) { $Ui.WpSsids.Text = $Cur } } catch { } }
    $Ui.WpSeries.Text = $script:Wplan.CurSeries
    $Ui.WpOffset.Text = "$($script:Wplan.Opt.Offset)"; $Ui.WpCap5.Text = "$($script:Wplan.Opt.Cap5)"; $Ui.WpCap24.Text = "$($script:Wplan.Opt.Cap24)"
    $Ui.WpReport.Text = ""
    Refresh-Wplan
}

function Refresh-Wplan {
    $script:WplanPointItems.Clear()
    $script:WplanApItems.Clear()
    if (-not $script:Wplan) { return }
    $i = 0
    foreach ($P in @($script:Wplan.Points)) {
        if ($P.Series -eq $script:Wplan.CurSeries) {
            $Ours = @($P.Samples | Where-Object { Test-WplanOurs $_ })
            $B = $Ours | Sort-Object { [int]$_.Rssi } -Descending | Select-Object -First 1
            $script:WplanPointItems.Add([pscustomobject]@{ Index = $i; Room = $(if ($P.Kind -eq "trans") { "↔ $($P.Room)" } else { $P.Room }); Time = $P.Time; Meta = "своих BSSID: $($Ours.Count)"
                Best = $(if ($B) { "$(Get-WplanApName (Get-WplanKey $B.Bssid)) $($B.Rssi) dBm · $($B.Band)" } else { "—" }) })
        }
        $i++
    }
    foreach ($K in @($script:Wplan.Aps.Keys | Sort-Object { Get-WplanApName $_ })) {
        $A = $script:Wplan.Aps[$K]
        $Tx = @(); if ("$($A.Tx24)") { $Tx += "2.4: $($A.Tx24) dBm" }; if ("$($A.Tx5)") { $Tx += "5: $($A.Tx5) dBm" }
        $script:WplanApItems.Add([pscustomobject]@{ Key = $K; Name = (Get-WplanApName $K); Named = [bool]$A.Name; Meta = "BSSID: $(@($A.Bssids).Count) · $K"; Tx = $(if ($Tx) { $Tx -join " · " } else { "мощность не указана" }) })
    }
    $Ui.WpPointsEmpty.Visibility = $(if ($script:WplanPointItems.Count) { "Collapsed" } else { "Visible" })
    $Ui.WpPointsEmpty.Text = "В серии «$($script:Wplan.CurSeries)» замеров нет."
    Update-PageSub
}

function Get-WplanSub {
    if (-not $script:Wplan) { return "Замеры по комнатам → мощность, каналы и роуминг для точек Omada" }
    $N = @($script:Wplan.Points | Where-Object { $_.Series -eq $script:Wplan.CurSeries }).Count
    return "$($script:Wplan.Site) · серия «$($script:Wplan.CurSeries)»: замеров $N · точек: $($script:Wplan.Aps.Count)"
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
    Add-PickMenu $Ui.WpSeriesPick $Ui.WpSeries {
        $L = @(Get-WplanSeriesList)
        $N = 1; while ($L -contains "После правок $N") { $N++ }
        @($L | ForEach-Object { [pscustomobject]@{ Label = $_; Value = $_ } }) + @([pscustomobject]@{ Label = "+ новая: После правок $N"; Value = "После правок $N" })
    }
    $Ui.WpSite.Add_LostKeyboardFocus({ $S = $Ui.WpSite.Text.Trim(); if ($S -and (-not $script:Wplan -or $script:Wplan.Site -ne $S)) { Open-WplanSite $S } })
    $Ui.WpSite.Add_TextChanged({ $S = $Ui.WpSite.Text.Trim(); if ($S -and (Test-Path (Get-WplanPath $S)) -and (-not $script:Wplan -or $script:Wplan.Site -ne $S)) { Open-WplanSite $S } })
    $Ui.WpSeries.Add_TextChanged({ if ($script:Wplan) { $S = $Ui.WpSeries.Text.Trim(); if ($S -and $S -ne $script:Wplan.CurSeries) { $script:Wplan.CurSeries = $S; $script:WplanLastReport = $null; Save-Wplan; Refresh-Wplan } } })
    foreach ($Fld in @($Ui.WpSsids, $Ui.WpOffset, $Ui.WpCap5, $Ui.WpCap24)) { $Fld.Add_LostKeyboardFocus({ if ($script:Wplan) { Use-WplanSite; Save-Wplan; $script:WplanLastReport = $null; Refresh-Wplan } }) }
    $Ui.WpMeasure.Add_Click({ Start-WplanMeasure })
    $Ui.WpRoom.Add_KeyDown({ param($S, $E) if ("$($E.Key)" -eq "Return") { Start-WplanMeasure; $E.Handled = $true } })
    $Ui.WpCalc.Add_Click({ Use-WplanSite; $Ui.WpReport.Text = Get-WplanReport })
    $Ui.WpCompare.Add_Click({ Use-WplanSite; $Ui.WpReport.Text = Format-WplanCompare })
    $Ui.WpHtml.Add_Click({ Use-WplanSite; Export-WplanHtml })
    $Ui.WpCopy.Add_Click({ if ($Ui.WpReport.Text) { Copy-Text $Ui.WpReport.Text "отчёт" } })
    $Ui.WpCopySheet.Add_Click({ Use-WplanSite; $T = Get-WplanSheet; if ($T) { Copy-Text $T "лист для Omada (вставляется в Excel)" } else { Show-Toast "Сначала замеры и расчёт" "warn" } })
    $Ui.WpAi.Add_Click({ Use-WplanSite; Start-WplanAi })
    $Ui.WpAps.Add_MouseDoubleClick({ $R = $Ui.WpAps.SelectedItem; if ($R) { Show-WplanApDialog $R.Key } })
    $Ui.WpAps.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Имя, мощность, объединить…" 0xE70F { $R = $Ui.WpAps.SelectedItem; if ($R) { Show-WplanApDialog $R.Key } } "2×клик")
        (New-MenuItem "Копировать BSSID" 0xE8C8 { $R = $Ui.WpAps.SelectedItem; if ($R) { Copy-Text (@($script:Wplan.Aps[$R.Key].Bssids) -join "`r`n") "BSSID" } })
    )
    $Ui.WpPoints.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Комната ↔ переход" 0xE8AB {
            $R = $Ui.WpPoints.SelectedItem; if (-not $R) { return }
            $P = @($script:Wplan.Points)[$R.Index]
            $P.Kind = $(if ($P.Kind -eq "trans") { "room" } else { "trans" })
            $script:WplanLastReport = $null; Save-Wplan; Refresh-Wplan
        })
        (New-MenuItem "Удалить замер" 0xE74D {
            $R = $Ui.WpPoints.SelectedItem; if (-not $R) { return }
            $L = [System.Collections.Generic.List[object]]::new(); $j = 0
            foreach ($P in @($script:Wplan.Points)) { if ($j -ne $R.Index) { $L.Add($P) }; $j++ }
            $script:Wplan.Points = @($L); $script:WplanLastReport = $null; Save-Wplan; Refresh-Wplan
        } "" "Fail")
    )
    $Last = "$($script:Settings.WplanSite)"
    if (-not $Last) { $Last = @(Get-WplanSites) | Select-Object -First 1 }
    if ($Last) { Open-WplanSite $Last }
    else {
        $Ui.WpSite.Text = ""; $Ui.WpSeries.Text = $script:WplanBaseSeries
        $O = New-WplanOpt; $Ui.WpOffset.Text = "$($O.Offset)"; $Ui.WpCap5.Text = "$($O.Cap5)"; $Ui.WpCap24.Text = "$($O.Cap24)"
        try { $Cur = (Get-WlanInfo).Ssid; if ($Cur) { $Ui.WpSsids.Text = $Cur } } catch { }
    }
}
