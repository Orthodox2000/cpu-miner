# Read-only health check. Safe to run anytime.

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Validate-Wallet.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$fail = 0
function Ok { param([string]$s) Write-Host ('  [ OK ] ' + $s) -ForegroundColor Green }
function Bad { param([string]$s) Write-Host ('  [FAIL] ' + $s) -ForegroundColor Red; $script:fail++ }
function Warn { param([string]$s) Write-Host ('  [WARN] ' + $s) -ForegroundColor Yellow }

Write-Host ('Miner health check - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host ''

$cfg = Get-Config
if (Test-Path -LiteralPath $Script:ConfigPath) { Ok 'config.env present' } else { Bad 'config.env missing - run Install.ps1' }
if (Test-WalletAddress -Coin ([string]$cfg['PAYOUT_COIN']) -Address ([string]$cfg['WALLET'])) {
    Ok ('payout address valid (' + $cfg['PAYOUT_COIN'] + ')')
} else { Bad 'payout address missing or invalid' }

if (Test-Path -LiteralPath $Script:XmrigPath) { Ok 'xmrig.exe present' } else { Bad 'xmrig.exe missing - run Install.ps1' }
if (Test-Path -LiteralPath $Script:LhmPath) { Ok 'LibreHardwareMonitor present' } else { Bad 'LibreHardwareMonitor missing - run Install.ps1' }

if (Test-MinerRunning) { Ok 'xmrig process running' } else { Warn 'xmrig process not running' }
if (Test-Path -LiteralPath $Script:WasActive) { Ok 'manual-run flag armed (resumes after reboot)' } else { Warn 'manual-run flag absent (will not resume after reboot)' }

$temp = Get-CpuTemp -Config $cfg
if ($null -ne $temp) {
    if ($temp -ge [double]$cfg['STOP_TEMP']) { Bad ('CPU {0:N1}C is at/over stop limit {1}C' -f $temp, [double]$cfg['STOP_TEMP']) }
    else { Ok ('CPU temperature {0:N1}C (stop {1}C / resume {2}C)' -f $temp, [double]$cfg['STOP_TEMP'], [double]$cfg['RESUME_TEMP']) }
} else { Bad 'CPU temperature unavailable - heat guard cannot work' }

foreach ($task in @('CpuMiner-Supervisor', 'CpuMiner-LHM')) {
    $t = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    if ($t -and @('Ready', 'Running') -contains $t.State) {
        Ok ($task + ' task registered (' + $t.State + ')')
    } else {
        Bad ($task + ' task missing or not ready')
    }
}
if (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Startup')) 'LTC Miner.lnk')) {
    Ok 'control panel startup shortcut present'
} else { Warn 'control panel startup shortcut missing' }

$rules = @('CpuMiner XMRig allow pool TLS', 'CpuMiner XMRig allow DNS',
           'CpuMiner XMRig block other TCP', 'CpuMiner XMRig block other UDP')
$missing = @($rules | Where-Object { -not (Get-NetFirewallRule -DisplayName $_ -ErrorAction SilentlyContinue) })
if ($missing.Count -eq 0) { Ok 'firewall restrictions present' } else { Bad ('missing firewall rules: ' + ($missing -join ', ')) }

$raw = & (Join-Path $PSScriptRoot 'Earnings.ps1') -Raw 2>$null
$fields = ([string]($raw | Select-Object -First 1)) -split '\|'
if ($fields.Count -ge 5) { Ok ('earnings {0} {1}, auto-pay {2}' -f $fields[0], $cfg['PAYOUT_COIN'], $fields[3]) }
else { Warn 'earnings unavailable (network or API)' }

Write-Host ''
if ($fail -eq 0) { Write-Host 'RESULT: all critical checks passed.' -ForegroundColor Green }
else { Write-Host ('RESULT: ' + $fail + ' critical check(s) failed.') -ForegroundColor Red }
exit ([math]::Min($fail, 1))
