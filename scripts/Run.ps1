# Drop-and-play runner for the Windows CPU miner.
# Double-click RUN.cmd, or run:
#   powershell.exe -ExecutionPolicy Bypass -File .\scripts\Run.ps1
#
# It installs only when needed (one UAC prompt), starts mining immediately,
# waits for the heat sensor, then opens the control panel. Running it again is
# safe: existing installs are detected and no binaries are downloaded again.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Miner.ps1')

function Test-Installed {
    $supervisor = Get-ScheduledTask -TaskName 'CpuMiner-Supervisor' -ErrorAction SilentlyContinue
    $lhmTask = Get-ScheduledTask -TaskName 'CpuMiner-LHM' -ErrorAction SilentlyContinue
    $tasksOk = $null -ne $supervisor -and $null -ne $lhmTask -and
               @('Ready', 'Running') -contains $supervisor.State -and
               @('Ready', 'Running') -contains $lhmTask.State
    return (Test-Path -LiteralPath $Script:ConfigPath) -and
           $tasksOk -and
           (Test-Path -LiteralPath $Script:XmrigPath) -and
           (Test-Path -LiteralPath $Script:LhmPath)
}

function Invoke-FirstInstall {
    $installer = Join-Path $Script:RepoRoot 'scripts\Install.ps1'
    $owner = "$env:USERDOMAIN\$env:USERNAME"
    $startup = [Environment]::GetFolderPath('Startup')
    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $installer),
        '-Owner', ('"{0}"' -f $owner),
        '-StartupFolder', ('"{0}"' -f $startup)
    )

    Write-Host 'First run: installing. Approve the Windows admin prompt if it appears.' -ForegroundColor Yellow
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
            -WorkingDirectory $Script:RepoRoot -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        throw ('Installation was cancelled or failed: ' + $_.Exception.Message)
    }
    if ($proc.ExitCode -ne 0) {
        throw ('Installer exited with code ' + $proc.ExitCode + '. See the installer window for details.')
    }
}

function Wait-ForTemperature {
    param([hashtable]$Config, [int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $temp = Get-CpuTemp -Config $Config
        if ($null -ne $temp) { return $temp }
        Start-Sleep -Seconds 3
    }
    return $null
}

function Show-FailureAndExit {
    param([string]$Message)
    Write-Host ''
    Write-Host ('Could not finish: ' + $Message) -ForegroundColor Red
    Write-Host ('Logs: ' + $Script:LogsDir) -ForegroundColor Yellow
    if ([Environment]::UserInteractive) {
        Write-Host 'Press Enter to close...'
        Read-Host | Out-Null
    }
    exit 1
}

try {
    Write-Host ('LTC miner runner - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $wasInstalled = Test-Installed

    if (-not $wasInstalled) {
        Invoke-FirstInstall
        if (-not (Test-Installed)) {
            throw 'Installation finished but required files or tasks are still missing.'
        }
    } else {
        Write-Host 'Existing installation detected; no download needed.' -ForegroundColor Green
        if (-not (Get-Process -Name 'LibreHardwareMonitor' -ErrorAction SilentlyContinue)) {
            & (Join-Path $PSScriptRoot 'Start-Lhm.ps1')
        }
    }

    Write-Host 'Checking CPU temperature sensor...'
    $cfg = Get-Config
    $temp = Wait-ForTemperature -Config $cfg -TimeoutSeconds 60
    if ($null -eq $temp) {
        throw 'CPU temperature is unavailable. Mining is not started because the heat guard needs it. Check the CpuMiner-LHM task.'
    }
    Write-Host ('CPU temperature: {0:N1} C (guard {1}/{2} C)' -f $temp, $cfg['RESUME_TEMP'], $cfg['STOP_TEMP'])

    if (-not (Start-Miner)) {
        throw 'xmrig did not start. See logs\miner.log and logs\stderr.log.'
    }

    Write-Host 'Mining is running. Opening the control panel...' -ForegroundColor Green
    Start-Sleep -Seconds 1
    & (Join-Path $PSScriptRoot 'Menu.ps1')
    exit 0
} catch {
    Show-FailureAndExit -Message $_.Exception.Message
}
