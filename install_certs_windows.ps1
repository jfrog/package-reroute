# (c) JFrog Ltd. (2026)
# Export Windows trust-store CAs and configure Node/npm, Python, and/or Ruby for redirect-proxy usage.
# Run: powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package all -ExtractPath certs\npm
#   Or: powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package all -UseCert C:\path\to\ca.pem
#
# Parameters:
#   -Package npm|python|huggingface|ruby|all
#     npm / python / huggingface / ruby / all (all = npm + Python TLS + Ruby + Hugging Face Hub)
#   -ExtractPath <path>    Directory for the PEM (writes <path>\package-route.pem); relative to each
#                          user's profile or absolute. Full export of Windows trust stores (Root,
#                          AuthRoot, and Intermediate CA stores) — system roots, enterprise CAs, and
#                          intermediates (e.g. NetSkope signing CAs). Cannot be used with -UseCert.
#   -UseCert <path>        Path to an existing PEM cert file. Sets env vars to point at this file; does
#                          not touch the cert store. Cannot be used with -ExtractPath.
#
# Either -ExtractPath OR -UseCert must be provided (exactly one).
#
# Must run as Administrator (or SYSTEM). Exits with error otherwise.
# When run as SYSTEM/admin with -ExtractPath: installs PEM and User-level env per user (each user's profile).
# When run with -UseCert: sets Machine-level env (admin) pointing at the supplied PEM.
# Also performs best-effort Docker Hub credential cleanup for the current user.

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("npm", "python", "huggingface", "ruby", "all")]
    [string]$Package = "all",

    [Parameter(Mandatory = $false)]
    [string]$ExtractPath,

    [Parameter(Mandatory = $false)]
    [string]$UseCert
)

$ErrorActionPreference = 'Stop'

$isSystemContext = ($env:USERNAME -eq 'SYSTEM') -or ($env:USERPROFILE -like '*systemprofile*')
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not ($isSystemContext -or $isAdmin)) {
    Write-Error "Error: this script must be run as Administrator. Run PowerShell as Administrator (e.g. right-click -> Run as administrator)."
    exit 1
}

$hasExtractPath = -not [string]::IsNullOrWhiteSpace($ExtractPath)
$hasUseCert = -not [string]::IsNullOrWhiteSpace($UseCert)
if ($hasUseCert -and $hasExtractPath) {
    Write-Host "[Error] -UseCert and -ExtractPath cannot be used together." -ForegroundColor Red
    exit 1
}
if (-not $hasUseCert -and -not $hasExtractPath) {
    Write-Host "[Error] either -ExtractPath or -UseCert must be provided." -ForegroundColor Red
    exit 1
}
$certMode = if ($hasUseCert) { "UseCert" } else { "Extract" }

# UTF-8 without BOM so PEM starts with "-----BEGIN" (Set-Content -Encoding UTF8 adds BOM on PowerShell 5.1 and breaks parsing).
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function DoNpm { $Package -eq 'npm' -or $Package -eq 'all' }
function DoPythonTls { $Package -eq 'python' -or $Package -eq 'huggingface' -or $Package -eq 'all' }
function DoHuggingface { $Package -eq 'huggingface' -or $Package -eq 'all' }
function DoRuby { $Package -eq 'ruby' -or $Package -eq 'all' }

$DockerHubKeys = @(
    "https://index.docker.io/v1/",
    "index.docker.io",
    "docker.io",
    "https://registry-1.docker.io/",
    "registry-1.docker.io"
)

function Get-DockerCommandPath {
    $candidates = @()
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe")
    }
    if ($env:ProgramW6432 -and $env:ProgramW6432 -ne $env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramW6432 "Docker\Docker\resources\bin\docker.exe")
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $cmd = Get-Command docker -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-DockerHubCredentialCleanup {
    Write-Host "[3/4] Clearing Docker Hub credentials for the current user..."

    if ($isSystemContext) {
        Write-Warning "Skipping Docker credential cleanup while running as SYSTEM; run this step in the user's Windows session."
        return
    }

    $docker = Get-DockerCommandPath
    if ($docker) {
        foreach ($key in $DockerHubKeys) {
            try {
                $output = (& $docker logout $key 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "docker logout '$key' failed; continuing. $output"
                }
            } catch {
                Write-Warning "docker logout '$key' failed; continuing. $($_.Exception.Message)"
            }
        }
        Write-Host "   + Docker Hub credentials cleared (if any were present)."
        return
    }

    Write-Host "   + Docker CLI not found, skipping credential cleanup."
}

# --- PEM helpers (align with macOS: validate, fingerprint, blocks) ---

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

function Get-CertFromPemBlock {
    param([string]$PemBlock)
    $der = Get-DerFromPemBlock -PemBlock $PemBlock
    if (-not $der) { return $null }
    try {
        return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,[byte[]]$der)
    } catch { return $null }
}

function Get-PemFingerprint {
    param([string]$PemBlock)
    $cert = Get-CertFromPemBlock -PemBlock $PemBlock
    if (-not $cert) { return $null }
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($cert.RawData)
    return [BitConverter]::ToString($hash).Replace("-", "")
}

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

function Convert-CertToPemBlock {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    if (-not $Cert) { return $null }
    return "-----BEGIN CERTIFICATE-----`n" + [System.Convert]::ToBase64String($Cert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks) + "`n-----END CERTIFICATE-----"
}

function Add-CertToBundleList {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
        [System.Collections.ArrayList]$Blocks,
        [hashtable]$SeenThumbprints
    )
    if (-not $Cert) { return 0 }
    $thumb = $Cert.Thumbprint
    if ([string]::IsNullOrWhiteSpace($thumb)) { return 0 }
    if ($SeenThumbprints.ContainsKey($thumb)) { return 0 }
    $pem = Convert-CertToPemBlock -Cert $Cert
    if ([string]::IsNullOrWhiteSpace($pem)) { return 0 }
    $SeenThumbprints[$thumb] = $true
    [void]$Blocks.Add($pem)
    return 1
}

function Get-CertsFromWindowsStore {
    param(
        [System.Security.Cryptography.X509Certificates.StoreLocation]$Location,
        [System.Security.Cryptography.X509Certificates.StoreName]$Name
    )
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($Name, $Location)
    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        return @($store.Certificates)
    } catch {
        return @()
    } finally {
        $store.Close()
    }
}

# Export all trusted CAs from Windows trust stores (same idea as macOS keychain dump).
function Get-WindowsTrustStorePemBlocks {
    $bundleBlocks = New-Object System.Collections.ArrayList
    $seen = @{}
    $stores = @(
        @{ Location = [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine; Name = [System.Security.Cryptography.X509Certificates.StoreName]::Root },
        @{ Location = [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine; Name = [System.Security.Cryptography.X509Certificates.StoreName]::AuthRoot },
        @{ Location = [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine; Name = [System.Security.Cryptography.X509Certificates.StoreName]::CertificateAuthority },
        @{ Location = [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser; Name = [System.Security.Cryptography.X509Certificates.StoreName]::Root },
        @{ Location = [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser; Name = [System.Security.Cryptography.X509Certificates.StoreName]::CertificateAuthority }
    )
    foreach ($s in $stores) {
        foreach ($cert in Get-CertsFromWindowsStore -Location $s.Location -Name $s.Name) {
            Add-CertToBundleList -Cert $cert -Blocks $bundleBlocks -SeenThumbprints $seen | Out-Null
        }
    }
    if ($bundleBlocks.Count -eq 0) {
        Import-Module Microsoft.PowerShell.Security -ErrorAction SilentlyContinue
        foreach ($storePath in @(
            "Cert:\LocalMachine\Root",
            "Cert:\LocalMachine\AuthRoot",
            "Cert:\LocalMachine\CA",
            "Cert:\CurrentUser\Root",
            "Cert:\CurrentUser\CA"
        )) {
            if (-not (Test-Path $storePath)) { continue }
            foreach ($cert in @(Get-ChildItem $storePath -ErrorAction SilentlyContinue)) {
                Add-CertToBundleList -Cert $cert -Blocks $bundleBlocks -SeenThumbprints $seen | Out-Null
            }
        }
    }
    return @($bundleBlocks.ToArray())
}

function Test-DeployableUserProfile {
    param([string]$ProfilePath)
    $name = Split-Path -Leaf $ProfilePath
    if ($name -in @('Public', 'Default', 'Default User', 'All Users')) { return $false }
    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Container)) { return $false }
    $ntuser = Join-Path $ProfilePath 'NTUSER.DAT'
    return (Test-Path -LiteralPath $ntuser -PathType Leaf)
}

function Write-TrustStorePemFile {
    param([string]$TargetPath, [string[]]$PemBlocks)
    $TargetPath = [System.IO.Path]::GetFullPath($TargetPath)
    $targetDir = Split-Path -Parent $TargetPath
    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
        New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop | Out-Null
    }
    if ($PemBlocks.Count -eq 0) {
        throw "No valid certificates to write."
    }
    [System.IO.File]::WriteAllText($TargetPath, (($PemBlocks) -join "`n"), $utf8NoBom)
}

function Get-UserSidFromProfile {
    param([string]$ProfilePath)
    $normalized = ([System.IO.Path]::GetFullPath($ProfilePath)).TrimEnd('\').ToLowerInvariant()
    try {
        $profiles = Get-CimInstance Win32_UserProfile -ErrorAction Stop
        foreach ($prof in $profiles) {
            if ($prof.LocalPath -and ($prof.LocalPath.TrimEnd('\').ToLowerInvariant() -eq $normalized)) {
                return $prof.SID
            }
        }
    } catch { }
    $listKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($sub in Get-ChildItem -Path $listKey -ErrorAction SilentlyContinue) {
        $imagePath = (Get-ItemProperty -Path $sub.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        if ($imagePath -and ($imagePath.TrimEnd('\').ToLowerInvariant() -eq $normalized)) {
            return Split-Path -Leaf $sub.PSPath
        }
    }
    return $null
}

function Test-SameProfilePath {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    $fullA = ([System.IO.Path]::GetFullPath($A)).TrimEnd('\')
    $fullB = ([System.IO.Path]::GetFullPath($B)).TrimEnd('\')
    return $fullA.Equals($fullB, [StringComparison]::OrdinalIgnoreCase)
}

function Send-EnvironmentChangeNotification {
    if (-not ("NativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeMethods {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
"@ -ErrorAction SilentlyContinue | Out-Null
    }
    if ("NativeMethods" -as [type]) {
        $result = [UIntPtr]::Zero
        [void][NativeMethods]::SendMessageTimeout(
            [IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, "Environment",
            0x0002, 5000, [ref]$result)
    }
}

function Set-UserEnvRegistryValues {
    param([string]$KeyPath, [string]$CertPath, [bool]$DoNpm, [bool]$DoPythonTls, [bool]$DoHuggingface, [bool]$DoRuby)
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        New-Item -Path $KeyPath -Force -ErrorAction Stop | Out-Null
    }
    if ($DoNpm) {
        Set-ItemProperty -Path $KeyPath -Name "NODE_USE_SYSTEM_CA" -Value "1" -Type String -Force
        Set-ItemProperty -Path $KeyPath -Name "NODE_EXTRA_CA_CERTS" -Value $CertPath -Type String -Force
    }
    if ($DoPythonTls) {
        Set-ItemProperty -Path $KeyPath -Name "UV_NATIVE_TLS" -Value "1" -Type String -Force
        Set-ItemProperty -Path $KeyPath -Name "UV_SYSTEM_CERTS" -Value "true" -Type String -Force
        Set-ItemProperty -Path $KeyPath -Name "REQUESTS_CA_BUNDLE" -Value $CertPath -Type String -Force
        Set-ItemProperty -Path $KeyPath -Name "SSL_CERT_FILE" -Value $CertPath -Type String -Force
    }
    if ($DoRuby) {
        Set-ItemProperty -Path $KeyPath -Name "SSL_CERT_FILE" -Value $CertPath -Type String -Force
    }
    if ($DoHuggingface) {
        Set-ItemProperty -Path $KeyPath -Name "HF_HUB_DISABLE_XET" -Value "1" -Type String -Force
        Set-ItemProperty -Path $KeyPath -Name "HF_HUB_ETAG_TIMEOUT" -Value "86400" -Type String -Force
        Set-ItemProperty -Path $KeyPath -Name "HF_HUB_DOWNLOAD_TIMEOUT" -Value "86400" -Type String -Force
    }
}

function Set-OtherUserEnvVars {
    param([string]$ProfilePath, [string]$CertPath, [bool]$DoNpm, [bool]$DoPythonTls, [bool]$DoHuggingface, [bool]$DoRuby)
    if (Test-SameProfilePath -A $ProfilePath -B $env:USERPROFILE) {
        Set-CurrentUserCertEnvVars -CertPath $CertPath -DoNpm:$DoNpm -DoPythonTls:$DoPythonTls -DoHuggingface:$DoHuggingface -DoRuby:$DoRuby
        Send-EnvironmentChangeNotification
        return
    }
    $sid = Get-UserSidFromProfile -ProfilePath $ProfilePath
    $keyPath = $null
    $weLoaded = $false
    $tempKey = $null
    if ($sid -and (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid" -ErrorAction SilentlyContinue)) {
        $keyPath = "Registry::HKEY_USERS\$sid\Environment"
    } else {
        $ntuser = Join-Path $ProfilePath "NTUSER.DAT"
        if (-not (Test-Path -LiteralPath $ntuser -PathType Leaf)) {
            throw "Cannot set env vars: no SID and no NTUSER.DAT at $ProfilePath"
        }
        $tempKey = "temp_env_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        & reg.exe load "HKU\$tempKey" "$ntuser" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Cannot set env vars: failed to load NTUSER.DAT for $ProfilePath (user may be logged in elsewhere)"
        }
        $weLoaded = $true
        $keyPath = "Registry::HKEY_USERS\$tempKey\Environment"
    }
    try {
        Set-UserEnvRegistryValues -KeyPath $keyPath -CertPath $CertPath -DoNpm:$DoNpm -DoPythonTls:$DoPythonTls -DoHuggingface:$DoHuggingface -DoRuby:$DoRuby
    } finally {
        if ($weLoaded -and $tempKey) { & reg.exe unload "HKU\$tempKey" 2>&1 | Out-Null }
    }
}

function Get-EnvRegistryPath {
    param([string]$Scope)
    if ($Scope -eq "Machine") {
        return "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
    }
    return "Registry::HKEY_CURRENT_USER\Environment"
}

function Remove-CertEnvVar {
    param([string]$VarName, [string]$Scope)
    $regPath = Get-EnvRegistryPath -Scope $Scope
    if (Test-Path -LiteralPath $regPath) {
        $existing = Get-ItemProperty -Path $regPath -Name $VarName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Remove-ItemProperty -Path $regPath -Name $VarName -Force -ErrorAction SilentlyContinue
        }
    }
    [Environment]::SetEnvironmentVariable($VarName, $null, $Scope)
}

function Clear-CertEnvVars {
    param([string]$Scope, [bool]$DoNpm, [bool]$DoPythonTls, [bool]$DoRuby, [bool]$DoHuggingface)
    $vars = @()
    if ($DoNpm) { $vars += @("NODE_EXTRA_CA_CERTS", "NODE_USE_SYSTEM_CA") }
    if ($DoPythonTls) { $vars += @("UV_NATIVE_TLS", "UV_SYSTEM_CERTS", "REQUESTS_CA_BUNDLE", "SSL_CERT_FILE") }
    elseif ($DoRuby) { $vars += @("SSL_CERT_FILE") }
    if ($DoHuggingface) { $vars += @("HF_HUB_DISABLE_XET", "HF_HUB_ETAG_TIMEOUT", "HF_HUB_DOWNLOAD_TIMEOUT") }
    foreach ($var in ($vars | Select-Object -Unique)) {
        Remove-CertEnvVar -VarName $var -Scope $Scope
    }
}

function Set-CurrentUserCertEnvVars {
    param([string]$CertPath, [bool]$DoNpm, [bool]$DoPythonTls, [bool]$DoHuggingface, [bool]$DoRuby)
    if ($DoNpm) {
        [Environment]::SetEnvironmentVariable("NODE_USE_SYSTEM_CA", "1", "User")
        [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $CertPath, "User")
    }
    if ($DoPythonTls) {
        [Environment]::SetEnvironmentVariable("UV_NATIVE_TLS", "1", "User")
        [Environment]::SetEnvironmentVariable("UV_SYSTEM_CERTS", "true", "User")
        [Environment]::SetEnvironmentVariable("REQUESTS_CA_BUNDLE", $CertPath, "User")
        [Environment]::SetEnvironmentVariable("SSL_CERT_FILE", $CertPath, "User")
    }
    if ($DoRuby) {
        [Environment]::SetEnvironmentVariable("SSL_CERT_FILE", $CertPath, "User")
    }
    if ($DoHuggingface) {
        [Environment]::SetEnvironmentVariable("HF_HUB_DISABLE_XET", "1", "User")
        [Environment]::SetEnvironmentVariable("HF_HUB_ETAG_TIMEOUT", "86400", "User")
        [Environment]::SetEnvironmentVariable("HF_HUB_DOWNLOAD_TIMEOUT", "86400", "User")
    }
}

function Set-ScopedCertEnvVars {
    param([string]$CertPath, [string]$Scope, [bool]$DoNpm, [bool]$DoPythonTls, [bool]$DoHuggingface, [bool]$DoRuby)
    if ($DoNpm) {
        [Environment]::SetEnvironmentVariable("NODE_USE_SYSTEM_CA", "1", $Scope)
        [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $CertPath, $Scope)
    }
    if ($DoPythonTls) {
        [Environment]::SetEnvironmentVariable("UV_NATIVE_TLS", "1", $Scope)
        [Environment]::SetEnvironmentVariable("UV_SYSTEM_CERTS", "true", $Scope)
        [Environment]::SetEnvironmentVariable("REQUESTS_CA_BUNDLE", $CertPath, $Scope)
        [Environment]::SetEnvironmentVariable("SSL_CERT_FILE", $CertPath, $Scope)
    }
    if ($DoRuby) {
        [Environment]::SetEnvironmentVariable("SSL_CERT_FILE", $CertPath, $Scope)
    }
    if ($DoHuggingface) {
        [Environment]::SetEnvironmentVariable("HF_HUB_DISABLE_XET", "1", $Scope)
        [Environment]::SetEnvironmentVariable("HF_HUB_ETAG_TIMEOUT", "86400", $Scope)
        [Environment]::SetEnvironmentVariable("HF_HUB_DOWNLOAD_TIMEOUT", "86400", $Scope)
    }
}

# --- Context and paths ---

Write-Host "--- Certificate installation and configuring ($Package) ---"

if ($certMode -eq "UseCert") {
    if (-not (Test-Path -LiteralPath $UseCert -PathType Leaf)) {
        Write-Host "[Error] -UseCert path is not a file: $UseCert" -ForegroundColor Red
        exit 1
    }
    if (-not (Test-ValidPemFile -Path $UseCert)) {
        Write-Host "[Error] Invalid or missing PEM at: $UseCert" -ForegroundColor Red
        exit 1
    }
    Write-Host "[1/4] Using existing certificate at $UseCert..."
} else {
    Write-Host "[1/4] Preparing per-user PEM bundle (full trust store export)..."
}

$trustStoreBlocks = $null
if ($certMode -eq "Extract") {
    $trustStoreBlocks = @(Get-WindowsTrustStorePemBlocks)
    if ($trustStoreBlocks.Count -eq 0) {
        Write-Host "[Error] No certificates found in Windows trust stores." -ForegroundColor Red
        exit 1
    }
    Write-Host "   + Found $($trustStoreBlocks.Count) certificate(s) in Windows trust stores."
}

$extractPathTrim = "certs"
if ($certMode -eq "Extract") {
    $extractPathTrim = $ExtractPath.TrimStart('\', '/')
    if ([System.IO.Path]::IsPathRooted($extractPathTrim)) {
        $extractPathTrim = $extractPathTrim.TrimStart([System.IO.Path]::GetPathRoot($extractPathTrim)).TrimStart('\', '/')
    }
    if ([string]::IsNullOrWhiteSpace($extractPathTrim)) { $extractPathTrim = "certs" }
}

if ($certMode -eq "Extract") {
    if ($isSystemContext -or $isAdmin) {
        Write-Host "[2/4] Deploying cert bundle and User-level env per user..."
        $userDirs = @(Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { Test-DeployableUserProfile -ProfilePath $_.FullName })
        if ($env:USERPROFILE -and (Test-Path -LiteralPath $env:USERPROFILE -PathType Container)) {
            $currentProfile = Get-Item -LiteralPath $env:USERPROFILE
            if ($userDirs.FullName -notcontains $currentProfile.FullName) {
                $userDirs = @($currentProfile) + $userDirs
            }
        }
        $deployedCount = 0
        foreach ($ud in $userDirs) {
            $userHome = $ud.FullName
            $certDir = Join-Path $userHome $extractPathTrim
            $certPath = Join-Path $certDir "package-route.pem"
            try {
                Write-TrustStorePemFile -TargetPath $certPath -PemBlocks $trustStoreBlocks
                if (-not (Test-ValidPemFile -Path $certPath)) {
                    throw "Exported PEM file is invalid: $certPath"
                }
                $certCount = (Get-PemBlocksFromFile -Path $certPath).Count
                Set-OtherUserEnvVars -ProfilePath $userHome -CertPath $certPath -DoNpm:(DoNpm) -DoPythonTls:(DoPythonTls) -DoHuggingface:(DoHuggingface) -DoRuby:(DoRuby)
                Write-Host "   + $(Split-Path -Leaf $userHome): $certCount certs → $certPath (env vars set)"
                $deployedCount++
            } catch {
                Write-Warning "Skipping $userHome : $($_.Exception.Message)"
            }
        }
        if ($deployedCount -eq 0) {
            Write-Host "[Error] Could not deploy cert bundle to any user profile." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "[2/4] Deploying cert bundle and User-level env for current user..."
        $certDir = Join-Path $env:USERPROFILE $extractPathTrim
        $certPath = Join-Path $certDir "package-route.pem"
        Write-TrustStorePemFile -TargetPath $certPath -PemBlocks $trustStoreBlocks
        if (-not (Test-ValidPemFile -Path $certPath)) {
            Write-Host "[Error] Exported PEM file is invalid: $certPath" -ForegroundColor Red
            exit 1
        }
        $certCount = (Get-PemBlocksFromFile -Path $certPath).Count
        Set-CurrentUserCertEnvVars -CertPath $certPath -DoNpm:(DoNpm) -DoPythonTls:(DoPythonTls) -DoHuggingface:(DoHuggingface) -DoRuby:(DoRuby)
        Write-Host "   + $certCount certs → $certPath"
        if (DoNpm) { Write-Host "   + NODE_USE_SYSTEM_CA and NODE_EXTRA_CA_CERTS set." }
        if (DoPythonTls) {
            Write-Host "   + UV_NATIVE_TLS, UV_SYSTEM_CERTS set; REQUESTS_CA_BUNDLE and SSL_CERT_FILE set to $certPath"
        }
        if ((DoRuby) -and -not (DoPythonTls)) { Write-Host "   + SSL_CERT_FILE set to $certPath" }
        if (DoHuggingface) { Write-Host "   + Hugging Face Hub timeouts / HF_HUB_DISABLE_XET set." }
    }
}

if ($certMode -eq "UseCert") {
    $envScope = if ($isSystemContext -or $isAdmin) { "Machine" } else { "User" }
    Write-Host "[2/4] Setting Environment Variables ($envScope)..."
    Set-ScopedCertEnvVars -CertPath $UseCert -Scope $envScope -DoNpm:(DoNpm) -DoPythonTls:(DoPythonTls) -DoHuggingface:(DoHuggingface) -DoRuby:(DoRuby)
    if (DoNpm) { Write-Host "   + NODE_USE_SYSTEM_CA and NODE_EXTRA_CA_CERTS set." }
    if (DoPythonTls) {
        Write-Host "   + UV_NATIVE_TLS, UV_SYSTEM_CERTS set; REQUESTS_CA_BUNDLE and SSL_CERT_FILE set to $UseCert"
        if (DoHuggingface) { Write-Host "   + HF_HUB_DISABLE_XET and HF Hub timeouts set." }
    }
    if ((DoRuby) -and -not (DoPythonTls)) { Write-Host "   + SSL_CERT_FILE set to $UseCert" }
    if ($envScope -eq "Machine") {
        Clear-CertEnvVars -Scope "User" -DoNpm:(DoNpm) -DoPythonTls:(DoPythonTls) -DoRuby:(DoRuby) -DoHuggingface:(DoHuggingface)
        Write-Host "   + Cleared User-level cert vars so Machine settings apply."
    }
}

Invoke-DockerHubCredentialCleanup

Write-Host "---------------------------------------------------"
Write-Host "[4/4] COMPLETE!"
Write-Host ""
if ($certMode -eq "UseCert") {
    Write-Host "Using existing cert at $UseCert. Users must start new terminals to pick up changes."
} elseif ($isSystemContext -or $isAdmin) {
    Write-Host "Certificate bundle exported to each user's profile (package-route.pem). User-level env set per user. Users must start new terminals to pick up changes."
} else {
    Write-Host "Certificate: $certPath"
    Write-Host "Please restart your terminal for changes to take effect."
}
