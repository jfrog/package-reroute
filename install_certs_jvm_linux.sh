#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Download a JVM truststore and wire it on Linux for JVM clients (Maven,
# Gradle, sbt, Apache Ivy).
#
# Single path: download a JKS from --truststore-url into
#   /etc/ssl/package-route-jvm/truststore.jks
# then set JAVA_TOOL_OPTIONS in /etc/environment so every new JVM startup
# inherits the trustStore path.
#
# Run:
#   sudo bash install_certs_jvm_linux.sh --truststore-url https://example/truststore.jks
#
# Notes:
#   - Linux only.
#   - Must run as root.
#   - Requires curl.
#   - JVM trust only — does not configure npm/Python/HF and does not touch
#     Docker credentials. Pair with install_certs_debian_ubuntu.sh if needed.
#   - GUI-launched IDEs need a logoff/login to pick up /etc/environment.
#   - RHEL-family hosts that intentionally use Red Hat OpenJDK system trust
#     should use install_certs_jvm_rhel.sh instead.

set -euo pipefail

# Keep this installer self-contained: it is often copied/run as a standalone
# script during onboarding, so avoid requiring sibling files for constants.
JKS_DIR="/etc/ssl/package-route-jvm"
JKS_PATH="${JKS_DIR}/truststore.jks"
JKS_PASSWORD="changeit"
ENVIRONMENT_FILE="/etc/environment"

TRUSTSTORE_URL=""
RC_UPDATED=0

usage() {
    cat <<EOF
Usage:
  sudo $0 --truststore-url <url>

Options:
  --truststore-url <url>  Download the JVM truststore (JKS/PKCS12-compatible)
                          from this URL into ${JKS_PATH}, then wire
                          JAVA_TOOL_OPTIONS to that path. The truststore must
                          be readable by JVMs with password '${JKS_PASSWORD}'.
  -h, --help              Show this help.

Examples:
  sudo $0 --truststore-url https://artifacts.example.com/package-route-truststore.jks
EOF
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Error: this script must be run as root." >&2
        echo "Use: sudo $0 --truststore-url <url>" >&2
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --truststore-url)
                TRUSTSTORE_URL="${2:?Error: --truststore-url requires a value}"
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

    if [[ -z "$TRUSTSTORE_URL" ]]; then
        echo "Error: --truststore-url is required." >&2
        usage >&2
        exit 1
    fi
}

check_os() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        echo "Error: this script supports Linux only." >&2
        exit 1
    fi
}

download_truststore() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is required to download the truststore." >&2
        exit 1
    fi

    echo "[1/4] Downloading truststore from $TRUSTSTORE_URL..."
    mkdir -p "$JKS_DIR"
    chmod 0755 "$JKS_DIR"

    local tmp
    tmp="$(mktemp -p "$JKS_DIR")"
    if ! curl -fsSL --connect-timeout 30 --max-time 120 -o "$tmp" "$TRUSTSTORE_URL"; then
        rm -f "$tmp"
        echo "Error: failed to download truststore from $TRUSTSTORE_URL" >&2
        exit 1
    fi
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        echo "Error: downloaded truststore is empty: $TRUSTSTORE_URL" >&2
        exit 1
    fi

    mv "$tmp" "$JKS_PATH"
    chmod 0644 "$JKS_PATH"
}

replace_export_in_file() {
    local file="$1" var="$2" value="$3"
    local tmp escaped

    escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"

    tmp=$(mktemp -p "$(dirname "$file")")
    awk -v var="$var" -v val="$escaped" '
        $0 ~ "^export " var "=" { print "export " var "=\"" val "\""; next }
        { print }
    ' "$file" > "$tmp"
    if [[ ! -s "$tmp" && -s "$file" ]]; then
        rm -f "$tmp"
        echo "Error: awk produced empty output; refusing to overwrite $file" >&2
        exit 1
    fi
    mv "$tmp" "$file"
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

ensure_kv_in_environment_file() {
    local key="$1" value="$2"
    local tmp escaped

    touch "$ENVIRONMENT_FILE"

    escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"

    if grep -qE "^${key}=" "$ENVIRONMENT_FILE" 2>/dev/null; then
        tmp=$(mktemp -p "$(dirname "$ENVIRONMENT_FILE")")
        awk -v k="$key" -v v="$escaped" '
            $0 ~ "^" k "=" { print k "=\"" v "\""; next }
            { print }
        ' "$ENVIRONMENT_FILE" > "$tmp"
        if [[ ! -s "$tmp" && -s "$ENVIRONMENT_FILE" ]]; then
            rm -f "$tmp"
            echo "Error: awk produced empty output; refusing to overwrite $ENVIRONMENT_FILE" >&2
            exit 1
        fi
        mv "$tmp" "$ENVIRONMENT_FILE"
    else
        printf '%s="%s"\n' "$key" "$escaped" >> "$ENVIRONMENT_FILE"
    fi

    chmod 0644 "$ENVIRONMENT_FILE"
}

get_target_user() {
    local candidate

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        candidate="$SUDO_USER"
    else
        candidate="$(logname 2>/dev/null || true)"
        if [[ -z "$candidate" || "$candidate" == "root" ]]; then
            if command -v loginctl >/dev/null 2>&1; then
                candidate="$(loginctl list-sessions --no-legend 2>/dev/null | awk '
                    $2 >= 1000 && $3 != "root" && $4 == "seat0" { print $3; found=1; exit }
                    $2 >= 1000 && $3 != "root" && !fallback { fallback=$3 }
                    END { if (!found && fallback) print fallback }
                ')"
            fi
        fi
    fi

    if [[ -z "$candidate" || "$candidate" == "root" ]]; then
        return 0
    fi
    if ! getent passwd "$candidate" >/dev/null 2>&1; then
        return 0
    fi

    echo "$candidate"
}

get_user_home() {
    local user="$1"
    getent passwd "$user" | cut -d: -f6
}

get_user_shell() {
    local user="$1"
    getent passwd "$user" | cut -d: -f7
}

update_user_shell_rc() {
    local jto_value="$1"
    local target_user user_home user_shell rc_file chown_err

    target_user="$(get_target_user)"
    if [[ -z "$target_user" || "$target_user" == "root" ]]; then
        echo "      [warn] Per-user rc not updated: could not determine non-root target user." >&2
        echo "             /etc/environment is written and will reach new login sessions." >&2
        return 0
    fi

    user_home="$(get_user_home "$target_user")"
    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        echo "      [warn] Per-user rc not updated: home not found for $target_user." >&2
        return 0
    fi

    user_shell="$(get_user_shell "$target_user")"
    case "$user_shell" in
        */zsh) rc_file="$user_home/.zshrc" ;;
        *)     rc_file="$user_home/.bashrc" ;;
    esac

    touch "$rc_file"
    ensure_export_in_file "$rc_file" "JAVA_TOOL_OPTIONS" "$jto_value"
    if ! chown_err="$(chown "$target_user":"$target_user" "$rc_file" 2>&1)"; then
        echo "      [warn] chown failed on $rc_file: $chown_err" >&2
    fi

    echo "      Updated $rc_file"
    RC_UPDATED=1
}

main() {
    require_root
    parse_args "$@"
    check_os

    download_truststore

    local jto_value="-Djavax.net.ssl.trustStore=\"${JKS_PATH}\" -Djavax.net.ssl.trustStorePassword=\"${JKS_PASSWORD}\""

    echo "[2/4] Writing JAVA_TOOL_OPTIONS to $ENVIRONMENT_FILE..."
    ensure_kv_in_environment_file "JAVA_TOOL_OPTIONS" "$jto_value"

    echo "[3/4] Updating target user's shell rc file..."
    update_user_shell_rc "$jto_value"

    echo "[4/4] Done."
    echo
    echo "Truststore:"
    echo "  $JKS_PATH"
    echo "JAVA_TOOL_OPTIONS:"
    echo "  $jto_value"
    echo
    echo "Notes:"
    echo "  - Log out and log back in for GDM/KDM-launched IDEs to pick up JAVA_TOOL_OPTIONS."
    echo "  - Run 'gradle --stop' to refresh the Gradle Daemon if one was already running."
    echo "  - The 'Picked up JAVA_TOOL_OPTIONS:' banner on stderr is expected."

    if [[ "$RC_UPDATED" -eq 0 ]]; then
        echo
        echo "WARNING: per-user shell rc was NOT updated; existing shells of the developer user"
        echo "         will not see JAVA_TOOL_OPTIONS until they log out and back in (or source"
        echo "         /etc/environment manually). The system-wide change in $ENVIRONMENT_FILE"
        echo "         takes effect on the next fresh login." >&2
    fi
}

main "$@"
