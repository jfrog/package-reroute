#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Install a custom CA certificate on Debian/Ubuntu and configure package-manager
# related environment variables for redirected package traffic.
#
# Run:
#   sudo bash install_certs_debian_ubuntu.sh --use-cert /path/to/cert.pem [--package npm|pip|all]
#
# Examples:
#   sudo bash install_certs_debian_ubuntu.sh --use-cert /tmp/ZscalerRoot0.pem
#   sudo bash install_certs_debian_ubuntu.sh --use-cert /tmp/ZscalerRoot0.pem --package npm
#   sudo bash install_certs_debian_ubuntu.sh --use-cert /tmp/ZscalerRoot0.pem --package pip
#   sudo bash install_certs_debian_ubuntu.sh --use-cert /tmp/ZscalerRoot0.pem --cert-name zscaler-root
#
# What it does:
#   1. Validates the provided PEM/CRT certificate
#   2. Installs it into Debian/Ubuntu system trust store
#   3. Runs update-ca-certificates
#   4. Writes a managed file under /etc/profile.d
#   5. Updates the invoking user's shell rc file (~/.zshrc or ~/.bashrc)
#
# Notes:
#   - Debian/Ubuntu only
#   - Must run as root
#   - On Debian/Ubuntu, the system CA bundle becomes the combined bundle once the
#     custom CA is installed via update-ca-certificates
#   - New terminals should pick up the env vars automatically

set -euo pipefail

PACKAGE="all"
USE_CERT=""
CERT_BASENAME="package-route-custom-ca"

PROFILED_FILE="/etc/profile.d/package-route-certs.sh"
SYSTEM_CERT_DIR="/usr/local/share/ca-certificates"
SYSTEM_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"

usage() {
    cat <<EOF
Usage:
  sudo $0 --use-cert <path> [--package npm|pip|all] [--cert-name <name>]

Options:
  --use-cert <path>       Path to an existing PEM/CRT certificate file
  --package npm|pip|all   Configure npm, pip, or both (default: all)
  --cert-name <name>      Base name for installed cert (default: ${CERT_BASENAME})
  -h, --help              Show this help

Examples:
  sudo $0 --use-cert /tmp/ZscalerRoot0.pem
  sudo $0 --use-cert /tmp/ZscalerRoot0.pem --package npm
  sudo $0 --use-cert /tmp/ZscalerRoot0.pem --package pip
  sudo $0 --use-cert /tmp/ZscalerRoot0.pem --cert-name zscaler-root
EOF
}

do_npm() { [[ "$PACKAGE" == "npm" || "$PACKAGE" == "all" ]]; }
do_pip() { [[ "$PACKAGE" == "pip" || "$PACKAGE" == "all" ]]; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Error: this script must be run as root." >&2
        echo "Use: sudo $0 --use-cert <path> [--package npm|pip|all]" >&2
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --package)
                PACKAGE="${2:?Error: --package requires a value}"
                shift 2
                ;;
            --use-cert)
                USE_CERT="${2:?Error: --use-cert requires a value}"
                shift 2
                ;;
            --cert-name)
                CERT_BASENAME="${2:?Error: --cert-name requires a value}"
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

    case "$PACKAGE" in
        npm|pip|all) ;;
        *)
            echo "Error: --package must be npm, pip, or all (got: $PACKAGE)." >&2
            exit 1
            ;;
    esac

    if [[ -z "$USE_CERT" ]]; then
        echo "Error: --use-cert is required." >&2
        usage >&2
        exit 1
    fi

    if [[ ! -f "$USE_CERT" ]]; then
        echo "Error: certificate file not found: $USE_CERT" >&2
        exit 1
    fi

    if [[ -z "$CERT_BASENAME" ]]; then
        echo "Error: --cert-name cannot be empty." >&2
        exit 1
    fi
}

check_os() {
    if [[ ! -r /etc/os-release ]]; then
        echo "Error: cannot determine OS." >&2
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]] && [[ "${ID_LIKE:-}" != *debian* ]]; then
        echo "Error: this script supports Debian/Ubuntu only." >&2
        echo "Detected ID=${ID:-unknown}, ID_LIKE=${ID_LIKE:-unknown}" >&2
        exit 1
    fi
}

check_dependencies() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo "Error: openssl is required but not found." >&2
        exit 1
    fi

    if ! command -v update-ca-certificates >/dev/null 2>&1; then
        echo "Error: update-ca-certificates is required but not found." >&2
        exit 1
    fi
}

validate_pem() {
    local path="$1"

    if ! openssl x509 -in "$path" -noout >/dev/null 2>&1; then
        echo "Error: invalid PEM/CRT certificate file: $path" >&2
        exit 1
    fi
}

install_system_cert() {
    local system_cert_path="$1"

    echo "[1/4] Installing certificate into system trust store..."

    mkdir -p "$SYSTEM_CERT_DIR"
    cp "$USE_CERT" "$system_cert_path"
    chmod 0644 "$system_cert_path"

    update-ca-certificates

    if [[ ! -f "$SYSTEM_CA_BUNDLE" ]]; then
        echo "Error: expected CA bundle not found: $SYSTEM_CA_BUNDLE" >&2
        exit 1
    fi

    echo "      Installed custom CA at: $system_cert_path"
    echo "      Combined system CA bundle: $SYSTEM_CA_BUNDLE"
}

write_profiled() {
    echo "[2/4] Writing managed environment file to $PROFILED_FILE..."

    {
        echo "# Managed by install_certs_debian_ubuntu.sh"
        echo "# Package manager CA configuration for redirected package traffic"
        echo "# On Debian/Ubuntu, once the custom CA is installed via"
        echo "# update-ca-certificates, the system CA bundle is already the"
        echo "# combined bundle (public roots + corporate CA)."
        echo

        if do_npm; then
            echo "export NODE_USE_SYSTEM_CA=1"
            echo "export NODE_EXTRA_CA_CERTS=\"$SYSTEM_CA_BUNDLE\""
            echo
        fi

        if do_pip; then
            echo "export REQUESTS_CA_BUNDLE=\"$SYSTEM_CA_BUNDLE\""
            echo "export SSL_CERT_FILE=\"$SYSTEM_CA_BUNDLE\""
            echo "export UV_NATIVE_TLS=true"
            echo "export UV_SYSTEM_CERTS=true"
            echo "export CARGO_HTTP_CAINFO=\"$SYSTEM_CA_BUNDLE\""
            echo "export CURL_CA_BUNDLE=\"$SYSTEM_CA_BUNDLE\""
            echo
        fi
    } > "$PROFILED_FILE"

    chmod 0644 "$PROFILED_FILE"
}

replace_export_in_file() {
    local file="$1"
    local var="$2"
    local value="$3"
    local tmp escaped

    escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"

    tmp="$(mktemp)"
    awk -v var="$var" -v val="$escaped" '
        $0 ~ "^export " var "=" {
            print "export " var "=\"" val "\""
            next
        }
        { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

ensure_export_in_file() {
    local file="$1"
    local var="$2"
    local value="$3"

    touch "$file"

    if grep -qE "^export ${var}=" "$file" 2>/dev/null; then
        replace_export_in_file "$file" "$var" "$value"
    else
        printf 'export %s="%s"\n' "$var" "$value" >> "$file"
    fi
}

get_target_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        echo "$SUDO_USER"
    else
        logname 2>/dev/null || true
    fi
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
    local target_user user_home user_shell rc_file

    target_user="$(get_target_user)"

    if [[ -z "$target_user" || "$target_user" == "root" ]]; then
        echo "[3/4] Skipping user shell rc update: could not determine non-root invoking user."
        return 0
    fi

    user_home="$(get_user_home "$target_user")"
    user_shell="$(get_user_shell "$target_user")"

    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        echo "[3/4] Skipping user shell rc update: could not determine home for user $target_user."
        return 0
    fi

    case "$user_shell" in
        */zsh) rc_file="$user_home/.zshrc" ;;
        *)     rc_file="$user_home/.bashrc" ;;
    esac

    echo "[3/4] Updating user shell rc file: $rc_file"

    touch "$rc_file"

    if do_npm; then
        ensure_export_in_file "$rc_file" "NODE_USE_SYSTEM_CA" "1"
        ensure_export_in_file "$rc_file" "NODE_EXTRA_CA_CERTS" "$SYSTEM_CA_BUNDLE"
    fi

    if do_pip; then
        ensure_export_in_file "$rc_file" "REQUESTS_CA_BUNDLE" "$SYSTEM_CA_BUNDLE"
        ensure_export_in_file "$rc_file" "SSL_CERT_FILE" "$SYSTEM_CA_BUNDLE"
        ensure_export_in_file "$rc_file" "UV_NATIVE_TLS" "true"
        ensure_export_in_file "$rc_file" "UV_SYSTEM_CERTS" "true"
        ensure_export_in_file "$rc_file" "CARGO_HTTP_CAINFO" "$SYSTEM_CA_BUNDLE"
        ensure_export_in_file "$rc_file" "CURL_CA_BUNDLE" "$SYSTEM_CA_BUNDLE"
    fi

    chown "$target_user":"$target_user" "$rc_file" 2>/dev/null || true
}

print_done() {
    local system_cert_path="$1"
    local target_user rc_hint

    target_user="$(get_target_user)"
    rc_hint="new terminal"

    if [[ -n "$target_user" && "$target_user" != "root" ]]; then
        rc_hint="new terminal for $target_user"
    fi

    echo "[4/4] COMPLETE"
    echo
    echo "Installed certificate:"
    echo "  $system_cert_path"
    echo
    echo "Combined system CA bundle:"
    echo "  $SYSTEM_CA_BUNDLE"
    echo

    if do_npm; then
        echo "npm/node environment:"
        echo "  NODE_USE_SYSTEM_CA=1"
        echo "  NODE_EXTRA_CA_CERTS=$SYSTEM_CA_BUNDLE"
        echo
    fi

    if do_pip; then
        echo "python/tooling environment:"
        echo "  REQUESTS_CA_BUNDLE=$SYSTEM_CA_BUNDLE"
        echo "  SSL_CERT_FILE=$SYSTEM_CA_BUNDLE"
        echo "  UV_NATIVE_TLS=true"
        echo "  UV_SYSTEM_CERTS=true"
        echo "  CARGO_HTTP_CAINFO=$SYSTEM_CA_BUNDLE"
        echo "  CURL_CA_BUNDLE=$SYSTEM_CA_BUNDLE"
        echo
    fi

    echo "Configuration written to:"
    echo "  $PROFILED_FILE"
    echo "  invoking user's shell rc file"
    echo
    echo "Open a $rc_hint and validate:"
    if do_npm; then
        echo "  env | grep -E 'NODE_USE_SYSTEM_CA|NODE_EXTRA_CA_CERTS'"
        echo "  npm i axios"
    fi
    if do_pip; then
        echo "  env | grep -E 'REQUESTS_CA_BUNDLE|SSL_CERT_FILE|UV_NATIVE_TLS|UV_SYSTEM_CERTS|CARGO_HTTP_CAINFO|CURL_CA_BUNDLE'"
        echo "  python3 -m venv .venv"
        echo "  source .venv/bin/activate"
        echo "  pip install requests"
    fi
}

main() {
    local system_cert_path

    require_root
    parse_args "$@"
    check_os
    check_dependencies
    validate_pem "$USE_CERT"

    system_cert_path="${SYSTEM_CERT_DIR}/${CERT_BASENAME}.crt"

    install_system_cert "$system_cert_path"
    write_profiled
    update_user_shell_rc
    print_done "$system_cert_path"
}

main "$@"