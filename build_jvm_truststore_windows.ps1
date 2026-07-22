# (c) JFrog Ltd. (2026)
# Build a JVM truststore from Windows LocalMachine root certificates.
#
# Enterprise CAs already in LocalMachine\Root (e.g. Zscaler via ZCC) are
# included automatically. This is a build-time helper for the JVM installers —
# it does not install anything and does not require Administrator rights for
# normal LocalMachine Root read access.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File .\build_jvm_truststore_windows.ps1 `
#     -Output C:\Temp\package-route-truststore.jks

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Output
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$JksPassword = 'changeit'

function Fail {
    param([string]$Message)
    Write-Error $Message
    exit 1
}

function Get-Keytool {
    if ($env:JAVA_HOME) {
        $candidate = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $cmd = Get-Command keytool.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    Fail 'keytool.exe is required. Install a JDK or set JAVA_HOME.'
}

function Invoke-Keytool {
    param(
        [string]$Keytool,
        [string[]]$KeytoolArgs
    )

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $rc = 0
    try {
        $out = & $Keytool @KeytoolArgs 2>&1
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }

    if ($rc -ne 0) {
        $head = ($out | Select-Object -First 5) -join '; '
        Fail "keytool exited $rc. Output: $head"
    }
}

function Import-CertToTruststore {
    param(
        [string]$Keytool,
        [string]$CertPath,
        [string]$Alias,
        [string]$TruststorePath
    )

    Invoke-Keytool -Keytool $Keytool -KeytoolArgs @(
        '-importcert', '-noprompt',
        '-storetype', 'JKS',
        '-alias', $Alias,
        '-file', $CertPath,
        '-keystore', $TruststorePath,
        '-storepass', $JksPassword
    )
}

function Get-SystemRootCertificates {
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )

    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        return @($store.Certificates | Where-Object { $_.NotAfter -gt (Get-Date) })
    } finally {
        $store.Close()
    }
}

$keytool = Get-Keytool
$outputParent = Split-Path -Parent $Output
if ($outputParent) {
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("package-route-jvm-build-{0}" -f ([Guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    $tempStore = Join-Path $tempDir 'truststore.jks'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $imported = 0

    foreach ($cert in (Get-SystemRootCertificates)) {
        $thumb = $cert.Thumbprint.ToLowerInvariant()
        if (-not $seen.Add($thumb)) {
            continue
        }

        $certPath = Join-Path $tempDir ("system-{0}.cer" -f $thumb)
        [System.IO.File]::WriteAllBytes(
            $certPath,
            $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        )
        Import-CertToTruststore -Keytool $keytool -CertPath $certPath -Alias "system-$thumb" -TruststorePath $tempStore
        $imported++
    }

    if ($imported -eq 0) {
        Fail 'No certificates could be imported from LocalMachine\Root.'
    }

    Move-Item -LiteralPath $tempStore -Destination $Output -Force

    Write-Host 'Built JVM truststore:'
    Write-Host "  $Output"
    Write-Host 'Imported Windows LocalMachine root certificates:'
    Write-Host "  $imported"
    Write-Host "Truststore password: $JksPassword"
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
