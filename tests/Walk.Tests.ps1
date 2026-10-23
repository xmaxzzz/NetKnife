# Pester 5: the walk file of pages\Walk.ps1 (§4.1, §4.4) — shape of what goes into the envelope, without WPF.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:DataDir = Join-Path ([IO.Path]::GetTempPath()) ("nk-walk-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $DataDir | Out-Null
    function Write-AppLog { param([string]$Text) }
    . (Join-Path $Root "lib\Collector.ps1")
    . (Join-Path $Root "pages\Walk.ps1")
    $script:RoamEvents = New-Object System.Collections.ObjectModel.ObservableCollection[object]

    function New-TestWalkState {
        param([DateTime]$Started = [DateTime]::Now.AddMinutes(-2))
        return @{ Id = "20261023-120000-LAPTOP-1"; Phase = "before"; Series = "Исходная"; Running = $true; Started = $Started; Base = (Join-Path $DataDir ("zzz-test.walk-" + [Guid]::NewGuid().ToString("N").Substring(0, 6))); Wav = ""; Mic = $null
            Target = @{ Site = "zzz-test" }; Plan = $null; Duration = 120.0
            Clicks = [System.Collections.Generic.List[object]]::new(); Scans = [System.Collections.Generic.List[object]]::new(); Conn = [System.Collections.Generic.List[object]]::new()
            Marks = [System.Collections.Generic.List[object]]::new(); Rooms = [System.Collections.Generic.List[object]]::new(); Events = @(); ScanUntil = [DateTime]::MinValue; ScanErr = ""; CpNext = 0 }
    }
    function Read-Saved { param([string]$Suffix = ".json") return (Get-Content "$($script:Walk.Base)$Suffix" -Raw -Encoding UTF8 | ConvertFrom-Json) }
}

Describe "файл обхода" {
    BeforeEach { $script:Walk = New-TestWalkState; $script:Roam = @{ Log = [System.Collections.Generic.List[object]]::new() } }

    It "одно событие — всё равно массив Events[], Rooms[] — массив; полей анализа нет" {
        $script:Walk.Events = @(@{ T = 0.0; Kind = "info"; Title = "Монитор запущен"; Detail = "" })
        Add-WalkRoom "Кухня"
        Save-WalkFile
        $Raw = Get-Content "$($script:Walk.Base).json" -Raw
        $Raw | Should -Match '"Events":\[\{'
        $Raw | Should -Match '"Rooms":\[\{"'
        foreach ($K in "Words", "Phrases", "Timeline", "Notes") { $Raw | Should -Not -Match "`"$K`"" }
        $J = Read-Saved
        $J.Rooms[0].Room | Should -Be "Кухня"
        $J.Id | Should -Be "20261023-120000-LAPTOP-1"
        $Raw | Should -Match '"Started":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}[+-]\d\d:\d\d"'
        Test-WalkFileCompatible $Raw | Should -BeNullOrEmpty
    }
    It "ни одного события — Events: []" {
        Save-WalkFile
        Get-Content "$($script:Walk.Base).json" -Raw | Should -Match '"Events":\[\]'
    }
    It "раз в 30 с — .json.partial с текущей длительностью и событиями монитора" {
        $script:Roam.Log.Add([ordered]@{ Time = [DateTime]::Now.ToString("o"); Kind = "warn"; Title = "Роуминг A → B"; Detail = "x" })
        Save-WalkFile -Partial
        $J = Read-Saved ".json.partial"
        $J.Duration | Should -BeGreaterThan 100
        @($J.Events).Count | Should -Be 1
        Test-Path "$($script:Walk.Base).json" | Should -BeFalse
    }
    It "Events[]: T ≥ 0, события до старта обхода отброшены, Title ≤ 300, Detail ≤ 1000, дубли роуминга схлопнуты" {
        $S = $script:Walk.Started
        $script:Roam.Log.Add([ordered]@{ Time = $S.AddMinutes(-3).ToString("o"); Kind = "info"; Title = "Монитор запущен"; Detail = "" })
        $script:Roam.Log.Add([ordered]@{ Time = $S.AddSeconds(-0.7).ToString("o"); Kind = "info"; Title = "Монитор запущен"; Detail = "" })
        $script:Roam.Log.Add([ordered]@{ Time = $S.AddSeconds(10).ToString("o"); Kind = "warn"; Title = ("М" * 400); Detail = ("д" * 1500) })
        $script:Roam.Log.Add([ordered]@{ Time = $S.AddSeconds(20).ToString("o"); Kind = "wait"; Title = "Роуминг A → B"; Detail = "проверяю связь…" })
        $script:Roam.Log.Add([ordered]@{ Time = $S.AddSeconds(20).ToString("o"); Kind = "ok"; Title = "Роуминг A → B"; Detail = "бесшовно" })
        $E = @(Get-WalkEvents)
        $E.Count | Should -Be 3
        $E[0].T | Should -Be 0
        foreach ($X in $E) { $X.T | Should -BeGreaterOrEqual 0 }
        $E[1].Title.Length | Should -Be 300
        $E[1].Detail.Length | Should -Be 1000
        ($E | Where-Object { $_.Title -like "Роуминг*" }).Kind | Should -Be "ok"
    }
    It "Conn[]: Ip, Pfx, GwIp, GwMac, Dns, Ssid из монитора" {
        Add-WalkConn @{ Time = [DateTime]::Now; State = 1; Bssid = "aa:bb"; Rssi = -60; Ch = 36; GwMs = 3; NetMs = 20; DnsMs = 15; Ip = "10.0.0.5"; Pfx = 24; Gw = "10.0.0.1"; GwMac = "AA-BB"; Ssid = "Парус" }
        $C = $script:Walk.Conn[0]
        $C.Ip | Should -Be "10.0.0.5"; $C.Pfx | Should -Be 24; $C.GwIp | Should -Be "10.0.0.1"; $C.GwMac | Should -Be "AA-BB"; $C.Dns | Should -Be 15; $C.Ssid | Should -Be "Парус"
        $C.Gw | Should -Be 3; $C.Net | Should -Be 20; $C.Conn | Should -BeTrue
    }
}
