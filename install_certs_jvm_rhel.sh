#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Install a custom CA certificate into RHEL-family system trust for JVM clients.
#
# This script is for Red Hat OpenJDK-style hosts where Java cacerts is managed
# by update-ca-trust at /etc/pki/ca-trust/extracted/java/cacerts.
#
# Run:
#   sudo bash install_certs_jvm_rhel.sh --use-cert /path/to/cert.pem [--cert-name <name>]

set -euo pipefail

DEFAULT_CERT_BASENAME="package-route-custom-ca"
RHEL_ANCHOR_DIR="/etc/pki/ca-trust/source/anchors"
RHEL_JAVA_CACERTS="/etc/pki/ca-trust/extracted/java/cacerts"
JKS_PASSWORD="changeit"
EXPIRY_WARN_SECONDS=2592000

USE_CERT=""
CERT_BASENAME="$DEFAULT_CERT_BASENAME"

usage() {
    cat <<EOF
Usage:
  sudo $0 --use-cert <path> [--cert-name <name>]

Options:
  --use-cert <path>   Path to an existing PEM/CRT certificate file (required).
  --cert-name <name>  Base name for the installed anchor file
                      (default: ${DEFAULT_CERT_BASENAME}).
  -h, --help          Show this help.

Examples:
  sudo $0 --use-cert /tmp/ZscalerRoot0.pem
  sudo $0 --use-cert /tmp/ca.pem --cert-name zscaler-root
EOF
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Error: this script must be run as root." >&2
        echo "Use: sudo $0 --use-cert <path> [--cert-name <name>]" >&2
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
    if [[ ! "$CERT_BASENAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "Error: --cert-name must match [A-Za-z0-9._-]+ (got: $CERT_BASENAME)." >&2
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
    local id="${ID:-}" id_like="${ID_LIKE:-}"
    case "$id" in
        rhel|fedora|centos|rocky|almalinux|amzn) return 0 ;;
    esac
    case "$id_like" in
        *rhel*|*fedora*|*centos*) return 0 ;;
    esac

    echo "Error: this script supports RHEL/Fedora/CentOS/Amazon-Linux families." >&2
    echo "Detected ID=${id:-unknown}, ID_LIKE=${id_like:-unknown}" >&2
    exit 1
}

check_dependencies() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo "Error: openssl is required but not found." >&2
        exit 1
    fi
    if ! command -v update-ca-trust >/dev/null 2>&1; then
        echo "Error: update-ca-trust is required but not found." >&2
        exit 1
    fi
}

validate_pem() {
    local path="$1"

    if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$path" 2>/dev/null; then
        echo "Error: certificate is not PEM-encoded: $path" >&2
        echo "       If it's DER, convert first:" >&2
        echo "         openssl x509 -inform der -in $path -out $path.pem" >&2
        exit 1
    fi
    if ! openssl x509 -in "$path" -noout >/dev/null 2>&1; then
        echo "Error: invalid PEM/CRT certificate file: $path" >&2
        exit 1
    fi
    if ! openssl x509 -in "$path" -checkend 0 -noout >/dev/null 2>&1; then
        echo "Error: certificate has already expired: $path" >&2
        exit 1
    fi
    if ! openssl x509 -in "$path" -checkend "$EXPIRY_WARN_SECONDS" -noout >/dev/null 2>&1; then
        echo "[warn] certificate expires within 30 days: $path" >&2
    fi

    local bc
    bc="$(openssl x509 -in "$path" -noout -ext basicConstraints 2>/dev/null || true)"
    if ! grep -qi 'CA:TRUE' <<<"$bc"; then
        echo "Error: certificate is not a CA (basicConstraints missing CA:TRUE): $path" >&2
        echo "       Java trust stores reject non-CA trust anchors during PKIX path building." >&2
        exit 1
    fi

    local count
    count="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$path" 2>/dev/null || echo 0)"
    if [[ "$count" -gt 1 ]]; then
        echo "[warn] PEM file contains $count certificates; update-ca-trust will ingest the bundle as one anchor file." >&2
    fi
}

install_anchor() {
    local anchor_path="${RHEL_ANCHOR_DIR}/${CERT_BASENAME}.crt"

    echo "[1/3] Installing CA into system anchor: $anchor_path"
    mkdir -p "$RHEL_ANCHOR_DIR"

    if [[ -e "$anchor_path" ]]; then
        local existing_fp installer_fp
        existing_fp="$(openssl x509 -in "$anchor_path" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' || true)"
        installer_fp="$(openssl x509 -in "$USE_CERT" -noout -fingerprint -sha256 | sed 's/.*=//')"
        if [[ "$existing_fp" == "$installer_fp" ]]; then
            echo "      Anchor already present with matching fingerprint; skipping copy."
        else
            echo "      [warn] Replacing existing anchor at $anchor_path" >&2
            echo "             existing fingerprint: $existing_fp" >&2
            echo "             new fingerprint:      $installer_fp" >&2
            cp "$USE_CERT" "$anchor_path"
        fi
    else
        cp "$USE_CERT" "$anchor_path"
    fi
    chmod 0644 "$anchor_path"

    echo "[2/3] Running update-ca-trust extract..."
    update-ca-trust extract

    echo "[3/3] Verifying Java cacerts contains the CA..."
    if ! command -v keytool >/dev/null 2>&1; then
        echo "      [warn] keytool not on PATH; skipping Java-side verification. Install a JDK and re-run validate_certs_jvm_rhel.sh." >&2
    else
        local fingerprint listing
        fingerprint="$(openssl x509 -in "$anchor_path" -noout -fingerprint -sha256 | sed 's/.*=//')"
        if ! listing="$(keytool -list -keystore "$RHEL_JAVA_CACERTS" -storepass "$JKS_PASSWORD" 2>&1)"; then
            echo "      [warn] keytool could not read $RHEL_JAVA_CACERTS. Output:" >&2
            printf '%s\n' "$listing" | head -n5 >&2
        elif grep -qiF "$fingerprint" <<<"$listing"; then
            echo "      OK: CA fingerprint visible in $RHEL_JAVA_CACERTS"
        else
            echo "      [warn] CA fingerprint not visible in $RHEL_JAVA_CACERTS." >&2
        fi
    fi

    echo
    echo "Installed certificate:"
    echo "  $anchor_path"
    echo "Java trust path:"
    echo "  $RHEL_JAVA_CACERTS"
}

main() {
    require_root
    parse_args "$@"
    check_os
    check_dependencies
    validate_pem "$USE_CERT"
    install_anchor
}

main "$@"
