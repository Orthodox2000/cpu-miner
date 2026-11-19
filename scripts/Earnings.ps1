# Unmineable balance with a 5-minute cache, like the Linux earnings.sh.
#   .\Earnings.ps1            friendly summary
#   .\Earnings.ps1 -Raw       ts-free fields: balance|threshold|percent|auto|age
#   .\Earnings.ps1 -Refresh   force a fresh network fetch

param([switch]$Raw, [switch]$Refresh)

. (Join-Path $PSScriptRoot 'Common.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Update-EarningsCache {
    $cfg = Get-Config
    $wallet = [string]$cfg['WALLET']
    if ([string]::IsNullOrWhiteSpace($wallet)) { return $false }
    $coin = [string]$cfg['PAYOUT_COIN']
    $url = 'https://api.unmineable.com/v5/address/{0}?coin={1}' -f $wallet, $coin
    try {
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        $data = $response.data
        $bal = [string]$data.balance
        $thr = [string]$data.payment_threshold
        if ([string]::IsNullOrWhiteSpace($bal)) { $bal = '0' }
        if ([string]::IsNullOrWhiteSpace($thr)) { $thr = '0' }
        $auto = if ($data.auto) { 'on' } else { 'off' }
        $pct = 0.0
        $b = 0.0; $t = 0.0
        if ([double]::TryParse($bal, [ref]$b) -and [double]::TryParse($thr, [ref]$t) -and $t -gt 0) {
            $pct = [math]::Min(100.0, [math]::Max(0.0, $b / $t * 100.0))
        }
        $line = '{0}|{1}|{2}|{3:F2}|{4}' -f (Get-UnixTime), $bal, $thr, $pct, $auto
        Set-Content -LiteralPath $Script:CacheFile -Value $line -Force
        return $true
    } catch {
        Write-Log -Component 'earnings' -Message ("fetch failed: " + $_.Exception.Message)
        return $false
    }
}

Ensure-Dirs
$cached = $null
if (Test-Path -LiteralPath $Script:CacheFile) {
    $cached = (Get-Content -LiteralPath $Script:CacheFile -TotalCount 1)
}
$age = 999999
$parts = @()
if ($cached) {
    $parts = $cached -split '\|'
    $ts = 0
    if ([int]::TryParse($parts[0], [ref]$ts)) { $age = (Get-UnixTime) - $ts }
}

if ($Refresh -or -not $cached -or $age -gt 300) {
    Update-EarningsCache | Out-Null
    if (Test-Path -LiteralPath $Script:CacheFile) {
        $cached = (Get-Content -LiteralPath $Script:CacheFile -TotalCount 1)
        $parts = $cached -split '\|'
        $ts = 0
        if ([int]::TryParse($parts[0], [ref]$ts)) { $age = (Get-UnixTime) - $ts }
    }
}

if (-not $cached -or $parts.Count -lt 5) {
    if ($Raw) { Write-Output '|||0|unknown'; exit 0 }
    Write-Host 'Earnings unavailable right now (network or Unmineable API).'
    exit 0
}

$bal = $parts[1]; $thr = $parts[2]; $pct = $parts[3]; $auto = $parts[4]
if ($Raw) {
    Write-Output ("{0}|{1}|{2}|{3}|{4}" -f $bal, $thr, $pct, $auto, $age)
    exit 0
}

$cfg = Get-Config
$coin = [string]$cfg['PAYOUT_COIN']
$payout = if ($auto -eq 'on') { 'automatic, daily at 13:00 UTC' } else { 'MANUAL - enable auto-pay on unmineable.com' }
Write-Host ("Earned so far : {0} {1}" -f $bal, $coin)
Write-Host ("Next payout   : {0} {1} ({2}% of the way there)" -f $thr, $coin, $pct)
Write-Host ("Payout mode   : {0}" -f $payout)
