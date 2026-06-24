# (c) JFrog Ltd. (2026)
# Install a bundled JVM truststore on Windows for JVM clients (Maven, Gradle,
# sbt, Apache Ivy).
#
# Single path: copy a supplied JKS truststore to
#   %LOCALAPPDATA%\JFrog\package-route-jvm\truststore.jks
# then set JAVA_TOOL_OPTIONS at User scope
# (HKCU\Environment + WM_SETTINGCHANGE broadcast) so every new JVM startup
# inherits the trustStore path.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File install_certs_jvm_windows.ps1 -UseTruststore C:\path\to\truststore.jks
#
# Notes:
#   - Windows only.
#   - Requires PowerShell 5.1+ (Windows PowerShell or PowerShell 7).
#   - User scope only -- does NOT require Administrator. No Machine-scope
#     option in v1 (intentional; the Wiki recommends user-scope for
#     developer machines).
#   - JVM trust only -- does not configure Node/npm/Python and does not
#     touch Docker credentials. Pair with install_certs_windows.ps1 for those.
#   - Existing processes need a logoff/logon (or to handle WM_SETTINGCHANGE)
#     before they see the new env var. Most daemons don't; restart Gradle
#     Daemon via `gradle --stop` and restart your IDE after install.
#   - The "use the OS trust store" alternative (-Djavax.net.ssl.trustStoreType=
#     Windows-ROOT) is deliberately not exposed in v1. The Gradle daemon
#     stale-cache issue (gradle/gradle#6584) was fixed in Gradle 8.3 via
#     gradle/gradle#25106, but the JKS+JAVA_TOOL_OPTIONS recipe stays uniform
#     across Linux/macOS/Windows and works for developers on older Gradle.
#
# Cross-platform siblings (keep CLI shapes and contracts in sync):
#   install_certs_jvm_linux.sh       - update-ca-trust OR JKS+JAVA_TOOL_OPTIONS
#   install_certs_jvm_macos.sh       - LaunchAgent + per-user JKS
#
# Research / rationale: see the JVM client-onboarding wiki page
#   https://jfrog-int.atlassian.net/wiki/spaces/RTFACT/pages/2440101931/

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$UseTruststore
)

$ErrorActionPreference = 'Stop'

# Keep this installer self-contained: it is often copied/run as a standalone
# script during onboarding, so avoid requiring sibling files for constants.
$JvmWindowsJksRelativeDir = 'JFrog\package-route-jvm'
$JvmWindowsJksBasename = 'truststore.jks'
$JvmWindowsJksPassword = 'changeit'
$JvmWindowsEnvVarName = 'JAVA_TOOL_OPTIONS'

function Get-JvmWindowsJksPath {
    Join-Path $env:LOCALAPPDATA (Join-Path $JvmWindowsJksRelativeDir $JvmWindowsJksBasename)
}

function Show-Usage {
    @'
Usage:
  powershell -ExecutionPolicy Bypass -File install_certs_jvm_windows.ps1 -UseTruststore <path>

Parameters:
  -UseTruststore <path>  Path to an existing JVM truststore (JKS/PKCS12-compatible)
                         to copy into the current user's fixed JKS location.
                         The truststore must be readable by JVMs with password
                         'changeit'.

Notes:
  No -AllUsers flag -- User-scope env var is per-user by construction; each
  developer runs the installer in their own session. There is no -Mode
  flag (no OS-trust fallback by design: Windows-ROOT is not exposed in v1
  -- the daemon stale-cache issue gradle/gradle#6584 is fixed in Gradle 8.3,
  but the JKS recipe stays uniform across platforms).

Examples:
  powershell -File install_certs_jvm_windows.ps1 -UseTruststore C:\tmp\package-route-truststore.jks
'@
}

function Test-Truststore {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Error "Error: truststore file not found: $Path"
        exit 1
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -le 0) {
        Write-Error "Error: truststore file is empty: $Path"
        exit 1
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    } catch {
        Write-Error "Error: truststore file is not readable: $Path ($($_.Exception.Message))"
        exit 1
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Install-JksTruststore {
    param(
        [string]$JksPath,
        [string]$SourceTruststore
    )

    # Precondition: %LOCALAPPDATA% must exist and be writable. OneDrive
    # Known-Folder-Move, roaming-profile misconfiguration, and IT GPO
    # restrictions are the common failure modes; without this check the
    # New-Item below would throw a generic .NET path message that doesn't
    # hint at profile redirection.
    if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) {
        Write-Error 'Error: %LOCALAPPDATA% is empty. Cannot place the JKS truststore. Are you running under a service account or a profile that has not been provisioned?'
        exit 1
    }
    if (-not (Test-Path -LiteralPath $env:LOCALAPPDATA)) {
        Write-Error ("Error: %LOCALAPPDATA% ({0}) does not exist on this filesystem. OneDrive Known-Folder-Move or roaming-profile failure?" -f $env:LOCALAPPDATA)
        exit 1
    }

    $jksDir = Split-Path -Parent $JksPath
    if (-not (Test-Path -LiteralPath $jksDir)) {
        New-Item -ItemType Directory -Path $jksDir -Force | Out-Null
    }

    Write-Host ("  [JKS] Installing truststore at {0}" -f $JksPath)
    $sourcePath = (Resolve-Path -LiteralPath $SourceTruststore).Path
    if (Test-Path -LiteralPath $JksPath -PathType Leaf) {
        $destPath = (Resolve-Path -LiteralPath $JksPath).Path
        if ([string]::Equals($sourcePath, $destPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "  [JKS] Source already matches destination; leaving truststore in place."
            return
        }
    }
    Copy-Item -LiteralPath $sourcePath -Destination $JksPath -Force
    Write-Host "  [JKS] OK"
}

function Set-JavaToolOptions {
    param(
        [string]$JksPath,
        [string]$Password
    )

    # User scope = HKCU\Environment. [Environment]::SetEnvironmentVariable
    # also broadcasts WM_SETTINGCHANGE, so processes that handle the message
    # (Explorer, some shells) pick up the value without a logoff. Most JVM
    # toolchains do not -- daemons and IDE processes still need a fresh
    # session before the env var reaches a new java -version.
    #
    # Both trustStore and trustStorePassword values are quoted so a future
    # password change to one containing spaces doesn't tokenize wrongly when
    # the JVM splits JAVA_TOOL_OPTIONS.
    $jtoValue = '-Djavax.net.ssl.trustStore="{0}" -Djavax.net.ssl.trustStorePassword="{1}"' -f $JksPath, $Password

    Write-Host ("  [Env] Setting User-scope {0}" -f $JvmWindowsEnvVarName)
    [Environment]::SetEnvironmentVariable($JvmWindowsEnvVarName, $jtoValue, [EnvironmentVariableTarget]::User)

    # Round-trip verify: on Windows 10 1607+ a SetEnvironmentVariable value
    # exceeding 2047 chars is silently truncated rather than throwing. A
    # future feature that lengthens JAVA_TOOL_OPTIONS (e.g. adds -Dhttps
    # proxy flags) would leave the user with a half-written value and the
    # validator complaining that JKS path doesn't match -- exactly the kind
    # of silent failure the project bans.
    $readBack = [Environment]::GetEnvironmentVariable($JvmWindowsEnvVarName, [EnvironmentVariableTarget]::User)
    if ($readBack -ne $jtoValue) {
        Write-Error ("Error: HKCU\Environment round-trip verify failed for {0}.`n  Wrote ({1} chars): {2}`n  Read  ({3} chars): {4}" `
            -f $JvmWindowsEnvVarName, $jtoValue.Length, $jtoValue, ($readBack.Length), $readBack)
        exit 1
    }
    Write-Host "  [Env] OK"

    return $jtoValue
}

function Show-DoneSummary {
    param(
        [string]$JksPath,
        [string]$JtoValue
    )

    Write-Host ""
    Write-Host "Truststore:"
    Write-Host ("  {0}" -f $JksPath)
    Write-Host ("{0}:" -f $JvmWindowsEnvVarName)
    Write-Host ("  {0}" -f $JtoValue)
    Write-Host ""
    Write-Host "Notes:"
    Write-Host "  - The User-scope env var is written to HKCU\Environment and broadcast"
    Write-Host "    via WM_SETTINGCHANGE. NEW processes started after this point inherit"
    Write-Host "    JAVA_TOOL_OPTIONS automatically."
    Write-Host "  - Existing PowerShell/cmd sessions did NOT see the value; open a new"
    Write-Host "    Terminal (or log off/on) so daemons and IDEs read it on startup."
    Write-Host "  - Run 'gradle --stop' to refresh the Gradle Daemon if one was already"
    Write-Host "    running -- daemons cache the env at startup."
    Write-Host "  - The 'Picked up JAVA_TOOL_OPTIONS:' banner on stderr is expected and"
    Write-Host "    indicates the JVM read the var correctly."
}

function Main {
    Test-Truststore -Path $UseTruststore

    $jksPath = Get-JvmWindowsJksPath
    Install-JksTruststore `
        -JksPath  $jksPath `
        -SourceTruststore $UseTruststore

    $jtoValue = Set-JavaToolOptions `
        -JksPath  $jksPath `
        -Password $JvmWindowsJksPassword

    Show-DoneSummary -JksPath $jksPath -JtoValue $jtoValue
}

Main
