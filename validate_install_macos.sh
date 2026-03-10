#!/usr/bin/env bash
# Validate certificate installation: PEM file(s) exist and are valid; optionally check .zshrc exports.
# Run as any user. Use --all-users (as root) to check every user's config.
#
# Use after install_certs_macos.sh to confirm PEM files exist and are valid. No root needed for current user; use --cert-path to check a specific file, or --all-users as root to check every user's .zshrc and their cert paths. Exit 0 = all checks passed.
#
# Usage:
#   ./validate_install_macos.sh                    # Validate current user's cert path(s) from ~/.zshrc
#   ./validate_install_macos.sh --cert-path PATH   # Validate only this PEM file
#   sudo ./validate_install_macos.sh --all-users   # Validate each user's .zshrc and their cert path(s)
#   ./validate_install_macos.sh --expected-subject "Zscaler"  # Also require at least one cert in the bundle to match subject

set -e

CERT_PATH=""
ALL_USERS=0
EXPECTED_SUBJECT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cert-path)
            CERT_PATH="${2:?Error: --cert-path requires a value}"
            shift 2
            ;;
        --all-users)
            ALL_USERS=1
            shift
            ;;
        --expected-subject)
            EXPECTED_SUBJECT="${2:?Error: --expected-subject requires a value}"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--cert-path <path>] [--all-users] [--expected-subject <pattern>]"
            echo ""
            echo "  --cert-path <path>       Validate only this PEM file (exists and valid PEM)."
            echo "  --all-users              (Root only) Validate each user's .zshrc and cert path(s)."
            echo "  --expected-subject <pat> Require at least one cert in each PEM file to have subject matching <pat> (case-insensitive)."
            echo "  -h, --help               Print this help."
            echo ""
            echo "With no options: reads NODE_EXTRA_CA_CERTS and REQUESTS_CA_BUNDLE from current user's ~/.zshrc,"
            echo "expands ~ to home, and validates each referenced PEM file."
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

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
    if ! openssl x509 -in "$path" -noout 2>/dev/null; then
        # Multi-cert bundle: try to read first cert
        if ! awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/{print}' "$path" 2>/dev/null | openssl x509 -noout 2>/dev/null; then
            echo "  FAIL: not a valid PEM certificate (or bundle): $path"
            return 1
        fi
    fi
    if [ -n "$EXPECTED_SUBJECT" ]; then
        local content rest block subject found=0
        content=$(cat "$path")
        rest="$content"
        while [[ "$rest" == *"-----BEGIN CERTIFICATE-----"* ]]; do
            rest="${rest#*-----BEGIN CERTIFICATE-----}"
            rest="-----BEGIN CERTIFICATE-----${rest}"
            block="${rest%%-----END CERTIFICATE-----*}-----END CERTIFICATE-----"
            subject=$(printf '%s' "$block" | openssl x509 -noout -subject 2>/dev/null)
            if [ -n "$subject" ] && echo "$subject" | grep -qi "$EXPECTED_SUBJECT"; then
                found=1
                break
            fi
            rest="${rest#*-----END CERTIFICATE-----}"
        done
        if [ $found -eq 0 ]; then
            echo "  FAIL: no cert in $path has subject matching: $EXPECTED_SUBJECT"
            return 1
        fi
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

if [ -n "$CERT_PATH" ]; then
    echo "Validating single cert path: $CERT_PATH"
    validate_pem "$CERT_PATH" || FAIL=$((FAIL+1))
elif [ "$ALL_USERS" -eq 1 ]; then
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
