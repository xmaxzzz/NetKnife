# Background workers: thread jobs that talk to the UI through a concurrent queue.
# Worker body signature: param($Q, $Ctl, ...args). Enqueue hashtables with a Type key.

$script:Workers = [System.Collections.Generic.List[object]]::new()
$script:NetLib = Join-Path $PSScriptRoot "Net.ps1"

$script:WorkerWrapper = {
    param($Lib, $Q, $Ctl, $BodyText, $A)
    . $Lib
    $Body = [scriptblock]::Create($BodyText)
    try {
        & $Body $Q $Ctl @A
    } catch {
        $Q.Enqueue(@{ Type = "error"; Text = "$($_.Exception.Message)" })
    }
    $Q.Enqueue(@{ Type = "end" })
}

function Start-Worker {
    param(
        [string]$Name,
        [scriptblock]$Body,
        [object[]]$ArgList = @(),
        [scriptblock]$OnMessage,
        [scriptblock]$OnDone,
        [hashtable]$State = @{},
        [switch]$Replace
    )

    if ($Replace) { Stop-Worker $Name }

    $Q = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $Ctl = [hashtable]::Synchronized(@{ Stop = $false })
    $Job = Start-ThreadJob -ThrottleLimit 48 -ScriptBlock $script:WorkerWrapper -ArgumentList $script:NetLib, $Q, $Ctl, $Body.ToString(), $ArgList

    $W = [pscustomobject]@{ Name = $Name; Q = $Q; Ctl = $Ctl; Job = $Job; OnMessage = $OnMessage; OnDone = $OnDone; State = $State; Started = [DateTime]::Now }
    $script:Workers.Add($W)
    return $W
}

function Stop-Worker {
    param([string]$Name)
    foreach ($W in @($script:Workers | Where-Object { $_.Name -eq $Name })) {
        $W.Ctl.Stop = $true
        $script:Workers.Remove($W) | Out-Null
        $J = $W.Job
        # let it finish on its own; clean up later
        $script:Orphans.Add($J)
    }
}

function Test-WorkerRunning {
    param([string]$Name)
    return [bool]($script:Workers | Where-Object { $_.Name -eq $Name })
}

$script:Orphans = [System.Collections.Generic.List[object]]::new()

function Invoke-WorkerPump {
    foreach ($W in @($script:Workers)) {
        # handlers do not see the locals of the function that started the worker; pass them via -State
        $State = $W.State
        $Msg = $null
        $N = 0
        $Ended = $false
        while ($N -lt 400 -and $W.Q.TryDequeue([ref]$Msg)) {
            $N++
            if ($Msg.Type -eq "end") { $Ended = $true; break }
            if ($Msg.Type -eq "error") { Show-Toast "Ошибка ($($W.Name)): $($Msg.Text)" "fail" }
            if ($W.OnMessage) {
                try { & $W.OnMessage $Msg } catch { Write-AppLog "[$($W.Name)] handler: $_ $($_.ScriptStackTrace)" }
            }
        }
        if ($Ended) {
            $script:Workers.Remove($W) | Out-Null
            Remove-Job $W.Job -Force -ErrorAction SilentlyContinue
            if ($W.OnDone) {
                try { & $W.OnDone } catch { Write-AppLog "[$($W.Name)] done: $_ $($_.ScriptStackTrace)" }
            }
        }
    }

    foreach ($J in @($script:Orphans)) {
        if ("$($J.State)" -in @("Completed", "Failed", "Stopped")) {
            Remove-Job $J -Force -ErrorAction SilentlyContinue
            $script:Orphans.Remove($J) | Out-Null
        }
    }
}
