# Opened in a terminal at GUI login.
# Resumes mining only if it was active at last shutdown, then leaves the
# control panel open either way. The supervisor normally starts mining first;
# this call is idempotent and covers the short window before the task runs.

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Miner.ps1')

if (Test-Path -LiteralPath $Script:WasActive) {
    Write-Host 'Mining was active at shutdown - resuming...' -ForegroundColor Green
    Start-Miner | Out-Null
} else {
    Write-Host 'Mining was not active at shutdown - opening control panel only.' -ForegroundColor Yellow
}

& (Join-Path $PSScriptRoot 'Menu.ps1')
