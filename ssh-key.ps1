# Setup-SshAccess-Debug.ps1
# Windows -> Linux SSH access setup
#
# Main menu:
# 1. Setup SSH key by password
# 2. Generate SSH key, print public key, save SSH config, then test
# 3. Test last SSH connection
# 4. Install goodies on last SSH connection
#
# Key rule:
# - KeyName = Alias
# - Example: Alias "mihomo" -> C:\Users\<USER>\.ssh\mihomo
#
# Goodies:
# - micro
# - micro as default editor
# - zsh
# - oh-my-zsh
# - powerlevel10k
# - plugins:
#   git
#   docker
#   z
#   sudo
#   history-substring-search
#   zsh-autosuggestions
#   zsh-syntax-highlighting
# - alias please='sudo'
#
# Goodies installer has live remote logs.

#
# Non-interactive launch (used by SshKeys.ps1 GUI):
#   -Mode 1|2|3|4    skip main menu
#   -Goodies 1|2|3|4 skip goodies menu (mode 4)
#   -Port N          SSH port (default 22)
#   Mode 3/4 with -Alias use that alias instead of last saved profile.

param(
    [string]$HostName,
    [string]$UserName,
    [string]$Alias,
    [int]$Port = 22,
    [ValidateSet("", "1", "2", "3", "4")]
    [string]$Mode = "",
    [ValidateSet("", "1", "2", "3", "4")]
    [string]$Goodies = "",
    [switch]$ForceNewKey
)

$ErrorActionPreference = "Stop"

$PortGiven = $PSBoundParameters.ContainsKey("Port")

$Ctx = [ordered]@{
    HostName   = $HostName
    UserName   = $UserName
    Alias      = $Alias
    Port       = $Port
    KeyName    = $null
    SshDir     = Join-Path $env:USERPROFILE ".ssh"
    KeyPath    = $null
    PubKeyPath = $null
    ConfigPath = $null
    StatePath  = $null
    PublicKey  = $null
}

$Ctx.ConfigPath = Join-Path $Ctx.SshDir "config"
$Ctx.StatePath  = Join-Path $Ctx.SshDir "setup-ssh-access-last.json"

function Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Time = Get-Date -Format "HH:mm:ss"
    $Line = "[$Time] [$Level] $Message"

    switch ($Level) {
        "OK"    { Write-Host $Line -ForegroundColor Green }
        "WARN"  { Write-Host $Line -ForegroundColor Yellow }
        "ERROR" { Write-Host $Line -ForegroundColor Red }
        "STEP"  { Write-Host $Line -ForegroundColor Magenta }
        default { Write-Host $Line -ForegroundColor Cyan }
    }
}

function Wait-Exit {
    Write-Host ""
    Write-Host "Press any key to exit..."
    [void][System.Console]::ReadKey($true)
}

function Fail {
    param([string]$Message)
    Log $Message "ERROR"
    throw $Message
}

function Read-WithDefault {
    param(
        [string]$Prompt,
        [string]$DefaultValue
    )

    if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
        return (Read-Host $Prompt).Trim()
    }

    $Value = Read-Host "$Prompt [$DefaultValue]"

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $DefaultValue
    }

    return $Value.Trim()
}

function Ensure-Command {
    param([string]$Name)

    Log "Checking command: $Name" "STEP"

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "Command not found: $Name"
    }

    $Cmd = Get-Command $Name -ErrorAction Stop
    Log "Command found: $($Cmd.Source)" "OK"
}

function Ensure-SshDir {
    if (-not (Test-Path $Ctx.SshDir)) {
        Log "Creating SSH directory: $($Ctx.SshDir)" "STEP"
        New-Item -ItemType Directory -Path $Ctx.SshDir | Out-Null
        Log "SSH directory created" "OK"
    }
}

function Set-KeyNameFromAlias {
    if ([string]::IsNullOrWhiteSpace($Ctx.Alias)) {
        Fail "Alias is empty, cannot set key name"
    }

    $SafeKeyName = $Ctx.Alias.Trim()
    $SafeKeyName = $SafeKeyName -replace '[\\/:*?"<>| ]', '_'

    $Ctx.KeyName = $SafeKeyName
}

function Update-KeyPaths {
    Set-KeyNameFromAlias
    $Ctx.KeyPath = Join-Path $Ctx.SshDir $Ctx.KeyName
    $Ctx.PubKeyPath = "$($Ctx.KeyPath).pub"
}

function Save-State {
    Ensure-SshDir

    $State = [ordered]@{
        HostName = $Ctx.HostName
        UserName = $Ctx.UserName
        Alias    = $Ctx.Alias
        Port     = $Ctx.Port
        KeyName  = $Ctx.KeyName
    }

    $State | ConvertTo-Json | Set-Content -Path $Ctx.StatePath -Encoding UTF8

    Log "Saved last SSH profile: $($Ctx.StatePath)" "OK"
}

function Load-State {
    if (-not (Test-Path $Ctx.StatePath)) {
        return $false
    }

    $State = Get-Content $Ctx.StatePath -Raw | ConvertFrom-Json

    if (-not [string]::IsNullOrWhiteSpace($State.HostName)) {
        $Ctx.HostName = $State.HostName
    }

    if (-not [string]::IsNullOrWhiteSpace($State.UserName)) {
        $Ctx.UserName = $State.UserName
    }

    if (-not [string]::IsNullOrWhiteSpace($State.Alias)) {
        $Ctx.Alias = $State.Alias
    }

    if ($State.Port) {
        $Ctx.Port = [int]$State.Port
    }

    Set-KeyNameFromAlias
    Update-KeyPaths

    Log "Loaded last SSH profile: $($Ctx.StatePath)" "OK"
    Log "Alias: $($Ctx.Alias)" "OK"
    Log "HostName: $($Ctx.HostName)" "OK"
    Log "UserName: $($Ctx.UserName)" "OK"
    Log "KeyName: $($Ctx.KeyName)" "OK"

    return $true
}

function Read-ConnectionParamsOnce {
    if ([string]::IsNullOrWhiteSpace($Ctx.HostName)) {
        $Ctx.HostName = Read-WithDefault "Host / IP" ""
    }

    if ([string]::IsNullOrWhiteSpace($Ctx.UserName)) {
        $Ctx.UserName = Read-WithDefault "Username" "root"
    }

    if (-not $PortGiven) {
        $Ctx.Port = [int](Read-WithDefault "Port" "22")
    }

    if ([string]::IsNullOrWhiteSpace($Ctx.Alias)) {
        $AliasDefault = $Ctx.HostName.Replace(".", "-")
        $Ctx.Alias = Read-WithDefault "SSH alias" $AliasDefault
    }

    if ([string]::IsNullOrWhiteSpace($Ctx.HostName)) {
        Fail "HostName is empty"
    }

    if ([string]::IsNullOrWhiteSpace($Ctx.UserName)) {
        Fail "UserName is empty"
    }

    if ([string]::IsNullOrWhiteSpace($Ctx.Alias)) {
        Fail "Alias is empty"
    }

    Set-KeyNameFromAlias
    Update-KeyPaths

    Log "HostName: $($Ctx.HostName)" "OK"
    Log "UserName: $($Ctx.UserName)" "OK"
    Log "Port: $($Ctx.Port)" "OK"
    Log "Alias: $($Ctx.Alias)" "OK"
    Log "KeyName = Alias: $($Ctx.KeyName)" "OK"
}

function Ensure-PoshSSH {
    Log "Checking PowerShell module: Posh-SSH" "STEP"

    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        Log "Posh-SSH module not found" "WARN"

        $Install = Read-Host "Install Posh-SSH now? [Y/n]"

        if ($Install -eq "" -or $Install -match "^[Yy]$") {
            Log "Installing NuGet provider" "STEP"
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
            Log "NuGet provider ready" "OK"

            Log "Setting PSGallery as trusted" "STEP"
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
            Log "PSGallery trusted" "OK"

            Log "Installing Posh-SSH" "STEP"
            Install-Module Posh-SSH -Scope CurrentUser -Force -AllowClobber
            Log "Posh-SSH installed" "OK"
        } else {
            Fail "Posh-SSH is required"
        }
    } else {
        Log "Posh-SSH already installed" "OK"
    }

    Log "Importing Posh-SSH" "STEP"
    Import-Module Posh-SSH -ErrorAction Stop
    Log "Posh-SSH imported" "OK"
}

function Invoke-SshKeygenEd25519 {
    param(
        [string]$KeyPath,
        [string]$Comment
    )

    Log "Running ssh-keygen via cmd.exe" "STEP"

    $Cmd = 'ssh-keygen -t ed25519 -C "{0}" -f "{1}" -N ""' -f $Comment, $KeyPath

    Log "ssh-keygen command: $Cmd" "STEP"

    cmd.exe /c $Cmd

    $ExitCode = $LASTEXITCODE

    Log "ssh-keygen exit code: $ExitCode" "STEP"

    if ($ExitCode -ne 0) {
        Fail "ssh-keygen failed"
    }
}

function Ensure-LocalSshKey {
    Ensure-SshDir
    Update-KeyPaths

    Log "Private key path: $($Ctx.KeyPath)" "STEP"
    Log "Public key path: $($Ctx.PubKeyPath)" "STEP"

    if ($ForceNewKey -and (Test-Path $Ctx.KeyPath)) {
        Log "ForceNewKey enabled, removing private key" "WARN"
        Remove-Item $Ctx.KeyPath -Force

        if (Test-Path $Ctx.PubKeyPath) {
            Log "Removing public key" "WARN"
            Remove-Item $Ctx.PubKeyPath -Force
        }
    }

    if (-not (Test-Path $Ctx.KeyPath)) {
        Log "Creating SSH key" "STEP"

        $Comment = "$($Ctx.UserName)@$($Ctx.HostName)"
        Invoke-SshKeygenEd25519 -KeyPath $Ctx.KeyPath -Comment $Comment

        Log "SSH key created" "OK"
    } else {
        Log "SSH key already exists" "OK"
    }

    if (-not (Test-Path $Ctx.PubKeyPath)) {
        Fail "Public key not found: $($Ctx.PubKeyPath)"
    }

    $Ctx.PublicKey = (Get-Content $Ctx.PubKeyPath -Raw).Trim()

    if ([string]::IsNullOrWhiteSpace($Ctx.PublicKey)) {
        Fail "Public key is empty"
    }

    Log "Public key loaded, length: $($Ctx.PublicKey.Length)" "OK"
}

function Add-OrUpdateSshConfig {
    Ensure-SshDir
    Update-KeyPaths

    Log "Updating SSH config: $($Ctx.ConfigPath)" "STEP"

    if (-not (Test-Path $Ctx.ConfigPath)) {
        Log "Creating config file" "STEP"
        New-Item -ItemType File -Path $Ctx.ConfigPath -Force | Out-Null
    }

    $Config = Get-Content $Ctx.ConfigPath -Raw -ErrorAction SilentlyContinue

    if ($null -eq $Config) {
        $Config = ""
    }

    $IdentityFile = "~/.ssh/$($Ctx.KeyName)"

    $PortLine = ""
    if ($Ctx.Port -and $Ctx.Port -ne 22) {
        $PortLine = "    Port $($Ctx.Port)`n"
    }

    $Block = @"
Host $($Ctx.Alias)
    HostName $($Ctx.HostName)
    User $($Ctx.UserName)
$PortLine    IdentityFile $IdentityFile
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 15
    ServerAliveCountMax 3

"@

    $EscapedAlias = [regex]::Escape($Ctx.Alias)
    $Pattern = "(?ms)^Host\s+$EscapedAlias\s*\r?\n.*?(?=^Host\s+|^Match\s+|\z)"

    if ($Config -match $Pattern) {
        # Update only managed options; keep ProxyJump, LocalForward etc.
        Log "Updating existing Host block: $($Ctx.Alias)" "STEP"
        $Existing = $Matches[0]

        $Managed = [ordered]@{
            HostName     = $Ctx.HostName
            User         = $Ctx.UserName
            IdentityFile = $IdentityFile
        }

        if ($Ctx.Port -and ($Ctx.Port -ne 22 -or $Existing -match "(?mi)^\s*Port\b")) {
            $Managed.Port = $Ctx.Port
        }

        foreach ($Name in $Managed.Keys) {
            $Value = "$($Managed[$Name])"
            $OptRegex = [regex]::new("(?mi)^([ \t]*)$Name\b[ \t=].*$")

            if ($OptRegex.IsMatch($Existing)) {
                $Existing = $OptRegex.Replace($Existing, { param($M) "$($M.Groups[1].Value)$Name $Value" }, 1)
            } else {
                $HeadRegex = [regex]::new("^(Host[^\r\n]*\r?\n)")
                $Existing = $HeadRegex.Replace($Existing, { param($M) "$($M.Groups[1].Value)    $Name $Value`n" }, 1)
            }
        }

        $Index = $Config.IndexOf($Matches[0])
        $Config = $Config.Substring(0, $Index) + $Existing + $Config.Substring($Index + $Matches[0].Length)
        Set-Content -Path $Ctx.ConfigPath -Value $Config -Encoding UTF8 -NoNewline
    } else {
        Log "Adding new Host block: $($Ctx.Alias)" "STEP"
        Add-Content -Path $Ctx.ConfigPath -Value "`n$Block" -Encoding UTF8
    }

    Log "SSH config updated" "OK"
}

function Show-PublicKeyForManualCopy {
    Write-Host ""
    Write-Host "PUBLIC SSH KEY FOR MANUAL COPY:" -ForegroundColor Green
    Write-Host ""
    Write-Host $Ctx.PublicKey -ForegroundColor Yellow
    Write-Host ""

    try {
        Set-Clipboard -Value $Ctx.PublicKey
        Write-Host "(public key copied to clipboard)" -ForegroundColor Green
        Write-Host ""
    } catch {
    }
    Write-Host "Private key:" -ForegroundColor Cyan
    Write-Host $Ctx.KeyPath
    Write-Host ""
    Write-Host "Public key file:" -ForegroundColor Cyan
    Write-Host $Ctx.PubKeyPath
    Write-Host ""
    Write-Host "Manual install on Linux/OpenSSH:" -ForegroundColor Cyan
    Write-Host "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
    Write-Host "echo '$($Ctx.PublicKey)' >> ~/.ssh/authorized_keys"
    Write-Host "chmod 600 ~/.ssh/authorized_keys"
    Write-Host ""
    Write-Host "Manual install on OpenWrt/Dropbear:" -ForegroundColor Cyan
    Write-Host "mkdir -p /etc/dropbear"
    Write-Host "echo '$($Ctx.PublicKey)' >> /etc/dropbear/authorized_keys"
    Write-Host "chmod 600 /etc/dropbear/authorized_keys"
    Write-Host "/etc/init.d/dropbear reload"
    Write-Host ""
}

function Show-MainMenu {
    Write-Host ""
    Write-Host "Select mode:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Setup SSH key by password"
    Write-Host "2. Generate SSH key, print public key, save SSH config, then test"
    Write-Host "3. Test last SSH connection"
    Write-Host "4. Install goodies on last SSH connection"
    Write-Host ""

    $Choice = Read-Host "Select option [1-4]"

    if ([string]::IsNullOrWhiteSpace($Choice)) {
        return "1"
    }

    return $Choice.Trim()
}

function Show-GoodiesMenu {
    Write-Host ""
    Write-Host "Select goodies to install:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Install micro"
    Write-Host "2. Install micro + set default editor"
    Write-Host "3. Install zsh + oh-my-zsh + powerlevel10k + plugins"
    Write-Host "4. Install micro default + zsh + oh-my-zsh + powerlevel10k + plugins"
    Write-Host ""

    $Choice = Read-Host "Select option [1-4]"

    if ([string]::IsNullOrWhiteSpace($Choice)) {
        return "1"
    }

    return $Choice.Trim()
}

function Test-SshConnection {
    if ([string]::IsNullOrWhiteSpace($Ctx.Alias)) {
        Fail "Alias is empty. Create profile first with option 1 or 2."
    }

    Log "Testing SSH alias: $($Ctx.Alias)" "STEP"

    $TestOutput = & ssh `
        -o BatchMode=yes `
        -o ConnectTimeout=10 `
        "$($Ctx.Alias)" `
        "echo SSH_TEST_OK; echo USER:; whoami; echo HOSTNAME:; hostname 2>/dev/null || uname -n" 2>&1

    $TestExitCode = $LASTEXITCODE

    Log "SSH test exit code: $TestExitCode" "STEP"

    if ($TestOutput.Count -gt 0) {
        Log "SSH test output:" "STEP"
        foreach ($Line in $TestOutput) {
            Write-Host "    $Line"
        }
    } else {
        Log "SSH test output is empty" "WARN"
    }

    if ($TestExitCode -eq 0 -and ($TestOutput -join "`n") -match "SSH_TEST_OK") {
        Log "SSH connection works" "OK"
        Write-Host ""
        Write-Host "SSH TEST OK" -ForegroundColor Green
        Write-Host "Connect:"
        Write-Host "ssh $($Ctx.Alias)" -ForegroundColor Yellow
        return $true
    }

    Log "SSH test failed. Running verbose SSH debug." "WARN"

    $VerboseOutput = & ssh `
        -vvv `
        -o BatchMode=yes `
        -o ConnectTimeout=10 `
        -o StrictHostKeyChecking=accept-new `
        "$($Ctx.Alias)" `
        "echo SSH_TEST_OK" 2>&1

    Log "SSH verbose debug output:" "WARN"
    foreach ($Line in $VerboseOutput) {
        Write-Host "    $Line" -ForegroundColor Yellow
    }

    return $false
}

function Install-PublicKeyRemote {
    $PublicKeyB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Ctx.PublicKey))
    Log "Public key base64 length: $($PublicKeyB64.Length)" "STEP"

    Log "Opening SSH session to $($Ctx.UserName)@$($Ctx.HostName)" "STEP"

    $Password = Read-Host "Password for $($Ctx.UserName)@$($Ctx.HostName)" -AsSecureString

    if ($null -eq $Password) {
        Fail "Password is empty"
    }

    $Credential = New-Object System.Management.Automation.PSCredential($Ctx.UserName, $Password)
    Log "Password received" "OK"

    $Session = New-SSHSession `
        -ComputerName $Ctx.HostName `
        -Port $Ctx.Port `
        -Credential $Credential `
        -AcceptKey `
        -ConnectionTimeout 15 `
        -ErrorAction Stop

    Log "SSH session opened" "OK"

    try {
        $SessionId = $Session.SessionId
        Log "SessionId: $SessionId" "STEP"

        $RemoteScript = @'
KEY_B64="__KEY_B64__"

echo SSH_REMOTE_START

echo USER:
whoami

echo SHELL:
echo "$SHELL"

echo HOME:
echo "$HOME"

if command -v base64 >/dev/null 2>&1; then
    KEY=$(printf '%s' "$KEY_B64" | base64 -d 2>/dev/null)
else
    echo BASE64_NOT_FOUND
    exit 11
fi

if [ -z "$KEY" ]; then
    echo KEY_DECODE_FAILED
    exit 12
fi

echo SSH_SERVER_CHECK:

if command -v dropbear >/dev/null 2>&1; then
    echo DROPBEAR_FOUND
else
    echo DROPBEAR_NOT_FOUND
fi

if [ -d /etc/dropbear ]; then
    echo ETC_DROPBEAR_EXISTS
else
    echo ETC_DROPBEAR_NOT_EXISTS
fi

echo INSTALL_OPENSSH_AUTHORIZED_KEYS:

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

if grep -qxF "$KEY" "$HOME/.ssh/authorized_keys"; then
    echo OPENSSH_KEY_ALREADY_EXISTS
else
    printf '%s\n' "$KEY" >> "$HOME/.ssh/authorized_keys"
    echo OPENSSH_KEY_ADDED
fi

chmod 600 "$HOME/.ssh/authorized_keys"

if grep -qxF "$KEY" "$HOME/.ssh/authorized_keys"; then
    echo OPENSSH_KEY_OK
else
    echo OPENSSH_KEY_FAIL
    exit 13
fi

if [ -d /etc/dropbear ]; then
    echo INSTALL_DROPBEAR_AUTHORIZED_KEYS:

    touch /etc/dropbear/authorized_keys
    chmod 600 /etc/dropbear/authorized_keys

    if grep -qxF "$KEY" /etc/dropbear/authorized_keys; then
        echo DROPBEAR_KEY_ALREADY_EXISTS
    else
        printf '%s\n' "$KEY" >> /etc/dropbear/authorized_keys
        echo DROPBEAR_KEY_ADDED
    fi

    chmod 600 /etc/dropbear/authorized_keys

    if grep -qxF "$KEY" /etc/dropbear/authorized_keys; then
        echo DROPBEAR_KEY_OK
    else
        echo DROPBEAR_KEY_FAIL
        exit 14
    fi

    if [ -x /etc/init.d/dropbear ]; then
        echo RESTART_DROPBEAR:
        /etc/init.d/dropbear reload >/dev/null 2>&1 || /etc/init.d/dropbear restart >/dev/null 2>&1 || true
        echo DROPBEAR_RELOAD_DONE
    fi
fi

echo SSH_REMOTE_SETUP_OK
'@

        $RemoteScript = $RemoteScript.Replace("__KEY_B64__", $PublicKeyB64)
        $RemoteScript = $RemoteScript -replace "`r`n", "`n"
        $RemoteScript = $RemoteScript -replace "`r", "`n"

        $RemoteScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($RemoteScript))
        $RemoteCommand = "printf '%s' '$RemoteScriptB64' | base64 -d | sh"

        Log "Running remote SSH key setup through base64 -> sh" "STEP"

        $Result = Invoke-SSHCommand `
            -SessionId $SessionId `
            -Command $RemoteCommand `
            -TimeOut 60 `
            -ErrorAction Stop

        Log "Remote command exit status: $($Result.ExitStatus)" "STEP"

        if ($Result.Output.Count -gt 0) {
            Log "Remote output:" "STEP"
            foreach ($Line in $Result.Output) {
                Write-Host "    $Line"
            }
        }

        if ($Result.Error.Count -gt 0) {
            Log "Remote stderr:" "WARN"
            foreach ($Line in $Result.Error) {
                Write-Host "    $Line" -ForegroundColor Yellow
            }
        }

        if ($Result.ExitStatus -ne 0) {
            Fail "Remote command failed"
        }

        $RemoteText = $Result.Output -join "`n"

        if ($RemoteText -notmatch "SSH_REMOTE_SETUP_OK") {
            Fail "Remote setup marker not found"
        }

        Log "Public key installed on remote host" "OK"
    }
    finally {
        if ($Session) {
            Log "Closing SSH session" "STEP"
            Remove-SSHSession -SessionId $Session.SessionId | Out-Null
            Log "SSH session closed" "OK"
        }
    }
}

function Invoke-RemoteGoodiesSetup {
    param(
        [string]$GoodiesChoice
    )

    if ([string]::IsNullOrWhiteSpace($Ctx.Alias)) {
        Fail "Alias is empty. Create or load SSH profile first."
    }

    $InstallMicro = "0"
    $SetMicroDefault = "0"
    $InstallZshStack = "0"

    switch ($GoodiesChoice) {
        "1" {
            $InstallMicro = "1"
            Log "Goodies: install micro" "STEP"
        }
        "2" {
            $InstallMicro = "1"
            $SetMicroDefault = "1"
            Log "Goodies: install micro + default editor" "STEP"
        }
        "3" {
            $InstallZshStack = "1"
            Log "Goodies: install zsh stack" "STEP"
        }
        "4" {
            $InstallMicro = "1"
            $SetMicroDefault = "1"
            $InstallZshStack = "1"
            Log "Goodies: install micro default + zsh stack" "STEP"
        }
        default {
            Fail "Unknown goodies option: $GoodiesChoice"
        }
    }

    $RemoteOptionalScript = @'
INSTALL_MICRO="__INSTALL_MICRO__"
SET_MICRO_DEFAULT="__SET_MICRO_DEFAULT__"
INSTALL_ZSH_STACK="__INSTALL_ZSH_STACK__"

log() {
    printf '\n[REMOTE] %s\n' "$1"
}

fail() {
    printf '\n[REMOTE ERROR] %s\n' "$1"
    exit "$2"
}

append_line_once() {
    FILE="$1"
    LINE="$2"

    touch "$FILE"

    if grep -qxF "$LINE" "$FILE" 2>/dev/null; then
        log "Already exists in $FILE: $LINE"
    else
        printf '%s\n' "$LINE" >> "$FILE"
        log "Added to $FILE: $LINE"
    fi
}

replace_or_append_zsh_var() {
    FILE="$1"
    NAME="$2"
    VALUE="$3"

    touch "$FILE"

    if grep -q "^$NAME=" "$FILE" 2>/dev/null; then
        sed -i "s|^$NAME=.*|$NAME=\"$VALUE\"|g" "$FILE"
        log "Updated $NAME in $FILE"
    else
        printf '%s="%s"\n' "$NAME" "$VALUE" >> "$FILE"
        log "Added $NAME to $FILE"
    fi
}

write_omz_plugins_block() {
    FILE="$1"

    touch "$FILE"

    TMP_FILE="${FILE}.tmp.$$"

    awk '
        BEGIN { skip=0 }
        /^plugins=\(/ { skip=1; next }
        skip==1 && /^\)/ { skip=0; next }
        skip==0 { print }
    ' "$FILE" > "$TMP_FILE" 2>/dev/null || cp "$FILE" "$TMP_FILE"

    cat "$TMP_FILE" > "$FILE"
    rm -f "$TMP_FILE"

    cat >> "$FILE" <<'PLUGINS_EOF'

plugins=(
  git
  docker
  z
  sudo
  history-substring-search
  zsh-autosuggestions
  zsh-syntax-highlighting
)
PLUGINS_EOF

    log "Updated plugins block in $FILE"
}

ensure_zshrc_sources_omz() {
    FILE="$1"

    touch "$FILE"

    if grep -q 'source $ZSH/oh-my-zsh.sh' "$FILE" 2>/dev/null; then
        log "oh-my-zsh source already exists in $FILE"
    else
        cat >> "$FILE" <<'SOURCE_EOF'

if [ -f "$ZSH/oh-my-zsh.sh" ]; then
  source "$ZSH/oh-my-zsh.sh"
fi
SOURCE_EOF
        log "Added oh-my-zsh source block to $FILE"
    fi
}

ensure_please_alias() {
    FILE="$1"

    touch "$FILE"

    if grep -qxF "alias please='sudo'" "$FILE" 2>/dev/null; then
        log "Alias please already exists"
    else
        printf "%s\n" "alias please='sudo'" >> "$FILE"
        log "Added alias please='sudo'"
    fi
}

log "OPTIONAL_SETUP_START"

log "User:"
whoami

log "Home:"
echo "$HOME"

log "Shell:"
echo "$SHELL"

if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" != "0" ]; then
    SUDO="sudo"
else
    SUDO=""
fi

if [ -z "$SUDO" ]; then
    log "sudo not required"
else
    log "sudo required"

    if ! sudo -n true >/dev/null 2>&1; then
        fail "sudo password is required but non-interactive sudo is not available. Run script as root or configure passwordless sudo." 91
    fi
fi

run_apt_update() {
    log "APT update started"

    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update
    elif command -v apt >/dev/null 2>&1; then
        $SUDO apt update
    else
        fail "apt/apt-get not found" 40
    fi

    log "APT update finished"
}

install_packages() {
    PACKAGES="$1"

    log "Installing packages: $PACKAGES"

    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y $PACKAGES
    elif command -v apt >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive $SUDO apt install -y $PACKAGES
    else
        fail "apt/apt-get not found" 41
    fi

    log "Packages installed: $PACKAGES"
}

if [ "$INSTALL_MICRO" = "1" ]; then
    log "MICRO install started"

    if command -v micro >/dev/null 2>&1; then
        log "micro already installed"
        micro -version 2>/dev/null || true
    else
        run_apt_update
        install_packages "micro"
    fi

    if command -v micro >/dev/null 2>&1; then
        log "MICRO_INSTALL_OK"
        micro -version 2>/dev/null || true
    else
        fail "micro install failed" 50
    fi
fi

if [ "$SET_MICRO_DEFAULT" = "1" ]; then
    log "Set micro as default editor started"

    append_line_once "$HOME/.profile" 'export EDITOR=micro'
    append_line_once "$HOME/.profile" 'export VISUAL=micro'

    append_line_once "$HOME/.bashrc" 'export EDITOR=micro'
    append_line_once "$HOME/.bashrc" 'export VISUAL=micro'

    append_line_once "$HOME/.zshrc" 'export EDITOR=micro'
    append_line_once "$HOME/.zshrc" 'export VISUAL=micro'

    log "MICRO_DEFAULT_EDITOR_OK"
fi

if [ "$INSTALL_ZSH_STACK" = "1" ]; then
    log "ZSH stack install started"

    run_apt_update
    install_packages "zsh curl git"

    ZSH_PATH="$(command -v zsh)"

    if [ -z "$ZSH_PATH" ]; then
        fail "zsh not found after install" 60
    fi

    log "zsh path: $ZSH_PATH"

    CURRENT_USER="$(whoami)"

    log "Set zsh as default shell for user: $CURRENT_USER"

    if command -v chsh >/dev/null 2>&1; then
        if [ "$(id -u)" = "0" ]; then
            chsh -s "$ZSH_PATH" "$CURRENT_USER" 2>/dev/null || true
        else
            $SUDO chsh -s "$ZSH_PATH" "$CURRENT_USER" 2>/dev/null || true
        fi
        log "chsh command executed"
    else
        log "chsh not found, skipping default shell change"
    fi

    log "oh-my-zsh install started"

    export RUNZSH=no
    export CHSH=no
    export KEEP_ZSHRC=yes

    if [ -d "$HOME/.oh-my-zsh" ]; then
        log "oh-my-zsh already installed"
    else
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi

    if [ -d "$HOME/.oh-my-zsh" ]; then
        log "OH_MY_ZSH_OK"
    else
        fail "oh-my-zsh install failed" 61
    fi

    ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    log "powerlevel10k install started"

    if [ -d "$ZSH_CUSTOM/themes/powerlevel10k" ]; then
        log "powerlevel10k already installed"
    else
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$ZSH_CUSTOM/themes/powerlevel10k"
    fi

    if [ -d "$ZSH_CUSTOM/themes/powerlevel10k" ]; then
        log "POWERLEVEL10K_OK"
    else
        fail "powerlevel10k install failed" 62
    fi

    log "zsh plugins install started"

    if [ -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
        log "zsh-autosuggestions already installed"
    else
        git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
    fi

    if [ -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
        log "zsh-syntax-highlighting already installed"
    else
        git clone https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
    fi

    if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
        fail "zsh-autosuggestions install failed" 63
    fi

    if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
        fail "zsh-syntax-highlighting install failed" 64
    fi

    log "Configure ~/.zshrc started"

    ZSHRC="$HOME/.zshrc"

    touch "$ZSHRC"

    replace_or_append_zsh_var "$ZSHRC" "export ZSH" "$HOME/.oh-my-zsh"
    replace_or_append_zsh_var "$ZSHRC" "ZSH_THEME" "powerlevel10k/powerlevel10k"

    write_omz_plugins_block "$ZSHRC"

    append_line_once "$ZSHRC" 'export EDITOR=micro'
    append_line_once "$ZSHRC" 'export VISUAL=micro'

    ensure_please_alias "$ZSHRC"
    ensure_zshrc_sources_omz "$ZSHRC"

    log "Validate zsh config started"

    if zsh -ic 'echo ZSH_CONFIG_LOAD_OK' 2>/tmp/zsh_config_test.err; then
        log "ZSH_CONFIG_LOAD_OK"
    else
        log "ZSH config validation stderr:"
        cat /tmp/zsh_config_test.err 2>/dev/null || true
        fail "zsh config validation failed" 65
    fi

    log "Final source ~/.zshrc check started"

    if zsh -ic 'source ~/.zshrc >/dev/null 2>&1; echo SOURCE_ZSHRC_OK' 2>/tmp/zsh_source_test.err; then
        log "SOURCE_ZSHRC_OK"
    else
        log "source ~/.zshrc stderr:"
        cat /tmp/zsh_source_test.err 2>/dev/null || true
        fail "source ~/.zshrc check failed" 66
    fi

    log "ZSH_STACK_OK"
fi

log "OPTIONAL_SETUP_OK"
'@

    $RemoteOptionalScript = $RemoteOptionalScript.Replace("__INSTALL_MICRO__", $InstallMicro)
    $RemoteOptionalScript = $RemoteOptionalScript.Replace("__SET_MICRO_DEFAULT__", $SetMicroDefault)
    $RemoteOptionalScript = $RemoteOptionalScript.Replace("__INSTALL_ZSH_STACK__", $InstallZshStack)

    $RemoteOptionalScript = $RemoteOptionalScript -replace "`r`n", "`n"
    $RemoteOptionalScript = $RemoteOptionalScript -replace "`r", "`n"

    $RemoteOptionalScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($RemoteOptionalScript))
    $RemoteOptionalCommand = "printf '%s' '$RemoteOptionalScriptB64' | base64 -d | sh"

    Log "Running goodies setup on alias: $($Ctx.Alias)" "STEP"
    Log "Remote script prepared, starting SSH stream..." "STEP"
    Log "If it stops on apt/sudo, check remote sudo permissions." "WARN"

    Write-Host ""
    Write-Host "===== REMOTE LIVE LOG START =====" -ForegroundColor Cyan
    Write-Host ""

    & ssh `
        -tt `
        -o ConnectTimeout=10 `
        -o ServerAliveInterval=15 `
        -o ServerAliveCountMax=3 `
        "$($Ctx.Alias)" `
        "$RemoteOptionalCommand"

    $ExitCode = $LASTEXITCODE

    Write-Host ""
    Write-Host "===== REMOTE LIVE LOG END =====" -ForegroundColor Cyan
    Write-Host ""

    Log "Goodies setup exit code: $ExitCode" "STEP"

    if ($ExitCode -ne 0) {
        Fail "Goodies setup failed"
    }

    Log "Goodies setup completed" "OK"
}

try {
    Clear-Host

    Log "=== Windows -> Linux SSH access setup started ===" "STEP"
    Log "PowerShell version: $($PSVersionTable.PSVersion)" "STEP"
    Log "User profile: $env:USERPROFILE" "STEP"

    Ensure-Command "ssh"
    Ensure-Command "ssh-keygen"

    if ($Mode) {
        $MenuChoice = $Mode
    } else {
        $MenuChoice = Show-MainMenu
    }
    Log "Selected menu option: $MenuChoice" "OK"

    # Mode 3/4 with explicit alias: use it, not last saved profile
    function Use-ProfileForExistingHost {
        if (-not [string]::IsNullOrWhiteSpace($Ctx.Alias)) {
            Update-KeyPaths
            Log "Using alias from parameters: $($Ctx.Alias)" "OK"
            return $true
        }
        return (Load-State)
    }

    if ($MenuChoice -eq "1") {
        Ensure-PoshSSH

        Read-ConnectionParamsOnce
        Ensure-LocalSshKey
        Install-PublicKeyRemote
        Add-OrUpdateSshConfig
        Save-State

        $Ok = Test-SshConnection

        if (-not $Ok) {
            Fail "SSH connection test failed"
        }

        Write-Host ""
        Write-Host "DONE" -ForegroundColor Green
        Write-Host "Connect:"
        Write-Host "ssh $($Ctx.Alias)" -ForegroundColor Yellow

        Wait-Exit
        exit 0
    }

    if ($MenuChoice -eq "2") {
        Log "Manual public key generation + SSH config + test mode selected" "STEP"

        Read-ConnectionParamsOnce
        Ensure-LocalSshKey
        Add-OrUpdateSshConfig
        Save-State
        Show-PublicKeyForManualCopy

        Write-Host ""
        Write-Host "SSH config entry saved:" -ForegroundColor Green
        Write-Host $Ctx.ConfigPath
        Write-Host ""
        Write-Host "After manually copying the public key to the remote machine, press Enter to test:" -ForegroundColor Cyan
        Write-Host "ssh $($Ctx.Alias)" -ForegroundColor Yellow
        Read-Host "Press Enter after manual key copy"

        $Ok = Test-SshConnection

        if (-not $Ok) {
            Fail "SSH connection test failed"
        }

        Wait-Exit
        exit 0
    }

    if ($MenuChoice -eq "3") {
        if (-not (Use-ProfileForExistingHost)) {
            Fail "No saved SSH profile found. Use option 1 or 2 first."
        }

        $Ok = Test-SshConnection

        if (-not $Ok) {
            Fail "SSH connection test failed"
        }

        Wait-Exit
        exit 0
    }

    if ($MenuChoice -eq "4") {
        if (-not (Use-ProfileForExistingHost)) {
            Fail "No saved SSH profile found. Use option 1 or 2 first."
        }

        $Ok = Test-SshConnection

        if (-not $Ok) {
            Fail "SSH connection test failed. Goodies install aborted."
        }

        if ($Goodies) {
            $GoodiesChoice = $Goodies
        } else {
            $GoodiesChoice = Show-GoodiesMenu
        }
        Invoke-RemoteGoodiesSetup -GoodiesChoice $GoodiesChoice

        Write-Host ""
        Write-Host "GOODIES DONE" -ForegroundColor Green
        Write-Host "Reconnect:"
        Write-Host "ssh $($Ctx.Alias)" -ForegroundColor Yellow

        Wait-Exit
        exit 0
    }

    Fail "Unknown menu option: $MenuChoice"
}
catch {
    Log "FAILED: $($_.Exception.Message)" "ERROR"

    Write-Host ""
    Write-Host "ERROR" -ForegroundColor Red
    Write-Host $_.Exception.Message

    Wait-Exit
    exit 1
}