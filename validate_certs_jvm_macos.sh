#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Validate JVM truststore installation done by install_certs_jvm_macos.sh.
#
# Asserts, per user:
#   1. JKS file exists at the path given by --use-truststore
#   2. JKS contains a cert whose subject matches --expected-subject
#   3. ~/.zshrc exports JAVA_TOOL_OPTIONS pointing at that JKS path
#
# Run:
#   bash validate_certs_jvm_macos.sh --expected-subject "O=Zscaler" \
#       --use-truststore /path/to/truststore.jks
#   sudo bash validate_certs_jvm_macos.sh --expected-subject "O=Zscaler" \
#       --use-truststore /path/to/truststore.jks --all-users
#
# Exit 0 = all checks passed; 1 = at least one failure.
#
# Cross-platform siblings (keep CLI shapes and contracts in sync):
#   validate_certs_jvm_linux.sh      — /etc/environment JTO check
#   validate_certs_jvm_windows.ps1   — HKCU\Environment JTO check
#
# Research / rationale: see the JVM client-onboarding wiki page
#   https://jfrog-int.atlassian.net/wiki/spaces/RTFACT/pages/2440101931/

set -euo pipefail

# Keep this validator self-contained: it is often copied/run as a standalone
# script during onboarding, so avoid requiring sibling files for constants.
JKS_PASSWORD="changeit"

ALL_USERS=0
EXPECTED_SUBJECT=""
USE_TRUSTSTORE=""

usage() {
    cat <<EOF
Usage:
  $0 --expected-subject <substring> --use-truststore <path> [--all-users] [--cert-name <name>]

Options:
  --expected-subject <substring>   Required. Case-insensitive substring match against the cert subject.
  --use-truststore <path>          Required. Path to the IT-published JKS that install wired into
                                   JAVA_TOOL_OPTIONS (same value passed to the installer).
  --all-users                      Iterate /Users/* (UID >= 501). Requires root.
  --cert-name <name>               Accepted for cross-platform CLI parity with the Linux validator.
                                   Ignored here: macOS matches by subject substring.
  -h, --help                       Show this help

Exits 0 if all checks pass, 1 if any check fails.
EOF
}

canonicalize_path() {
    local path="$1"
    local dir base
    if command -v realpath >/dev/null 2>&1; then
        realpath "$path"
        return 0
    fi
    dir="$(cd "$(dirname "$path")" && pwd)"
    base="$(basename "$path")"
    echo "${dir}/${base}"
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
            --use-truststore)
                USE_TRUSTSTORE="${2:?Error: --use-truststore requires a value}"
                shift 2
                ;;
            --cert-name)
                # Cross-platform CLI parity (see usage). A fleet wrapper that
                # passes --cert-name to all three validators must not fail on
                # macOS. We accept and silently ignore: macOS matches by
                # subject substring, not by alias name.
                : "${2:?Error: --cert-name requires a value}"
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

    if [[ -z "$USE_TRUSTSTORE" ]]; then
        echo "Error: --use-truststore is required." >&2
        usage >&2
        exit 1
    fi

    if [[ ! -f "$USE_TRUSTSTORE" ]]; then
        echo "Error: truststore file not found: $USE_TRUSTSTORE" >&2
        exit 1
    fi

    USE_TRUSTSTORE="$(canonicalize_path "$USE_TRUSTSTORE")"

    if [[ "$ALL_USERS" -eq 1 && "$(id -u)" -ne 0 ]]; then
        echo "Error: --all-users requires root (other users' homes are typically 0700)." >&2
        echo "Use: sudo $0 --all-users --expected-subject ... --use-truststore ..." >&2
        exit 1
    fi
}

check_os() {
    local os
    os="$(uname -s)"
    if [[ "$os" != "Darwin" ]]; then
        echo "Error: this script supports macOS only (detected: $os)." >&2
        exit 1
    fi
}

FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
ok()   { echo "  OK:   $1"; }

# When iterating --all-users, reads of /Users/<other> need root.
# Wrap file tests so the same call works in both single-user and --all-users mode.
file_exists() {
    local path="$1"
    if [[ -f "$path" ]]; then
        return 0
    fi
    [[ "$ALL_USERS" -eq 1 ]] && sudo test -f "$path"
}

read_file() {
    local path="$1"
    if [[ "$ALL_USERS" -eq 1 ]]; then
        sudo cat "$path"
    else
        cat "$path"
    fi
}

get_user_home() {
    local user="$1"
    local home
    home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    if [[ -z "$home" ]]; then
        home="$(eval echo "~${user}")"
    fi
    echo "$home"
}

iter_all_users() {
    local dir base uid
    for dir in /Users/*; do
        [[ -d "$dir" ]] || continue
        base="$(basename "$dir")"
        [[ "$base" == "Shared" || "$base" == ".localized" ]] && continue
        uid="$(stat -f '%u' "$dir" 2>/dev/null || true)"
        [[ -n "$uid" && "$uid" -ge 501 ]] || continue
        id -u "$base" >/dev/null 2>&1 || continue
        printf '%s\t%s\n' "$base" "$dir"
    done
}

validate_keystore_contains_subject() {
    local keystore="$1" storepass="$2" label="$3"
    if ! file_exists "$keystore"; then
        fail "$label keystore does not exist: $keystore"
        return 1
    fi
    if ! command -v keytool >/dev/null 2>&1; then
        # JKS exists but we can't open it. Don't silently pass the core invariant.
        fail "$label keystore present but keytool is not on PATH; cannot verify subject. Install a JDK."
        return 1
    fi

    # Capture keytool output explicitly. Reading another user's keystore under
    # --all-users requires sudo; the single-user case reads as the current user.
    local keytool_output rc
    if [[ "$ALL_USERS" -eq 1 ]]; then
        keytool_output="$(sudo keytool -list -v -keystore "$keystore" -storepass "$storepass" 2>&1)"
        rc=$?
    else
        keytool_output="$(keytool -list -v -keystore "$keystore" -storepass "$storepass" 2>&1)"
        rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
        fail "$label: keytool could not read the keystore. Output (first 3 lines):"
        printf '%s\n' "$keytool_output" | head -n3 | sed 's/^/        /'
        return 1
    fi

    # Two-stage filter via a variable, not a pipe-pair: under set -o pipefail
    # the second grep -qi exits early on match and SIGPIPEs the first, which
    # poisons the pipeline status and turns positive matches into false negatives.
    local owners
    owners="$(printf '%s\n' "$keytool_output" | grep -E '^Owner:' || true)"
    if ! grep -qi "$EXPECTED_SUBJECT" <<<"$owners"; then
        fail "$label has no cert with subject matching: $EXPECTED_SUBJECT"
        return 1
    fi
    # I8 cross-platform parity (see validate_certs_jvm_linux.sh): refuse to
    # validate stores that contain key material. The installer only writes
    # trustedCertEntry records, so any PrivateKeyEntry here indicates drift
    # — likely a future installer change or hand-edited store. The well-known
    # `changeit` password is unsuitable for actual private-key protection.
    if printf '%s\n' "$keytool_output" | grep -qE '^Entry type: PrivateKeyEntry'; then
        fail "$label contains a PrivateKeyEntry — this truststore must hold only trustedCertEntry records."
        return 1
    fi
    ok "$label contains cert with subject matching: $EXPECTED_SUBJECT"
    return 0
}

# Extract the unquoted value from `export VAR="…"`. Handles both double-quoted
# and bare forms written by ensure_export_in_file.
get_export_value() {
    local file="$1" var="$2"
    local line
    if ! file_exists "$file"; then
        return 1
    fi
    line="$(read_file "$file" | grep -E "^export ${var}=" | head -1 || true)"
    [[ -n "$line" ]] || return 1
    line="${line#export ${var}=}"
    # Strip one layer of surrounding quotes if present.
    if [[ "$line" == \"*\" ]]; then
        line="${line:1:${#line}-2}"
    fi
    # Unescape \" and \\ that ensure_export_in_file wrote.
    line="${line//\\\"/\"}"
    line="${line//\\\\/\\}"
    printf '%s' "$line"
}

validate_zshrc_jto() {
    local zshrc="$1" jks_path="$2" label="$3"
    local seen

    if ! file_exists "$zshrc"; then
        fail "$label .zshrc not found: $zshrc"
        return 1
    fi

    if ! seen="$(get_export_value "$zshrc" "JAVA_TOOL_OPTIONS")"; then
        fail "$label: $zshrc has no export JAVA_TOOL_OPTIONS="
        return 1
    fi

    # Accept both quoted and unquoted trustStore= forms.
    case "$seen" in
        *"trustStore=\"${jks_path}\""*|*"trustStore=${jks_path} "*|*"trustStore=${jks_path}")
            ok "$label: $zshrc JAVA_TOOL_OPTIONS points at $jks_path"
            return 0
            ;;
        *)
            fail "$label: $zshrc JAVA_TOOL_OPTIONS does not point at $jks_path (got: $seen)"
            return 1
            ;;
    esac
}

validate_for_user() {
    local user="$1" home="$2"
    local uid
    uid="$(id -u "$user")"
    local zshrc="${home}/.zshrc"

    echo "Checking user $user (uid=$uid)..."
    validate_zshrc_jto "$zshrc" "$USE_TRUSTSTORE" "$user" || true
}

main() {
    parse_args "$@"
    check_os

    echo "Expected subject (case-insensitive substring): $EXPECTED_SUBJECT"
    echo "Truststore path: $USE_TRUSTSTORE"
    echo

    # Truststore content is shared (IT-published); check once, then per-user JTO.
    validate_keystore_contains_subject "$USE_TRUSTSTORE" "$JKS_PASSWORD" "Truststore $USE_TRUSTSTORE" || true

    if [[ "$ALL_USERS" -eq 1 ]]; then
        local iter_count=0 user home
        while IFS=$'\t' read -r user home; do
            validate_for_user "$user" "$home"
            iter_count=$((iter_count + 1))
        done < <(iter_all_users)
        if [[ "$iter_count" -eq 0 ]]; then
            fail "no eligible users found under /Users/* (UID >= 501)"
        fi
    else
        # Default: validate the invoking user. If invoked via sudo, use SUDO_USER;
        # otherwise the current $USER.
        local user
        if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
            user="$SUDO_USER"
        else
            user="$(id -un)"
        fi
        if [[ "$user" == "root" ]]; then
            fail "cannot validate as root without --all-users (no home to inspect)"
        else
            local home
            home="$(get_user_home "$user")"
            if [[ -z "$home" || ! -d "$home" ]]; then
                fail "home directory not found for $user"
            else
                validate_for_user "$user" "$home"
            fi
        fi
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
