# (c) JFrog Ltd. (2026)
# Smoke matrix for install_certs_jvm_windows.ps1 + validate_certs_jvm_windows.ps1.
#
# Run from the repo root:
#   powershell -ExecutionPolicy Bypass -File testing/test_install_certs_jvm_windows.ps1
#
# No Administrator required -- User-scope env vars and %LOCALAPPDATA% paths
# are per-user. The runner uses the *current* user's profile and HKCU.
# Idempotent end-state via try/finally cleanup.
#
# Invariants exercised:
#   1. Positive install + validate (subject substring match)
#   2. Subject mismatch -> exit 1
#   3. Idempotent re-install (single JKS alias after 2 runs; env var replaced)
#   4. Custom -CertName round-trips (alias inside JKS = cert-name)
#   5. Path-traversal -CertName rejected
#   6. Malformed PEM rejected
#   7. Expired CA rejected (skip if openssl can't produce one verifiably-expired)
#   8. Leaf cert (CA:FALSE) rejected
#   9. After install, [Environment]::GetEnvironmentVariable('JAVA_TOOL_OPTIONS','User')
#      returns a string referencing the expected JKS path
#  10. validate_pem 30-day-expiry warn fires (cert valid <30d still installs)
#  11. validate_pem multi-cert bundle warn fires
#  12. JTO env var REPLACES (not appends) on re-install: pre-seed a stale value,
#      run installer, assert old value is gone
#  13. Missing keytool fails cleanly: clear PATH+JAVA_HOME and assert exit 1
#  14. Mandatory -UseCert: invoke with no args, assert non-interactive exit 1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail-Test { param([string]$Msg) Write-Host "BUG: $Msg" -ForegroundColor Red; exit 1 }

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $RepoRoot

# Locate openssl. windows-latest GHA runners have Git for Windows preinstalled,
# which bundles openssl at C:\Program Files\Git\usr\bin\openssl.exe. Also try
# Strawberry Perl's openssl. Don't fall back silently -- `where openssl` could
# return LibreSSL-equivalent if anything in PATH is malformed.
$OpenSsl = $null
$candidates = @(
    'C:\Program Files\Git\usr\bin\openssl.exe',
    'C:\Strawberry\c\bin\openssl.exe'
)
foreach ($cand in $candidates) {
    if (Test-Path -LiteralPath $cand -PathType Leaf) {
        $OpenSsl = $cand; break
    }
}
if (-not $OpenSsl) {
    $cmd = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if ($cmd) { $OpenSsl = $cmd.Source }
}
if (-not $OpenSsl) {
    Fail-Test 'no openssl.exe found (need Git for Windows or similar)'
}
Write-Host ("Using openssl: {0}" -f $OpenSsl)
$openSslVersionLine = (& $OpenSsl version) 2>&1
Write-Host $openSslVersionLine

# Test #7 (expired CA) uses OpenSSL 3.2+'s -not_before/-not_after flags.
# windows-latest currently ships 3.5.x via Git for Windows. If that ever
# regresses below 3.2 the test silently SKIPs -- surface a yellow flag now
# so a future maintainer sees the version drift in the CI run summary.
if ($openSslVersionLine -match 'OpenSSL\s+(\d+)\.(\d+)') {
    $major = [int]$matches[1]
    $minor = [int]$matches[2]
    if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 2)) {
        Write-Warning ("Detected OpenSSL {0}.{1}, but test #7 (expired CA) requires 3.2+ for -not_before / -not_after. It will SKIP." -f $major, $minor)
    }
}

. (Join-Path $RepoRoot '_jvm_windows_paths.ps1')
$JksPath  = Get-JvmWindowsJksPath
$JksDir   = Split-Path -Parent $JksPath
$LabSubj  = 'Lab JVM Win CA Test'

function Cleanup {
    # Reset JAVA_TOOL_OPTIONS regardless of prior state. Setting to $null
    # via SetEnvironmentVariable deletes the value.
    [Environment]::SetEnvironmentVariable('JAVA_TOOL_OPTIONS', $null, [EnvironmentVariableTarget]::User)
    if (Test-Path -LiteralPath $JksDir) {
        # I12: probe-then-warn rather than -ErrorAction SilentlyContinue.
        # Silent failure here hides locked files left by a leaked keytool.exe
        # child from a previous test crash, which then surface as a confusing
        # error inside the NEXT test's Build-JksTruststore.
        try {
            Remove-Item -LiteralPath $JksDir -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "Cleanup: could not remove $JksDir ($($_.Exception.Message)). A previous keytool.exe child may still hold a file handle; subsequent tests will likely fail."
        }
    }
}

# Run cleanup unconditionally on exit so re-running after a partial failure
# starts from the same baseline.
try {

Cleanup

# --- Generate the lab CA used by all positive cases ---
$labKey = 'C:\Windows\Temp\jvm-win-test-k.pem'
$labCa  = 'C:\Windows\Temp\jvm-win-test-ca.pem'
Remove-Item -LiteralPath $labKey, $labCa -ErrorAction SilentlyContinue
& $OpenSsl req -x509 -newkey rsa:2048 -nodes `
    -keyout $labKey -out $labCa -days 7 `
    -subj "/CN=$LabSubj/O=JFrog" `
    -addext 'basicConstraints=critical,CA:TRUE' 2>&1 | Out-Null
if (-not (Test-Path -LiteralPath $labCa)) {
    Fail-Test "openssl req failed to produce $labCa"
}

# Run installer/validator as a child powershell.exe and capture combined
# output via Tee-Object -- Tee writes BOTH to the file AND down the pipeline.
# We pass the pipeline through Out-String to flatten formatted records and
# return the joined string. On unexpected exit the caller can dump the
# captured output via Write-Host.
#
# Don't name the parameter $Args -- that's a PowerShell automatic variable
# that collides with @Args splat semantics inside the function body and
# silently turns into an empty array.
function Invoke-Installer {
    param([string[]]$ScriptArgs, [switch]$ExpectFail)
    # C1 fix: capture $LASTEXITCODE IMMEDIATELY after the native call, BEFORE
    # the Out-String pipeline. With `$ErrorActionPreference='Stop'` plus
    # `Set-StrictMode -Version Latest` a downstream pipeline element raising
    # any error would jump past `$rc = $LASTEXITCODE` and leave $rc carrying
    # the value from a previous step -- which can flip an `-ExpectFail`
    # assertion into a phantom pass.
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File '.\install_certs_jvm_windows.ps1' @ScriptArgs 2>&1
    $rc  = $LASTEXITCODE
    $out = $raw | Out-String
    if ($ExpectFail) {
        if ($rc -eq 0) {
            Write-Host "--- captured output ---"
            Write-Host $out
            Write-Host "--- end captured output ---"
            Fail-Test "installer was expected to exit non-zero, got 0 (args: $($ScriptArgs -join ' '))"
        }
    } else {
        if ($rc -ne 0) {
            Write-Host "--- captured output ---"
            Write-Host $out
            Write-Host "--- end captured output ---"
            Fail-Test "installer exited $rc unexpectedly (args: $($ScriptArgs -join ' '))"
        }
    }
    return $out
}

function Invoke-Validator {
    param([string[]]$ScriptArgs, [switch]$ExpectFail)
    # Same rc-capture-before-pipeline pattern as Invoke-Installer; see C1
    # comment there for the rationale.
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File '.\validate_certs_jvm_windows.ps1' @ScriptArgs 2>&1
    $rc  = $LASTEXITCODE
    $out = $raw | Out-String
    if ($ExpectFail) {
        if ($rc -eq 0) {
            Write-Host "--- captured output ---"
            Write-Host $out
            Write-Host "--- end captured output ---"
            Fail-Test "validator was expected to exit non-zero, got 0 (args: $($ScriptArgs -join ' '))"
        }
    } else {
        if ($rc -ne 0) {
            Write-Host "--- captured output ---"
            Write-Host $out
            Write-Host "--- end captured output ---"
            Fail-Test "validator exited $rc unexpectedly (args: $($ScriptArgs -join ' '))"
        }
    }
    return $out
}

# Find keytool for direct independent checks (alias count, etc.)
function Get-Keytool {
    if ($env:JAVA_HOME) {
        $kt = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
        if (Test-Path -LiteralPath $kt) { return $kt }
    }
    $cmd = Get-Command keytool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Fail-Test 'keytool.exe not on PATH (need JAVA_HOME set or actions/setup-java)'
}
$Keytool = Get-Keytool

# I10: wrap inline keytool calls with EAP=Continue. keytool -list on JDK 17+
# has been observed emitting crypto-policy notices and JKS-deprecation
# warnings to stderr at rc=0; under $ErrorActionPreference='Stop' those
# would terminate the test. Same pattern as install/validate scripts use.
function Invoke-Keytool {
    param([string[]]$KeytoolArgs)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Keytool @KeytoolArgs 2>&1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    return $out
}

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 1. positive: install + validate ==="
Cleanup
Invoke-Installer -ScriptArgs @('-UseCert', $labCa) | Out-Null
Invoke-Validator -ScriptArgs @('-ExpectedSubject', $LabSubj) | Out-Null
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 2. negative: subject mismatch must exit 1 ==="
Invoke-Validator -ScriptArgs @('-ExpectedSubject', 'Microsoft Root CA NoMatch') -ExpectFail | Out-Null
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 3. idempotency: 2nd install produces single alias / single env value ==="
Invoke-Installer -ScriptArgs @('-UseCert', $labCa) | Out-Null
Invoke-Validator -ScriptArgs @('-ExpectedSubject', $LabSubj) | Out-Null

$listOut = Invoke-Keytool -KeytoolArgs @('-list', '-keystore', $JksPath, '-storepass', 'changeit')
$aliasCount = (($listOut | Select-String 'trustedCertEntry').Matches.Count)
# JKS extends the JDK's bundled cacerts (~150 public roots) plus exactly one
# corporate-CA alias. After two installs, the corporate alias count must be
# exactly 1; the JDK-supplied aliases stay constant.
$corpCount = (($listOut | Select-String '^package-route-custom-ca[,\s]').Matches.Count)
if ($corpCount -ne 1) {
    Fail-Test "expected exactly 1 corporate-CA alias after 2 installs, got $corpCount"
}
if ($aliasCount -lt 100) {
    Fail-Test "expected JKS to extend default cacerts (>=100 aliases), got $aliasCount"
}
Write-Host ("  ok (alias_count={0}, corp_alias_count={1})" -f $aliasCount, $corpCount)

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 4. custom -CertName round-trips (alias inside JKS = cert-name) ==="
Cleanup
Invoke-Installer -ScriptArgs @('-UseCert', $labCa, '-CertName', 'zscaler-root') | Out-Null
$listOut = Invoke-Keytool -KeytoolArgs @('-list', '-keystore', $JksPath, '-storepass', 'changeit')
if (-not ($listOut | Select-String '^zscaler-root,')) {
    Fail-Test "expected JKS alias 'zscaler-root', got: $($listOut -join '; ')"
}
Invoke-Validator -ScriptArgs @('-ExpectedSubject', $LabSubj) | Out-Null
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 5. negative: path-traversal -CertName rejected ==="
Invoke-Installer -ScriptArgs @('-UseCert', $labCa, '-CertName', '..\etc\pwned') -ExpectFail | Out-Null
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 6. negative: malformed PEM rejected ==="
$badPem = 'C:\Windows\Temp\jvm-win-bad.pem'
'not a certificate' | Set-Content -LiteralPath $badPem -Encoding ASCII
Invoke-Installer -ScriptArgs @('-UseCert', $badPem) -ExpectFail | Out-Null
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 7. negative: expired CA rejected ==="
$expiredPem = 'C:\Windows\Temp\jvm-win-expired.pem'
Remove-Item -LiteralPath $expiredPem -ErrorAction SilentlyContinue
# Try OpenSSL 3.2+'s -not_before/-not_after.
& $OpenSsl req -x509 -newkey rsa:2048 -nodes `
    -keyout 'C:\Windows\Temp\jvm-win-expired-k.pem' -out $expiredPem `
    -subj '/CN=Expired/O=JFrog' `
    -addext 'basicConstraints=critical,CA:TRUE' `
    -not_before 20200101000000Z -not_after 20200201000000Z 2>&1 | Out-Null

# Verify the cert is actually expired before running the assertion.
$produced = Test-Path -LiteralPath $expiredPem
$stillValid = $false
if ($produced) {
    # Re-parse via .NET to confirm NotAfter < now (sidestep openssl -checkend).
    try {
        $bytes = [System.IO.File]::ReadAllBytes($expiredPem)
        $cert  = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$bytes)
        $stillValid = ($cert.NotAfter.ToUniversalTime() -ge [DateTime]::UtcNow)
    } catch {
        $produced = $false
    }
}
if (-not $produced -or $stillValid) {
    Write-Host "  SKIP: cannot produce a verifiably-expired cert with the installed openssl"
} else {
    Invoke-Installer -ScriptArgs @('-UseCert', $expiredPem) -ExpectFail | Out-Null
    Write-Host "  ok"
}

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 8. negative: leaf cert (CA:FALSE) rejected ==="
$leafPem = 'C:\Windows\Temp\jvm-win-leaf.pem'
& $OpenSsl req -x509 -newkey rsa:2048 -nodes `
    -keyout 'C:\Windows\Temp\jvm-win-leaf-k.pem' -out $leafPem -days 7 `
    -subj '/CN=Leaf Not CA' `
    -addext 'basicConstraints=critical,CA:FALSE' 2>&1 | Out-Null
Invoke-Installer -ScriptArgs @('-UseCert', $leafPem) -ExpectFail | Out-Null
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 9. User-scope JAVA_TOOL_OPTIONS references the expected JKS ==="
Cleanup
Invoke-Installer -ScriptArgs @('-UseCert', $labCa) | Out-Null
$jto = [Environment]::GetEnvironmentVariable('JAVA_TOOL_OPTIONS', [EnvironmentVariableTarget]::User)
if (-not $jto) {
    Fail-Test 'User-scope JAVA_TOOL_OPTIONS not set'
}
if (-not ($jto -like "*trustStore=*$JksPath*")) {
    Fail-Test ("JAVA_TOOL_OPTIONS doesn't reference expected JKS path. got: {0}" -f $jto)
}
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 10. validate_pem 30-day-expiry warn fires ==="
# Short-validity CA (1 day) -- within 30 days, should produce the expiry warn
# but install succeed.
$soonPem = 'C:\Windows\Temp\jvm-win-soon.pem'
& $OpenSsl req -x509 -newkey rsa:2048 -nodes `
    -keyout 'C:\Windows\Temp\jvm-win-soon-k.pem' -out $soonPem -days 1 `
    -subj '/CN=Soon to Expire/O=JFrog' `
    -addext 'basicConstraints=critical,CA:TRUE' 2>&1 | Out-Null
$out = Invoke-Installer -ScriptArgs @('-UseCert', $soonPem)
if (-not ($out -match 'certificate expires within 30 days')) {
    Write-Host $out
    Fail-Test '30-day expiry warn missing'
}
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 11. validate_pem multi-cert bundle warn fires ==="
# Multi-cert bundle: append a second cert to the test CA. The installer
# warns and imports only the first; install must still succeed.
$bundlePem = 'C:\Windows\Temp\jvm-win-bundle.pem'
Get-Content -LiteralPath $labCa, $soonPem | Set-Content -LiteralPath $bundlePem
$out = Invoke-Installer -ScriptArgs @('-UseCert', $bundlePem)
if (-not ($out -match 'PEM file contains \d+ certificates')) {
    Write-Host $out
    Fail-Test 'multi-cert bundle warn missing'
}
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 12. JTO env var REPLACES (not appends) on re-install ==="
# Pre-seed a junk value, run installer, assert the junk is gone.
[Environment]::SetEnvironmentVariable('JAVA_TOOL_OPTIONS', '-Dpackage-reroute-test-sentinel=must-be-replaced', [EnvironmentVariableTarget]::User)
Invoke-Installer -ScriptArgs @('-UseCert', $labCa) | Out-Null
$post = [Environment]::GetEnvironmentVariable('JAVA_TOOL_OPTIONS', [EnvironmentVariableTarget]::User)
if ($post -match 'package-reroute-test-sentinel') {
    Fail-Test "JTO env var was APPENDED to (sentinel survived). Re-install must replace. got: $post"
}
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 13. missing keytool fails cleanly ==="
# Run the installer in a child process with PATH stripped of all JDK
# locations and JAVA_HOME unset. Installer should error with our
# Require-Keytool message, not crash mid-Build-JksTruststore.
$strippedPath = 'C:\Windows;C:\Windows\System32'
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -Command "`$env:JAVA_HOME=`$null; `$env:PATH='$strippedPath'; & .\install_certs_jvm_windows.ps1 -UseCert '$labCa'" 2>&1
$rc13 = $LASTEXITCODE
if ($rc13 -eq 0) {
    Write-Host $out
    Fail-Test "installer should have rejected missing keytool (rc=0)"
}
if (-not ($out -match 'keytool')) {
    Write-Host $out
    Fail-Test "missing-keytool error message should mention 'keytool' (got rc=$rc13)"
}
Write-Host "  ok (rc=$rc13)"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 14. -UseCert mandatory: no-args invocation fails ==="
# Non-interactive PS prompts for mandatory params and then errors out.
# `pwsh -NonInteractive` ensures we don't hang waiting for input.
$out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File '.\install_certs_jvm_windows.ps1' 2>&1
$rc14 = $LASTEXITCODE
if ($rc14 -eq 0) {
    Write-Host $out
    Fail-Test 'installer should have rejected no-args invocation (rc=0)'
}
Write-Host "  ok (rc=$rc14)"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 15. negative: DER cert rejected (C1 cross-platform parity) ==="
# C1 backport: convert the lab CA to DER, then attempt install -- should
# fail with a hint to convert back. Mirrors Linux + macOS behavior so a fleet
# wrapper that hands the wrong format gets a uniform error across platforms.
$derPath = 'C:\Windows\Temp\jvm-win-test-ca.der'
Remove-Item -LiteralPath $derPath -ErrorAction SilentlyContinue
& openssl x509 -in $labCa -outform DER -out $derPath 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  SKIP: openssl unavailable to convert DER, can't run this test"
} else {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -Command "& .\install_certs_jvm_windows.ps1 -UseCert '$derPath'" 2>&1
    $rc15 = $LASTEXITCODE
    if ($rc15 -eq 0) {
        Write-Host $out
        Fail-Test "installer should have rejected DER-encoded cert (rc=0)"
    }
    if (-not ($out -match 'PEM-encoded')) {
        Write-Host $out
        Fail-Test "DER reject message should mention 'PEM-encoded' (got rc=$rc15)"
    }
    Write-Host "  ok (rc=$rc15)"
}

#-----------------------------------------------------------------------------
# Re-install once so the next two invariants observe the post-fix end state.
Cleanup
Invoke-Installer -ScriptArgs @('-UseCert', $labCa) | Out-Null

Write-Host ""
Write-Host "=== 16. JKS extends default cacerts (preserves public roots) ==="
# Regression guard for the "trustStore replaces, not extends" footgun.
# -Djavax.net.ssl.trustStore in OpenJDK swaps the JVM's trust source; a JKS
# holding only the corporate CA would break every public-CA TLS handshake
# (Maven Central, Gradle plugin portal, Let's Encrypt-fronted mirrors).
# Installer must therefore copy $JAVA_HOME\lib\security\cacerts first.
$listOut16  = Invoke-Keytool -KeytoolArgs @('-list', '-keystore', $JksPath, '-storepass', 'changeit')
$aliasCount = (($listOut16 | Select-String 'trustedCertEntry').Matches.Count)
if ($aliasCount -lt 100) {
    Fail-Test "JKS has $aliasCount aliases; expected >= 100 (JDK cacerts ~150 public roots + corporate CA)"
}
Write-Host ("  ok ({0} aliases)" -f $aliasCount)

Write-Host ""
Write-Host "=== 17. JKS contains a well-known public root (DigiCert family) ==="
# Spot-check the merge actually happened. DigiCert root certs ship in every
# JDK's cacerts under several aliases (digicertglobalrootca, digicertglobalrootg2,
# digicerttrustedrootg4, etc.) -- case-insensitive substring match catches them all.
$listOut17 = Invoke-Keytool -KeytoolArgs @('-list', '-keystore', $JksPath, '-storepass', 'changeit')
if (-not ($listOut17 | Select-String -Pattern 'digicert' -SimpleMatch -Quiet)) {
    Fail-Test "JKS missing the DigiCert family of public roots; the copy-from-JDK step did not run"
}
Write-Host "  ok"

Write-Host ""
Write-Host "================================================================="
Write-Host "ALL SMOKE TESTS PASSED"
Write-Host "================================================================="

# Tests #13 / #14 / #15 deliberately spawn child powershell.exe invocations
# that exit non-zero (Expected-Fail negative cases). Each leaves $LASTEXITCODE
# at the child's rc, which the outer `shell: pwsh` wrapper would inherit
# and report as a job failure. Explicit exit 0 here ensures the wrapper
# sees the runner's actual aggregate result.
$global:LASTEXITCODE = 0

} finally {
    Cleanup
}

exit 0
