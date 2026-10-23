# In-memory HelpDesk collector API (netknife-survey/1) for the tests: Invoke-CollectorHttp is mocked with
# Invoke-FakeHttp. Behaviour follows docs/WIFI-COLLECTOR-NETKNIFE.md §2–§5 closely enough to drive the client.

function New-FakeServer {
    param([int]$PartSize = 1000)
    $script:Fake = @{
        Url = "https://hd.test"; Token = "hdw_TESTTOKEN_0123456789abcdef"; Code = ("A" * 43); CodeUsed = $false; Revoked = $false
        PartSize = $PartSize; NextId = 100; Walks = @{}; Uploads = @{}; Calls = [System.Collections.Generic.List[object]]::new()
        Faults = [System.Collections.Generic.List[object]]::new(); ResultCode = 202; Stage = "stt"; LastEnvelope = ""; ForgetPart = -1
        PairCalls = 0
    }
    return $script:Fake
}

# a fault is taken once by the first request it matches: @{ Method; Path (regex); Code; Json; Headers }
function Add-FakeFault {
    param([string]$Method, [string]$Path, [int]$Code, $Json = $null, [hashtable]$Headers = @{}, [int]$Times = 1)
    for ($i = 0; $i -lt $Times; $i++) { $script:Fake.Faults.Add(@{ Method = $Method; Path = $Path; Code = $Code; Json = $Json; Headers = $Headers }) }
}

function New-FakeResp { param([int]$Code, $Json = $null, [hashtable]$Headers = @{}, [byte[]]$Bytes = $null) return @{ Code = $Code; Json = $Json; Headers = $Headers; Error = $(if ($Code -eq 0) { "connection reset" } else { "" }); Bytes = $Bytes } }
function New-FakeErr { param([int]$Code, [string]$ErrCode, [string]$Detail = "ошибка", $Extra = @{}) $J = @{ code = $ErrCode; detail = $Detail; fields = @{} }; foreach ($K in $Extra.Keys) { $J[$K] = $Extra[$K] }; return New-FakeResp $Code $J }

function Get-FakeSha { param([byte[]]$B) return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($B)).ToLower() }

function Invoke-FakeHttp {
    param([string]$Method = "GET", [string]$Uri, [hashtable]$Headers = @{}, $Body = $null, [string]$ContentType = "", [int]$TimeoutSec = 30, [switch]$Binary)
    $F = $script:Fake
    $Path = ([Uri]$Uri).AbsolutePath
    $Query = ([Uri]$Uri).Query
    $F.Calls.Add(@{ Method = $Method.ToUpper(); Path = $Path; Query = $Query; Headers = $Headers; Body = $Body; ContentType = $ContentType })
    foreach ($X in @($F.Faults)) {
        if ($X.Method -eq $Method.ToUpper() -and $Path -match $X.Path) { [void]$F.Faults.Remove($X); return New-FakeResp $X.Code $X.Json $X.Headers }
    }
    $Rel = $Path -replace '^/api/v1/wifi/collector', ''
    $M = $Method.ToUpper()
    if ($Rel -eq "/pair" -and $M -eq "POST") {
        $F.PairCalls++
        $J = [Text.Encoding]::UTF8.GetString([byte[]]$Body) | ConvertFrom-Json -AsHashtable
        if ($J.code -eq $F.Code -and -not $F.CodeUsed) { $F.CodeUsed = $true; return New-FakeResp 200 @{ token = $F.Token; token_id = 7; last4 = $F.Token.Substring($F.Token.Length - 4); site = @{ slug = "zzz-test"; name = "ZZZ тест" }; plan_id = 12 } }
        return New-FakeErr 410 "gone" "Код неверный, уже использован или истёк"
    }
    if ($Headers.Authorization -ne "Bearer $($F.Token)" -or $F.Revoked) { return New-FakeErr 401 "unauthorized" "Токен не принят" }
    if ($Rel -eq "/me") { return New-FakeResp 200 @{ protocol = "netknife-survey/1"; user = @{ id = 1; name = "Smoke" }; token = @{ id = 7; name = "x"; last4 = "cdef" }; scope = @{ slug = "zzz-test"; name = "ZZZ тест" }; transcriber = "none"; limits = @{ walk_bytes = 16MB; audio_upload_bytes = 800MB; audio_part_bytes = $F.PartSize } } }
    if ($Rel -eq "/walks" -and $M -eq "POST") {
        if ($Headers["Content-Encoding"] -ne "gzip") { return New-FakeErr 415 "unsupported_encoding" }
        $In = [IO.MemoryStream]::new([byte[]]$Body); $Gz = [IO.Compression.GZipStream]::new($In, [IO.Compression.CompressionMode]::Decompress); $Out = [IO.MemoryStream]::new(); $Gz.CopyTo($Out)
        $Txt = [Text.Encoding]::UTF8.GetString($Out.ToArray()); $F.LastEnvelope = $Txt
        $E = $Txt | ConvertFrom-Json -AsHashtable
        $Uid = "$($E.walk.Id)"
        $Key = Get-FakeSha ([Text.Encoding]::UTF8.GetBytes(($Txt -replace '"collector":\{[^}]*\},', '')))
        if ($F.Walks.ContainsKey($Uid)) {
            $W = $F.Walks[$Uid]
            if ($W.Key -ne $Key) { return New-FakeErr 409 "conflict" "Обход с этим Id уже загружен с другим содержимым" }
            return New-FakeResp 200 @{ id = $W.Id; uid = $Uid; created = $false; audio_url = "/api/v1/wifi/collector/walks/$($W.Id)/audio"; stage = $W.Stage }
        }
        $Id = $F.NextId++
        $F.Walks[$Uid] = @{ Id = $Id; Key = $Key; Stage = $(if ($E.collector.audio) { "audio" } else { "timeline" }) }
        return New-FakeResp 201 @{ id = $Id; uid = $Uid; created = $true; audio_url = "/api/v1/wifi/collector/walks/$Id/audio"; stage = $F.Walks[$Uid].Stage }
    }
    if ($Rel -match '^/walks/(\d+)/audio$') {
        $Wid = [int]$Matches[1]; $U = $F.Uploads[$Wid]
        if ($M -eq "GET") { if (-not $U) { return New-FakeErr 404 "no_upload" }; return New-FakeResp 200 (Get-FakeUpload $U) }
        $J = [Text.Encoding]::UTF8.GetString([byte[]]$Body) | ConvertFrom-Json -AsHashtable
        if ($U -and $U.State -eq "complete" -and $U.Sha -eq $J.sha256) { return New-FakeResp 200 (Get-FakeUpload $U) }
        if ($U -and $U.Parts.Count -and ($U.Sha -ne $J.sha256 -or $U.Size -ne [long]$J.size)) { return New-FakeErr 409 "conflict" "Идёт загрузка другой записи" }
        if ($U -and $U.Sha -eq $J.sha256) { return New-FakeResp 200 (Get-FakeUpload $U) }
        $U = @{ Wid = $Wid; Size = [long]$J.size; Sha = "$($J.sha256)"; PartSize = $F.PartSize; Parts = @{}; Data = @{}; State = "open" }
        $F.Uploads[$Wid] = $U
        return New-FakeResp 201 (Get-FakeUpload $U)
    }
    if ($Rel -match '^/walks/(\d+)/audio/parts/(\d+)$' -and $M -eq "PUT") {
        $U = $F.Uploads[[int]$Matches[1]]; $N = [int]$Matches[2]
        if (-not $U) { return New-FakeErr 404 "no_upload" }
        if (-not $Headers["Content-SHA256"]) { return New-FakeErr 400 "sha_required" }
        $B = [byte[]]$Body; $Sha = Get-FakeSha $B
        if ($Sha -ne $Headers["Content-SHA256"]) { return New-FakeErr 400 "sha_mismatch" }
        $Cnt = [int][Math]::Ceiling($U.Size / $U.PartSize)
        $Want = [Math]::Min($U.PartSize, $U.Size - [long]$N * $U.PartSize)
        if ($N -ge $Cnt) { return New-FakeErr 422 "bad_part" }
        if ($B.Length -ne $Want) { return New-FakeErr 400 "bad_size" }
        $Created = -not $U.Parts.ContainsKey($N)
        $U.Parts[$N] = $Sha; $U.Data[$N] = $B
        return New-FakeResp $(if ($Created) { 201 } else { 200 }) @{ n = $N; created = $Created }
    }
    if ($Rel -match '^/walks/(\d+)/audio/complete$' -and $M -eq "POST") {
        $U = $F.Uploads[[int]$Matches[1]]
        if (-not $U) { return New-FakeErr 404 "no_upload" }
        if ($F.ForgetPart -ge 0) { [void]$U.Parts.Remove($F.ForgetPart); [void]$U.Data.Remove($F.ForgetPart); $F.ForgetPart = -1 }
        $Miss = @(Get-FakeUpload $U).missing
        if ($Miss.Count) { return New-FakeErr 409 "parts_missing" "Не все части" @{ missing = $Miss } }
        $All = [IO.MemoryStream]::new(); foreach ($K in ($U.Data.Keys | Sort-Object)) { $All.Write($U.Data[$K], 0, $U.Data[$K].Length) }
        $F.Assembled = $All.ToArray()
        if ((Get-FakeSha $F.Assembled) -ne $U.Sha) { return New-FakeErr 400 "sha_mismatch" "sha256 склейки не совпал" }
        $U.State = "complete"
        return New-FakeResp 201 ((Get-FakeUpload $U) + @{ stage = "stt" })
    }
    if ($Rel -match '^/walks/(\d+)/result$') {
        if ($F.ResultCode -eq 200) { return New-FakeResp 200 @{ stage = "done"; ready = $true; rooms = 3; report_url = "https://hd.test/objects/zzz-test/tools/wifi_survey/12" } @{ ETag = '"e2"' } }
        return New-FakeResp 202 @{ stage = $F.Stage; ready = $false } @{ ETag = '"e1"' }
    }
    if ($Rel -eq "/sites") { return New-FakeResp 200 @{ protocol = "netknife-survey/1"; sites = @(@{ slug = "zzz-test"; name = "ZZZ тест"; can_write = $true; plans = @(@{ id = 12; name = "Основной"; rooms = @("Кухня"); floor = @{ image = @{ mime = "image/png"; sha256 = "ab12" } }; aps = @(@{ name = "EAP-кухня"; bssids = @("AA:BB:CC:DD:EE:F0") }); series = @() }) }) } }
    if ($Rel -match '^/plans/(\d+)/image$' -and $M -eq "GET") { $F.ImageGets++; return New-FakeResp 200 $null @{} ([byte[]](137, 80, 78, 71)) }
    if ($Rel -eq "/plans/import" -and $M -eq "POST") { return New-FakeResp 201 @{ id = 55 } }
    if ($Rel -match '^/plans/(\d+)/image$' -and $M -eq "PUT") { return New-FakeResp 200 @{ ok = $true } }
    return New-FakeErr 404 "not_found"
}

function Get-FakeUpload {
    param($U)
    $Cnt = [int][Math]::Ceiling($U.Size / $U.PartSize)
    $Rec = @($U.Parts.Keys | Sort-Object)
    $Miss = @(0..($Cnt - 1) | Where-Object { -not $U.Parts.ContainsKey($_) })
    return @{ walk_id = $U.Wid; size = $U.Size; sha256 = $U.Sha; part_size = $U.PartSize; parts = $Cnt; received = $Rec; missing = $Miss; state = $U.State }
}
