#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Build a JVM truststore from the Linux system CA bundle.
#
# Enterprise CAs already in the system trust store (e.g. Zscaler via ZCC /
# update-ca-certificates) are included automatically. This is a build-time
# helper for the JVM installers — it does not install anything and does not
# require root.
#
# Run:
#   ./build_jvm_truststore_linux.sh --output /tmp/package-route-truststore.jks

set -euo pipefail

JKS_PASSWORD="changeit"
OUTPUT=""
SYSTEM_BUNDLE=""
OPENSSL_BIN="${OPENSSL:-openssl}"

usage() {
    cat <<EOF
Usage:
  $0 --output <path> [--system-bundle <path>]

Options:
  --output <path>        Destination truststore path. Replaced atomically after
                         successful build.
  --system-bundle <path> Override the detected Linux system CA PEM bundle.
  -h, --help             Show this help.

Imports certificates from the host system CA bundle into a JKS truststore
(password '${JKS_PASSWORD}').
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                OUTPUT="${2:?Error: --output requires a value}"
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

    [[ -n "$OUTPUT" ]] || { echo "Error: --output is required." >&2; usage >&2; exit 1; }
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
    # Expand path now — under set -u a deferred "$tmpdir" fails once this
    # local goes out of scope when build_truststore returns.
    trap 'rm -rf "'"$tmpdir"'"' EXIT
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

    mkdir -p "$(dirname "$OUTPUT")"
    mv "$tmp_store" "$OUTPUT"
    chmod 0644 "$OUTPUT"

    echo "Built JVM truststore:"
    echo "  $OUTPUT"
    echo "System bundle:"
    echo "  $system_bundle"
    echo "Imported system certificates:"
    echo "  $imported_count"
}

main() {
    parse_args "$@"
    check_dependencies

    local system_bundle
    system_bundle="$(detect_system_bundle)"
    build_truststore "$system_bundle"
}

main "$@"
