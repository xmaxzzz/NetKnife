# Self-update from GitHub releases. A release carries NetKnife.zip (app folder at the zip root); the app
# compares the release tag with VERSION, downloads the zip, then hands over to a tiny updater script that
# waits for this process to exit, copies the files over, and relaunches via launch.vbs.

$script:UpdateRepo = "xmaxzzz/NetKnife"
$script:AppVersion = "0"
try { $V = Get-Content (Join-Path $script:AppDir "VERSION") -ErrorAction Stop | Select-Object -First 1; if ($V) { $script:AppVersion = "$V".Trim() } } catch { }
$script:UpdateAvail = $null      # @{ Tag; Version; Url; Size; Notes } once a newer release is known
$script:UpdateTmp = Join-Path $script:DataDir "update"

function ConvertTo-AppVersion {
    param([string]$S)
    $S = "$S".Trim() -replace '^[vV]', ''
    try { return [version]$S } catch { }
    try { return [version]"$S.0" } catch { }
    return [version]"0.0"
}

$script:UpdateCheckBody = {
    param($Q, $Ctl, $Repo)
    try {
        $Rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "NetKnife" } -TimeoutSec 25
        $Asset = @($Rel.assets | Where-Object { $_.name -eq "NetKnife.zip" }) | Select-Object -First 1
        if (-not $Asset) { $Q.Enqueue(@{ Type = "upd"; Error = "в релизе $($Rel.tag_name) нет NetKnife.zip" }); return }
        $Q.Enqueue(@{ Type = "upd"; Tag = "$($Rel.tag_name)"; Url = "$($Asset.browser_download_url)"; Size = [long]$Asset.size; Notes = "$($Rel.body)"; Published = "$($Rel.published_at)" })
    } catch {
        $Msg = "$($_.Exception.Message)"
        if ($Msg -match '404') { $Msg = "релизов ещё нет" }
        $Q.Enqueue(@{ Type = "upd"; Error = $Msg })
    }
}

function Start-UpdateCheck {
    param([switch]$Manual)
    if (Test-WorkerRunning "upd-check") { return }
    if ($Manual) { Set-UpdateStatus "Проверяю GitHub…" }
    [void](Start-Worker -Name "upd-check" -Body $script:UpdateCheckBody -ArgList @($script:UpdateRepo) -State @{ Manual = [bool]$Manual } -OnMessage {
        param($M)
        if ($M.Type -ne "upd") { return }
        if ($M.Error) {
            Write-AppLog "update check: $($M.Error)"
            if ($State.Manual) { Set-UpdateStatus "Не удалось проверить: $($M.Error)" }
            return
        }
        $Remote = ConvertTo-AppVersion $M.Tag
        $Local = ConvertTo-AppVersion $script:AppVersion
        if ($Remote -gt $Local) {
            $script:UpdateAvail = @{ Tag = $M.Tag; Url = $M.Url; Size = $M.Size; Notes = $M.Notes }
            Set-UpdateStatus ("Доступна версия $($M.Tag) ({0:N1} МБ)" -f ($M.Size / 1MB))
            if ($Ui.SetUpdApply) { $Ui.SetUpdApply.Visibility = "Visible" }
            Show-Toast "Доступно обновление NetKnife $($M.Tag) — Настройки → Обновить" "info"
        } else {
            $script:UpdateAvail = $null
            if ($Ui.SetUpdApply) { $Ui.SetUpdApply.Visibility = "Collapsed" }
            if ($State.Manual) { Set-UpdateStatus "Это последняя версия ($($M.Tag))" }
        }
    })
}

function Set-UpdateStatus {
    param([string]$Text)
    if ($Ui -and $Ui.SetUpdStatus) { $Ui.SetUpdStatus.Text = $Text }
}

$script:UpdateDownloadBody = {
    param($Q, $Ctl, $Url, $Tmp)
    try {
        if (Test-Path $Tmp) { Remove-Item $Tmp -Recurse -Force }
        New-Item -ItemType Directory -Path $Tmp | Out-Null
        $Zip = Join-Path $Tmp "NetKnife.zip"
        Invoke-WebRequest $Url -OutFile $Zip -Headers @{ "User-Agent" = "NetKnife" } -TimeoutSec 300
        $New = Join-Path $Tmp "new"
        Expand-Archive $Zip -DestinationPath $New -Force
        # tolerate a zip with a single top-level folder
        if (-not (Test-Path (Join-Path $New "NetKnife.ps1"))) {
            $Inner = Get-ChildItem $New -Directory | Where-Object { Test-Path (Join-Path $_.FullName "NetKnife.ps1") } | Select-Object -First 1
            if ($Inner) { $New = $Inner.FullName }
        }
        if (-not (Test-Path (Join-Path $New "NetKnife.ps1"))) { $Q.Enqueue(@{ Type = "upddl"; Error = "в архиве нет NetKnife.ps1" }); return }
        $Q.Enqueue(@{ Type = "upddl"; Src = $New })
    } catch { $Q.Enqueue(@{ Type = "upddl"; Error = "$($_.Exception.Message)" }) }
}

function Install-AppUpdate {
    $U = $script:UpdateAvail
    if (-not $U) { Show-Toast "Сначала проверь обновления" "info"; return }
    if (Test-WorkerRunning "upd-dl") { return }
    $Msg = "NetKnife $($U.Tag) скачается с GitHub ($($script:UpdateRepo)), приложение закроется, файлы заменятся и оно запустится снова. Настройки и данные не трогаются."
    if (-not (Show-Confirm "Обновить до $($U.Tag)?" $Msg "Обновить" -Detail $U.Notes)) { return }
    Set-UpdateStatus "Скачиваю $($U.Tag)…"
    [void](Start-Worker -Name "upd-dl" -Body $script:UpdateDownloadBody -ArgList @($U.Url, $script:UpdateTmp) -OnMessage {
        param($M)
        if ($M.Type -ne "upddl") { return }
        if ($M.Error) { Set-UpdateStatus "Загрузка не удалась: $($M.Error)"; Show-Toast "Обновление: $($M.Error)" "fail"; return }
        Invoke-AppReplace $M.Src
    })
}

# Hands over to an external pwsh: wait for us to exit, copy the new files in, relaunch.
function Invoke-AppReplace {
    param([string]$Src)
    $Script = Join-Path $script:UpdateTmp "apply.ps1"
    @'
param([int]$ProcId, [string]$Src, [string]$Dst, [string]$Launch)
$Deadline = (Get-Date).AddSeconds(40)
while ((Get-Date) -lt $Deadline -and (Get-Process -Id $ProcId -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 300 }
Start-Sleep -Milliseconds 500
$Log = Join-Path (Split-Path $Src -Parent) "apply.log"
try {
    Copy-Item -Path (Join-Path $Src "*") -Destination $Dst -Recurse -Force
    "ok $(Get-Date -Format s)" | Set-Content $Log
} catch { "fail $(Get-Date -Format s): $_" | Set-Content $Log }
if (Test-Path $Launch) { Start-Process wscript.exe -ArgumentList ('"' + $Launch + '"') }
'@ | Set-Content -Path $Script -Encoding UTF8
    $Launch = Join-Path $script:AppDir "launch.vbs"
    $Pwsh = (Get-Process -Id $PID).Path
    $ArgsLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $(Quote-Arg $Script) -ProcId $PID -Src $(Quote-Arg $Src) -Dst $(Quote-Arg $script:AppDir) -Launch $(Quote-Arg $Launch)"
    Start-Process $Pwsh -ArgumentList $ArgsLine -WindowStyle Hidden
    Write-AppLog "update: applying from $Src"
    $script:ReallyExit = $true
    $script:Win.Close()
}
