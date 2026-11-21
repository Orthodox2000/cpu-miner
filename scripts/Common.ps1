# Shared helpers for the Windows CPU miner.
# Dot-source this file from the other scripts. Windows PowerShell 5.1 compatible.

$Script:RepoRoot   = Split-Path -Parent $PSScriptRoot
$Script:DataRoot   = Join-Path $env:ProgramData 'CpuMiner'
$Script:ConfigPath = Join-Path $Script:DataRoot 'config.env'
$Script:StateDir   = Join-Path $Script:DataRoot 'state'
$Script:LogsDir    = Join-Path $Script:DataRoot 'logs'
$Script:BinDir     = Join-Path $Script:RepoRoot 'bin'
$Script:XmrigPath  = Join-Path $Script:BinDir 'xmrig\xmrig.exe'
$Script:LhmPath    = Join-Path $Script:BinDir 'LibreHardwareMonitor\LibreHardwareMonitor.exe'
$Script:WasActive  = Join-Path $Script:StateDir 'was-active'
$Script:PidFile    = Join-Path $Script:StateDir 'xmrig.pid'
$Script:CoolingFile= Join-Path $Script:StateDir 'cooling.state'
$Script:NextFile   = Join-Path $Script:StateDir 'next-restart.txt'
$Script:CacheFile  = Join-Path $Script:StateDir 'earnings.cache'

function Ensure-Dirs {
    foreach ($d in @($Script:DataRoot, $Script:StateDir, $Script:LogsDir, $Script:BinDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}

function Get-Config {
    $cfg = @{
        PAYOUT_COIN         = 'LTC'
        WALLET              = ''
        POOL                = 'stratum+ssl://rx.unmineable.com:443'
        POOL_WORKER         = 'HomePC'
        API_PORT            = '18080'
        MAX_THREADS         = '100'
        DONATE_LEVEL        = '0'
        STOP_TEMP           = '75'
        RESUME_TEMP         = '65'
        RESTART_MINUTES     = '45'
        WATCHDOG_SECONDS    = '180'
        TEMP_SECONDS        = '60'
        TEMP_REQUIRED       = 'true'
        LHM_URL             = 'http://127.0.0.1:8085/data.json'
        AUTO_START_ON_LOGIN = 'true'
    }
    if (Test-Path -LiteralPath $Script:ConfigPath) {
        foreach ($line in (Get-Content -LiteralPath $Script:ConfigPath)) {
            if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$') {
                $cfg[$matches[1]] = $matches[2]
            }
        }
    }
    return $cfg
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Ensure-Dirs
    $file = Join-Path $Script:LogsDir ($Component + '.log')
    Add-Content -LiteralPath $file -Value ("{0} {1}" -f (Get-Date -Format o), $Message)
    try {
        if ((Get-Item -LiteralPath $file).Length -gt 1MB) {
            Copy-Item -LiteralPath $file -Destination ($file + '.1') -Force
            Set-Content -LiteralPath $file -Value '' -Force
        }
    } catch { }
}

function Enter-MinerLock {
    $mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList $false, 'Global\CpuMinerLock'
    try {
        if (-not $mutex.WaitOne(15000)) {
            throw 'Another miner operation is still running.'
        }
    } catch [System.Threading.AbandonedMutexException] {
        # Previous owner died; we now own it.
    }
    return $mutex
}

function Exit-MinerLock {
    param([Parameter(Mandatory = $true)]$Mutex)
    try { $Mutex.ReleaseMutex() } catch { }
    try { $Mutex.Dispose() } catch { }
}

function Get-MinerProcesses {
    $procs = @()
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='xmrig.exe'" -ErrorAction Stop
    } catch { return @() }
    return @($procs | Where-Object {
        $path = [string]$_.ExecutablePath
        $cmd  = [string]$_.CommandLine
        ($path -and $path -eq $Script:XmrigPath) -or
        ($cmd -and $cmd -like ('*' + $Script:XmrigPath + '*'))
    })
}

function Test-MinerRunning {
    return (@(Get-MinerProcesses).Count -gt 0)
}

function Get-CpuTemp {
    param($Config)
    $url = [string]$Config['LHM_URL']
    try {
        $json = Invoke-RestMethod -Uri $url -TimeoutSec 4 -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Log -Component 'temp' -Message ("LHM unreachable: " + $_.Exception.Message)
        return $null
    }

    $stack = New-Object System.Collections.Stack
    $stack.Push($json)
    $candidates = @()
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }
        $props = $node.PSObject.Properties
        if ($props['Type'] -and $props['Type'].Value -eq 'Temperature') {
            $name = [string]$node.Text
            $raw  = [string]$node.RawValue
            $val = 0.0
            if ([double]::TryParse($raw, [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val)) {
                $score = 0
                if ($name -match 'CPU Package') { $score = 5 }
                elseif ($name -match 'CPU Total') { $score = 4 }
                elseif ($name -match 'Package') { $score = 3 }
                elseif ($name -match 'CPU') { $score = 2 }
                if ($score -gt 0) {
                    $candidates += [pscustomobject]@{ Score = $score; Name = $name; Value = $val }
                }
            }
        }
        if ($props['Children'] -and $node.Children) {
            foreach ($child in $node.Children) { $stack.Push($child) }
        }
    }
    if ($candidates.Count -eq 0) {
        Write-Log -Component 'temp' -Message 'No CPU temperature sensor found in LibreHardwareMonitor.'
        return $null
    }
    $best = $candidates | Sort-Object -Property Score -Descending | Select-Object -First 1
    return [double]$best.Value
}

function Wait-ForTemperature {
    param($Config, [int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $temp = Get-CpuTemp -Config $Config
        if ($null -ne $temp) { return $temp }
        Start-Sleep -Seconds 3
    }
    return $null
}

function Get-CoolingState {
    if (-not (Test-Path -LiteralPath $Script:CoolingFile)) { return 'normal' }
    $first = (Get-Content -LiteralPath $Script:CoolingFile -TotalCount 1) -split '\|'
    if ($first[0] -eq 'cooling') { return 'cooling' }
    return 'normal'
}

function Set-CoolingState {
    param([ValidateSet('normal', 'cooling')][string]$State, [string]$Temp = '-')
    Ensure-Dirs
    Set-Content -LiteralPath $Script:CoolingFile -Value ("{0}|{1}|{2}" -f $State, (Get-Date -Format o), $Temp) -Force
}

function Write-NextRestart {
    param($Config)
    Ensure-Dirs
    $minutes = [int]$Config['RESTART_MINUTES']
    if (Test-Path -LiteralPath $Script:WasActive) {
        $next = Get-UnixTime -Date (Get-Date).AddMinutes($minutes)
        Set-Content -LiteralPath $Script:NextFile -Value ("{0} {1}" -f $next, $minutes) -Force
    } else {
        Remove-Item -LiteralPath $Script:NextFile -Force -ErrorAction SilentlyContinue
    }
}

# PowerShell 5.1 has no ToUnixTimeSeconds(); use a small helper instead.
function Get-UnixTime {
    param([datetime]$Date = (Get-Date))
    return [int]([math]::Floor(($Date.ToUniversalTime() - [datetime]'1970-01-01T00:00:00Z').TotalSeconds))
}

function Set-WasActive {
    Ensure-Dirs
    Set-Content -LiteralPath $Script:WasActive -Value (Get-Date -Format o) -Force
}

function Clear-RuntimeState {
    Remove-Item -LiteralPath $Script:WasActive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Script:PidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Script:CoolingFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Script:NextFile -Force -ErrorAction SilentlyContinue
}
