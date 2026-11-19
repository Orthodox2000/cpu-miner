# Always-on supervisor: watchdog, temperature guard, and 45-minute restarts.
# Launched hidden at logon by the CpuMiner-Supervisor scheduled task.

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Miner.ps1')

function Invoke-Watchdog {
    if (-not (Test-Path -LiteralPath $Script:WasActive)) { return }
    if (-not (Test-MinerRunning)) {
        Write-Log -Component 'watchdog' -Message 'miner was down -> restarting'
        Start-Miner | Out-Null
    }
}

function Invoke-TempGuard {
    $cfg = Get-Config
    $temp = Get-CpuTemp -Config $cfg
    $stop = [double]$cfg['STOP_TEMP']
    $resume = [double]$cfg['RESUME_TEMP']

    if ($null -eq $temp) {
        Write-Log -Component 'temp' -Message 'temperature unavailable -> stopping miner fail-safe'
        if (Test-MinerRunning) { Stop-Miner | Out-Null }
        return
    }

    $state = Get-CoolingState
    if ($temp -ge $stop) {
        if ((Test-MinerRunning) -or (Test-Path -LiteralPath $Script:WasActive)) {
            Stop-Miner | Out-Null
            Set-CoolingState -State 'cooling' -Temp $temp.ToString('0.0')
            Write-Log -Component 'temp' -Message ("HOT {0:N1}C >= {1}C -> mining stopped" -f $temp, $stop)
        } else {
            Set-CoolingState -State 'cooling' -Temp $temp.ToString('0.0')
        }
        return
    }

    if ($state -eq 'cooling') {
        if ($temp -le $resume) {
            if (Start-Miner) {
                Set-CoolingState -State 'normal' -Temp $temp.ToString('0.0')
                Write-Log -Component 'temp' -Message ("COOL {0:N1}C <= {1}C -> mining resumed" -f $temp, $resume)
            } else {
                Write-Log -Component 'temp' -Message ("COOL {0:N1}C but restart failed; will retry" -f $temp)
            }
        }
        return
    }

    Set-CoolingState -State 'normal' -Temp $temp.ToString('0.0')
}

function Invoke-AutoRestart {
    if (-not (Test-Path -LiteralPath $Script:WasActive)) { return }
    Write-Log -Component 'auto-restart' -Message 'restarting miner on schedule'
    if (Restart-Miner) {
        Write-Log -Component 'auto-restart' -Message 'restart ok'
    } else {
        Write-Log -Component 'auto-restart' -Message 'restart failed'
    }
}

function Start-Supervisor {
    Ensure-Dirs
    Write-Log -Component 'supervisor' -Message 'started'
    $cfg = Get-Config
    if (Test-Path -LiteralPath $Script:WasActive) {
        Write-Log -Component 'supervisor' -Message 'was active at shutdown -> resuming'
        Start-Miner | Out-Null
    } else {
        Write-Log -Component 'supervisor' -Message 'not active at shutdown -> idle'
        Remove-Item -LiteralPath $Script:NextFile -Force -ErrorAction SilentlyContinue
    }

    $lastTemp = Get-Date
    $lastWatch = Get-Date
    $lastRestart = Get-Date

    while ($true) {
        Start-Sleep -Seconds 5
        $cfg = Get-Config
        $now = Get-Date

        if (($now - $lastTemp).TotalSeconds -ge [int]$cfg['TEMP_SECONDS']) {
            Invoke-TempGuard
            $lastTemp = $now
        }
        if (($now - $lastWatch).TotalSeconds -ge [int]$cfg['WATCHDOG_SECONDS']) {
            Invoke-Watchdog
            $lastWatch = $now
        }
        $restartSecs = [int]$cfg['RESTART_MINUTES'] * 60
        if (($now - $lastRestart).TotalSeconds -ge $restartSecs) {
            Invoke-AutoRestart
            $lastRestart = $now
        }
    }
}

Start-Supervisor
