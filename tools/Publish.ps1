# Cut a release: bump VERSION, build NetKnife.zip, commit VERSION, tag, push main + tag atomically, publish a GitHub release.
# Usage:  pwsh -File tools\Publish.ps1 -Version 2026.10.15.1 -Notes "что нового"
#         pwsh -File tools\Publish.ps1 -Bump           (last number +1)
#         pwsh -File tools\Publish.ps1 -Bump -DryRun   (all checks + zip, nothing is committed, tagged or pushed)
# Refuses to start unless: branch main, clean tree (untracked too), HEAD == origin/main after fetch, the new tag is not
# taken locally / on origin / by a release, gh is logged in. Nothing is changed before these checks pass.
param(
    [string]$Version,
    [switch]$Bump,
    [string]$Notes = "",
    [string]$Repo = "xmaxzzz/NetKnife",
    [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root

# files the script itself changes — the only ones that go into the release commit
$ReleaseFiles = @("VERSION")

# run git/gh, return exit code + output lines (stderr included) instead of trusting $ErrorActionPreference
function Invoke-Tool([string]$Exe, [string[]]$ToolArgs) {
    $global:LASTEXITCODE = 0
    $Out = & $Exe @ToolArgs 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($Out); Text = (@($Out) -join "`n").Trim() }
}
function Stop-Publish([string]$Why, [string]$Fix) {
    $Msg = "релиз остановлен: $Why"
    if ($Fix) { $Msg += "`n  что сделать: $Fix" }
    throw $Msg
}

# --- preflight: read-only, nothing is changed until all of it passes ---
foreach ($Exe in "git", "gh") {
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { Stop-Publish "не найден $Exe" "установи $Exe и добавь в PATH" }
}
$R = Invoke-Tool gh @("auth", "status")
if ($R.Code -ne 0) { Stop-Publish "gh не авторизован ($($R.Text))" "gh auth login" }

$R = Invoke-Tool git @("fetch", "-q", "origin")
if ($R.Code -ne 0) { Stop-Publish "git fetch origin не прошёл ($($R.Text))" "проверь сеть/доступ к GitHub и запусти снова" }

$Branch = (Invoke-Tool git @("rev-parse", "--abbrev-ref", "HEAD")).Text
if ($Branch -ne "main") { Stop-Publish "текущая ветка '$Branch', а релиз выпускается только с main" "git switch main" }

$R = Invoke-Tool git @("status", "--porcelain", "--untracked-files=all")
if ($R.Code -ne 0) { Stop-Publish "git status не прошёл ($($R.Text))" }
$Dirty = @($R.Out | Where-Object { $_ })
if ($Dirty) {
    $List = ($Dirty | Select-Object -First 10 | ForEach-Object { "    $_" }) -join "`n"
    if ($Dirty.Count -gt 10) { $List += "`n    … ещё $($Dirty.Count - 10)" }
    Stop-Publish "рабочее дерево не чистое ($($Dirty.Count) файл(ов)):`n$List" "закоммить нужное (git commit) или убери в сторону (git stash -u), потом git pull --ff-only"
}

$R = Invoke-Tool git @("rev-list", "--left-right", "--count", "HEAD...origin/main")
if ($R.Code -ne 0) { Stop-Publish "не удалось сравнить HEAD с origin/main ($($R.Text))" }
$Ahead, $Behind = [int[]]($R.Text -split '\s+')
if ($Behind -gt 0 -and $Ahead -gt 0) { Stop-Publish "main разошёлся с origin/main (локально +$Ahead, на GitHub +$Behind коммит(ов))" "разберись вручную: git log --oneline --graph main origin/main" }
if ($Behind -gt 0) { Stop-Publish "main позади origin/main на $Behind коммит(ов) — zip собрался бы со старого кода" "git pull --ff-only" }
if ($Ahead -gt 0) { Stop-Publish "main впереди origin/main на $Ahead коммит(ов) — они не на GitHub" "сначала git push origin main (или сбрось лишнее), потом релиз" }
$StartHead = (Invoke-Tool git @("rev-parse", "HEAD")).Text

$Cur = "0.0.0.0"
if (Test-Path "VERSION") { $Cur = (Get-Content VERSION | Select-Object -First 1).Trim() }
if ($Bump) {
    $Parts = $Cur -split '\.'
    $Parts[-1] = [int]$Parts[-1] + 1
    $Version = $Parts -join '.'
}
if (-not $Version) { Stop-Publish "нужен -Version X.Y.Z.N или -Bump (сейчас $Cur)" }
if ($Version -eq $Cur) { Stop-Publish "версия $Version уже записана в VERSION" "-Bump или другой -Version" }
$Tag = "v$Version"

if ((Invoke-Tool git @("tag", "-l", $Tag)).Text) { Stop-Publish "тег $Tag уже есть локально" "другая версия, или git tag -d $Tag, если он ошибочный" }
$R = Invoke-Tool git @("ls-remote", "--tags", "origin", "refs/tags/$Tag")
if ($R.Code -ne 0) { Stop-Publish "не удалось проверить теги на origin ($($R.Text))" "проверь сеть и запусти снова" }
if ($R.Text) { Stop-Publish "тег $Tag уже есть на GitHub" "другая версия; удалять опубликованный тег — только осознанно" }
$R = Invoke-Tool gh @("release", "view", $Tag, "--repo", $Repo, "--json", "tagName")
if ($R.Code -eq 0) { Stop-Publish "релиз $Tag уже есть на GitHub" "другая версия" }
if ($R.Text -notmatch "not found") { Stop-Publish "не удалось проверить релиз $Tag ($($R.Text))" "проверь сеть и запусти снова" }

"проверки пройдены: main == origin/main ($($StartHead.Substring(0, [Math]::Min(7, $StartHead.Length)))), дерево чистое, $Tag свободен"

# --- build: VERSION + zip; on any failure before the push the tree goes back to $StartHead (it was clean) ---
$Out = Join-Path ([IO.Path]::GetTempPath()) "NetKnife.zip"
$TagCreated = $false
$Pushed = $false
$Unverified = $false
function Undo-Local {
    if ($TagCreated) { Invoke-Tool git @("tag", "-d", $Tag) | Out-Null }
    Invoke-Tool git @("reset", "-q", "--hard", $StartHead) | Out-Null
}
try {
    Set-Content -Path VERSION -Value $Version -Encoding ascii -NoNewline

    # zip: everything the app needs, nothing from dev/history
    if (Test-Path $Out) { Remove-Item $Out -Force }
    $Include = Get-ChildItem $Root -Force | Where-Object { $_.Name -notin @(".git", ".gitignore", "legacy", "tools", "tests", ".claude") -and $_.Name -notlike "*.bak*" }
    Compress-Archive -Path ($Include | ForEach-Object { $_.FullName }) -DestinationPath $Out -CompressionLevel Optimal
    "zip: $Out ({0:N1} МБ)" -f ((Get-Item $Out).Length / 1MB)

    if ($DryRun) {
        Invoke-Tool git (@("checkout", "-q", "--") + $ReleaseFiles) | Out-Null
        "DryRun: zip для $Tag собран из $StartHead; коммит, тег, push и релиз пропущены, VERSION возвращён"
        return
    }

    $R = Invoke-Tool git (@("add", "--") + $ReleaseFiles)
    if ($R.Code -ne 0) { throw "git add: $($R.Text)" }
    $R = Invoke-Tool git (@("commit", "-q", "-m", "release $Tag", "--") + $ReleaseFiles)
    if ($R.Code -ne 0) { throw "git commit: $($R.Text)" }
    $R = Invoke-Tool git @("tag", $Tag)
    if ($R.Code -ne 0) { throw "git tag: $($R.Text)" }
    $TagCreated = $true
    $NewHead = (Invoke-Tool git @("rev-parse", "HEAD")).Text

    # main and the tag go together or not at all; the link to GitHub drops now and then, so a failed push is retried
    # with the same atomic set, and a "failed" push that actually landed is recognised by ls-remote
    for ($i = 1; $i -le 3; $i++) {
        $R = Invoke-Tool git @("push", "--atomic", "origin", "main", $Tag)
        if ($R.Code -eq 0) { $Pushed = $true; break }
        $Remote = Invoke-Tool git @("ls-remote", "origin", "refs/heads/main", "refs/tags/$Tag")
        $Unverified = $Remote.Code -ne 0
        $RemoteMain = ($Remote.Out | Where-Object { $_ -match 'refs/heads/main$' } | ForEach-Object { ($_ -split '\s+')[0] })
        $RemoteTag = ($Remote.Out | Where-Object { $_ -match "refs/tags/$([regex]::Escape($Tag))$" } | ForEach-Object { ($_ -split '\s+')[0] })
        if ($Remote.Code -eq 0 -and $RemoteMain -eq $NewHead -and $RemoteTag) { $Pushed = $true; break }
        if ($Remote.Code -eq 0 -and $RemoteMain -and $RemoteMain -ne $StartHead) { throw "push отклонён: origin/main ушёл вперёд ($RemoteMain) — $($R.Text)" }
        if ($i -lt 3) { "push: попытка $i/3 не прошла ($($R.Text)), повторяю тот же атомарный push…"; Start-Sleep 5 }
    }
    if (-not $Pushed) { throw "push не прошёл за 3 попытки: $($R.Text)" }
}
catch {
    if (-not $Pushed) {
        Undo-Local
        $Remote = if ($Unverified) { "состояние origin проверить не удалось (сеть) — посмотри git ls-remote origin main $Tag" } else { "на GitHub ничего не отправлено (push атомарный)" }
        throw "релиз $Tag не выпущен: $($_.Exception.Message)`n  локально откатено: тег $Tag удалён, main сброшен на $StartHead; $Remote.`n  что сделать: git fetch, проверь git status / git log origin/main и запусти скрипт снова"
    }
    throw
}

# --- GitHub release: only after main + tag are on origin ---
if (-not $Notes) { $Notes = "NetKnife $Version" }
$Created = $false
for ($i = 1; $i -le 3; $i++) {
    $R = Invoke-Tool gh @("release", "create", $Tag, $Out, "--repo", $Repo, "--title", "NetKnife $Version", "--notes", $Notes)
    if ((Invoke-Tool gh @("release", "view", $Tag, "--repo", $Repo, "--json", "tagName")).Code -eq 0) { $Created = $true; break }
    if ($i -lt 3) { "release: попытка $i/3 не прошла ($($R.Text)), повторяю…"; Start-Sleep 5 }
}
if (-not $Created) {
    throw "коммит $NewHead и тег $Tag уже на GitHub, но релиз не создан: $($R.Text)`n  доделать вручную (zip лежит в $Out):`n  gh release create $Tag `"$Out`" --repo $Repo --title `"NetKnife $Version`" --notes `"$Notes`""
}
"released $Tag — https://github.com/$Repo/releases/tag/$Tag"
