# Opened in a terminal at GUI login.
# Starts mining at every login by default (AUTO_START_ON_LOGIN=true), or resumes
# only when the marker exists if that setting is false. The control panel stays
# open either way. The supervisor normally starts mining first; this call is
# idempotent and covers the short window before the task runs.

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Miner.ps1')

$cfg = Get-Config
$auto = [string]$cfg['AUTO_START_ON_LOGIN']
$shouldStart = ($auto -eq 'true') -or (Test-Path -LiteralPath $Script:WasActive)

if ($shouldStart) {
    Write-Host 'Starting mining at login...' -ForegroundColor Green
    $null = Wait-ForTemperature -Config $cfg -TimeoutSeconds 60
    Start-Miner | Out-Null
} else {
    Write-Host 'Auto-start disabled and miner was inactive - opening control panel only.' -ForegroundColor Yellow
}

& (Join-Path $PSScriptRoot 'Menu.ps1')
