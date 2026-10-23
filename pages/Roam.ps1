# Page: roaming monitor. Walk around with the laptop; every ~0.5 s it records which AP it is on (BSSID, RSSI,
# channel, link rate) and probes four layers in parallel — gateway (ICMP), internet (ICMP to a few hosts),
# DNS (raw UDP query to the configured server, bypassing the Windows cache) and every 2 s the gateway MAC (ARP).
# The UI turns that stream into events (roam with recovery time, Wi-Fi drop, gateway/internet/DNS outage,
# address/subnet/gateway-MAC change) plus live per-AP numbers. Windows WLAN-AutoConfig log entries (disconnect
# reasons) are pulled into the timeline. During a walk the samples become Conn[] and the log becomes Events[];
# the verdicts and the diagnosis are made by the HelpDesk server.

$script:RoamEvents = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:RoamApItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:Roam = $null

$script:RoamBody = {
    param($Q, $Ctl, $Targets, $IntervalMs)
    $LastEv = [DateTime]::Now
    $Tick = 0
    $WlanIds = @(8002, 8003, 11004, 11005, 11006, 11010, 12011, 12012, 12013)
    while (-not $Ctl.Stop) {
        $T0 = [DateTime]::Now
        $W = $null; try { $W = [NetKnife.WlanCur]::Current() } catch { }
        $Ip = ""; $Pfx = 0; $Gw = ""; $DnsSrv = ""
        try {
            # the interface that carries the default route (Wi-Fi bridged into a Hyper-V vSwitch has no IP itself —
            # the address lives on vEthernet); refreshed every ~5 s and whenever it loses its gateway
            if ($Tick % 10 -eq 0 -or -not $IfIndex) {
                try { $IfIndex = (Find-NetRoute -RemoteIPAddress $Targets[0] -ErrorAction Stop | Where-Object { $_.InterfaceIndex } | Select-Object -First 1).InterfaceIndex } catch { $IfIndex = $null }
            }
            $All = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { $_.OperationalStatus -eq "Up" }
            $Nic = $null
            if ($IfIndex) { $Nic = $All | Where-Object { try { $_.GetIPProperties().GetIPv4Properties().Index -eq $IfIndex } catch { $false } } | Select-Object -First 1 }
            if (-not $Nic) { $Nic = $All | Where-Object { $_.NetworkInterfaceType -eq "Wireless80211" } | Select-Object -First 1 }
            if ($Nic) {
                $P = $Nic.GetIPProperties()
                $U = $P.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq "InterNetwork" } | Select-Object -First 1
                if ($U) { $Ip = "$($U.Address)"; $Pfx = [int]$U.PrefixLength }
                $G = $P.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq "InterNetwork" } | Select-Object -First 1
                if ($G) { $Gw = "$($G.Address)" }
                $D = $P.DnsAddresses | Where-Object { $_.AddressFamily -eq "InterNetwork" } | Select-Object -First 1
                if ($D) { $DnsSrv = "$D" }
            }
        } catch { }
        $Tasks = @{}
        if ($Gw) { try { $Tasks.gw = ([System.Net.NetworkInformation.Ping]::new()).SendPingAsync($Gw, 900) } catch { } }
        $i = 0
        foreach ($T in $Targets) { try { $Tasks["n$i"] = ([System.Net.NetworkInformation.Ping]::new()).SendPingAsync($T, 900) } catch { }; $i++ }
        if ($DnsSrv) { $Tasks.dns = [NetKnife.Probe]::DnsAsync($DnsSrv, "www.msftconnecttest.com", 900) }
        if ($Gw -and $Tick % 4 -eq 0) { $Tasks.arp = [NetKnife.Probe]::ArpMacAsync($Gw) }
        if ($Tasks.Count) { try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($Tasks.Values), 1600) } catch { } }

        $PingMs = {
            param($Tk)
            if (-not $Tk -or -not $Tk.IsCompleted -or $Tk.IsFaulted) { return -1 }
            if ("$($Tk.Result.Status)" -eq "Success") { return [int]$Tk.Result.RoundtripTime } else { return -1 }
        }
        $GwMs = $(if ($Gw) { & $PingMs $Tasks.gw } else { -1 })
        $NetMs = -1
        foreach ($K in @($Tasks.Keys | Where-Object { $_ -like "n*" })) { $V = & $PingMs $Tasks[$K]; if ($V -ge 0 -and ($NetMs -lt 0 -or $V -lt $NetMs)) { $NetMs = $V } }
        $DnsMs = $(if ($Tasks.dns -and $Tasks.dns.IsCompleted -and -not $Tasks.dns.IsFaulted) { [int]$Tasks.dns.Result } else { -1 })
        $GwMac = $(if ($Tasks.arp -and $Tasks.arp.IsCompleted -and -not $Tasks.arp.IsFaulted) { "$($Tasks.arp.Result)" } else { $null })

        $Q.Enqueue(@{ Type = "rs"; Time = $T0; State = $(if ($W) { $W.State } else { 4 }); Ssid = $(if ($W) { $W.Ssid } else { "" }); Bssid = $(if ($W) { $W.Bssid } else { "" })
            Rssi = $(if ($W) { $W.Rssi } else { 0 }); Ch = $(if ($W) { $W.Channel } else { 0 }); Rx = $(if ($W) { [int]($W.RxKbps / 1000) } else { 0 }); Tx = $(if ($W) { [int]($W.TxKbps / 1000) } else { 0 })
            Ip = $Ip; Pfx = $Pfx; Gw = $Gw; Dns = $DnsSrv; GwMs = $GwMs; NetMs = $NetMs; DnsMs = $DnsMs; GwMac = $GwMac; HasGw = [bool]$Gw })

        if ($Tick % 10 -eq 9) {
            try {
                $Now = [DateTime]::Now
                $Evs = @(Get-WinEvent -FilterHashtable @{ LogName = "Microsoft-Windows-WLAN-AutoConfig/Operational"; StartTime = $LastEv; Id = $WlanIds } -ErrorAction SilentlyContinue)
                $LastEv = $Now
                foreach ($E in ($Evs | Sort-Object TimeCreated)) {
                    $Lines = @("$($E.Message)" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    $Reason = ($Lines | Where-Object { $_ -match '^(Причина|Reason|Код причины|Failure Reason)' } | Select-Object -First 1)
                    $Q.Enqueue(@{ Type = "rwin"; Time = $E.TimeCreated; Id = $E.Id; Title = $Lines[0]; Reason = "$Reason" })
                }
            } catch { }
        }
        $Tick++
        $Left = $IntervalMs - [int]([DateTime]::Now - $T0).TotalMilliseconds
        while ($Left -gt 0 -and -not $Ctl.Stop) { Start-Sleep -Milliseconds ([Math]::Min(100, $Left)); $Left -= 100 }
    }
}

# ---------------------------------------------------------------- naming

function Get-RoamApName {
    param([string]$Bssid)
    if (-not $Bssid) { return "—" }
    # names of the plan in HelpDesk (aps[].bssids of the selected plan) win
    $Pn = Find-CollectorApName (Get-SurveyPlan) $Bssid
    if ($Pn) { return $Pn }
    $Nm = $script:Settings.RoamNames
    if ($Nm -and $Nm[$Bssid]) { return "$($Nm[$Bssid])" }
    $Mt = Get-MtApName $Bssid
    if ($Mt) { return $Mt }
    return "…" + $Bssid.Substring([Math]::Max(0, $Bssid.Length - 8))
}

function Get-RoamBand { param([int]$Ch) if ($Ch -gt 14) { return "5" } elseif ($Ch -gt 0) { return "2.4" } else { return "" } }

# ---------------------------------------------------------------- events

function Add-RoamEvent {
    param([DateTime]$Time, [string]$Kind, [string]$Title, [string]$Detail = "")
    $E = [pscustomobject]@{ Time = $Time.ToString("HH:mm:ss"); Kind = $Kind; Title = $Title; Detail = $Detail; Raw = $Time }
    $script:RoamEvents.Insert(0, $E)
    while ($script:RoamEvents.Count -gt 500) { $script:RoamEvents.RemoveAt($script:RoamEvents.Count - 1) }
    # with fractions of a second: the walk turns these into Events[].T relative to its start
    $script:Roam.Log.Add([ordered]@{ Time = $Time.ToString("o"); Kind = $Kind; Title = $Title; Detail = $Detail })
    return $E
}

function Set-RoamEvent {
    param($E, [string]$Kind, [string]$Title, [string]$Detail)
    $i = $script:RoamEvents.IndexOf($E)
    $N = [pscustomobject]@{ Time = $E.Time; Kind = $Kind; Title = $Title; Detail = $Detail; Raw = $E.Raw }
    if ($i -ge 0) { $script:RoamEvents[$i] = $N }
    $script:Roam.Log.Add([ordered]@{ Time = $E.Raw.ToString("o"); Kind = $Kind; Title = $Title; Detail = $Detail })
    return $N
}

function Get-RoamStat {
    param([string]$Bssid)
    $S = $script:Roam.Stats
    if (-not $S.ContainsKey($Bssid)) {
        $S[$Bssid] = @{ Bssid = $Bssid; Ssid = ""; Ch = 0; N = 0; Sec = 0.0; RssiSum = 0; RssiMin = 0; GwOk = 0; GwFail = 0; GwSum = 0.0; GwSq = 0.0
            NetOk = 0; NetFail = 0; DnsFail = 0; RoamsIn = 0; RoamOut = @(); Drops = 0; DropSec = 0.0; NetChanges = 0; Disc = 0; Reasons = @() }
    }
    return $S[$Bssid]
}

function Format-RoamSec { param([double]$S) return ("{0:N1} с" -f $S) }

# One sample from the worker → stats + events
function Invoke-RoamSample {
    param($M)
    $R = $script:Roam
    $Prev = $R.Prev
    $Conn = ($M.State -eq 1 -and $M.Bssid)
    $Dt = $(if ($Prev) { [Math]::Min(5.0, ($M.Time - $Prev.Time).TotalSeconds) } else { 0.5 })
    $GwOk = ($M.GwMs -ge 0); $NetOk = ($M.NetMs -ge 0); $DnsOk = ($M.DnsMs -ge 0)

    # loss right after a roam belongs to the roam event, not to the AP's uplink statistics
    $InRoam = ($R.Pending -or ($Prev -and $Prev.Conn -and $Conn -and $Prev.Bssid -ne $M.Bssid))
    # same for probes during a background Wi-Fi scan of the walk (the adapter briefly leaves the channel)
    $InScan = Test-WalkScanning $M.Time
    if ($InScan) { $InRoam = $true }
    if ($Conn) {
        $St = Get-RoamStat $M.Bssid
        $St.Ssid = $M.Ssid; $St.Ch = $M.Ch
        $St.N++; $St.Sec += $Dt; $St.RssiSum += $M.Rssi; if ($St.N -eq 1 -or $M.Rssi -lt $St.RssiMin) { $St.RssiMin = $M.Rssi }
        if (-not $InRoam) {
            if ($M.HasGw) { if ($GwOk) { $St.GwOk++; $St.GwSum += $M.GwMs; $St.GwSq += [double]$M.GwMs * $M.GwMs } else { $St.GwFail++ } }
            if ($NetOk) { $St.NetOk++ } else { $St.NetFail++ }
            if (-not $DnsOk) { $St.DnsFail++ }
        }
    }

    # Wi-Fi drop / reconnect
    if ($Prev -and $Prev.Conn -and -not $Conn) {
        $R.Disc = @{ Time = $M.Time; From = $Prev.Bssid; Rssi = $Prev.Rssi }
        (Get-RoamStat $Prev.Bssid).Disc++
        [void](Add-RoamEvent $M.Time "fail" "Wi-Fi отключился от $(Get-RoamApName $Prev.Bssid)" "сигнал перед этим $($Prev.Rssi) dBm")
    }
    if ($Conn -and $Prev -and -not $Prev.Conn -and $R.Disc) {
        $Sec = ($M.Time - $R.Disc.Time).TotalSeconds
        [void](Add-RoamEvent $M.Time "warn" "Подключился к $(Get-RoamApName $M.Bssid) через $(Format-RoamSec $Sec)" "$($M.Rssi) dBm · канал $($M.Ch)")
        $R.Disc = $null
    }

    # roam: BSSID changed while associated
    if ($Conn -and $Prev -and $Prev.Conn -and $Prev.Bssid -ne $M.Bssid) {
        if ($R.Pending) { Complete-RoamPending $M.Time }
        (Get-RoamStat $M.Bssid).RoamsIn++
        $Title = "Роуминг $(Get-RoamApName $Prev.Bssid) → $(Get-RoamApName $M.Bssid)"
        $Ev = Add-RoamEvent $M.Time "wait" $Title "$($Prev.Rssi) → $($M.Rssi) dBm, канал $($Prev.Ch) → $($M.Ch) · проверяю связь…"
        $R.Pending = @{ Ev = $Ev; T0 = $M.Time; Title = $Title; From = $Prev.Bssid; To = $M.Bssid; RssiFrom = $Prev.Rssi; RssiTo = $M.Rssi
            GwFirst = $null; NetFirst = $null; GwFail = $false; NetFail = $false; Flags = [System.Collections.Generic.List[string]]::new() }
        if ($Prev.Rssi -lt -75) { $R.Pending.Flags.Add("держался за слабую точку до $($Prev.Rssi) dBm") }
    }
    if ($R.Pending -and $Conn) {
        $Pd = $R.Pending
        if ($M.HasGw) { if ($GwOk) { if (-not $Pd.GwFirst) { $Pd.GwFirst = $M.Time } } else { if (-not $Pd.GwFirst) { $Pd.GwFail = $true } } }
        else { if (-not $Pd.GwFirst) { $Pd.GwFail = $true } }
        if ($NetOk) { if (-not $Pd.NetFirst) { $Pd.NetFirst = $M.Time } } elseif (-not $Pd.NetFirst) { $Pd.NetFail = $true }
        if (($Pd.GwFirst -and $Pd.NetFirst) -or ($M.Time - $Pd.T0).TotalSeconds -gt 30) { Complete-RoamPending $M.Time }
    }

    # address / subnet / gateway / gateway MAC changes (VLAN or DHCP trouble)
    if ($Conn -and $Prev -and $Prev.Conn) {
        $Ch = @()
        if ($M.Ip -and $Prev.Ip -and $M.Ip -ne $Prev.Ip) { $Ch += "адрес $($Prev.Ip) → $($M.Ip)" }
        if ($M.Pfx -and $Prev.Pfx -and $M.Pfx -ne $Prev.Pfx) { $Ch += "маска /$($Prev.Pfx) → /$($M.Pfx)" }
        if ($M.Gw -and $Prev.Gw -and $M.Gw -ne $Prev.Gw) { $Ch += "шлюз $($Prev.Gw) → $($M.Gw)" }
        if ($Ch.Count) {
            (Get-RoamStat $M.Bssid).NetChanges++
            [void](Add-RoamEvent $M.Time "warn" "Сменилась сеть на $(Get-RoamApName $M.Bssid)" ($Ch -join "; "))
            if ($R.Pending) { $R.Pending.Flags.Add(($Ch -join "; ")) }
        }
    }
    if ($M.GwMac) {
        if ($R.GwMac -and $R.GwMacIp -eq $M.Gw -and $M.GwMac -ne $R.GwMac) {
            (Get-RoamStat $M.Bssid).NetChanges++
            [void](Add-RoamEvent $M.Time "fail" "MAC шлюза сменился на $(Get-RoamApName $M.Bssid)" "$($R.GwMac) → $($M.GwMac): тот же IP шлюза, другое устройство — другой VLAN/второй DHCP-роутер")
            if ($R.Pending) { $R.Pending.Flags.Add("сменился MAC шлюза") }
        }
        $R.GwMac = $M.GwMac; $R.GwMacIp = $M.Gw
    }

    # outages without a roam in progress
    if ($Conn -and -not $R.Pending -and -not $InScan) {
        $Kind = $(if (-not $M.Ip) { "dhcp" } elseif (-not $GwOk) { "gw" } elseif (-not $NetOk) { "net" } elseif (-not $DnsOk) { "dns" } else { "" })
        if ($Kind) {
            if (-not $R.Out -or $R.Out.Kind -ne $Kind) { if ($R.Out) { Close-RoamOutage $M.Time }; $R.Out = @{ Kind = $Kind; Start = $M.Time; Bssid = $M.Bssid; Rssi = $M.Rssi; N = 0 } }
            $R.Out.N++
        } elseif ($R.Out) { Close-RoamOutage $M.Time }
    } elseif ($R.Out -and -not $Conn) { $R.Out = $null }

    $R.Prev = @{ Time = $M.Time; Conn = $Conn; Bssid = $M.Bssid; Rssi = $M.Rssi; Ch = $M.Ch; Ip = $M.Ip; Pfx = $M.Pfx; Gw = $M.Gw }
    $R.Last = $M
    $R.Count++
}

function Close-RoamOutage {
    param([DateTime]$Now)
    $O = $script:Roam.Out
    $script:Roam.Out = $null
    if (-not $O -or $O.N -lt 2) { return }   # one lost probe is noise
    $Sec = ($Now - $O.Start).TotalSeconds
    $Ap = Get-RoamApName $O.Bssid
    $St = Get-RoamStat $O.Bssid
    switch ($O.Kind) {
        "gw"  { $St.Drops++; $St.DropSec += $Sec; [void](Add-RoamEvent $O.Start "fail" "Пропал шлюз на $Ap на $(Format-RoamSec $Sec)" "Wi-Fi подключён, сигнал $($O.Rssi) dBm — потери между точкой и шлюзом (uplink точки) или помехи") }
        "dhcp" { $St.Drops++; $St.DropSec += $Sec; [void](Add-RoamEvent $O.Start "fail" "Нет IP-адреса на $Ap $(Format-RoamSec $Sec)" "Wi-Fi подключён, DHCP не выдал адрес — VLAN этого SSID не доходит до точки или DHCP-сервер недоступен") }
        "net" { [void](Add-RoamEvent $O.Start "warn" "Пропал интернет на $(Format-RoamSec $Sec) (шлюз отвечает)" "на $Ap — проблема за роутером/провайдером, не Wi-Fi") }
        "dns" { [void](Add-RoamEvent $O.Start "warn" "Не отвечал DNS $(Format-RoamSec $Sec)" "на $Ap; шлюз и интернет отвечали") }
    }
}

function Complete-RoamPending {
    param([DateTime]$Now)
    $Pd = $script:Roam.Pending
    $script:Roam.Pending = $null
    if (-not $Pd) { return }
    $GwSec = $(if ($Pd.GwFail) { $(if ($Pd.GwFirst) { ($Pd.GwFirst - $Pd.T0).TotalSeconds } else { ($Now - $Pd.T0).TotalSeconds }) } else { 0 })
    $NetSec = $(if ($Pd.NetFail) { $(if ($Pd.NetFirst) { ($Pd.NetFirst - $Pd.T0).TotalSeconds } else { ($Now - $Pd.T0).TotalSeconds }) } else { 0 })
    $Lost = $Pd.GwFail -and -not $Pd.GwFirst
    $St = Get-RoamStat $Pd.To
    $St.RoamOut += [Math]::Round([Math]::Max($GwSec, $NetSec), 1)
    $Det = "$($Pd.RssiFrom) → $($Pd.RssiTo) dBm"
    if ($Lost) { $Kind = "fail"; $Det += " · шлюз так и не ответил за 30 с" }
    elseif ($GwSec -ge 1 -or $NetSec -ge 1.5) { $Kind = $(if ($GwSec -ge 3 -or $NetSec -ge 4) { "fail" } else { "warn" }); $Det += " · без связи: шлюз $(Format-RoamSec $GwSec), интернет $(Format-RoamSec $NetSec)" }
    else { $Kind = "ok"; $Det += " · бесшовно" }
    if ($Pd.Flags.Count) { $Det += " · " + ($Pd.Flags -join "; ") }
    [void](Set-RoamEvent $Pd.Ev $Kind $Pd.Title $Det)
}

# ---------------------------------------------------------------- live numbers per AP

function Get-RoamApNumbers {
    param($St)
    $Rssi = $(if ($St.N) { [int]($St.RssiSum / $St.N) } else { 0 })
    $GwN = $St.GwOk + $St.GwFail
    $Loss = $(if ($GwN) { 100.0 * $St.GwFail / $GwN } else { 0 })
    $Avg = $(if ($St.GwOk) { $St.GwSum / $St.GwOk } else { 0 })
    $Jit = $(if ($St.GwOk -gt 1) { [Math]::Sqrt([Math]::Max(0.0, $St.GwSq / $St.GwOk - $Avg * $Avg)) } else { 0 })
    return @{ Rssi = $Rssi; Loss = $Loss; Avg = $Avg; Jit = $Jit }
}

function Update-RoamAps {
    if (-not $script:Roam) { return }
    $Sel = $(if ($Ui.RoamAps.SelectedItem) { $Ui.RoamAps.SelectedItem.Bssid } else { $null })
    $script:RoamApItems.Clear()
    foreach ($St in @($script:Roam.Stats.Values | Sort-Object { -$_.Sec })) {
        $V = Get-RoamApNumbers $St
        $Cur = ($script:Roam.Last -and $script:Roam.Last.Bssid -eq $St.Bssid)
        $Drops = $St.Drops + $St.Disc + @($St.RoamOut | Where-Object { $_ -ge 1 }).Count
        $script:RoamApItems.Add([pscustomobject]@{ Bssid = $St.Bssid; Name = "$(Get-RoamApName $St.Bssid)$(if ($Cur) { '  ●' })"; Kind = $(if ($Drops) { "warn" } else { "ok" })
            Meta = "$($St.Bssid) · кан. $($St.Ch) ($(Get-RoamBand $St.Ch) ГГц) · на точке $(Format-RoamSec $St.Sec)"
            Line = ("{0} dBm · потери {1:N0}% · шлюз {2:N0}±{3:N0} мс · переходов {4} · обрывов {5}" -f $V.Rssi, $V.Loss, $V.Avg, $V.Jit, $St.RoamsIn, $Drops) })
    }
    if ($Sel) { $Ui.RoamAps.SelectedItem = ($script:RoamApItems | Where-Object { $_.Bssid -eq $Sel } | Select-Object -First 1) }
}

# ---------------------------------------------------------------- run

function Start-RoamMonitor {
    if ($script:Roam -and $script:Roam.Running) { return }
    $Targets = @("$($Ui.RoamTargets.Text)" -split '[,;\s]+' | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
    if (-not $Targets.Count) { $Targets = @("8.8.8.8", "77.88.8.8"); $Ui.RoamTargets.Text = $Targets -join ", " }
    $script:Settings.RoamTargets = $Ui.RoamTargets.Text; Save-Settings
    $script:Roam = @{ Running = $true; Started = [DateTime]::Now; Stats = @{}; Log = [System.Collections.Generic.List[object]]::new(); Prev = $null; Last = $null; Pending = $null; Out = $null; Disc = $null; GwMac = ""; GwMacIp = ""; Count = 0
        Mt = $null; MtAp = @{} }
    $RtId = "$($Ui.RoamRouter.SelectedValue)"
    $script:Settings.RoamRouterId = $RtId; Save-Settings
    if ($RtId) {
        $Rt = Get-MtRouter $RtId
        if ($Rt) {
            $script:Roam.Mt = @{ Router = $Rt; Ip = ""; Mac = ""; Lease = ""; Streak = @{}; If = @{}; Err = $false }
            Start-MtApRefresh $Rt   # fresh AP list + names from DHCP
        }
    }
    $script:RoamEvents.Clear(); $script:RoamApItems.Clear()
    $Ui.RoamStart.IsEnabled = $false; $Ui.RoamStop.IsEnabled = $true
    [void](Add-RoamEvent ([DateTime]::Now) "info" "Монитор запущен" "интернет: $($Targets -join ', ') · шаг 0.5 с")
    [void](Start-Worker -Name "roam" -Replace -Body $script:RoamBody -ArgList (@(, $Targets) + @(500)) -OnMessage {
        param($M)
        if (-not $script:Roam -or -not $script:Roam.Running) { return }
        switch ($M.Type) {
            "rs" {
                Invoke-RoamSample $M
                Update-RoamNow $M
                if ($script:Walk -and $script:Walk.Running) { Add-WalkConn $M }
                # router feed follows the laptop's address (a roam into another subnet restarts it)
                $Mt = $script:Roam.Mt
                if ($Mt -and $M.Ip -and $M.Ip -ne $Mt.Ip) {
                    $First = -not $Mt.Ip
                    $Mt.Ip = $M.Ip
                    Start-MtFeed $Mt.Router $M.Ip { param($X) Invoke-RoamMt $X }
                    if ($First) { [void](Add-RoamEvent ([DateTime]::Now) "info" "MikroTik $($Mt.Router.Name): подключаюсь" "ARP/DHCP ноутбука $($M.Ip), пинг до точек, журнал, порты · вход: $(if ($Mt.Router.Ready) { 'butler-service (только чтение)' } else { $Mt.Router.Admin })") }
                }
                if ($script:Roam.Count % 4 -eq 0) { Update-RoamAps }
            }
            "rwin" {
                $Txt = "$($M.Title)$(if ($M.Reason) { ' · ' + $M.Reason })"
                [void](Add-RoamEvent $M.Time $(if ($M.Id -in @(8002, 8003)) { "fail" } else { "warn" }) "Windows: $($M.Title)" "$($M.Reason)")
                if ($script:Roam.Last -and $script:Roam.Last.Bssid) { $St = Get-RoamStat $script:Roam.Last.Bssid; if ($M.Reason) { $St.Reasons = @($St.Reasons) + @($M.Reason) } }
            }
        }
    })
    Update-PageSub
}

function Stop-RoamMonitor {
    param([switch]$Quiet)
    Stop-Worker "roam"
    Stop-MtFeed
    if (-not $script:Roam -or -not $script:Roam.Running) { return }
    $script:Roam.Running = $false
    if ($script:Roam.Pending) { Complete-RoamPending ([DateTime]::Now) }
    if ($script:Roam.Out) { Close-RoamOutage ([DateTime]::Now) }
    $Ui.RoamStart.IsEnabled = $true; $Ui.RoamStop.IsEnabled = $false
    Update-RoamAps
    Update-PageSub
}

function Set-RoamPill {
    param($Pill, $Text, [string]$Label, [int]$Ms, [bool]$Have = $true)
    if (-not $Have) { $Text.Text = "$Label —"; $Pill.Background = Get-Brush "Chip"; $Text.Foreground = Get-Brush "Sub"; return }
    if ($Ms -ge 0) { $Text.Text = "$Label $Ms мс"; $K = $(if ($Ms -lt 50) { "Ok" } else { "Warn" }) } else { $Text.Text = "$Label нет"; $K = "Fail" }
    $Pill.Background = Get-Brush "${K}Soft"; $Text.Foreground = Get-Brush $K
}

function Update-RoamNow {
    param($M)
    if ($M.State -eq 1 -and $M.Bssid) {
        $Ui.RoamNowAp.Text = "$(Get-RoamApName $M.Bssid)"
        $Ui.RoamNowMeta.Text = "$($M.Ssid) · $($M.Bssid) · $($M.Rssi) dBm · канал $($M.Ch) ($(Get-RoamBand $M.Ch) ГГц) · линк $($M.Rx)/$($M.Tx) Мбит/с · $($M.Ip)/$($M.Pfx) → $($M.Gw)"
        $Ui.RoamNowAp.Foreground = Get-Brush $(if ($M.Rssi -ge -67) { "Text" } elseif ($M.Rssi -ge -75) { "Warn" } else { "Fail" })
    } else {
        $St = switch ($M.State) { 5 { "подключается…" } 7 { "аутентификация…" } 6 { "поиск сети…" } 3 { "отключается…" } default { "Wi-Fi не подключён" } }
        $Ui.RoamNowAp.Text = $St; $Ui.RoamNowAp.Foreground = Get-Brush "Fail"; $Ui.RoamNowMeta.Text = ""
    }
    Set-RoamPill $Ui.RoamGwPill $Ui.RoamGwText "шлюз" $M.GwMs $M.HasGw
    Set-RoamPill $Ui.RoamNetPill $Ui.RoamNetText "интернет" $M.NetMs
    Set-RoamPill $Ui.RoamDnsPill $Ui.RoamDnsText "DNS" $M.DnsMs ([bool]$M.Dns)
}

function Get-RoamSub {
    if ($script:Roam -and $script:Roam.Running) { return ("Идёт запись · {0:N0} с · переходов: {1}" -f ([DateTime]::Now - $script:Roam.Started).TotalSeconds, @($script:Roam.Log | Where-Object { $_.Title -like "Роуминг*" }).Count) }
    return "Ходи по объекту — монитор поймает переходы между точками и пропадания связи"
}

function Show-RoamNameDialog {
    param([string]$Bssid)
    $D = New-Dialog "Имя точки" @"
<StackPanel>
    <TextBlock Text="Имя точки" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="$Bssid — как в Omada. Имена из плана в Helpdesk подставляются сами." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,12" FontSize="12.5"/>
    <TextBox x:Name="FName" Style="{StaticResource Field}"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="Сохранить" MinWidth="120" Margin="8,0,0,0" IsDefault="True"/>
    </StackPanel>
</StackPanel>
"@ 460
    $FName = $D.FindName("FName")
    $Nm = $script:Settings.RoamNames; if ($Nm -and $Nm[$Bssid]) { $FName.Text = "$($Nm[$Bssid])" }
    $D.FindName("FOk").Add_Click({ $D.DialogResult = $true })
    $D.Add_ContentRendered({ [void]$FName.Focus() })
    if (-not $D.ShowDialog()) { return }
    if (-not $script:Settings.RoamNames) { $script:Settings.RoamNames = @{} }
    $script:Settings.RoamNames[$Bssid] = $FName.Text.Trim()
    Save-Settings
    Update-RoamAps
}

# ---------------------------------------------------------------- MikroTik feed

function Update-RoamRouterList {
    if (-not $Ui.RoamRouter) { return }
    $Items = @([pscustomobject]@{ Id = ""; Label = "— без роутера —" }) + @(Get-MtRouters | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Label = "$($_.Name)$(if (-not $_.Ready) { ' (не подготовлен)' })" } })
    $Ui.RoamRouter.ItemsSource = $Items
    $Ui.RoamRouter.DisplayMemberPath = "Label"; $Ui.RoamRouter.SelectedValuePath = "Id"
    $Want = "$($script:Settings.RoamRouterId)"
    $Ui.RoamRouter.SelectedValue = $(if ($Want -and ($Items | Where-Object { $_.Id -eq $Want })) { $Want } else { "" })
}

# AP list of the selected router (from the last DHCP read): ip → AP
function Get-RoamMtApByIp {
    param([string]$Ip)
    $Mt = $script:Roam.Mt
    if (-not $Mt) { return $null }
    return @(Get-MtCachedAps $Mt.Router.Id) | Where-Object { $_.Ip -eq $Ip } | Select-Object -First 1
}

function Invoke-RoamMt {
    param($X)
    $R = $script:Roam
    if (-not $R -or -not $R.Running -or -not $R.Mt) { return }
    $Mt = $R.Mt
    $Now = [DateTime]::Now
    $Rn = "MikroTik"
    if ($X.Error) {
        if (-not $Mt.Err) { $Mt.Err = $true; [void](Add-RoamEvent $Now "fail" "$($Rn): $($X.Error)" "проверь роутер в Настройках → Роутеры MikroTik") }
        return
    }
    if ($X.Kind -eq "log") {
        $L = $X.Line -replace '^\d{4}-\d\d-\d\d\s+', '' -replace '^\d\d:\d\d:\d\d\s+', ''
        if ($L -match 'ssh-cmd:|executing script from sshd') { return }   # our own session noise
        $IsDhcp = ($X.Line -match '\bdhcp')
        if ($IsDhcp) {
            $Hit = $false
            if ($Mt.Mac -and $X.Line -match [regex]::Escape($Mt.Mac)) { $Hit = $true }
            if ($Mt.Ip -and $X.Line -match "\b$([regex]::Escape($Mt.Ip))\b") { $Hit = $true }
            foreach ($A in @(Get-MtCachedAps $Mt.Router.Id)) { if ($X.Line -match [regex]::Escape($A.Mac)) { $Hit = $true; break } }
            if (-not $Hit) { return }
        }
        $K = $(if ($X.Line -match '(?i)link down|error|fail|loop|conflict|without success|declin|critical') { "fail" } elseif ($X.Line -match '(?i)link up|warning') { "warn" } else { "info" })
        [void](Add-RoamEvent $Now $K "$($Rn): $L" "журнал роутера")
        return
    }
    $J = $null; try { $J = $X.Json | ConvertFrom-Json -AsHashtable } catch { return }
    $Mt.Err = $false
    switch ($X.Tag) {
        "J" {
            $Arp = @($J.arp) | Select-Object -First 1
            if ($Arp -and $Arp.'mac-address') { $Mt.Mac = "$($Arp.'mac-address')".ToUpper() }
            $Ls = @($J.lease) | Select-Object -First 1
            $Sig = $(if ($Ls) { "$($Ls.address)|$($Ls.server)|$($Ls.status)" } else { "" })
            if ($Ls -and $Sig -ne $Mt.Lease) {
                $Old = $Mt.Lease
                $Mt.Lease = $Sig
                $Kind = $(if ($Old -and ($Old -split '\|')[1] -ne "$($Ls.server)") { "fail" } elseif ($Old) { "warn" } else { "info" })
                [void](Add-RoamEvent $Now $Kind "$($Rn): DHCP ноутбука — $($Ls.address) от $($Ls.server), статус $($Ls.status)" $(if ($Kind -eq "fail") { "сменился DHCP-сервер (был $(($Old -split '\|')[1])) — ноутбук попал в другой VLAN" } else { "MAC $($Ls.'mac-address') · последний раз $($Ls.'last-seen')" }))
            }
        }
        "P" {
            foreach ($Ip in @($J.Keys)) {
                $Ok = ([int]$J[$Ip] -ge 1)
                $Ap = Get-RoamMtApByIp $Ip
                $Key = $(if ($Ap) { $Ap.Key } else { "ip:$Ip" })
                $Name = $(if ($Ap -and $Ap.Name) { $Ap.Name } else { $Ip })
                if (-not $R.MtAp.ContainsKey($Key)) { $R.MtAp[$Key] = @{ Ok = 0; Fail = 0; Name = $Name; Ip = $Ip } }
                $S = $R.MtAp[$Key]
                if ($Ok) { $S.Ok++ } else { $S.Fail++ }
                $Prev = [int]$Mt.Streak[$Ip]
                if ($Ok) {
                    if ($Prev -ge 2) { [void](Add-RoamEvent $Now "ok" "$($Rn): точка $Name ($Ip) снова отвечает роутеру" "не отвечала $Prev проверок подряд (~$(10 * $Prev) с)") }
                    $Mt.Streak[$Ip] = 0
                } else {
                    $Mt.Streak[$Ip] = $Prev + 1
                    if ($Prev + 1 -eq 2) { [void](Add-RoamEvent $Now "fail" "$($Rn): точка $Name ($Ip) не отвечает роутеру" "пинг по проводу роутер → коммутатор → точка: проблема в проводной части или точка перезагружается") }
                }
            }
        }
        "I" {
            foreach ($If in @($J)) {
                $Nm = "$($If.name)"
                $Cur = @{ Run = [bool]$If.running }
                foreach ($F in @("rx-error", "tx-error", "rx-drop", "tx-drop")) { $Cur[$F] = [long]$(if ($null -ne $If[$F]) { $If[$F] } else { 0 }) }
                $Old = $Mt.If[$Nm]
                if ($Old) {
                    if ($Old.Run -ne $Cur.Run) { [void](Add-RoamEvent $Now $(if ($Cur.Run) { "warn" } else { "fail" }) "$($Rn): $Nm $(if ($Cur.Run) { 'поднялся' } else { 'упал (нет линка)' })" "порт роутера") }
                    $D = @()
                    foreach ($F in @("rx-error", "tx-error", "rx-drop", "tx-drop")) { $Dl = $Cur[$F] - $Old[$F]; if ($Dl -gt 0) { $D += "$F +$Dl" } }
                    if ($D.Count) { [void](Add-RoamEvent $Now "warn" "$($Rn): ошибки на $Nm" (($D -join ", ") + " за ~10 с — кабель/порт до коммутатора или перегрузка")) }
                }
                $Mt.If[$Nm] = $Cur
            }
        }
    }
}

function Initialize-RoamPage {
    $Ui.RoamEvents.ItemsSource = $script:RoamEvents
    $Ui.RoamAps.ItemsSource = $script:RoamApItems
    $Ui.RoamTargets.Text = $(if ($script:Settings.RoamTargets) { "$($script:Settings.RoamTargets)" } else { "8.8.8.8, 77.88.8.8" })
    Update-RoamRouterList
    $Ui.RoamStart.Add_Click({ Start-RoamMonitor })
    $Ui.RoamStop.Add_Click({ Stop-RoamMonitor })
    $Ui.RoamCopy.Add_Click({
        $Ev = @($script:RoamEvents | Select-Object -First 200 | ForEach-Object { "$($_.Time)  $($_.Title)$(if ($_.Detail) { ' — ' + $_.Detail })" })
        Copy-Text ($Ev -join "`r`n") "события"
    })
    $Ui.RoamAps.Add_MouseDoubleClick({ $R = $Ui.RoamAps.SelectedItem; if ($R) { Show-RoamNameDialog $R.Bssid } })
    $Ui.RoamAps.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Имя точки…" 0xE70F { $R = $Ui.RoamAps.SelectedItem; if ($R) { Show-RoamNameDialog $R.Bssid } } "2×клик")
        (New-MenuItem "Копировать BSSID" 0xE8C8 { $R = $Ui.RoamAps.SelectedItem; if ($R) { Copy-Text $R.Bssid $R.Bssid } })
    )
}
