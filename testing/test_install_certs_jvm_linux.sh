#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Docker-driven smoke test matrix for install_certs_jvm_linux.sh and
# validate_certs_jvm_linux.sh. Runs the same internal probe script across
# four distro x JDK combinations in parallel and reports per-image status.
#
# Run from the repo root:
#   ./testing/test_install_certs_jvm_linux.sh
#
# Each container:
#   1. installs JDK + openssl
#   2. mints a self-signed lab CA (CA:TRUE, 7-day validity)
#   3. creates a non-root devx user (so update_user_shell_rc has a target)
#   4. runs install_certs_jvm_linux.sh + validate_certs_jvm_linux.sh
#   5. exercises 7 additional invariants:
#      - subject mismatch must exit 1
#      - idempotent re-install (no duplicate lines / aliases)
#      - custom --cert-name round-trips through validator
#      - path-traversal --cert-name is rejected
#      - malformed PEM is rejected
#      - expired CA is rejected
#      - leaf cert (CA:FALSE) is rejected
#
# Exit 0 iff every container reports ALL SMOKE TESTS PASSED.

set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker is required to run this test matrix." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROBE="$(mktemp)"
trap 'rm -f "$PROBE"' EXIT
cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set -euo pipefail
fail() { echo "BUG: $1" >&2; exit 1; }

# I5: surface openssl version per-container so a future image bump that
# drops openssl below 3.2 doesn't silently turn the expired-CA assertion
# into a SKIP that nobody notices. The expired-CA case uses -not_before/
# -not_after, which require OpenSSL 3.2+.
openssl_version="$(openssl version)"
echo "openssl: $openssl_version"
case "$openssl_version" in
    OpenSSL\ [01]*|OpenSSL\ 2*|OpenSSL\ 3.0*|OpenSSL\ 3.1*)
        echo "  [warn] openssl < 3.2 -- expired-CA assertion will fall back to -days -1 path or SKIP" >&2
        ;;
esac

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /tmp/k.pem -out /tmp/ca.pem -days 7 \
    -subj "/CN=Lab JVM CA Final/O=JFrog" \
    -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null

useradd -m -s /bin/bash devx >/dev/null 2>&1 || true

echo "=== positive: install + validate ==="
SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/ca.pem >/dev/null
./validate_certs_jvm_linux.sh --expected-subject "Lab JVM CA Final" >/dev/null
echo "  ok"

echo "=== negative: subject mismatch must exit 1 ==="
if ./validate_certs_jvm_linux.sh --expected-subject "Microsoft Root CA NoMatch" >/dev/null 2>&1; then
    fail "validator should have exited 1 on subject mismatch"
fi
echo "  ok"

echo "=== idempotency: 2nd install must produce same final state ==="
SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/ca.pem >/dev/null
./validate_certs_jvm_linux.sh --expected-subject "Lab JVM CA Final" >/dev/null

# I4: assert -eq 1 (not -le 1). A regression that silently DROPS the line
# from /etc/environment would slip past `-le 1` with 0; the env var should
# always be present after a successful install in Path B mode.
# On Path A the env var should NOT be set at all (0 lines expected); the
# distinction is per-distro since detect_mode picks the path.
env_lines=0
[[ -f /etc/environment ]] && env_lines=$(grep -c '^JAVA_TOOL_OPTIONS=' /etc/environment 2>/dev/null || true)
env_lines=${env_lines:-0}
rc_lines=0
[[ -f /home/devx/.bashrc ]] && rc_lines=$(grep -c '^export JAVA_TOOL_OPTIONS=' /home/devx/.bashrc 2>/dev/null || true)
rc_lines=${rc_lines:-0}

# Determine which path the installer took by checking which artifact exists.
if [[ -f /etc/ssl/package-route-jvm/truststore.jks ]]; then
    # Path B: JKS exists, env vars must be exactly 1
    [[ "$env_lines" -eq 1 ]] || fail "/etc/environment has $env_lines JAVA_TOOL_OPTIONS lines (expected 1 on Path B)"
    [[ "$rc_lines" -eq 1 ]]  || fail "/home/devx/.bashrc has $rc_lines export lines (expected 1 on Path B)"

    # Path B JKS contains the JDK's default cacerts (~150 public roots) PLUS
    # exactly one corporate-CA alias. After two installs, the corporate alias
    # count must be exactly 1 — the JDK aliases stay constant.
    corp_alias_count="$(keytool -list -keystore /etc/ssl/package-route-jvm/truststore.jks -storepass changeit 2>/dev/null | grep -cE '^package-route-custom-ca[,[:space:]]' || true)"
    corp_alias_count="${corp_alias_count:-0}"
    [[ "$corp_alias_count" -eq 1 ]] || fail "JKS corporate-CA alias count after 2nd install: $corp_alias_count (expected 1)"
else
    # Path A: no env vars, anchor file must exist and be exactly 1 file with our basename
    [[ "$env_lines" -eq 0 ]] || fail "Path A leaked JAVA_TOOL_OPTIONS to /etc/environment ($env_lines lines)"
    anchor_count="$(ls -1 /etc/pki/ca-trust/source/anchors/package-route-custom-ca.crt 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$anchor_count" -eq 1 ]] || fail "Path A anchor count: $anchor_count (expected 1)"
fi
echo "  ok (env=$env_lines rc=$rc_lines)"

# I1: JTO replaces-not-appends sentinel. Pre-seed a junk value in
# /etc/environment, run installer, assert the junk is gone (env var was
# REPLACED, not concatenated). Only applies when detect_mode picks Path B.
if [[ -f /etc/ssl/package-route-jvm/truststore.jks ]]; then
    echo "=== JTO env var REPLACES (not appends) on re-install ==="
    sed -i '/^JAVA_TOOL_OPTIONS=/d' /etc/environment
    echo 'JAVA_TOOL_OPTIONS="-Dpackage-reroute-test-sentinel=must-be-replaced"' >> /etc/environment
    SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/ca.pem >/dev/null
    if grep -q 'package-reroute-test-sentinel' /etc/environment; then
        fail "JTO env var was APPENDED to (sentinel survived). Re-install must replace."
    fi
    echo "  ok"
fi

echo "=== --cert-name custom: alias and basename honor flag ==="
SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/ca.pem --cert-name zscaler-root >/dev/null
./validate_certs_jvm_linux.sh --expected-subject "Lab JVM CA Final" --cert-name zscaler-root >/dev/null
echo "  ok"

echo "=== negative: --cert-name with bad chars must exit 1 ==="
if SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/ca.pem --cert-name '../etc/pwned' >/dev/null 2>&1; then
    fail "installer should have rejected path-traversal --cert-name"
fi
echo "  ok"

echo "=== negative: malformed PEM must exit 1 ==="
echo "not a certificate" > /tmp/bad.pem
if SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/bad.pem >/dev/null 2>&1; then
    fail "installer should have rejected malformed PEM"
fi
echo "  ok"

echo "=== negative: expired CA must exit 1 ==="
# Generate a cert with explicit past not_before / not_after when openssl supports it,
# otherwise fall back to negative -days. Verify the result is actually expired before
# running the assertion — some openssl 3.x builds treat -days -1 as 1 day in the future.
rm -f /tmp/old-ca.pem
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /tmp/old-k.pem -out /tmp/old-ca.pem \
    -subj "/CN=Expired CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -not_before 20200101000000Z -not_after 20200201000000Z 2>/dev/null \
|| openssl x509 -req -in <(openssl req -new -key /tmp/k.pem -subj "/CN=Expired") \
       -signkey /tmp/k.pem -days -1 -out /tmp/old-ca.pem 2>/dev/null \
|| true
if [[ ! -f /tmp/old-ca.pem ]] || openssl x509 -in /tmp/old-ca.pem -checkend 0 -noout >/dev/null 2>&1; then
    echo "  SKIP: cannot produce a verifiably expired cert with the installed openssl ($(openssl version))"
else
    if SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/old-ca.pem >/dev/null 2>&1; then
        fail "installer should have rejected expired CA"
    fi
    echo "  ok"
fi

echo "=== negative: leaf cert (not CA) must exit 1 ==="
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /tmp/leaf-k.pem -out /tmp/leaf.pem -days 7 \
    -subj "/CN=Leaf Not CA" \
    -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
if SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/leaf.pem >/dev/null 2>&1; then
    fail "installer should have rejected leaf cert (CA:FALSE)"
fi
echo "  ok"

echo "=== forced --mode update-ca-trust ==="
if command -v update-ca-trust >/dev/null 2>&1; then
    # Reset Path B state so we can exercise Path A cleanly.
    rm -rf /etc/ssl/package-route-jvm
    sed -i '/^JAVA_TOOL_OPTIONS=/d' /etc/environment 2>/dev/null || true
    sed -i '/^export JAVA_TOOL_OPTIONS=/d' /home/devx/.bashrc 2>/dev/null || true

    SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/ca.pem --mode update-ca-trust >/dev/null
    [[ -f /etc/pki/ca-trust/source/anchors/package-route-custom-ca.crt ]] \
        || fail "Path A anchor file not created"
    keytool -list -keystore /etc/pki/ca-trust/extracted/java/cacerts -storepass changeit 2>/dev/null \
        | grep -q "$(openssl x509 -in /tmp/ca.pem -noout -fingerprint -sha256 | sed 's/.*=//')" \
        || fail "Path A: CA fingerprint not visible in system Java cacerts"
    # /etc/environment must NOT have JAVA_TOOL_OPTIONS on Path A.
    if [[ -f /etc/environment ]] && grep -q '^JAVA_TOOL_OPTIONS=' /etc/environment; then
        fail "Path A leaked JAVA_TOOL_OPTIONS into /etc/environment"
    fi
    ./validate_certs_jvm_linux.sh --expected-subject "Lab JVM CA Final" >/dev/null
    echo "  ok"
else
    echo "  SKIP: update-ca-trust not installed on this distro"
fi

echo "=== regression: dual-artifact validator must not silent-pass ==="
# Reproduce the iteration-1 fix's regression: both Path A anchor and Path B JKS
# present at once. detect_mode previously leaked warn-stdout into command
# substitution and exited 0 with NO checks run.
if command -v update-ca-trust >/dev/null 2>&1; then
    # Both artifacts already exist from Path A run; force Path B side too.
    SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/ca.pem --mode java-tool-options >/dev/null
    [[ -f /etc/ssl/package-route-jvm/truststore.jks ]] || fail "Path B JKS not created"
    [[ -f /etc/pki/ca-trust/source/anchors/package-route-custom-ca.crt ]] || fail "Path A anchor missing"

    # Validator must NOT print 'All checks passed' silently — it must actually run
    # the Path B checks (positive subject match against the JKS).
    out="$(./validate_certs_jvm_linux.sh --expected-subject "Lab JVM CA Final" 2>&1)"
    grep -q 'Validating Path B' <<<"$out" || fail "validator did not run Path B checks: $out"
    grep -q 'All checks passed' <<<"$out" || fail "validator did not report success: $out"
    echo "  ok"
else
    echo "  SKIP: cannot construct dual-artifact state without update-ca-trust"
fi

echo "=== validate_pem 30-day-expiry warn fires (1-day cert) ==="
# I2 backport from macOS/Windows: assert the warn is emitted but install succeeds.
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /tmp/soon-k.pem -out /tmp/soon-ca.pem -days 1 \
    -subj "/CN=Soon to Expire/O=JFrog" \
    -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
warn_out="$(SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/soon-ca.pem 2>&1)"
if ! echo "$warn_out" | grep -q "certificate expires within 30 days"; then
    echo "$warn_out" | tail -10
    fail "30-day expiry warn not emitted"
fi
echo "  ok"

echo "=== validate_pem multi-cert bundle warn fires ==="
# I2 backport: concat two certs, assert the warn is emitted but install succeeds.
cat /tmp/ca.pem /tmp/soon-ca.pem > /tmp/bundle.pem
warn_out="$(SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/bundle.pem 2>&1)"
if ! echo "$warn_out" | grep -qE "PEM file contains [0-9]+ certificates"; then
    echo "$warn_out" | tail -10
    fail "multi-cert bundle warn not emitted"
fi
echo "  ok"

echo "=== negative: missing keytool fails cleanly (Path B) ==="
# I3 backport from Windows: temporarily hide every keytool on PATH (incl. the
# JDK-installed one symlinked via update-alternatives), assert the installer
# exits non-zero with a message mentioning keytool. Path A is keytool-optional
# so we only exercise Path B (--mode java-tool-options).
keytool_paths=()
while IFS= read -r p; do keytool_paths+=("$p"); done < <(command -v keytool 2>/dev/null; type -ap keytool 2>/dev/null | sort -u)
for p in "${keytool_paths[@]}"; do mv "$p" "$p.hidden_for_test" 2>/dev/null || true; done
trap 'for p in "${keytool_paths[@]}"; do [[ -f "$p.hidden_for_test" ]] && mv "$p.hidden_for_test" "$p" 2>/dev/null || true; done' EXIT
if SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/ca.pem --mode java-tool-options >/tmp/nokey.out 2>&1; then
    cat /tmp/nokey.out | head -10
    fail "installer should have rejected missing keytool"
fi
if ! grep -q -i keytool /tmp/nokey.out; then
    cat /tmp/nokey.out | head -10
    fail "missing-keytool error message should mention 'keytool'"
fi
# Restore now (and clear the EXIT trap) so subsequent tests can use keytool.
for p in "${keytool_paths[@]}"; do [[ -f "$p.hidden_for_test" ]] && mv "$p.hidden_for_test" "$p" 2>/dev/null || true; done
trap - EXIT
echo "  ok"

echo "=== negative: DER cert rejected (C1 cross-platform parity) ==="
# C1 backport: convert the lab CA to DER, then attempt install — should
# fail with a hint to convert back. Mirrors Windows behavior (which now
# also rejects DER for cross-platform symmetry).
openssl x509 -in /tmp/ca.pem -outform DER -out /tmp/ca.der 2>/dev/null
if SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/ca.der >/dev/null 2>&1; then
    fail "installer should have rejected DER-encoded cert"
fi
echo "  ok"

echo "=== Path B: JKS extends default cacerts (preserves public roots) ==="
# Bug 2 regression guard. -Djavax.net.ssl.trustStore in OpenJDK REPLACES the
# JVM trust source (it does not merge with $JAVA_HOME/lib/security/cacerts).
# We must therefore ship a JKS that already contains the JDK's ~150 public
# roots PLUS the corporate CA. A future change that re-shrinks the truststore
# to just the corporate CA would break every public-CA TLS handshake.
if [[ -f /etc/ssl/package-route-jvm/truststore.jks ]]; then
    # Re-build via Path B so we measure the post-fix state.
    SUDO_USER=devx ./install_certs_jvm_linux.sh --use-cert /tmp/ca.pem --mode java-tool-options >/dev/null
    alias_count=$(keytool -list -keystore /etc/ssl/package-route-jvm/truststore.jks \
        -storepass changeit 2>/dev/null | grep -c 'trustedCertEntry' || true)
    alias_count=${alias_count:-0}
    [[ "$alias_count" -ge 100 ]] || fail "Path B truststore has $alias_count aliases; expected >= 100 (JDK cacerts ~150 public roots + corporate CA)"
    keytool -list -keystore /etc/ssl/package-route-jvm/truststore.jks -storepass changeit 2>/dev/null \
        | grep -qi 'digicert' \
        || fail "Path B truststore is missing the DigiCert family of public roots; the copy-from-JDK step did not run"
    echo "  ok ($alias_count aliases, DigiCert present)"
else
    echo "  SKIP: Path B not exercised on this distro (Path A only)"
fi

echo "=== ALL SMOKE TESTS PASSED ==="
PROBE_EOF
chmod +x "$PROBE"

# distro_id|image|setup_command
MATRIX=(
    "ubuntu|ubuntu:22.04|export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends openssl ca-certificates default-jdk-headless >/dev/null"
    "debian|debian:12|export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends openssl ca-certificates default-jdk-headless >/dev/null"
    "rhel|redhat/ubi9:latest|dnf install -y -q java-21-openjdk-headless openssl shadow-utils >/dev/null"
    "amazonlinux|amazonlinux:2023|dnf install -y -q java-21-amazon-corretto-headless openssl shadow-utils >/dev/null"
)

LOG_DIR="$(mktemp -d)"
trap 'rm -f "$PROBE"; rm -rf "$LOG_DIR"' EXIT

pids=()
labels=()

for entry in "${MATRIX[@]}"; do
    distro="${entry%%|*}"
    rest="${entry#*|}"
    image="${rest%%|*}"
    setup="${rest#*|}"

    log="${LOG_DIR}/${distro}.log"
    (
        docker run --rm \
            -v "${REPO_ROOT}":/lab \
            -v "${PROBE}":/probe.sh:ro \
            -w /lab "$image" bash -c "set -e; ${setup}; bash /probe.sh"
    ) >"$log" 2>&1 &
    pids+=("$!")
    labels+=("$distro ($image)")
    echo "[launched] $distro ($image) -> $log"
done

overall_rc=0
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
        echo "[PASS] ${labels[$i]}"
    else
        echo "[FAIL] ${labels[$i]} — last 30 lines:"
        tail -30 "${LOG_DIR}/${labels[$i]%% *}.log" | sed 's/^/    /'
        overall_rc=1
    fi
done

if [[ "$overall_rc" -eq 0 ]]; then
    echo "All distros passed."
else
    echo "One or more distros failed."
fi

exit "$overall_rc"
