# Full backup of everything NetKnife keeps, as one password-encrypted file (*.nkbak), by default into the
# Yandex Disk folder (the desktop client uploads it; NetKnife needs no Yandex account or token).
#
# Inside (a zip): appdata/… — %APPDATA%\NetKnife except downloadable engines/logs; ssh/… — the whole ~/.ssh (keys,
# config, config.d, known_hosts); local/helpdesk-hosts.json; secrets.json — every DPAPI-protected value of
# settings.json plus the Helpdesk token, decrypted, so a restore works on another laptop / Windows user (DPAPI blobs
# do not); manifest.json.
# File: "NKBAK1" + iterations (int32 LE) + salt(16) + nonce(12) + tag(16) + AES-256-GCM(zip); key = PBKDF2-SHA256.
# The password is never stored: lost password = unreadable backup.

$script:BkMagic = [Text.Encoding]::ASCII.GetBytes("NKBAK1")
$script:BkIterations = 600000
$script:BkSkipData = @("conemu", "sing-box", "mihomo", "vpn", "update", "whisper")   # downloadable engines, caches
$script:BkSkipFile = '\.(pid|log|tmp)$|\.bak'

# ---------------------------------------------------------------- where

# Yandex Disk desktop client keeps its sync root in the registry
function Get-YandexDiskRoot {
    foreach ($K in @("HKCU:\Software\Yandex\Yandex.Disk.4", "HKCU:\Software\Yandex\Yandex.Disk.3", "HKCU:\Software\Yandex\Yandex.Disk.2")) {
        try { $P = (Get-ItemProperty $K -ErrorAction Stop).CurrentUserSyncPath; if ($P -and (Test-Path -LiteralPath $P)) { return $P } } catch { }
    }
    foreach ($P in @("$env:USERPROFILE\YandexDisk", "$env:USERPROFILE\Яндекс.Диск")) { if (Test-Path -LiteralPath $P) { return $P } }
    return ""
}

function Get-BackupDir {
    if ($script:Settings.BackupDir) { return "$($script:Settings.BackupDir)" }
    $Y = Get-YandexDiskRoot
    if ($Y) { return Join-Path $Y "NetKnife Backup" }
    return Join-Path ([Environment]::GetFolderPath("MyDocuments")) "NetKnife Backup"
}

# ---------------------------------------------------------------- secrets (DPAPI → plain inside the encrypted file)

# DPAPI flavours used by NetKnife: "ss" = ConvertFrom-SecureString (collector tokens), "pd" = ProtectedData base64 (MikroTik)
function Unprotect-BkValue {
    param([string]$V)
    try { return @{ S = "ss"; V = [System.Net.NetworkCredential]::new("", (ConvertTo-SecureString $V -ErrorAction Stop)).Password } } catch { }
    try { return @{ S = "pd"; V = [Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($V), $null, "CurrentUser")) } } catch { }
    return $null
}
function Protect-BkValue {
    param([string]$Scheme, [string]$V)
    if ($Scheme -eq "pd") { return [Convert]::ToBase64String([System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($V), $null, "CurrentUser")) }
    return (ConvertTo-SecureString $V -AsPlainText -Force | ConvertFrom-SecureString)
}

# every non-empty string under a key ending in "Enc" → @{ Path = @(keys/indexes); Scheme; Value }
function Get-BkSecrets {
    param($Node, [object[]]$Path = @())
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($K in @($Node.Keys)) {
            $V = $Node[$K]
            if ("$K" -like "*Enc" -and $V -is [string] -and $V) {
                $U = Unprotect-BkValue $V
                if ($U) { @{ Path = @($Path + "$K"); Scheme = $U.S; Value = $U.V } }
            } else { Get-BkSecrets $V @($Path + "$K") }
        }
    } elseif ($Node -is [System.Collections.IList] -and $Node -isnot [string]) {
        for ($i = 0; $i -lt $Node.Count; $i++) { Get-BkSecrets $Node[$i] @($Path + $i) }
    }
}

function Set-BkSecret {
    param($Root, [object[]]$Path, $Value)
    $N = $Root
    for ($i = 0; $i -lt $Path.Count - 1; $i++) {
        $K = $Path[$i]
        # plain assignments: $(if …) would unroll a one-element array into its element
        if ($N -is [System.Collections.IList]) { $N = $N[[int]$K] } else { $N = $N[$K] }
        if ($null -eq $N) { return $false }
    }
    $Last = $Path[-1]
    if ($N -is [System.Collections.IDictionary]) { $N[$Last] = $Value; return $true }
    return $false
}

# ---------------------------------------------------------------- plan: which files go in

function Get-BackupPlan {
    $Files = [System.Collections.Generic.List[object]]::new()
    $Add = {
        param([string]$Root, [string]$Prefix, [string[]]$SkipDirs)
        if (-not (Test-Path -LiteralPath $Root)) { return }
        foreach ($F in Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue) {
            $Rel = $F.FullName.Substring($Root.TrimEnd('\').Length + 1)
            $Top = ($Rel -split '[\\/]')[0]
            if ($SkipDirs -contains $Top -or $F.Name -match $script:BkSkipFile) { continue }
            $Files.Add([pscustomobject]@{ Src = $F.FullName; Entry = "$Prefix/" + $Rel.Replace('\', '/'); Size = $F.Length })
        }
    }
    & $Add $script:DataDir "appdata" $script:BkSkipData
    & $Add $script:SshDir "ssh" @()
    $Hd = Join-Path $env:LOCALAPPDATA "NetKnife\helpdesk-hosts.json"
    if (Test-Path -LiteralPath $Hd) { $Files.Add([pscustomobject]@{ Src = $Hd; Entry = "local/helpdesk-hosts.json"; Size = (Get-Item -LiteralPath $Hd).Length }) }

    $Sec = @(Get-BkSecrets $script:Settings)
    $Token = $(if (Get-Command Get-HdToken -ErrorAction SilentlyContinue) { Get-HdToken } else { $null })
    $Secrets = @{ settings = @($Sec | ForEach-Object { @{ path = $_.Path; scheme = $_.Scheme; value = $_.Value } }); helpdeskToken = $(if ($Token) { $Token } else { "" }) }
    $Manifest = @{
        format = "netknife-backup/1"; created = [DateTime]::Now.ToString("o"); app = "$script:AppVersion"
        computer = $env:COMPUTERNAME; user = $env:USERNAME; files = $Files.Count; bytes = [long](($Files | Measure-Object Size -Sum).Sum)
        parts = @{ appdata = @($Files | Where-Object { $_.Entry -like "appdata/*" }).Count; ssh = @($Files | Where-Object { $_.Entry -like "ssh/*" }).Count; secrets = $Sec.Count + [int][bool]$Token }
    }
    return @{ Files = $Files.ToArray(); SecretsJson = ($Secrets | ConvertTo-Json -Depth 8); ManifestJson = ($Manifest | ConvertTo-Json -Depth 4); Manifest = $Manifest }
}

# ---------------------------------------------------------------- crypto (used by the worker too — keep self-contained)

$script:BkCrypto = {
    function Protect-BkBytes {
        param([byte[]]$Data, [string]$Password, [int]$Iter = 600000)
        $Salt = [byte[]]::new(16); $Nonce = [byte[]]::new(12); $Tag = [byte[]]::new(16)
        [Security.Cryptography.RandomNumberGenerator]::Fill($Salt); [Security.Cryptography.RandomNumberGenerator]::Fill($Nonce)
        $Key = [Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2([Text.Encoding]::UTF8.GetBytes($Password), $Salt, $Iter, [Security.Cryptography.HashAlgorithmName]::SHA256, 32)
        $Ct = [byte[]]::new($Data.Length)
        $G = [Security.Cryptography.AesGcm]::new($Key, 16)
        try { $G.Encrypt($Nonce, $Data, $Ct, $Tag) } finally { $G.Dispose(); [Array]::Clear($Key, 0, $Key.Length) }
        $Ms = [IO.MemoryStream]::new()
        $Ms.Write([Text.Encoding]::ASCII.GetBytes("NKBAK1"), 0, 6); $Ms.Write([BitConverter]::GetBytes([int]$Iter), 0, 4)
        $Ms.Write($Salt, 0, 16); $Ms.Write($Nonce, 0, 12); $Ms.Write($Tag, 0, 16); $Ms.Write($Ct, 0, $Ct.Length)
        return $Ms.ToArray()
    }
    function Unprotect-BkBytes {
        param([byte[]]$Blob, [string]$Password)
        if ($Blob.Length -lt 54 -or [Text.Encoding]::ASCII.GetString($Blob, 0, 6) -ne "NKBAK1") { throw "это не бэкап NetKnife" }
        $Iter = [BitConverter]::ToInt32($Blob, 6)
        if ($Iter -lt 10000 -or $Iter -gt 10000000) { throw "повреждённый заголовок" }
        $Salt = $Blob[10..25]; $Nonce = $Blob[26..37]; $Tag = $Blob[38..53]
        $Ct = [byte[]]::new($Blob.Length - 54); [Array]::Copy($Blob, 54, $Ct, 0, $Ct.Length)
        $Key = [Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2([Text.Encoding]::UTF8.GetBytes($Password), [byte[]]$Salt, $Iter, [Security.Cryptography.HashAlgorithmName]::SHA256, 32)
        $Pt = [byte[]]::new($Ct.Length)
        $G = [Security.Cryptography.AesGcm]::new($Key, 16)
        try { $G.Decrypt([byte[]]$Nonce, $Ct, [byte[]]$Tag, $Pt) } catch { throw "неверный пароль или файл повреждён" } finally { $G.Dispose(); [Array]::Clear($Key, 0, $Key.Length) }
        return $Pt
    }
}
. $script:BkCrypto

# zip + encrypt + write (tmp → rename). Runs in a thread job: only .NET and the crypto block above.
$script:BkMakeBody = {
    param($Q, $Ctl, $Files, $SecretsJson, $ManifestJson, $Password, $Out, $CryptoText, $Iter)
    . ([scriptblock]::Create($CryptoText))
    Add-Type -AssemblyName System.IO.Compression
    $Ms = [IO.MemoryStream]::new()
    $Zip = [IO.Compression.ZipArchive]::new($Ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    $Skipped = @()
    $N = 0
    foreach ($F in $Files) {
        if ($Ctl.Stop) { $Zip.Dispose(); return }
        try {
            $E = $Zip.CreateEntry($F.Entry, [IO.Compression.CompressionLevel]::Optimal)
            $W = $E.Open()
            try { $R = [IO.File]::Open($F.Src, "Open", "Read", "ReadWrite"); try { $R.CopyTo($W) } finally { $R.Dispose() } } finally { $W.Dispose() }
        } catch { $Skipped += "$($F.Entry): $($_.Exception.Message)" }
        $N++
        if ($N % 50 -eq 0) { $Q.Enqueue(@{ Type = "bk"; Stage = "zip"; Done = $N; Total = $Files.Count }) }
    }
    foreach ($P in @(@("secrets.json", $SecretsJson), @("manifest.json", $ManifestJson))) {
        $E = $Zip.CreateEntry($P[0]); $W = [IO.StreamWriter]::new($E.Open(), [Text.UTF8Encoding]::new($false)); $W.Write($P[1]); $W.Dispose()
    }
    $Zip.Dispose()
    $Q.Enqueue(@{ Type = "bk"; Stage = "crypt" })
    $Blob = Protect-BkBytes $Ms.ToArray() $Password $Iter
    $Dir = Split-Path $Out -Parent
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $Tmp = "$Out.part"
    [IO.File]::WriteAllBytes($Tmp, $Blob)
    [IO.File]::Move($Tmp, $Out, $true)
    $Q.Enqueue(@{ Type = "bk"; Stage = "done"; Out = $Out; Bytes = $Blob.Length; Skipped = $Skipped })
}

# ---------------------------------------------------------------- restore

# decrypted zip → @{ Manifest; Secrets; Entries = @(name, size) ; Zip bytes }
function Read-BackupFile {
    param([string]$Path, [string]$Password)
    $Pt = Unprotect-BkBytes ([IO.File]::ReadAllBytes($Path)) $Password
    Add-Type -AssemblyName System.IO.Compression
    $Zip = [IO.Compression.ZipArchive]::new([IO.MemoryStream]::new($Pt), [IO.Compression.ZipArchiveMode]::Read)
    $Read = { param($Name) $E = $Zip.GetEntry($Name); if (-not $E) { return $null }; $R = [IO.StreamReader]::new($E.Open()); try { $R.ReadToEnd() } finally { $R.Dispose() } }
    $M = & $Read "manifest.json"
    if (-not $M) { $Zip.Dispose(); throw "в файле нет manifest.json" }
    $Out = @{ Manifest = ($M | ConvertFrom-Json -AsHashtable); Secrets = ((& $Read "secrets.json") | ConvertFrom-Json -AsHashtable); Zip = $Zip }
    if ($Out.Manifest.format -ne "netknife-backup/1") { $Zip.Dispose(); throw "неизвестный формат $($Out.Manifest.format)" }
    return $Out
}

# zip entry name → target path; anything outside the three roots (or with "..") is refused
function Resolve-BkTarget {
    param([string]$Entry)
    if ($Entry -match '(^|/)\.\.(/|$)' -or $Entry -match '^[/\\]' -or $Entry -match ':') { return $null }
    $P = $Entry -split '/', 2
    if ($P.Count -lt 2 -or -not $P[1]) { return $null }
    if ($P[0] -eq "local" -and $P[1] -ne "helpdesk-hosts.json") { return $null }   # %LOCALAPPDATA%\NetKnife is the app itself
    $Root = switch ($P[0]) { "appdata" { $script:DataDir } "ssh" { $script:SshDir } "local" { Join-Path $env:LOCALAPPDATA "NetKnife" } default { $null } }
    if (-not $Root) { return $null }
    $T = [IO.Path]::GetFullPath((Join-Path $Root $P[1].Replace('/', '\')))
    if (-not $T.StartsWith([IO.Path]::GetFullPath($Root).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $T
}

# Files are added/overwritten (nothing is deleted); what gets overwritten is first copied to
# %APPDATA%\NetKnife-before-restore-<time>\ (same three roots). Returns @{ Written; SafetyDir; Secrets }.
function Invoke-BackupRestore {
    param($B)
    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $Safety = Join-Path (Split-Path $script:DataDir -Parent) "NetKnife-before-restore-$Stamp"
    $Written = 0; $Refused = @()
    foreach ($E in @($B.Zip.Entries)) {
        if ($E.FullName -in @("manifest.json", "secrets.json") -or $E.FullName.EndsWith("/")) { continue }
        $T = Resolve-BkTarget $E.FullName
        if (-not $T) { $Refused += $E.FullName; continue }
        if (Test-Path -LiteralPath $T) {
            $S = Join-Path $Safety ($E.FullName.Replace('/', '\'))
            New-Item -ItemType Directory -Path (Split-Path $S -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $T -Destination $S -Force
        }
        New-Item -ItemType Directory -Path (Split-Path $T -Parent) -Force | Out-Null
        $In = $E.Open(); try { $Fs = [IO.File]::Create($T); try { $In.CopyTo($Fs) } finally { $Fs.Dispose() } } finally { $In.Dispose() }
        $Written++
    }
    $B.Zip.Dispose()

    # settings.json from the backup → secrets protected again for THIS Windows user
    $script:Settings = Get-Settings
    $Sec = 0
    foreach ($S in @($B.Secrets.settings)) {
        if ($S -and $S.path -and (Set-BkSecret $script:Settings @($S.path) (Protect-BkValue "$($S.scheme)" "$($S.value)"))) { $Sec++ }
    }
    Save-Settings
    if ($B.Secrets.helpdeskToken -and (Get-Command Set-HdToken -ErrorAction SilentlyContinue)) { try { Set-HdToken "$($B.Secrets.helpdeskToken)"; $Sec++ } catch { } }
    return @{ Written = $Written; SafetyDir = $(if (Test-Path -LiteralPath $Safety) { $Safety } else { "" }); Secrets = $Sec; Refused = $Refused }
}

# ---------------------------------------------------------------- UI

function Show-BackupPasswordDialog {
    param([string]$Title, [string]$Text, [switch]$Confirm)
    $Esc = { param($S) [System.Security.SecurityElement]::Escape($S) }
    $Second = $(if ($Confirm) { '<TextBlock Text="ЕЩЁ РАЗ" Style="{StaticResource Caption}" Margin="2,12,0,6"/><Border Background="{StaticResource Card}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Height="36"><PasswordBox x:Name="FPass2" Background="Transparent" BorderThickness="0" Foreground="{StaticResource Text}" CaretBrush="{StaticResource Text}" Padding="10,0" VerticalContentAlignment="Center"/></Border>' } else { "" })
    $D = New-Dialog $Title -Width 500 @"
<StackPanel>
    <TextBlock Text="$(& $Esc $Title)" FontFamily="{StaticResource DisplayFont}" FontSize="18" FontWeight="SemiBold"/>
    <TextBlock Text="$(& $Esc $Text)" TextWrapping="Wrap" Foreground="{StaticResource Sub}" Margin="0,8,0,14"/>
    <TextBlock Text="ПАРОЛЬ БЭКАПА" Style="{StaticResource Caption}"/>
    <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Height="36">
        <PasswordBox x:Name="FPass" Background="Transparent" BorderThickness="0" Foreground="{StaticResource Text}" CaretBrush="{StaticResource Text}" Padding="10,0" VerticalContentAlignment="Center"/>
    </Border>
    $Second
    <TextBlock x:Name="FError" Foreground="{StaticResource Fail}" FontSize="12" Margin="2,6,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="Дальше" MinWidth="110" Margin="8,0,0,0" IsDefault="True"/>
    </StackPanel>
</StackPanel>
"@
    $F = @{ P1 = $D.FindName("FPass"); P2 = $D.FindName("FPass2"); Err = $D.FindName("FError"); Confirm = [bool]$Confirm }
    $D.Tag = $F
    $D.FindName("FOk").Add_Click({
        $F = $D.Tag
        $E = $(if ($F.P1.Password.Length -lt 8) { "Не короче 8 символов" } elseif ($F.Confirm -and $F.P1.Password -cne $F.P2.Password) { "Пароли не совпадают" } else { "" })
        if ($E) { $F.Err.Text = $E; $F.Err.Visibility = "Visible"; return }
        $D.DialogResult = $true
    })
    $D.Add_ContentRendered({ [void]$D.Tag.P1.Focus() })
    if (-not $D.ShowDialog()) { return $null }
    return $F.P1.Password
}

function Update-BackupInfo {
    if (-not $Ui.SetBkDir) { return }
    $Dir = Get-BackupDir
    $Ui.SetBkDir.Text = $Dir
    $Last = $(if (Test-Path -LiteralPath $Dir) { Get-ChildItem -LiteralPath $Dir -Filter "NetKnife-*.nkbak" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 })
    $Y = Get-YandexDiskRoot
    $Ui.SetBkStatus.Text = $(if ($Last) { "последний: $($Last.Name) · {0:N1} МБ · {1:dd.MM.yyyy HH:mm}" -f ($Last.Length / 1MB), $Last.LastWriteTime } else { "бэкапов в этой папке пока нет" }) +
        $(if ($Y -and $Dir.StartsWith($Y, [StringComparison]::OrdinalIgnoreCase)) { " · папка Яндекс Диска — клиент загрузит файл в облако" } elseif ($Y) { " · это не папка Яндекс Диска ($Y)" } else { " · клиент Яндекс Диска не найден" })
}

function Start-AppBackup {
    if (Test-WorkerRunning "backup") { Show-Toast "Бэкап уже идёт" "info"; return }
    $Plan = Get-BackupPlan
    $M = $Plan.Manifest
    $Pw = Show-BackupPasswordDialog "Бэкап NetKnife" ("В файл войдут: настройки и данные NetKnife ({0} файлов), вся папка ~/.ssh — приватные ключи, config, known_hosts ({1} файлов), токены и пароли из настроек ({2}). Файл шифруется этим паролем (AES-256). Пароль нигде не сохраняется: без него бэкап не открыть." -f $M.parts.appdata, $M.parts.ssh, $M.parts.secrets) -Confirm
    if (-not $Pw) { return }
    $Out = Join-Path (Get-BackupDir) ("NetKnife-{0}-{1:yyyyMMdd-HHmm}.nkbak" -f $env:COMPUTERNAME, (Get-Date))
    $Ui.SetBkStatus.Text = "собираю {0} файлов ({1:N0} МБ)…" -f $M.files, ($M.bytes / 1MB)
    $Ui.SetBkMake.IsEnabled = $false
    [void](Start-Worker -Name "backup" -Body $script:BkMakeBody -ArgList @(@(, $Plan.Files) + @($Plan.SecretsJson, $Plan.ManifestJson, $Pw, $Out, $script:BkCrypto.ToString(), $script:BkIterations)) -OnMessage {
        param($M)
        if ($M.Type -ne "bk") { return }
        switch ($M.Stage) {
            "zip" { $Ui.SetBkStatus.Text = "упаковываю: $($M.Done) из $($M.Total)…" }
            "crypt" { $Ui.SetBkStatus.Text = "шифрую…" }
            "done" {
                Update-BackupInfo
                Show-Toast ("Бэкап готов: {0} · {1:N1} МБ{2}" -f (Split-Path $M.Out -Leaf), ($M.Bytes / 1MB), $(if ($M.Skipped.Count) { " · пропущено файлов: $($M.Skipped.Count)" })) $(if ($M.Skipped.Count) { "warn" } else { "info" })
                if ($M.Skipped.Count) { Write-AppLog "backup skipped: $($M.Skipped -join '; ')" }
            }
        }
    } -OnDone { $Ui.SetBkMake.IsEnabled = $true; if ($Ui.SetBkStatus.Text -like "*…") { Update-BackupInfo } })
}

function Start-AppRestore {
    $D = New-Object Microsoft.Win32.OpenFileDialog
    $D.Title = "Бэкап NetKnife"; $D.Filter = "Бэкап NetKnife (*.nkbak)|*.nkbak"
    $Dir = Get-BackupDir; if (Test-Path -LiteralPath $Dir) { $D.InitialDirectory = $Dir }
    if (-not $D.ShowDialog($script:Win)) { return }
    $Path = $D.FileName
    $Pw = Show-BackupPasswordDialog "Восстановить из бэкапа" "$(Split-Path $Path -Leaf) — введи пароль, с которым он создавался."
    if (-not $Pw) { return }
    [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait   # PBKDF2 + decrypt: a few seconds
    try { $B = Read-BackupFile $Path $Pw } catch { Show-Toast "Не открыл: $($_.Exception.Message)" "fail"; return } finally { [System.Windows.Input.Mouse]::OverrideCursor = $null }
    $M = $B.Manifest
    $Detail = "Создан: $($M.created) на $($M.computer) ($($M.user)), NetKnife $($M.app)`nДанные NetKnife: $($M.parts.appdata) файлов`n~/.ssh: $($M.parts.ssh) файлов`nСекреты: $($M.parts.secrets)"
    if (-not (Show-Confirm "Восстановить?" "Файлы из бэкапа добавятся и заменят одноимённые: настройки NetKnife, данные обходов, ~/.ssh (ключи, config, known_hosts). Ничего не удаляется; всё, что будет заменено, сначала копируется в %APPDATA%\NetKnife-before-restore-<время>. Потом NetKnife перезапустится." "Восстановить" -Danger -Detail $Detail)) { $B.Zip.Dispose(); return }
    [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
    try { $R = Invoke-BackupRestore $B } catch { Show-Toast "Восстановление прервано: $($_.Exception.Message)" "fail"; Write-AppLog "restore: $_"; return } finally { [System.Windows.Input.Mouse]::OverrideCursor = $null }
    Write-AppLog "restore: $($R.Written) files, $($R.Secrets) secrets, safety $($R.SafetyDir), refused $($R.Refused.Count)"
    [void](Show-Confirm "Восстановлено" ("Файлов: {0}, секретов: {1}{2}{3}. NetKnife перезапустится." -f $R.Written, $R.Secrets, $(if ($R.SafetyDir) { ". Прежние версии заменённых файлов: $($R.SafetyDir)" }), $(if ($R.Refused.Count) { ". Отклонено записей с недопустимым путём: $($R.Refused.Count)" })) "Перезапустить")
    Restart-App
}

function Initialize-BackupSettings {
    if (-not $Ui.SetBkMake) { return }
    Update-BackupInfo
    $Ui.SetBkMake.Add_Click({ Start-AppBackup })
    $Ui.SetBkRestore.Add_Click({ Start-AppRestore })
    $Ui.SetBkOpen.Add_Click({ $Dir = Get-BackupDir; if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }; Start-Process explorer.exe -ArgumentList (Quote-Arg $Dir) })
    $Ui.SetBkPick.Add_Click({
        try {
            $D = New-Object Microsoft.Win32.OpenFolderDialog
            $D.Title = "Папка для бэкапов NetKnife"
            $Cur = Get-BackupDir; if (Test-Path -LiteralPath $Cur) { $D.InitialDirectory = $Cur } elseif (Get-YandexDiskRoot) { $D.InitialDirectory = Get-YandexDiskRoot }
            if (-not $D.ShowDialog($script:Win)) { return }
            $script:Settings.BackupDir = $D.FolderName; Save-Settings; Update-BackupInfo
        } catch { Show-Toast "Выбор папки не открылся: $($_.Exception.Message)" "fail" }
    })
}
