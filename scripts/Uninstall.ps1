# Removes the Windows miner setup. Run elevated.
#   .\scripts\Uninstall.ps1            keeps config/logs/bin
#   .\scripts\Uninstall.ps1 -RemoveData  deletes everything under ProgramData\CpuMiner too

param([switch]$RemoveData)

$ErrorActionPreference = 'Stop'
function Assert-Admin {
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this from PowerShell as Administrator.'
    }
}
Assert-Admin
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Miner.ps1')

Stop-Miner | Out-Null

foreach ($name in @('CpuMiner-Supervisor', 'CpuMiner-LHM')) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -TaskName $name -Confirm:$false -Force }
}
$startup = [Environment]::GetFolderPath('Startup')
Remove-Item -LiteralPath (Join-Path $startup 'LTC Miner.lnk') -Force -ErrorAction SilentlyContinue

foreach ($rule in @('CpuMiner XMRig allow pool TLS', 'CpuMiner XMRig allow DNS',
                   'CpuMiner XMRig block other TCP', 'CpuMiner XMRig block other UDP')) {
    Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
}
Get-Process -Name 'LibreHardwareMonitor' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

if ($RemoveData) {
    $data = Join-Path $env:ProgramData 'CpuMiner'
    if (Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Recurse -Force }
    Write-Host 'ProgramData\CpuMiner removed.'
}
Write-Host 'Miner setup removed.'
