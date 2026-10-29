# Self-update from GitHub releases. A release carries NetKnife.zip (app folder at the zip root); the GitHub API gives
# its SHA256 digest. At start the app checks quietly, not more often than every $UpdateEveryHours (the answer is cached
# in settings), and shows the banner "Доступна vX — Обновить". One click: download, SHA256 against the digest, unpack,
# then the new package's install.ps1 takes over (-Source <unpacked> -WaitPid <this pid>): it waits for this process to
# exit, backs the old files up, copies the new ones over, relaunches and rolls back if the new version does not start.
# Everything is relative to $script:AppDir, so any install folder works (%LOCALAPPDATA%\NetKnife, a git clone, …).

$script:UpdateRepo = "xmaxzzz/NetKnife"
$script:UpdateEveryHours = 6
$script:AppVersion = "0"
try { $V = Get-Content (Join-Path $script:AppDir "VERSION") -ErrorAction Stop | Select-Object -First 1; if ($V) { $script:AppVersion = "$V".Trim() } } catch { }
$script:UpdateAvail = $null      # @{ Tag; Url; Size; Sha256; Notes } once a newer release is known
$script:UpdateDir = Join-Path $script:DataDir "update"   # shared with install.ps1: started.txt, result.json, backup\, install.log
$script:UpdateTmp = Join-Path $script:UpdateDir "dl"
$script:QuitSignal = $null
$script:UpdateLastError = ""     # the previous attempt failed (update\result.json) — kept in the banner text

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
        $Sha = $(if ("$($Asset.digest)" -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1].ToLower() } else { "" })
        $Q.Enqueue(@{ Type = "upd"; Tag = "$($Rel.tag_name)"; Url = "$($Asset.browser_download_url)"; Size = [long]$Asset.size; Sha256 = $Sha; Notes = "$($Rel.body)" })
    } catch {
        $Msg = "$($_.Exception.Message)"
        if ($Msg -match '404') { $Msg = "релизов ещё нет" }
        $Q.Enqueue(@{ Type = "upd"; Error = $Msg })
    }
}

# Quiet start-up check uses the cached answer while it is fresh; "Проверить" always asks GitHub.
function Start-UpdateCheck {
    param([switch]$Manual)
    if (Test-WorkerRunning "upd-check") { return }
    $Age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]("0$($script:Settings.UpdateCheckedAt)" -replace '\D', '')
    if (-not $Manual -and $script:Settings.UpdateCache -and $Age -lt $script:UpdateEveryHours * 3600) {
        Use-UpdateInfo $script:Settings.UpdateCache
        return
    }
    if ($Manual) { Set-UpdateStatus "Проверяю GitHub…" }
    [void](Start-Worker -Name "upd-check" -Body $script:UpdateCheckBody -ArgList @($script:UpdateRepo) -State @{ Manual = [bool]$Manual } -OnMessage {
        param($M)
        if ($M.Type -ne "upd") { return }
        if ($M.Error) {
            Write-AppLog "update check: $($M.Error)"
            if ($State.Manual) { Set-UpdateStatus "Не удалось проверить: $($M.Error)" }
            return
        }
        $script:Settings.UpdateCheckedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $script:Settings.UpdateCache = @{ Tag = $M.Tag; Url = $M.Url; Size = $M.Size; Sha256 = $M.Sha256; Notes = $M.Notes }
        Save-Settings
        Use-UpdateInfo $script:Settings.UpdateCache -Manual:$State.Manual
    })
}

function Use-UpdateInfo {
    param($Info, [switch]$Manual)
    if ((ConvertTo-AppVersion $Info.Tag) -gt (ConvertTo-AppVersion $script:AppVersion)) {
        $script:UpdateAvail = @{ Tag = "$($Info.Tag)"; Url = "$($Info.Url)"; Size = [long]$Info.Size; Sha256 = "$($Info.Sha256)"; Notes = "$($Info.Notes)" }
        Set-UpdateStatus ("Доступна версия $($Info.Tag) ({0:N1} МБ)" -f ($script:UpdateAvail.Size / 1MB))
        if ($Ui.SetUpdApply) { $Ui.SetUpdApply.Visibility = "Visible" }
        if ($script:UpdateLastError) { Show-UpdateBanner "Доступна NetKnife $($Info.Tag) · прошлая попытка не удалась: $($script:UpdateLastError)" -Button "Обновить" -Fail }
        else { Show-UpdateBanner "Доступна NetKnife $($Info.Tag)" -Button "Обновить" }
    } else {
        $script:UpdateAvail = $null
        if ($Ui.SetUpdApply) { $Ui.SetUpdApply.Visibility = "Collapsed" }
        if ($Manual) { Set-UpdateStatus "Это последняя версия ($($Info.Tag))" }
    }
}

function Set-UpdateStatus {
    param([string]$Text)
    if ($Ui -and $Ui.SetUpdStatus) { $Ui.SetUpdStatus.Text = $Text }
}

# the banner above the page header; -Button "" hides the button (download in progress)
function Show-UpdateBanner {
    param([string]$Text, [string]$Button = "", [switch]$Fail)
    if (-not ($Ui -and $Ui.UpdBanner)) { return }
    $Ui.UpdBannerText.Text = $Text
    $Ui.UpdBannerText.Foreground = Get-Brush $(if ($Fail) { "Fail" } else { "Text" })
    $Ui.UpdBannerBtnText.Text = $Button
    $Ui.UpdBannerBtn.Visibility = $(if ($Button) { "Visible" } else { "Collapsed" })
    $Ui.UpdBannerBtn.ToolTip = $(if ($script:UpdateAvail -and $script:UpdateAvail.Notes) { $script:UpdateAvail.Notes } else { $null })
    $Ui.UpdBanner.Visibility = "Visible"
}

function Initialize-UpdateBanner {
    $Ui.UpdBannerBtn.Add_Click({ Install-AppUpdate })
    $Ui.UpdBannerClose.Add_Click({ $Ui.UpdBanner.Visibility = "Collapsed" })
}

$script:UpdateDownloadBody = {
    param($Q, $Ctl, $Url, $Sha256, $Tmp)
    try {
        if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Recurse -Force }
        New-Item -ItemType Directory -Path $Tmp | Out-Null
        $Zip = Join-Path $Tmp "NetKnife.zip"
        Invoke-WebRequest $Url -OutFile $Zip -Headers @{ "User-Agent" = "NetKnife" } -TimeoutSec 300
        $Got = (Get-FileHash -Algorithm SHA256 -LiteralPath $Zip).Hash.ToLower()
        if ($Got -ne "$Sha256".ToLower()) {
            Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
            $Why = $(if ($Sha256) { "SHA256 архива не совпал с GitHub — файл удалён" } else { "GitHub не отдал SHA256 архива — проверить нечем" })
            $Q.Enqueue(@{ Type = "upddl"; Error = $Why }); return
        }
        $New = Join-Path $Tmp "new"
        try { Expand-Archive -LiteralPath $Zip -DestinationPath $New -Force }
        catch { $Q.Enqueue(@{ Type = "upddl"; Error = "архив не распаковался: $($_.Exception.Message)" }); return }
        # tolerate a zip with a single top-level folder
        if (-not (Test-Path -LiteralPath (Join-Path $New "NetKnife.ps1"))) {
            $Inner = Get-ChildItem -LiteralPath $New -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "NetKnife.ps1") } | Select-Object -First 1
            if ($Inner) { $New = $Inner.FullName }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $New "NetKnife.ps1")) -or -not (Test-Path -LiteralPath (Join-Path $New "VERSION"))) {
            $Q.Enqueue(@{ Type = "upddl"; Error = "в архиве нет NetKnife.ps1 или VERSION" }); return
        }
        $Q.Enqueue(@{ Type = "upddl"; Src = $New })
    } catch { $Q.Enqueue(@{ Type = "upddl"; Error = "$($_.Exception.Message)" }) }
}

# one click: no confirmation, settings and data are not touched
function Install-AppUpdate {
    $U = $script:UpdateAvail
    if (-not $U) { Show-Toast "Сначала проверь обновления" "info"; return }
    if (Test-WorkerRunning "upd-dl") { return }
    Set-UpdateStatus "Скачиваю $($U.Tag)…"
    Show-UpdateBanner "Скачиваю NetKnife $($U.Tag)…"
    if ($Ui.SetUpdApply) { $Ui.SetUpdApply.IsEnabled = $false }
    [void](Start-Worker -Name "upd-dl" -Body $script:UpdateDownloadBody -ArgList @($U.Url, $U.Sha256, $script:UpdateTmp) -OnMessage {
        param($M)
        if ($M.Type -ne "upddl") { return }
        if ($M.Error) {
            Write-AppLog "update download: $($M.Error)"
            if ($Ui.SetUpdApply) { $Ui.SetUpdApply.IsEnabled = $true }
            Set-UpdateStatus "Загрузка не удалась: $($M.Error)"
            Show-UpdateBanner "Обновление не скачалось: $($M.Error)" -Button "Повторить" -Fail
            return
        }
        Show-UpdateBanner "Устанавливаю $($script:UpdateAvail.Tag) — NetKnife перезапустится…"
        Invoke-AppReplace $M.Src
    })
}

# Hands over to install.ps1 of the new package (an older package without it: ours) and exits.
function Invoke-AppReplace {
    param([string]$Src)
    $Installer = Join-Path $Src "install.ps1"
    if (-not (Test-Path -LiteralPath $Installer)) { $Installer = Join-Path $script:AppDir "install.ps1" }
    $Pwsh = (Get-Process -Id $PID).Path
    $ArgsLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $(Quote-Arg $Installer) -Path $(Quote-Arg $script:AppDir) -Source $(Quote-Arg $Src) -WaitPid $PID -Quiet -NoShortcuts"
    Start-Process -FilePath $Pwsh -ArgumentList $ArgsLine -WindowStyle Hidden
    Write-AppLog "update: install.ps1 from $Src → $($script:AppDir)"
    $script:ReallyExit = $true
    $script:Win.Close()
}

# Right before the window shows: tell install.ps1 this version started (no file in 90 s → it rolls back) and open the
# quit signal install.ps1 uses to close a running copy the proper way.
function Register-AppStarted {
    try {
        New-Item -ItemType Directory -Path $script:UpdateDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:UpdateDir "started.txt") -Value $script:AppVersion -Encoding UTF8
    } catch { Write-AppLog "update marker: $_" }
    try { $script:QuitSignal = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, "Local\NetKnife.Quit") } catch { }
}

function Test-QuitSignal {
    if ($script:QuitSignal -and $script:QuitSignal.WaitOne(0)) {
        Write-AppLog "quit requested by install.ps1"
        $script:ReallyExit = $true
        $script:Win.Close()
    }
}

# result of the last install/update (install.ps1 writes update\result.json); shown once, after Start-UpdateCheck
function Show-UpdateResult {
    $F = Join-Path $script:UpdateDir "result.json"
    if (-not (Test-Path -LiteralPath $F)) { return }
    try { $R = Get-Content -LiteralPath $F -Raw | ConvertFrom-Json } catch { $R = $null }
    Remove-Item -LiteralPath $F -Force -ErrorAction SilentlyContinue
    if (-not $R) { return }
    if ($R.Ok) {
        if ($R.From -and $R.From -ne $R.Version) { Show-Toast "NetKnife обновлён: $($R.From) → $($R.Version)" }
    } else {
        $script:UpdateLastError = "$($R.Error)"
        Set-UpdateStatus "Обновление до $($R.Version) не удалось: $($R.Error)"
        Show-UpdateBanner "Обновление до $($R.Version) не удалось: $($R.Error)" -Button $(if ($script:UpdateAvail) { "Повторить" } else { "" }) -Fail
        Show-Toast "Обновление не удалось — работает прежняя версия" "fail"
    }
}
