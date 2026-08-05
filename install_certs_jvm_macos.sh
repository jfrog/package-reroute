#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Wire an IT-published JVM truststore on macOS for JVM clients (Maven, Gradle,
# sbt, Apache Ivy).
#
# Single path: take a supplied JKS truststore path and set JAVA_TOOL_OPTIONS
# in the target user's ~/.zshrc so every new JVM startup inherits that
# trustStore path. The supplied path is the runtime location — this script
# does not copy the file (IT publishes the ready JKS to a durable path of
# its choosing). KeychainStore is broken per JDK-8321045, so there is no
# OS-trust fallback.
#
# Run:
#   sudo bash install_certs_jvm_macos.sh --use-truststore /path/to/truststore.jks
#       [--all-users]
#
# Notes:
#   - macOS only.
#   - Must run as root (so per-user ~/.zshrc can be chown'd to the target user).
#   - JVM trust only — does not configure npm/Python/HF and does not touch
#     Docker credentials. Pair with install_certs_macos.sh if you need those.
#   - Users need a new terminal (or `source ~/.zshrc`) for the env var to
#     take effect.
#
# Cross-platform siblings (keep CLI shapes and contracts in sync):
#   install_certs_jvm_linux.sh       — JAVA_TOOL_OPTIONS in /etc/environment
#   install_certs_jvm_rhel.sh        — RHEL update-ca-trust
#   install_certs_jvm_windows.ps1    — HKCU\Environment JAVA_TOOL_OPTIONS
#
# Research / rationale: see the JVM client-onboarding wiki page
#   https://jfrog-int.atlassian.net/wiki/spaces/RTFACT/pages/2440101931/

set -euo pipefail

# Keep this installer self-contained: it is often copied/run as a standalone
# script during onboarding, so avoid requiring sibling files for constants.
JKS_PASSWORD="changeit"

USE_TRUSTSTORE=""
ALL_USERS=0

usage() {
    cat <<EOF
Usage:
  sudo $0 --use-truststore <path> [--all-users]

Options:
  --use-truststore <path>
                         Absolute or relative path to the IT-published JVM
                         truststore (JKS/PKCS12-compatible). JAVA_TOOL_OPTIONS
                         will point at this path (resolved to absolute). The
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
  sudo $0 --use-truststore /Library/Managed/package-route-truststore.jks
  sudo $0 --use-truststore /Library/Managed/package-route-truststore.jks --all-users
EOF
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Error: this script must be run as root." >&2
        echo "Use: sudo $0 --use-truststore <path> [--all-users]" >&2
        exit 1
    fi
}

# Resolve to an absolute path so relative --use-truststore values do not break
# after the shell's cwd changes.
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
            --use-truststore)
                USE_TRUSTSTORE="${2:?Error: --use-truststore requires a value}"
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

    if [[ -z "$USE_TRUSTSTORE" ]]; then
        echo "Error: --use-truststore is required." >&2
        usage >&2
        exit 1
    fi

    if [[ ! -f "$USE_TRUSTSTORE" ]]; then
        echo "Error: truststore file not found: $USE_TRUSTSTORE" >&2
        exit 1
    fi

    if [[ ! -r "$USE_TRUSTSTORE" ]]; then
        echo "Error: truststore file is not readable: $USE_TRUSTSTORE" >&2
        exit 1
    fi

    if [[ ! -s "$USE_TRUSTSTORE" ]]; then
        echo "Error: truststore file is empty: $USE_TRUSTSTORE" >&2
        exit 1
    fi

    USE_TRUSTSTORE="$(canonicalize_path "$USE_TRUSTSTORE")"
}

check_os() {
    local os
    os="$(uname -s)"
    if [[ "$os" != "Darwin" ]]; then
        echo "Error: this script supports macOS only (detected: $os)." >&2
        exit 1
    fi
}

jto_value_for_path() {
    local jks_path="$1"
    # Paths may contain spaces (e.g. under Application Support). The JVM
    # tokenizer splits JAVA_TOOL_OPTIONS on whitespace and only honours
    # `"…"` grouping. Embed literal quotes around the path/password so they
    # reach the JVM after .zshrc is sourced.
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

    jto_value="$(jto_value_for_path "$USE_TRUSTSTORE")"

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

    echo "  Truststore: $USE_TRUSTSTORE"
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
