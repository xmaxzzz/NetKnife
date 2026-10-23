# Pester 5: lib\Collector.ps1 against an in-memory server (tests\FakeServer.ps1). Runs on Windows and on pwsh/Linux;
# DPAPI is Windows-only.  Run:  Invoke-Pester -Path tests

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Lib = Join-Path $Root "lib\Collector.ps1"
    . $Lib
    . (Join-Path $PSScriptRoot "FakeServer.ps1")

    function Reset-Env {
        $script:DataDir = $null
        $D = Join-Path ([IO.Path]::GetTempPath()) ("nk-col-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory -Path $D | Out-Null
        $env:APPDATA = $D
        $script:CollectorLogPath = Join-Path $D "collector.log"
        return $D
    }
    function New-TestWalk {
        param([string]$Id = "20261023-120000-LAPTOP-1", [string]$Extra = "")
        return '{"Id":"' + $Id + '","Site":"zzz","Phase":"before","Series":"Исходная","Started":"2026-10-23T12:00:00.7000000+04:00","Duration":61.5,"Clicks":[],"Marks":[{"T":3.0,"Text":"отметка «тут плохо»"}],"Conn":[{"T":0.5,"Conn":true,"Bssid":"aa:bb:cc:dd:ee:f0","Rssi":-55,"Ip":"10.0.0.5","Pfx":24,"GwIp":"10.0.0.1","GwMac":"AA-BB","Dns":12,"Ssid":"Парус"}],"Scans":[],"Events":[],"Rooms":[{"T":10.0,"Room":"Кухня"}]' + $Extra + '}'
    }
    function New-TestWav {
        param([string]$Path, [int]$Bytes = 4544)
        $B = New-Object byte[] $Bytes
        $R = [Random]::new(5); $R.NextBytes($B)
        [Text.Encoding]::ASCII.GetBytes("RIFF").CopyTo($B, 0)
        [IO.File]::WriteAllBytes($Path, $B)
        return $Path
    }
    function Get-Target { return @{ Url = "https://hd.test"; Site = "zzz-test"; SiteName = "ZZZ тест"; PlanId = 12; PlanName = "Основной"; Series = "before"; SeriesLabel = "Исходная"; Phase = "before" } }
    function Get-Conns { return @{ "https://hd.test|zzz-test" = @{ Url = "https://hd.test"; Token = $script:Fake.Token; Limits = @{ walk_bytes = 16MB } } } }
    function Get-Calls { param([string]$Method, [string]$Path) return , @($script:Fake.Calls | Where-Object { $_.Method -eq $Method -and $_.Path -match $Path }) }
}

Describe "строка подключения" {
    It "разбирает JSON hd-wifi-pair/1" {
        $C = "B" * 43
        $R = ConvertFrom-PairString ('{"t":"hd-wifi-pair/1","url":"https://help.butlerdc.ae/","code":"' + $C + '","site":"alye-parusa"}')
        $R.Error | Should -BeNullOrEmpty
        $R.Url | Should -Be "https://help.butlerdc.ae"
        $R.Code | Should -Be $C
        $R.Site | Should -Be "alye-parusa"
    }
    It "голый код из 43 символов берёт URL из настроек" {
        $R = ConvertFrom-PairString ("aZ09_-" + ("x" * 37)) "https://hd.test"
        $R.Url | Should -Be "https://hd.test"
        $R.Code.Length | Should -Be 43
    }
    It "голый код без URL — ошибка" { (ConvertFrom-PairString ("x" * 43)).Error | Should -Not -BeNullOrEmpty }
    It "чужой формат — «это не код HelpDesk»" {
        (ConvertFrom-PairString '{"t":"other/1","url":"https://x","code":"y"}').Error | Should -Match "не код"
        (ConvertFrom-PairString "привет").Error | Should -Match "не код"
        (ConvertFrom-PairString ("x" * 42)).Error | Should -Match "не код"
    }
}

Describe "pair" {
    BeforeEach { Reset-Env | Out-Null; New-FakeServer | Out-Null; Mock Invoke-CollectorHttp { Invoke-FakeHttp -Method $Method -Uri $Uri -Headers $Headers -Body $Body -ContentType $ContentType -TimeoutSec $TimeoutSec -Binary:$Binary } }
    It "200 — токен, объект, план по умолчанию; имя сборщика «NetKnife <компьютер>»" {
        $R = Invoke-CollectorPair -Url "https://hd.test" -Code $Fake.Code -Name "NetKnife LAPTOP-1"
        $R.Ok | Should -BeTrue
        $R.Token | Should -Be $Fake.Token
        $R.Site.slug | Should -Be "zzz-test"
        $R.PlanId | Should -Be 12
        $C = (Get-Calls POST '/pair$')[0]
        $C.Headers.Authorization | Should -BeNullOrEmpty
        ([Text.Encoding]::UTF8.GetString($C.Body) | ConvertFrom-Json).name | Should -Be "NetKnife LAPTOP-1"
    }
    It "410 — код использован: просим новый" {
        Invoke-CollectorPair -Url "https://hd.test" -Code $Fake.Code | Out-Null
        $R = Invoke-CollectorPair -Url "https://hd.test" -Code $Fake.Code
        $R.Ok | Should -BeFalse; $R.Code | Should -Be 410; $R.Error | Should -Match "новый код"
    }
    It "429 — ждать Retry-After" {
        Add-FakeFault POST '/pair$' 429 @{ code = "rate_limited"; detail = "лимит" } @{ "Retry-After" = "17" }
        $R = Invoke-CollectorPair -Url "https://hd.test" -Code $Fake.Code
        $R.Code | Should -Be 429; $R.Wait | Should -Be 17
    }
    It "/me: scope и лимиты из ответа" {
        $M = Get-CollectorMe @{ Url = "https://hd.test"; Token = $Fake.Token; Version = "1" }
        $M.Ok | Should -BeTrue
        Format-CollectorMe $M.Me | Should -Match "ZZZ тест.*…cdef.*не распознаёт.*16 МБ"
        $Fake.Revoked = $true
        (Get-CollectorMe @{ Url = "https://hd.test"; Token = $Fake.Token; Version = "1" }).Error | Should -Match "заново кодом"
    }
    It "справочник кэшируется, картинка качается только при новом sha256" {
        $Ctx = @{ Url = "https://hd.test"; Token = $Fake.Token; Version = "1" }
        (Update-CollectorSites $Ctx "https://hd.test|zzz-test").Ok | Should -BeTrue
        (Update-CollectorSites $Ctx "https://hd.test|zzz-test").Ok | Should -BeTrue
        (Get-Calls GET '/plans/12/image$').Count | Should -Be 1
        $C = Read-CollectorSitesCache
        $C["https://hd.test|zzz-test"].sites[0].plans[0].name | Should -Be "Основной"
        Test-Path (Join-Path (Get-CollectorCacheDir) "plan-12-ab12.png") | Should -BeTrue
        Find-CollectorApName $C["https://hd.test|zzz-test"].sites[0].plans[0] "aa-bb-cc-dd-ee-f0" | Should -Be "EAP-кухня"
    }
}

Describe "конверт и gzip" {
    BeforeEach { Reset-Env | Out-Null; New-FakeServer | Out-Null; Mock Invoke-CollectorHttp { Invoke-FakeHttp -Method $Method -Uri $Uri -Headers $Headers -Body $Body -ContentType $ContentType -TimeoutSec $TimeoutSec -Binary:$Binary } }
    It "Id: yyyyMMdd-HHmmss-<устройство>, не длиннее 64" {
        New-CollectorWalkId ([DateTime]"2026-10-23 12:34:56") "LAPTOP 1" | Should -Be "20261023-123456-LAPTOP_1"
        (New-CollectorWalkId ([DateTime]::Now) ("D" * 80)).Length | Should -Be 64
    }
    It "текст обхода вклеен как есть, тело — gzip, распаковывается в тот же JSON, кириллица цела" {
        $W = New-TestWalk
        $A = Add-OutboxWalk -WalkJson $W -Target (Get-Target) -Version "2026.10.23.1"
        $A.Ok | Should -BeTrue
        $Env = [IO.File]::ReadAllText((Join-Path $A.Dir "envelope.json"), [Text.Encoding]::UTF8)
        $Env | Should -BeLike '*"walk":{"Id":"20261023-120000-LAPTOP-1"*'
        $Env | Should -BeLike '*"Started":"2026-10-23T12:00:00.7000000+04:00"*'
        (Invoke-OutboxItem $A.Dir @{ Url = "https://hd.test"; Token = $Fake.Token; Version = "1" }).Outcome | Should -Be "sent"
        $C = (Get-Calls POST '/walks$')[0]
        $C.Headers["Content-Encoding"] | Should -Be "gzip"
        $C.ContentType | Should -Match "application/json"
        ([byte[]]$C.Body)[0..1] | Should -Be @(0x1f, 0x8b)
        $Fake.LastEnvelope | Should -BeExactly $Env
        $J = $Fake.LastEnvelope | ConvertFrom-Json
        $J.format | Should -Be "netknife-survey/1"
        $J.plan_id | Should -Be 12
        $J.collector.audio | Should -BeFalse
        $J.walk.Rooms[0].Room | Should -Be "Кухня"
        $J.walk.Conn[0].Ssid | Should -Be "Парус"
    }
    It "повтор того же конверта — 200 и тот же id" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -Target (Get-Target)
        Invoke-OutboxItem $A.Dir @{ Url = "https://hd.test"; Token = $Fake.Token } | Out-Null
        $Id = (Read-OutboxState $A.Dir).ServerId
        Reset-OutboxRetry $A.Dir
        $St = Read-OutboxState $A.Dir; $St.ServerId = $null; Save-OutboxState $A.Dir $St
        Invoke-OutboxItem $A.Dir @{ Url = "https://hd.test"; Token = $Fake.Token } | Out-Null
        $S2 = Read-OutboxState $A.Dir
        $S2.ServerId | Should -Be $Id
        $S2.Created | Should -BeFalse
        $Fake.Walks.Count | Should -Be 1
    }
    It "старая прогулка: Words/Phrases/Timeline/Notes убраны из копии, исходник не тронут" {
        $D = Join-Path $env:APPDATA "NetKnife\wifiplan"; New-Item -ItemType Directory $D -Force | Out-Null
        $P = Join-Path $D "zzz.walk-20261001-100000.json"
        $Old = New-TestWalk "20261001-100000" ',"Words":[{"T0":1,"T1":2,"Text":"кухня"}],"Phrases":[{"T0":1,"Text":"кухня"}],"Timeline":[{"Room":"Кухня"}],"Notes":[]'
        [IO.File]::WriteAllText($P, $Old, [Text.UTF8Encoding]::new($false))
        $Before = Get-FileHash $P
        $A = Add-OutboxLegacyWalk -Path $P -Target (Get-Target)
        $A.Ok | Should -BeTrue
        (Get-FileHash $P).Hash | Should -Be $Before.Hash
        $E = [IO.File]::ReadAllText((Join-Path $A.Dir "envelope.json"))
        foreach ($K in "Words", "Phrases", "Timeline", "Notes") { $E | Should -Not -Match "`"$K`"" }
        $E | Should -BeLike '*"Started":"2026-10-23T12:00:00.7000000+04:00"*'
        ($E | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain "series"
    }
    It "несовместимая старая прогулка не ставится в очередь" {
        $P = Join-Path $env:APPDATA "bad.walk-1.json"
        [IO.File]::WriteAllText($P, '{"Id":"x","Started":"2026-10-01T10:00:00+04:00"}')
        $A = Add-OutboxLegacyWalk -Path $P -Target (Get-Target)
        $A.Ok | Should -BeFalse
        $A.Error | Should -Match "Duration"
        @(Get-OutboxItems).Count | Should -Be 0
    }
}

Describe "запись частями" {
    BeforeEach {
        Reset-Env | Out-Null; New-FakeServer -PartSize 1000 | Out-Null
        Mock Invoke-CollectorHttp { Invoke-FakeHttp -Method $Method -Uri $Uri -Headers $Headers -Body $Body -ContentType $ContentType -TimeoutSec $TimeoutSec -Binary:$Binary }
        $script:Wav = New-TestWav (Join-Path $env:APPDATA "w.wav") 4544
        $script:Ctx = @{ Url = "https://hd.test"; Token = $Fake.Token; Version = "1" }
    }
    It "части по part_size, Content-SHA256 у каждой, склейка = файл; walk.wav удалён после complete" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -WavPath $Wav -Target (Get-Target)
        (Read-OutboxState $A.Dir).WavSha256 | Should -Be (Get-FakeSha ([IO.File]::ReadAllBytes($Wav)))
        (Invoke-OutboxItem $A.Dir $Ctx).Outcome | Should -Be "sent"
        ($Fake.LastEnvelope | ConvertFrom-Json).collector.audio | Should -BeTrue
        $P = (Get-Calls PUT '/audio/parts/\d+$')
        $P.Count | Should -Be 5
        foreach ($C in $P) { $C.Headers["Content-SHA256"] | Should -Be (Get-FakeSha ([byte[]]$C.Body)); $C.ContentType | Should -Be "application/octet-stream" }
        ([byte[]]$P[4].Body).Length | Should -Be 544
        (Get-FakeSha $Fake.Assembled) | Should -Be (Get-FakeSha ([IO.File]::ReadAllBytes($Wav)))
        Test-Path (Join-Path $A.Dir "walk.wav") | Should -BeFalse
        Test-Path $Wav | Should -BeTrue
        $St = Read-OutboxState $A.Dir
        $St.State | Should -Be "sent"; $St.Stage | Should -Be "stt"
    }
    It "обрыв на части → перезапуск из state.json → GET audio_url → досылаются только недостающие" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -WavPath $Wav -Target (Get-Target)
        Add-FakeFault PUT '/audio/parts/2$' 0
        $R = Invoke-OutboxPass -Conns (Get-Conns)
        $St = Read-OutboxState $A.Dir
        $St.State | Should -Be "queued"; $St.Step | Should -Be "parts"
        @($St.PartsDone) | Should -Be @(0, 1)
        $St.Attempts | Should -Be 1
        # «restart»: the module is loaded again over the existing outbox
        . $Lib
        $Fake.Calls.Clear()
        Invoke-OutboxPass -Conns (Get-Conns) -Force | Out-Null
        $Fake.Calls[0].Method | Should -Be "GET"
        $Fake.Calls[0].Path | Should -Match '/walks/\d+/audio$'
        (Get-Calls POST '/walks$').Count | Should -Be 0
        @((Get-Calls PUT '/parts/') | ForEach-Object { [int]($_.Path -replace '.*/', '') }) | Should -Be @(2, 3, 4)
        (Read-OutboxState $A.Dir).State | Should -Be "sent"
    }
    It "parts_missing на complete — досылаем указанные части" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -WavPath $Wav -Target (Get-Target)
        $Fake.ForgetPart = 1
        (Invoke-OutboxItem $A.Dir $Ctx).Outcome | Should -Be "sent"
        (Get-Calls PUT '/parts/1$').Count | Should -Be 2
        (Get-Calls POST '/complete$').Count | Should -Be 2
    }
    It "sha_mismatch части — часть повторяется" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -WavPath $Wav -Target (Get-Target)
        Add-FakeFault PUT '/parts/3$' 400 @{ code = "sha_mismatch"; detail = "x" }
        (Invoke-OutboxItem $A.Dir $Ctx).Outcome | Should -Be "sent"
        (Get-Calls PUT '/parts/3$').Count | Should -Be 2
    }
    It "sha_mismatch на complete при том же файле — все части заново" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -WavPath $Wav -Target (Get-Target)
        Add-FakeFault POST '/complete$' 400 @{ code = "sha_mismatch"; detail = "x" }
        (Invoke-OutboxItem $A.Dir $Ctx).Outcome | Should -Be "sent"
        (Get-Calls PUT '/parts/').Count | Should -Be 10
    }
    It "no_upload (загрузку удалили) — заново POST audio_url" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -WavPath $Wav -Target (Get-Target)
        Add-FakeFault PUT '/parts/1$' 0
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        $Fake.Uploads.Clear()
        Invoke-OutboxPass -Conns (Get-Conns) -Force | Out-Null
        (Read-OutboxState $A.Dir).State | Should -Be "sent"
        (Get-Calls POST '/audio$').Count | Should -Be 2
    }
}

Describe "ошибки и повторы" {
    BeforeEach {
        Reset-Env | Out-Null; New-FakeServer | Out-Null
        Mock Invoke-CollectorHttp { Invoke-FakeHttp -Method $Method -Uri $Uri -Headers $Headers -Body $Body -ContentType $ContentType -TimeoutSec $TimeoutSec -Binary:$Binary }
    }
    It "backoff 10 с · 2ⁿ ± 20 %, потолок 15 мин" {
        Get-CollectorBackoff 0 0 | Should -Be 10
        Get-CollectorBackoff 0 1 | Should -Be 12
        Get-CollectorBackoff 0 -1 | Should -Be 8
        Get-CollectorBackoff 3 0 | Should -Be 80
        Get-CollectorBackoff 6 0 | Should -Be 640
        Get-CollectorBackoff 7 0 | Should -Be 900
        Get-CollectorBackoff 7 1 | Should -Be 900
        Get-CollectorBackoff 50 -1 | Should -Be 720
        foreach ($i in 1..200) { Get-CollectorBackoff (Get-Random -Maximum 30) | Should -BeLessOrEqual 900 }
    }
    It "5xx и сеть — в очереди с backoff, удачный шаг сбрасывает счётчик" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -Target (Get-Target)
        Add-FakeFault POST '/walks$' 503 @{ code = "x"; detail = "x" }
        Add-FakeFault POST '/walks$' 0
        $T0 = [DateTime]::Now
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        $St = Read-OutboxState $A.Dir
        $St.State | Should -Be "queued"; $St.Attempts | Should -Be 1; $St.LastCode | Should -Be 503
        $D = ((ConvertTo-CollectorDate $St.NextAt) - $T0).TotalSeconds
        $D | Should -BeGreaterOrEqual 7.9; $D | Should -BeLessOrEqual 12.5
        Test-OutboxDue @{ State = $St } | Should -BeFalse
        Invoke-OutboxPass -Conns (Get-Conns) -Force | Out-Null
        $St = Read-OutboxState $A.Dir
        $St.Attempts | Should -Be 2
        $D = ((ConvertTo-CollectorDate $St.NextAt) - [DateTime]::Now).TotalSeconds
        $D | Should -BeGreaterThan 14; $D | Should -BeLessOrEqual 24.5
        Invoke-OutboxPass -Conns (Get-Conns) -Force | Out-Null
        $St = Read-OutboxState $A.Dir
        $St.State | Should -Be "sent"; $St.Attempts | Should -Be 0
    }
    It "429 — ждём ровно Retry-After, попытки не растут" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -Target (Get-Target)
        Add-FakeFault POST '/walks$' 429 @{ code = "rate_limited"; detail = "x" } @{ "Retry-After" = "7" }
        $T0 = [DateTime]::Now
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        $St = Read-OutboxState $A.Dir
        $St.Attempts | Should -Be 0
        $D = ((ConvertTo-CollectorDate $St.NextAt) - $T0).TotalSeconds
        $D | Should -BeGreaterOrEqual 6.9; $D | Should -BeLessOrEqual 7.6
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        (Get-Calls POST '/walks$').Count | Should -Be 1
    }
    It "401 — не повторять: каталог -r2, очередь объекта на паузе; после переподключения «Отправить снова»" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -Target (Get-Target)
        $B = Add-OutboxWalk -WalkJson (New-TestWalk "20261023-130000-LAPTOP-1") -Target (Get-Target)
        $Fake.Revoked = $true
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        Test-Path $A.Dir | Should -BeFalse
        $R2 = "$($A.Dir)-r2"
        (Read-OutboxState $R2).ErrKind | Should -Be "unauthorized"
        (Read-OutboxState $R2).LastError | Should -Match "подключите сборщик заново"
        $Fake.Calls.Clear()
        Invoke-OutboxPass -Conns (Get-Conns) -Force | Out-Null
        $Fake.Calls.Count | Should -Be 0
        (Read-OutboxState $B.Dir).State | Should -Be "queued"
        $Fake.Revoked = $false
        Clear-OutboxPause "zzz-test"; Reset-OutboxRetry $R2
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        (Read-OutboxState $R2).State | Should -Be "sent"
        (Read-OutboxState $B.Dir).State | Should -Be "sent"
    }
    It "409 — каталог -r2; «Отправить как новый» даёт новый Id" {
        $Fake.Walks["20261023-120000-LAPTOP-1"] = @{ Id = 5; Key = "other"; Stage = "done" }
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -Target (Get-Target)
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        $R2 = "$($A.Dir)-r2"
        $St = Read-OutboxState $R2
        $St.State | Should -Be "error"; $St.ErrKind | Should -Be "conflict"
        $St.LastError | Should -Match "другим содержимым"
        Invoke-OutboxPass -Conns (Get-Conns) -Force | Out-Null
        (Get-Calls POST '/walks$').Count | Should -Be 1
        $D = Reset-OutboxAsNew $R2
        (Get-Content (Join-Path $D "envelope.json") -Raw | ConvertFrom-Json).walk.Id | Should -Be "20261023-120000-LAPTOP-1-r2"
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        $St = Read-OutboxState $D
        $St.State | Should -Be "sent"; $St.WalkId | Should -Be "20261023-120000-LAPTOP-1-r2"
        $Fake.Walks.ContainsKey("20261023-120000-LAPTOP-1-r2") | Should -BeTrue
    }
    It "409 на записи (другая запись у обхода) — -r2, не повторять" {
        $W = New-TestWav (Join-Path $env:APPDATA "w.wav") 2100
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -WavPath $W -Target (Get-Target)
        Add-FakeFault POST '/audio$' 409 @{ code = "conflict"; detail = "у обхода уже другая запись" }
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        (Read-OutboxState "$($A.Dir)-r2").LastError | Should -Match "другая запись"
    }
    It "413/422 — в ошибки, сами не повторяются; 422 показывает detail и fields" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -Target (Get-Target)
        Add-FakeFault POST '/walks$' 422 @{ code = "validation_error"; detail = "Обход не прошёл проверку"; fields = @{ "walk.Duration" = "больше 6 ч" } }
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        $St = Read-OutboxState $A.Dir
        $St.State | Should -Be "error"; $St.LastError | Should -Match "walk.Duration: больше 6 ч"
        $B = Add-OutboxWalk -WalkJson (New-TestWalk "20261023-140000-X") -Target (Get-Target)
        Add-FakeFault POST '/walks$' 413 @{ code = "too_large"; detail = "x" }
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        (Read-OutboxState $B.Dir).LastError | Should -Match "больше 16 МБ"
        Invoke-OutboxPass -Conns (Get-Conns) -Force | Out-Null
        (Get-Calls POST '/walks$').Count | Should -Be 2
    }
    It "403/404 — ошибка; пересобрать под другой план" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -Target (Get-Target)
        Add-FakeFault POST '/walks$' 404 @{ code = "not_found"; detail = "x" }
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        (Read-OutboxState $A.Dir).ErrKind | Should -Be "notfound"
        $T = Get-Target; $T.PlanId = 13; $T.Series = "after"; $T.Phase = "after"
        Reset-OutboxTarget $A.Dir $T
        $E = Get-Content (Join-Path $A.Dir "envelope.json") -Raw | ConvertFrom-Json
        $E.plan_id | Should -Be 13; $E.series | Should -Be "after"; $E.walk.Started | Should -Not -BeNullOrEmpty
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        (Read-OutboxState $A.Dir).State | Should -Be "sent"
    }
    It "объект без подключения — ждёт в очереди с подсказкой" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -Target (Get-Target)
        Invoke-OutboxPass -Conns @{} | Out-Null
        $St = Read-OutboxState $A.Dir
        $St.State | Should -Be "queued"; $St.LastError | Should -Match "не подключён"
        $Fake.Calls.Count | Should -Be 0
    }
}

Describe "очередь на диске" {
    BeforeEach { Reset-Env | Out-Null; New-FakeServer | Out-Null; Mock Invoke-CollectorHttp { Invoke-FakeHttp -Method $Method -Uri $Uri -Headers $Headers -Body $Body -ContentType $ContentType -TimeoutSec $TimeoutSec -Binary:$Binary } }
    It "после «перезапуска» (новая загрузка модуля) очередь на месте и уходит по порядку" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk "20261023-100000-A") -Target (Get-Target)
        Start-Sleep -Milliseconds 20
        $B = Add-OutboxWalk -WalkJson (New-TestWalk "20261023-110000-B") -Target (Get-Target)
        . $Lib
        $I = @(Get-OutboxItems)
        $I.Count | Should -Be 2
        $I[0].State.WalkId | Should -Be "20261023-100000-A"
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        $U = Get-Calls POST '/walks$'
        $U.Count | Should -Be 2
        (Read-OutboxState $A.Dir).State | Should -Be "sent"; (Read-OutboxState $B.Dir).State | Should -Be "sent"
    }
    It "state.json пишется атомарно: временный файл и замена, обрыв записи не портит состояние" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -Target (Get-Target)
        $P = Join-Path $A.Dir "state.json"
        @(Get-ChildItem $A.Dir -Filter "*.tmp").Count | Should -Be 0
        # a write that died before the rename leaves only a stray tmp file
        [IO.File]::WriteAllText("$P.999.abcdef.tmp", '{"State":"sen')
        (Read-OutboxState $A.Dir).State | Should -Be "queued"
        Mock -CommandName Write-CollectorFile -MockWith { throw "диск отвалился" } -ParameterFilter { $Path -like "*state.json" }
        { Save-OutboxState $A.Dir @{ State = "broken" } } | Should -Throw
        (Read-OutboxState $A.Dir).State | Should -Be "queued"
    }
    It "Write-CollectorFile заменяет существующий файл через Move" {
        $P = Join-Path $env:APPDATA "x\s.json"
        Write-CollectorFile $P "1"; Write-CollectorFile $P "2"
        Get-Content $P -Raw | Should -Be "2"
        @(Get-ChildItem (Split-Path $P) -Filter "*.tmp").Count | Should -Be 0
    }
    It "отправленное старше 14 дней удаляется, ошибки — никогда" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk "a1") -Target (Get-Target)
        $B = Add-OutboxWalk -WalkJson (New-TestWalk "b1") -Target (Get-Target)
        $S = Read-OutboxState $A.Dir; $S.State = "sent"; $S.SentAt = [DateTime]::Now.AddDays(-15).ToString("o"); Save-OutboxState $A.Dir $S
        $S = Read-OutboxState $B.Dir; $S.State = "error"; $S.QueuedAt = [DateTime]::Now.AddDays(-90).ToString("o"); Save-OutboxState $B.Dir $S
        Remove-OutboxExpired | Should -Be 1
        Test-Path $A.Dir | Should -BeFalse; Test-Path $B.Dir | Should -BeTrue
    }
    It "опрос итога: 202 → стадия, 200 → помещений N и report_url; If-None-Match" {
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -Target (Get-Target)
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        (Read-OutboxState $A.Dir).Stage | Should -Be "stt"
        $Fake.ResultCode = 200
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        $St = Read-OutboxState $A.Dir
        (ConvertTo-CollectorDate $St.PollAt) | Should -BeGreaterThan ([DateTime]::Now.AddSeconds(5))
        $St.PollAt = ""; Save-OutboxState $A.Dir $St
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        $St = Read-OutboxState $A.Dir
        $St.Stage | Should -Be "done"; $St.Rooms | Should -Be 3; $St.ReportUrl | Should -Match "wifi_survey/12"
        (Get-Calls GET '/result$')[-1].Headers["If-None-Match"] | Should -Be '"e1"'
    }
}

Describe "секреты" {
    BeforeEach { Reset-Env | Out-Null; New-FakeServer | Out-Null; Mock Invoke-CollectorHttp { Invoke-FakeHttp -Method $Method -Uri $Uri -Headers $Headers -Body $Body -ContentType $ContentType -TimeoutSec $TimeoutSec -Binary:$Binary } }
    It "токен и код не попадают в лог, state.json и конверт" {
        Write-CollectorLog "ответ: Bearer $($Fake.Token) code=$($Fake.Code)"
        $A = Add-OutboxWalk -WalkJson (New-TestWalk) -Target (Get-Target)
        $Fake.Revoked = $true
        Invoke-OutboxPass -Conns (Get-Conns) | Out-Null
        Invoke-CollectorPair -Url "https://hd.test" -Code ("Z" * 43) | Out-Null
        $Log = Get-Content $CollectorLogPath -Raw
        $Log | Should -Match "401"
        $Log | Should -Not -Match ([regex]::Escape($Fake.Token))
        $Log | Should -Not -Match ([regex]::Escape($Fake.Code))
        foreach ($F in Get-ChildItem $env:APPDATA -Recurse -File) { [IO.File]::ReadAllText($F.FullName) | Should -Not -Match "hdw_TESTTOKEN" }
    }
    It "DPAPI: токен шифруется и расшифровывается (только Windows)" -Skip:(-not $IsWindows) {
        $E = Protect-CollectorToken "hdw_secret"
        $E | Should -Not -Match "hdw_secret"
        Unprotect-CollectorToken $E | Should -Be "hdw_secret"
    }
}

Describe "WAV после падения" {
    It "нулевой заголовок восстанавливается под 16 кГц моно 16 бит" {
        Reset-Env | Out-Null
        $P = Join-Path $env:APPDATA "cut.wav"
        [IO.File]::WriteAllBytes($P, (New-Object byte[] (44 + 32000)))
        Repair-CollectorWav $P | Should -BeTrue
        $B = [IO.File]::ReadAllBytes($P)
        [Text.Encoding]::ASCII.GetString($B, 0, 4) | Should -Be "RIFF"
        [Text.Encoding]::ASCII.GetString($B, 8, 8) | Should -Be "WAVEfmt "
        [BitConverter]::ToInt32($B, 24) | Should -Be 16000
        [BitConverter]::ToInt32($B, 40) | Should -Be 32000
    }
}
