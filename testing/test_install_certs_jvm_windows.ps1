# (c) JFrog Ltd. (2026)
# Smoke matrix for install_certs_jvm_windows.ps1 + validate_certs_jvm_windows.ps1.
#
# Run from the repo root:
#   powershell -ExecutionPolicy Bypass -File testing/test_install_certs_jvm_windows.ps1
#
# No Administrator required -- User-scope env vars and %LOCALAPPDATA% paths
# are per-user. The runner builds a bundled truststore fixture from Windows
# LocalMachine root certificates plus a lab CA, then verifies the installer only
# copies that ready-made JKS into place and configures HKCU\Environment.
#
# Invariants exercised:
#   1. Positive install + validate (subject substring match)
#   2. Subject mismatch -> exit 1
#   3. Idempotent re-install (copied JKS checksum stable; env var replaced)
#   4. Missing / empty truststore paths are rejected
#   5. User-scope JAVA_TOOL_OPTIONS references the expected JKS
#   6. JTO env var REPLACES (not appends) on re-install
#   7. Mandatory -UseTruststore: no-args invocation fails non-interactively
#   8. Installed JKS preserves public roots from the bundled truststore
#   9. Installed JKS contains a well-known public root (DigiCert family)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail-Test { param([string]$Msg) Write-Host "BUG: $Msg" -ForegroundColor Red; exit 1 }

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $RepoRoot

# Locate openssl. windows-latest GHA runners have Git for Windows preinstalled,
# which bundles openssl at C:\Program Files\Git\usr\bin\openssl.exe. Also try
# Strawberry Perl's openssl. The test needs openssl only to mint the lab CA
# that goes into the bundled truststore fixture; the installer itself does not.
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
    Fail-Test 'no openssl.exe found (need Git for Windows or similar to build the test fixture)'
}
Write-Host ("Using openssl: {0}" -f $OpenSsl)
Write-Host ((& $OpenSsl version) 2>&1)

$JvmWindowsJksRelativeDir = 'JFrog\package-route-jvm'
$JvmWindowsJksBasename = 'truststore.jks'
function Get-JvmWindowsJksPath {
    Join-Path $env:LOCALAPPDATA (Join-Path $JvmWindowsJksRelativeDir $JvmWindowsJksBasename)
}

$JksPath   = Get-JvmWindowsJksPath
$JksDir    = Split-Path -Parent $JksPath
$LabSubj   = 'Lab JVM Win CA Test'
$BundleJks = 'C:\Windows\Temp\jvm-win-bundled-truststore.jks'

function Cleanup {
    # Reset JAVA_TOOL_OPTIONS regardless of prior state. Setting to $null
    # via SetEnvironmentVariable deletes the value.
    [Environment]::SetEnvironmentVariable('JAVA_TOOL_OPTIONS', $null, [EnvironmentVariableTarget]::User)
    if (Test-Path -LiteralPath $JksDir) {
        try {
            Remove-Item -LiteralPath $JksDir -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "Cleanup: could not remove $JksDir ($($_.Exception.Message)). A previous process may still hold a file handle; subsequent tests will likely fail."
        }
    }
    Remove-Item -LiteralPath 'C:\Windows\Temp\jvm-win-empty-truststore.jks' -ErrorAction SilentlyContinue
}

function Final-Cleanup {
    Cleanup
    Remove-Item -LiteralPath $BundleJks -ErrorAction SilentlyContinue
}

try {

Cleanup

# --- Generate the lab CA used by the bundled truststore fixture ---
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

function Invoke-Installer {
    param([string[]]$ScriptArgs, [switch]$ExpectFail)
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

function Get-Keytool {
    if ($env:JAVA_HOME) {
        $kt = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
        if (Test-Path -LiteralPath $kt) { return $kt }
    }
    $cmd = Get-Command keytool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Fail-Test 'keytool.exe not on PATH (need JAVA_HOME set or actions/setup-java for validator/test fixture)'
}
$Keytool = Get-Keytool

function Invoke-Keytool {
    param([string[]]$KeytoolArgs)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $rc = 0
    try {
        $out = & $Keytool @KeytoolArgs 2>&1
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($rc -ne 0) {
        Fail-Test ("keytool exited {0}: {1}" -f $rc, (($out | Select-Object -First 5) -join '; '))
    }
    return $out
}

function Build-BundledTruststore {
    param([string]$CaPath)
    Remove-Item -LiteralPath $BundleJks -ErrorAction SilentlyContinue
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File '.\build_jvm_truststore_windows.ps1' `
        -UseCert $CaPath `
        -Output $BundleJks 2>&1
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Write-Host "--- captured output ---"
        Write-Host ($raw | Out-String)
        Write-Host "--- end captured output ---"
        Fail-Test "build_jvm_truststore_windows.ps1 exited $rc"
    }
    Write-Host ("Bundled truststore fixture: {0}" -f $BundleJks)
}

Build-BundledTruststore -CaPath $labCa

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 1. positive: install + validate ==="
Cleanup
Invoke-Installer -ScriptArgs @('-UseTruststore', $BundleJks) | Out-Null
Invoke-Validator -ScriptArgs @('-ExpectedSubject', $LabSubj) | Out-Null
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 2. negative: subject mismatch must exit 1 ==="
Invoke-Validator -ScriptArgs @('-ExpectedSubject', 'Microsoft Root CA NoMatch') -ExpectFail | Out-Null
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 3. idempotency: 2nd install preserves bundled JKS / single env value ==="
Invoke-Installer -ScriptArgs @('-UseTruststore', $BundleJks) | Out-Null
Invoke-Validator -ScriptArgs @('-ExpectedSubject', $LabSubj) | Out-Null

$bundleHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $BundleJks).Hash
$installedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $JksPath).Hash
if ($installedHash -ne $bundleHash) {
    Fail-Test "installed JKS checksum differs from bundled truststore"
}

$listOut = Invoke-Keytool -KeytoolArgs @('-list', '-keystore', $JksPath, '-storepass', 'changeit')
$aliasCount = (($listOut | Select-String 'trustedCertEntry').Matches.Count)
$corpCount = (($listOut | Select-String '^package-route-custom-ca[,\s]').Matches.Count)
if ($corpCount -ne 1) {
    Fail-Test "expected exactly 1 corporate-CA alias after 2 installs, got $corpCount"
}
if ($aliasCount -lt 100) {
    Fail-Test "expected JKS to preserve bundled public roots (>=100 aliases), got $aliasCount"
}
Write-Host ("  ok (alias_count={0}, corp_alias_count={1}, sha={2})" -f $aliasCount, $corpCount, $installedHash)

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 4. negative: missing truststore path rejected ==="
Invoke-Installer -ScriptArgs @('-UseTruststore', 'C:\Windows\Temp\no-such-jvm-truststore.jks') -ExpectFail | Out-Null
Write-Host "  ok"

Write-Host ""
Write-Host "=== 5. negative: empty truststore rejected ==="
'' | Set-Content -LiteralPath 'C:\Windows\Temp\jvm-win-empty-truststore.jks' -NoNewline
Invoke-Installer -ScriptArgs @('-UseTruststore', 'C:\Windows\Temp\jvm-win-empty-truststore.jks') -ExpectFail | Out-Null
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 6. User-scope JAVA_TOOL_OPTIONS references the expected JKS ==="
Cleanup
Invoke-Installer -ScriptArgs @('-UseTruststore', $BundleJks) | Out-Null
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
Write-Host "=== 7. JTO env var REPLACES (not appends) on re-install ==="
[Environment]::SetEnvironmentVariable('JAVA_TOOL_OPTIONS', '-Dpackage-reroute-test-sentinel=must-be-replaced', [EnvironmentVariableTarget]::User)
Invoke-Installer -ScriptArgs @('-UseTruststore', $BundleJks) | Out-Null
$post = [Environment]::GetEnvironmentVariable('JAVA_TOOL_OPTIONS', [EnvironmentVariableTarget]::User)
if ($post -match 'package-reroute-test-sentinel') {
    Fail-Test "JTO env var was APPENDED to (sentinel survived). Re-install must replace. got: $post"
}
Write-Host "  ok"

#-----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 8. -UseTruststore mandatory: no-args invocation fails ==="
$out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File '.\install_certs_jvm_windows.ps1' 2>&1
$rc8 = $LASTEXITCODE
if ($rc8 -eq 0) {
    Write-Host $out
    Fail-Test 'installer should have rejected no-args invocation (rc=0)'
}
Write-Host "  ok (rc=$rc8)"

#-----------------------------------------------------------------------------
Cleanup
Invoke-Installer -ScriptArgs @('-UseTruststore', $BundleJks) | Out-Null

Write-Host ""
Write-Host "=== 9. JKS preserves bundled public roots ==="
$listOut9 = Invoke-Keytool -KeytoolArgs @('-list', '-keystore', $JksPath, '-storepass', 'changeit')
$aliasCount = (($listOut9 | Select-String 'trustedCertEntry').Matches.Count)
if ($aliasCount -lt 100) {
    Fail-Test "JKS has $aliasCount aliases; expected >= 100 (bundled public roots + corporate CA)"
}
Write-Host ("  ok ({0} aliases)" -f $aliasCount)

Write-Host ""
Write-Host "=== 10. JKS contains a well-known public root (DigiCert family) ==="
$listOut10 = Invoke-Keytool -KeytoolArgs @('-list', '-v', '-keystore', $JksPath, '-storepass', 'changeit')
if (-not ($listOut10 | Select-String -Pattern 'digicert' -SimpleMatch -Quiet)) {
    Fail-Test "JKS missing the DigiCert family of public roots; the bundled truststore fixture is incomplete"
}
Write-Host "  ok"

Write-Host ""
Write-Host "================================================================="
Write-Host "ALL SMOKE TESTS PASSED"
Write-Host "================================================================="

# Test #8 deliberately spawns a child powershell.exe invocation that exits
# non-zero. Reset LASTEXITCODE so the outer shell sees the aggregate result.
$global:LASTEXITCODE = 0

} finally {
    Final-Cleanup
}

exit 0
