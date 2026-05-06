# (c) JFrog Ltd. (2026)
# Auto-Extract certificate from Windows store (or use existing PEM) and configure Node/npm and/or pip for Windows
# Run: powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package all -CertName Zscaler -ExtractPath Zscaler\npm
#   Or: powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package all -UseCert C:\path\to\ca.pem
#
# Parameters:
#   -Package npm|pip|all   What to configure: npm, pip (UV_NATIVE_TLS, REQUESTS_CA_BUNDLE, HF Hub vars), or all (default: all)
#   -CertName <pattern>    Substring to match cert subject (errors if 0 or >1 match). Requires -ExtractPath. Cannot be used with -UseCert.
#   -ExtractPath <path>    Directory for the PEM (writes <path>\package-route.pem); relative to each user's profile or absolute. Requires -CertName.
#   -UseCert <path>        Path to an existing PEM cert file. Cannot be used with -CertName/-ExtractPath.
#
# Either (-CertName AND -ExtractPath) OR -UseCert must be provided.
# If user had a different env path, it is replaced with the new path; new PEM is first, other PEMs from the old file are appended (dedupe by fingerprint).
#
# Must run as Administrator (or SYSTEM). Exits with error otherwise.
# When run as SYSTEM/admin with -CertName: installs PEM and User-level env per user (each user's profile).
# When run with -UseCert: sets Machine-level env to that path; no per-user PEM.

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("npm", "pip", "all")]
    [string]$Package = "all",

    [Parameter(ParameterSetName = "Extract", Mandatory = $true)]
    [string]$CertName,

    [Parameter(ParameterSetName = "Extract", Mandatory = $true)]
    [string]$ExtractPath,

    [Parameter(ParameterSetName = "UseCert", Mandatory = $true)]
    [string]$UseCert
)

$ErrorActionPreference = 'Stop'

$isSystemContext = ($env:USERNAME -eq 'SYSTEM') -or ($env:USERPROFILE -like '*systemprofile*')
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not ($isSystemContext -or $isAdmin)) {
    Write-Error "Error: this script must be run as Administrator. Run PowerShell as Administrator (e.g. right-click -> Run as administrator)."
    exit 1
}

# UTF-8 without BOM so PEM starts with "-----BEGIN" (Set-Content -Encoding UTF8 adds BOM on PowerShell 5.1 and breaks parsing).
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function DoNpm { $Package -eq 'npm' -or $Package -eq 'all' }
function DoPip { $Package -eq 'pip' -or $Package -eq 'all' }

# --- PEM helpers (align with macOS: validate, fingerprint, blocks, merge) ---

# Parse PEM file into list of PEM block strings (each between BEGIN/END CERTIFICATE).
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

# Get DER bytes from a single PEM block string.
function Get-DerFromPemBlock {
    param([string]$PemBlock)
    if ([string]::IsNullOrEmpty($PemBlock)) { return $null }
    $m = [regex]::Match($PemBlock, '(?s)-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----')
    if (-not $m.Success) { return $null }
    $b64 = $m.Groups[1].Value.Trim() -replace '\s', ''
    try {
        return [System.Convert]::FromBase64String($b64)
    } catch { return $null }
}

# Load X509Certificate2 from PEM block (works on .NET Framework and .NET Core).
function Get-CertFromPemBlock {
    param([string]$PemBlock)
    $der = Get-DerFromPemBlock -PemBlock $PemBlock
    if (-not $der) { return $null }
    try {
        return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,[byte[]]$der)
    } catch { return $null }
}

# SHA-256 fingerprint of a PEM block (hex string, no separators) for dedupe. Same idea as macOS openssl x509 -fingerprint -sha256.
function Get-PemFingerprint {
    param([string]$PemBlock)
    $cert = Get-CertFromPemBlock -PemBlock $PemBlock
    if (-not $cert) { return $null }
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($cert.RawData)
    return [BitConverter]::ToString($hash).Replace("-", "")
}

# Validate file exists and contains at least one valid PEM cert. Uses same read/regex/decode path as test_pem_validation_windows.ps1.
function Test-ValidPemFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $m = [regex]::Match($text, '(?s)-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----')
    if (-not $m.Success) { return $false }
    $block = "-----BEGIN CERTIFICATE-----`n" + $m.Groups[1].Value.Trim() + "`n-----END CERTIFICATE-----"
    $m2 = [regex]::Match($block, '(?s)-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----')
    if (-not $m2.Success) { return $false }
    $b64 = $m2.Groups[1].Value.Trim() -replace '\s', ''
    try {
        $der = [System.Convert]::FromBase64String($b64)
        $null = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,[byte[]]$der)
        return $true
    } catch { return $false }
}

# True if bundle file already contains a cert with the same fingerprint.
function Test-BundleContainsPem {
    param([string]$BundlePath, [string]$PemBlock)
    $ourFp = Get-PemFingerprint -PemBlock $PemBlock
    if (-not $ourFp) { return $false }
    if (-not (Test-Path -LiteralPath $BundlePath -PathType Leaf)) { return $false }
    $blocks = Get-PemBlocksFromFile -Path $BundlePath
    foreach ($b in $blocks) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        $fp = Get-PemFingerprint -PemBlock $b
        if ($fp -eq $ourFp) { return $true }
    }
    return $false
}

# Merge certs from source file into target path: append blocks that are not our cert and not already in target. Dedupe by fingerprint.
function Merge-CertsIntoTarget {
    param([string]$SourceFile, [string]$TargetPath, [string]$OurPemBlock, [string]$DisplayName = "")
    if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) { return 0 }
    if ((Get-Item -LiteralPath $SourceFile).Length -eq 0) { return 0 }
    $ourFp = Get-PemFingerprint -PemBlock $OurPemBlock
    if (-not $ourFp) { return 0 }
    $blocks = Get-PemBlocksFromFile -Path $SourceFile
    $appended = 0
    $name = if ($DisplayName) { $DisplayName } else { [System.IO.Path]::GetFileName($SourceFile) }
    $targetName = [System.IO.Path]::GetFileName($TargetPath)
    Write-Host "   [merge] reading cert blocks from $name into $targetName"
    foreach ($b in $blocks) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        $fp = Get-PemFingerprint -PemBlock $b
        if (-not $fp) { continue }
        if ($fp -eq $ourFp) { continue }
        if (Test-BundleContainsPem -BundlePath $TargetPath -PemBlock $b) { continue }
        [System.IO.File]::AppendAllText($TargetPath, "`n$b", $utf8NoBom)
        $appended++
    }
    if ($appended -gt 0) { Write-Host "   [merge] $appended cert(s) appended from $name" }
    return $appended
}

# Normalize path for comparison: trim, forward slashes to backslash, trim trailing slash (Windows).
function Get-NormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $p = $Path.Trim() -replace '/', '\'
    $p = $p.TrimEnd('\')
    return $p
}

# True if two paths refer to the same file (case-insensitive, normalized).
function Test-SamePath {
    param([string]$Path1, [string]$Path2)
    if ([string]::IsNullOrWhiteSpace($Path1) -or [string]::IsNullOrWhiteSpace($Path2)) { return $false }
    $n1 = Get-NormalizedPath -Path $Path1
    $n2 = Get-NormalizedPath -Path $Path2
    return [string]::Equals($n1, $n2, [StringComparison]::OrdinalIgnoreCase)
}

# Write target with new PEM first, then merge from each old path (dedupe). If we overwrote an existing file, always merge from the saved copy so re-runs keep multiple certs even when registry path format differs from our target path.
function Write-MergedPemFile {
    param([string]$TargetPath, [string]$NewPem, [string[]]$OldPaths)
    $TargetPath = [System.IO.Path]::GetFullPath($TargetPath)
    $savedTarget = $null
    if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
        $content = [System.IO.File]::ReadAllText($TargetPath, $utf8NoBom)
        if ($content.Length -gt 0) { $savedTarget = [System.IO.Path]::GetTempFileName(); [System.IO.File]::WriteAllText($savedTarget, $content, $utf8NoBom) }
    }
    [System.IO.File]::WriteAllText($TargetPath, $NewPem, $utf8NoBom)
    # Always merge from saved copy when we overwrote an existing bundle (re-run scenario). Do not rely on OldPaths matching target path (registry may store 8.3 or different casing).
    if ($savedTarget -and (Test-Path -LiteralPath $savedTarget -PathType Leaf)) {
        Write-Host "   [merge] appending certs from previous bundle at $TargetPath"
        Merge-CertsIntoTarget -SourceFile $savedTarget -TargetPath $TargetPath -OurPemBlock $NewPem -DisplayName "previous bundle" | Out-Null
    }
    # Merge from any other env-configured PEM files (different path than target).
    foreach ($p in $OldPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (Test-SamePath -Path1 $p -Path2 $TargetPath) { continue }
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $len = (Get-Item -LiteralPath $p).Length
            if ($len -gt 0) { Merge-CertsIntoTarget -SourceFile $p -TargetPath $TargetPath -OurPemBlock $NewPem -DisplayName ([System.IO.Path]::GetFileName($p)) | Out-Null }
        }
    }
    if ($savedTarget -and (Test-Path -LiteralPath $savedTarget -PathType Leaf)) { Remove-Item -LiteralPath $savedTarget -Force -ErrorAction SilentlyContinue }
}

# Get current env var value for the given scope (Machine or User).
function Get-EnvPath {
    param([string]$VarName, [string]$Scope)
    $val = [Environment]::GetEnvironmentVariable($VarName, $Scope)
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    $val = $val.Trim().Trim('"').Trim("'")
    return $val
}

# Get User env paths (NODE_EXTRA_CA_CERTS, REQUESTS_CA_BUNDLE) for a user by loading their registry hive. Returns array of existing file paths.
function Get-UserEnvCertPaths {
    param([string]$ProfilePath, [string]$Scope)
    if ($Scope -eq "Machine") { return @() }
    $paths = @()
    $nodePath = Get-EnvPath -VarName "NODE_EXTRA_CA_CERTS" -Scope "User"
    $pipPath = Get-EnvPath -VarName "REQUESTS_CA_BUNDLE" -Scope "User"
    if ($nodePath -and (Test-Path -LiteralPath $nodePath -PathType Leaf) -and $paths -notcontains $nodePath) { $paths += $nodePath }
    if ($pipPath -and (Test-Path -LiteralPath $pipPath -PathType Leaf) -and $paths -notcontains $pipPath) { $paths += $pipPath }
    return $paths
}

# Get SID for a user profile path (e.g. C:\Users\Administrator). Returns $null if not found.
function Get-UserSidFromProfile {
    param([string]$ProfilePath)
    try {
        $prof = Get-WmiObject Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath -eq $ProfilePath } | Select-Object -First 1
        if ($prof) { return $prof.SID }
    } catch { }
    return $null
}

# Get User env cert paths from another user's registry. If hive already loaded (user logged in), use HKU\<SID>. Else load NTUSER.DAT.
function Get-OtherUserEnvCertPaths {
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
            if ($nodePath -and (Test-Path -LiteralPath $nodePath -PathType Leaf) -and $paths -notcontains $nodePath) { $paths += $nodePath }
            if ($pipPath -and (Test-Path -LiteralPath $pipPath -PathType Leaf) -and $paths -notcontains $pipPath) { $paths += $pipPath }
        }
    } finally {
        if ($weLoaded -and $tempKey) { & reg.exe unload "HKU\$tempKey" 2>&1 | Out-Null }
    }
    return $paths
}

# Set User env vars for another user. If hive already loaded use HKU\<SID>; else load NTUSER.DAT.
function Set-OtherUserEnvVars {
    param([string]$ProfilePath, [string]$CertPath, [bool]$DoNpm, [bool]$DoPip)
    $sid = Get-UserSidFromProfile -ProfilePath $ProfilePath
    $keyPath = $null
    $weLoaded = $false
    $tempKey = $null
    if ($sid -and (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid" -ErrorAction SilentlyContinue)) {
        $keyPath = "Registry::HKEY_USERS\$sid\Environment"
    } else {
        $ntuser = Join-Path $ProfilePath "NTUSER.DAT"
        if (-not (Test-Path -LiteralPath $ntuser -PathType Leaf)) { return }
        $tempKey = "temp_env_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        $result = & reg.exe load "HKU\$tempKey" "$ntuser" 2>&1
        if ($LASTEXITCODE -ne 0) { return }
        $weLoaded = $true
        $keyPath = "Registry::HKEY_USERS\$tempKey\Environment"
    }
    try {
        if (-not (Test-Path -LiteralPath $keyPath)) { New-Item -Path $keyPath -Force | Out-Null }
        if ($DoNpm) {
            Set-ItemProperty -Path $keyPath -Name "NODE_USE_SYSTEM_CA" -Value "1" -Type String -Force
            Set-ItemProperty -Path $keyPath -Name "NODE_EXTRA_CA_CERTS" -Value $CertPath -Type String -Force
        }
        if ($DoPip) {
            Set-ItemProperty -Path $keyPath -Name "UV_NATIVE_TLS" -Value "1" -Type String -Force
            Set-ItemProperty -Path $keyPath -Name "REQUESTS_CA_BUNDLE" -Value $CertPath -Type String -Force
            Set-ItemProperty -Path $keyPath -Name "HF_HUB_DISABLE_XET" -Value "1" -Type String -Force
            Set-ItemProperty -Path $keyPath -Name "HF_HUB_ETAG_TIMEOUT" -Value "86400" -Type String -Force
            Set-ItemProperty -Path $keyPath -Name "HF_HUB_DOWNLOAD_TIMEOUT" -Value "86400" -Type String -Force
        }
    } finally {
        if ($weLoaded -and $tempKey) { & reg.exe unload "HKU\$tempKey" 2>&1 | Out-Null }
    }
}

# --- Context and paths ---

Write-Host "--- Certificate installation and configuring ($Package) ---"

if ($PSCmdlet.ParameterSetName -eq "UseCert") {
    if (-not (Test-Path -LiteralPath $UseCert -PathType Leaf)) {
        Write-Host "[Error] -UseCert path is not a file: $UseCert" -ForegroundColor Red
        exit 1
    }
    if (-not (Test-ValidPemFile -Path $UseCert)) {
        Write-Host "[Error] Invalid or missing PEM at: $UseCert" -ForegroundColor Red
        exit 1
    }
    Write-Host "[1/3] Using existing certificate at $UseCert..."
} else {
    # Validate CertName + ExtractPath
    if ([string]::IsNullOrWhiteSpace($CertName) -or [string]::IsNullOrWhiteSpace($ExtractPath)) {
        Write-Host "[Error] -CertName and -ExtractPath are required when not using -UseCert." -ForegroundColor Red
        exit 1
    }
}

$certStore = if ($isSystemContext -or $isAdmin) { "LocalMachine" } else { "CurrentUser" }

# --- Extract from store (when -CertName -ExtractPath): get PEM once ---

$extractedPem = $null
if ($PSCmdlet.ParameterSetName -eq "Extract") {
    Write-Host "[1/3] Extracting certificate (CertName pattern=$CertName)..."
    $pattern = "*$CertName*"
    $root = "Cert:\$certStore\Root"
    $certs = @()
    if (Test-Path $root) {
        $certs = @(Get-ChildItem $root -ErrorAction SilentlyContinue | Where-Object { $_.Subject -like $pattern })
    }
    if ($certs.Count -eq 0) {
        Write-Host "[Error] No certificate in store ($certStore\Root) matched pattern: $CertName" -ForegroundColor Red
        exit 1
    }
    if ($certs.Count -gt 1) {
        $rootCert = $certs | Where-Object { $_.Subject -like "*Root*" } | Select-Object -First 1
        if ($rootCert) { $cert = $rootCert } else { $cert = $certs[0] }
        Write-Host "[Warning] Multiple certificates matched in $certStore\Root; using: $($cert.Subject)"
    } else {
        $cert = $certs[0]
    }
    $extractedPem = "-----BEGIN CERTIFICATE-----`n" + [System.Convert]::ToBase64String($cert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks) + "`n-----END CERTIFICATE-----"
}

# --- Per-user install when Extract: PEM and User env per user ---

# Under each user's profile: strip leading slashes; if path is absolute, use path relative to drive so we still get per-user dir (e.g. C:\certs -> certs).
$extractPathTrim = $ExtractPath.TrimStart('\', '/')
if ([System.IO.Path]::IsPathRooted($extractPathTrim)) {
    $extractPathTrim = $extractPathTrim.TrimStart([System.IO.Path]::GetPathRoot($extractPathTrim)).TrimStart('\', '/')
}
if ([string]::IsNullOrWhiteSpace($extractPathTrim)) { $extractPathTrim = "certs" }

if ($PSCmdlet.ParameterSetName -eq "Extract" -and $null -ne $extractedPem) {
    if ($isSystemContext -or $isAdmin) {
        Write-Host "[2/3] Installing cert and User-level env per user (each user's profile)..."
        $userDirs = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public', 'Default', 'Default User') }
        foreach ($ud in $userDirs) {
            $userHome = $ud.FullName
            $certDir = Join-Path $userHome $extractPathTrim
            $certPath = Join-Path $certDir "package-route.pem"
            $oldPaths = Get-OtherUserEnvCertPaths -ProfilePath $userHome
            if (-not (Test-Path $certDir)) { New-Item -ItemType Directory -Path $certDir -Force | Out-Null }
            Write-MergedPemFile -TargetPath $certPath -NewPem $extractedPem -OldPaths $oldPaths
            if (-not (Test-ValidPemFile -Path $certPath)) {
                Write-Host "[Error] Extracted PEM file is invalid: $certPath" -ForegroundColor Red
                exit 1
            }
            Set-OtherUserEnvVars -ProfilePath $userHome -CertPath $certPath -DoNpm:(DoNpm) -DoPip:(DoPip)
            Write-Host "   + $userHome : $certPath"
        }
    } else {
        Write-Host "[2/3] Installing cert and User-level env for current user..."
        $certDir = Join-Path $env:USERPROFILE $extractPathTrim
        $certPath = Join-Path $certDir "package-route.pem"
        $oldPaths = Get-UserEnvCertPaths -ProfilePath $env:USERPROFILE -Scope "User"
        if (-not (Test-Path $certDir)) { New-Item -ItemType Directory -Path $certDir -Force | Out-Null }
        Write-MergedPemFile -TargetPath $certPath -NewPem $extractedPem -OldPaths $oldPaths
        if (-not (Test-ValidPemFile -Path $certPath)) {
            Write-Host "[Error] Extracted PEM file is invalid: $certPath" -ForegroundColor Red
            exit 1
        }
        if (DoNpm) {
            [Environment]::SetEnvironmentVariable("NODE_USE_SYSTEM_CA", "1", "User")
            [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $certPath, "User")
        }
        if (DoPip) {
            [Environment]::SetEnvironmentVariable("UV_NATIVE_TLS", "1", "User")
            [Environment]::SetEnvironmentVariable("REQUESTS_CA_BUNDLE", $certPath, "User")
            [Environment]::SetEnvironmentVariable("HF_HUB_DISABLE_XET", "1", "User")
            [Environment]::SetEnvironmentVariable("HF_HUB_ETAG_TIMEOUT", "86400", "User")
            [Environment]::SetEnvironmentVariable("HF_HUB_DOWNLOAD_TIMEOUT", "86400", "User")
        }
        Write-Host "   + NODE_USE_SYSTEM_CA and NODE_EXTRA_CA_CERTS set."
        Write-Host "   + UV_NATIVE_TLS set; REQUESTS_CA_BUNDLE set to $certPath"
        if (DoPip) { Write-Host "   + Hugging Face Hub timeouts / HF_HUB_DISABLE_XET set." }
    }
    # Only clear the other scope after new User vars are set (above); on failure we exit 1 before reaching here.
    # Extract = per-user cert; clear Machine-level cert vars so only User applies (avoids confusing duplication with old -UseCert).
    if (DoNpm) {
        [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $null, "Machine")
        [Environment]::SetEnvironmentVariable("NODE_USE_SYSTEM_CA", $null, "Machine")
    }
    if (DoPip) {
        [Environment]::SetEnvironmentVariable("UV_NATIVE_TLS", $null, "Machine")
        [Environment]::SetEnvironmentVariable("REQUESTS_CA_BUNDLE", $null, "Machine")
        [Environment]::SetEnvironmentVariable("HF_HUB_DISABLE_XET", $null, "Machine")
        [Environment]::SetEnvironmentVariable("HF_HUB_ETAG_TIMEOUT", $null, "Machine")
        [Environment]::SetEnvironmentVariable("HF_HUB_DOWNLOAD_TIMEOUT", $null, "Machine")
    }
    Write-Host "   + Cleared Machine-level cert vars so only User settings apply."
}

# --- UseCert: set env once (Machine if admin, User if not) ---

if ($PSCmdlet.ParameterSetName -eq "UseCert") {
    $envScope = if ($isSystemContext -or $isAdmin) { "Machine" } else { "User" }
    Write-Host "[2/3] Setting Environment Variables ($envScope)..."
    if (DoNpm) {
        [Environment]::SetEnvironmentVariable("NODE_USE_SYSTEM_CA", "1", $envScope)
        [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $UseCert, $envScope)
        Write-Host "   + NODE_USE_SYSTEM_CA and NODE_EXTRA_CA_CERTS set."
    }
    if (DoPip) {
        [Environment]::SetEnvironmentVariable("UV_NATIVE_TLS", "1", $envScope)
        [Environment]::SetEnvironmentVariable("REQUESTS_CA_BUNDLE", $UseCert, $envScope)
        [Environment]::SetEnvironmentVariable("HF_HUB_DISABLE_XET", "1", $envScope)
        [Environment]::SetEnvironmentVariable("HF_HUB_ETAG_TIMEOUT", "86400", $envScope)
        [Environment]::SetEnvironmentVariable("HF_HUB_DOWNLOAD_TIMEOUT", "86400", $envScope)
        Write-Host "   + UV_NATIVE_TLS set; REQUESTS_CA_BUNDLE set to $UseCert"
        Write-Host "   + HF_HUB_DISABLE_XET and HF Hub timeouts set."
    }
    # Only clear the other scope after new vars are set above (so we never leave user with no cert vars on failure).
    # When setting Machine, remove User-level cert vars so they don't override (User wins over Machine on Windows).
    if ($envScope -eq "Machine") {
        if (DoNpm) {
            [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $null, "User")
            [Environment]::SetEnvironmentVariable("NODE_USE_SYSTEM_CA", $null, "User")
        }
        if (DoPip) {
            [Environment]::SetEnvironmentVariable("UV_NATIVE_TLS", $null, "User")
            [Environment]::SetEnvironmentVariable("REQUESTS_CA_BUNDLE", $null, "User")
            [Environment]::SetEnvironmentVariable("HF_HUB_DISABLE_XET", $null, "User")
            [Environment]::SetEnvironmentVariable("HF_HUB_ETAG_TIMEOUT", $null, "User")
            [Environment]::SetEnvironmentVariable("HF_HUB_DOWNLOAD_TIMEOUT", $null, "User")
        }
        Write-Host "   + Cleared User-level cert vars so Machine settings apply."
    }
}

Write-Host "---------------------------------------------------"
Write-Host "[3/3] COMPLETE!"
Write-Host ""
if ($PSCmdlet.ParameterSetName -eq "UseCert") {
    Write-Host "Using existing cert at $UseCert. Users must start new terminals to pick up changes."
} elseif ($isSystemContext -or $isAdmin) {
    Write-Host "Certificate exported to each user's profile (package-route.pem). User-level env set per user. Users must start new terminals to pick up changes."
} else {
    Write-Host "Certificate: $certPath"
    Write-Host "Please restart your terminal for changes to take effect."
}
