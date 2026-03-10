#!/usr/bin/env bash
# Auto-Extract certificate from keychain and configure Node/npm and/or pip for macOS
# Run: bash install_certs_macos.sh [OPTIONS]
#
# Options:
#   --package npm|pip|all      What to configure: npm, pip (REQUESTS_CA_BUNDLE), or all (default: all)
#   --cert-name <pattern>      Wildcard/regex to match exactly one cert in keychain (requires --extract-path)
#   --extract-path <path>      Path under each user's home for the PEM (writes ~/<path>/package-route.pem) (requires --cert-name)
#   --use-cert <path>          Path to an already existing PEM cert file (cannot be used with --cert-name/--extract-path)
#   --install-dependencies     If openssl is missing, install it via Homebrew and continue in the same run
#
# Either (--cert-name AND --extract-path) OR --use-cert must be provided, not both.
# If user had a different env path, it is replaced with the new path; new PEM is first, other PEMs from the old file are appended.
#
# Requirements: run as root; openssl on PATH; when using --cert-name, macOS security (Keychain) is also used. Installs the cert per user and adds env to each user's .zshrc.
#
# Run as root (e.g. sudo) so the script can write to /Users/* and system keychains.
# Use --use-cert when you already have a PEM from your PKI; use --cert-name + --extract-path to pull from macOS Keychain (e.g. after pushing a root CA via MDM).
# --extract-path is always under each user's home: ~/<path>/package-route.pem (e.g. /tmp/test-certs -> ~/tmp/test-certs/package-route.pem, or certs -> ~/certs/package-route.pem). After run, users need a new shell (or source ~/.zshrc) to pick up env vars.
# To verify: run scripts/validate_install_macos.sh (no root) for current user, or sudo scripts/validate_install_macos.sh --all-users.

set -e

# Single temp dir for the whole script; removed on EXIT (success, failure, or any exit).
SCRIPT_TMP=$(mktemp -d)
trap '[ -n "${SCRIPT_TMP:-}" ] && rm -rf "$SCRIPT_TMP"' EXIT

PACKAGE=""
CERT_NAME=""
EXTRACT_PATH=""
USE_CERT=""
INSTALL_DEPS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --package)
            PACKAGE="${2:?Error: --package requires a value}"
            shift 2
            ;;
        --cert-name)
            CERT_NAME="${2:?Error: --cert-name requires a value}"
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
            echo "Usage: $0 [--package npm|pip|all] [--cert-name <pattern> --extract-path <path> | --use-cert <path>] [--install-dependencies]"
            echo ""
            echo "  --package npm|pip|all      Configure npm (NODE_EXTRA_CA_CERTS, NODE_USE_SYSTEM_CA), pip (REQUESTS_CA_BUNDLE), or both (default: all)"
            echo "  --cert-name <pattern>      Wildcard/regex to match exactly one cert in keychain (requires --extract-path)"
            echo "  --extract-path <path>      Path under each user's home (writes ~/<path>/package-route.pem) (requires --cert-name)"
            echo "  --use-cert <path>          Path to an existing PEM cert file (cannot be used with --cert-name/--extract-path)"
            echo "  --install-dependencies     Install openssl via Homebrew if missing, then continue"
            echo ""
            echo "Either (--cert-name AND --extract-path) OR --use-cert must be provided, not both."
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Default package to all if not provided
[ -z "$PACKAGE" ] && PACKAGE="all"

case "$PACKAGE" in
    npm|pip|all) ;;
    *)
        echo "Error: --package must be npm, pip, or all (got: $PACKAGE)." >&2
        exit 1
        ;;
esac

# Cert source: either (cert-name + extract-path) or use-cert, not both.
# Prefer --use-cert with a path to your org's PEM if you have it; --cert-name is for pulling from Keychain when the CA was deployed there.
if [ -n "$USE_CERT" ]; then
    if [ -n "$CERT_NAME" ] || [ -n "$EXTRACT_PATH" ]; then
        echo "Error: --use-cert cannot be used together with --cert-name or --extract-path." >&2
        exit 1
    fi
    [ ! -f "$USE_CERT" ] && { echo "Error: --use-cert path is not a file: $USE_CERT" >&2; exit 1; }
else
    if [ -n "$CERT_NAME" ] && [ -z "$EXTRACT_PATH" ]; then
        echo "Error: --cert-name requires --extract-path to be set." >&2
        exit 1
    fi
    if [ -n "$EXTRACT_PATH" ] && [ -z "$CERT_NAME" ]; then
        echo "Error: --extract-path requires --cert-name to be set." >&2
        exit 1
    fi
    if [ -z "$CERT_NAME" ] && [ -z "$EXTRACT_PATH" ]; then
        echo "Error: either (--cert-name and --extract-path) or --use-cert must be provided." >&2
        echo "Run $0 --help for usage." >&2
        exit 1
    fi
fi


# Prepend common paths so openssl and security (Keychain) are found when PATH is minimal (e.g. under some MDM runners).
export PATH="/usr/bin:/opt/homebrew/opt/openssl/bin:/opt/homebrew/bin:/usr/local/opt/openssl/bin:/usr/local/bin:$PATH"

# Must run as root: script writes under /Users/* and (when using --cert-name) reads system keychains.
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root. Use: sudo $0 [options]" >&2
    exit 1
fi

do_npm() { [ "$PACKAGE" = "npm" ] || [ "$PACKAGE" = "all" ]; }
do_pip() { [ "$PACKAGE" = "pip" ] || [ "$PACKAGE" = "all" ]; }


# --install-dependencies: if openssl is missing, install via Homebrew in this run so admins do not need a second pass.
if [ "$INSTALL_DEPS" -eq 1 ] && ! command -v openssl >/dev/null 2>&1; then
    BREW=""
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$b" ] && BREW="$b" && break
    done
    [ -z "$BREW" ] && command -v brew >/dev/null 2>&1 && BREW="brew"
    if [ -z "$BREW" ]; then
        echo "Error: openssl is missing and Homebrew is not installed. Install Homebrew (e.g. from https://brew.sh) or install openssl manually." >&2
        exit 1
    fi
    echo "Installing openssl via Homebrew..."
    "$BREW" install openssl || { echo "Error: brew install openssl failed." >&2; exit 1; }
    # Ensure PATH includes the just-installed openssl
    BREW_PREFIX=$("$BREW" --prefix openssl 2>/dev/null) && [ -d "$BREW_PREFIX/bin" ] && export PATH="$BREW_PREFIX/bin:$PATH"
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl is required but not found on PATH." >&2
    echo "Run with --install-dependencies to install openssl via Homebrew." >&2
    exit 1
fi

if [ -z "$USE_CERT" ] && ! command -v security >/dev/null 2>&1; then
    echo "Error: security (macOS Keychain) is required for --cert-name but not found. It is a system tool and cannot be installed; ensure you are on macOS." >&2
    exit 1
fi

echo "--- Extracting certificate and configuring ($PACKAGE) ---"
echo "[Root] Installing cert per user (each user's PEM in their space under --extract-path, owned by that user)."

PEM=""

# Check file exists and is valid PEM (openssl x509). Used for --use-cert and after writing extracted cert.
validate_pem() {
    local path="$1"
    [ -f "$path" ] || return 1
    openssl x509 -in "$path" -noout 2>/dev/null || return 1
    return 0
}

# Get path from first "export VAR=..." in file; strip quotes and expand ~ to expand_home. Used to detect existing NODE_EXTRA_CA_CERTS / REQUESTS_CA_BUNDLE before updating.
get_export_path() {
    local f="$1" var="$2" expand_home="${3:-}"
    local line path
    line=$(grep -E "^export ${var}=" "$f" 2>/dev/null | head -1)
    [ -z "$line" ] && return 0
    path=$(echo "$line" | sed -E "s/^export ${var}=//" | sed -E 's/^["'\'']//;s/["'\'']$//')
    [ -n "$expand_home" ] && [ -z "${path%%~*}" ] && path="${expand_home}${path#\~}"
    echo "$path"
}

# SHA-256 fingerprint of a PEM block; used to dedupe certs when merging bundles.
# Normalize PEM via openssl x509 so same cert with different encoding (line endings, wrapping) produces the same fingerprint.
pem_fingerprint() {
    local pem="$1"
    echo "$pem" | openssl x509 -out /dev/stdout 2>/dev/null | openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/.*=//'
}

# Extract PEM blocks from file (NUL-separated).
read_blocks_from_file() {
    local path="$1"
    [ ! -f "$path" ] && return 1
    awk '/-----BEGIN CERTIFICATE-----/{p=1; b=$0"\n"; next} p{b=b $0 "\n"} /-----END CERTIFICATE-----/{if(p){p=0; printf "%s%c", b, 0}}' "$path" 2>/dev/null
}

# True if bundle file already contains a cert with the same fingerprint (avoid duplicate when merging).
bundle_contains_pem() {
    local bundle_path="$1" our_pem="$2"
    local our_fp fp
    our_fp=$(pem_fingerprint "$our_pem")
    [ -z "$our_fp" ] && return 1
    [ ! -f "$bundle_path" ] && return 1
    while IFS= read -r -d '' block; do
        [ -z "$block" ] && continue
        fp=$(pem_fingerprint "$block")
        [ "$fp" = "$our_fp" ] && return 0
    done < <(read_blocks_from_file "$bundle_path" 2>/dev/null)
    return 1
}

# Merge certs from source_file into target_path (append to target, dedupe by fingerprint, skip certs same as our_pem). Optional $4 = display name for logs (else basename of source_file).
# Split source into one file per PEM block then append from files (avoids passing large PEM through shell variables which can drop content).
merge_certs_into_target() {
    local source_file="$1" target_path="$2" our_pem="$3" display_name="${4:-}"
    local our_fp fp block_dir f appended=0
    [ ! -f "$source_file" ] || [ ! -s "$source_file" ] && return 0
    our_fp=$(pem_fingerprint "$our_pem")
    [ -z "$our_fp" ] && return 0
    block_dir="$SCRIPT_TMP/merge_blocks"
    rm -rf "$block_dir" 2>/dev/null
    mkdir -p "$block_dir"
    awk -v tmp="$block_dir" '
        /-----BEGIN CERTIFICATE-----/{p=1; n++; b=$0"\n"; next}
        p{b=b $0 "\n"}
        /-----END CERTIFICATE-----/{if(p){p=0; f=tmp "/block_" n ".pem"; print b > f; close(f)}}
    ' "$source_file" 2>/dev/null
    echo "   [merge] reading cert blocks from ${display_name:-$source_file} into $(basename "$target_path")"
    for f in "$block_dir"/block_*.pem; do
        [ -f "$f" ] || continue
        fp=$(pem_fingerprint "$(cat "$f")")
        [ -z "$fp" ] && continue
        [ "$fp" = "$our_fp" ] && continue
        bundle_contains_pem "$target_path" "$(cat "$f")" >/dev/null 2>&1 && continue
        cat "$f" >> "$target_path"
        appended=$((appended + 1))
    done
    rm -rf "$block_dir" 2>/dev/null
    [ "$appended" -gt 0 ] && echo "   [merge] ${appended} cert(s) appended from ${display_name:-$(basename "$source_file" 2>/dev/null)}"
}

# Canonical absolute path (resolve dir so ~ and relative match the same file as target_path). Empty if path is invalid.
canonical_path() {
    local d b
    d=$(cd "$(dirname "$1")" 2>/dev/null && pwd) && b=$(basename "$1") && echo "$d/$b"
}

# Requirement: new file = new PEM + all old PEMs (from existing NODE_EXTRA_CA_CERTS/REQUESTS_CA_BUNDLE paths if they exist), no duplicates.
# Writes target_path with new_pem first, then appends certs from each path in old_paths. If target_path is in old_paths, we read target_path first into a temp file so we don't lose its content when overwriting.
# When an old path points to the same file as target_path (e.g. ~/x vs /Users/u/x), we must merge from saved_target, not from the file (which we just overwrote).
write_merged_pem_file() {
    local target_path="$1" new_pem="$2" p saved_target target_canon p_canon
    shift 2
    saved_target=$(mktemp "$SCRIPT_TMP/saved.XXXXXX")
    [ -f "$target_path" ] && [ -s "$target_path" ] && cp "$target_path" "$saved_target"
    echo "$new_pem" > "$target_path"
    target_canon=$(canonical_path "$target_path")
    for p in "$@"; do
        [ -z "$p" ] && continue
        p_canon=$(canonical_path "$p" 2>/dev/null)
        if [ -n "$target_canon" ] && [ -n "$p_canon" ] && [ "$p_canon" = "$target_canon" ]; then
            merge_certs_into_target "$saved_target" "$target_path" "$new_pem" "previous bundle (same path)"
        elif [ -f "$p" ] && [ -s "$p" ]; then
            merge_certs_into_target "$p" "$target_path" "$new_pem" "$(basename "$p")"
        fi
    done
}

# Replace every "export VAR=..." line in the file with the new path (for NODE_EXTRA_CA_CERTS or REQUESTS_CA_BUNDLE). All occurrences are updated so both npm and pip blocks point to the same cert path.
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
    ' "$f" > "$tmp" && mv "$tmp" "$f"
}

if [ -n "$USE_CERT" ]; then
    echo "[1/3] Using existing certificate at $USE_CERT..."
    validate_pem "$USE_CERT" || { echo "[Error] Invalid or missing PEM at: $USE_CERT" >&2; exit 1; }
else
    echo "[1/3] Extracting certificate from keychain (cert-name pattern=$CERT_NAME)..."
    # Reads System.keychain and SystemRootCertificates.keychain; --cert-name is a regex on the cert subject (e.g. "My CA"). Exactly one match required.
    keychains=()
    [ -f "/Library/Keychains/System.keychain" ] && keychains+=( "/Library/Keychains/System.keychain" )
    [ -f "/System/Library/Keychains/SystemRootCertificates.keychain" ] && keychains+=( "/System/Library/Keychains/SystemRootCertificates.keychain" )

    match_count=0
    cert_tmp="$SCRIPT_TMP/cert-extract"
    mkdir -p "$cert_tmp"

    for keychain in "${keychains[@]}"; do
        [ "$match_count" -gt 1 ] && break
        [ "$match_count" -eq 1 ] && break
        security find-certificate -a -p $keychain 2>/dev/null | awk '
            /-----BEGIN CERTIFICATE-----/{p=1; b=$0"\n"}
            p{ b=b $0 "\n" }
            /-----END CERTIFICATE-----/{ if(p){ p=0; print b } }
        ' > "$cert_tmp/all.pem" 2>/dev/null || continue
        [ ! -s "$cert_tmp/all.pem" ] && continue
        # Split into separate files (csplit not always available on macOS; use awk)
        rm -f "$cert_tmp"/cert-*.pem
        awk '/-----BEGIN CERTIFICATE-----/{n++; f="'"$cert_tmp"'/cert-"n".pem"} f{print > f} /-----END CERTIFICATE-----/{close(f); f=""}' "$cert_tmp/all.pem" 2>/dev/null
        for f in "$cert_tmp"/cert-*.pem; do
            [ -f "$f" ] || continue
            subject=$(openssl x509 -noout -subject -in "$f" 2>/dev/null) || continue
            if echo "$subject" | grep -qE "$CERT_NAME"; then
                match_count=$((match_count + 1))
                PEM=$(cat "$f")
                [ "$match_count" -gt 1 ] && break
            fi
        done
    done

    if [ "$match_count" -eq 0 ]; then
        echo "[Error] No certificate in keychain matched pattern: $CERT_NAME" >&2
        exit 1
    fi
    if [ "$match_count" -gt 1 ]; then
        echo "[Error] More than one certificate matched pattern: $CERT_NAME (exactly one required)." >&2
        exit 1
    fi
fi

# Writes or updates NODE_EXTRA_CA_CERTS / REQUESTS_CA_BUNDLE in the user's .zshrc to point to cert_path. Merging of old PEMs into the new file is done in write_merged_pem_file.
add_exports_to_file() {
    local f="$1" cert_path="$2" expand_home P
    [ ! -f "$cert_path" ] && return 0
    expand_home=$(dirname "$f")

    if do_npm; then
        P=$(get_export_path "$f" "NODE_EXTRA_CA_CERTS" "$expand_home")
        if [ -z "$P" ]; then
            echo "" >> "$f"
            echo "export NODE_USE_SYSTEM_CA=1" >> "$f"
            echo "export NODE_EXTRA_CA_CERTS=\"$cert_path\"" >> "$f"
        else
            replace_export_in_file "$f" "NODE_EXTRA_CA_CERTS" "$cert_path"
            grep -q '^export NODE_USE_SYSTEM_CA=' "$f" 2>/dev/null || echo "export NODE_USE_SYSTEM_CA=1" >> "$f"
        fi
    fi

    if do_pip; then
        P=$(get_export_path "$f" "REQUESTS_CA_BUNDLE" "$expand_home")
        if [ -z "$P" ]; then
            echo "" >> "$f"
            echo "export REQUESTS_CA_BUNDLE=\"$cert_path\"" >> "$f"
        else
            replace_export_in_file "$f" "REQUESTS_CA_BUNDLE" "$cert_path"
        fi
    fi
}

# Per-user loop: each user gets their PEM in their space under the path. New file = new PEM + this user's old PEMs (from their .zshrc) only, no cross-user aggregation.
for homedir in /Users/*; do
    [ "$homedir" = "/Users/Shared" ] && continue
    [ ! -d "$homedir" ] && continue

    if [ -n "$USE_CERT" ]; then
        user_cert_path="$USE_CERT"
    else
        # Always under user's home: ~/<path>/package-route.pem (path is EXTRACT_PATH with leading / stripped if present).
        user_cert_path="${homedir}/${EXTRACT_PATH#/}/package-route.pem"
        mkdir -p "$(dirname "$user_cert_path")" 2>/dev/null || true
    fi

    # This user's old paths from their .zshrc only (for merge).
    user_old_paths=()
    if [ -f "$homedir/.zshrc" ]; then
        expand_home="$homedir"
        for _v in NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE; do
            _q=$(get_export_path "$homedir/.zshrc" "$_v" "$expand_home")
            [ -z "$_q" ] || [ ! -f "$_q" ] && continue
            case " ${user_old_paths[*]} " in *" $_q "*) continue ;; esac
            user_old_paths+=("$_q")
        done
    fi

    if [ -z "$USE_CERT" ]; then
        write_merged_pem_file "$user_cert_path" "$PEM" "${user_old_paths[@]}"
        validate_pem "$user_cert_path" || { echo "[Error] Extracted PEM is invalid: $user_cert_path" >&2; exit 1; }
        chmod 644 "$user_cert_path" 2>/dev/null || true
    fi
    owner=$(stat -f '%Su:%Sg' "$homedir" 2>/dev/null) || owner="nobody:staff"
    [ -f "$homedir/.zshrc" ] && add_exports_to_file "$homedir/.zshrc" "$user_cert_path"
    # replace_export_in_file (used inside add_exports_to_file) does mv of a root-owned temp over .zshrc, so we must chown back to the user
    [ -f "$homedir/.zshrc" ] && chown "$owner" "$homedir/.zshrc"
    if [ -z "$USE_CERT" ]; then
        cert_dir="$(dirname "$user_cert_path")"
        chown -R "$owner" "$cert_dir" 2>/dev/null || true
        # Chown parent dirs up to homedir so the user can e.g. rm -rf the path (they own the whole chain).
        _dir="$cert_dir"
        while [ -n "$_dir" ] && [ "$_dir" != "$homedir" ]; do
            chown "$owner" "$_dir" 2>/dev/null || true
            _dir="$(dirname "$_dir")"
        done
    fi
done

if [ -n "$USE_CERT" ]; then
    echo "   Using existing cert at $USE_CERT for all users."
else
    echo "   Certificate exported to each user's cert path (owned by user)."
fi
echo "   + NODE_USE_SYSTEM_CA / NODE_EXTRA_CA_CERTS and/or REQUESTS_CA_BUNDLE added to each user's existing .zshrc."

echo "---------------------------------------------------"
echo "[3/3] COMPLETE!"
echo ""
# Users must open a new terminal (or run source ~/.zshrc) for NODE_EXTRA_CA_CERTS / REQUESTS_CA_BUNDLE to take effect.
echo "Cert and config installed per user. Users must start new terminals to pick up changes."
