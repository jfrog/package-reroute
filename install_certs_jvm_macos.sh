#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Wire a Jamf-installed JVM truststore for Maven, Gradle, sbt, and Apache Ivy.
#
# Jamf installs the truststore .pkg so the JKS already exists at
#   /Library/Application Support/JFrog/package-route-jvm/truststore.jks
# This script only writes JAVA_TOOL_OPTIONS in the target user's ~/.zshrc so
# every new JVM startup inherits that trustStore path. KeychainStore is
# broken per JDK-8321045, so there is no OS-trust fallback.
#
# Run:
#   sudo bash install_certs_jvm_macos.sh [--all-users]
#
# Jamf policy: Packages payload first, then this script with no parameters.
# Jamf always prepends $1=/ $2=computer $3=user and blank params 4-11 —
# those are ignored.
#
# Notes:
#   - macOS only.
#   - Must run as root (chown per-user ~/.zshrc).
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

ALL_USERS=0

usage() {
    cat <<EOF
Usage:
  sudo $0 [--all-users]

Jamf must install the truststore package first so
  ${JKS_PATH}
exists (readable by JVMs with password '${JKS_PASSWORD}'). This script only
writes JAVA_TOOL_OPTIONS into ~/.zshrc.

Options:
  --all-users            Iterate /Users/* (UID >= 501, skip Shared) and write
                         the ~/.zshrc export for every account. Default =
                         only SUDO_USER (or the console-user under JAMF).
  -h, --help             Show this help.

Note: unlike the Linux sibling, macOS has only one install path
(per-user ~/.zshrc JAVA_TOOL_OPTIONS). There is no --mode flag because the
KeychainStore truststoreType is broken (JDK-8321045) and no OS-trust
fallback exists.

Examples:
  sudo $0
  sudo $0 --all-users
EOF
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Error: this script must be run as root." >&2
        echo "Use: sudo $0 [--all-users]" >&2
        exit 1
    fi
}

parse_args() {
    # Jamf policy scripts always receive:
    #   $1 = target volume mount point (almost always /)
    #   $2 = computer name
    #   $3 = currently logged-in user (may be empty)
    # Custom parameters start at $4. Drop the Jamf prefix so a bare "/" is
    # not treated as an unknown option (that is what failed Customer0-jfproxy-mvn).
    if [[ "${1:-}" == "/" ]]; then
        shift || true
        [[ $# -gt 0 ]] && shift || true
        [[ $# -gt 0 ]] && shift || true
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            "")
                # Jamf passes script parameters 4-11 as empty strings whenever
                # the policy leaves them blank.
                shift
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
    # The JKS path is under /Library/Application Support/ — the embedded
    # space breaks unquoted JAVA_TOOL_OPTIONS at the JVM tokenizer (which
    # splits on whitespace and only honours `"…"` grouping). Embed literal
    # double quotes around the path/password so they reach the JVM after
    # .zshrc is sourced. The export itself is wrapped in single quotes so
    # zsh does not treat those inner " as string terminators
    # (export: not valid in this context: Support/JFrog/...).
    echo "-Djavax.net.ssl.trustStore=\"${jks_path}\" -Djavax.net.ssl.trustStorePassword=\"${JKS_PASSWORD}\""
}

replace_export_in_file() {
    local file="$1" var="$2" value="$3"
    local tmp

    tmp="$(mktemp "${file}.XXXXXX")"
    # Outer single quotes so zsh does not close the string at the inner
    # trustStore="…". awk -v treats \" as an escape, so pass the value
    # through ENVIRON instead of -v.
    JTO_EXPORT_VAL="$value" awk -v var="$var" -v q="'" '
        BEGIN { val = ENVIRON["JTO_EXPORT_VAL"] }
        $0 ~ "^export " var "=" { print "export " var "=" q val q; next }
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
        printf "export %s='%s'\n" "$var" "$value" >> "$file"
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

    if [[ ! -s "$JKS_PATH" ]]; then
        echo "Error: truststore not found at:" >&2
        echo "       $JKS_PATH" >&2
        echo "       Install the Jamf truststore package first, then re-run this script." >&2
        exit 1
    fi

    echo
    echo "  [JKS] Using already-installed truststore at $JKS_PATH"

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
