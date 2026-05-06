#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Export macOS Keychain CAs and configure Node/npm and/or pip for redirect-proxy usage.
# Run: sudo bash install_certs_macos.sh [OPTIONS]
#
# Options:
#   --package npm|pip|all      What to configure: npm, pip, or both (default: all)
#   --extract-path <path>      Path under each user's home for the PEM
#                              (writes ~/<path>/package-route.pem). The PEM is a single
#                              export of BOTH macOS Keychains (SystemRootCertificates +
#                              System) — includes Apple's system roots AND enterprise
#                              CAs like Zscaler. Cannot be combined with --use-cert.
#   --use-cert <path>          Path to an already-existing PEM cert file. Sets env vars
#                              to point at this file; does not touch the Keychain.
#                              Cannot be combined with --extract-path.
#   --install-dependencies     If openssl is missing, install it via Homebrew and continue
#
# Either --extract-path OR --use-cert must be provided (exactly one).
#
# What it writes:
#   Per-user PEM bundle at ~/<extract-path>/package-route.pem (full Keychain dump).
#
#   User's .zshrc gets these env vars (pointing at the PEM file):
#     NODE_USE_SYSTEM_CA=1, NODE_EXTRA_CA_CERTS, UV_NATIVE_TLS=true,
#     UV_SYSTEM_CERTS=true, REQUESTS_CA_BUNDLE,
#     HF_HUB_DISABLE_XET=1, HF_HUB_ETAG_TIMEOUT=86400, HF_HUB_DOWNLOAD_TIMEOUT=86400 (pip/Hugging Face Hub)
#
# After run, users need a new shell (or source ~/.zshrc) to pick up env vars.
# To verify: run validate_install_macos.sh for current user,
# or sudo validate_install_macos.sh --all-users.

set -e

# Single temp dir for the whole script; removed on EXIT.
SCRIPT_TMP=$(mktemp -d)
trap '[ -n "${SCRIPT_TMP:-}" ] && rm -rf "$SCRIPT_TMP"' EXIT

PACKAGE=""
EXTRACT_PATH=""
USE_CERT=""
INSTALL_DEPS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --package)
            PACKAGE="${2:?Error: --package requires a value}"
            shift 2
            ;;
        --extract-path)
            EXTRACT_PATH="${2:?Error: --extract-path requires a value}"
            shift 2
            ;;
        --use-cert)
            USE_CERT="${2:?Error: --use-cert requires a value}"
            shift 2
            ;;
        --install-dependencies)
            INSTALL_DEPS=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--package npm|pip|all] [--extract-path <path> | --use-cert <path>] [--install-dependencies]"
            echo ""
            echo "  --package npm|pip|all      Configure npm (NODE_USE_SYSTEM_CA, NODE_EXTRA_CA_CERTS), pip (UV_NATIVE_TLS, UV_SYSTEM_CERTS, REQUESTS_CA_BUNDLE, Hugging Face Hub vars), or both (default: all)"
            echo "  --extract-path <path>      Path under each user's home for the PEM (writes ~/<path>/package-route.pem as a full Keychain dump)"
            echo "  --use-cert <path>          Path to an existing PEM cert file (cannot be used with --extract-path)"
            echo "  --install-dependencies     Install openssl via Homebrew if missing, then continue"
            echo ""
            echo "Either --extract-path or --use-cert must be provided (exactly one)."
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Default package to all if not provided.
[ -z "$PACKAGE" ] && PACKAGE="all"

case "$PACKAGE" in
    npm|pip|all) ;;
    *)
        echo "Error: --package must be npm, pip, or all (got: $PACKAGE)." >&2
        exit 1
        ;;
esac

# Cert source: exactly one of --extract-path or --use-cert.
if [ -n "$USE_CERT" ] && [ -n "$EXTRACT_PATH" ]; then
    echo "Error: --use-cert and --extract-path cannot be used together." >&2
    exit 1
fi
if [ -z "$USE_CERT" ] && [ -z "$EXTRACT_PATH" ]; then
    echo "Error: either --extract-path or --use-cert must be provided." >&2
    echo "Run $0 --help for usage." >&2
    exit 1
fi
if [ -n "$USE_CERT" ] && [ ! -f "$USE_CERT" ]; then
    echo "Error: --use-cert path is not a file: $USE_CERT" >&2
    exit 1
fi

# Prepend common paths so openssl and security (Keychain) are found when PATH is minimal (e.g. under some MDM runners).
export PATH="/usr/bin:/opt/homebrew/opt/openssl/bin:/opt/homebrew/bin:/usr/local/opt/openssl/bin:/usr/local/bin:$PATH"

# Must run as root: script writes under /Users/* and reads system keychains.
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root. Use: sudo $0 [options]" >&2
    exit 1
fi

do_npm() { [ "$PACKAGE" = "npm" ] || [ "$PACKAGE" = "all" ]; }
do_pip() { [ "$PACKAGE" = "pip" ] || [ "$PACKAGE" = "all" ]; }

# --install-dependencies: install openssl via Homebrew in this run so admins don't need a second pass.
if [ "$INSTALL_DEPS" -eq 1 ] && ! command -v openssl >/dev/null 2>&1; then
    BREW=""
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$b" ] && BREW="$b" && break
    done
    [ -z "$BREW" ] && command -v brew >/dev/null 2>&1 && BREW="brew"
    if [ -z "$BREW" ]; then
        echo "Error: openssl is missing and Homebrew is not installed." >&2
        exit 1
    fi
    echo "Installing openssl via Homebrew..."
    "$BREW" install openssl || { echo "Error: brew install openssl failed." >&2; exit 1; }
    BREW_PREFIX=$("$BREW" --prefix openssl 2>/dev/null) && [ -d "$BREW_PREFIX/bin" ] && export PATH="$BREW_PREFIX/bin:$PATH"
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl is required but not found on PATH." >&2
    echo "Run with --install-dependencies to install openssl via Homebrew." >&2
    exit 1
fi

if [ -z "$USE_CERT" ] && ! command -v security >/dev/null 2>&1; then
    echo "Error: 'security' (macOS Keychain CLI) is required but not found." >&2
    exit 1
fi

echo "--- Extracting certificate and configuring ($PACKAGE) ---"

# --- Helpers ---

# True if file is a valid PEM (openssl x509 can parse it).
validate_pem() {
    local path="$1"
    [ -f "$path" ] || return 1
    openssl x509 -in "$path" -noout 2>/dev/null
}

# Read current value of an exported env var from a shell rc file. Expands leading ~ to $2.
get_export_path() {
    local f="$1" var="$2" expand_home="${3:-}"
    local line path
    line=$(grep -E "^export ${var}=" "$f" 2>/dev/null | head -1)
    [ -z "$line" ] && return 0
    path=$(echo "$line" | sed -E "s/^export ${var}=//" | sed -E 's/^["'\'']//;s/["'\'']$//')
    [ -n "$expand_home" ] && [ -z "${path%%~*}" ] && path="${expand_home}${path#\~}"
    echo "$path"
}

# Replace every "export VAR=..." line in a file with a new value. Symlink-safe (writes
# through the symlink target by redirecting rather than mv'ing a new file over it).
replace_export_in_file() {
    local f="$1" var="$2" new_value="$3"
    [ ! -f "$f" ] && return 1
    local tmp escaped
    escaped="${new_value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    tmp=$(mktemp "$SCRIPT_TMP/zshrc.XXXXXX")
    awk -v var="$var" -v val="$escaped" '
        $0 ~ "^export " var "=" { print "export " var "=\"" val "\""; next }
        { print }
    ' "$f" > "$tmp" && cat "$tmp" > "$f" && rm -f "$tmp"
}

# Ensure a simple "export VAR=<value>" is present in the file. Adds if missing;
# replaces if present with a different value; leaves as-is if already matches.
ensure_export() {
    local f="$1" var="$2" value="$3"
    [ ! -f "$f" ] && return 1
    if ! grep -q "^export ${var}=" "$f" 2>/dev/null; then
        echo "export ${var}=${value}" >> "$f"
    else
        local current
        current=$(grep -E "^export ${var}=" "$f" 2>/dev/null | head -1 | sed -E "s/^export ${var}=//" | sed -E 's/^["'\'']//;s/["'\'']$//')
        if [ "$current" != "$value" ]; then
            replace_export_in_file "$f" "$var" "$value"
        fi
    fi
}

if [ -n "$USE_CERT" ]; then
    echo "[1/3] Using existing certificate at $USE_CERT..."
    validate_pem "$USE_CERT" || { echo "[Error] Invalid or missing PEM at: $USE_CERT" >&2; exit 1; }
else
    echo "[1/3] Preparing per-user PEM bundle (full Keychain export)..."
fi

# Writes/updates cert-related env vars in the user's .zshrc.
add_exports_to_file() {
    local f="$1" cert_path="$2"
    [ ! -e "$cert_path" ] && return 0

    if do_npm; then
        ensure_export "$f" "NODE_USE_SYSTEM_CA" "1"
        if [ -z "$(get_export_path "$f" "NODE_EXTRA_CA_CERTS" "$(dirname "$f")")" ]; then
            echo "export NODE_EXTRA_CA_CERTS=\"$cert_path\"" >> "$f"
        else
            replace_export_in_file "$f" "NODE_EXTRA_CA_CERTS" "$cert_path"
        fi
    fi

    if do_pip; then
        # UV_NATIVE_TLS (< 0.11.0) and UV_SYSTEM_CERTS (>= 0.11.0) both to "true" for compatibility.
        ensure_export "$f" "UV_NATIVE_TLS" "true"
        ensure_export "$f" "UV_SYSTEM_CERTS" "true"
        if [ -z "$(get_export_path "$f" "REQUESTS_CA_BUNDLE" "$(dirname "$f")")" ]; then
            echo "export REQUESTS_CA_BUNDLE=\"$cert_path\"" >> "$f"
        else
            replace_export_in_file "$f" "REQUESTS_CA_BUNDLE" "$cert_path"
        fi
        # Hugging Face Hub: corporate MITM / Artifactory redirect flows (no XET; longer timeouts).
        ensure_export "$f" "HF_HUB_DISABLE_XET" "1"
        ensure_export "$f" "HF_HUB_ETAG_TIMEOUT" "86400"
        ensure_export "$f" "HF_HUB_DOWNLOAD_TIMEOUT" "86400"
    fi
}

# --- Per-user loop ---

echo "[2/3] Deploying cert bundle and env vars per user..."

for homedir in /Users/*; do
    [ "$homedir" = "/Users/Shared" ] && continue
    [ ! -d "$homedir" ] && continue
    # Skip system folders (UIDs below 501 are not human users on macOS).
    owner_uid=$(stat -f '%u' "$homedir" 2>/dev/null) || continue
    [ "$owner_uid" -lt 501 ] && continue

    if [ -n "$USE_CERT" ]; then
        user_cert_path="$USE_CERT"
    else
        # Path is always under user's home: ~/<extract-path>/package-route.pem.
        user_cert_path="${homedir}/${EXTRACT_PATH#/}/package-route.pem"
        mkdir -p "$(dirname "$user_cert_path")" 2>/dev/null || true
    fi

    if [ -z "$USE_CERT" ]; then
        # Export ALL trusted root CAs from BOTH macOS Keychains into a single PEM file.
        # This includes Apple's system roots AND enterprise CAs (including Zscaler).
        #
        # Why the Keychains (NOT /etc/ssl/cert.pem):
        #   - /etc/ssl/cert.pem is STATIC (only updated with macOS version upgrades)
        #   - SystemRootCertificates.keychain is DYNAMICALLY updated by Apple trust
        #     store updates, independent of macOS upgrades (~20-30 more CAs)
        #   - System.keychain includes enterprise CAs deployed via MDM (e.g., Zscaler)
        security find-certificate -a -p \
            /System/Library/Keychains/SystemRootCertificates.keychain \
            /Library/Keychains/System.keychain \
            > "$user_cert_path" 2>/dev/null
        validate_pem "$user_cert_path" || { echo "[Error] Exported PEM is invalid: $user_cert_path" >&2; exit 1; }
        chmod 644 "$user_cert_path" 2>/dev/null || true
        cert_count=$(grep -c 'BEGIN CERTIFICATE' "$user_cert_path" 2>/dev/null || echo 0)
        echo "   $(basename "$homedir"): $cert_count certs → $user_cert_path"
    fi

    # Directory guard: skip if .zshrc is accidentally a directory.
    zshrc="$homedir/.zshrc"
    if [ -d "$zshrc" ]; then
        echo "   [warn] Skipping $zshrc — it is a directory, not a file." >&2
        continue
    fi
    [ ! -f "$zshrc" ] && touch "$zshrc"

    add_exports_to_file "$zshrc" "$user_cert_path"

    # Restore ownership after root-owned writes.
    chown "$owner_uid" "$zshrc" 2>/dev/null || true
    if [ -z "$USE_CERT" ]; then
        cert_dir="$(dirname "$user_cert_path")"
        chown -R "$owner_uid" "$cert_dir" 2>/dev/null || true
        # Chown parent dirs up to homedir so the user owns the whole chain (can rm -rf).
        _dir="$cert_dir"
        while [ -n "$_dir" ] && [ "$_dir" != "$homedir" ]; do
            chown "$owner_uid" "$_dir" 2>/dev/null || true
            _dir="$(dirname "$_dir")"
        done
    fi
done

echo "[3/3] COMPLETE!"
echo ""
if [ -n "$USE_CERT" ]; then
    echo "Using existing cert at $USE_CERT for all users."
else
    echo "Certificate bundle exported to each user's path (owned by user)."
fi
echo "Env vars added to each user's .zshrc. Users must start a new terminal to pick them up."
