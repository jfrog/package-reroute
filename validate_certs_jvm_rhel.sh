#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Validate JVM trust installation done by install_certs_jvm_rhel.sh.

set -euo pipefail

DEFAULT_CERT_BASENAME="package-route-custom-ca"
RHEL_ANCHOR_DIR="/etc/pki/ca-trust/source/anchors"
RHEL_JAVA_CACERTS="/etc/pki/ca-trust/extracted/java/cacerts"
JKS_PASSWORD="changeit"

EXPECTED_SUBJECT=""
CERT_BASENAME="$DEFAULT_CERT_BASENAME"

usage() {
    cat <<EOF
Usage:
  $0 --expected-subject <substring> [--cert-name <name>]

Options:
  --expected-subject <substring>   Required. Case-insensitive substring match against the cert subject.
  --cert-name <name>               Base name used at install (default: ${DEFAULT_CERT_BASENAME}).
  -h, --help                       Show this help.

Exits 0 if all checks pass, 1 if any check fails.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --expected-subject)
                EXPECTED_SUBJECT="${2:?Error: --expected-subject requires a value}"
                shift 2
                ;;
            --cert-name)
                CERT_BASENAME="${2:?Error: --cert-name requires a value}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    if [[ -z "$EXPECTED_SUBJECT" ]]; then
        echo "Error: --expected-subject is required." >&2
        usage >&2
        exit 1
    fi
    if [[ -z "$CERT_BASENAME" ]]; then
        echo "Error: --cert-name cannot be empty." >&2
        exit 1
    fi
    if [[ ! "$CERT_BASENAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "Error: --cert-name must match [A-Za-z0-9._-]+ (got: $CERT_BASENAME)." >&2
        exit 1
    fi
}

FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
ok()   { echo "  OK:   $1"; }

validate_pem_subject() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        fail "file does not exist: $path"
        return 1
    fi
    if ! openssl x509 -in "$path" -noout >/dev/null 2>&1; then
        fail "not a valid PEM certificate: $path"
        return 1
    fi
    local subject
    subject="$(openssl x509 -in "$path" -noout -subject 2>/dev/null)"
    if echo "$subject" | grep -qi "$EXPECTED_SUBJECT"; then
        ok "PEM at $path has subject matching: $EXPECTED_SUBJECT"
        return 0
    fi
    fail "PEM at $path subject does not match '$EXPECTED_SUBJECT' (got: $subject)"
    return 1
}

validate_keystore_contains_subject() {
    local keystore="$1" storepass="$2" label="$3"
    if [[ ! -f "$keystore" ]]; then
        fail "$label keystore does not exist: $keystore"
        return 1
    fi
    if ! command -v keytool >/dev/null 2>&1; then
        fail "$label keystore present but keytool is not on PATH; cannot verify subject. Install a JDK."
        return 1
    fi

    local keytool_output
    if ! keytool_output="$(keytool -list -v -keystore "$keystore" -storepass "$storepass" 2>&1)"; then
        fail "$label: keytool could not read the keystore. Output (first 3 lines):"
        printf '%s\n' "$keytool_output" | head -n3 | sed 's/^/        /'
        return 1
    fi

    local owners
    owners="$(printf '%s\n' "$keytool_output" | grep -E '^Owner:' || true)"
    if ! grep -qi "$EXPECTED_SUBJECT" <<<"$owners"; then
        fail "$label has no cert with subject matching: $EXPECTED_SUBJECT"
        return 1
    fi
    if printf '%s\n' "$keytool_output" | grep -qE '^Entry type: PrivateKeyEntry'; then
        fail "$label contains a PrivateKeyEntry — this truststore must hold only trustedCertEntry records."
        return 1
    fi
    ok "$label contains cert with subject matching: $EXPECTED_SUBJECT"
    return 0
}

main() {
    parse_args "$@"

    local anchor="${RHEL_ANCHOR_DIR}/${CERT_BASENAME}.crt"

    echo "Expected subject (case-insensitive substring): $EXPECTED_SUBJECT"
    echo
    echo "Validating RHEL update-ca-trust JVM install..."

    validate_pem_subject "$anchor" || true
    validate_keystore_contains_subject "$RHEL_JAVA_CACERTS" "$JKS_PASSWORD" "Java cacerts" || true

    echo "---------------------------------------------------"
    if [[ "$FAIL" -eq 0 ]]; then
        echo "Result: All checks passed."
        exit 0
    else
        echo "Result: $FAIL check(s) failed."
        exit 1
    fi
}

main "$@"
