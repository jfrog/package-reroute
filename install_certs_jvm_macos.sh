#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Extract a JVM truststore from a Jamf-delivered macOS .pkg and wire it for
# JVM clients (Maven, Gradle, sbt, Apache Ivy).
#
# Single path: expand --use-pkg, copy the JKS payload into
#   /Library/Application Support/JFrog/package-route-jvm/truststore.jks
# then set JAVA_TOOL_OPTIONS in the target user's ~/.zshrc so every new JVM
# startup inherits that trustStore path. KeychainStore is broken per
# JDK-8321045, so there is no OS-trust fallback.
#
# Run:
#   sudo bash install_certs_jvm_macos.sh --use-pkg /path/to/truststore.pkg
#       [--all-users]
#
# Notes:
#   - macOS only.
#   - Must run as root (write into /Library + chown per-user ~/.zshrc).
#   - Requires pkgutil (macOS built-in). The pkg payload must contain a
#     non-empty truststore.jks (or a single *.jks / *.p12 file).
#   - JVM trust only — does not configure npm/Python/HF and does not touch
#     Docker credentials. Pair with install_certs_macos.sh if you need those.
#   - Users need a new terminal (or `source ~/.zshrc`) for the env var to
#     take effect.
#
# Cross-platform siblings (keep CLI shapes and contracts in sync):
#   install_certs_jvm_linux.sh       — local JKS + JAVA_TOOL_OPTIONS in /etc/environment
#   install_certs_jvm_rhel.sh        — RHEL update-ca-trust
#   install_certs_jvm_windows.ps1    — local JKS + HKCU\Environment JAVA_TOOL_OPTIONS
#
# Research / rationale: see the JVM client-onboarding wiki page
#   https://jfrog-int.atlassian.net/wiki/spaces/RTFACT/pages/2440101931/

set -euo pipefail

# Keep this installer self-contained: it is often copied/run as a standalone
# script during onboarding, so avoid requiring sibling files for constants.
JKS_DIR="/Library/Application Support/JFrog/package-route-jvm"
JKS_PATH="${JKS_DIR}/truststore.jks"
JKS_PASSWORD="changeit"

USE_PKG=""
ALL_USERS=0

usage() {
    cat <<EOF
Usage:
  sudo $0 --use-pkg <path.pkg> [--all-users]

Options:
  --use-pkg <path.pkg>   Path to a macOS installer package whose payload
                         contains the JVM truststore (prefer basename
                         truststore.jks; otherwise a single *.jks / *.p12).
                         The JKS is extracted into ${JKS_PATH}, then
                         JAVA_TOOL_OPTIONS is wired to that path. The
                         truststore must be readable by JVMs with password
                         '${JKS_PASSWORD}'.
  --all-users            Iterate /Users/* (UID >= 501, skip Shared) and write
                         the ~/.zshrc export for every account. Default =
                         only SUDO_USER (or the console-user under JAMF).
  -h, --help             Show this help.

Note: unlike the Linux sibling, macOS has only one install path
(per-user ~/.zshrc JAVA_TOOL_OPTIONS). There is no --mode flag because the
KeychainStore truststoreType is broken (JDK-8321045) and no OS-trust
fallback exists.

Examples:
  sudo $0 --use-pkg /Library/Application\\ Support/JFrog/package-route-truststore.pkg
  sudo $0 --use-pkg /tmp/package-route-truststore.pkg --all-users
EOF
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Error: this script must be run as root." >&2
        echo "Use: sudo $0 --use-pkg <path.pkg> [--all-users]" >&2
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --use-pkg)
                USE_PKG="${2:?Error: --use-pkg requires a value}"
                shift 2
                ;;
            --all-users)
                ALL_USERS=1
                shift
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

    if [[ -z "$USE_PKG" ]]; then
        echo "Error: --use-pkg is required." >&2
        usage >&2
        exit 1
    fi

    if [[ ! -f "$USE_PKG" ]]; then
        echo "Error: package file not found: $USE_PKG" >&2
        exit 1
    fi
    if [[ ! -r "$USE_PKG" ]]; then
        echo "Error: package file is not readable: $USE_PKG" >&2
        exit 1
    fi
    if [[ ! -s "$USE_PKG" ]]; then
        echo "Error: package file is empty: $USE_PKG" >&2
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

# Expand a component or product .pkg and copy the truststore payload to JKS_PATH.
extract_truststore_from_pkg() {
    if ! command -v pkgutil >/dev/null 2>&1; then
        echo "Error: pkgutil is required to extract the truststore from a .pkg." >&2
        exit 1
    fi

    echo "  [JKS] Extracting truststore from $USE_PKG"

    # pkgutil --expand-full creates dest-dir; it must not already exist.
    local expand_dir
    expand_dir="$(mktemp -d /tmp/package-route-jvm-pkg.XXXXXX)"
    rmdir "$expand_dir"
    if ! pkgutil --expand-full "$USE_PKG" "$expand_dir" >/dev/null; then
        echo "Error: failed to expand package: $USE_PKG" >&2
        exit 1
    fi

    local named=() matches=() f
    while IFS= read -r -d '' f; do
        [[ -s "$f" ]] || continue
        matches+=("$f")
        if [[ "$(basename "$f")" == "truststore.jks" ]]; then
            named+=("$f")
        fi
    done < <(find "$expand_dir" -type f \( -name '*.jks' -o -name '*.p12' \) -print0 2>/dev/null)

    local source=""
    if [[ "${#named[@]}" -eq 1 ]]; then
        source="${named[0]}"
    elif [[ "${#named[@]}" -gt 1 ]]; then
        rm -rf "$expand_dir"
        echo "Error: package contains multiple truststore.jks files; expected exactly one." >&2
        exit 1
    elif [[ "${#matches[@]}" -eq 1 ]]; then
        source="${matches[0]}"
    elif [[ "${#matches[@]}" -eq 0 ]]; then
        rm -rf "$expand_dir"
        echo "Error: package contains no JKS/PKCS12 truststore (looked for truststore.jks, *.jks, *.p12): $USE_PKG" >&2
        exit 1
    else
        rm -rf "$expand_dir"
        echo "Error: package contains ${#matches[@]} JKS/PKCS12 files and no unique truststore.jks; expected one." >&2
        exit 1
    fi

    mkdir -p "$JKS_DIR"
    cp "$source" "$JKS_PATH"
    rm -rf "$expand_dir"
    chmod 0755 "$JKS_DIR"
    chmod 0644 "$JKS_PATH"
    echo "  [JKS] Installed at $JKS_PATH"
}

jto_value_for_path() {
    local jks_path="$1"
    # The JKS path is under /Library/Application Support/ — the embedded
    # space breaks unquoted JAVA_TOOL_OPTIONS at the JVM tokenizer (which
    # splits on whitespace and only honours `"…"` grouping). Embed literal
    # quotes around the path/password so they reach the JVM after .zshrc is
    # sourced.
    echo "-Djavax.net.ssl.trustStore=\"${jks_path}\" -Djavax.net.ssl.trustStorePassword=\"${JKS_PASSWORD}\""
}

replace_export_in_file() {
    local file="$1" var="$2" value="$3"
    local tmp escaped

    escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"

    tmp="$(mktemp "${file}.XXXXXX")"
    awk -v var="$var" -v val="$escaped" '
        $0 ~ "^export " var "=" { print "export " var "=\"" val "\""; next }
        { print }
    ' "$file" > "$tmp"
    if [[ ! -s "$tmp" && -s "$file" ]]; then
        rm -f "$tmp"
        echo "Error: awk produced empty output; refusing to overwrite $file" >&2
        exit 1
    fi
    # Symlink-safe: write through the target rather than mv'ing over it.
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

ensure_export_in_file() {
    local file="$1" var="$2" value="$3"

    touch "$file"
    if grep -qE "^export ${var}=" "$file" 2>/dev/null; then
        replace_export_in_file "$file" "$var" "$value"
    else
        local escaped="${value//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        printf 'export %s="%s"\n' "$var" "$escaped" >> "$file"
    fi
}

update_zshrc_for_user() {
    local target_user="$1" user_home="$2"
    local zshrc="${user_home}/.zshrc"
    local jto_value

    jto_value="$(jto_value_for_path "$JKS_PATH")"

    echo "  [zsh] Updating $zshrc"

    if [[ -d "$zshrc" ]]; then
        echo "Error: $zshrc is a directory, not a file." >&2
        exit 1
    fi

    ensure_export_in_file "$zshrc" "JAVA_TOOL_OPTIONS" "$jto_value"

    local chown_err
    if ! chown_err="$(chown "$target_user" "$zshrc" 2>&1)"; then
        echo "Error: chown $target_user $zshrc failed: $chown_err" >&2
        exit 1
    fi

    echo "  [zsh] OK"
}

# Determine the single non-root target user when --all-users is NOT set.
# Fallback order matches install_certs_macos.sh:314-328: SUDO_USER first,
# then /dev/console owner (the JAMF / GUI-elevated case), then `logname` as a
# last resort. `loginwindow` is the special user that owns /dev/console at
# the login screen — must be filtered or we'd install into a non-account.
get_single_target_user() {
    local candidate

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        candidate="$SUDO_USER"
    else
        candidate="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
        if [[ -z "$candidate" || "$candidate" == "root" || "$candidate" == "loginwindow" ]]; then
            candidate="$(logname 2>/dev/null || true)"
        fi
    fi

    if [[ -z "$candidate" || "$candidate" == "root" || "$candidate" == "loginwindow" ]]; then
        return 0
    fi

    # Reject users that don't exist on the box.
    if ! id -u "$candidate" >/dev/null 2>&1; then
        return 0
    fi

    echo "$candidate"
}

get_user_home() {
    local user="$1"
    # `dscl . -read /Users/$user NFSHomeDirectory` is the macOS canonical
    # source of truth (passwd is a synthetic view). Fall back to dscacheutil
    # if dscl is unavailable (sandboxed CI images, OpenDirectory hiccups).
    local home
    home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    if [[ -z "$home" ]] && command -v dscacheutil >/dev/null 2>&1; then
        home="$(dscacheutil -q user -a name "$user" 2>/dev/null | awk '/^dir:/ {print $2}')"
    fi
    echo "$home"
}

install_for_user() {
    local target_user="$1" user_home="$2"

    echo "=== User: $target_user (home: $user_home) ==="
    update_zshrc_for_user "$target_user" "$user_home"

    echo "  Truststore: $JKS_PATH"
    echo "  Shell rc:   ${user_home}/.zshrc"
}

# Outputs `username\thome_dir` lines for every /Users/* directory that
# represents a real account with UID >= 501.
#
# Stricter filter than install_certs_macos.sh:256-261 (which skips only
# /Users/Shared and UID < 501): also skips .localized, and rejects
# directories whose owning user no longer exists in dscl (stale home dirs
# left behind by deleted accounts would otherwise crash chown).
iter_all_users() {
    local dir base uid
    for dir in /Users/*; do
        [[ -d "$dir" ]] || continue
        base="$(basename "$dir")"
        [[ "$base" == "Shared" || "$base" == ".localized" ]] && continue
        uid="$(stat -f '%u' "$dir" 2>/dev/null || true)"
        [[ -n "$uid" && "$uid" -ge 501 ]] || continue
        # Reject stale home dirs whose owning user no longer exists in dscl.
        id -u "$base" >/dev/null 2>&1 || continue
        printf '%s\t%s\n' "$base" "$dir"
    done
}

print_caveats() {
    cat <<EOF

Notes:
  - Open a new terminal (or run 'source ~/.zshrc') so JAVA_TOOL_OPTIONS is set.
  - Restart IntelliJ / your IDE if it was already running before the install.
  - Run 'gradle --stop' to refresh the Gradle Daemon if one was already running.
  - The 'Picked up JAVA_TOOL_OPTIONS:' banner on stderr is expected.
EOF
}

main() {
    require_root
    parse_args "$@"
    check_os

    echo
    extract_truststore_from_pkg

    if [[ "$ALL_USERS" -eq 1 ]]; then
        local iter_count=0 user home
        while IFS=$'\t' read -r user home; do
            echo
            install_for_user "$user" "$home"
            iter_count=$((iter_count + 1))
        done < <(iter_all_users)

        if [[ "$iter_count" -eq 0 ]]; then
            echo "Error: --all-users found no eligible accounts under /Users/* (UID >= 501)." >&2
            exit 1
        fi

        echo
        echo "Installed for $iter_count user(s)."
        print_caveats
        return 0
    fi

    local target_user user_home
    target_user="$(get_single_target_user)"
    if [[ -z "$target_user" ]]; then
        echo "Error: could not determine non-root target user." >&2
        echo "       Set SUDO_USER or invoke via sudo from the developer account," >&2
        echo "       or pass --all-users to iterate every eligible account." >&2
        exit 1
    fi
    user_home="$(get_user_home "$target_user")"
    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        echo "Error: home directory not found for $target_user." >&2
        exit 1
    fi

    echo
    install_for_user "$target_user" "$user_home"
    print_caveats
}

main "$@"
