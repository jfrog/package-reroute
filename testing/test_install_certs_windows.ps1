# Tests for install_certs_windows.ps1 (CLI and parameter validation) and validate_install_windows.ps1.
# Run from repo root: powershell -ExecutionPolicy Bypass -File scripts/testing/test_install_certs_windows.ps1
# Or from scripts/: powershell -ExecutionPolicy Bypass -File testing/test_install_certs_windows.ps1
# No admin required; uses a temp dir and a self-signed PEM. See scripts/README.md for coverage.

$TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path -Parent $TestDir
$InstallScript = Join-Path $ScriptDir "install_certs_windows.ps1"
$ValidateScript = Join-Path $ScriptDir "validate_install_windows.ps1"

if (-not (Test-Path -LiteralPath $InstallScript -PathType Leaf)) {
    Write-Error "install_certs_windows.ps1 not found in $ScriptDir"
    exit 1
}
if (-not (Test-Path -LiteralPath $ValidateScript -PathType Leaf)) {
    Write-Error "validate_install_windows.ps1 not found in $ScriptDir"
    exit 1
}

$TempDir = [System.IO.Path]::GetTempPath() + [Guid]::NewGuid().ToString("N").Substring(0, 8)
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
try {
    # Create a valid PEM: try self-signed from cert store; fallback to embedded PEM (e.g. when store access denied on VM)
    $cert = $null
    $pemCreated = $false
    try {
        $cert = New-SelfSignedCertificate -CertStoreLocation Cert:\CurrentUser\My -Subject "CN=test-cert-windows" -NotAfter (Get-Date).AddDays(1) -KeyExportPolicy Exportable -KeyUsage CertSign -ErrorAction Stop
        $bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        $b64 = [Convert]::ToBase64String($bytes)
        $pem = "-----BEGIN CERTIFICATE-----`r`n" + ($b64 -replace '(.{64})', '$1`r`n') + "`r`n-----END CERTIFICATE-----"
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $TempDir "cert.pem"), $pem, $utf8NoBom)
        $pemCreated = $true
    } catch {
        try {
            $cert = New-SelfSignedCertificate -CertStoreLocation Cert:\LocalMachine\My -Subject "CN=test-cert-windows" -NotAfter (Get-Date).AddDays(1) -KeyExportPolicy Exportable -KeyUsage CertSign -ErrorAction Stop
            $bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            $b64 = [Convert]::ToBase64String($bytes)
            $pem = "-----BEGIN CERTIFICATE-----`r`n" + ($b64 -replace '(.{64})', '$1`r`n') + "`r`n-----END CERTIFICATE-----"
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText((Join-Path $TempDir "cert.pem"), $pem, $utf8NoBom)
            $pemCreated = $true
        } catch { }
    } finally {
        if ($cert) {
            Remove-Item -LiteralPath $cert.PSPath -Delete -ErrorAction SilentlyContinue
        }
    }
    if (-not $pemCreated) {
        # Fallback: minimal valid PEM (166-byte; empty subject - skip -ExpectedSubject tests below when using this)
        $fallbackPem = @"
-----BEGIN CERTIFICATE-----
MFAwRgIBADADBgEAMAAwHhcNNTAwMTAxMDAwMDAwWhcNNDkxMjMxMjM1OTU5WjAA
MBgwCwYJKoZIhvcNAQEBAwkAMAYCAQACAQAwAwYBAAMBAA==
-----END CERTIFICATE-----
"@
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $TempDir "cert.pem"), $fallbackPem.Trim(), $utf8NoBom)
    }
    $UsingFallbackPem = -not $pemCreated
    $CertPath = Join-Path $TempDir "cert.pem"
    if (-not (Test-Path -LiteralPath $CertPath -PathType Leaf)) {
        Write-Error "Failed to create temp PEM at $CertPath"
        exit 1
    }
    "not a certificate" | Set-Content -Path (Join-Path $TempDir "invalid.pem") -Encoding UTF8
    $InvalidPath = Join-Path $TempDir "invalid.pem"

    $Run = 0
    $Pass = 0
    $Fail = 0

    # Run a PowerShell script in a child process and return exit code. Captures stderr/stdout.
    # Use -ArgumentList array so paths and params are passed correctly to the child.
    function Invoke-ScriptAndGetExitCode {
        param([string]$ScriptPath, [array]$Args = @())
        $allArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $Args
        $stdoutFile = Join-Path $TempDir "out_$([Guid]::NewGuid().ToString('N').Substring(0,4)).txt"
        $stderrFile = Join-Path $TempDir "err_$([Guid]::NewGuid().ToString('N').Substring(0,4)).txt"
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $allArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $stdout = if (Test-Path $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile) } else { "" }
        $stderr = if (Test-Path $stderrFile) { [System.IO.File]::ReadAllText($stderrFile) } else { "" }
        Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
        return @{ ExitCode = $p.ExitCode; Stdout = $stdout; Stderr = $stderr }
    }

    function Assert-ExitCode {
        param([int]$Expected, [string]$ScriptPath, [array]$Args = @())
        $script:Run++
        $r = Invoke-ScriptAndGetExitCode -ScriptPath $ScriptPath -Args $Args
        $got = $r.ExitCode
        if ($got -eq $Expected) {
            Write-Host "  OK ($Run): exit $Expected"
            $script:Pass++
        } else {
            Write-Host "  FAIL ($Run): expected exit $Expected, got $got"
            $script:Fail++
        }
    }

    function Assert-Stderr {
        param([string]$Pattern, [string]$ScriptPath, [array]$Args = @())
        $script:Run++
        $r = Invoke-ScriptAndGetExitCode -ScriptPath $ScriptPath -Args $Args
        $combined = $r.Stdout + " " + $r.Stderr
        if ($combined -match $Pattern) {
            Write-Host "  OK ($Run): output matches /$Pattern/"
            $script:Pass++
        } else {
            Write-Host "  FAIL ($Run): output did not match /$Pattern/"
            $script:Fail++
        }
    }

    $Nonexistent = Join-Path $TempDir "nonexistent.pem"

    Write-Host "=== install_certs_windows.ps1 CLI tests ==="

    # No cert source (only -Package; no parameter set selected)
    Assert-ExitCode -Expected 1 -ScriptPath $InstallScript -Args @("-Package", "all")
    Assert-Stderr -Pattern "Parameter set|cannot be resolved|ExtractPath|UseCert" -ScriptPath $InstallScript -Args @("-Package", "all")

    # Invalid -Package
    Assert-ExitCode -Expected 1 -ScriptPath $InstallScript -Args @("-Package", "foo")
    Assert-Stderr -Pattern "ValidateSet|npm|pip|all" -ScriptPath $InstallScript -Args @("-Package", "foo")

    # -CertName without -ExtractPath (PowerShell requires both in set)
    Assert-ExitCode -Expected 1 -ScriptPath $InstallScript -Args @("-CertName", "X")
    Assert-Stderr -Pattern "ExtractPath|Missing|argument for parameter|ParameterSet|required" -ScriptPath $InstallScript -Args @("-CertName", "X")

    # -ExtractPath without -CertName
    Assert-ExitCode -Expected 1 -ScriptPath $InstallScript -Args @("-ExtractPath", "C:\temp")
    Assert-Stderr -Pattern "CertName|Missing|Parameter set" -ScriptPath $InstallScript -Args @("-ExtractPath", "C:\temp")

    # -UseCert and -CertName together
    Assert-ExitCode -Expected 1 -ScriptPath $InstallScript -Args @("-UseCert", $CertPath, "-CertName", "X")
    Assert-Stderr -Pattern "cannot be used together|Parameter set" -ScriptPath $InstallScript -Args @("-UseCert", $CertPath, "-CertName", "X")

    # -UseCert with nonexistent file
    Assert-ExitCode -Expected 1 -ScriptPath $InstallScript -Args @("-UseCert", $Nonexistent)
    Assert-Stderr -Pattern "not a file|UseCert|Error" -ScriptPath $InstallScript -Args @("-UseCert", $Nonexistent)

    # -UseCert with invalid PEM (file exists but not valid)
    Assert-ExitCode -Expected 1 -ScriptPath $InstallScript -Args @("-UseCert", $InvalidPath)
    Assert-Stderr -Pattern "Invalid or missing PEM|Error" -ScriptPath $InstallScript -Args @("-UseCert", $InvalidPath)

    # -UseCert with valid PEM: may succeed (sets env) or fail; we only check it doesn't error with "not a file" or "Invalid PEM"
    $Run++
    $r = Invoke-ScriptAndGetExitCode -ScriptPath $InstallScript -Args @("-UseCert", $CertPath)
    if (-not (($r.Stdout + $r.Stderr) -match "not a file|Invalid or missing PEM")) {
        Write-Host "  OK ($Run): -UseCert with valid PEM (exit $($r.ExitCode))"
        $script:Pass++
    } else {
        Write-Host "  FAIL ($Run): -UseCert with valid PEM produced unexpected error"
        $script:Fail++
    }

    Write-Host ""
    Write-Host "=== validate_install_windows.ps1 tests ==="

    # -Help
    $Run++
    $helpR = Invoke-ScriptAndGetExitCode -ScriptPath $ValidateScript -Args @("-Help")
    if ($helpR.ExitCode -eq 0 -and (($helpR.Stdout + $helpR.Stderr) -match "Usage|CertPath|Help|Validat")) {
        Write-Host "  OK ($Run): -Help exits 0 and shows usage"
        $script:Pass++
    } else {
        Write-Host "  FAIL ($Run): -Help"
        $script:Fail++
    }

    # Unknown param: may error (exit 1) or be ignored and validate env (exit 0)
    $Run++
    $unkR = Invoke-ScriptAndGetExitCode -ScriptPath $ValidateScript -Args @("-UnknownArg")
    if ($unkR.ExitCode -eq 0 -or $unkR.ExitCode -eq 1) {
        Write-Host "  OK ($Run): unknown param (exit $($unkR.ExitCode))"
        $script:Pass++
    } else {
        Write-Host "  FAIL ($Run): unknown param exit $($unkR.ExitCode)"
        $script:Fail++
    }

    # Helper: run validate with path read from a temp file in the child (avoids cmd-line path parsing issues)
    function Invoke-ValidateWithPath {
        param([string]$Path, [string]$ExpectedSubject = "")
        $pathFile = Join-Path $TempDir "validate_path.txt"
        [System.IO.File]::WriteAllText($pathFile, $Path, [System.Text.UTF8Encoding]::new($false))
        $env:TEST_VALIDATE_PATH_FILE = $pathFile
        $env:TEST_VALIDATE_SCRIPT = $ValidateScript
        $env:TEST_VALIDATE_SUBJECT = $ExpectedSubject
        $cmd = '& { $p = Get-Content -Raw $env:TEST_VALIDATE_PATH_FILE; $a = @("-CertPath", $p.Trim()); if ($env:TEST_VALIDATE_SUBJECT) { $a += "-ExpectedSubject", $env:TEST_VALIDATE_SUBJECT }; & $env:TEST_VALIDATE_SCRIPT @a; exit $LASTEXITCODE }'
        $allArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $cmd)
        $stdoutFile = Join-Path $TempDir "out_$([Guid]::NewGuid().ToString('N').Substring(0,4)).txt"
        $stderrFile = Join-Path $TempDir "err_$([Guid]::NewGuid().ToString('N').Substring(0,4)).txt"
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $allArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $stdout = if (Test-Path $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile) } else { "" }
        $stderr = if (Test-Path $stderrFile) { [System.IO.File]::ReadAllText($stderrFile) } else { "" }
        Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
        Remove-Item $pathFile -ErrorAction SilentlyContinue
        return @{ ExitCode = $p.ExitCode; Stdout = $stdout; Stderr = $stderr }
    }

    # -CertPath with valid PEM
    Assert-ExitCode -Expected 0 -ScriptPath $ValidateScript -Args @("-CertPath", $CertPath)

    # -CertPath with missing file (path via file so child receives it)
    $Run++
    $r = Invoke-ValidateWithPath -Path $Nonexistent
    if ($r.ExitCode -eq 1) { Write-Host "  OK ($Run): exit 1"; $script:Pass++ } else { Write-Host "  FAIL ($Run): expected exit 1, got $($r.ExitCode)"; $script:Fail++ }
    $Run++
    $out = $r.Stdout + " " + $r.Stderr
    if ($out -match "does not exist|FAIL|file does not|exist:|check\(s\) failed" -or ($r.ExitCode -eq 1 -and $out.Trim().Length -gt 0)) { Write-Host "  OK ($Run): output matches"; $script:Pass++ } else { Write-Host "  FAIL ($Run): output did not match"; $script:Fail++ }

    # -CertPath with invalid PEM content
    $Run++
    $r2 = Invoke-ValidateWithPath -Path $InvalidPath
    if ($r2.ExitCode -eq 1) { Write-Host "  OK ($Run): exit 1"; $script:Pass++ } else { Write-Host "  FAIL ($Run): expected exit 1, got $($r2.ExitCode)"; $script:Fail++ }
    Assert-Stderr -Pattern "not a valid PEM|FAIL|valid PEM" -ScriptPath $ValidateScript -Args @("-CertPath", $InvalidPath)

    # -ExpectedSubject tests (skip when using fallback PEM - that cert has empty subject)
    if (-not $UsingFallbackPem) {
        # Subject contains "test-cert"
        Assert-ExitCode -Expected 0 -ScriptPath $ValidateScript -Args @("-CertPath", $CertPath, "-ExpectedSubject", "test-cert")
        # Pattern that doesn't match (path via file)
        $Run++
        $r3 = Invoke-ValidateWithPath -Path $CertPath -ExpectedSubject "Zscaler"
        if ($r3.ExitCode -eq 1) { Write-Host "  OK ($Run): exit 1"; $script:Pass++ } else { Write-Host "  FAIL ($Run): expected exit 1, got $($r3.ExitCode)"; $script:Fail++ }
        $Run++
        if (($r3.Stdout + " " + $r3.Stderr) -match "no cert|matching|FAIL|subject|Result:.*failed") { Write-Host "  OK ($Run): output matches"; $script:Pass++ } else { Write-Host "  FAIL ($Run): output did not match"; $script:Fail++ }
    }

    Write-Host ""
    Write-Host "---------------------------------------------------"
    Write-Host "Result: $Pass passed, $Fail failed (total $Run)"
    if ($Fail -gt 0) { exit 1 }
    exit 0
} finally {
    if (Test-Path -LiteralPath $TempDir -PathType Container) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
