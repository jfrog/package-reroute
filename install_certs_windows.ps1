# (c) JFrog Ltd. (2026)
# Export a combined CA bundle from the Windows LocalMachine root store and configure
# npm and/or Python-related tooling for redirected package traffic.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package all
#   powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package npm
#   powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package python
#   powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package all -CertName Zscaler
#   powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package all -BundlePath C:\ProgramData\JFrog\corporate-certs\ca-bundle.pem
#
# What it does:
#   1. Verifies Administrator privileges
#   2. Optionally verifies that a certificate matching -CertName exists in LocalMachine\Root
#   3. Exports ALL certificates from LocalMachine\Root into a PEM bundle
#   4. Writes the PEM bundle to a machine-stable path
#   5. Sets Machine-level environment variables
#
# Notes:
#   - Windows only
#   - Must run as Administrator
#   - The exported PEM is the effective combined bundle (public roots + corporate CA)
#     because LocalMachine\Root already contains trusted roots deployed via GPO/Intune
#   - New terminals/processes are required to pick up the env vars

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("npm", "python", "all")]
    [string]$Package = "all",

    [Parameter(Mandatory = $false)]
    [string]$CertName,

    [Parameter(Mandatory = $false)]
    [string]$BundlePath = "C:\ProgramData\JFrog\corporate-certs\ca-bundle.pem"
)

$ErrorActionPreference = "Stop"

function DoNpm {
    return $Package -eq "npm" -or $Package -eq "all"
}

function DoPython {
    return $Package -eq "python" -or $Package -eq "all"
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Error "This script must be run as Administrator. Open PowerShell as Administrator and try again."
        exit 1
    }
}

function Assert-Windows {
    if (-not $env:WINDIR) {
        Write-Error "This script must be run on Windows."
        exit 1
    }
}

function Normalize-BundlePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $dir = Split-Path -Path $fullPath -Parent

    if ([string]::IsNullOrWhiteSpace($dir)) {
        Write-Error "Invalid bundle path: $Path"
        exit 1
    }

    return $fullPath
}

function Ensure-BundleDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Assert-CertPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $storePath = "Cert:\LocalMachine\Root"
    $matches = @(Get-ChildItem -Path $storePath -ErrorAction Stop | Where-Object { $_.Subject -like "*$Pattern*" })

    if ($matches.Count -eq 0) {
        Write-Error "No certificate in LocalMachine\Root matched pattern: $Pattern"
        exit 1
    }

    Write-Host "Verified certificate presence in LocalMachine\Root:"
    foreach ($match in $matches) {
        Write-Host "   $($match.Subject)"
    }
}

function Export-RootStoreToPem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $storePath = "Cert:\LocalMachine\Root"
    $certs = @(Get-ChildItem -Path $storePath -ErrorAction Stop)

    if ($certs.Count -eq 0) {
        Write-Error "No certificates found in LocalMachine\Root."
        exit 1
    }

    $pemBlocks = New-Object System.Collections.Generic.List[string]

    foreach ($cert in $certs) {
        $base64 = [System.Convert]::ToBase64String(
            $cert.RawData,
            [System.Base64FormattingOptions]::InsertLineBreaks
        )

        $pemBlock = @(
            "-----BEGIN CERTIFICATE-----"
            $base64
            "-----END CERTIFICATE-----"
            ""
        ) -join "`r`n"

        [void]$pemBlocks.Add($pemBlock)
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, ($pemBlocks -join ""), $utf8NoBom)
}

function Test-ValidPemFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $content = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $false
    }

    $regex = [regex]'(?s)-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----'
    $matches = $regex.Matches($content)

    if ($matches.Count -eq 0) {
        return $false
    }

    foreach ($match in $matches) {
        $base64 = $match.Groups[1].Value.Trim() -replace '\s', ''
        try {
            $der = [System.Convert]::FromBase64String($base64)
            $null = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,[byte[]]$der)
        }
        catch {
            return $false
        }
    }

    return $true
}

function Set-MachineEnvVar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    [Environment]::SetEnvironmentVariable($Name, $Value, "Machine")
}

function Print-Done {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PemPath
    )

    Write-Host "---------------------------------------------------"
    Write-Host "[3/3] COMPLETE!"
    Write-Host ""
    Write-Host "Combined CA bundle written to:"
    Write-Host "  $PemPath"
    Write-Host ""

    if (DoNpm) {
        Write-Host "npm/node environment:"
        Write-Host "  NODE_USE_SYSTEM_CA=1"
        Write-Host "  NODE_EXTRA_CA_CERTS=$PemPath"
        Write-Host ""
    }

    if (DoPython) {
        Write-Host "python/tooling environment:"
        Write-Host "  REQUESTS_CA_BUNDLE=$PemPath"
        Write-Host "  UV_NATIVE_TLS=true"
        Write-Host "  UV_SYSTEM_CERTS=true"
        Write-Host ""
    }

    Write-Host "Open a new terminal and validate:"
    if (DoNpm) {
        Write-Host '  [Environment]::GetEnvironmentVariable("NODE_USE_SYSTEM_CA","Machine")'
        Write-Host '  [Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS","Machine")'
        Write-Host "  npm i axios"
    }
    if (DoPython) {
        Write-Host '  [Environment]::GetEnvironmentVariable("REQUESTS_CA_BUNDLE","Machine")'
        Write-Host '  [Environment]::GetEnvironmentVariable("UV_NATIVE_TLS","Machine")'
        Write-Host '  [Environment]::GetEnvironmentVariable("UV_SYSTEM_CERTS","Machine")'
        Write-Host "  py -3 -m venv .venv"
        Write-Host "  .\.venv\Scripts\Activate.ps1"
        Write-Host "  python -m pip install requests"
    }
}

function Main {
    Assert-Windows
    Assert-Admin

    $resolvedBundlePath = Normalize-BundlePath -Path $BundlePath

    Write-Host "--- Certificate installation and configuring ($Package) ---"

    if (-not [string]::IsNullOrWhiteSpace($CertName)) {
        Write-Host "[1/3] Verifying certificate presence (pattern=$CertName)..."
        Assert-CertPresent -Pattern $CertName
    }
    else {
        Write-Host "[1/3] No -CertName provided; exporting full LocalMachine\Root store..."
    }

    Write-Host "[2/3] Exporting LocalMachine\Root to PEM bundle..."
    Ensure-BundleDirectory -Path $resolvedBundlePath
    Export-RootStoreToPem -OutputPath $resolvedBundlePath

    if (-not (Test-ValidPemFile -Path $resolvedBundlePath)) {
        Write-Error "Exported PEM bundle is invalid: $resolvedBundlePath"
        exit 1
    }

    if (DoNpm) {
        Set-MachineEnvVar -Name "NODE_USE_SYSTEM_CA" -Value "1"
        Set-MachineEnvVar -Name "NODE_EXTRA_CA_CERTS" -Value $resolvedBundlePath
        Write-Host "   + Set NODE_USE_SYSTEM_CA=1"
        Write-Host "   + Set NODE_EXTRA_CA_CERTS=$resolvedBundlePath"
    }

    if (DoPython) {
        Set-MachineEnvVar -Name "REQUESTS_CA_BUNDLE" -Value $resolvedBundlePath
        Set-MachineEnvVar -Name "UV_NATIVE_TLS" -Value "true"
        Set-MachineEnvVar -Name "UV_SYSTEM_CERTS" -Value "true"
        Write-Host "   + Set REQUESTS_CA_BUNDLE=$resolvedBundlePath"
        Write-Host "   + Set UV_NATIVE_TLS=true"
        Write-Host "   + Set UV_SYSTEM_CERTS=true"
    }

    Print-Done -PemPath $resolvedBundlePath
}

Main