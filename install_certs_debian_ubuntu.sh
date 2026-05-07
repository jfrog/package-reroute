#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Install a custom CA certificate on Debian/Ubuntu and configure npm and/or Python
# via environment variables.
#
# Run:
#   sudo bash install_certs_debian_ubuntu.sh --use-cert /path/to/cert.pem [--package npm|python|huggingface|all]
#
# Examples:
#   sudo bash install_certs_debian_ubuntu.sh --use-cert /tmp/ZscalerRoot0.pem
#   sudo bash install_certs_debian_ubuntu.sh --use-cert /tmp/ZscalerRoot0.pem --package npm
#   sudo bash install_certs_debian_ubuntu.sh --use-cert /tmp/ZscalerRoot0.pem --package python
#   sudo bash install_certs_debian_ubuntu.sh --use-cert /tmp/ZscalerRoot0.pem --package huggingface
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
#   - npm uses the single installed custom cert
#   - Python TLS: REQUESTS_CA_BUNDLE, SSL_CERT_FILE (python / huggingface / all)
#   - Hugging Face Hub: HF_HUB_* (huggingface or all)
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
  sudo $0 --use-cert <path> [--package npm|python|huggingface|all] [--cert-name <name>]

Options:
  --use-cert <path>       Path to an existing PEM/CRT certificate file
  --package npm|python|huggingface|all   npm, python TLS, python+huggingface, or all (default: all)
  --cert-name <name>      Base name for installed cert (default: ${CERT_BASENAME})
  -h, --help              Show this help

Examples:
  sudo $0 --use-cert /tmp/ZscalerRoot0.pem
  sudo $0 --use-cert /tmp/ZscalerRoot0.pem --package npm
  sudo $0 --use-cert /tmp/ZscalerRoot0.pem --package python
  sudo $0 --use-cert /tmp/ZscalerRoot0.pem --package huggingface
  sudo $0 --use-cert /tmp/ZscalerRoot0.pem --cert-name zscaler-root
EOF
}

do_npm() { [[ "$PACKAGE" == "npm" || "$PACKAGE" == "all" ]]; }
do_python_tls() { [[ "$PACKAGE" == "python" || "$PACKAGE" == "huggingface" || "$PACKAGE" == "all" ]]; }
do_huggingface() { [[ "$PACKAGE" == "huggingface" || "$PACKAGE" == "all" ]]; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Error: this script must be run as root." >&2
        echo "Use: sudo $0 --use-cert <path> [--package npm|python|huggingface|all]" >&2
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
        npm|python|huggingface|all) ;;
        *)
            echo "Error: --package must be npm, python, huggingface, or all (got: $PACKAGE)." >&2
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
    echo "      System CA bundle is:    $SYSTEM_CA_BUNDLE"
}

write_profiled() {
    local system_cert_path="$1"

    echo "[2/4] Writing managed environment file to $PROFILED_FILE..."

    {
        echo "# Managed by install_certs_debian_ubuntu.sh"
        echo "# Package manager CA configuration"
        echo

        if do_npm; then
            echo "export NODE_USE_SYSTEM_CA=1"
            echo "export NODE_EXTRA_CA_CERTS=\"$system_cert_path\""
            echo
        fi

        if do_python_tls; then
            echo "export REQUESTS_CA_BUNDLE=\"$SYSTEM_CA_BUNDLE\""
            echo "export SSL_CERT_FILE=\"$SYSTEM_CA_BUNDLE\""
            echo
        fi
        if do_huggingface; then
            echo "export HF_HUB_DISABLE_XET=1"
            echo "export HF_HUB_ETAG_TIMEOUT=86400"
            echo "export HF_HUB_DOWNLOAD_TIMEOUT=86400"
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

    tmp=$(mktemp)
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

remove_hf_hub_exports_from_file() {
    local file="$1"
    [[ ! -f "$file" ]] && return 0
    local tmp
    tmp=$(mktemp)
    grep -v -E '^export HF_HUB_(DISABLE_XET|ETAG_TIMEOUT|DOWNLOAD_TIMEOUT)=' "$file" > "$tmp" && mv "$tmp" "$file"
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
    local system_cert_path="$1"
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
        ensure_export_in_file "$rc_file" "NODE_EXTRA_CA_CERTS" "$system_cert_path"
    fi

    if do_python_tls; then
        ensure_export_in_file "$rc_file" "REQUESTS_CA_BUNDLE" "$SYSTEM_CA_BUNDLE"
        ensure_export_in_file "$rc_file" "SSL_CERT_FILE" "$SYSTEM_CA_BUNDLE"
    fi
    if do_huggingface; then
        ensure_export_in_file "$rc_file" "HF_HUB_DISABLE_XET" "1"
        ensure_export_in_file "$rc_file" "HF_HUB_ETAG_TIMEOUT" "86400"
        ensure_export_in_file "$rc_file" "HF_HUB_DOWNLOAD_TIMEOUT" "86400"
    elif do_python_tls; then
        remove_hf_hub_exports_from_file "$rc_file"
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

    if do_npm; then
        echo "npm environment:"
        echo "  NODE_USE_SYSTEM_CA=1"
        echo "  NODE_EXTRA_CA_CERTS=$system_cert_path"
        echo
    fi

    if do_python_tls; then
        echo "Python environment:"
        echo "  REQUESTS_CA_BUNDLE=$SYSTEM_CA_BUNDLE"
        echo "  SSL_CERT_FILE=$SYSTEM_CA_BUNDLE"
        echo
    fi
    if do_huggingface; then
        echo "Hugging Face Hub:"
        echo "  HF_HUB_DISABLE_XET=1"
        echo "  HF_HUB_ETAG_TIMEOUT=86400"
        echo "  HF_HUB_DOWNLOAD_TIMEOUT=86400"
        echo
    fi

    echo "Configuration written to:"
    echo "  $PROFILED_FILE"
    echo "  invoking user's shell rc file"
    echo
    echo "Open a $rc_hint and validate:"
    if do_npm; then
        echo "  env | grep NODE_EXTRA_CA_CERTS"
        echo "  npm i axios"
    fi
    if do_python_tls; then
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
    write_profiled "$system_cert_path"
    update_user_shell_rc "$system_cert_path"
    print_done "$system_cert_path"
}

main "$@"