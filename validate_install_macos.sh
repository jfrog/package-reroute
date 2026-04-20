#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Validate certificate installation: PEM file(s) exist and are valid; require subject match.
# See README for usage. --expected-subject is required. Exit 0 = all checks passed.

set -e

ALL_USERS=0
EXPECTED_SUBJECT=""

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
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$EXPECTED_SUBJECT" ]; then
    echo "Error: --expected-subject is required." >&2
    exit 1
fi

export PATH="/usr/bin:/opt/homebrew/opt/openssl/bin:/opt/homebrew/bin:/usr/local/opt/openssl/bin:/usr/local/bin:$PATH"

FAIL=0

# Check that path exists and openssl accepts it as PEM (single cert or bundle).
# If EXPECTED_SUBJECT is set, at least one cert in the file must have a subject matching it (case-insensitive).
validate_pem() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "  FAIL: file does not exist: $path"
        return 1
    fi
    # crl2pkcs7 + pkcs7 -print_certs dumps every cert subject in one openssl pipeline,
    # which is much faster than walking the file cert-by-cert with a subprocess per cert
    # (matters for full-Keychain bundles of ~150+ certs: 3.8s → 0.03s).
    local subjects
    subjects=$(openssl crl2pkcs7 -nocrl -certfile "$path" 2>/dev/null | openssl pkcs7 -print_certs -noout 2>/dev/null)
    if [ -z "$subjects" ]; then
        echo "  FAIL: not a valid PEM certificate (or bundle): $path"
        return 1
    fi
    if ! echo "$subjects" | grep -qi "^subject=.*$EXPECTED_SUBJECT"; then
        echo "  FAIL: no cert in $path has subject matching: $EXPECTED_SUBJECT"
        return 1
    fi
    echo "  OK: valid PEM at $path"
    return 0
}

# Read first "export VAR=..." from file; strip quotes and expand ~. Used for NODE_EXTRA_CA_CERTS and REQUESTS_CA_BUNDLE.
get_export_path() {
    local f="$1" var="$2" expand_home="${3:-}"
    local line path
    [ ! -f "$f" ] && return 0
    line=$(grep -E "^export ${var}=" "$f" 2>/dev/null | head -1)
    [ -z "$line" ] && echo "" && return 0
    path=$(echo "$line" | sed -E "s/^export ${var}=//" | sed -E 's/^["'\'']//;s/["'\'']$//')
    [ -n "$expand_home" ] && [ -z "${path%%~*}" ] && path="${expand_home}${path#\~}"
    echo "$path"
}

# For one user: read .zshrc, get cert paths from exports, validate each PEM. Skips if no .zshrc or no exports.
validate_user_config() {
    local zshrc="$1" home="$2" label="${3:-$zshrc}"
    local node_path pip_path

    if [ ! -f "$zshrc" ]; then
        echo "  SKIP: no .zshrc at $zshrc"
        return 0
    fi

    node_path=$(get_export_path "$zshrc" "NODE_EXTRA_CA_CERTS" "$home")
    pip_path=$(get_export_path "$zshrc" "REQUESTS_CA_BUNDLE" "$home")

    if [ -z "$node_path" ] && [ -z "$pip_path" ]; then
        echo "  WARN: no NODE_EXTRA_CA_CERTS or REQUESTS_CA_BUNDLE in $label"
        return 0
    fi

    echo "  Checking $label ..."
    if [ -n "$node_path" ]; then
        validate_pem "$node_path" || FAIL=$((FAIL+1))
    fi
    if [ -n "$pip_path" ] && [ "$pip_path" != "$node_path" ]; then
        validate_pem "$pip_path" || FAIL=$((FAIL+1))
    fi
}

if [ "$ALL_USERS" -eq 1 ]; then
    # --all-users reads /Users/* and each user's .zshrc; requires root to access other users' homes.
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: --all-users requires root. Use: sudo $0 --all-users" >&2
        exit 1
    fi
    echo "Validating all users' config and cert paths..."
    for homedir in /Users/*; do
        [ "$homedir" = "/Users/Shared" ] && continue
        [ ! -d "$homedir" ] && continue
        user=$(basename "$homedir")
        validate_user_config "$homedir/.zshrc" "$homedir" "user $user"
    done
else
    # Default: current user only. Reads ~/.zshrc and validates NODE_EXTRA_CA_CERTS / REQUESTS_CA_BUNDLE paths.
    echo "Validating current user config (~/.zshrc) and cert path(s)..."
    [ -z "$HOME" ] && HOME=$(eval echo ~)
    validate_user_config "$HOME/.zshrc" "$HOME" "current user"
fi

echo "---------------------------------------------------"
if [ "$FAIL" -eq 0 ]; then
    echo "Result: All checks passed."
    exit 0
else
    echo "Result: $FAIL check(s) failed."
    exit 1
fi
