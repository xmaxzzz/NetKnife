# Local speech-to-text for the voice-annotated Wi-Fi walk: whisper.cpp (whisper-cli.exe) + ggml model in
# %APPDATA%\NetKnife\whisper. Installed on first use after the user confirms (pinned release + SHA-256 of both
# downloads); audio never leaves the laptop. Output: words with offsets (ms) → phrases.

$script:WhisperDir = Join-Path $script:DataDir "whisper"
$script:WhisperZip = @{ Url = "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-bin-x64.zip"; Sha = "49DCC16DE826F20BD53D44F947A1AE49DFA81F86CAD67A64D80820CB192D674A"; Mb = 8 }
$script:WhisperModels = @{
    small = @{ File = "ggml-small.bin"; Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"; Sha = "1BE3A9B2063867B937E64E2EC7483364A79917E157FA98C5D94B5C1FFFEA987B"; Mb = 466 }
    base  = @{ File = "ggml-base.bin";  Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin";  Sha = "60ED5BC3DD14EEA856493D334349B405782DDCAF0028D4B5DF4088345FBA2EFE"; Mb = 141 }
}

function Get-WhisperModel { $M = "$($script:Settings.WhisperModel)"; if (-not $script:WhisperModels.ContainsKey($M)) { $M = "small" }; return $M }
function Get-WhisperExe { return Join-Path $script:WhisperDir "whisper-cli.exe" }
function Get-WhisperModelPath { return Join-Path $script:WhisperDir $script:WhisperModels[(Get-WhisperModel)].File }
function Test-WhisperReady { return ((Test-Path (Get-WhisperExe)) -and (Test-Path (Get-WhisperModelPath))) }

# download → verify → place; one worker, messages: wdl (progress), wdone (Ok/Error)
$script:WhisperInstallBody = {
    param($Q, $Ctl, $Dir, $Items)
    $Get = {
        param($Url, $Dest, $Sha, $Label)
        for ($Try = 1; $Try -le 5; $Try++) {
            if ($Ctl.Stop) { return "отменено" }
            try {
                $H = [System.Net.Http.HttpClient]::new(); $H.Timeout = [TimeSpan]::FromMinutes(30)
                $R = $H.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
                if (-not $R.IsSuccessStatusCode) { throw "HTTP $([int]$R.StatusCode)" }
                $Len = $R.Content.Headers.ContentLength
                $In = $R.Content.ReadAsStreamAsync().Result
                $Tmp = "$Dest.part"
                $Out = [IO.File]::Create($Tmp)
                $Buf = [byte[]]::new(1MB); $Done = 0L; $Last = [DateTime]::Now
                while (($N = $In.Read($Buf, 0, $Buf.Length)) -gt 0) {
                    if ($Ctl.Stop) { $Out.Dispose(); $In.Dispose(); Remove-Item $Tmp -ErrorAction SilentlyContinue; return "отменено" }
                    $Out.Write($Buf, 0, $N); $Done += $N
                    if (([DateTime]::Now - $Last).TotalMilliseconds -gt 400) { $Last = [DateTime]::Now; $Q.Enqueue(@{ Type = "wdl"; Label = $Label; Done = $Done; Total = $Len }) }
                }
                $Out.Dispose(); $In.Dispose(); $H.Dispose()
                $Got = (Get-FileHash $Tmp -Algorithm SHA256).Hash
                if ($Got -ne $Sha) { Remove-Item $Tmp -ErrorAction SilentlyContinue; throw "контрольная сумма не совпала" }
                Move-Item $Tmp $Dest -Force
                return ""
            } catch {
                $E = $_.Exception; while ($E.InnerException) { $E = $E.InnerException }
                $Q.Enqueue(@{ Type = "wdl"; Label = "$Label — попытка $Try не удалась: $($E.Message)"; Done = 0; Total = 0 })
                if ($Try -eq 5) { return "$Label`: $($E.Message)" }
                Start-Sleep -Seconds (3 * $Try)
            }
        }
    }
    try {
        if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
        foreach ($It in $Items) {
            if ($It.Zip) {
                $Z = Join-Path $Dir "whisper-bin-x64.zip"
                $Err = & $Get $It.Url $Z $It.Sha "whisper.cpp"
                if ($Err) { $Q.Enqueue(@{ Type = "wdone"; Ok = $false; Error = $Err }); return }
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $A = [IO.Compression.ZipFile]::OpenRead($Z)
                foreach ($E in $A.Entries) {
                    $N = $E.Name
                    if ($N -eq "whisper-cli.exe" -or ($N -like "*.dll" -and $N -notlike "parakeet*" -and $N -ne "SDL2.dll")) { [IO.Compression.ZipFileExtensions]::ExtractToFile($E, (Join-Path $Dir $N), $true) }
                }
                $A.Dispose(); Remove-Item $Z -ErrorAction SilentlyContinue
            } else {
                $Err = & $Get $It.Url (Join-Path $Dir $It.File) $It.Sha "модель $($It.File)"
                if ($Err) { $Q.Enqueue(@{ Type = "wdone"; Ok = $false; Error = $Err }); return }
            }
        }
        $Q.Enqueue(@{ Type = "wdone"; Ok = $true })
    } catch { $Q.Enqueue(@{ Type = "wdone"; Ok = $false; Error = "$($_.Exception.Message)" }) }
}

# asks first (sizes, sources); $OnStatus gets (text, kind), $OnReady runs when installed
function Install-Whisper {
    param([scriptblock]$OnStatus, [scriptblock]$OnReady)
    if (Test-WhisperReady) { if ($OnReady) { & $OnReady }; return }
    if (Test-WorkerRunning "whisper-install") { return }
    $M = $script:WhisperModels[(Get-WhisperModel)]
    $Items = @()
    if (-not (Test-Path (Get-WhisperExe))) { $Items += @{ Zip = $true; Url = $script:WhisperZip.Url; Sha = $script:WhisperZip.Sha } }
    if (-not (Test-Path (Get-WhisperModelPath))) { $Items += @{ Zip = $false; Url = $M.Url; Sha = $M.Sha; File = $M.File } }
    $Mb = $(if ($Items | Where-Object { $_.Zip }) { $script:WhisperZip.Mb } else { 0 }) + $(if ($Items | Where-Object { -not $_.Zip }) { $M.Mb } else { 0 })
    $Msg = "Для расшифровки голоса NetKnife скачает whisper.cpp v1.9.2 (github.com/ggml-org) и модель $($M.File) (huggingface.co/ggerganov) — всего ≈$Mb МБ, в $($script:WhisperDir). Файлы проверяются по контрольной сумме. Распознавание идёт на этом ноутбуке, запись никуда не отправляется."
    if (-not (Show-Confirm "Установить распознавание речи?" $Msg "Скачать")) { return }
    $script:WhisperCb = @{ Status = $OnStatus; Ready = $OnReady }
    [void](Start-Worker -Name "whisper-install" -Replace -Body $script:WhisperInstallBody -ArgList @($script:WhisperDir, $Items) -OnMessage {
        param($X)
        $Cb = $script:WhisperCb
        switch ($X.Type) {
            "wdl" { if ($Cb.Status) { & $Cb.Status $(if ($X.Total) { "{0}: {1:N0} из {2:N0} МБ" -f $X.Label, ($X.Done / 1MB), ($X.Total / 1MB) } else { $X.Label }) "wait" } }
            "wdone" {
                if ($X.Ok) { if ($Cb.Status) { & $Cb.Status "Распознавание речи установлено" "ok" }; Show-Toast "Whisper установлен"; if ($Cb.Ready) { & $Cb.Ready } }
                else { if ($Cb.Status) { & $Cb.Status "Не скачалось: $($X.Error)" "fail" }; Show-Toast "Whisper: $($X.Error)" "fail" }
            }
        }
    })
}

# transcription worker: messages wtp (progress %), wtx (Words or Error)
$script:WhisperRunBody = {
    param($Q, $Ctl, $Exe, $Model, $Wav, $Prompt, $Threads)
    try {
        $OutBase = [IO.Path]::ChangeExtension($Wav, $null).TrimEnd('.')
        $Psi = New-Object System.Diagnostics.ProcessStartInfo $Exe
        foreach ($A in @("-m", $Model, "-l", "ru", "-f", $Wav, "-oj", "-of", $OutBase, "-ml", "1", "-sow", "-pp", "-t", "$Threads")) { $Psi.ArgumentList.Add($A) }
        if ($Prompt) { $Psi.ArgumentList.Add("--prompt"); $Psi.ArgumentList.Add($Prompt) }
        $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true; $Psi.RedirectStandardError = $true; $Psi.RedirectStandardOutput = $true
        $Psi.StandardErrorEncoding = [Text.Encoding]::UTF8; $Psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $P = [System.Diagnostics.Process]::Start($Psi)
        $OutT = $P.StandardOutput.ReadToEndAsync()
        while (-not $P.StandardError.EndOfStream) {
            if ($Ctl.Stop) { try { $P.Kill() } catch { }; return }
            $Ln = $P.StandardError.ReadLine()
            if ($Ln -match 'progress\s*=\s*(\d+)%') { $Q.Enqueue(@{ Type = "wtp"; Pct = [int]$Matches[1] }) }
        }
        $P.WaitForExit()
        $J = "$OutBase.json"
        if ($P.ExitCode -ne 0 -or -not (Test-Path $J)) { $Q.Enqueue(@{ Type = "wtx"; Error = "whisper-cli код $($P.ExitCode)" }); return }
        $T = (Get-Content $J -Raw -Encoding UTF8 | ConvertFrom-Json).transcription
        $Words = @(foreach ($S in @($T)) { $Tx = "$($S.text)".Trim(); if ($Tx) { @{ T0 = [double]$S.offsets.from / 1000; T1 = [double]$S.offsets.to / 1000; Text = $Tx } } })
        $Q.Enqueue(@{ Type = "wtx"; Words = $Words })
    } catch { $Q.Enqueue(@{ Type = "wtx"; Error = "$($_.Exception.Message)" }) }
}

function Start-WhisperTranscribe {
    param([string]$Wav, [string]$Prompt, [scriptblock]$OnProgress, [scriptblock]$OnDone)
    $script:WhisperRunCb = @{ Progress = $OnProgress; Done = $OnDone }
    $Th = [Math]::Max(2, [Math]::Min(8, [Environment]::ProcessorCount - 2))
    [void](Start-Worker -Name "whisper-run" -Replace -Body $script:WhisperRunBody -ArgList @((Get-WhisperExe), (Get-WhisperModelPath), $Wav, $Prompt, $Th) -OnMessage {
        param($X)
        $Cb = $script:WhisperRunCb
        if ($X.Type -eq "wtp" -and $Cb.Progress) { & $Cb.Progress $X.Pct }
        if ($X.Type -eq "wtx" -and $Cb.Done) { & $Cb.Done $X }
    })
}

# words → phrases: a new phrase after a pause > 0.8 s or after . , ! ? ;
function ConvertTo-WhisperPhrases {
    param($Words)
    $Out = [System.Collections.Generic.List[object]]::new()
    $Cur = $null
    foreach ($W in @($Words)) {
        $Tx = ($W.Text -replace '^[\.\s]+', '')
        if (-not $Tx) { continue }
        if ($Cur -and ($W.T0 - $Cur.T1) -gt 0.8) { $Out.Add($Cur); $Cur = $null }
        if (-not $Cur) { $Cur = @{ T0 = $W.T0; T1 = $W.T1; Text = $Tx } } else { $Cur.Text += " " + $Tx; $Cur.T1 = $W.T1 }
        if ($Tx -match '[\.\,\!\?;]$') { $Out.Add($Cur); $Cur = $null }
    }
    if ($Cur) { $Out.Add($Cur) }
    foreach ($P in $Out) { $P.Text = ($P.Text -replace '[\s\.\,;]+$', '').Trim() }
    return @($Out | Where-Object { $_.Text })
}
