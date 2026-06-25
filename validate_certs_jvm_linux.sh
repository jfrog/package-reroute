#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Validate JVM truststore installation done by install_certs_jvm_linux.sh.
#
# Asserts:
#   1. JKS truststore exists at /etc/ssl/package-route-jvm/truststore.jks
#   2. JKS contains a cert whose subject matches --expected-subject
#   3. /etc/environment contains JAVA_TOOL_OPTIONS pointing at the JKS
#   4. Current user's shell rc files reference the same value (WARN if missing)
#   5. Current process inherited JAVA_TOOL_OPTIONS (HINT if missing)

set -euo pipefail

JKS_DIR="/etc/ssl/package-route-jvm"
JKS_PATH="${JKS_DIR}/truststore.jks"
JKS_PASSWORD="changeit"
ENVIRONMENT_FILE="/etc/environment"

ALL_USERS=0
EXPECTED_SUBJECT=""

usage() {
    cat <<EOF
Usage:
  $0 --expected-subject <substring> [--all-users]

Options:
  --expected-subject <substring>   Required. Case-insensitive substring match against the cert subject.
  --all-users                      Validate /home/* users' rc files (requires root).
  -h, --help                       Show this help.

Exits 0 if all checks pass, 1 if any check fails.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all-users)
                ALL_USERS=1
                shift
                ;;
            --expected-subject)
                EXPECTED_SUBJECT="${2:?Error: --expected-subject requires a value}"
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

    if [[ "$ALL_USERS" -eq 1 && "$(id -u)" -ne 0 ]]; then
        echo "Error: --all-users requires root. Use: sudo $0 --all-users --expected-subject ..." >&2
        exit 1
    fi
}

FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
ok()   { echo "  OK:   $1"; }
warn() { echo "  WARN: $1"; }
skip() { echo "  SKIP: $1"; }

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

validate_export_in_file() {
    local file="$1" label="$2"
    if [[ ! -f "$file" ]]; then
        skip "$label not present: $file"
        return 0
    fi
    if [[ ! -r "$file" ]]; then
        warn "$label not readable by current user; re-run as that user or with sudo --all-users."
        return 0
    fi
    if grep -qE "^export JAVA_TOOL_OPTIONS=.*trustStore=\"?${JKS_PATH}\"?" "$file" 2>/dev/null; then
        ok "$label contains JAVA_TOOL_OPTIONS pointing at $JKS_PATH"
        return 0
    fi
    if grep -qE '^export JAVA_TOOL_OPTIONS=' "$file" 2>/dev/null; then
        fail "$label has JAVA_TOOL_OPTIONS but it does not point at $JKS_PATH"
        return 1
    fi
    warn "$label has no JAVA_TOOL_OPTIONS export (current session may need re-login or 'source $file')"
    return 0
}

validate_environment_file() {
    if [[ ! -f "$ENVIRONMENT_FILE" ]]; then
        fail "$ENVIRONMENT_FILE does not exist"
        return 1
    fi
    if grep -qE "^JAVA_TOOL_OPTIONS=.*trustStore=\"?${JKS_PATH}\"?" "$ENVIRONMENT_FILE" 2>/dev/null; then
        ok "$ENVIRONMENT_FILE contains JAVA_TOOL_OPTIONS pointing at $JKS_PATH"
        return 0
    fi
    fail "$ENVIRONMENT_FILE has no JAVA_TOOL_OPTIONS pointing at $JKS_PATH"
    return 1
}

validate_shell_rc_files() {
    if [[ "$ALL_USERS" -eq 1 ]]; then
        local homedir user
        for homedir in /home/*; do
            [[ -d "$homedir" ]] || continue
            user="$(basename "$homedir")"
            echo "  Checking user $user ..."
            validate_export_in_file "$homedir/.bashrc" "$user .bashrc" || true
            validate_export_in_file "$homedir/.zshrc" "$user .zshrc" || true
        done
    else
        echo "  Checking current user ..."
        [[ -z "${HOME:-}" ]] && HOME=$(eval echo "~")
        validate_export_in_file "$HOME/.bashrc" "current user .bashrc" || true
        validate_export_in_file "$HOME/.zshrc" "current user .zshrc" || true
    fi
}

main() {
    parse_args "$@"

    echo "Expected subject (case-insensitive substring): $EXPECTED_SUBJECT"
    echo

    validate_keystore_contains_subject "$JKS_PATH" "$JKS_PASSWORD" "Truststore $JKS_PATH" || true
    validate_environment_file || true
    validate_shell_rc_files

    if [[ -z "${JAVA_TOOL_OPTIONS:-}" ]]; then
        echo "  HINT: JAVA_TOOL_OPTIONS is NOT set in this shell. Open a new"
        echo "        login shell, or 'source $ENVIRONMENT_FILE', then re-run"
        echo "        the build. The next 'mvn'/'gradle' won't see the trust"
        echo "        store until then."
    fi

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
