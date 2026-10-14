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
$Include = Get-ChildItem $Root -Force | Where-Object { $_.Name -notin @(".git", ".gitignore", "legacy", "tools", ".claude") -and $_.Name -notlike "*.bak*" }
Compress-Archive -Path ($Include | ForEach-Object { $_.FullName }) -DestinationPath $Out -CompressionLevel Optimal
"zip: $Out ({0:N1} МБ)" -f ((Get-Item $Out).Length / 1MB)

git add -A
git commit -q -m "release v$Version" 2>$null
git tag -f "v$Version"
git push -q origin main
git push -q -f origin "v$Version"
if (-not $Notes) { $Notes = "NetKnife $Version" }
gh release create "v$Version" $Out --repo $Repo --title "NetKnife $Version" --notes $Notes
"released v$Version"
