# One-time / repair installer for the Windows CPU miner.
#   powershell.exe -ExecutionPolicy Bypass -File .\scripts\Install.ps1
# The payout address comes from config\wallet.txt unless -Wallet is supplied.
# RUN.cmd passes -Owner / -StartupFolder so a UAC prompt for a different admin
# account still configures the account that launched the runner.
# UNATTENDED.cmd adds -Unattended: auto-login, RustDesk startup and no-sleep,
# all scoped to this PC. Use -BlankPassword to try a passwordless account.

param(
    [string]$Wallet,
    [string]$Owner,
    [string]$StartupFolder,
    [switch]$Unattended,
    [switch]$BlankPassword,
    [switch]$SkipAutoLogin,
    [switch]$SkipRustDesk,
    [switch]$SkipPower
)

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

function Get-XmrigExpectedSha {
    $sums = (Invoke-WebRequest -Uri $XmrigSumsUrl -UseBasicParsing -TimeoutSec 60).Content
    foreach ($line in ($sums -split '\r?\n')) {
        if ($line -match ([regex]::Escape($XmrigZipName))) {
            return (($line -split '\s+')[0]).ToLowerInvariant()
        }
    }
    throw 'Could not find XMRig checksum in SHA256SUMS.'
}

function Enable-AutoLogin {
    param([string]$OwnerAccount)

    if ([string]::IsNullOrWhiteSpace($OwnerAccount)) { $OwnerAccount = "$env:USERDOMAIN\$env:USERNAME" }
    if ($OwnerAccount -like '*\*') {
        $domain, $account = $OwnerAccount -split '\', 2
    } else {
        $domain = $env:COMPUTERNAME
        $account = $OwnerAccount
    }

    Write-Host ''
    Write-Host 'AUTO-LOGIN WARNING - THIS PC ONLY' -ForegroundColor Red
    Write-Host 'The Windows sign-in prompt will be skipped on this computer.'
    Write-Host 'Anyone with physical access will land directly on the desktop.'
    if ($BlankPassword) {
        $password = ''
        Write-Host 'Using a blank password. Windows 10 may refuse this; a password is more reliable.' -ForegroundColor Yellow
    } else {
        $secure = Read-Host -Prompt ("Windows password for '{0}' (hidden input)" -f $OwnerAccount) -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $key -Name 'AutoAdminLogon' -Value '1' -Type String
    Set-ItemProperty -Path $key -Name 'DefaultUserName' -Value $account -Type String
    Set-ItemProperty -Path $key -Name 'DefaultDomainName' -Value $domain -Type String
    Set-ItemProperty -Path $key -Name 'DefaultPassword' -Value $password -Type String
    Set-ItemProperty -Path $key -Name 'AutoLogonCount' -Value 0 -Type DWord
    Remove-ItemProperty -Path $key -Name 'ForceAutoLogon' -ErrorAction SilentlyContinue

    $passwordless = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
    if (-not (Test-Path -LiteralPath $passwordless)) { New-Item -Path $passwordless -Force | Out-Null }
    Set-ItemProperty -Path $passwordless -Name 'DevicePasswordLessBuildVersion' -Value 0 -Type DWord

    Write-Host ("Auto-login configured for {0}\{1} on this computer." -f $domain, $account) -ForegroundColor Green
    if (-not $BlankPassword) {
        Write-Host 'The password is stored in the local registry. Keep this PC physically secure.' -ForegroundColor Yellow
    }
}

function Find-RustDeskExe {
    $roots = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        $roots += Join-Path $base 'RustDesk'
    }
    if ($env:LOCALAPPDATA) {
        $roots += Join-Path $env:LOCALAPPDATA 'Programs\RustDesk'
    }
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($p in (Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue)) {
        if ($p.DisplayName -like 'RustDesk*' -and $p.InstallLocation) { $roots += $p.InstallLocation }
    }
    foreach ($root in ($roots | Where-Object { $_ })) {
        $candidate = Join-Path $root 'rustdesk.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Enable-RustDeskStartup {
    param([string]$ShortcutFolder)

    $service = Get-Service -Name 'RustDesk*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($service) {
        try {
            Set-Service -Name $service.Name -StartupType Automatic -ErrorAction Stop
            Start-Service -Name $service.Name -ErrorAction SilentlyContinue
            Write-Host ('RustDesk service {0} set to Automatic on this PC.' -f $service.Name) -ForegroundColor Green
        } catch {
            Write-Warning ('Could not configure RustDesk service: ' + $_.Exception.Message)
        }
    }

    $exe = Find-RustDeskExe
    if ($exe) {
        $shortcutPath = Join-Path $ShortcutFolder 'RustDesk.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $exe
        $shortcut.WorkingDirectory = Split-Path -Parent $exe
        $shortcut.WindowStyle = 7
        $shortcut.Save()
        Write-Host 'RustDesk startup shortcut added for this user.' -ForegroundColor Green
    } else {
        Write-Warning 'RustDesk was not found. Install it, or enable its own "run on startup" setting.'
    }
    Write-Host 'In RustDesk, set a permanent password so unattended access keeps working.' -ForegroundColor Yellow
}

function Set-AlwaysOnPower {
    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change standby-timeout-dc 0 | Out-Null
    powercfg /change hibernate-timeout-ac 0 | Out-Null
    powercfg /change hibernate-timeout-dc 0 | Out-Null
    Write-Host 'Sleep and hibernate disabled for this Windows power plan.' -ForegroundColor Green
    Write-Host 'BIOS: set "Restore on AC Power Loss" to Power On so the PC starts when power returns.' -ForegroundColor Yellow
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
$xmrigExe = Join-Path $xmrigDir 'xmrig.exe'
$lhmExe = Join-Path $lhmDir 'LibreHardwareMonitor.exe'

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

# --- account that will own the tasks / data --------------------------------
if ([string]::IsNullOrWhiteSpace($Owner)) { $Owner = "$env:USERDOMAIN\$env:USERNAME" }
$user = $Owner
Write-Host ('Configuring miner for ' + $user + '.')

# --- restrict ACLs ---------------------------------------------------------
& icacls $data /inheritance:r /grant:r "${user}:(OI)(CI)F" "SYSTEM:(OI)(CI)F" /T | Out-Null

# --- XMRig (download only when missing) ------------------------------------
if (Test-Path -LiteralPath $xmrigExe) {
    Write-Host 'XMRig already installed; skipping download.'
} else {
    $xmrigZip = Join-Path $bin $XmrigZipName
    $needDownload = -not (Test-Path -LiteralPath $xmrigZip)
    if (-not $needDownload) {
        if ((Get-Sha256 -Path $xmrigZip) -ne (Get-XmrigExpectedSha)) {
            Write-Warning 'Cached XMRig archive failed verification; downloading again.'
            Remove-Item -LiteralPath $xmrigZip -Force
            $needDownload = $true
        }
    }
    if ($needDownload) {
        Download-File -Url $XmrigZipUrl -Path $xmrigZip
    }
    $expected = Get-XmrigExpectedSha
    $actual = Get-Sha256 -Path $xmrigZip
    if ($actual -ne $expected) {
        throw ("XMRig checksum mismatch. Expected {0}, got {1}." -f $expected, $actual)
    }
    Write-Host 'XMRig checksum verified.'
    if (Test-Path -LiteralPath $xmrigDir) { Remove-Item -LiteralPath $xmrigDir -Recurse -Force }
    Expand-Archive -LiteralPath $xmrigZip -DestinationPath $xmrigDir -Force
    if (-not (Test-Path -LiteralPath $xmrigExe)) {
        $nested = Get-ChildItem -LiteralPath $xmrigDir -Filter 'xmrig.exe' -Recurse | Select-Object -First 1
        if ($nested) { Copy-Item -LiteralPath $nested.FullName -Destination $xmrigExe -Force }
    }
    if (-not (Test-Path -LiteralPath $xmrigExe)) { throw 'xmrig.exe was not found after extraction.' }
}

# --- LibreHardwareMonitor (download only when missing) ----------------------
if (Test-Path -LiteralPath $lhmExe) {
    Write-Host 'LibreHardwareMonitor already installed; skipping download.'
} else {
    $lhmZip = Join-Path $bin $LhmZipName
    $needDownload = -not (Test-Path -LiteralPath $lhmZip)
    if (-not $needDownload -and (Get-Sha256 -Path $lhmZip) -ne $LhmExpectedSha) {
        Write-Warning 'Cached LibreHardwareMonitor archive failed verification; downloading again.'
        Remove-Item -LiteralPath $lhmZip -Force
        $needDownload = $true
    }
    if ($needDownload) {
        Download-File -Url $LhmZipUrl -Path $lhmZip
    }
    $lhmActual = Get-Sha256 -Path $lhmZip
    if ($lhmActual -ne $LhmExpectedSha) {
        throw ("LibreHardwareMonitor checksum mismatch. Expected {0}, got {1}." -f $LhmExpectedSha, $lhmActual)
    }
    Write-Host 'LibreHardwareMonitor checksum verified.'
    if (Test-Path -LiteralPath $lhmDir) { Remove-Item -LiteralPath $lhmDir -Recurse -Force }
    Expand-Archive -LiteralPath $lhmZip -DestinationPath $lhmDir -Force
    if (-not (Test-Path -LiteralPath $lhmExe)) {
        $nested = Get-ChildItem -LiteralPath $lhmDir -Filter 'LibreHardwareMonitor.exe' -Recurse | Select-Object -First 1
        if ($nested) { Copy-Item -LiteralPath $nested.FullName -Destination $lhmExe -Force }
    }
    if (-not (Test-Path -LiteralPath $lhmExe)) { throw 'LibreHardwareMonitor.exe was not found after extraction.' }
}

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
if ([string]::IsNullOrWhiteSpace($StartupFolder)) { $StartupFolder = [Environment]::GetFolderPath('Startup') }
$shortcutPath = Join-Path $StartupFolder 'LTC Miner.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = 'powershell.exe'
$shortcut.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $repo 'scripts\ResumeOnLogin.ps1'))
$shortcut.WorkingDirectory = $repo
$shortcut.WindowStyle = 1
$shortcut.Save()

# --- optional unattended startup (THIS PC ONLY) -----------------------------
if ($Unattended) {
    Write-Host ''
    Write-Host '--- Unattended startup setup (this PC only) ---' -ForegroundColor Cyan
    if (-not $SkipAutoLogin) { Enable-AutoLogin -OwnerAccount $Owner }
    if (-not $SkipRustDesk) { Enable-RustDeskStartup -ShortcutFolder $StartupFolder }
    if (-not $SkipPower) { Set-AlwaysOnPower }
}

Start-ScheduledTask -TaskName 'CpuMiner-LHM'
Start-ScheduledTask -TaskName 'CpuMiner-Supervisor'
Write-Host ''
Write-Host 'Installation complete.' -ForegroundColor Green
Write-Host 'Returning to the runner to start mining now...'
Write-Host 'Run .\scripts\HealthCheck.ps1 at any time to verify everything.'
exit 0
