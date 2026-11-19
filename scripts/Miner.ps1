# Start / stop / restart the XMRig miner. Usage:
#   .\Miner.ps1 start|stop|restart|status
# Dot-source this file to call Start-Miner / Stop-Miner / Restart-Miner directly.

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Validate-Wallet.ps1')

function Start-Miner {
    $cfg = Get-Config
    $mutex = Enter-MinerLock
    try {
        if (Test-MinerRunning) {
            Write-Log -Component 'events' -Message 'START skipped (already running)'
            return $true
        }
        if (-not (Test-Path -LiteralPath $Script:XmrigPath)) {
            throw 'xmrig.exe is missing. Run Install.ps1 first.'
        }
        $coin = [string]$cfg['PAYOUT_COIN']
        $wallet = [string]$cfg['WALLET']
        if ([string]::IsNullOrWhiteSpace($wallet)) {
            throw 'WALLET is empty in config.env. Run Install.ps1 -Wallet <address>.'
        }
        if (-not (Test-WalletAddress -Coin $coin -Address $wallet)) {
            throw ('WALLET is not a valid {0} address.' -f $coin)
        }

        if ($cfg['TEMP_REQUIRED'] -eq 'true') {
            $temp = Get-CpuTemp -Config $cfg
            if ($null -eq $temp) {
                throw 'CPU temperature unavailable (LibreHardwareMonitor). Refusing to mine safely.'
            }
            if ($temp -ge [double]$cfg['STOP_TEMP']) {
                throw ('CPU is {0:N1}C, at/over the {1}C stop limit.' -f $temp, [double]$cfg['STOP_TEMP'])
            }
        }

        $worker = [string]$cfg['POOL_WORKER']
        $user = '{0}:{1}.{2}' -f $coin, $wallet, $worker
        $logFile = Join-Path $Script:LogsDir 'miner.log'
        $apiPort = [string]$cfg['API_PORT']
        $argsList = @(
            '-o', ('"{0}"' -f $cfg['POOL']),
            '-a', 'rx/0',
            '-k',
            '-u', ('"{0}"' -f $user),
            '-p', 'x',
            ('--cpu-max-threads-hint={0}' -f $cfg['MAX_THREADS']),
            ('--donate-level={0}' -f $cfg['DONATE_LEVEL']),
            '--print-time=30',
            '--http-host=127.0.0.1',
            ('--http-port={0}' -f $apiPort),
            ('--log-file="{0}"' -f $logFile),
            '--no-color'
        )

        $proc = Start-Process -FilePath $Script:XmrigPath -ArgumentList $argsList `
            -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $Script:LogsDir 'stdout.log') `
            -RedirectStandardError (Join-Path $Script:LogsDir 'stderr.log') `
            -ErrorAction Stop
        Start-Sleep -Seconds 4
        if ($proc.HasExited) {
            throw ('xmrig exited immediately with code {0}. See stderr.log.' -f $proc.ExitCode)
        }
        if (-not (Test-MinerRunning)) {
            throw 'xmrig did not stay running. See stderr.log.'
        }

        Set-Content -LiteralPath $Script:PidFile -Value $proc.Id -Force
        Set-WasActive
        Set-CoolingState -State 'normal'
        Write-NextRestart -Config $cfg
        Write-Log -Component 'events' -Message ("START pid={0}" -f $proc.Id)
        return $true
    } catch {
        Write-Log -Component 'events' -Message ("START_FAILED " + $_.Exception.Message)
        Write-Host ("Could not start miner: " + $_.Exception.Message) -ForegroundColor Red
        return $false
    } finally {
        Exit-MinerLock -Mutex $mutex
    }
}

function Stop-Miner {
    $mutex = Enter-MinerLock
    try {
        $procs = @(Get-MinerProcesses)
        foreach ($p in $procs) {
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
        if ($procs.Count -gt 0) {
            Start-Sleep -Seconds 1
        }
        $still = @(Get-MinerProcesses)
        if ($still.Count -gt 0) {
            foreach ($p in $still) {
                & taskkill /PID $p.ProcessId /T /F > $null 2>&1
            }
        }
        Clear-RuntimeState
        Write-Log -Component 'events' -Message 'STOP'
        return $true
    } catch {
        Write-Log -Component 'events' -Message ("STOP_FAILED " + $_.Exception.Message)
        return $false
    } finally {
        Exit-MinerLock -Mutex $mutex
    }
}

function Restart-Miner {
    Stop-Miner | Out-Null
    return Start-Miner
}

function Get-MinerStatus {
    $cfg = Get-Config
    $running = Test-MinerRunning
    $temp = Get-CpuTemp -Config $cfg
    return [pscustomobject]@{
        Running  = $running
        WasActive = (Test-Path -LiteralPath $Script:WasActive)
        Cooling  = ((Get-CoolingState) -eq 'cooling')
        Temp     = $temp
        StopTemp = [double]$cfg['STOP_TEMP']
        ResumeTemp = [double]$cfg['RESUME_TEMP']
        Next     = (Get-NextRestartInfo)
    }
}

function Get-NextRestartInfo {
    if (-not (Test-Path -LiteralPath $Script:NextFile)) { return $null }
    $parts = ((Get-Content -LiteralPath $Script:NextFile -TotalCount 1) -split '\s+')
    if ($parts.Count -lt 2) { return $null }
    $epoch = 0
    $minutes = 0
    if (-not [int]::TryParse($parts[0], [ref]$epoch)) { return $null }
    if (-not [int]::TryParse($parts[1], [ref]$minutes)) { return $null }
    $left = $epoch - (Get-UnixTime)
    if ($left -lt 0) { $left = 0 }
    return [pscustomobject]@{ SecondsLeft = $left; Minutes = $minutes }
}

if ($MyInvocation.InvocationName -ne '.') {
    Ensure-Dirs
    $action = if ($args.Count -gt 0) { $args[0].ToLowerInvariant() } else { 'status' }
    switch ($action) {
        'start' { if (Start-Miner) { Write-Host 'Miner started.' -ForegroundColor Green } else { exit 1 } }
        'stop' { Stop-Miner | Out-Null; Write-Host 'Miner stopped.' -ForegroundColor Yellow }
        'restart' { if (Restart-Miner) { Write-Host 'Miner restarted.' -ForegroundColor Green } else { exit 1 } }
        'status' {
            $s = Get-MinerStatus
            Write-Host ("Running: {0}  WasActive: {1}  Cooling: {2}" -f $s.Running, $s.WasActive, $s.Cooling)
            if ($null -ne $s.Temp) { Write-Host ("CPU temp: {0:N1}C (stop {1}C / resume {2}C)" -f $s.Temp, $s.StopTemp, $s.ResumeTemp) }
            if ($null -ne $s.Next) { Write-Host ("Next restart in: {0}m {1}s (every {2} min)" -f [int]($s.Next.SecondsLeft / 60), ($s.Next.SecondsLeft % 60), $s.Next.Minutes) }
        }
        default { Write-Host 'Usage: Miner.ps1 start|stop|restart|status' }
    }
}
