#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Docker-driven smoke test matrix for Linux JVM trust installers.
#
# Runs:
#   - generic Linux bundled-JKS flow on Debian/Ubuntu/Amazon Linux
#   - RHEL update-ca-trust PEM flow on UBI/RHEL

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

MODE="${1:?mode required: generic|rhel}"
fail() { echo "BUG: $1" >&2; exit 1; }

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /tmp/k.pem -out /tmp/ca.pem -days 7 \
    -subj "/CN=Lab JVM CA Final/O=JFrog" \
    -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null

useradd -m -s /bin/bash devx >/dev/null 2>&1 || true

find_jdk_cacerts() {
    if [[ -n "${JAVA_HOME:-}" && -f "${JAVA_HOME}/lib/security/cacerts" ]]; then
        echo "${JAVA_HOME}/lib/security/cacerts"
        return 0
    fi
    local keytool_path keytool_dir
    keytool_path="$(command -v keytool 2>/dev/null || true)"
    if [[ -n "$keytool_path" ]]; then
        keytool_dir="$(dirname "$(readlink -f "$keytool_path" 2>/dev/null || echo "$keytool_path")")"
        if [[ -f "${keytool_dir}/../lib/security/cacerts" ]]; then
            echo "${keytool_dir}/../lib/security/cacerts"
            return 0
        fi
    fi
    fail "cannot locate JDK cacerts for bundled truststore fixture"
}

build_bundle_truststore() {
    local src_cacerts
    src_cacerts="$(find_jdk_cacerts)"
    cp "$src_cacerts" /tmp/bundled-truststore.jks
    chmod 0644 /tmp/bundled-truststore.jks
    keytool -importcert -noprompt \
        -alias package-route-custom-ca \
        -file /tmp/ca.pem \
        -keystore /tmp/bundled-truststore.jks \
        -storepass changeit >/dev/null
    echo "bundle base: $src_cacerts"
}

run_generic() {
    build_bundle_truststore

    echo "=== generic: positive install + validate ==="
    SUDO_USER=devx ./install_certs_jvm_linux.sh --use-truststore /tmp/bundled-truststore.jks >/dev/null
    ./validate_certs_jvm_linux.sh --expected-subject "Lab JVM CA Final" >/dev/null
    echo "  ok"

    echo "=== generic: subject mismatch must exit 1 ==="
    if ./validate_certs_jvm_linux.sh --expected-subject "Microsoft Root CA NoMatch" >/dev/null 2>&1; then
        fail "validator should have exited 1 on subject mismatch"
    fi
    echo "  ok"

    echo "=== generic: idempotent re-install preserves bundled JKS ==="
    SUDO_USER=devx ./install_certs_jvm_linux.sh --use-truststore /tmp/bundled-truststore.jks >/dev/null
    bundle_sha="$(sha256sum /tmp/bundled-truststore.jks | awk '{print $1}')"
    installed_sha="$(sha256sum /etc/ssl/package-route-jvm/truststore.jks | awk '{print $1}')"
    [[ "$installed_sha" == "$bundle_sha" ]] || fail "installed JKS checksum differs from bundle"
    env_lines="$(grep -c '^JAVA_TOOL_OPTIONS=' /etc/environment 2>/dev/null || true)"
    rc_lines="$(grep -c '^export JAVA_TOOL_OPTIONS=' /home/devx/.bashrc 2>/dev/null || true)"
    [[ "${env_lines:-0}" -eq 1 ]] || fail "/etc/environment has $env_lines JAVA_TOOL_OPTIONS lines (expected 1)"
    [[ "${rc_lines:-0}" -eq 1 ]] || fail "/home/devx/.bashrc has $rc_lines export lines (expected 1)"
    echo "  ok"

    echo "=== generic: JTO env var REPLACES (not appends) on re-install ==="
    sed -i '/^JAVA_TOOL_OPTIONS=/d' /etc/environment
    echo 'JAVA_TOOL_OPTIONS="-Dpackage-reroute-test-sentinel=must-be-replaced"' >> /etc/environment
    SUDO_USER=devx ./install_certs_jvm_linux.sh --use-truststore /tmp/bundled-truststore.jks >/dev/null
    if grep -q 'package-reroute-test-sentinel' /etc/environment; then
        fail "JTO env var was APPENDED to (sentinel survived). Re-install must replace."
    fi
    echo "  ok"

    echo "=== generic: missing and empty truststores rejected ==="
    if SUDO_USER=devx ./install_certs_jvm_linux.sh --use-truststore /tmp/no-such-truststore.jks >/dev/null 2>&1; then
        fail "installer should have rejected missing truststore"
    fi
    : > /tmp/empty-truststore.jks
    if SUDO_USER=devx ./install_certs_jvm_linux.sh --use-truststore /tmp/empty-truststore.jks >/dev/null 2>&1; then
        fail "installer should have rejected empty truststore"
    fi
    echo "  ok"

    echo "=== generic: JKS preserves bundled public roots ==="
    alias_count="$(keytool -list -keystore /etc/ssl/package-route-jvm/truststore.jks -storepass changeit 2>/dev/null | grep -c 'trustedCertEntry' || true)"
    [[ "${alias_count:-0}" -ge 100 ]] || fail "truststore has $alias_count aliases; expected >= 100"
    keytool -list -keystore /etc/ssl/package-route-jvm/truststore.jks -storepass changeit 2>/dev/null \
        | grep -qi 'digicert' \
        || fail "truststore is missing the DigiCert family of public roots"
    echo "  ok ($alias_count aliases)"
}

run_rhel() {
    echo "=== rhel: positive install + validate ==="
    ./install_certs_jvm_rhel.sh --use-cert /tmp/ca.pem >/dev/null
    ./validate_certs_jvm_rhel.sh --expected-subject "Lab JVM CA Final" >/dev/null
    [[ -f /etc/pki/ca-trust/source/anchors/package-route-custom-ca.crt ]] || fail "RHEL anchor file not created"
    echo "  ok"

    echo "=== rhel: subject mismatch must exit 1 ==="
    if ./validate_certs_jvm_rhel.sh --expected-subject "Microsoft Root CA NoMatch" >/dev/null 2>&1; then
        fail "validator should have exited 1 on subject mismatch"
    fi
    echo "  ok"

    echo "=== rhel: custom --cert-name round-trips ==="
    ./install_certs_jvm_rhel.sh --use-cert /tmp/ca.pem --cert-name zscaler-root >/dev/null
    ./validate_certs_jvm_rhel.sh --expected-subject "Lab JVM CA Final" --cert-name zscaler-root >/dev/null
    [[ -f /etc/pki/ca-trust/source/anchors/zscaler-root.crt ]] || fail "custom RHEL anchor file not created"
    echo "  ok"

    echo "=== rhel: path traversal cert-name rejected ==="
    if ./install_certs_jvm_rhel.sh --use-cert /tmp/ca.pem --cert-name '../etc/pwned' >/dev/null 2>&1; then
        fail "installer should have rejected path-traversal --cert-name"
    fi
    echo "  ok"

    echo "=== rhel: malformed PEM rejected ==="
    echo "not a certificate" > /tmp/bad.pem
    if ./install_certs_jvm_rhel.sh --use-cert /tmp/bad.pem >/dev/null 2>&1; then
        fail "installer should have rejected malformed PEM"
    fi
    echo "  ok"

    echo "=== rhel: leaf cert rejected ==="
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /tmp/leaf-k.pem -out /tmp/leaf.pem -days 7 \
        -subj "/CN=Leaf Not CA" \
        -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
    if ./install_certs_jvm_rhel.sh --use-cert /tmp/leaf.pem >/dev/null 2>&1; then
        fail "installer should have rejected leaf cert"
    fi
    echo "  ok"

    echo "=== rhel: DER cert rejected ==="
    openssl x509 -in /tmp/ca.pem -outform DER -out /tmp/ca.der 2>/dev/null
    if ./install_certs_jvm_rhel.sh --use-cert /tmp/ca.der >/dev/null 2>&1; then
        fail "installer should have rejected DER-encoded cert"
    fi
    echo "  ok"

    echo "=== rhel: no JAVA_TOOL_OPTIONS written ==="
    if [[ -f /etc/environment ]] && grep -q '^JAVA_TOOL_OPTIONS=' /etc/environment; then
        fail "RHEL flow should not write JAVA_TOOL_OPTIONS"
    fi
    echo "  ok"
}

case "$MODE" in
    generic) run_generic ;;
    rhel)    run_rhel ;;
    *)       fail "unknown mode: $MODE" ;;
esac

echo "=== ALL SMOKE TESTS PASSED ($MODE) ==="
PROBE_EOF
chmod +x "$PROBE"

# distro_id|mode|image|setup_command
MATRIX=(
    "ubuntu|generic|ubuntu:22.04|export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends openssl ca-certificates default-jdk-headless >/dev/null"
    "debian|generic|debian:12|export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends openssl ca-certificates default-jdk-headless >/dev/null"
    "amazonlinux|generic|amazonlinux:2023|dnf install -y -q java-21-amazon-corretto-headless openssl shadow-utils >/dev/null"
    "rhel|rhel|redhat/ubi9:latest|dnf install -y -q java-21-openjdk-headless openssl shadow-utils >/dev/null"
)

LOG_DIR="$(mktemp -d)"
trap 'rm -f "$PROBE"; rm -rf "$LOG_DIR"' EXIT

pids=()
labels=()
log_names=()

for entry in "${MATRIX[@]}"; do
    distro="${entry%%|*}"
    rest="${entry#*|}"
    mode="${rest%%|*}"
    rest="${rest#*|}"
    image="${rest%%|*}"
    setup="${rest#*|}"

    log="${LOG_DIR}/${distro}.log"
    (
        docker run --rm \
            -v "${REPO_ROOT}":/lab \
            -v "${PROBE}":/probe.sh:ro \
            -w /lab "$image" bash -c "set -e; ${setup}; bash /probe.sh ${mode}"
    ) >"$log" 2>&1 &
    pids+=("$!")
    labels+=("$distro/$mode ($image)")
    log_names+=("$log")
    echo "[launched] $distro/$mode ($image) -> $log"
done

overall_rc=0
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
        echo "[PASS] ${labels[$i]}"
    else
        echo "[FAIL] ${labels[$i]} — last 30 lines:"
        tail -30 "${log_names[$i]}" | sed 's/^/    /'
        overall_rc=1
    fi
done

if [[ "$overall_rc" -eq 0 ]]; then
    echo "All distros passed."
else
    echo "One or more distros failed."
fi

exit "$overall_rc"
