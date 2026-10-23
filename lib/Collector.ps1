# Collector: the client side of the HelpDesk Wi-Fi survey protocol «netknife-survey/1» (helpdesk repo,
# docs/WIFI-COLLECTOR-NETKNIFE.md). NetKnife only collects a walk and sends it; the server transcribes the voice and
# builds the room timeline, the track and the report.
#   • pairing by a one-time code → per-site token (DPAPI in settings.json, never in the log);
#   • directory (/me, /sites, plan pictures) cached in %APPDATA%\NetKnife\collector\ — walks run offline;
#   • offline outbox %APPDATA%\NetKnife\outbox\<site>\<walkId>\ { envelope.json, walk.wav, state.json }: the envelope is
#     built once, sent gzip-compressed; the WAV goes in parts with resume; retries with backoff.
# No UI here: dot-sourced by NetKnife.ps1, inside the sending worker (path via Start-Worker -ArgList) and by tests.
# Every HTTP call goes through Invoke-CollectorHttp.

$script:CollectorProtocol = "netknife-survey/1"
$script:CollectorApi = "/api/v1/wifi/collector"
$script:CollectorFinalStages = @("done", "failed")

function Get-CollectorDataDir {
    if ($script:DataDir) { return $script:DataDir }
    return Join-Path $env:APPDATA "NetKnife"
}
function Get-CollectorCacheDir { return Join-Path (Get-CollectorDataDir) "collector" }
function Get-OutboxDir { return Join-Path (Get-CollectorDataDir) "outbox" }

# secrets never reach the log: tokens hdw_… and 43-char pairing codes are masked
function Hide-CollectorSecret {
    param([string]$Text)
    return ($Text -replace 'hdw_[A-Za-z0-9_\-]+', 'hdw_…' -replace '(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]{43}(?![A-Za-z0-9_\-])', '<code>')
}

function Write-CollectorLog {
    param([string]$Text)
    $T = Hide-CollectorSecret $Text
    if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) { Write-AppLog "collector: $T"; return }
    if ($script:CollectorLogPath) { try { Add-Content -Path $script:CollectorLogPath -Value "$(Get-Date -Format 's') collector: $T" -Encoding UTF8 } catch { } }
}

# DPAPI (current Windows user), the same way the old AI keys were stored
function Protect-CollectorToken { param([string]$Token) if (-not $Token) { return "" }; return (ConvertTo-SecureString $Token -AsPlainText -Force | ConvertFrom-SecureString) }
function Unprotect-CollectorToken { param([string]$Enc) if (-not $Enc) { return "" }; try { return [System.Net.NetworkCredential]::new("", (ConvertTo-SecureString $Enc)).Password } catch { return "" } }

# ---------------------------------------------------------------- small helpers

# tmp file + rename: an interrupted write never leaves a half-written state.json
function Write-CollectorFile {
    param([string]$Path, $Content)
    $Dir = Split-Path $Path -Parent
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $Tmp = "$Path.$PID.$([Guid]::NewGuid().ToString('N').Substring(0, 6)).tmp"
    if ($Content -is [byte[]]) { [IO.File]::WriteAllBytes($Tmp, $Content) }
    else { [IO.File]::WriteAllText($Tmp, "$Content", [Text.UTF8Encoding]::new($false)) }
    [IO.File]::Move($Tmp, $Path, $true)
}

function Get-CollectorSha256 { param([byte[]]$Bytes) return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLower() }
# ConvertFrom-Json turns ISO strings into DateTime; "$date" would then be culture-dependent — normalise here
function ConvertTo-CollectorDate {
    param($V)
    if ($V -is [DateTime]) { return $V }
    if (-not "$V") { return $null }
    return [DateTime]::Parse("$V", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}

function Get-CollectorFileSha256 { param([string]$Path) return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower() }

function ConvertTo-GzipBytes {
    param([byte[]]$Bytes)
    $Ms = [IO.MemoryStream]::new()
    $Gz = [IO.Compression.GZipStream]::new($Ms, [IO.Compression.CompressionLevel]::Optimal)
    $Gz.Write($Bytes, 0, $Bytes.Length); $Gz.Dispose()
    return $Ms.ToArray()
}

function Get-CollectorJsonOptions {
    $O = [System.Text.Json.JsonSerializerOptions]::new()
    $O.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping   # Cyrillic stays readable
    return $O
}

# walk Id: yyyyMMdd-HHmmss-<device>, ≤ 64 chars (the server key of a retry is per site; two laptops must not collide)
function New-CollectorWalkId {
    param([DateTime]$At = [DateTime]::Now, [string]$Device = $env:COMPUTERNAME)
    $Dev = "$Device" -replace '[^\w.-]', '_'
    $Id = "$($At.ToString('yyyyMMdd-HHmmss'))-$Dev"
    if ($Id.Length -gt 64) { $Id = $Id.Substring(0, 64) }
    return $Id
}

# 10 s · 2ⁿ ± 20 %, never more than 15 min between attempts
function Get-CollectorBackoff {
    param([int]$Attempt, [double]$Jitter = (Get-Random -Minimum -1.0 -Maximum 1.0))
    $N = [Math]::Min([Math]::Max(0, $Attempt), 20)
    $D = 10.0 * [Math]::Pow(2, $N)
    return [Math]::Min(900.0, [Math]::Min(900.0, $D) * (1.0 + 0.2 * $Jitter))
}

# ---------------------------------------------------------------- pairing string

# {"t":"hd-wifi-pair/1","url":…,"code":…,"site":…} or a bare 43-char code (the URL then comes from the settings)
function ConvertFrom-PairString {
    param([string]$Text, [string]$DefaultUrl = "")
    $T = "$Text".Trim()
    if (-not $T) { return @{ Error = "Вставьте строку подключения из Helpdesk" } }
    if ($T -match '^[A-Za-z0-9_-]{43}$') {
        if (-not $DefaultUrl) { return @{ Error = "Это код без адреса сервера — вставьте строку целиком (кнопка «Скопировать» в Helpdesk)" } }
        return @{ Url = $DefaultUrl.TrimEnd('/'); Code = $T; Site = "" }
    }
    $J = $null
    try { $J = $T | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { }
    if (-not ($J -is [System.Collections.IDictionary]) -or "$($J['t'])" -ne "hd-wifi-pair/1") { return @{ Error = "Это не код Helpdesk: нужна строка подключения из блока «Сборщики NetKnife»" } }
    $Url = "$($J['url'])".Trim().TrimEnd('/')
    $Code = "$($J['code'])".Trim()
    if ($Url -notmatch '^https?://') { return @{ Error = "В строке подключения нет адреса сервера" } }
    if ($Code -notmatch '^[A-Za-z0-9_-]{43}$') { return @{ Error = "В строке подключения неверный код" } }
    return @{ Url = $Url; Code = $Code; Site = "$($J['site'])" }
}

# ---------------------------------------------------------------- HTTP

# One place for all requests (tests mock it). Never throws: Code 0 = network error / timeout.
function Invoke-CollectorHttp {
    param([string]$Method = "GET", [string]$Uri, [hashtable]$Headers = @{}, $Body = $null, [string]$ContentType = "", [int]$TimeoutSec = 30, [switch]$Binary)
    $A = @{ Uri = $Uri; Method = $Method; Headers = $Headers; TimeoutSec = $TimeoutSec; SkipHttpErrorCheck = $true; ErrorAction = "Stop" }
    if ($null -ne $Body) { $A.Body = $Body }
    if ($ContentType) { $A.ContentType = $ContentType }
    try { $R = Invoke-WebRequest @A }
    catch { return @{ Code = 0; Error = "$($_.Exception.Message)"; Json = $null; Headers = @{}; Bytes = $null } }
    $H = @{}
    foreach ($K in $R.Headers.Keys) { $H[$K] = "$(@($R.Headers[$K]) | Select-Object -First 1)" }
    $Out = @{ Code = [int]$R.StatusCode; Headers = $H; Json = $null; Error = ""; Bytes = $null }
    if ($Binary) { $Out.Bytes = $R.RawContentStream.ToArray(); return $Out }
    $Txt = $(if ($R.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($R.Content) } else { "$($R.Content)" })
    if ($Txt.Trim()) { try { $Out.Json = $Txt | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $Out.Error = "ответ не JSON (HTTP $($Out.Code))" } }
    return $Out
}

# $Ctx: @{ Url; Token; Version } — Path relative to /api/v1/wifi/collector, or absolute from the server root
function Invoke-CollectorApi {
    param([hashtable]$Ctx, [string]$Method = "GET", [string]$Path, $Body = $null, [string]$ContentType = "", [hashtable]$Headers = @{}, [int]$TimeoutSec = 30, [switch]$Binary)
    $Uri = $(if ($Path -like "/api/*") { "$($Ctx.Url.TrimEnd('/'))$Path" } else { "$($Ctx.Url.TrimEnd('/'))$script:CollectorApi/$($Path.TrimStart('/'))" })
    $H = @{ "User-Agent" = "NetKnife/$($Ctx.Version)" }
    if ($Ctx.Token) { $H.Authorization = "Bearer $($Ctx.Token)" }
    foreach ($K in $Headers.Keys) { $H[$K] = $Headers[$K] }
    $R = Invoke-CollectorHttp -Method $Method -Uri $Uri -Headers $H -Body $Body -ContentType $ContentType -TimeoutSec $TimeoutSec -Binary:$Binary
    if ($R.Code -eq 0 -or $R.Code -ge 400) { Write-CollectorLog "$Method $Path → $(if ($R.Code) { $R.Code } else { 'сеть' }) $(Get-CollectorErrText $R)" }
    return $R
}

function Get-CollectorErrText {
    param($R)
    if (-not $R) { return "" }
    if ($R.Code -eq 0) { return "нет связи с сервером ($($R.Error))" }
    $J = $R.Json
    $D = $(if ($J -is [System.Collections.IDictionary] -and $J['detail']) { "$($J['detail'])" } else { "HTTP $($R.Code)" })
    if ($J -is [System.Collections.IDictionary] -and $J['fields'] -is [System.Collections.IDictionary] -and $J['fields'].Count) {
        $D += " (" + ((@($J['fields'].Keys) | ForEach-Object { "${_}: $($J['fields'][$_])" }) -join "; ") + ")"
    }
    return $D
}

function Get-CollectorErrCode { param($R) if ($R.Json -is [System.Collections.IDictionary]) { return "$($R.Json['code'])" }; return "" }

function Get-CollectorRetryAfter {
    param($R)
    $V = "$($R.Headers['Retry-After'])".Trim()
    if ($V -match '^\d+$') { return [int]$V }
    return 60
}

# ---------------------------------------------------------------- pairing and directory

function Invoke-CollectorPair {
    param([string]$Url, [string]$Code, [string]$Name = "NetKnife $env:COMPUTERNAME", [string]$Version = "0")
    $Body = [Text.Encoding]::UTF8.GetBytes((@{ code = $Code; name = $Name } | ConvertTo-Json -Compress))
    $R = Invoke-CollectorApi -Ctx @{ Url = $Url; Token = ""; Version = $Version } -Method Post -Path "pair" -Body $Body -ContentType "application/json; charset=utf-8"
    switch ($R.Code) {
        200 {
            $J = $R.Json
            return @{ Ok = $true; Url = $Url.TrimEnd('/'); Token = "$($J['token'])"; TokenId = $J['token_id']; Last4 = "$($J['last4'])"
                Site = @{ slug = "$($J['site']['slug'])"; name = "$($J['site']['name'])" }; PlanId = $J['plan_id'] }
        }
        410 { return @{ Ok = $false; Code = 410; Error = "$(Get-CollectorErrText $R) — попросите новый код в Helpdesk" } }
        429 { $W = Get-CollectorRetryAfter $R; return @{ Ok = $false; Code = 429; Wait = $W; Error = "Слишком много попыток — подождите $W с" } }
        default { return @{ Ok = $false; Code = $R.Code; Error = (Get-CollectorErrText $R) } }
    }
}

function Get-CollectorMe {
    param([hashtable]$Ctx)
    $R = Invoke-CollectorApi -Ctx $Ctx -Path "me" -TimeoutSec 20
    if ($R.Code -eq 200) { return @{ Ok = $true; Me = $R.Json } }
    return @{ Ok = $false; Code = $R.Code; Error = $(if ($R.Code -eq 401) { "Токен не принят (отозван или неверный) — подключите сборщик заново кодом" } else { Get-CollectorErrText $R }) }
}

# /me → one line for the UI (scope, user, last4, transcriber, limits)
function Format-CollectorMe {
    param($Me)
    if (-not $Me) { return "" }
    $L = $Me['limits']
    $Mb = { param($B) if ($B) { "{0:N0} МБ" -f ([double]$B / 1MB) } else { "?" } }
    $Scope = $(if ($Me['scope']) { "объект «$($Me['scope']['name'])»" } else { "устаревший токен на все объекты — подключите заново кодом" })
    $Tr = $(if ("$($Me['transcriber'])" -eq "gateway") { "голос распознаёт сервер" } else { "голос сервер не распознаёт" })
    return "$Scope · $($Me['user']['name']) · токен …$($Me['token']['last4']) · $Tr · обход до $(& $Mb $L['walk_bytes']), запись до $(& $Mb $L['audio_upload_bytes'])"
}

function Get-CollectorSitesCachePath { return Join-Path (Get-CollectorCacheDir) "sites.json" }

# sites.json: { "<url>|<slug>": <answer of GET /sites> } — one entry per connected object
function Read-CollectorSitesCache {
    $P = Get-CollectorSitesCachePath
    if (-not (Test-Path $P)) { return @{} }
    try { $J = Get-Content $P -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable; if ($J -is [System.Collections.IDictionary]) { return $J } } catch { }
    return @{}
}

function Update-CollectorSites {
    param([hashtable]$Ctx, [string]$Key)
    $R = Invoke-CollectorApi -Ctx $Ctx -Path "sites" -TimeoutSec 20
    if ($R.Code -ne 200) { return @{ Ok = $false; Code = $R.Code; Wait = $(if ($R.Code -eq 429) { Get-CollectorRetryAfter $R } else { 0 }); Error = (Get-CollectorErrText $R) } }
    $All = Read-CollectorSitesCache
    $R.Json['cached_at'] = [DateTime]::Now.ToString("o")
    $All[$Key] = $R.Json
    Write-CollectorFile (Get-CollectorSitesCachePath) ($All | ConvertTo-Json -Depth 14)
    $Imgs = @(foreach ($S in @($R.Json['sites'])) { foreach ($P in @($S['plans'])) { if ($P) { Save-CollectorPlanImage $Ctx $P } } })
    return @{ Ok = $true; Sites = @($R.Json['sites']); Images = $Imgs }
}

function Get-CollectorPlanImagePath {
    param($Plan)
    $F = $Plan['floor']; if (-not $F) { return "" }
    $Img = $F['image']; if (-not $Img -or -not $Img['sha256']) { return "" }
    $Ext = $(if ("$($Img['mime'])" -eq "image/jpeg") { "jpg" } else { "png" })
    return Join-Path (Get-CollectorCacheDir) "plan-$($Plan['id'])-$($Img['sha256']).$Ext"
}

# the picture is downloaded again only when floor.image.sha256 changed
function Save-CollectorPlanImage {
    param([hashtable]$Ctx, $Plan)
    $File = Get-CollectorPlanImagePath $Plan
    if (-not $File) { return "" }
    if (Test-Path $File) { return $File }
    $R = Invoke-CollectorApi -Ctx $Ctx -Path "plans/$($Plan['id'])/image" -TimeoutSec 60 -Binary
    if ($R.Code -ne 200 -or -not $R.Bytes) { return "" }
    Write-CollectorFile $File $R.Bytes
    return $File
}

# AP name by BSSID from the selected plan (aps[].bssids), "" if unknown
function Find-CollectorApName {
    param($Plan, [string]$Bssid)
    if (-not $Plan -or -not $Bssid) { return "" }
    $B = ($Bssid -replace '-', ':').ToLower()
    foreach ($A in @($Plan['aps'])) {
        if (-not $A) { continue }
        foreach ($X in @($A['bssids'])) { if ("$X".Replace('-', ':').ToLower() -eq $B) { return "$($A['name'])" } }
    }
    return ""
}

# ---------------------------------------------------------------- envelope

# The walk file is pasted into the envelope as text: ConvertFrom-Json would turn Started into a DateTime and rewrite it.
function New-SurveyEnvelope {
    param([string]$WalkJson, [string]$Site, [int]$PlanId, [string]$Series, [string]$Phase, [bool]$HasWav, [string]$Version, [string]$Device = $env:COMPUTERNAME)
    $Head = [ordered]@{ format = $script:CollectorProtocol; site = $Site; plan_id = $PlanId }
    if ($Series) { $Head.series = $Series }
    if ($Phase) { $Head.phase = $Phase }
    $Head.collector = [ordered]@{ app = "NetKnife"; version = $Version; platform = "windows"; device = $Device; audio = $HasWav }
    $H = $Head | ConvertTo-Json -Compress -Depth 4
    return $H.Substring(0, $H.Length - 1) + ',"walk":' + $WalkJson.Trim() + '}'
}

# results of the old local analysis: the server builds them itself now (Phrases/Words would even switch off
# server-side speech recognition). Works on a copy of the text; Started etc. stay byte-for-byte.
function Remove-WalkAnalysisFields {
    param([string]$WalkJson)
    $N = [System.Text.Json.Nodes.JsonNode]::Parse($WalkJson)
    $O = $N.AsObject()
    foreach ($K in @("Words", "Phrases", "Timeline", "Notes")) { [void]$O.Remove($K) }
    return $N.ToJsonString((Get-CollectorJsonOptions))
}

# required fields of §4.1 — an old file without them is not sent
function Test-WalkFileCompatible {
    param([string]$WalkJson)
    try { $J = $WalkJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { return "файл не JSON" }
    if (-not ($J -is [System.Collections.IDictionary])) { return "файл не похож на обход NetKnife" }
    if ("$($J['Id'])" -notmatch '^[\w.:-]{1,64}$') { return "нет поля Id или оно не подходит серверу" }
    if (-not $J['Started']) { return "нет поля Started" }
    $D = 0.0
    if (-not [double]::TryParse("$($J['Duration'])", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$D) -or $D -le 0 -or $D -gt 21600) { return "нет длительности (Duration) или она больше 6 ч" }
    return ""
}

# a recording cut by a crash has a zero header (MicRec writes it on «Стоп»): rebuild it for 16 kHz mono 16 bit
function Repair-CollectorWav {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $Len = (Get-Item $Path).Length
    if ($Len -le 44) { return $false }
    $Fs = [IO.File]::Open($Path, "Open", "ReadWrite")
    try {
        $Hd = New-Object byte[] 4; [void]$Fs.Read($Hd, 0, 4)
        if ([Text.Encoding]::ASCII.GetString($Hd) -eq "RIFF") { return $true }
        $Data = [int](($Len - 44) - (($Len - 44) % 2))
        $Bw = [IO.BinaryWriter]::new($Fs)
        $Fs.Position = 0
        $Bw.Write([Text.Encoding]::ASCII.GetBytes("RIFF")); $Bw.Write([int](36 + $Data)); $Bw.Write([Text.Encoding]::ASCII.GetBytes("WAVEfmt "))
        $Bw.Write([int]16); $Bw.Write([int16]1); $Bw.Write([int16]1); $Bw.Write([int]16000); $Bw.Write([int]32000); $Bw.Write([int16]2); $Bw.Write([int16]16)
        $Bw.Write([Text.Encoding]::ASCII.GetBytes("data")); $Bw.Write([int]$Data)
        $Bw.Flush()
        return $true
    } finally { $Fs.Dispose() }
}

# ---------------------------------------------------------------- outbox

function Read-OutboxState {
    param([string]$Dir)
    $P = Join-Path $Dir "state.json"
    if (-not (Test-Path $P)) { return $null }
    try { return (Get-Content $P -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable) } catch { return $null }
}

function Save-OutboxState {
    param([string]$Dir, $State)
    Write-CollectorFile (Join-Path $Dir "state.json") ($State | ConvertTo-Json -Depth 6)
}

function Get-OutboxKey { param([string]$Dir) return "$(Split-Path (Split-Path $Dir -Parent) -Leaf)/$(Split-Path $Dir -Leaf)" }
function Get-OutboxPath { param([string]$Key) return Join-Path (Get-OutboxDir) ($Key -replace '/', [IO.Path]::DirectorySeparatorChar) }
function ConvertTo-OutboxName { param([string]$S) return ("$S" -replace '[\\/:*?"<>|]', '_') }

# Queue a walk: envelope built once (never changes afterwards), WAV linked or copied, sha256 counted once.
# $Target: @{ Url; Site; SiteName; PlanId; PlanName; Series; SeriesLabel; Phase }
function Add-OutboxWalk {
    param([string]$WalkJson, [string]$WavPath = "", [hashtable]$Target, [string]$Version = "0", [string]$Note = "")
    $J = $WalkJson | ConvertFrom-Json -AsHashtable
    $Id = "$($J['Id'])"
    $Dir = Join-Path (Join-Path (Get-OutboxDir) (ConvertTo-OutboxName $Target.Site)) (ConvertTo-OutboxName $Id)
    if (Test-Path (Join-Path $Dir "state.json")) { return @{ Ok = $false; Dir = $Dir; Error = "обход $Id уже в очереди" } }
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $HasWav = [bool]($WavPath -and (Test-Path $WavPath) -and (Get-Item $WavPath).Length -gt 44)
    $Env = New-SurveyEnvelope -WalkJson $WalkJson -Site $Target.Site -PlanId ([int]$Target.PlanId) -Series $Target.Series -Phase $Target.Phase -HasWav $HasWav -Version $Version
    Write-CollectorFile (Join-Path $Dir "envelope.json") $Env
    $Size = 0L; $Sha = ""
    if ($HasWav) {
        $Wav = Join-Path $Dir "walk.wav"
        $Linked = $false
        try { New-Item -ItemType HardLink -Path $Wav -Target $WavPath -ErrorAction Stop | Out-Null; $Linked = $true } catch { }
        if (-not $Linked) { Copy-Item -LiteralPath $WavPath -Destination $Wav -Force }
        $Size = (Get-Item $Wav).Length
        $Sha = Get-CollectorFileSha256 $Wav
    }
    $St = @{ State = "queued"; Step = "walk"; ServerId = $null; AudioUrl = ""; WavSize = $Size; WavSha256 = $Sha; PartsDone = @(); PartsTotal = 0
        Attempts = 0; NextAt = ""; LastCode = 0; LastError = ""; QueuedAt = [DateTime]::Now.ToString("o"); SentAt = ""
        WalkId = $Id; Url = $Target.Url; Site = $Target.Site; SiteName = $Target.SiteName; PlanId = [int]$Target.PlanId; PlanName = $Target.PlanName
        Series = $Target.Series; SeriesLabel = $Target.SeriesLabel; Phase = $Target.Phase; Started = $(if ($J['Started'] -is [DateTime]) { $J['Started'].ToString("o") } else { "$($J['Started'])" }); Duration = [double]$J['Duration']
        Stage = ""; StageError = ""; Rooms = $null; ReportUrl = ""; ETag = ""; PollAt = ""; ErrKind = ""; Note = $Note }
    Save-OutboxState $Dir $St
    return @{ Ok = $true; Dir = $Dir; State = $St }
}

# an old walk-*.json from wifiplan\: a copy without the analysis fields goes to the queue, the file stays as it is
function Add-OutboxLegacyWalk {
    param([string]$Path, [hashtable]$Target, [string]$Version = "0")
    $Txt = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $Why = Test-WalkFileCompatible $Txt
    if ($Why) { return @{ Ok = $false; Error = "$(Split-Path $Path -Leaf): $Why" } }
    $Clean = Remove-WalkAnalysisFields $Txt
    $Wav = [IO.Path]::ChangeExtension($Path, ".wav")
    $T = @{} + $Target
    $J = $Clean | ConvertFrom-Json -AsHashtable
    # the old file knows its own series/phase; the server takes walk.Series / walk.Phase when the envelope has none
    $T.Series = ""; $T.Phase = ""; $T.SeriesLabel = $(if ($J['Series']) { "$($J['Series'])" } else { "$($J['Phase'])" })
    return Add-OutboxWalk -WalkJson $Clean -WavPath $(if (Test-Path $Wav) { $Wav } else { "" }) -Target $T -Version $Version -Note "старая прогулка"
}

function Get-OutboxItems {
    $Root = Get-OutboxDir
    if (-not (Test-Path $Root)) { return @() }
    return @(foreach ($S in Get-ChildItem $Root -Directory) {
        foreach ($D in Get-ChildItem $S.FullName -Directory) {
            $St = Read-OutboxState $D.FullName
            if ($St) { @{ Key = (Get-OutboxKey $D.FullName); Dir = $D.FullName; State = $St; Paused = (Test-Path (Join-Path $S.FullName ".paused")) } }
        }
    }) | Sort-Object { "$($_.State.QueuedAt)" }
}

function Test-OutboxDue {
    param($Item, [DateTime]$Now = [DateTime]::Now)
    $St = $Item.State
    if ($Item.Paused) { return $false }
    if ($St.State -in @("queued", "sending")) { return (-not $St.NextAt -or (ConvertTo-CollectorDate $St.NextAt) -le $Now) }
    if ($St.State -eq "sent" -and "$($St.Stage)" -notin $script:CollectorFinalStages) { return (-not $St.PollAt -or (ConvertTo-CollectorDate $St.PollAt) -le $Now) }
    return $false
}

# «-r2» after 401/409: the directory leaves the queue under a new name (…-r2, then …-r3)
function Get-OutboxR2Path {
    param([string]$Dir)
    $Parent = Split-Path $Dir -Parent; $Leaf = Split-Path $Dir -Leaf
    $Base = $Leaf; $N = 2
    if ($Leaf -match '^(.*)-r(\d+)$') { $Base = $Matches[1]; $N = [int]$Matches[2] + 1 }
    while (Test-Path (Join-Path $Parent "$Base-r$N")) { $N++ }
    return Join-Path $Parent "$Base-r$N"
}

function Move-OutboxR2 {
    param([string]$Dir)
    $New = Get-OutboxR2Path $Dir
    [IO.Directory]::Move($Dir, $New)
    return $New
}

function Set-OutboxPause { param([string]$Site, [string]$Why) $P = Join-Path (Join-Path (Get-OutboxDir) (ConvertTo-OutboxName $Site)) ".paused"; Write-CollectorFile $P $Why }
function Clear-OutboxPause { param([string]$Site) $P = Join-Path (Join-Path (Get-OutboxDir) (ConvertTo-OutboxName $Site)) ".paused"; if (Test-Path $P) { Remove-Item $P -Force } }

# «Отправить снова» (after 401 or a temporary error): same envelope, continues from the step it stopped at
function Reset-OutboxRetry {
    param([string]$Dir)
    $St = Read-OutboxState $Dir; if (-not $St) { return }
    $St.State = "queued"; $St.NextAt = ""; $St.Attempts = 0; $St.ErrKind = ""; $St.LastError = ""
    Save-OutboxState $Dir $St
}

# «Отправить как новый» (after 409): new walk.Id = name of the -r2 directory, new envelope, from the start
function Reset-OutboxAsNew {
    param([string]$Dir)
    $St = Read-OutboxState $Dir; if (-not $St) { return $null }
    $NewId = Split-Path $Dir -Leaf
    if ($NewId -notmatch '-r\d+$') { $Dir = Move-OutboxR2 $Dir; $NewId = Split-Path $Dir -Leaf }
    if ($NewId.Length -gt 64) { $Sfx = [regex]::Match($NewId, '-r\d+$').Value; $NewId = $NewId.Substring(0, 64 - $Sfx.Length) + $Sfx }
    $P = Join-Path $Dir "envelope.json"
    $N = [System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($P, [Text.Encoding]::UTF8))
    $N["walk"]["Id"] = [System.Text.Json.Nodes.JsonNode]$NewId
    Write-CollectorFile $P ($N.ToJsonString((Get-CollectorJsonOptions)))
    foreach ($K in @("ServerId", "Uid")) { $St[$K] = $null }
    $St.AudioUrl = ""; $St.PartsDone = @(); $St.PartsTotal = 0; $St.Step = "walk"; $St.State = "queued"; $St.NextAt = ""; $St.Attempts = 0
    $St.ErrKind = ""; $St.LastError = ""; $St.LastCode = 0; $St.Stage = ""; $St.WalkId = $NewId
    Save-OutboxState $Dir $St
    return $Dir
}

# 403/404/422 plan_required: the envelope head is rebuilt for another object/plan/series; the walk text stays
function Reset-OutboxTarget {
    param([string]$Dir, [hashtable]$Target)
    $St = Read-OutboxState $Dir; if (-not $St) { return }
    $P = Join-Path $Dir "envelope.json"
    $N = [System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($P, [Text.Encoding]::UTF8))
    $Walk = $N["walk"].ToJsonString((Get-CollectorJsonOptions))
    $Has = $(try { $N["collector"]["audio"].ToJsonString() -eq "true" } catch { $false })
    $Ver = $(try { $N["collector"]["version"].ToString() } catch { "0" })
    $Env = New-SurveyEnvelope -WalkJson $Walk -Site $Target.Site -PlanId ([int]$Target.PlanId) -Series $Target.Series -Phase $Target.Phase -HasWav $Has -Version $Ver
    Write-CollectorFile $P $Env
    foreach ($K in @("Url", "Site", "SiteName", "PlanName", "Series", "SeriesLabel", "Phase")) { if ($Target.ContainsKey($K)) { $St[$K] = $Target[$K] } }
    $St.PlanId = [int]$Target.PlanId
    $St.ServerId = $null; $St.AudioUrl = ""; $St.PartsDone = @(); $St.Step = "walk"; $St.State = "queued"; $St.NextAt = ""; $St.Attempts = 0; $St.ErrKind = ""; $St.LastError = ""
    Save-OutboxState $Dir $St
}

# sent walks are kept 14 days; errors are never removed automatically
function Remove-OutboxExpired {
    param([int]$Days = 14, [DateTime]$Now = [DateTime]::Now)
    $N = 0
    foreach ($I in @(Get-OutboxItems)) {
        $St = $I.State
        if ($St.State -eq "sent" -and $St.SentAt -and (ConvertTo-CollectorDate $St.SentAt) -lt $Now.AddDays(-$Days)) { Remove-Item $I.Dir -Recurse -Force; $N++ }
    }
    return $N
}

# ---------------------------------------------------------------- sending (state machine of one walk)

function Send-OutboxEvent {
    param([hashtable]$Ctx, [string]$Dir, $St, [string]$Kind = "state", [string]$Text = "")
    if ($Ctx.OnEvent) { & $Ctx.OnEvent @{ Kind = $Kind; Key = (Get-OutboxKey $Dir); Dir = $Dir; State = $St; Text = $Text } }
}

function Format-OutboxMb { param($B) if (-not $B) { return "?" }; return ("{0:N0}" -f ([double]$B / 1MB)) }

# what to do with a failed answer (§5.3). Returns the outcome; the state is saved.
function Set-OutboxFailure {
    param([string]$Dir, $St, $R, [string]$What, [hashtable]$Ctx)
    $Now = [DateTime]::Now
    $St.LastCode = [int]$R.Code
    $Code = Get-CollectorErrCode $R
    $Txt = Get-CollectorErrText $R
    $Out = "error"
    if ($R.Code -eq 0 -or $R.Code -ge 500 -or $R.Code -eq 408) {
        $St.State = "queued"; $St.NextAt = $Now.AddSeconds((Get-CollectorBackoff ([int]$St.Attempts))).ToString("o"); $St.Attempts = [int]$St.Attempts + 1
        $St.LastError = $Txt; $Out = "retry"
    } elseif ($R.Code -eq 429) {
        $St.State = "queued"; $St.NextAt = $Now.AddSeconds((Get-CollectorRetryAfter $R)).ToString("o"); $St.LastError = "лимит запросов сервера — жду $(Get-CollectorRetryAfter $R) с"; $Out = "retry"
    } elseif ($R.Code -eq 401) {
        $St.State = "error"; $St.ErrKind = "unauthorized"; $St.LastError = "Токен не принят (отозван или неверный) — подключите сборщик заново кодом"
        Save-OutboxState $Dir $St
        $Dir = Move-OutboxR2 $Dir
        Set-OutboxPause $St.Site $St.LastError
        Send-OutboxEvent $Ctx $Dir $St "error" $St.LastError
        return @{ Outcome = "pause"; Dir = $Dir }
    } elseif ($R.Code -eq 409) {
        $St.State = "error"; $St.ErrKind = "conflict"
        $St.LastError = $(if ($What -eq "walk") { "На сервере уже есть обход с этим Id и другим содержимым" } else { "У обхода уже другая запись" }) + $(if ($Txt -and $Txt -notlike "HTTP*") { " — $Txt" })
        Save-OutboxState $Dir $St
        $Dir = Move-OutboxR2 $Dir
        Send-OutboxEvent $Ctx $Dir $St "error" $St.LastError
        return @{ Outcome = "error"; Dir = $Dir }
    } else {
        $St.State = "error"
        $Lim = $(if ($Ctx.Limits) { $Ctx.Limits } else { @{} })
        $Accepted = $(if ($What -ne "walk") { " — обход при этом уже принят" } else { "" })
        switch ($R.Code) {
            403 { $St.ErrKind = "forbidden"; $St.LastError = "Нет прав загружать на объект" }
            404 { $St.ErrKind = "notfound"; $St.LastError = "Объект или план не виден этому токену — обновите справочник и выберите заново" }
            413 { $St.ErrKind = "invalid"; $St.LastError = $(if ($What -eq "walk") { "Обход больше $(Format-OutboxMb $Lim['walk_bytes']) МБ" } else { "Запись больше $(Format-OutboxMb $Lim['audio_upload_bytes']) МБ$Accepted" }) }
            415 { $St.ErrKind = "invalid"; $St.LastError = $(if ($What -eq "walk") { "Сервер не принял формат: $Txt" } else { "Запись не WAV$Accepted" }) }
            422 { $St.ErrKind = $(if ($Code -eq "plan_required") { "notfound" } else { "invalid" }); $St.LastError = $(if ($What -ne "walk" -and $Code -eq "too_long") { "Запись длиннее 6 ч$Accepted" } else { "$Txt$Accepted" }) }
            default { $St.ErrKind = "invalid"; $St.LastError = "Ошибка сборщика: $Txt" }
        }
    }
    Save-OutboxState $Dir $St
    Send-OutboxEvent $Ctx $Dir $St $(if ($Out -eq "error") { "error" } else { "state" }) $St.LastError
    return @{ Outcome = $Out; Dir = $Dir }
}

function Read-OutboxPart {
    param([IO.FileStream]$Fs, [long]$N, [long]$PartSize, [long]$Size)
    $Len = [int][Math]::Min($PartSize, $Size - $N * $PartSize)
    $Buf = New-Object byte[] $Len
    $Fs.Position = $N * $PartSize
    $Read = 0
    while ($Read -lt $Len) { $G = $Fs.Read($Buf, $Read, $Len - $Read); if ($G -le 0) { throw "файл записи короче, чем был" }; $Read += $G }
    return , $Buf
}

# §4.2: GET audio_url → (404) POST {size, sha256} → missing parts → complete. Returns $null when the WAV is in.
function Send-OutboxAudio {
    param([string]$Dir, $St, [hashtable]$Ctx)
    $Wav = Join-Path $Dir "walk.wav"
    $Url = "$($St.AudioUrl)"
    $Up = $null; $Missing = $null; $Reuploaded = $false
    for ($Round = 0; $Round -lt 8; $Round++) {
        if (-not $Up) {
            $R = Invoke-CollectorApi -Ctx $Ctx -Path $Url -TimeoutSec 30
            if ($R.Code -eq 404) {
                if (-not (Test-Path $Wav)) { $St.State = "error"; $St.ErrKind = "invalid"; $St.LastError = "Файла записи нет — обход принят без голоса"; Save-OutboxState $Dir $St; Send-OutboxEvent $Ctx $Dir $St "error" $St.LastError; return @{ Outcome = "error"; Dir = $Dir } }
                $B = [Text.Encoding]::UTF8.GetBytes((@{ size = [long]$St.WavSize; sha256 = $St.WavSha256 } | ConvertTo-Json -Compress))
                $R = Invoke-CollectorApi -Ctx $Ctx -Method Post -Path $Url -Body $B -ContentType "application/json; charset=utf-8"
            }
            if ($R.Code -notin @(200, 201)) { return Set-OutboxFailure $Dir $St $R "audio" $Ctx }
            $Up = $R.Json
            $St.Attempts = 0
        }
        if ("$($Up['state'])" -eq "complete") { break }
        $Ps = [long]$Up['part_size']; $Size = [long]$Up['size']
        $St.Step = "parts"; $St.PartsTotal = [int]$Up['parts']; $St.PartsDone = @($Up['received'] | Where-Object { $null -ne $_ }); $St.State = "sending"
        Save-OutboxState $Dir $St; Send-OutboxEvent $Ctx $Dir $St
        $Todo = $(if ($null -ne $Missing) { @($Missing) } else { @($Up['missing'] | Where-Object { $null -ne $_ }) })
        $Missing = $null
        $Restart = $false
        if ($Todo.Count) {
            if (-not (Test-Path $Wav)) { $St.State = "error"; $St.ErrKind = "invalid"; $St.LastError = "Файла записи нет — обход принят без голоса"; Save-OutboxState $Dir $St; Send-OutboxEvent $Ctx $Dir $St "error" $St.LastError; return @{ Outcome = "error"; Dir = $Dir } }
            $Fs = [IO.File]::OpenRead($Wav)
            try {
                foreach ($N in $Todo) {
                    if ($Ctx.Ctl -and $Ctx.Ctl.Stop) { $St.State = "queued"; Save-OutboxState $Dir $St; return @{ Outcome = "stopped"; Dir = $Dir } }
                    $Buf = Read-OutboxPart $Fs ([long]$N) $Ps $Size
                    $Hex = Get-CollectorSha256 $Buf
                    $Try = 0
                    do {
                        $R = Invoke-CollectorApi -Ctx $Ctx -Method Put -Path "$Url/parts/$N" -Body $Buf -ContentType "application/octet-stream" -Headers @{ "Content-SHA256" = $Hex } -TimeoutSec 120
                        $Try++
                    } while ($R.Code -eq 400 -and (Get-CollectorErrCode $R) -eq "sha_mismatch" -and $Try -lt 3)
                    if ($R.Code -in @(200, 201)) {
                        $St.PartsDone = @(@($St.PartsDone) + @([int]$N) | Sort-Object -Unique); $St.Attempts = 0
                        Save-OutboxState $Dir $St; Send-OutboxEvent $Ctx $Dir $St
                        continue
                    }
                    $Ec = Get-CollectorErrCode $R
                    if ($R.Code -eq 404 -or ($R.Code -eq 409 -and $Ec -eq "upload_complete")) { $Up = $null; $Restart = $true; break }
                    if ($R.Code -eq 400 -and $Ec -eq "sha_mismatch") { $R = @{ Code = 0; Error = "часть $N портится в пути (sha_mismatch)"; Json = $null; Headers = @{} } }
                    return Set-OutboxFailure $Dir $St $R "part" $Ctx
                }
            } finally { $Fs.Dispose() }
        }
        if ($Restart) { continue }
        $St.Step = "complete"; Save-OutboxState $Dir $St
        $R = Invoke-CollectorApi -Ctx $Ctx -Method Post -Path "$Url/complete" -TimeoutSec 300
        if ($R.Code -in @(200, 201)) { $Up = $R.Json; if (-not $Up['state']) { $Up['state'] = "complete" }; break }
        $Ec = Get-CollectorErrCode $R
        if ($R.Code -eq 409 -and $Ec -eq "parts_missing") {
            $Missing = @($R.Json['missing'] | Where-Object { $null -ne $_ })
            if (-not $Missing.Count -and $R.Json['fields'] -and $R.Json['fields']['missing']) { $Missing = @("$($R.Json['fields']['missing'])" -split ',' | ForEach-Object { [int]$_.Trim() }) }
            if (-not $Missing.Count) { $Up = $null; $Missing = $null }
            continue
        }
        if ($R.Code -eq 400 -and $Ec -eq "sha_mismatch") {
            # the parts on the server do not add up: same file → upload all parts again, once
            if ($Reuploaded -or (Get-CollectorFileSha256 $Wav) -ne $St.WavSha256) { $St.State = "error"; $St.ErrKind = "invalid"; $St.LastError = "Запись на сервере не сошлась по sha256 — файл записи изменился (обход принят)"; Save-OutboxState $Dir $St; Send-OutboxEvent $Ctx $Dir $St "error" $St.LastError; return @{ Outcome = "error"; Dir = $Dir } }
            $Reuploaded = $true
            $Missing = @(0..([int]$Up['parts'] - 1))
            continue
        }
        if ($R.Code -eq 404) { $Up = $null; continue }
        return Set-OutboxFailure $Dir $St $R "complete" $Ctx
    }
    if (-not $Up -or "$($Up['state'])" -ne "complete") { return Set-OutboxFailure $Dir $St @{ Code = 0; Error = "загрузка записи не завершилась"; Json = $null; Headers = @{} } "audio" $Ctx }
    # the copy in the outbox is removed only after the server confirmed the whole recording
    if (Test-Path $Wav) { try { Remove-Item $Wav -Force } catch { } }
    if ($Up['stage']) { $St.Stage = "$($Up['stage'])" }
    if ([int]$St.PartsTotal -gt 0) { $St.PartsDone = @(0..([int]$St.PartsTotal - 1)) }
    $St.Step = "poll"
    return $null
}

# §4.3: stages and the result — only for showing, sending does not wait for it
function Invoke-OutboxPoll {
    param([string]$Dir, $St, [hashtable]$Ctx)
    $Now = [DateTime]::Now
    $H = @{}; if ($St.ETag) { $H["If-None-Match"] = $St.ETag }
    $R = Invoke-CollectorApi -Ctx $Ctx -Path "walks/$($St.ServerId)/result" -Headers $H -TimeoutSec 20
    $Every = $(if ($St.SentAt -and (ConvertTo-CollectorDate $St.SentAt) -lt $Now.AddHours(-1)) { 60 } else { 10 })
    switch ($R.Code) {
        200 { $St.Stage = "done"; $St.Rooms = $R.Json['rooms']; $St.ReportUrl = "$($R.Json['report_url'])"; $St.StageError = "" }
        202 { $St.Stage = "$($R.Json['stage'])"; $St.Upload = $R.Json['upload'] }
        304 { }
        409 { $St.Stage = "failed"; $St.StageError = $(if ($R.Json['detail']) { "$($R.Json['detail'])" } else { "$($R.Json['error'])" }) }
        404 { $St.Stage = "failed"; $St.StageError = "обход на сервере не найден" }
        default { $Every = $(if ($R.Code -eq 429) { Get-CollectorRetryAfter $R } else { 30 }) }
    }
    if ($R.Headers -and $R.Headers['ETag']) { $St.ETag = $R.Headers['ETag'] }
    $St.PollAt = $Now.AddSeconds($Every).ToString("o")
    Save-OutboxState $Dir $St
    Send-OutboxEvent $Ctx $Dir $St $(if ($St.Stage -in $script:CollectorFinalStages) { "stage" } else { "state" })
}

# one walk: POST /walks → WAV → «sent» (+ one poll). Continues from the step saved in state.json.
# $Ctx: @{ Url; Token; Version; Limits; OnEvent; Ctl }
function Invoke-OutboxItem {
    param([string]$Dir, [hashtable]$Ctx)
    $St = Read-OutboxState $Dir
    if (-not $St) { return @{ Outcome = "error"; Dir = $Dir } }
    if ($St.State -eq "sent") {
        if ("$($St.Stage)" -notin $script:CollectorFinalStages -and $St.ServerId) { Invoke-OutboxPoll $Dir $St $Ctx }
        return @{ Outcome = "polled"; Dir = $Dir }
    }
    if ($St.State -eq "error") { return @{ Outcome = "error"; Dir = $Dir } }
    $St.State = "sending"; Save-OutboxState $Dir $St; Send-OutboxEvent $Ctx $Dir $St
    if (-not $St.ServerId) {
        $Raw = [IO.File]::ReadAllBytes((Join-Path $Dir "envelope.json"))
        $Body = ConvertTo-GzipBytes $Raw
        for ($Try = 0; $Try -lt 2; $Try++) {
            $R = Invoke-CollectorApi -Ctx $Ctx -Method Post -Path "walks" -Body $Body -ContentType "application/json; charset=utf-8" -Headers @{ "Content-Encoding" = "gzip" } -TimeoutSec 120
            if (-not ($R.Code -eq 400 -and (Get-CollectorErrCode $R) -eq "bad_gzip")) { break }
        }
        if ($R.Code -notin @(200, 201)) { return Set-OutboxFailure $Dir $St $R "walk" $Ctx }
        $J = $R.Json
        $St.ServerId = $J['id']; $St.Uid = "$($J['uid'])"; $St.AudioUrl = "$($J['audio_url'])"; $St.Stage = "$($J['stage'])"
        $St.Created = [bool]$J['created']; $St.Attempts = 0
        $St.Step = $(if ([long]$St.WavSize -gt 0) { "audio" } else { "poll" })
        Save-OutboxState $Dir $St; Send-OutboxEvent $Ctx $Dir $St
    }
    if ([long]$St.WavSize -gt 0 -and $St.Step -in @("audio", "parts", "complete")) {
        $A = Send-OutboxAudio $Dir $St $Ctx
        if ($A) { return $A }
    }
    $St.State = "sent"; $St.Step = "poll"; $St.SentAt = [DateTime]::Now.ToString("o"); $St.LastError = ""; $St.NextAt = ""; $St.Attempts = 0
    Save-OutboxState $Dir $St
    Send-OutboxEvent $Ctx $Dir $St "sent"
    Invoke-OutboxPoll $Dir $St $Ctx
    return @{ Outcome = "sent"; Dir = $Dir }
}

# one pass over the queue, oldest first. $Conns: @{ "<url>|<slug>" = @{ Url; Token; Limits } }
function Invoke-OutboxPass {
    param([hashtable]$Conns, [string]$Version = "0", [scriptblock]$OnEvent, $Ctl, [switch]$Force)
    $Did = 0
    $PausedNow = @{}
    foreach ($I in @(Get-OutboxItems)) {
        if ($Ctl -and $Ctl.Stop) { break }
        $St = $I.State
        if ($PausedNow.ContainsKey("$($St.Site)")) { continue }
        if ($Force -and $St.State -eq "queued" -and -not $I.Paused) { $St.NextAt = "" }
        if (-not (Test-OutboxDue $I)) { continue }
        $C = $Conns["$($St.Url)|$($St.Site)"]
        if (-not $C -or -not $C.Token) {
            if ($St.State -in @("queued", "sending") -and $St.ErrKind -ne "noconn") {
                $St.State = "queued"; $St.ErrKind = "noconn"; $St.LastError = "Объект «$($St.SiteName)» не подключён — подключите сборщик кодом"
                Save-OutboxState $I.Dir $St; Send-OutboxEvent @{ OnEvent = $OnEvent } $I.Dir $St
            }
            continue
        }
        if ($St.ErrKind -eq "noconn") { $St.ErrKind = ""; $St.LastError = "" }
        $Ctx = @{ Url = $C.Url; Token = $C.Token; Limits = $C.Limits; Version = $Version; OnEvent = $OnEvent; Ctl = $Ctl }
        $Res = Invoke-OutboxItem $I.Dir $Ctx
        $Did++
        if ($Res.Outcome -eq "pause") { $PausedNow["$($St.Site)"] = $true; continue }
        # by one and in order: a temporary failure keeps the rest of this object's queue waiting as well
        if ($Res.Outcome -in @("retry", "stopped")) { break }
    }
    return $Did
}

# ---------------------------------------------------------------- old local plans (wifiplan\<site>.json)

function Send-CollectorPlanImport {
    param([hashtable]$Ctx, [string]$Site, [string]$Path)
    $Raw = [IO.File]::ReadAllBytes($Path)
    $Name = [IO.Path]::GetFileNameWithoutExtension($Path)
    try { $J = [Text.Encoding]::UTF8.GetString($Raw) | ConvertFrom-Json -AsHashtable; if ($J['Site']) { $Name = "$($J['Site'])" } } catch { $J = $null }
    $Q = "plans/import?site=$([Uri]::EscapeDataString($Site))&name=$([Uri]::EscapeDataString($Name))"
    $R = Invoke-CollectorApi -Ctx $Ctx -Method Post -Path $Q -Body $Raw -ContentType "application/json; charset=utf-8" -TimeoutSec 60
    if ($R.Code -notin @(200, 201)) { return @{ Ok = $false; Name = $Name; Error = (Get-CollectorErrText $R) } }
    $Id = $R.Json['id']
    $Img = $(if ($J -and $J['Floor'] -and $J['Floor']['Image']) { Join-Path (Split-Path $Path -Parent) "$($J['Floor']['Image'])" } else { "" })
    if ($Img -and (Test-Path $Img)) {
        $Mime = $(if ($Img -match '\.jpe?g$') { "image/jpeg" } else { "image/png" })
        $Ri = Invoke-CollectorApi -Ctx $Ctx -Method Put -Path "plans/$Id/image" -Body ([IO.File]::ReadAllBytes($Img)) -ContentType $Mime -TimeoutSec 120
        if ($Ri.Code -notin @(200, 201)) { return @{ Ok = $true; Name = $Name; PlanId = $Id; Error = "план принят, картинка — нет: $(Get-CollectorErrText $Ri)" } }
    }
    return @{ Ok = $true; Name = $Name; PlanId = $Id }
}
