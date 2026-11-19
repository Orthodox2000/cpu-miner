# Interactive control panel (same feel as the Linux miner.sh).

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Miner.ps1')

function Get-Bar {
    param([double]$Percent, [int]$Width = 15)
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $fill = [int]($Percent * $Width / 100)
    $out = ''
    for ($i = 0; $i -lt $Width; $i++) {
        if ($i -lt $fill) { $out += '█' } else { $out += '░' }
    }
    return $out
}

function Get-EarningsLine {
    $raw = & (Join-Path $PSScriptRoot 'Earnings.ps1') -Raw 2>$null
    $line = [string]($raw | Select-Object -First 1)
    $f = $line -split '\|'
    if ($f.Count -lt 5) { return ('{0} LTC   [----------] unknown' -f '-') }
    $bal = $f[0]; $thr = $f[1]; $pct = 0.0
    [double]::TryParse($f[2], [ref]$pct) | Out-Null
    $bar = Get-Bar -Percent $pct -Width 10
    return ('{0} LTC   {1} {2:N0}% to {3}' -f $bal, $bar, $pct, $thr)
}

function Draw-Screen {
    param([string]$Message)
    $cfg = Get-Config
    $status = Get-MinerStatus
    Clear-Host
    Write-Host ('  LTC MINER                                      ' + (Get-Date -Format 'HH:mm:ss'))
    Write-Host ''
    if ($status.Running) {
        Write-Host '  ● MINING — you are earning Litecoin.' -ForegroundColor Green
    } elseif ($status.Cooling) {
        Write-Host '  ◌ COOLING — mining paused to protect the CPU.' -ForegroundColor Yellow
    } else {
        Write-Host '  ○ STOPPED — press S to start mining.' -ForegroundColor Red
    }
    Write-Host ''
    $tempText = if ($null -ne $status.Temp) { ('{0:N1} C' -f $status.Temp) } else { 'unavailable' }
    $nextText = if ($null -ne $status.Next) {
        ('in {0}m {1}s (every {2} min)' -f [int]($status.Next.SecondsLeft / 60), ($status.Next.SecondsLeft % 60), $status.Next.Minutes)
    } else { 'off' }
    Write-Host ('  {0,-18}{1}' -f 'CPU temperature', $tempText)
    Write-Host ('  {0,-18}{1}' -f 'Temp guard', ('stop {0}C / resume {1}C' -f $status.StopTemp, $status.ResumeTemp))
    Write-Host ('  {0,-18}{1}' -f 'Auto-restart', $nextText)
    Write-Host ('  {0,-18}{1}' -f 'Earned so far', (Get-EarningsLine))
    Write-Host ('  {0,-18}{1}' -f 'Pool', $cfg['POOL'])
    $walletFull = [string]$cfg['WALLET']
    $walletShort = if ($walletFull.Length -gt 14) {
        $walletFull.Substring(0, 10) + '...' + $walletFull.Substring($walletFull.Length - 4)
    } else { $walletFull }
    Write-Host ('  {0,-18}{1}' -f 'Payout address', $walletShort)
    Write-Host ''
    Write-Host '  ─────────────────────────────────────────────────'
    Write-Host '  [S] Start    [X] Stop    [R] Restart    [Q] Quit'
    Write-Host ''
    if ($Message) { Write-Host ('  ' + $Message) -ForegroundColor Yellow }
}

try {
    $null = [Console]::KeyAvailable
} catch {
    Write-Host 'No interactive console detected. Use .\Miner.ps1 status instead.'
    exit 0
}

$message = ''
while ($true) {
    Draw-Screen -Message $message
    $deadline = (Get-Date).AddSeconds(2)
    $keyChar = ''
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            $keyChar = $key.KeyChar.ToString().ToLowerInvariant()
            break
        }
        Start-Sleep -Milliseconds 100
    }
    switch ($keyChar) {
        's' {
            if (Start-Miner) { $message = 'Mining started.' } else { $message = 'Could not start. Check logs.' }
        }
        'x' { Stop-Miner | Out-Null; $message = 'Mining stopped.' }
        'r' { if (Restart-Miner) { $message = 'Mining restarted.' } else { $message = 'Restart failed.' } }
        'q' { Clear-Host; exit 0 }
    }
}
