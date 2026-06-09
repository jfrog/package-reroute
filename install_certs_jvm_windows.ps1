# (c) JFrog Ltd. (2026)
# Install a custom CA certificate on Windows for JVM clients (Maven, Gradle,
# sbt, Apache Ivy).
#
# Single path: build a per-user JKS truststore at
#   %LOCALAPPDATA%\JFrog\package-route-jvm\truststore.jks
# containing only the customer CA, then set JAVA_TOOL_OPTIONS at User scope
# (HKCU\Environment + WM_SETTINGCHANGE broadcast) so every new JVM startup
# inherits the trustStore path.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File install_certs_jvm_windows.ps1 -UseCert C:\path\to\ca.pem [-CertName <name>]
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
    [string]$UseCert,

    [Parameter(Mandatory = $false)]
    [string]$CertName
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
. (Join-Path $ScriptDir '_jvm_windows_paths.ps1')

if (-not $CertName) {
    $CertName = $JvmWindowsDefaultCertBasename
}

function Show-Usage {
    @'
Usage:
  powershell -ExecutionPolicy Bypass -File install_certs_jvm_windows.ps1 -UseCert <path> [-CertName <name>]

Parameters:
  -UseCert <path>        Path to an existing PEM/CRT certificate file (required).
                         Validation: parseable X.509, not expired, basicConstraints CA:TRUE.
  -CertName <name>       Alias under which the CA is stored inside the JKS
                         truststore (default: package-route-custom-ca). Cosmetic --
                         affects only `keytool -list` output. JKS path and env
                         var name are fixed per-user.

Notes:
  No -AllUsers flag -- User-scope env var is per-user by construction; each
  developer runs the installer in their own session. There is no -Mode
  flag (no OS-trust fallback by design: Windows-ROOT is not exposed in v1
  -- the daemon stale-cache issue gradle/gradle#6584 is fixed in Gradle 8.3,
  but the JKS recipe stays uniform across platforms).

Examples:
  powershell -File install_certs_jvm_windows.ps1 -UseCert C:\tmp\ZscalerRoot.pem
  powershell -File install_certs_jvm_windows.ps1 -UseCert C:\tmp\ca.pem -CertName zscaler-root
'@
}

function Test-CertName {
    param([string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') {
        Write-Error "Error: -CertName must match [A-Za-z0-9._-]+ (got: $Name). Path-traversal characters are rejected."
        exit 1
    }
}

# Port of the Linux/macOS hardened validate_pem. Uses the built-in
# System.Security.Cryptography.X509Certificates type so it works without
# openssl on stock Windows (PowerShell 5.1+ ships .NET; PowerShell 7
# bundles its own .NET runtime). Rejects: not parseable, expired,
# CA:FALSE (leaf cert). Warns on: expiring within 30 days, multi-cert
# bundle (keytool -importcert -noprompt reads only the first cert).
function Test-CaCertificate {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Error "Error: certificate file not found: $Path"
        exit 1
    }

    # C1 cross-platform parity (matches Linux + macOS siblings): require PEM
    # text input. X509Certificate2 happily parses DER, but the bash siblings
    # reject DER for predictable cross-platform behaviour, and keytool's
    # -importcert in PEM-text mode is what we exercise downstream.
    $textPeek = [System.IO.File]::ReadAllText($Path)
    if ($textPeek -notmatch '-----BEGIN CERTIFICATE-----') {
        Write-Error "Error: certificate is not PEM-encoded: $Path. If it's DER, convert first: openssl x509 -inform der -in $Path -out $Path.pem"
        exit 1
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $cert = $null
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$bytes)
    } catch {
        Write-Error "Error: invalid PEM/CRT certificate file: $Path ($($_.Exception.Message))"
        exit 1
    }

    # Reject expired anchors: keytool -importcert -noprompt accepts them silently
    # and the user gets cryptic CertificateExpiredException at TLS handshake time.
    $now = [DateTime]::UtcNow
    if ($cert.NotAfter.ToUniversalTime() -lt $now) {
        Write-Error "Error: certificate has already expired: $Path (NotAfter=$($cert.NotAfter))"
        exit 1
    }

    # Warn (don't fail) on a cert expiring within 30 days.
    # I23 parity: the 30-day window matches Linux JVM_LINUX_EXPIRY_WARN_SECONDS
    # (_jvm_linux_paths.sh, 2592000s = 30d) and the macOS `-checkend 2592000`
    # sibling. Change all three together -- there is no single source of truth
    # across the three platforms.
    if ($cert.NotAfter.ToUniversalTime() -lt $now.AddDays(30)) {
        Write-Warning ("certificate expires within 30 days: {0} (NotAfter={1})" -f $Path, $cert.NotAfter)
    }

    # Reject leaf certs: a cert without CA:TRUE in basicConstraints will import
    # into a JKS truststore but PKIX path-building won't use it as a trust anchor.
    #
    # Caveat (matches Linux/macOS siblings): a cert that OMITS the
    # basicConstraints extension entirely (rare on modern roots; legal for
    # some legacy self-signed CAs) is treated as "don't know, allow" -- same
    # behavior as OpenSSL's `-ext basicConstraints` returning empty. PKIX
    # will then accept the cert as a trust anchor based on its keyUsage /
    # explicit-trust-anchor status. The hard rejection only fires when the
    # extension is present and explicitly says CA:FALSE.
    $bcExt = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' } | Select-Object -First 1
    if ($bcExt) {
        $bc = [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]$bcExt
        if (-not $bc.CertificateAuthority) {
            Write-Error "Error: certificate is not a CA (basicConstraints CA:FALSE): $Path. JKS imports succeed but PKIX rejects non-CA trust anchors."
            exit 1
        }
    }

    # Warn on bundles: keytool -importcert -noprompt reads only the first cert,
    # silently dropping intermediates. Count `BEGIN CERTIFICATE` markers in
    # the file (works on both binary DER and text PEM -- DER files have 0).
    $content = [System.IO.File]::ReadAllText($Path)
    $count = ([regex]::Matches($content, '-----BEGIN CERTIFICATE-----')).Count
    if ($count -gt 1) {
        Write-Warning ("PEM file contains {0} certificates; only the first will be imported as the JVM trust anchor. Supply only the root CA (or split the bundle) if intermediates are needed." -f $count)
    }
}

# Locate keytool. Prefer JAVA_HOME\bin (set by actions/setup-java and by
# standard JDK installers); fall back to PATH for IDE-bundled JBR setups
# that aren't reflected in JAVA_HOME.
function Resolve-Keytool {
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
    return $null
}

# Locate the JDK's default cacerts file. Mirrors the Linux + macOS siblings:
# -Djavax.net.ssl.trustStore in OpenJDK REPLACES the JVM trust source rather
# than extending it -- pointing JVMs at a JKS holding only the corporate CA
# would break every public-CA TLS handshake. Copy the JDK's bundled cacerts
# into the target keystore first, then keytool -importcert appends the
# corporate CA, so the merged store has ~150 public roots PLUS the corporate
# one.
#
# Resolution: $JAVA_HOME first, then dir-of-keytool/../lib/security/cacerts
# (works for stock Adoptium / Corretto / Microsoft / Zulu JDK layouts where
# bin/keytool.exe and lib/security/cacerts are siblings under the JDK home).
function Resolve-JdkCacerts {
    if ($env:JAVA_HOME) {
        $candidate = Join-Path $env:JAVA_HOME 'lib\security\cacerts'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    $keytool = Resolve-Keytool
    if ($keytool) {
        $keytoolDir = Split-Path -Parent $keytool
        $candidate  = Join-Path $keytoolDir '..\lib\security\cacerts'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    Write-Error @'
Error: cannot locate the JDK's default cacerts file.
  Set JAVA_HOME, or ensure keytool.exe resolves under a standard JDK bin/ layout.
  Tried: $JAVA_HOME\lib\security\cacerts, <dir-of-keytool>\..\lib\security\cacerts
'@
    exit 1
}

function Require-Keytool {
    $kt = Resolve-Keytool
    if (-not $kt) {
        Write-Error @'
Error: keytool.exe not found.
  - Install a JDK (Adoptium Temurin, Amazon Corretto, Microsoft Build of OpenJDK, Azul Zulu, etc.)
  - Ensure JAVA_HOME points at the JDK install dir, OR add $JAVA_HOME\bin to PATH.
'@
        exit 1
    }

    # Probe `keytool -help` to reject corrupt 0-byte stubs (leftover from a
    # failed JDK uninstall) and to catch broken-runtime cases where the
    # binary exists but won't execute cleanly. EAP=Continue around the call
    # because some JDKs print informational lines to stderr even on -help.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $probeOutput = & $kt -help 2>&1
    } catch {
        $ErrorActionPreference = $prevEAP
        Write-Error "Error: keytool.exe at $kt threw on probe: $($_.Exception.Message). Reinstall the JDK."
        exit 1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Error ("Error: keytool.exe at {0} does not execute cleanly (rc={1}). Reinstall the JDK.`nProbe output (first 5 lines):`n  {2}" `
            -f $kt, $LASTEXITCODE, (($probeOutput | Select-Object -First 5) -join "`n  "))
        exit 1
    }

    return $kt
}

function Build-JksTruststore {
    param(
        [string]$JksPath,
        [string]$CertPath,
        [string]$Alias,
        [string]$Password
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

    $keytool = Require-Keytool
    $srcCacerts = Resolve-JdkCacerts
    Write-Host ("  [JKS] Building truststore at {0} (extending {1})" -f $JksPath, $srcCacerts)

    # Copy the JDK's bundled cacerts (~150 public root CAs) as the base so the
    # merged store keeps trusting Maven Central, Let's Encrypt, etc. Without
    # this, -Djavax.net.ssl.trustStore would REPLACE the JVM's trust source
    # and break every public-CA handshake. Copy-Item -Force overwrites any
    # prior JKS, guaranteeing idempotent end-state: each run starts from the
    # canonical JDK cacerts plus exactly one corporate-CA alias.
    Copy-Item -LiteralPath $srcCacerts -Destination $JksPath -Force

    # keytool.exe writes "Certificate was added to keystore" to STDERR (yes,
    # really -- it's been doing this since the Sun era). Under
    # $ErrorActionPreference='Stop' PowerShell promotes any native-command
    # stderr output to a terminating error before 2>&1 has a chance to
    # capture it. Switch to Continue for the duration of the call so we can
    # examine $LASTEXITCODE ourselves.
    #
    # Maintenance note: $prevEAP captures the script-scope EAP. Today that's
    # 'Stop' (line 33). If the script-scope default ever changes, this
    # restore-via-finally still restores to whatever was set -- but the
    # rest of the script's stop-on-error contract would then have to be
    # re-audited.
    #
    # No -storetype flag: modern JDKs default cacerts to PKCS12 and keytool
    # autodetects the format from the existing file.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $keytoolOutput = & $keytool `
            -importcert -noprompt `
            -alias  $Alias `
            -file   $CertPath `
            -keystore $JksPath `
            -storepass $Password 2>&1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Error ("Error: keytool -importcert failed for {0}.`nOutput:`n  {1}" -f $JksPath, ($keytoolOutput -join "`n  "))
        exit 1
    }

    # keytool emits stderr warnings (JKS deprecation on JDK 17+, weak-algo
    # advisories, etc.) WITH rc=0. The success branch should surface them
    # rather than silently discard, otherwise customers see no warning until
    # JDK 25 makes JKS read-only.
    if ($keytoolOutput) {
        $kOut = ($keytoolOutput | Where-Object { $_ -and $_.ToString().Trim() }) -join "`n  "
        if ($kOut) {
            Write-Host "  [JKS] keytool output:`n  $kOut"
        }
    }

    # Post-import verification: a JBR-bundled keytool can rc=0 without
    # actually writing a trustedCertEntry if the JKS provider was stripped
    # from java.security. Confirm the entry exists; on mismatch hard-fail
    # so the operator can switch to a real JDK keytool.
    $ErrorActionPreference = 'Continue'
    try {
        $listOutput = & $keytool -list -keystore $JksPath -storepass $Password 2>&1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if (-not ($listOutput | Select-String -Pattern 'trustedCertEntry' -Quiet)) {
        Write-Error ("Error: keytool -importcert reported rc=0 but the keystore at {0} contains no trustedCertEntry. The resolved keytool ({1}) may be an IDE-bundled JBR with a non-standard provider list. Try a stock JDK (Adoptium / Corretto)." `
            -f $JksPath, $keytool)
        exit 1
    }

    Write-Host ("  [JKS] OK: alias={0}" -f $Alias)
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
        [string]$Alias,
        [string]$JtoValue
    )

    Write-Host ""
    Write-Host "Truststore:"
    Write-Host ("  {0} (alias: {1})" -f $JksPath, $Alias)
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
    if (-not (Test-Path -LiteralPath $UseCert -PathType Leaf)) {
        Write-Error "Error: certificate file not found: $UseCert"
        exit 1
    }
    Test-CertName $CertName
    Test-CaCertificate -Path $UseCert

    $jksPath = Get-JvmWindowsJksPath
    Build-JksTruststore `
        -JksPath  $jksPath `
        -CertPath $UseCert `
        -Alias    $CertName `
        -Password $JvmWindowsJksPassword

    $jtoValue = Set-JavaToolOptions `
        -JksPath  $jksPath `
        -Password $JvmWindowsJksPassword

    Show-DoneSummary -JksPath $jksPath -Alias $CertName -JtoValue $jtoValue
}

Main
