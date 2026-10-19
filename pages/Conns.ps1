# Page: which hosts a program talks to. Polls the process (and its children) TCP connections once a second,
# names remote IPs from the Windows DNS client cache (kept as history, since cache entries expire), and flags
# targets that never get past SYN_SENT — exactly the ones blocked without a VPN. Output: domain/IP lists and
# ready-made MikroTik "/ip dns static ... type=FWD" lines to route those names through the tunnel resolver.

$script:ConnItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:ConnRows = @{}          # "ip:port" -> row data
$script:ConnNames = @{}         # ip -> domain (history from DNS cache)
$script:ConnRunning = $false

$script:ConnBody = {
    param($Q, $Ctl, $Pattern)
    $Names = @{}
    $Tick = 0
    $Pids = @()
    while (-not $Ctl.Stop) {
        if ($Tick % 3 -eq 0) {
            # process tree: name match (wildcards ok) + all descendants (updaters spawn helpers)
            try {
                $All = @(Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId, ParentProcessId, Name)
                $Root = @($All | Where-Object { $_.Name -like $Pattern -or $_.Name -like "$Pattern.exe" } | ForEach-Object { [int]$_.ProcessId })
                $Set = [System.Collections.Generic.HashSet[int]]::new()
                foreach ($R in $Root) { [void]$Set.Add($R) }
                $Grew = $true
                while ($Grew) {
                    $Grew = $false
                    foreach ($P in $All) { if ($Set.Contains([int]$P.ParentProcessId) -and $Set.Add([int]$P.ProcessId)) { $Grew = $true } }
                }
                $Pids = @($Set)
                $PNames = @{}; foreach ($P in $All) { if ($Set.Contains([int]$P.ProcessId)) { $PNames[[int]$P.ProcessId] = $P.Name } }
                $Q.Enqueue(@{ Type = "procs"; Count = $Pids.Count; Names = (@($PNames.Values | Sort-Object -Unique) -join ", ") })
            } catch { }
        }
        if ($Tick % 2 -eq 0) {
            try {
                foreach ($D in @(Get-DnsClientCache -ErrorAction Stop)) {
                    if ($D.Type -in @(1, 28) -and $D.Data -and -not $Names.ContainsKey("$($D.Data)")) {
                        $Names["$($D.Data)"] = "$($D.Entry)"
                        $Q.Enqueue(@{ Type = "dns"; Ip = "$($D.Data)"; Name = "$($D.Entry)" })
                    }
                }
            } catch { }
        }
        if ($Pids.Count) {
            try {
                $Conns = @(Get-NetTCPConnection -OwningProcess $Pids -ErrorAction SilentlyContinue | Where-Object { $_.RemoteAddress -and $_.RemoteAddress -notin @("0.0.0.0", "::") -and $_.State -ne "Listen" })
                $Out = foreach ($C in $Conns) { @{ Ip = "$($C.RemoteAddress)"; Port = [int]$C.RemotePort; State = "$($C.State)"; Pid = [int]$C.OwningProcess; Proc = "$($PNames[[int]$C.OwningProcess])" } }
                $Q.Enqueue(@{ Type = "conns"; List = @($Out) })
            } catch { }
        }
        $Tick++
        foreach ($i in 1..5) { if ($Ctl.Stop) { break }; Start-Sleep -Milliseconds 200 }
    }
}

function Test-ConnPrivateIp {
    param([string]$Ip)
    return ($Ip -match '^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|::1$|fe80:|fd)')
}

function Update-ConnRow {
    param([string]$Key)
    $D = $script:ConnRows[$Key]
    $Name = $script:ConnNames[$D.Ip]
    $Kind = "ok"; $St = "подключён"
    if (-not $D.Ever) {
        $Wait = ([DateTime]::Now - $D.First).TotalSeconds
        if ($Wait -gt 4) { $Kind = "fail"; $St = "не подключается" } else { $Kind = "wait"; $St = "подключается…" }
    } elseif (-not $D.Live) { $Kind = "none"; $St = "закрыт" }
    $Row = [pscustomobject]@{
        Key = $Key; Host = $(if ($Name) { $Name } else { "—" }); HasName = [bool]$Name
        Ip = $D.Ip; Port = $D.Port; Target = "$($D.Ip):$($D.Port)"; Proc = $D.Proc
        StatusText = $St; Kind = $Kind; Count = "×$($D.Hits)"
        Seen = $D.Last.ToString("HH:mm:ss")
    }
    for ($i = 0; $i -lt $script:ConnItems.Count; $i++) {
        if ($script:ConnItems[$i].Key -eq $Key) { $script:ConnItems[$i] = $Row; return }
    }
    # failed targets on top
    if ($Kind -eq "fail") { $script:ConnItems.Insert(0, $Row) } else { $script:ConnItems.Add($Row) }
}

function Start-ConnWatch {
    $Pat = $Ui.ConnProc.Text.Trim() -replace '\.exe$', ''
    if (-not $Pat) { Show-Toast "Укажи процесс (имя или маска, напр. Composer*)" "warn"; [void]$Ui.ConnProc.Focus(); return }
    if ($Pat -notmatch '[\*\?]') { $Pat = "$Pat*" }
    $script:ConnRows = @{}
    $script:ConnItems.Clear()
    $script:ConnRunning = $true
    $script:Settings.ConnLastProc = $Ui.ConnProc.Text.Trim(); Save-Settings
    $Ui.ConnStart.IsEnabled = $false; $Ui.ConnStop.IsEnabled = $true
    $Ui.ConnProcs.Text = "ищу процесс $Pat…"
    $HideLan = [bool]$Ui.ConnHideLan.IsChecked
    [void](Start-Worker -Name "conns" -Replace -Body $script:ConnBody -ArgList @($Pat) -OnMessage {
        param($M)
        switch ($M.Type) {
            "procs" { $Ui.ConnProcs.Text = $(if ($M.Count) { "процессов: $($M.Count) · $($M.Names)" } else { "процесс не запущен — запусти программу, слежка продолжается" }) }
            "dns" {
                if (-not $script:ConnNames.ContainsKey($M.Ip)) {
                    $script:ConnNames[$M.Ip] = $M.Name
                    foreach ($K in @($script:ConnRows.Keys)) { if ($script:ConnRows[$K].Ip -eq $M.Ip) { Update-ConnRow $K } }
                }
            }
            "conns" {
                $Now = [DateTime]::Now
                $Seen = @{}
                foreach ($C in @($M.List)) {
                    if ([bool]$Ui.ConnHideLan.IsChecked -and (Test-ConnPrivateIp $C.Ip)) { continue }
                    $K = "$($C.Ip):$($C.Port)"
                    $Seen[$K] = $true
                    $D = $script:ConnRows[$K]
                    if (-not $D) { $D = @{ Ip = $C.Ip; Port = $C.Port; Proc = $C.Proc; First = $Now; Last = $Now; Hits = 0; Ever = $false; Live = $true; Prev = "" }; $script:ConnRows[$K] = $D }
                    if ($C.State -ne $D.Prev) { $D.Hits++ }
                    $D.Prev = $C.State; $D.Last = $Now; $D.Live = $true
                    if ($C.State -eq "Established" -or $C.State -eq "CloseWait" -or $C.State -eq "FinWait2" -or $C.State -eq "TimeWait") { $D.Ever = $true }
                    if ($C.State -eq "SynSent" -and -not $D.Ever) { $D.Pending = $true }
                    Update-ConnRow $K
                }
                foreach ($K in @($script:ConnRows.Keys)) {
                    $D = $script:ConnRows[$K]
                    if (-not $Seen.ContainsKey($K) -and $D.Live) { $D.Live = $false; $D.Prev = ""; Update-ConnRow $K }
                    elseif (-not $D.Ever) { Update-ConnRow $K }   # re-evaluate "не подключается" timeout
                }
                Update-ConnSummary
            }
        }
    })
    Update-PageSub
}

function Stop-ConnWatch {
    Stop-Worker "conns"
    $script:ConnRunning = $false
    $Ui.ConnStart.IsEnabled = $true; $Ui.ConnStop.IsEnabled = $false
    Update-PageSub
}

function Update-ConnSummary {
    $All = @($script:ConnItems)
    $Fail = @($All | Where-Object { $_.Kind -eq "fail" }).Count
    $Hosts = @($All | Where-Object { $_.HasName } | ForEach-Object Host | Sort-Object -Unique).Count
    $Ui.ConnSummary.Text = "адресов: $($All.Count) · доменов: $Hosts" + $(if ($Fail) { " · не подключаются: $Fail" } else { "" })
    $Ui.ConnSummary.Foreground = Get-Brush $(if ($Fail) { "Fail" } else { "Sub" })
}

function Get-ConnsSub {
    if ($script:ConnRunning) { return "Слежу за «$($Ui.ConnProc.Text.Trim())» · TCP раз в секунду, имена из DNS-кэша Windows" }
    return "Куда ходит программа: домены и IP — чтобы добавить их в проброс через VPN"
}

# which rows to export: only failing ones, or all
function Get-ConnExportRows {
    $Rows = @($script:ConnItems)
    if ([bool]$Ui.ConnOnlyFail.IsChecked) { $Rows = @($Rows | Where-Object { $_.Kind -eq "fail" }) }
    return $Rows
}

function Copy-ConnList {
    param([string]$What)
    $Rows = Get-ConnExportRows
    if (-not $Rows.Count) { Show-Toast "Список пуст" "warn"; return }
    switch ($What) {
        "domains" {
            $L = @($Rows | Where-Object { $_.HasName } | ForEach-Object Host | Sort-Object -Unique)
            $NoName = @($Rows | Where-Object { -not $_.HasName }).Count
            if (-not $L.Count) { Show-Toast "Ни у одного адреса нет имени в DNS-кэше — копируй IP" "warn"; return }
            Copy-Text ($L -join "`r`n") "доменов: $($L.Count)$(if ($NoName) { " (ещё $NoName адресов без имени — см. IP)" })"
        }
        "ips" {
            $L = @($Rows | ForEach-Object Ip | Sort-Object -Unique)
            Copy-Text ($L -join "`r`n") "IP: $($L.Count)"
        }
        "mikrotik" {
            $Fwd = $Ui.ConnFwd.Text.Trim()
            if (-not $Fwd) { Show-Toast "Укажи DNS для FWD (resolver на стороне VPN)" "warn"; [void]$Ui.ConnFwd.Focus(); return }
            $script:Settings.ConnFwdTo = $Fwd; Save-Settings
            $L = @($Rows | Where-Object { $_.HasName } | ForEach-Object Host | Sort-Object -Unique)
            if (-not $L.Count) { Show-Toast "Нет доменов — для IP используй address-list" "warn"; return }
            $Lines = foreach ($N in $L) { "/ip dns static add name=$N type=FWD forward-to=$Fwd match-subdomain=yes comment=`"NetKnife $($Ui.ConnProc.Text.Trim())`"" }
            Copy-Text ($Lines -join "`r`n") "MikroTik FWD: $($L.Count) строк"
        }
        "addrlist" {
            $L = @($Rows | ForEach-Object Ip | Where-Object { $_ -notmatch ':' } | Sort-Object -Unique)
            $Lines = foreach ($I in $L) { "/ip firewall address-list add list=vpn address=$I comment=`"NetKnife $($Ui.ConnProc.Text.Trim())`"" }
            Copy-Text ($Lines -join "`r`n") "MikroTik address-list: $($L.Count) строк"
        }
    }
}

function Initialize-ConnsPage {
    $Ui.ConnList.ItemsSource = $script:ConnItems
    $Ui.ConnProc.Text = $(if ($script:Settings.ConnLastProc) { "$($script:Settings.ConnLastProc)" } else { "" })
    $Ui.ConnFwd.Text = $(if ($script:Settings.ConnFwdTo) { "$($script:Settings.ConnFwdTo)" } else { "" })
    Add-PickMenu $Ui.ConnProcPick $Ui.ConnProc {
        # processes that currently hold remote TCP connections first, then everything with a window
        $Net = @{}
        try { foreach ($C in @(Get-NetTCPConnection -State Established, SynSent -ErrorAction SilentlyContinue)) { $Net[[int]$C.OwningProcess] = 1 + [int]$Net[[int]$C.OwningProcess] } } catch { }
        $Procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -gt 4 })
        $ByName = $Procs | Group-Object ProcessName | ForEach-Object {
            $N = 0; foreach ($P in $_.Group) { $N += [int]$Net[$P.Id] }
            [pscustomobject]@{ Name = $_.Name; Conns = $N; Win = [bool]($_.Group | Where-Object { $_.MainWindowTitle }) }
        }
        $ByName | Where-Object { $_.Conns -or $_.Win } | Sort-Object @{ E = { -$_.Conns } }, Name | Select-Object -First 40 |
            ForEach-Object { [pscustomobject]@{ Label = "$($_.Name)$(if ($_.Conns) { "   · соединений: $($_.Conns)" })"; Value = $_.Name } }
    }
    $Ui.ConnStart.Add_Click({ Start-ConnWatch })
    $Ui.ConnStop.Add_Click({ Stop-ConnWatch })
    $Ui.ConnClear.Add_Click({ $script:ConnRows = @{}; $script:ConnItems.Clear(); Update-ConnSummary })
    $Ui.ConnProc.Add_KeyDown({ param($S, $E) if ("$($E.Key)" -eq "Return") { Start-ConnWatch; $E.Handled = $true } })
    $Ui.ConnCopyDomains.Add_Click({ Copy-ConnList "domains" })
    $Ui.ConnCopyIps.Add_Click({ Copy-ConnList "ips" })
    $Ui.ConnCopyMt.Add_Click({ param($S, $E) Show-Menu $S @(
        (New-MenuItem "DNS static FWD (домены → DNS за VPN)" 0xE8C8 { Copy-ConnList "mikrotik" })
        (New-MenuItem "Firewall address-list vpn (IP)" 0xE8C8 { Copy-ConnList "addrlist" })
    ) })
    $Ui.ConnList.ContextMenu = New-ContextMenu @(
        (New-MenuItem "Копировать домен" 0xE8C8 { $R = $Ui.ConnList.SelectedItem; if ($R -and $R.HasName) { Copy-Text $R.Host $R.Host } })
        (New-MenuItem "Копировать IP" 0xE8C8 { $R = $Ui.ConnList.SelectedItem; if ($R) { Copy-Text $R.Ip $R.Ip } })
        (New-MenuItem "Пинг" 0xE9D9 { $R = $Ui.ConnList.SelectedItem; if ($R) { Start-PingFor $(if ($R.HasName) { $R.Host } else { $R.Ip }) } })
        (New-MenuItem "Проверить порт" 0xE839 { $R = $Ui.ConnList.SelectedItem; if ($R) { Open-PortsFor $R.Ip } })
    )
}
