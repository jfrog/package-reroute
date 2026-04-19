# (c) JFrog Ltd. (2026)
# Validate certificate installation: PEM file(s) exist and are valid; require subject match.
# See README for usage. -ExpectedSubject is required. Exit 0 = all checks passed.

param(
    [switch]$AllUsers,
    [string]$ExpectedSubject = ""
)

$ErrorActionPreference = 'Stop'
$script:FailCount = 0

if ([string]::IsNullOrWhiteSpace($ExpectedSubject)) {
    Write-Error "Error: -ExpectedSubject is required."
    exit 1
}

# Validate file exists and contains at least one valid PEM cert (same logic as install_certs_windows.ps1).
function Test-ValidPemFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $m = [regex]::Match($text, '(?s)-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----')
    if (-not $m.Success) { return $false }
    $b64 = $m.Groups[1].Value.Trim() -replace '\s', ''
    try {
        $der = [System.Convert]::FromBase64String($b64)
        $null = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,[byte[]]$der)
        return $true
    } catch { return $false }
}

# Get all PEM blocks from a file (same regex as install script).
function Get-PemBlocksFromFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $blocks = @()
    $regex = [regex]'(?s)-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----'
    foreach ($m in $regex.Matches($text)) {
        $b = "-----BEGIN CERTIFICATE-----`n" + $m.Groups[1].Value.Trim() + "`n-----END CERTIFICATE-----"
        $blocks += $b
    }
    return $blocks
}

# Get subject string from a PEM block (null if decode fails).
function Get-SubjectFromPemBlock {
    param([string]$PemBlock)
    $m = [regex]::Match($PemBlock, '(?s)-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----')
    if (-not $m.Success) { return $null }
    $b64 = $m.Groups[1].Value.Trim() -replace '\s', ''
    try {
        $der = [System.Convert]::FromBase64String($b64)
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,[byte[]]$der)
        return $cert.Subject
    } catch { return $null }
}

function Validate-Pem {
    param([string]$Path, [string]$Label = $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host "  FAIL: file does not exist: $Path" -ForegroundColor Red
        $script:FailCount++
        return $false
    }
    if (-not (Test-ValidPemFile -Path $Path)) {
        Write-Host "  FAIL: not a valid PEM certificate (or bundle): $Path" -ForegroundColor Red
        $script:FailCount++
        return $false
    }
    $blocks = Get-PemBlocksFromFile -Path $Path
    $found = $false
    foreach ($block in $blocks) {
        $subject = Get-SubjectFromPemBlock -PemBlock $block
        if ($subject -and $subject.IndexOf($ExpectedSubject, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $found = $true
            break
        }
    }
    if (-not $found) {
        Write-Host "  FAIL: no cert in $Path has subject matching: $ExpectedSubject" -ForegroundColor Red
        $script:FailCount++
        return $false
    }
    Write-Host "  OK: valid PEM at $Path"
    return $true
}

# Get effective cert paths for current user (User overrides Machine on Windows).
function Get-CurrentUserCertPaths {
    $paths = @()
    foreach ($var in @("NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE")) {
        $val = [Environment]::GetEnvironmentVariable($var, "User")
        if ([string]::IsNullOrWhiteSpace($val)) { $val = [Environment]::GetEnvironmentVariable($var, "Machine") }
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            $val = $val.Trim().Trim('"').Trim("'")
            if ($val -and $paths -notcontains $val) { $paths += $val }
        }
    }
    return $paths
}

# Get SID for a user profile path.
function Get-UserSidFromProfile {
    param([string]$ProfilePath)
    try {
        $prof = Get-WmiObject Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath -eq $ProfilePath } | Select-Object -First 1
        if ($prof) { return $prof.SID }
    } catch { }
    return $null
}

# Get cert paths from another user's registry (User env only; Machine is shared).
function Get-OtherUserCertPaths {
    param([string]$ProfilePath)
    $paths = @()
    $sid = Get-UserSidFromProfile -ProfilePath $ProfilePath
    $keyPath = $null
    $weLoaded = $false
    $tempKey = $null
    if ($sid -and (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid\Environment" -ErrorAction SilentlyContinue)) {
        $keyPath = "Registry::HKEY_USERS\$sid\Environment"
    } else {
        $ntuser = Join-Path $ProfilePath "NTUSER.DAT"
        if (-not (Test-Path -LiteralPath $ntuser -PathType Leaf)) { return $paths }
        $tempKey = "temp_env_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        $result = & reg.exe load "HKU\$tempKey" "$ntuser" 2>&1
        if ($LASTEXITCODE -ne 0) { return $paths }
        $weLoaded = $true
        $keyPath = "Registry::HKEY_USERS\$tempKey\Environment"
    }
    try {
        if (Test-Path -LiteralPath $keyPath) {
            $nodePath = (Get-ItemProperty -Path $keyPath -Name "NODE_EXTRA_CA_CERTS" -ErrorAction SilentlyContinue).NODE_EXTRA_CA_CERTS
            $pipPath = (Get-ItemProperty -Path $keyPath -Name "REQUESTS_CA_BUNDLE" -ErrorAction SilentlyContinue).REQUESTS_CA_BUNDLE
            foreach ($p in @($nodePath, $pipPath)) {
                if (-not [string]::IsNullOrWhiteSpace($p)) {
                    $p = $p.Trim().Trim('"').Trim("'")
                    if ($p -and $paths -notcontains $p) { $paths += $p }
                }
            }
        }
    } finally {
        if ($weLoaded -and $tempKey) { & reg.exe unload "HKU\$tempKey" 2>&1 | Out-Null }
    }
    return $paths
}

# --- Main ---

if ($AllUsers) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "Error: -AllUsers requires admin. Run as Administrator." -ForegroundColor Red
        exit 1
    }
    Write-Host "Validating all users' config and cert paths..."
    $userDirs = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public', 'Default', 'Default User') }
    foreach ($ud in $userDirs) {
        $userHome = $ud.FullName
        $paths = Get-OtherUserCertPaths -ProfilePath $userHome
        if ($paths.Count -eq 0) {
            Write-Host "  SKIP: user $($ud.Name) has no NODE_EXTRA_CA_CERTS or REQUESTS_CA_BUNDLE set"
            continue
        }
        Write-Host "  Checking user $($ud.Name)..."
        foreach ($p in $paths) {
            Validate-Pem -Path $p | Out-Null
        }
    }
} else {
    Write-Host "Validating current user config (env) and cert path(s)..."
    $paths = Get-CurrentUserCertPaths
    if ($paths.Count -eq 0) {
        Write-Host "  WARN: no NODE_EXTRA_CA_CERTS or REQUESTS_CA_BUNDLE set for current user"
    } else {
        foreach ($p in $paths) {
            Validate-Pem -Path $p | Out-Null
        }
    }
}

Write-Host "---------------------------------------------------"
if ($script:FailCount -eq 0) {
    Write-Host "Result: All checks passed."
    exit 0
} else {
    Write-Host "Result: $($script:FailCount) check(s) failed." -ForegroundColor Red
    exit 1
}
