# NetKnife: установка, обновление и удаление. Работает в Windows PowerShell 5.1 и в pwsh 7, админ не нужен.
#
#   irm https://raw.githubusercontent.com/xmaxzzz/NetKnife/main/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/xmaxzzz/NetKnife/main/install.ps1))) -Path D:\Tools\NetKnife
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/xmaxzzz/NetKnife/main/install.ps1))) -Uninstall [-RemoveData]
#
# Install = repeat install = update: PowerShell 7 (winget) → releases/latest NetKnife.zip, SHA256 checked against the
# asset digest from the GitHub API → running NetKnife asked to quit → old files backed up → new files copied over →
# shortcuts → launch, and if the new version does not start in 90 s the old files come back. %APPDATA%\NetKnife is
# never touched except its update\ folder (backup, log, result for the app).
# The app's own "Обновить" runs the new package's install.ps1 -Source <unpacked, already verified> -WaitPid <app pid> -Quiet.
param(
    [string]$Path,
    [switch]$Uninstall,
    [switch]$RemoveData,
    [string]$Source,
    [int]$WaitPid,
    [switch]$Quiet,
    [switch]$NoShortcuts,
    [switch]$NoLaunch
)

$NkRepo = "xmaxzzz/NetKnife"
$NkStartTimeout = 90

function Get-NkDefaultPath { Join-Path $env:LOCALAPPDATA "NetKnife" }
function Get-NkDataDir { Join-Path $env:APPDATA "NetKnife" }
function Get-NkUpdateDir { Join-Path (Get-NkDataDir) "update" }

function Write-NkLog {
    param([string]$Text, [string]$Color = "Gray")
    if (-not $script:NkQuiet) { Write-Host $Text -ForegroundColor $Color }
    try { Add-Content -LiteralPath (Join-Path (Get-NkUpdateDir) "install.log") -Value "$(Get-Date -Format s) $Text" -Encoding UTF8 } catch { }
}

function Get-NkVersion {
    param([string]$Dir)
    $F = Join-Path $Dir "VERSION"
    if (-not (Test-Path -LiteralPath $F)) { return "" }
    return "$(Get-Content -LiteralPath $F -TotalCount 1)".Trim().TrimStart([char]0xFEFF)
}

function Read-NkYes {
    param([string]$Question)
    return ((Read-Host "$Question [y/N]") -match '^\s*(y|yes|д|да)\s*$')
}

# ---------------------------------------------------------------- PowerShell 7

function Find-NkPwsh {
    foreach ($P in @($env:ProgramW6432, $env:ProgramFiles)) {
        if ($P) { $C = Join-Path $P "PowerShell\7\pwsh.exe"; if (Test-Path -LiteralPath $C) { return $C } }
    }
    $Cmd = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Cmd) { return $Cmd.Source }
    return $null
}

function Assert-NkPwsh {
    if (Find-NkPwsh) { return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Нужен PowerShell 7, а winget не найден. Поставьте PowerShell 7 по инструкции https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows (или «Установщик приложений» из Microsoft Store, тогда появится winget) и запустите команду снова."
    }
    Write-NkLog "Ставлю PowerShell 7: winget install --id Microsoft.PowerShell -e" Cyan
    & winget install --id Microsoft.PowerShell -e --source winget --accept-package-agreements --accept-source-agreements
    if (-not (Find-NkPwsh)) { throw "PowerShell 7 не установился (winget, код $LASTEXITCODE). Поставьте вручную: winget install --id Microsoft.PowerShell -e" }
}

# ---------------------------------------------------------------- release: download + SHA256

function ConvertFrom-NkDigest {
    param([string]$Digest)
    if ("$Digest" -match '^sha256:([0-9a-fA-F]{64})$') { return $Matches[1].ToLower() }
    return ""
}

function Get-NkRelease {
    $Rel = Invoke-RestMethod "https://api.github.com/repos/$NkRepo/releases/latest" -Headers @{ "User-Agent" = "NetKnife-install" } -UseBasicParsing
    $A = @($Rel.assets | Where-Object { $_.name -eq "NetKnife.zip" }) | Select-Object -First 1
    if (-not $A) { throw "в релизе $($Rel.tag_name) нет NetKnife.zip" }
    $Sha = ConvertFrom-NkDigest $A.digest
    if (-not $Sha) { throw "GitHub не отдал SHA256 для NetKnife.zip ($($Rel.tag_name)) — проверить архив нечем, установка остановлена" }
    return [pscustomobject]@{ Tag = "$($Rel.tag_name)"; Url = "$($A.browser_download_url)"; Sha256 = $Sha; Size = [long]$A.size }
}

function Save-NkPackage {
    param($Release, [string]$OutFile)
    $ProgressPreference = "SilentlyContinue"   # the 5.1 progress bar makes Invoke-WebRequest many times slower
    Write-NkLog ("Скачиваю NetKnife {0} ({1:N1} МБ)…" -f $Release.Tag, ($Release.Size / 1MB)) Cyan
    Invoke-WebRequest $Release.Url -OutFile $OutFile -UseBasicParsing -Headers @{ "User-Agent" = "NetKnife-install" }
    $Got = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash.ToLower()
    if ($Got -ne $Release.Sha256) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        throw "SHA256 NetKnife.zip не совпал с GitHub (ожидали $($Release.Sha256), получили $Got) — файл удалён, установка остановлена"
    }
}

# unpacked package folder (a zip with one top-level folder is fine too)
function Expand-NkPackage {
    param([string]$Zip, [string]$Dir)
    Unblock-NkFiles $Zip
    try { Expand-Archive -LiteralPath $Zip -DestinationPath $Dir -Force }
    catch { throw "архив NetKnife.zip не распаковался: $($_.Exception.Message)" }
    $New = $Dir
    if (-not (Test-Path -LiteralPath (Join-Path $New "NetKnife.ps1"))) {
        $Inner = Get-ChildItem -LiteralPath $Dir -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "NetKnife.ps1") } | Select-Object -First 1
        if ($Inner) { $New = $Inner.FullName }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $New "NetKnife.ps1")) -or -not (Get-NkVersion $New)) { throw "в архиве нет NetKnife.ps1 или VERSION" }
    return $New
}

function Unblock-NkFiles {
    param([string]$Target)
    if ($env:OS -ne "Windows_NT") { return }
    if (Test-Path -LiteralPath $Target -PathType Container) { Get-ChildItem -LiteralPath $Target -Recurse -File | Unblock-File -ErrorAction SilentlyContinue }
    else { Unblock-File -LiteralPath $Target -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- running app

# pwsh processes running <Path>\NetKnife.ps1 (process ids)
function Get-NkAppProcess {
    param([string]$Path)
    if ($env:OS -ne "Windows_NT") { return @() }
    $Script = Join-Path $Path "NetKnife.ps1"
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and "$($_.CommandLine)".IndexOf($Script, [StringComparison]::OrdinalIgnoreCase) -ge 0
    } | ForEach-Object { [int]$_.ProcessId })
}

# NetKnife listens for this event and quits the proper way (system proxy restored, tunnels and children stopped)
function Send-NkQuit {
    try {
        $H = $null
        if ([System.Threading.EventWaitHandle]::TryOpenExisting("Local\NetKnife.Quit", [ref]$H)) { [void]$H.Set(); $H.Dispose(); return $true }
    } catch { }
    return $false
}

function Wait-NkExit {
    param([int[]]$Ids, [int]$Seconds)
    for ($I = 0; $I -lt $Seconds * 4; $I++) {
        if (-not @($Ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Stop-NkApp {
    param([string]$Path, [int]$WaitPid, [switch]$Force)
    if ($WaitPid -and -not (Wait-NkExit @($WaitPid) 60)) { Stop-Process -Id $WaitPid -Force -ErrorAction SilentlyContinue }
    $Ids = @(Get-NkAppProcess $Path)
    if (-not $Ids) { return }
    if (-not $Force) {
        Write-NkLog "NetKnife запущен — закрываю его…" Cyan
        if ((Send-NkQuit) -and (Wait-NkExit $Ids 30)) { return }
        if (-not $script:NkQuiet) {
            for ($Try = 0; $Try -lt 2; $Try++) {
                [void](Read-Host "Закройте NetKnife (значок в трее → Выход) и нажмите Enter")
                if (Wait-NkExit $Ids 5) { return }
            }
            throw "NetKnife всё ещё запущен — закройте его и запустите команду снова"
        }
    }
    Stop-Process -Id $Ids -Force -ErrorAction SilentlyContinue
    [void](Wait-NkExit $Ids 10)
}

function Start-NkApp {
    param([string]$Path)
    Start-Process -FilePath (Join-Path $env:WINDIR "System32\wscript.exe") -ArgumentList ('"' + (Join-Path $Path "launch.vbs") + '"')
}

# NetKnife writes its VERSION to update\started.txt right before showing the window (releases before the installer
# do not — for them the start is not checked)
function Test-NkReportsStart {
    param([string]$Path)
    $F = Join-Path $Path "lib\Update.ps1"
    return ((Test-Path -LiteralPath $F) -and (Select-String -LiteralPath $F -SimpleMatch "Register-AppStarted" -Quiet))
}

function Wait-NkStarted {
    param([string]$Version, [int]$Seconds = $NkStartTimeout)
    $Marker = Join-Path (Get-NkUpdateDir) "started.txt"
    for ($I = 0; $I -lt $Seconds * 2; $I++) {
        if ((Test-Path -LiteralPath $Marker) -and "$(Get-Content -LiteralPath $Marker -TotalCount 1)".Trim().TrimStart([char]0xFEFF) -eq $Version) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# ---------------------------------------------------------------- files: backup → copy → rollback

function Copy-NkItem {
    param([string]$Item, [string]$Dest)
    Copy-Item -LiteralPath $Item -Destination $Dest -Recurse -Force
}

# Copies the package over $Path. Only what the package brings is backed up (the folder may be a git clone with more
# in it); names the old version did not have are listed in .added and removed on rollback.
function Update-NkFiles {
    param([string]$Source, [string]$Path, [string]$Backup, [string]$Version)
    if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }
    New-Item -ItemType Directory -Path $Backup -Force | Out-Null
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $Items = @(Get-ChildItem -LiteralPath $Source -Force)
    $Added = @()
    foreach ($I in $Items) {
        $D = Join-Path $Path $I.Name
        if (Test-Path -LiteralPath $D) { Copy-Item -LiteralPath $D -Destination $Backup -Recurse -Force } else { $Added += $I.Name }
    }
    [IO.File]::WriteAllLines((Join-Path $Backup ".added"), [string[]]$Added)
    try {
        foreach ($I in $Items) { Copy-NkItem $I.FullName $Path }
        $Got = Get-NkVersion $Path
        if ($Got -ne $Version) { throw "после копирования VERSION = '$Got', а не $Version" }
    } catch {
        $Err = $_.Exception.Message
        Restore-NkFiles -Path $Path -Backup $Backup
        throw "не удалось заменить файлы ($Err) — возвращены прежние"
    }
}

function Restore-NkFiles {
    param([string]$Path, [string]$Backup)
    $AddedFile = Join-Path $Backup ".added"
    if (Test-Path -LiteralPath $AddedFile) {
        foreach ($N in @(Get-Content -LiteralPath $AddedFile)) {
            if ("$N".Trim()) { Remove-Item -LiteralPath (Join-Path $Path "$N".Trim()) -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($I in @(Get-ChildItem -LiteralPath $Backup -Force | Where-Object { $_.Name -ne ".added" })) {
        Copy-Item -LiteralPath $I.FullName -Destination $Path -Recurse -Force
    }
    if (-not @(Get-ChildItem -LiteralPath $Path -Force)) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

# what the app shows on its next start (update\result.json, read once and deleted)
function Write-NkResult {
    param([bool]$Ok, [string]$Version, [string]$From, [string]$Err = "")
    try {
        @{ Ok = $Ok; Version = $Version; From = $From; Error = $Err; At = (Get-Date -Format s) } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path (Get-NkUpdateDir) "result.json") -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- shortcuts

function Get-NkShortcutPaths {
    @((Join-Path ([Environment]::GetFolderPath("Programs")) "NetKnife.lnk"), (Join-Path ([Environment]::GetFolderPath("Desktop")) "NetKnife.lnk"))
}

function Set-NkShortcuts {
    param([string]$Path)
    $Sh = New-Object -ComObject WScript.Shell
    foreach ($L in Get-NkShortcutPaths) {
        $S = $Sh.CreateShortcut($L)
        $S.TargetPath = Join-Path $env:WINDIR "System32\wscript.exe"
        $S.Arguments = '"' + (Join-Path $Path "launch.vbs") + '"'
        $S.WorkingDirectory = $Path
        $S.IconLocation = (Join-Path $Path "NetKnife.ico") + ",0"
        $S.Description = "NetKnife"
        $S.Save()
    }
}

# only shortcuts that point into this install
function Remove-NkShortcuts {
    param([string]$Path)
    $Sh = New-Object -ComObject WScript.Shell
    foreach ($L in Get-NkShortcutPaths) {
        if (-not (Test-Path -LiteralPath $L)) { continue }
        if ("$($Sh.CreateShortcut($L).Arguments)".IndexOf($Path, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Remove-Item -LiteralPath $L -Force }
    }
}

# ---------------------------------------------------------------- install / update / uninstall

function Install-NetKnife {
    param([string]$Path, [string]$Source, [int]$WaitPid, [switch]$Quiet, [switch]$NoShortcuts, [switch]$NoLaunch)
    $ErrorActionPreference = "Stop"
    $script:NkQuiet = [bool]$Quiet
    if (-not $Path) { $Path = Get-NkDefaultPath }
    $Path = [IO.Path]::GetFullPath($Path)
    $Upd = Get-NkUpdateDir
    New-Item -ItemType Directory -Path $Upd -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Upd "install.log") -Value "$(Get-Date -Format s) install.ps1 → $Path" -Encoding UTF8
    if ((Test-Path -LiteralPath $Path) -and @(Get-ChildItem -LiteralPath $Path -Force) -and -not (Test-Path -LiteralPath (Join-Path $Path "NetKnife.ps1"))) {
        throw "папка $Path не пустая и в ней нет NetKnife — укажите другую через -Path"
    }
    $Was = Get-NkVersion $Path
    $New = ""
    $Work = Join-Path ([IO.Path]::GetTempPath()) ("NetKnife-setup-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    try {
        if (-not $Source) {
            Assert-NkPwsh
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
            $Rel = Get-NkRelease
            New-Item -ItemType Directory -Path $Work -Force | Out-Null
            $Zip = Join-Path $Work "NetKnife.zip"
            Save-NkPackage -Release $Rel -OutFile $Zip
            $Source = Expand-NkPackage -Zip $Zip -Dir (Join-Path $Work "new")
        }
        $New = Get-NkVersion $Source
        if (-not $New) { throw "в $Source нет VERSION" }
        Write-NkLog $(if ($Was) { "Обновляю NetKnife $Was → $New в $Path" } else { "Ставлю NetKnife $New в $Path" }) Cyan

        Stop-NkApp -Path $Path -WaitPid $WaitPid
        $Backup = Join-Path $Upd "backup"
        Update-NkFiles -Source $Source -Path $Path -Backup $Backup -Version $New
        Unblock-NkFiles $Path
        if (-not $NoShortcuts) {
            try { Set-NkShortcuts $Path; Write-NkLog "Ярлыки «NetKnife» — в меню «Пуск» и на рабочем столе" }
            catch { Write-NkLog "Ярлыки не созданы: $($_.Exception.Message)" Yellow }
        }
        Write-NkResult $true $New $Was
        if (-not $NoLaunch) {
            Remove-Item -LiteralPath (Join-Path $Upd "started.txt") -Force -ErrorAction SilentlyContinue
            Write-NkLog "Запускаю…"
            Start-NkApp $Path
            if ((Test-NkReportsStart $Path) -and -not (Wait-NkStarted $New)) {
                Stop-NkApp -Path $Path -Force
                if (-not $Was) { throw "NetKnife $New не запустился за $NkStartTimeout с" }
                Restore-NkFiles -Path $Path -Backup $Backup
                $Msg = "NetKnife $New не запустился за $NkStartTimeout с — возвращена $Was"
                Write-NkResult $false $New $Was $Msg
                Start-NkApp $Path
                throw $Msg
            }
        }
        Write-NkLog "Готово: NetKnife $New в $Path. Обновления — кнопкой «Обновить» в программе или этой же командой." Green
    } catch {
        $Msg = $_.Exception.Message
        Write-NkLog "Ошибка: $Msg" Red
        if ($New -and $Msg -notmatch 'возвращена') { Write-NkResult $false $New $Was $Msg }
        throw
    } finally {
        Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-NetKnife {
    param([string]$Path, [switch]$RemoveData)
    $ErrorActionPreference = "Stop"
    $script:NkQuiet = $false
    if (-not $Path) { $Path = Get-NkDefaultPath }
    $Path = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath (Join-Path $Path ".git")) { throw "$Path — git-клон, удалите его вручную" }
    if (Test-Path -LiteralPath (Join-Path $Path "NetKnife.ps1")) {
        Stop-NkApp -Path $Path
        Remove-Item -LiteralPath $Path -Recurse -Force
        Write-NkLog "NetKnife удалён из $Path" Green
    } else {
        Write-NkLog "NetKnife в $Path не найден" Yellow
    }
    try { Remove-NkShortcuts $Path } catch { Write-NkLog "Ярлыки не удалены: $($_.Exception.Message)" Yellow }
    $Data = Get-NkDataDir
    if (-not (Test-Path -LiteralPath $Data)) { return }
    if ($RemoveData -and (Read-NkYes "Удалить и данные $Data (настройки, профили VPN, очередь обходов Wi-Fi)?")) {
        Remove-Item -LiteralPath $Data -Recurse -Force
        Write-NkLog "Данные удалены" Green
    } else {
        Write-NkLog "Настройки и данные остались в $Data"
    }
}

# tests dot-source the functions only
if ($env:NETKNIFE_INSTALL_LIB -ne "1") {
    try {
        if ($Uninstall) { Uninstall-NetKnife -Path $Path -RemoveData:$RemoveData }
        else { Install-NetKnife -Path $Path -Source $Source -WaitPid $WaitPid -Quiet:$Quiet -NoShortcuts:$NoShortcuts -NoLaunch:$NoLaunch }
    } catch {
        if (-not $Quiet) { Write-Host "NetKnife: $($_.Exception.Message)" -ForegroundColor Red }
    }
}
