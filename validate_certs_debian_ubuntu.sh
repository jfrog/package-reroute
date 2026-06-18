#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Validate certificate installation after install_certs_debian_ubuntu.sh:
# PEM file(s) exist and are valid; require subject match on each checked path.
# Also checks /etc/profile.d/package-route-certs.sh when present.
#
# Run:
#   bash validate_certs_debian_ubuntu.sh --expected-subject "O=Example"
#   sudo bash validate_certs_debian_ubuntu.sh --all-users --expected-subject "O=Example"
#
# Exit 0 = all checks passed.

set -euo pipefail

ALL_USERS=0
EXPECTED_SUBJECT=""

PROFILED_FILE="/etc/profile.d/package-route-certs.sh"

usage() {
    cat <<EOF
Usage:
  $0 --expected-subject <substring> [--all-users]

Options:
  --expected-subject <substring>   Required. Case-insensitive match against openssl -subject (any cert in PEM/bundle).
  --all-users                      Validate /home/* users' ~/.bashrc and ~/.zshrc (requires root).
  -h, --help                       Show this help

Also validates $PROFILED_FILE when it exists (NODE_EXTRA_CA_CERTS, REQUESTS_CA_BUNDLE, SSL_CERT_FILE).
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
}

FAIL=0

validate_pem() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "  FAIL: file does not exist: $path"
        return 1
    fi
    if ! openssl x509 -in "$path" -noout 2>/dev/null; then
        if ! awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/{print}' "$path" 2>/dev/null | openssl x509 -noout 2>/dev/null; then
            echo "  FAIL: not a valid PEM certificate (or bundle): $path"
            return 1
        fi
    fi
    local content rest block subject found=0
    content=$(cat "$path")
    rest="$content"
    while [[ "$rest" == *"-----BEGIN CERTIFICATE-----"* ]]; do
        rest="${rest#*-----BEGIN CERTIFICATE-----}"
        rest="-----BEGIN CERTIFICATE-----${rest}"
        block="${rest%%-----END CERTIFICATE-----*}-----END CERTIFICATE-----"
        subject=""
        subject=$( (printf '%s' "$block" | openssl x509 -noout -subject 2>/dev/null) || true )
        if [[ -n "$subject" ]] && echo "$subject" | grep -qi "$EXPECTED_SUBJECT"; then
            found=1
            break
        fi
        rest="${rest#*-----END CERTIFICATE-----}"
    done
    if [[ $found -eq 0 ]]; then
        echo "  FAIL: no cert in $path has subject matching: $EXPECTED_SUBJECT"
        return 1
    fi
    echo "  OK: valid PEM at $path"
    return 0
}

get_export_path() {
    local f="$1" var="$2" expand_home="${3:-}"
    local line path
    [[ ! -f "$f" ]] && echo "" && return 0
    line=$(grep -E "^export ${var}=" "$f" 2>/dev/null | head -1) || true
    [[ -z "$line" ]] && echo "" && return 0
    path=$(echo "$line" | sed -E "s/^export ${var}=//" | sed -E 's/^["'\'']//;s/["'\'']$//')
    if [[ -n "$expand_home" && "$path" == "~"* ]]; then
        path="${expand_home}${path#\~}"
    fi
    echo "$path"
}

# Pipe-delimited list of paths already checked in this block (paths should not contain |).
DEDUPE="|"

validate_path_deduped() {
    local path="$1"
    [[ -z "$path" ]] && return 0
    [[ "$DEDUPE" == *"|${path}|"* ]] && return 0
    DEDUPE="${DEDUPE}${path}|"
    if ! validate_pem "$path"; then
        FAIL=$((FAIL + 1))
    fi
}

validate_from_rc_files() {
    local label="$1" home="$2"
    shift 2
    local rc_files=("$@")
    local any=0

    DEDUPE="|"
    for rc in "${rc_files[@]}"; do
        [[ -f "$rc" ]] || continue
        any=1
        validate_path_deduped "$(get_export_path "$rc" "NODE_EXTRA_CA_CERTS" "$home")"
        validate_path_deduped "$(get_export_path "$rc" "REQUESTS_CA_BUNDLE" "$home")"
        validate_path_deduped "$(get_export_path "$rc" "SSL_CERT_FILE" "$home")"
    done

    if [[ $any -eq 0 ]]; then
        echo "  SKIP: no rc files found for $label"
        return 0
    fi

    if [[ "$DEDUPE" == "|" ]]; then
        echo "  WARN: no NODE_EXTRA_CA_CERTS, REQUESTS_CA_BUNDLE, or SSL_CERT_FILE in rc files for $label"
    fi
}

validate_profiled() {
    if [[ ! -f "$PROFILED_FILE" ]]; then
        echo "  SKIP: $PROFILED_FILE not present"
        return 0
    fi

    echo "  Checking $PROFILED_FILE ..."
    DEDUPE="|"
    validate_path_deduped "$(get_export_path "$PROFILED_FILE" "NODE_EXTRA_CA_CERTS" "")"
    validate_path_deduped "$(get_export_path "$PROFILED_FILE" "REQUESTS_CA_BUNDLE" "")"
    validate_path_deduped "$(get_export_path "$PROFILED_FILE" "SSL_CERT_FILE" "")"

    if [[ "$DEDUPE" == "|" ]]; then
        echo "  WARN: no expected exports in $PROFILED_FILE"
    fi
}

check_os_hint() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]] && [[ "${ID_LIKE:-}" != *debian* ]]; then
            echo "Warning: not Debian/Ubuntu (ID=${ID:-unknown}). Paths may differ." >&2
        fi
    fi
}

main() {
    parse_args "$@"
    check_os_hint

    echo "Expected subject (case-insensitive substring): $EXPECTED_SUBJECT"
    echo

    if [[ "$ALL_USERS" -eq 1 ]]; then
        if [[ "$(id -u)" -ne 0 ]]; then
            echo "Error: --all-users requires root. Use: sudo $0 --all-users --expected-subject ..." >&2
            exit 1
        fi
        echo "Validating profile.d and all users under /home/* ..."
        validate_profiled
        for homedir in /home/*; do
            [[ -d "$homedir" ]] || continue
            user=$(basename "$homedir")
            echo "  Checking user $user ..."
            validate_from_rc_files "user $user" "$homedir" "$homedir/.bashrc" "$homedir/.zshrc"
        done
    else
        echo "Validating profile.d and current user rc files ..."
        [[ -z "${HOME:-}" ]] && HOME=$(eval echo "~")
        validate_profiled
        echo "  Checking current user ..."
        validate_from_rc_files "current user" "$HOME" "$HOME/.bashrc" "$HOME/.zshrc"
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
