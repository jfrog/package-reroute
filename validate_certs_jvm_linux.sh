#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Validate JVM truststore installation done by install_certs_jvm_linux.sh.
#
# Detects which path the installer used (RHEL update-ca-trust vs JKS +
# JAVA_TOOL_OPTIONS), then asserts:
#   1. Anchor file (Path A) OR JKS truststore (Path B) exists
#   2. Customer CA subject matches --expected-subject (substring, case-insensitive)
#   3. (Path B) /etc/environment contains JAVA_TOOL_OPTIONS pointing at the JKS
#   4. (Path B) Current user's shell rc files reference the same value (WARN if missing)
#   5. Current process inherited JAVA_TOOL_OPTIONS (HINT if missing — open a new shell)
#
# Run:
#   bash validate_certs_jvm_linux.sh --expected-subject "O=Zscaler"
#   sudo bash validate_certs_jvm_linux.sh --expected-subject "O=Zscaler" --all-users
#
# Pass the same --cert-name that was used during install if it was non-default.
#
# Exit 0 = all checks passed (warnings tolerated).
#
# Cross-platform siblings (keep CLI shapes and contracts in sync):
#   validate_certs_jvm_macos.sh      — LaunchAgent + launchctl getenv check
#   validate_certs_jvm_windows.ps1   — HKCU\Environment + Get-JavaToolOptions check
#
# Research / rationale: see the JVM client-onboarding wiki page
#   https://jfrog-int.atlassian.net/wiki/spaces/RTFACT/pages/2440101931/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/_jvm_linux_paths.sh" ]]; then
    echo "Error: _jvm_linux_paths.sh not found next to this validator (${SCRIPT_DIR})." >&2
    echo "       Invoke as ./validate_certs_jvm_linux.sh — not via 'curl | bash'." >&2
    exit 1
fi
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/_jvm_linux_paths.sh"

ALL_USERS=0
EXPECTED_SUBJECT=""
CERT_BASENAME="${JVM_LINUX_DEFAULT_CERT_BASENAME}"

usage() {
    cat <<EOF
Usage:
  $0 --expected-subject <substring> [--cert-name <name>] [--all-users]

Options:
  --expected-subject <substring>   Required. Case-insensitive substring match against the cert subject.
  --cert-name <name>               Base name used at install (default: ${CERT_BASENAME}).
                                   Must match the installer's --cert-name when non-default.
  --all-users                      For Path B (JKS+JTO), validate /home/* users' rc files (requires root).
  -h, --help                       Show this help

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

    # Symmetrical with installer: same regex constraint so the file path resolves cleanly.
    if [[ ! "$CERT_BASENAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "Error: --cert-name must match [A-Za-z0-9._-]+ (got: $CERT_BASENAME)." >&2
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

# Stdout contract: exactly one of {java-tool-options, update-ca-trust, none}.
# Callers MUST equality-match. Keep in sync with installer's detect_mode.
detect_mode() {
    local anchor="${RHEL_ANCHOR_DIR}/${CERT_BASENAME}.crt"
    local jks_present=0 anchor_present=0
    [[ -f "$JKS_PATH" ]] && jks_present=1
    [[ -f "$anchor" ]] && anchor_present=1

    if [[ "$jks_present" -eq 1 && "$anchor_present" -eq 1 ]]; then
        # detect_mode is consumed via $(...), so anything on stdout that is
        # NOT the mode token leaks into the caller's $mode and breaks the case
        # dispatch. Route the whole warn block to stderr.
        {
            warn "Both Path A and Path B artifacts exist on disk:"
            warn "  $JKS_PATH"
            warn "  $anchor"
            warn "Reporting Path B (more recent mode preferred). Clean up the unused path manually."
        } >&2
        echo "java-tool-options"
        return
    fi

    if [[ "$jks_present" -eq 1 ]]; then
        echo "java-tool-options"
        return
    fi
    if [[ "$anchor_present" -eq 1 ]]; then
        echo "update-ca-trust"
        return
    fi
    echo "none"
}

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
        # Promoting to FAIL: the keystore-subject check is the validator's
        # core assertion; silently passing here would mean CI is green even
        # though we never verified the cert is in the store.
        fail "$label keystore present but keytool is not on PATH; cannot verify subject. Install a JDK."
        return 1
    fi

    # Capture keytool output explicitly so a real keytool error (wrong password,
    # corrupt store, version mismatch) is reported as such — and not silently
    # masked as a "subject not found" via pipefail+|| true on the pipeline.
    local keytool_output rc=0
    if ! keytool_output="$(keytool -list -v -keystore "$keystore" -storepass "$storepass" 2>&1)"; then
        fail "$label: keytool could not read the keystore. Output (first 3 lines):"
        printf '%s\n' "$keytool_output" | head -n3 | sed 's/^/        /'
        return 1
    fi

    # Two-stage filter via a variable, not a pipe-pair: under `set -o pipefail`
    # the second `grep -qi` exits early on match and SIGPIPEs the first, which
    # poisons the pipeline status and turns positive matches into false negatives.
    local owners
    owners="$(printf '%s\n' "$keytool_output" | grep -E '^Owner:' || true)"
    if ! grep -qi "$EXPECTED_SUBJECT" <<<"$owners"; then
        fail "$label has no cert with subject matching: $EXPECTED_SUBJECT"
        return 1
    fi

    # I8: defence-in-depth — assert every alias is a `trustedCertEntry`.
    # The installer only calls `keytool -importcert`, which creates
    # trustedCertEntry records. A `PrivateKeyEntry` showing up here would mean
    # someone (or a compromised future installer change) imported a keypair
    # into this store — the password protecting that key would then be
    # `changeit`, which is the well-known JDK default and unsuitable for
    # private-key material. Refuse to validate such a store.
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
    # Accept either quoted or unquoted trustStore=<path>. Installer now writes
    # the quoted form (cross-platform symmetry with macOS/Windows); older
    # installs may carry the unquoted form. Both are valid JTO values.
    if grep -qE "^export JAVA_TOOL_OPTIONS=.*trustStore=\"?${JKS_PATH}\"?" "$file" 2>/dev/null; then
        ok "$label contains JAVA_TOOL_OPTIONS pointing at $JKS_PATH"
        return 0
    fi
    if grep -qE '^export JAVA_TOOL_OPTIONS=' "$file" 2>/dev/null; then
        # Wrong-target export is a real problem: it overrides /etc/environment.
        fail "$label has JAVA_TOOL_OPTIONS but it does not point at $JKS_PATH"
        return 1
    fi
    # Missing export in user rc is not authoritative — /etc/environment is the source of truth.
    warn "$label has no JAVA_TOOL_OPTIONS export (current session may need re-login or 'source $file')"
    return 0
}

validate_environment_file() {
    if [[ ! -f "$ENVIRONMENT_FILE" ]]; then
        fail "$ENVIRONMENT_FILE does not exist"
        return 1
    fi
    # Accept either quoted or unquoted trustStore=<path>; see validate_export_in_file.
    if grep -qE "^JAVA_TOOL_OPTIONS=.*trustStore=\"?${JKS_PATH}\"?" "$ENVIRONMENT_FILE" 2>/dev/null; then
        ok "$ENVIRONMENT_FILE contains JAVA_TOOL_OPTIONS pointing at $JKS_PATH"
        return 0
    fi
    fail "$ENVIRONMENT_FILE has no JAVA_TOOL_OPTIONS pointing at $JKS_PATH"
    return 1
}

validate_path_a() {
    echo "Validating Path A (RHEL update-ca-trust)..."
    local anchor="${RHEL_ANCHOR_DIR}/${CERT_BASENAME}.crt"
    validate_pem_subject "$anchor" || true
    validate_keystore_contains_subject "$RHEL_JAVA_CACERTS" "$JKS_PASSWORD" "Java cacerts" || true
}

validate_path_b() {
    echo "Validating Path B (JKS + JAVA_TOOL_OPTIONS)..."
    validate_keystore_contains_subject "$JKS_PATH" "$JKS_PASSWORD" "Truststore $JKS_PATH" || true
    validate_environment_file || true

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

    # Current-process env hint: the most common "validator passed but
    # Maven still fails TLS" support ticket. /etc/environment is the
    # authoritative source for new login sessions, but the SHELL THIS
    # VALIDATOR IS RUNNING IN inherits its env at startup. If the user
    # ran install -> validate in the same shell, the env var won't be set.
    if [[ -z "${JAVA_TOOL_OPTIONS:-}" ]]; then
        echo "  HINT: JAVA_TOOL_OPTIONS is NOT set in this shell. Open a new"
        echo "        login shell, or 'source $ENVIRONMENT_FILE', then re-run"
        echo "        the build. The next 'mvn'/'gradle' won't see the trust"
        echo "        store until then."
    fi
}

main() {
    parse_args "$@"

    echo "Expected subject (case-insensitive substring): $EXPECTED_SUBJECT"
    echo

    local mode
    mode="$(detect_mode)"
    echo "Detected installer path: $mode"
    echo

    case "$mode" in
        update-ca-trust)   validate_path_a ;;
        java-tool-options) validate_path_b ;;
        none)
            echo "Error: no install_certs_jvm_linux.sh artifacts found for cert-name '$CERT_BASENAME'." >&2
            echo "  Expected one of:" >&2
            echo "    $JKS_PATH (Path B)" >&2
            echo "    ${RHEL_ANCHOR_DIR}/${CERT_BASENAME}.crt (Path A)" >&2
            echo "  If you installed with a non-default --cert-name, pass --cert-name here too." >&2
            exit 1
            ;;
    esac

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
