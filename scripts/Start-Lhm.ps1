# Starts LibreHardwareMonitor minimized. Launched by the elevated LHM task.
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-Path -LiteralPath $Script:LhmPath)) {
    Write-Log -Component 'lhm' -Message 'LibreHardwareMonitor.exe missing'
    exit 1
}
$existing = Get-Process -Name 'LibreHardwareMonitor' -ErrorAction SilentlyContinue
if (-not $existing) {
    Start-Process -FilePath $Script:LhmPath -WindowStyle Minimized
    Write-Log -Component 'lhm' -Message 'started minimized'
}
