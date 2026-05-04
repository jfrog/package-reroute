# (c) JFrog Ltd. (2026)
# Tests for install_certs_windows.ps1 (CLI, LocalMachine\Root export, Python/HF Machine env) and validate_install_windows.ps1.
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
    # Valid PEM with subject CN=test-cert-windows (generated: openssl req -x509 -nodes -newkey rsa:2048 -subj "/CN=test-cert-windows" -days 3650)
    $CertPath = Join-Path $TempDir "cert.pem"
    $embeddedPem = @'
-----BEGIN CERTIFICATE-----
MIIDGTCCAgGgAwIBAgIUfjPrjG6+dJgm2iGavSVZsQ8GdmUwDQYJKoZIhvcNAQEL
BQAwHDEaMBgGA1UEAwwRdGVzdC1jZXJ0LXdpbmRvd3MwHhcNMjYwMzEwMTYxMTA5
WhcNMzYwMzA3MTYxMTA5WjAcMRowGAYDVQQDDBF0ZXN0LWNlcnQtd2luZG93czCC
ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMZhh/eVPr+G6Kmk1MkZQIWI
zDpH87uHNNKqUs3dzsJ1qw6t00II/t69L8i8pO7Rz0zFY2Qf1he++ZCGExfb8wxB
QgvNx9GvdtCS9jGxuOjWhb9M9Rk+hKUST2frzLwV9vCRzdSZaUGOspUj4VhfoW6X
c7agWkVm5p9ygC/lLYAFNuITWVAMRGktnWJHV3vK0x+b2XHF4tQBIng/J1AT8pb9
6dB29u0yOE7kpHbyA4EtlDF/LioP7CIxDDU/qlZlxLaCvrPA6Zuhnx6r+nzhkRwk
4y/90mmGr5SuWtOCObNjRx9J9s2Eql4KXAMMv2DzaC/Agw+2BeT1NWj/Q8vJvz8C
AwEAAaNTMFEwHQYDVR0OBBYEFBnly6MR2qd4OQC/K/IjhgVNxVAJMB8GA1UdIwQY
MBaAFBnly6MR2qd4OQC/K/IjhgVNxVAJMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZI
hvcNAQELBQADggEBAH1gZqN/40N10OPJjPIx1iDK14C0Pti8Um9Dv2eYSwrn7ZZ1
JSrJ6Boeevy1VQFx2gYXyQWDywf/hfaEJXy1OrwOkKGpAlft2H9n3tk1VGffXWNV
Sabx04KvcybkEynuVQ9XX+H92zfL1nkvyothYT2VssMnwlKZbCL84Bm1PQpXY/Fx
I9wVBXto0FkCgSTzxOwr3Kk5grc61Hp6gevBwsBpbtZl52wtavdTjwzTgZvQEMWt
rHRJMjbyf1IzDJAqq2Bi3+Cl+QtDmguvwGvs/AINia/V0CbNw5fmj7FtwO+Z77d8
jXKK5iDphL7LcKir6SLHxmyU339SrjNtTpiSBTU=
-----END CERTIFICATE-----
'@
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($CertPath, $embeddedPem.Trim(), $utf8NoBom)
    "not a certificate" | Set-Content -Path (Join-Path $TempDir "invalid.pem") -Encoding UTF8
    $InvalidPath = Join-Path $TempDir "invalid.pem"

    $Run = 0
    $Pass = 0
    $Fail = 0

    # Run a PowerShell script in a child process and return exit code. Captures stderr/stdout.
    # Use -ArgumentList array so paths and params are passed correctly to the child.
    function Invoke-ScriptAndGetExitCode {
        # Do not name this parameter "Args" — it conflicts with PowerShell's automatic $args and breaks binding on pwsh 7+.
        param([string]$ScriptPath, [array]$ScriptArguments = @())
        $allArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $ScriptArguments
        Write-Host "    [run] powershell -NoProfile -ExecutionPolicy Bypass -File '$ScriptPath' $($ScriptArguments -join ' ')"
        $stdoutFile = Join-Path $TempDir "out_$([Guid]::NewGuid().ToString('N').Substring(0,4)).txt"
        $stderrFile = Join-Path $TempDir "err_$([Guid]::NewGuid().ToString('N').Substring(0,4)).txt"
        Write-Host "    [Start-Process] powershell.exe -ArgumentList: $($allArgs -join ' ')"
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $allArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $stdout = if (Test-Path $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile) } else { "" }
        $stderr = if (Test-Path $stderrFile) { [System.IO.File]::ReadAllText($stderrFile) } else { "" }
        Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
        return @{ ExitCode = $p.ExitCode; Stdout = $stdout; Stderr = $stderr }
    }

    function Assert-ExitCode {
        param([int]$Expected, [string]$ScriptPath, [array]$ScriptArguments = @())
        $script:Run++
        $r = Invoke-ScriptAndGetExitCode -ScriptPath $ScriptPath -ScriptArguments $ScriptArguments
        $got = $r.ExitCode
         Write-Host "    ExitCode: $got | Stdout: <$($r.Stdout)> | Stderr: <$($r.Stderr)>"
        if ($got -eq $Expected) {
            Write-Host "  OK ($Run): exit $Expected"
            $script:Pass++
        } else {
            Write-Host "  FAIL ($Run): expected exit $Expected, got $got"
            $script:Fail++
        }
    }

    function Assert-Stderr {
        param([string]$Pattern, [string]$ScriptPath, [array]$ScriptArguments = @())
        $script:Run++
        $r = Invoke-ScriptAndGetExitCode -ScriptPath $ScriptPath -ScriptArguments $ScriptArguments
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

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Error "This test script must be run as Administrator. Run PowerShell as Administrator (e.g. right-click -> Run as administrator)."
        exit 1
    }

    Write-Host "=== install_certs_windows.ps1 CLI tests ==="

    $machineEnvNames = @(
        "NODE_USE_SYSTEM_CA",
        "NODE_EXTRA_CA_CERTS",
        "UV_NATIVE_TLS",
        "UV_SYSTEM_CERTS",
        "REQUESTS_CA_BUNDLE",
        "HF_HUB_DISABLE_XET",
        "HF_HUB_ETAG_TIMEOUT",
        "HF_HUB_DOWNLOAD_TIMEOUT"
    )

    function Save-MachineEnvForTest {
        $h = @{}
        foreach ($n in $machineEnvNames) {
            $h[$n] = [Environment]::GetEnvironmentVariable($n, "Machine")
        }
        return $h
    }

    function Restore-MachineEnvForTest {
        param($Hash)
        if (-not $Hash) { return }
        foreach ($n in $machineEnvNames) {
            $val = $null
            if ($Hash.ContainsKey($n)) { $val = $Hash[$n] }
            [Environment]::SetEnvironmentVariable($n, $val, "Machine")
        }
    }

    function Clear-InstallMachineEnv {
        foreach ($n in $machineEnvNames) {
            [Environment]::SetEnvironmentVariable($n, $null, "Machine")
        }
    }

    # Invalid -Package (ValidateSet)
    Assert-ExitCode -Expected 1 -ScriptPath $InstallScript -ScriptArguments @("-Package", "foo")
    Assert-Stderr -Pattern "ValidateSet|npm|python|all" -ScriptPath $InstallScript -ScriptArguments @("-Package", "foo")

    # -CertName pattern matches nothing in LocalMachine\Root
    Assert-ExitCode -Expected 1 -ScriptPath $InstallScript -ScriptArguments @("-Package", "all", "-CertName", "ZZZNonexistentRootCertPattern999")
    Assert-Stderr -Pattern "No certificate|Root|matched" -ScriptPath $InstallScript -ScriptArguments @("-Package", "all", "-CertName", "ZZZNonexistentRootCertPattern999")

    $savedMachine = Save-MachineEnvForTest
    try {
        Clear-InstallMachineEnv

        $bundlePy = Join-Path $TempDir "bundle-python.pem"
        $rPy = Invoke-ScriptAndGetExitCode -ScriptPath $InstallScript -ScriptArguments @("-Package", "python", "-BundlePath", $bundlePy)
        $Run++
        $bundlePyFull = [System.IO.Path]::GetFullPath($bundlePy)
        if ($rPy.ExitCode -ne 0) {
            Write-Host "  FAIL ($Run): -Package python expected exit 0, got $($rPy.ExitCode)"
            $script:Fail++
        } elseif (-not (Test-Path -LiteralPath $bundlePy -PathType Leaf)) {
            Write-Host "  FAIL ($Run): bundle file missing: $bundlePy"
            $script:Fail++
        } else {
            $nodeSys = [Environment]::GetEnvironmentVariable("NODE_USE_SYSTEM_CA", "Machine")
            $nodeExtra = [Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS", "Machine")
            $uv = [Environment]::GetEnvironmentVariable("UV_NATIVE_TLS", "Machine")
            $uvSys = [Environment]::GetEnvironmentVariable("UV_SYSTEM_CERTS", "Machine")
            $req = [Environment]::GetEnvironmentVariable("REQUESTS_CA_BUNDLE", "Machine")
            $hf0 = [Environment]::GetEnvironmentVariable("HF_HUB_DISABLE_XET", "Machine")
            $hf1 = [Environment]::GetEnvironmentVariable("HF_HUB_ETAG_TIMEOUT", "Machine")
            $hf2 = [Environment]::GetEnvironmentVariable("HF_HUB_DOWNLOAD_TIMEOUT", "Machine")
            $reqFull = if ($req) { [System.IO.Path]::GetFullPath($req.Trim().Trim('"').Trim("'")) } else { "" }
            if ([string]::IsNullOrWhiteSpace($nodeSys) -and [string]::IsNullOrWhiteSpace($nodeExtra) -and
                $uv -eq "true" -and $uvSys -eq "true" -and $reqFull -eq $bundlePyFull -and
                $hf0 -eq "1" -and $hf1 -eq "86400" -and $hf2 -eq "86400") {
                Write-Host "  OK ($Run): -Package python exports bundle and sets REQUESTS_CA_BUNDLE / UV / HF_HUB_*"
                $script:Pass++
            } else {
                Write-Host "  FAIL ($Run): unexpected Machine env after -Package python"
                Write-Host "    NODE_USE_SYSTEM_CA='$nodeSys' NODE_EXTRA_CA_CERTS='$nodeExtra'"
                Write-Host "    UV_NATIVE_TLS='$uv' UV_SYSTEM_CERTS='$uvSys' REQUESTS_CA_BUNDLE='$req'"
                Write-Host "    HF_DISABLE='$hf0' HF_ETAG='$hf1' HF_DL='$hf2'"
                $script:Fail++
            }
        }

        $bundleAll = Join-Path $TempDir "bundle-all.pem"
        Clear-InstallMachineEnv
        $rAll = Invoke-ScriptAndGetExitCode -ScriptPath $InstallScript -ScriptArguments @("-Package", "all", "-BundlePath", $bundleAll)
        $Run++
        $bundleAllFull = [System.IO.Path]::GetFullPath($bundleAll)
        if ($rAll.ExitCode -ne 0) {
            Write-Host "  FAIL ($Run): -Package all expected exit 0, got $($rAll.ExitCode)"
            $script:Fail++
        } elseif (-not (Test-Path -LiteralPath $bundleAll -PathType Leaf)) {
            Write-Host "  FAIL ($Run): bundle file missing: $bundleAll"
            $script:Fail++
        } else {
            $nodeSys = [Environment]::GetEnvironmentVariable("NODE_USE_SYSTEM_CA", "Machine")
            $nodeExtra = [Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS", "Machine")
            $uv = [Environment]::GetEnvironmentVariable("UV_NATIVE_TLS", "Machine")
            $uvSys = [Environment]::GetEnvironmentVariable("UV_SYSTEM_CERTS", "Machine")
            $req = [Environment]::GetEnvironmentVariable("REQUESTS_CA_BUNDLE", "Machine")
            $hf0 = [Environment]::GetEnvironmentVariable("HF_HUB_DISABLE_XET", "Machine")
            $hf1 = [Environment]::GetEnvironmentVariable("HF_HUB_ETAG_TIMEOUT", "Machine")
            $hf2 = [Environment]::GetEnvironmentVariable("HF_HUB_DOWNLOAD_TIMEOUT", "Machine")
            $nodeExtraFull = if ($nodeExtra) { [System.IO.Path]::GetFullPath($nodeExtra.Trim().Trim('"').Trim("'")) } else { "" }
            $reqFull = if ($req) { [System.IO.Path]::GetFullPath($req.Trim().Trim('"').Trim("'")) } else { "" }
            if ($nodeSys -eq "1" -and $nodeExtraFull -eq $bundleAllFull -and $reqFull -eq $bundleAllFull -and
                $uv -eq "true" -and $uvSys -eq "true" -and
                $hf0 -eq "1" -and $hf1 -eq "86400" -and $hf2 -eq "86400") {
                Write-Host "  OK ($Run): -Package all sets NODE / REQUESTS_CA_BUNDLE / UV / HF_HUB_* and bundle"
                $script:Pass++
            } else {
                Write-Host "  FAIL ($Run): unexpected Machine env after -Package all"
                Write-Host "    NODE_USE_SYSTEM_CA='$nodeSys' NODE_EXTRA_CA_CERTS='$nodeExtra'"
                Write-Host "    REQUESTS_CA_BUNDLE='$req' UV_NATIVE_TLS='$uv'"
                $script:Fail++
            }
        }

        Clear-InstallMachineEnv
        $bundleDef = Join-Path $TempDir "bundle-default.pem"
        $rDef = Invoke-ScriptAndGetExitCode -ScriptPath $InstallScript -ScriptArguments @("-BundlePath", $bundleDef)
        $Run++
        if ($rDef.ExitCode -eq 0 -and (Test-Path -LiteralPath $bundleDef -PathType Leaf)) {
            Write-Host "  OK ($Run): default Package + -BundlePath exports LocalMachine\Root and exits 0"
            $script:Pass++
        } else {
            Write-Host "  FAIL ($Run): default install expected exit 0 and bundle file, got exit $($rDef.ExitCode)"
            $script:Fail++
        }
    } finally {
        Restore-MachineEnvForTest -Hash $savedMachine
    }

    Write-Host ""
    Write-Host "=== validate_install_windows.ps1 tests ==="

    # -ExpectedSubject is required
    Assert-ExitCode -Expected 1 -ScriptPath $ValidateScript -ScriptArguments @()
    Assert-Stderr -Pattern "ExpectedSubject is required" -ScriptPath $ValidateScript -ScriptArguments @()

    # Helper: set User NODE_EXTRA_CA_CERTS before child, run validate in child, clear after.
    function Invoke-ValidateWithEnvPath {
        param([string]$Path, [string]$ExpectedSubject = "test-cert")
        $scriptEscaped = $ValidateScript -replace "'", "''"
        $cmd = "& '$scriptEscaped' -ExpectedSubject '$ExpectedSubject'; exit `$LASTEXITCODE"
        $allArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $cmd)
        Write-Host "    [run] Invoke-ValidateWithEnvPath Path='$Path' ExpectedSubject='$ExpectedSubject'"
        $saved = [Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS", "User")
        try {
            [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $Path, "User")
            $stdoutFile = Join-Path $TempDir "out_$([Guid]::NewGuid().ToString('N').Substring(0,4)).txt"
            $stderrFile = Join-Path $TempDir "err_$([Guid]::NewGuid().ToString('N').Substring(0,4)).txt"
            Write-Host "    [Start-Process] powershell.exe -ArgumentList: -NoProfile -ExecutionPolicy Bypass -Command <...>"
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList $allArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
            $stdout = if (Test-Path $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile) } else { "" }
            $stderr = if (Test-Path $stderrFile) { [System.IO.File]::ReadAllText($stderrFile) } else { "" }
            Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
            Write-Host "    [ExitCode] $($p.ExitCode) | Stdout: <$stdout> | Stderr: <$stderr>"
            Write-Host "    [return] @{ ExitCode = $($p.ExitCode); Stdout = <$stdout>; Stderr = <$stderr> }"
            return @{ ExitCode = $p.ExitCode; Stdout = $stdout; Stderr = $stderr }
        } finally {
            [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $saved, "User")
        }
    }

    # Helper: set Machine NODE_EXTRA_CA_CERTS and clear User so validate uses system-level env. Requires admin. Restores both in finally.
    function Invoke-ValidateWithMachinePath {
        param([string]$Path, [string]$ExpectedSubject = "test-cert")
        $scriptEscaped = $ValidateScript -replace "'", "''"
        $cmd = "& '$scriptEscaped' -ExpectedSubject '$ExpectedSubject'; exit `$LASTEXITCODE"
        $allArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $cmd)
        Write-Host "    [run] Invoke-ValidateWithMachinePath Path='$Path' ExpectedSubject='$ExpectedSubject'"
        $savedUser = [Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS", "User")
        $savedMachine = [Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS", "Machine")
        try {
            [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $Path, "Machine")
            [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $null, "User")
            $stdoutFile = Join-Path $TempDir "out_$([Guid]::NewGuid().ToString('N').Substring(0,4)).txt"
            $stderrFile = Join-Path $TempDir "err_$([Guid]::NewGuid().ToString('N').Substring(0,4)).txt"
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList $allArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
            $stdout = if (Test-Path $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile) } else { "" }
            $stderr = if (Test-Path $stderrFile) { [System.IO.File]::ReadAllText($stderrFile) } else { "" }
            Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
            Write-Host "    [ExitCode] $($p.ExitCode) | Stdout: <$stdout> | Stderr: <$stderr>"
            return @{ ExitCode = $p.ExitCode; Stdout = $stdout; Stderr = $stderr }
        } finally {
            [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $savedUser, "User")
            [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $savedMachine, "Machine")
        }
    }

    # Current user env: no paths set → WARN, exit 0 (use -Command so -ExpectedSubject is passed)
    $Run++
    $scriptEscaped = $ValidateScript -replace "'", "''"
    $cmd = "& '$scriptEscaped' -ExpectedSubject 'test-cert'; exit `$LASTEXITCODE"
    $allArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $cmd)
    $stdoutFile = Join-Path $TempDir "out_warn.txt"
    $stderrFile = Join-Path $TempDir "err_warn.txt"
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $allArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
    if ($p.ExitCode -eq 0) { Write-Host "  OK ($Run): no paths set (exit 0)"; $script:Pass++ } else { Write-Host "  FAIL ($Run): expected exit 0, got $($p.ExitCode)"; $script:Fail++ }
    Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue

    # Env path: valid PEM (subject contains "test-cert")
    $Run++
    $r0 = Invoke-ValidateWithEnvPath -Path $CertPath -ExpectedSubject "test-cert"
    if ($r0.ExitCode -eq 0) { Write-Host "  OK ($Run): env path valid PEM (exit 0)"; $script:Pass++ } else {
        Write-Host "  FAIL ($Run): expected exit 0, got $($r0.ExitCode)"
        Write-Host "    Stdout: $($r0.Stdout)"
        Write-Host "    Stderr: $($r0.Stderr)"
        $script:Fail++
    }

    # Env path: missing file
    $Run++
    $r = Invoke-ValidateWithEnvPath -Path $Nonexistent
    if ($r.ExitCode -eq 1) { Write-Host "  OK ($Run): exit 1"; $script:Pass++ } else { Write-Host "  FAIL ($Run): expected exit 1, got $($r.ExitCode)"; $script:Fail++ }
    $Run++
    $out = $r.Stdout + " " + $r.Stderr
    if ($out -match "does not exist|FAIL|file does not|exist:|check\(s\) failed" -or ($r.ExitCode -eq 1 -and $out.Trim().Length -gt 0)) { Write-Host "  OK ($Run): output matches"; $script:Pass++ } else { Write-Host "  FAIL ($Run): output did not match"; $script:Fail++ }

    # Env path: invalid PEM content
    $Run++
    $r2 = Invoke-ValidateWithEnvPath -Path $InvalidPath
    if ($r2.ExitCode -eq 1) { Write-Host "  OK ($Run): exit 1"; $script:Pass++ } else { Write-Host "  FAIL ($Run): expected exit 1, got $($r2.ExitCode)"; $script:Fail++ }
    $Run++
    $out2 = $r2.Stdout + " " + $r2.Stderr
    if ($out2 -match "not a valid PEM|FAIL|valid PEM") { Write-Host "  OK ($Run): output matches"; $script:Pass++ } else { Write-Host "  FAIL ($Run): output did not match"; $script:Fail++ }

    # Subject mismatch
    $Run++
    $r3 = Invoke-ValidateWithEnvPath -Path $CertPath -ExpectedSubject "Zscaler"
    if ($r3.ExitCode -eq 1) { Write-Host "  OK ($Run): exit 1"; $script:Pass++ } else { Write-Host "  FAIL ($Run): expected exit 1, got $($r3.ExitCode)"; $script:Fail++ }
    $Run++
    if (($r3.Stdout + " " + $r3.Stderr) -match "no cert|matching|FAIL|subject|Result:.*failed") { Write-Host "  OK ($Run): output matches"; $script:Pass++ } else { Write-Host "  FAIL ($Run): output did not match"; $script:Fail++ }

    # System-level (Machine) env: valid PEM. Validate reads User then Machine; we set only Machine and clear User.
    $Run++
    $rMachine = Invoke-ValidateWithMachinePath -Path $CertPath -ExpectedSubject "test-cert"
    if ($rMachine.ExitCode -eq 0) { Write-Host "  OK ($Run): system-level env path valid PEM (exit 0)"; $script:Pass++ } else {
        Write-Host "  FAIL ($Run): expected exit 0, got $($rMachine.ExitCode)"
        Write-Host "    Stdout: $($rMachine.Stdout)"
        Write-Host "    Stderr: $($rMachine.Stderr)"
        $script:Fail++
    }

    # User env: valid PEM path but HF_HUB_DISABLE_XET wrong → Validate-HfIfPresent fails
    $Run++
    $savedNodeUserHf = [Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS", "User")
    $savedHfUser = [Environment]::GetEnvironmentVariable("HF_HUB_DISABLE_XET", "User")
    try {
        [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $CertPath, "User")
        [Environment]::SetEnvironmentVariable("HF_HUB_DISABLE_XET", "0", "User")
        $scriptEscaped = $ValidateScript -replace "'", "''"
        $cmd = "& '$scriptEscaped' -ExpectedSubject 'test-cert'; exit `$LASTEXITCODE"
        $allArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $cmd)
        $stdoutFileHf = Join-Path $TempDir "out_hf_bad.txt"
        $stderrFileHf = Join-Path $TempDir "err_hf_bad.txt"
        $pHf = Start-Process -FilePath "powershell.exe" -ArgumentList $allArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFileHf -RedirectStandardError $stderrFileHf
        $outHf = ""
        if (Test-Path $stdoutFileHf) { $outHf += [System.IO.File]::ReadAllText($stdoutFileHf) }
        if (Test-Path $stderrFileHf) { $outHf += [System.IO.File]::ReadAllText($stderrFileHf) }
        Remove-Item $stdoutFileHf, $stderrFileHf -ErrorAction SilentlyContinue
        if ($pHf.ExitCode -eq 1 -and $outHf -match "HF_HUB_DISABLE_XET") {
            Write-Host "  OK ($Run): invalid User HF_HUB_DISABLE_XET → validate exit 1"
            $script:Pass++
        } else {
            Write-Host "  FAIL ($Run): expected exit 1 and HF message, got $($pHf.ExitCode)"
            $script:Fail++
        }
    } finally {
        [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $savedNodeUserHf, "User")
        [Environment]::SetEnvironmentVariable("HF_HUB_DISABLE_XET", $savedHfUser, "User")
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
