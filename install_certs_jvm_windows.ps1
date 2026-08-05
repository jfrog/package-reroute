# (c) JFrog Ltd. (2026)
# Wire an IT-published JVM truststore on Windows for JVM clients (Maven, Gradle,
# sbt, Apache Ivy).
#
# Single path: take a supplied JKS truststore path and set JAVA_TOOL_OPTIONS
# at User scope (HKCU\Environment + WM_SETTINGCHANGE broadcast) so every new
# JVM startup inherits that trustStore path. The supplied path is the runtime
# location — this script does not copy the file (IT publishes the ready JKS
# to a durable path of its choosing).
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
#   install_certs_jvm_linux.sh       - JAVA_TOOL_OPTIONS in /etc/environment
#   install_certs_jvm_rhel.sh        - RHEL update-ca-trust
#   install_certs_jvm_macos.sh       - ~/.zshrc JAVA_TOOL_OPTIONS
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
$JvmWindowsJksPassword = 'changeit'
$JvmWindowsEnvVarName = 'JAVA_TOOL_OPTIONS'

function Show-Usage {
    @'
Usage:
  powershell -ExecutionPolicy Bypass -File install_certs_jvm_windows.ps1 -UseTruststore <path>

Parameters:
  -UseTruststore <path>  Path to the IT-published JVM truststore
                         (JKS/PKCS12-compatible). JAVA_TOOL_OPTIONS will point
                         at this path (resolved to absolute). The truststore
                         must be readable by JVMs with password 'changeit'.

Notes:
  No -AllUsers flag -- User-scope env var is per-user by construction; each
  developer runs the installer in their own session. There is no -Mode
  flag (no OS-trust fallback by design: Windows-ROOT is not exposed in v1
  -- the daemon stale-cache issue gradle/gradle#6584 is fixed in Gradle 8.3,
  but the JKS recipe stays uniform across platforms).

Examples:
  powershell -File install_certs_jvm_windows.ps1 -UseTruststore C:\ProgramData\JFrog\package-route-truststore.jks
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
    # Both trustStore and trustStorePassword values are quoted so a path or
    # password containing spaces doesn't tokenize wrongly when the JVM
    # splits JAVA_TOOL_OPTIONS.
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

    $jksPath = (Resolve-Path -LiteralPath $UseTruststore).Path

    $jtoValue = Set-JavaToolOptions `
        -JksPath  $jksPath `
        -Password $JvmWindowsJksPassword

    Show-DoneSummary -JksPath $jksPath -JtoValue $jtoValue
}

Main
