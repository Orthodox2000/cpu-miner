# One-time installer for the Windows CPU miner. Run from an elevated PowerShell:
#   powershell.exe -ExecutionPolicy Bypass -File .\scripts\Install.ps1 -Wallet 'LTC...'
# If -Wallet is omitted, config\local.env (copied from the Linux machine) is used.

param([string]$Wallet)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$XmrigVersion = '6.26.0'
$XmrigZipName = 'xmrig-6.26.0-windows-x64.zip'
$XmrigZipUrl = 'https://github.com/xmrig/xmrig/releases/download/v6.26.0/xmrig-6.26.0-windows-x64.zip'
$XmrigSumsUrl = 'https://github.com/xmrig/xmrig/releases/download/v6.26.0/SHA256SUMS'
$LhmVersion = 'v0.9.6'
$LhmZipName = 'LibreHardwareMonitor.zip'
$LhmZipUrl = 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip'
$LhmExpectedSha = '086d9f1b5a99e643edc2cfaaac16051685b551e4c5ac0b32a57c58c0e529c001'

function Assert-Admin {
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this installer from PowerShell as Administrator.'
    }
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Download-File {
    param([string]$Url, [string]$Path)
    Write-Host ('Downloading ' + $Url)
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 180
}

Assert-Admin
$repo = Split-Path -Parent $PSScriptRoot
$data = Join-Path $env:ProgramData 'CpuMiner'
$state = Join-Path $data 'state'
$logs = Join-Path $data 'logs'
$bin = Join-Path $repo 'bin'
$xmrigDir = Join-Path $bin 'xmrig'
$lhmDir = Join-Path $bin 'LibreHardwareMonitor'
$configPath = Join-Path $data 'config.env'

foreach ($dir in @($data, $state, $logs, $bin)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# --- config ----------------------------------------------------------------
if (-not (Test-Path -LiteralPath $configPath)) {
    $local = Join-Path $repo 'config\local.env'
    if (Test-Path -LiteralPath $local) {
        Copy-Item -LiteralPath $local -Destination $configPath -Force
        Write-Host 'Copied config\local.env (local override).'
    } else {
        Copy-Item -LiteralPath (Join-Path $repo 'config\local.example.env') -Destination $configPath -Force
    }
}
if ([string]::IsNullOrWhiteSpace($Wallet)) {
    $walletFile = Join-Path $repo 'config\wallet.txt'
    if (Test-Path -LiteralPath $walletFile) {
        $Wallet = (Get-Content -LiteralPath $walletFile -Raw).Trim()
        Write-Host 'Using wallet address from config\wallet.txt.'
    }
}
if (-not [string]::IsNullOrWhiteSpace($Wallet)) {
    $lines = Get-Content -LiteralPath $configPath
    $lines = $lines | ForEach-Object {
        if ($_ -match '^WALLET=') { 'WALLET=' + $Wallet.Trim() } else { $_ }
    }
    Set-Content -LiteralPath $configPath -Value $lines -Force
}
$cfgText = Get-Content -LiteralPath $configPath -Raw
if ($cfgText -notmatch '(?m)^WALLET=\S+' -or $cfgText -match 'REPLACE_WITH_LTC_ADDRESS') {
    $answer = Read-Host -Prompt 'LTC payout wallet address'
    $lines = Get-Content -LiteralPath $configPath
    $lines = $lines | ForEach-Object { if ($_ -match '^WALLET=') { 'WALLET=' + $answer.Trim() } else { $_ } }
    Set-Content -LiteralPath $configPath -Value $lines -Force
}

# --- restrict ACLs ---------------------------------------------------------
$user = "$env:USERDOMAIN\$env:USERNAME"
& icacls $data /inheritance:r /grant:r "${user}:(OI)(CI)F" "SYSTEM:(OI)(CI)F" /T | Out-Null

# --- XMRig -----------------------------------------------------------------
$xmrigZip = Join-Path $bin $XmrigZipName
Download-File -Url $XmrigZipUrl -Path $xmrigZip
$sums = (Invoke-WebRequest -Uri $XmrigSumsUrl -UseBasicParsing -TimeoutSec 60).Content
$expected = ''
foreach ($line in ($sums -split '\r?\n')) {
    if ($line -match ([regex]::Escape($XmrigZipName))) {
        $expected = (($line -split '\s+')[0]).ToLowerInvariant()
        break
    }
}
if ([string]::IsNullOrWhiteSpace($expected)) { throw 'Could not find XMRig checksum in SHA256SUMS.' }
$actual = Get-Sha256 -Path $xmrigZip
if ($actual -ne $expected) {
    throw ("XMRig checksum mismatch. Expected {0}, got {1}." -f $expected, $actual)
}
Write-Host 'XMRig checksum verified.'
if (Test-Path -LiteralPath $xmrigDir) { Remove-Item -LiteralPath $xmrigDir -Recurse -Force }
Expand-Archive -LiteralPath $xmrigZip -DestinationPath $xmrigDir -Force
$xmrigExe = Join-Path $xmrigDir 'xmrig.exe'
if (-not (Test-Path -LiteralPath $xmrigExe)) {
    $nested = Get-ChildItem -LiteralPath $xmrigDir -Filter 'xmrig.exe' -Recurse | Select-Object -First 1
    if ($nested) { Copy-Item -LiteralPath $nested.FullName -Destination $xmrigExe -Force }
}
if (-not (Test-Path -LiteralPath $xmrigExe)) { throw 'xmrig.exe was not found after extraction.' }

# --- LibreHardwareMonitor --------------------------------------------------
$lhmZip = Join-Path $bin $LhmZipName
Download-File -Url $LhmZipUrl -Path $lhmZip
$lhmActual = Get-Sha256 -Path $lhmZip
if ($lhmActual -ne $LhmExpectedSha) {
    throw ("LibreHardwareMonitor checksum mismatch. Expected {0}, got {1}." -f $LhmExpectedSha, $lhmActual)
}
Write-Host 'LibreHardwareMonitor checksum verified.'
if (Test-Path -LiteralPath $lhmDir) { Remove-Item -LiteralPath $lhmDir -Recurse -Force }
Expand-Archive -LiteralPath $lhmZip -DestinationPath $lhmDir -Force
$lhmExe = Join-Path $lhmDir 'LibreHardwareMonitor.exe'
if (-not (Test-Path -LiteralPath $lhmExe)) {
    $nested = Get-ChildItem -LiteralPath $lhmDir -Filter 'LibreHardwareMonitor.exe' -Recurse | Select-Object -First 1
    if ($nested) { Copy-Item -LiteralPath $nested.FullName -Destination $lhmExe -Force }
}
if (-not (Test-Path -LiteralPath $lhmExe)) { throw 'LibreHardwareMonitor.exe was not found after extraction.' }

$lhmConfig = Join-Path $lhmDir 'LibreHardwareMonitor.exe.config'
@'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <add key="runWebServerMenuItem" value="true" />
    <add key="listenerIp" value="127.0.0.1" />
    <add key="listenerPort" value="8085" />
    <add key="authenticationEnabled" value="false" />
  </appSettings>
</configuration>
'@ | Set-Content -LiteralPath $lhmConfig -Encoding UTF8 -Force

# --- firewall: only pool TLS + DNS for xmrig -------------------------------
$rules = @(
    @{ Name = 'CpuMiner XMRig allow pool TLS'; Protocol = 'TCP'; Port = '443'; Action = 'Allow' },
    @{ Name = 'CpuMiner XMRig allow DNS';      Protocol = 'UDP'; Port = '53';  Action = 'Allow' },
    @{ Name = 'CpuMiner XMRig block other TCP'; Protocol = 'TCP'; Port = '1-442,444-65535'; Action = 'Block' },
    @{ Name = 'CpuMiner XMRig block other UDP'; Protocol = 'UDP'; Port = '1-52,54-65535';  Action = 'Block' }
)
foreach ($r in $rules) {
    New-NetFirewallRule -DisplayName $r.Name -Direction Outbound -Program $xmrigExe `
        -Protocol $r.Protocol -RemotePort $r.Port -Action $r.Action -Profile Any -Force | Out-Null
}
Write-Host 'Firewall rules installed (xmrig may only use TCP 443 and UDP 53).'

# --- scheduled tasks -------------------------------------------------------
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Days 3650)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$limited = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$highest = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest

$supervisorScript = Join-Path $repo 'scripts\Supervisor.ps1'
$supervisorAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $supervisorScript)
Register-ScheduledTask -TaskName 'CpuMiner-Supervisor' -Action $supervisorAction `
    -Trigger $trigger -Principal $limited -Settings $settings `
    -Description 'Watchdog, temperature guard and 45-minute miner restart' -Force | Out-Null

$lhmScript = Join-Path $repo 'scripts\Start-Lhm.ps1'
$lhmAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $lhmScript)
Register-ScheduledTask -TaskName 'CpuMiner-LHM' -Action $lhmAction `
    -Trigger $trigger -Principal $highest -Settings $settings `
    -Description 'LibreHardwareMonitor temperature sensor (elevated)' -Force | Out-Null

# --- startup control window ------------------------------------------------
$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'LTC Miner.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = 'powershell.exe'
$shortcut.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $repo 'scripts\ResumeOnLogin.ps1'))
$shortcut.WorkingDirectory = $repo
$shortcut.WindowStyle = 1
$shortcut.Save()

Start-ScheduledTask -TaskName 'CpuMiner-LHM'
Start-ScheduledTask -TaskName 'CpuMiner-Supervisor'
Write-Host ''
Write-Host 'Installation complete.' -ForegroundColor Green
Write-Host 'The control window opens at next login. To open it now:'
Write-Host ('  powershell.exe -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $repo 'scripts\ResumeOnLogin.ps1'))
Write-Host 'Run .\scripts\HealthCheck.ps1 to verify everything.'
