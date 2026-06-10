#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Validate JVM truststore installation done by install_certs_jvm_macos.sh.
#
# Asserts, per user:
#   1. JKS file exists at ~/Library/Application Support/JFrog/package-route-jvm/truststore.jks
#   2. JKS contains a cert whose subject matches --expected-subject
#   3. LaunchAgent plist exists at ~/Library/LaunchAgents/com.jfrog.package-reroute.jto-env.plist
#   4. launchctl getenv JAVA_TOOL_OPTIONS in gui/<uid> returns the JKS path
#      (only verifiable when the user is in an active GUI session; warn-not-fail
#      otherwise — the plist still loads on next login).
#
# Run:
#   bash validate_certs_jvm_macos.sh --expected-subject "O=Zscaler"
#   sudo bash validate_certs_jvm_macos.sh --expected-subject "O=Zscaler" --all-users
#
# Exit 0 = all checks passed; 1 = at least one failure.
#
# Cross-platform siblings (keep CLI shapes and contracts in sync):
#   validate_certs_jvm_linux.sh      — system anchor OR JKS+JTO check
#   validate_certs_jvm_windows.ps1   — HKCU\Environment JTO check
#
# Research / rationale: see the JVM client-onboarding wiki page
#   https://jfrog-int.atlassian.net/wiki/spaces/RTFACT/pages/2440101931/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/_jvm_macos_paths.sh" ]]; then
    echo "Error: _jvm_macos_paths.sh not found next to this validator (${SCRIPT_DIR})." >&2
    echo "       Invoke as ./validate_certs_jvm_macos.sh — not via 'curl | bash'." >&2
    exit 1
fi
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/_jvm_macos_paths.sh"

ALL_USERS=0
EXPECTED_SUBJECT=""

usage() {
    cat <<EOF
Usage:
  $0 --expected-subject <substring> [--all-users] [--cert-name <name>]

Options:
  --expected-subject <substring>   Required. Case-insensitive substring match against the cert subject.
  --all-users                      Iterate /Users/* (UID >= 501). Requires root.
  --cert-name <name>               Accepted for cross-platform CLI parity with the Linux validator.
                                   Ignored here: macOS matches by subject substring, and the JKS path /
                                   LaunchAgent label are fixed per-user regardless of cert-name.
  -h, --help                       Show this help

Exits 0 if all checks pass, 1 if any check fails. Result line is qualified
with a count of any non-fatal warnings (e.g. gui/<uid> domain absent on
headless / non-active accounts).
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

    if [[ "$ALL_USERS" -eq 1 && "$(id -u)" -ne 0 ]]; then
        echo "Error: --all-users requires root (other users' ~/Library is 0700)." >&2
        echo "Use: sudo $0 --all-users --expected-subject ..." >&2
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
WARN=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
ok()   { echo "  OK:   $1"; }
warn() { echo "  WARN: $1"; WARN=$((WARN + 1)); }

# When iterating --all-users, reads of /Users/<other>/Library need root.
# Wrap file tests so the same call works in both single-user and --all-users mode.
file_exists() {
    local path="$1"
    if [[ -f "$path" ]]; then
        return 0
    fi
    [[ "$ALL_USERS" -eq 1 ]] && sudo test -f "$path"
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

validate_launch_agent_plist() {
    local plist_path="$1" label="$2"
    if file_exists "$plist_path"; then
        if command -v plutil >/dev/null 2>&1; then
            if [[ "$ALL_USERS" -eq 1 ]]; then
                if sudo plutil -lint "$plist_path" >/dev/null 2>&1; then
                    ok "$label plist exists and is well-formed: $plist_path"
                    return 0
                fi
            else
                if plutil -lint "$plist_path" >/dev/null 2>&1; then
                    ok "$label plist exists and is well-formed: $plist_path"
                    return 0
                fi
            fi
            fail "$label plist exists but plutil -lint reports it as malformed: $plist_path"
            return 1
        fi
        ok "$label plist exists: $plist_path"
        return 0
    fi
    fail "$label LaunchAgent plist not found: $plist_path"
    return 1
}

validate_launchctl_getenv() {
    local target_uid="$1" jks_path="$2" label="$3"
    local domain="gui/${target_uid}"

    if ! launchctl print "$domain" >/dev/null 2>&1; then
        warn "$label is not in an active GUI session (no $domain); plist will activate at next login."
        return 0
    fi

    local seen
    seen="$(launchctl asuser "$target_uid" launchctl getenv JAVA_TOOL_OPTIONS 2>/dev/null || true)"
    if [[ -z "$seen" ]]; then
        fail "$label: $domain is active but launchctl getenv JAVA_TOOL_OPTIONS is empty."
        return 1
    fi

    # Accept both quoted and unquoted forms. The installer writes the quoted
    # form so the JVM tokenizer respects the space in "Application Support";
    # older installs (pre-bug-fix) wrote the unquoted form and we still want
    # the validator to recognise their JKS pointer as valid for diagnosis.
    case "$seen" in
        *"trustStore=\"${jks_path}\""*|*"trustStore=${jks_path} "*|*"trustStore=${jks_path}")
            ok "$label: $domain launchctl getenv JAVA_TOOL_OPTIONS points at $jks_path"
            return 0
            ;;
        *)
            fail "$label: $domain launchctl getenv JAVA_TOOL_OPTIONS does not point at $jks_path (got: $seen)"
            return 1
            ;;
    esac
}

validate_for_user() {
    local user="$1" home="$2"
    local uid
    uid="$(id -u "$user")"
    local jks="${home}/${JKS_RELATIVE_DIR}/${JKS_BASENAME}"
    local plist="${home}/${LAUNCH_AGENT_RELATIVE_DIR}/${LAUNCH_AGENT_BASENAME}"

    echo "Checking user $user (uid=$uid)..."
    validate_keystore_contains_subject "$jks" "$JKS_PASSWORD" "$user truststore" || true
    validate_launch_agent_plist        "$plist" "$user"                          || true
    validate_launchctl_getenv          "$uid" "$jks" "$user"                     || true
}

main() {
    parse_args "$@"
    check_os

    echo "Expected subject (case-insensitive substring): $EXPECTED_SUBJECT"
    echo

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
        if [[ "$WARN" -eq 0 ]]; then
            echo "Result: All checks passed."
        else
            # Qualify so a green exit doesn't over-promise. The common case
            # is "gui/<uid> domain absent" (validator can't verify launchctl
            # getenv without an active GUI session — plist will activate at
            # next login).
            echo "Result: All checks passed (with $WARN warning(s) — see above)."
        fi
        exit 0
    else
        echo "Result: $FAIL check(s) failed (and $WARN warning(s))."
        exit 1
    fi
}

main "$@"
