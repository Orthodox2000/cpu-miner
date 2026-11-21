# Removes the Windows miner setup. Run elevated.
#   .\scripts\Uninstall.ps1                    keeps config/logs/bin
#   .\scripts\Uninstall.ps1 -RemoveData         deletes ProgramData\CpuMiner too
#   .\scripts\Uninstall.ps1 -RemoveUnattended   also removes auto-login and the RustDesk startup shortcut

param([switch]$RemoveData, [switch]$RemoveUnattended)

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
if ($RemoveUnattended) {
    Remove-Item -LiteralPath (Join-Path $startup 'RustDesk.lnk') -Force -ErrorAction SilentlyContinue
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $key -Name 'AutoAdminLogon' -Value '0' -Type String
    foreach ($name in @('DefaultPassword', 'DefaultUserName', 'DefaultDomainName', 'AutoLogonCount', 'ForceAutoLogon')) {
        Remove-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue
    }
    Write-Host 'Auto-login and RustDesk startup shortcut removed.' -ForegroundColor Yellow
}

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
