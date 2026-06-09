# (c) JFrog Ltd. (2026)
# Validate JVM truststore installation done by install_certs_jvm_windows.ps1.
#
# Asserts:
#   1. JKS file exists at %LOCALAPPDATA%\JFrog\package-route-jvm\truststore.jks
#   2. JKS contains a cert whose subject (Owner: in keytool -list -v) matches
#      -ExpectedSubject (case-insensitive substring).
#   3. User-scope JAVA_TOOL_OPTIONS env var returns a value referencing the
#      expected JKS path.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File validate_certs_jvm_windows.ps1 -ExpectedSubject "O=Zscaler"
#
# Exits 0 if all checks pass, 1 if any check fails. Result line is qualified
# with a count of any non-fatal warnings.
#
# Cross-platform siblings (keep CLI shapes and contracts in sync):
#   validate_certs_jvm_linux.sh      - system anchor OR JKS+JTO check
#   validate_certs_jvm_macos.sh      - LaunchAgent + launchctl getenv check
#
# Research / rationale: see the JVM client-onboarding wiki page
#   https://jfrog-int.atlassian.net/wiki/spaces/RTFACT/pages/2440101931/

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExpectedSubject,

    # Accepted for cross-platform CLI parity with the Linux validator. Ignored
    # here: Windows matches by subject substring, and the JKS path / HKCU env
    # var name are fixed regardless of cert-name. A fleet wrapper that passes
    # -CertName to all three validators must not fail on Windows.
    [Parameter(Mandatory = $false)]
    [string]$CertName
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
. (Join-Path $ScriptDir '_jvm_windows_paths.ps1')

$script:FailCount = 0
$script:WarnCount = 0

function Write-Fail { param([string]$Msg) Write-Host "  FAIL: $Msg"; $script:FailCount++ }
function Write-Ok   { param([string]$Msg) Write-Host "  OK:   $Msg" }
function Write-Warn { param([string]$Msg) Write-Host "  WARN: $Msg"; $script:WarnCount++ }

# Locate keytool. Same logic as the installer's Resolve-Keytool.
function Resolve-Keytool {
    if ($env:JAVA_HOME) {
        $candidate = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    $cmd = Get-Command keytool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-KeystoreContainsSubject {
    param(
        [string]$Keystore,
        [string]$Password,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Keystore -PathType Leaf)) {
        Write-Fail "$Label keystore does not exist: $Keystore"
        return
    }

    $keytool = Resolve-Keytool
    if (-not $keytool) {
        # Promoting to FAIL: the keystore-subject check is the validator's
        # core assertion; silently passing here would mean CI is green even
        # though we never verified the cert is in the store.
        Write-Fail "$Label keystore present but keytool.exe is not on PATH and JAVA_HOME is not set; cannot verify subject."
        return
    }

    # Capture combined output. PowerShell's 2>&1 merges stderr into the
    # pipeline so a real keytool error (corrupt store, wrong password, etc.)
    # is visible instead of being silently dropped. Switch ErrorActionPreference
    # to Continue around the call: under Stop, PowerShell promotes any
    # native-command stderr to a terminating error before 2>&1 captures it.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $keytool -list -v -keystore $Keystore -storepass $Password 2>&1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Fail ("{0}: keytool could not read the keystore. Output (first 3 lines):`n        {1}" -f $Label, (($output | Select-Object -First 3) -join "`n        "))
        return
    }

    # `Owner:` lines are how `keytool -list -v` prints each cert's subject.
    # Case-insensitive substring match against the expected subject.
    $owners = $output | Where-Object { $_ -match '^Owner:' }
    $found = $false
    foreach ($owner in $owners) {
        if ($owner -match [regex]::Escape($ExpectedSubject)) {
            $found = $true
            break
        }
    }
    if (-not $found) {
        Write-Fail "$Label has no cert with subject matching: $ExpectedSubject"
        return
    }
    # I8 cross-platform parity (see validate_certs_jvm_linux.sh): refuse to
    # validate stores that contain key material. The installer only writes
    # trustedCertEntry records, so any PrivateKeyEntry here indicates drift
    # -- likely a future installer change or hand-edited store. The well-known
    # `changeit` password is unsuitable for actual private-key protection.
    if ($output | Where-Object { $_ -match '^Entry type: PrivateKeyEntry' }) {
        Write-Fail "$Label contains a PrivateKeyEntry -- this truststore must hold only trustedCertEntry records."
        return
    }
    Write-Ok "$Label contains cert with subject matching: $ExpectedSubject"
}

function Test-UserEnvVar {
    param([string]$JksPath)

    $envValue = [Environment]::GetEnvironmentVariable($JvmWindowsEnvVarName, [EnvironmentVariableTarget]::User)
    if (-not $envValue) {
        Write-Fail "User-scope $JvmWindowsEnvVarName is not set in HKCU\Environment"
        return
    }

    # Match either quoted or unquoted trustStore=...path against the expected JKS.
    # Both branches anchor the end so a path like `$JksPath.bak.pkcs12` doesn't
    # false-positive as a prefix-match of `$JksPath`.
    $quotedPattern   = 'trustStore="'  + [regex]::Escape($JksPath) + '"'
    $unquotedPattern = 'trustStore='   + [regex]::Escape($JksPath) + '(\s|$)'
    if ($envValue -match $quotedPattern -or $envValue -match $unquotedPattern) {
        Write-Ok ("User-scope {0} points at {1}" -f $JvmWindowsEnvVarName, $JksPath)
    } else {
        Write-Fail "User-scope $JvmWindowsEnvVarName does not reference $JksPath (got: $envValue)"
    }

    # The JVM resolution order is process > User > Machine. A Machine-scope
    # value would not override the User-scope one for the current process,
    # but mixed scopes confuse onboarding ("I see two different paths in
    # `setx /M JAVA_TOOL_OPTIONS`!"). Surface it as a warning rather than
    # let it lurk silently.
    $machineValue = [Environment]::GetEnvironmentVariable($JvmWindowsEnvVarName, [EnvironmentVariableTarget]::Machine)
    if ($machineValue) {
        Write-Warn ("Machine-scope {0} is ALSO set (value: {1}). v1 only manages User-scope; consider clearing the Machine-scope value if it's stale." -f $JvmWindowsEnvVarName, $machineValue)
    }
}

function Main {
    Write-Host ("Expected subject (case-insensitive substring): {0}" -f $ExpectedSubject)
    Write-Host ""

    $jksPath = Get-JvmWindowsJksPath
    Test-KeystoreContainsSubject -Keystore $jksPath -Password $JvmWindowsJksPassword -Label ("Truststore {0}" -f $jksPath)
    Test-UserEnvVar -JksPath $jksPath

    Write-Host "---------------------------------------------------"
    if ($script:FailCount -eq 0) {
        if ($script:WarnCount -eq 0) {
            Write-Host "Result: All checks passed."
        } else {
            Write-Host ("Result: All checks passed (with {0} warning(s) -- see above)." -f $script:WarnCount)
        }
        exit 0
    } else {
        Write-Host ("Result: {0} check(s) failed (and {1} warning(s))." -f $script:FailCount, $script:WarnCount)
        exit 1
    }
}

Main
