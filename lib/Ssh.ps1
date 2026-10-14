# SSH data: ~/.ssh/config hosts, key files, engine (ssh-key.ps1) launch. Dot-sourced.

$script:SshDir     = Join-Path $env:USERPROFILE ".ssh"
$script:ConfigPath = Join-Path $script:SshDir "config"
# engine script ships inside the app folder; one level up (D:\SCRIPTS\ssh-key.ps1) is the legacy location
$script:Engine     = Join-Path $script:AppDir "ssh-key.ps1"
if (-not (Test-Path $script:Engine)) { $script:Engine = Join-Path (Split-Path $script:AppDir -Parent) "ssh-key.ps1" }
$script:Pwsh       = (Get-Process -Id $PID).Path
$script:Wt         = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source

function Resolve-SshPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $Path = $Path.Trim('"')
    if ($Path.StartsWith("~")) { $Path = Join-Path $env:USERPROFILE $Path.Substring(1).TrimStart("/", "\") }
    return [System.IO.Path]::GetFullPath($Path.Replace("/", "\"))
}

function Get-SshHosts {
    $Result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path $script:ConfigPath)) { return $Result }

    $Current = @()
    foreach ($Raw in Get-Content $script:ConfigPath) {
        $Line = $Raw.Trim()
        if ($Line -eq "" -or $Line.StartsWith("#")) { continue }
        if ($Line -notmatch '^([A-Za-z]+)\s*[=\s]\s*(.*)$') { continue }

        $Key = $Matches[1].ToLower()
        $Value = $Matches[2].Trim()

        if ($Key -eq "host" -or $Key -eq "match") {
            $Current = @()
            if ($Key -eq "host") {
                $Names = $Value -split '\s+'
                foreach ($Name in $Names) {
                    if ($Name -match '[*?!]') { continue }
                    $Item = [pscustomobject]@{
                        Alias = $Name; HostName = $Name; User = ""; Port = "22"
                        IdentityFile = ""; ProxyJump = ""; Shared = ($Names.Count -gt 1)
                    }
                    $Result.Add($Item)
                    $Current += $Item
                }
            }
            continue
        }

        foreach ($Item in $Current) {
            switch ($Key) {
                "hostname"     { $Item.HostName = $Value }
                "user"         { $Item.User = $Value }
                "port"         { $Item.Port = $Value }
                "identityfile" { if (-not $Item.IdentityFile) { $Item.IdentityFile = Resolve-SshPath $Value } }
                "proxyjump"    { $Item.ProxyJump = $Value }
            }
        }
    }
    return $Result
}

function Get-PubInfo {
    param([string]$PubPath)

    $Info = [pscustomobject]@{ Type = ""; Comment = ""; Fingerprint = ""; Text = "" }
    if (-not (Test-Path $PubPath)) { return $Info }

    $Text = (Get-Content $PubPath -Raw).Trim()
    $Parts = $Text -split '\s+', 3
    $Info.Text = $Text
    $Info.Type = ($Parts[0] -replace '^ssh-', '' -replace '^ecdsa-sha2-', 'ecdsa-')
    if ($Parts.Count -ge 3) { $Info.Comment = $Parts[2] }

    try {
        $Blob = [Convert]::FromBase64String($Parts[1])
        $Hash = [System.Security.Cryptography.SHA256]::HashData($Blob)
        $Info.Fingerprint = "SHA256:" + [Convert]::ToBase64String($Hash).TrimEnd("=")

        if ($Parts[0] -eq "ssh-rsa") {
            $Pos = 0; $Fields = @()
            for ($i = 0; $i -lt 3; $i++) {
                $Len = [int]$Blob[$Pos] * 16777216 + [int]$Blob[$Pos + 1] * 65536 + [int]$Blob[$Pos + 2] * 256 + [int]$Blob[$Pos + 3]
                $Fields += $Len
                $Pos += 4 + $Len
            }
            $Bits = ($Fields[2] - 1) * 8
            if ($Bits -gt 0) { $Info.Type = "rsa $Bits" }
        }
    } catch { }

    return $Info
}

function New-KeyItem {
    param([string]$Path, $Hosts)

    $PubPath = "$Path.pub"
    $Info = Get-PubInfo $PubPath
    $IsDefault = [System.IO.Path]::GetFileName($Path) -match '^id_(ed25519|rsa|ecdsa)$'
    $UsedBy = @($Hosts | Where-Object { ($_.IdentityFile -and $_.IdentityFile -ieq $Path) -or ($IsDefault -and -not $_.IdentityFile) } | ForEach-Object Alias)

    $Problems = @()
    if (-not (Test-Path $Path))    { $Problems += "нет приватного" }
    if (-not (Test-Path $PubPath)) { $Problems += "нет .pub" }

    return [pscustomobject]@{
        Name = [System.IO.Path]::GetFileName($Path); Type = $Info.Type; Comment = $Info.Comment
        Fingerprint = $Info.Fingerprint; UsedBy = $UsedBy; Problems = $Problems
        Path = $Path; PubPath = $PubPath; PubText = $Info.Text
    }
}

function Get-SshKeys {
    param($Hosts)

    $Result = [System.Collections.Generic.List[object]]::new()
    $Seen = @{}
    if (-not (Test-Path $script:SshDir)) { return $Result }

    foreach ($File in Get-ChildItem $script:SshDir -File) {
        if ($File.Extension -eq ".pub" -or $File.Length -gt 20000) { continue }
        $First = Get-Content $File.FullName -TotalCount 1 -ErrorAction SilentlyContinue
        if ($First -notmatch '^-----BEGIN .*PRIVATE KEY-----') { continue }
        $Seen[$File.FullName.ToLower()] = $true
        $Result.Add((New-KeyItem -Path $File.FullName -Hosts $Hosts))
    }
    foreach ($File in Get-ChildItem $script:SshDir -File -Filter "*.pub") {
        $Private = $File.FullName.Substring(0, $File.FullName.Length - 4)
        if ($Seen.ContainsKey($Private.ToLower())) { continue }
        $Result.Add((New-KeyItem -Path $Private -Hosts $Hosts))
    }
    return $Result
}

function Get-ConfigBlock {
    param([string]$Alias)
    if (-not (Test-Path $script:ConfigPath)) { return $null }
    $Config = Get-Content $script:ConfigPath -Raw
    $M = [regex]::Match($Config, "(?ms)^Host\s+$([regex]::Escape($Alias))\s*\r?\n.*?(?=^Host\s+|^Match\s+|\z)")
    if ($M.Success) { return $M.Value.TrimEnd() }
    return $null
}

function Find-KeyForHost {
    param($HostItem)
    $Path = $HostItem.IdentityFile
    if (-not $Path) { $Path = Join-Path $script:SshDir "id_ed25519" }
    $Found = $script:Keys | Where-Object { $_.Path -ieq $Path } | Select-Object -First 1
    if ($Found) { return $Found }
    return (New-KeyItem -Path $Path -Hosts @())
}

function Get-InstallCommand {
    param([string]$PubText, [string]$Flavor = "openssh")
    if (-not $PubText) { return "" }
    if ($Flavor -eq "dropbear") {
        return "mkdir -p /etc/dropbear && grep -qxF '$PubText' /etc/dropbear/authorized_keys 2>/dev/null || echo '$PubText' >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys"
    }
    return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && (grep -qxF '$PubText' ~/.ssh/authorized_keys 2>/dev/null || echo '$PubText' >> ~/.ssh/authorized_keys) && chmod 600 ~/.ssh/authorized_keys"
}

function Get-CopyIdCommand {
    param($HostItem, $KeyItem)
    if (-not $KeyItem -or -not (Test-Path $KeyItem.PubPath)) { return "" }
    $Target = $HostItem.HostName
    if ($HostItem.User) { $Target = "$($HostItem.User)@$Target" }
    $PortArg = ""
    if ($HostItem.Port -and $HostItem.Port -ne "22") { $PortArg = " -p $($HostItem.Port)" }
    return "Get-Content `"$($KeyItem.PubPath)`" | ssh$PortArg $Target `"mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys`""
}

# ---------------------------------------------------------------- processes

function Start-Engine {
    param([string[]]$EngineArgs, [string]$Title)

    if (-not (Test-Path $script:Engine)) {
        Show-Toast "Не найден ssh-key.ps1: $($script:Engine)" "fail"
        return
    }
    $ArgLine = "-NoProfile -ExecutionPolicy Bypass -File $(Quote-Arg $script:Engine) " + (($EngineArgs | ForEach-Object { Quote-Arg $_ }) -join " ")
    $Proc = Start-Process -FilePath $script:Pwsh -ArgumentList $ArgLine -PassThru
    $script:EngineProcs.Add($Proc)
    Show-Toast "Открыто окно: $Title" "info"
}

function Start-Terminal {
    param([string]$Command, [string]$Title)

    if ($script:Wt) {
        $A = "-w 0 new-tab"
        if ($Title) { $A += " --title $(Quote-Arg $Title)" }
        if ($Command) { $A += " $Command" }
        Start-Process -FilePath $script:Wt -ArgumentList $A
    } elseif ($Command) {
        Start-Process -FilePath "cmd.exe" -ArgumentList "/k $Command"
    } else {
        Start-Process -FilePath $script:Pwsh
    }
}

function Connect-Host {
    param([string]$Alias)
    Start-Terminal "ssh $(Quote-Arg $Alias)" $Alias
    Show-Toast "ssh $Alias" "info"
}

# Runs a PowerShell script in a new terminal tab and keeps the tab open so the output stays visible.
# Base64 avoids the quoting mess between wt, cmd and pwsh.
function Start-TerminalPwsh {
    param([string]$Script, [string]$Title)
    $Enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    Start-Terminal "$(Quote-Arg $script:Pwsh) -NoProfile -NoExit -EncodedCommand $Enc" $Title
}

function ConvertTo-PsLiteral {
    param([string]$Text)
    return "'" + $Text.Replace("'", "''") + "'"
}

function Backup-Config {
    $Backup = "$($script:ConfigPath).bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $script:ConfigPath $Backup
    return $Backup
}

# ---------------------------------------------------------------- config editing

function Get-IdentityFileValue {
    param([string]$Path)
    if (-not $Path) { return "" }
    $Full = Resolve-SshPath $Path
    if ($Full.StartsWith($script:SshDir, [StringComparison]::OrdinalIgnoreCase)) {
        return "~/.ssh/" + $Full.Substring($script:SshDir.Length).TrimStart("\").Replace("\", "/")
    }
    return $Full.Replace("\", "/")
}

# Rewrites the given options inside one Host block; other lines (LocalForward, IdentitiesOnly…) stay as they are.
# Empty value removes the option. Returns backup path.
function Set-HostConfigOptions {
    param([string]$Alias, [hashtable]$Values)

    $Config = Get-Content $script:ConfigPath -Raw
    $Pattern = "(?ms)^Host\s+$([regex]::Escape($Alias))\s*\r?\n.*?(?=^Host\s+|^Match\s+|\z)"
    $M = [regex]::Match($Config, $Pattern)
    if (-not $M.Success) { throw "Блок Host $Alias не найден в config" }

    $Block = $M.Value
    $Nl = if ($Block -match "`r`n") { "`r`n" } else { "`n" }
    $Indent = if ($Block -match "(?m)^([ \t]+)\S") { $Matches[1] } else { "    " }

    foreach ($Name in $Values.Keys) {
        $Value = "$($Values[$Name])".Trim()
        $Line = [regex]::new("(?mi)^[ \t]*$Name[ \t=]+[^\r\n]*(\r?\n|\z)")
        if ($Value -eq "") { $Block = $Line.Replace($Block, "", 1); continue }
        $New = "$Indent$Name $Value"
        if ($Line.IsMatch($Block)) {
            $Block = $Line.Replace($Block, { param($Mm) $New + $Mm.Groups[1].Value }, 1)
        } else {
            $Block = [regex]::new("^(Host[^\r\n]*\r?\n)").Replace($Block, { param($Mm) $Mm.Groups[1].Value + $New + $Nl }, 1)
        }
    }

    $Backup = Backup-Config
    $Config = $Config.Substring(0, $M.Index) + $Block + $Config.Substring($M.Index + $M.Length)
    Set-Content -Path $script:ConfigPath -Value $Config -Encoding UTF8 -NoNewline
    return $Backup
}

# ---------------------------------------------------------------- known_hosts

function Get-KnownHostNames {
    param($HostItem)
    if ($HostItem.Port -and $HostItem.Port -ne "22") { return @("[$($HostItem.HostName)]:$($HostItem.Port)") }
    return @($HostItem.HostName)
}

function Get-KnownHostFingerprints {
    param($HostItem)
    $Out = foreach ($N in Get-KnownHostNames $HostItem) {
        $R = & ssh-keygen.exe -l -F $N 2>&1
        foreach ($L in @($R)) { if ("$L" -match '^\S+\s+(\S+)\s+(SHA256:\S+)') { "$($Matches[1])  $($Matches[2])" } }
    }
    return @($Out | Select-Object -Unique)
}

function Remove-KnownHostEntries {
    param($HostItem, [string[]]$Extra = @())
    $Removed = 0
    foreach ($N in @(@(Get-KnownHostNames $HostItem) + $Extra | Where-Object { $_ } | Select-Object -Unique)) {
        $R = & ssh-keygen.exe -R $N 2>&1
        if ("$R" -match 'updated') { $Removed++ }
    }
    return $Removed
}
