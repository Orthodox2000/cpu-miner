# Wallet address validation (LTC and SOL). Windows PowerShell 5.1 compatible.
$script:B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
$script:BECH32 = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'

function ConvertFrom-Base58 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $n = [System.Numerics.BigInteger]::Zero
    foreach ($c in $Text.ToCharArray()) {
        $idx = $script:B58.IndexOf($c)
        if ($idx -lt 0) { throw 'Invalid Base58 character.' }
        $n = ($n * 58) + $idx
    }
    $bytes = @($n.ToByteArray())
    while ($bytes.Count -gt 1 -and $bytes[$bytes.Count - 1] -eq 0) {
        $bytes = $bytes[0..($bytes.Count - 2)]
    }
    [Array]::Reverse($bytes)
    $leading = 0
    foreach ($c in $Text.ToCharArray()) {
        if ($c -eq '1') { $leading++ } else { break }
    }
    $result = New-Object byte[] ($leading + $bytes.Count)
    if ($bytes.Count -gt 0) { [Array]::Copy($bytes, 0, $result, $leading, $bytes.Count) }
    return $result
}

function Get-DoubleSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $first = $sha.ComputeHash($Bytes)
        return $sha.ComputeHash($first)
    } finally {
        $sha.Dispose()
    }
}

function Test-LtcLegacy {
    param([string]$Address)
    if ($Address.Length -ne 34) { return $false }
    if (@('L', 'M', '3') -notcontains [string]$Address[0]) { return $false }
    try { $raw = @(ConvertFrom-Base58 -Text $Address) } catch { return $false }
    if ($raw.Count -ne 25) { return $false }
    $payload = New-Object byte[] 21
    [Array]::Copy($raw, 0, $payload, 0, 21)
    $calc = Get-DoubleSha256 -Bytes $payload
    for ($i = 0; $i -lt 4; $i++) {
        if ($calc[$i] -ne $raw[21 + $i]) { return $false }
    }
    return $true
}

function Test-LtcBech32 {
    param([string]$Address)
    $low = $Address.ToLowerInvariant()
    $pos = $low.LastIndexOf('1')
    if ($pos -lt 1 -or $pos -ge ($low.Length - 1)) { return $false }
    $hrp = $low.Substring(0, $pos)
    $data = $low.Substring($pos + 1)
    if ($data.Length -lt 7) { return $false }
    foreach ($c in $data.ToCharArray()) {
        if ($script:BECH32.IndexOf($c) -lt 0) { return $false }
    }
    $gen = @(0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3)
    $chk = 1
    $values = @()
    foreach ($c in $hrp.ToCharArray()) { $values += ([int][char]$c -shr 5) }
    $values += 0
    foreach ($c in $hrp.ToCharArray()) { $values += ([int][char]$c -band 31) }
    foreach ($c in $data.ToCharArray()) { $values += $script:BECH32.IndexOf($c) }
    foreach ($v in $values) {
        $top = $chk -shr 25
        $chk = (($chk -band 0x1FFFFFF) -shl 5) -bxor $v
        for ($i = 0; $i -lt 5; $i++) {
            if ((($top -shr $i) -band 1) -eq 1) { $chk = $chk -bxor $gen[$i] }
        }
    }
    return ($chk -eq 1 -or $chk -eq 0x2BC830A3)
}

function Test-SolAddress {
    param([string]$Address)
    if ($Address.Length -lt 32 -or $Address.Length -gt 44) { return $false }
    foreach ($c in $Address.ToCharArray()) {
        if ($script:B58.IndexOf($c) -lt 0) { return $false }
    }
    try { $raw = @(ConvertFrom-Base58 -Text $Address) } catch { return $false }
    return ($raw.Count -eq 32)
}

function Test-WalletAddress {
    param(
        [Parameter(Mandatory = $true)][string]$Coin,
        [Parameter(Mandatory = $true)][string]$Address
    )
    $address = $Address.Trim()
    switch ($Coin.ToUpperInvariant()) {
        'LTC' {
            if ($address.ToLowerInvariant().StartsWith('ltc1')) {
                return Test-LtcBech32 -Address $address
            }
            return Test-LtcLegacy -Address $address
        }
        'SOL' { return Test-SolAddress -Address $address }
        default {
            Write-Warning ('Validation for coin {0} is not implemented in PowerShell; install the Python validator to use it.' -f $Coin)
            return $false
        }
    }
}
