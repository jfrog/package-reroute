#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Build a JVM truststore from the Linux system CA bundle plus one custom CA PEM.
#
# This is a build-time helper for the JVM installers. It does not install
# anything and does not require root.
#
# Run:
#   ./build_jvm_truststore_linux.sh --use-cert /path/to/company-ca.pem --output /tmp/package-route-truststore.jks

set -euo pipefail

JKS_PASSWORD="changeit"
DEFAULT_CERT_ALIAS="package-route-custom-ca"

USE_CERT=""
OUTPUT=""
CERT_ALIAS="$DEFAULT_CERT_ALIAS"
SYSTEM_BUNDLE=""
OPENSSL_BIN="${OPENSSL:-openssl}"

usage() {
    cat <<EOF
Usage:
  $0 --use-cert <path> --output <path> [--cert-alias <alias>] [--system-bundle <path>]

Options:
  --use-cert <path>      PEM certificate to add to the truststore. Must contain
                         exactly one non-expired CA certificate with CA:TRUE.
  --output <path>        Destination truststore path. Replaced atomically after
                         successful build.
  --cert-alias <alias>   Alias for the custom CA (default: ${DEFAULT_CERT_ALIAS}).
  --system-bundle <path> Override the detected Linux system CA PEM bundle.
  -h, --help             Show this help.

The generated truststore uses password '${JKS_PASSWORD}'.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --use-cert)
                USE_CERT="${2:?Error: --use-cert requires a value}"
                shift 2
                ;;
            --output)
                OUTPUT="${2:?Error: --output requires a value}"
                shift 2
                ;;
            --cert-alias)
                CERT_ALIAS="${2:?Error: --cert-alias requires a value}"
                shift 2
                ;;
            --system-bundle)
                SYSTEM_BUNDLE="${2:?Error: --system-bundle requires a value}"
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

    [[ -n "$USE_CERT" ]] || { echo "Error: --use-cert is required." >&2; usage >&2; exit 1; }
    [[ -n "$OUTPUT" ]] || { echo "Error: --output is required." >&2; usage >&2; exit 1; }
    [[ "$CERT_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]] || {
        echo "Error: --cert-alias must match [A-Za-z0-9._-]+ (got: $CERT_ALIAS)." >&2
        exit 1
    }
}

check_dependencies() {
    command -v keytool >/dev/null 2>&1 || { echo "Error: keytool is required." >&2; exit 1; }
    command -v "$OPENSSL_BIN" >/dev/null 2>&1 || { echo "Error: openssl is required." >&2; exit 1; }
}

detect_system_bundle() {
    if [[ -n "$SYSTEM_BUNDLE" ]]; then
        [[ -f "$SYSTEM_BUNDLE" && -r "$SYSTEM_BUNDLE" && -s "$SYSTEM_BUNDLE" ]] || {
            echo "Error: --system-bundle must point to a readable non-empty file: $SYSTEM_BUNDLE" >&2
            exit 1
        }
        echo "$SYSTEM_BUNDLE"
        return 0
    fi

    local candidate
    for candidate in \
        /etc/ssl/certs/ca-certificates.crt \
        /etc/pki/tls/certs/ca-bundle.crt \
        /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
        /etc/ssl/ca-bundle.pem; do
        if [[ -f "$candidate" && -r "$candidate" && -s "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    echo "Error: could not find a Linux system CA bundle. Pass --system-bundle <path>." >&2
    exit 1
}

validate_custom_pem() {
    local path="$1" count bc

    [[ -f "$path" && -r "$path" && -s "$path" ]] || {
        echo "Error: --use-cert must point to a readable non-empty file: $path" >&2
        exit 1
    }

    count="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$path" 2>/dev/null || true)"
    if [[ "$count" -ne 1 ]]; then
        echo "Error: --use-cert must contain exactly one PEM certificate (found $count): $path" >&2
        exit 1
    fi
    "$OPENSSL_BIN" x509 -in "$path" -noout >/dev/null 2>&1 || {
        echo "Error: invalid PEM certificate: $path" >&2
        exit 1
    }
    "$OPENSSL_BIN" x509 -in "$path" -checkend 0 -noout >/dev/null 2>&1 || {
        echo "Error: certificate has already expired: $path" >&2
        exit 1
    }
    bc="$("$OPENSSL_BIN" x509 -in "$path" -noout -ext basicConstraints 2>/dev/null || true)"
    if ! grep -qi 'CA:TRUE' <<<"$bc"; then
        echo "Error: certificate is not a CA (basicConstraints missing CA:TRUE): $path" >&2
        exit 1
    fi
}

split_pem_bundle() {
    local bundle="$1" out_dir="$2"
    awk -v dir="$out_dir" '
        /-----BEGIN CERTIFICATE-----/ { n++; file=sprintf("%s/cert-%05d.pem", dir, n) }
        file != "" { print > file }
        /-----END CERTIFICATE-----/ { file="" }
    ' "$bundle"
}

cert_fingerprint() {
    "$OPENSSL_BIN" x509 -in "$1" -noout -fingerprint -sha256 \
        | sed 's/.*=//' | tr -d ':' | tr '[:upper:]' '[:lower:]'
}

import_cert() {
    local cert="$1" alias="$2" truststore="$3" keytool_out

    if ! keytool_out="$(keytool -importcert -noprompt -storetype JKS \
            -alias "$alias" \
            -file "$cert" \
            -keystore "$truststore" \
            -storepass "$JKS_PASSWORD" 2>&1)"; then
        echo "Error: keytool failed while importing $cert as $alias. Output:" >&2
        printf '%s\n' "$keytool_out" | sed 's/^/  /' >&2
        exit 1
    fi
}

build_truststore() {
    local system_bundle="$1" tmpdir cert fp imported_count=0 tmp_store seen

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    mkdir -p "$tmpdir/system"
    seen="$tmpdir/seen-fingerprints.txt"
    : > "$seen"
    tmp_store="$tmpdir/truststore.jks"

    split_pem_bundle "$system_bundle" "$tmpdir/system"
    for cert in "$tmpdir"/system/*.pem; do
        [[ -s "$cert" ]] || continue
        if ! "$OPENSSL_BIN" x509 -in "$cert" -noout >/dev/null 2>&1; then
            continue
        fi
        fp="$(cert_fingerprint "$cert")"
        if grep -qx "$fp" "$seen"; then
            continue
        fi
        printf '%s\n' "$fp" >> "$seen"
        import_cert "$cert" "system-$fp" "$tmp_store"
        imported_count=$((imported_count + 1))
    done

    if [[ "$imported_count" -eq 0 ]]; then
        echo "Error: no certificates could be imported from system bundle: $system_bundle" >&2
        exit 1
    fi

    import_cert "$USE_CERT" "$CERT_ALIAS" "$tmp_store"

    mkdir -p "$(dirname "$OUTPUT")"
    mv "$tmp_store" "$OUTPUT"
    chmod 0644 "$OUTPUT"

    echo "Built JVM truststore:"
    echo "  $OUTPUT"
    echo "System bundle:"
    echo "  $system_bundle"
    echo "Imported system certificates:"
    echo "  $imported_count"
    echo "Custom CA alias:"
    echo "  $CERT_ALIAS"
}

main() {
    parse_args "$@"
    check_dependencies
    validate_custom_pem "$USE_CERT"

    local system_bundle
    system_bundle="$(detect_system_bundle)"
    build_truststore "$system_bundle"
}

main "$@"
