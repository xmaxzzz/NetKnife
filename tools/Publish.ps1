# Cut a release: bump VERSION, commit, tag, build NetKnife.zip, publish it as a GitHub release.
# Usage:  pwsh -File tools\Publish.ps1 -Version 2026.10.15.1 -Notes "что нового"
#         pwsh -File tools\Publish.ps1 -Bump           (last number +1)
param(
    [string]$Version,
    [switch]$Bump,
    [string]$Notes = "",
    [string]$Repo = "xmaxzzz/NetKnife"
)
$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root

$Cur = "0.0.0.0"
if (Test-Path "VERSION") { $Cur = (Get-Content VERSION | Select-Object -First 1).Trim() }
if ($Bump) {
    $Parts = $Cur -split '\.'
    $Parts[-1] = [int]$Parts[-1] + 1
    $Version = $Parts -join '.'
}
if (-not $Version) { throw "нужен -Version X.Y.Z.N или -Bump (сейчас $Cur)" }
Set-Content -Path VERSION -Value $Version -Encoding ascii -NoNewline

# zip: everything the app needs, nothing from dev/history
$Out = Join-Path $env:TEMP "NetKnife.zip"
if (Test-Path $Out) { Remove-Item $Out -Force }
$Include = Get-ChildItem $Root -Force | Where-Object { $_.Name -notin @(".git", ".gitignore", "legacy", "tools", "tests", ".claude") -and $_.Name -notlike "*.bak*" }
Compress-Archive -Path ($Include | ForEach-Object { $_.FullName }) -DestinationPath $Out -CompressionLevel Optimal
"zip: $Out ({0:N1} МБ)" -f ((Get-Item $Out).Length / 1MB)

git add -A
git commit -q -m "release v$Version" 2>$null
git tag -f "v$Version"
if (-not $Notes) { $Notes = "NetKnife $Version" }
# the link to GitHub drops now and then: retry and verify each step instead of trusting the exit code
for ($i = 1; $i -le 5; $i++) {
    git push -q origin main 2>&1 | Out-Null
    git push -q -f origin "v$Version" 2>&1 | Out-Null
    git fetch -q origin 2>&1 | Out-Null
    if ((git rev-parse origin/main) -eq (git rev-parse HEAD) -and (git ls-remote --tags origin "v$Version")) { break }
    "push: попытка $i не прошла, повторяю…"; Start-Sleep 5
}
if ((git rev-parse origin/main) -ne (git rev-parse HEAD)) { throw "main не отправлен на GitHub" }
for ($i = 1; $i -le 5; $i++) {
    if (-not (gh release view "v$Version" --repo $Repo --json tagName -q .tagName 2>$null)) { gh release create "v$Version" $Out --repo $Repo --title "NetKnife $Version" --notes $Notes 2>&1 | Out-Null }
    if (gh release view "v$Version" --repo $Repo --json tagName -q .tagName 2>$null) { break }
    "release: попытка $i не прошла, повторяю…"; Start-Sleep 5
}
if (-not (gh release view "v$Version" --repo $Repo --json tagName -q .tagName 2>$null)) { throw "релиз v$Version не создан" }
"released v$Version — https://github.com/$Repo/releases/tag/v$Version"
