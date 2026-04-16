#!/usr/bin/env bash
# Validate that install_certs_macos.sh ran successfully.
# Run as current user (no sudo needed), or sudo with --all-users.
#
# Usage:
#   ./validate_install_macos.sh                # validate current user
#   sudo ./validate_install_macos.sh --all-users  # validate all users

set -e

ALL_USERS=0
[ "$1" = "--all-users" ] && ALL_USERS=1

PASS=0
FAIL=0
WARN=0

check() {
    local label="$1" ok="$2" msg="$3"
    if [ "$ok" -eq 1 ]; then
        echo "  ✅ $label"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $label — $msg"
        FAIL=$((FAIL + 1))
    fi
}

warn() {
    echo "  ⚠️  $1"
    WARN=$((WARN + 1))
}

validate_user() {
    local home="$1"
    local zshrc="$home/.zshrc"
    local user=$(basename "$home")

    echo ""
    echo "--- User: $user ($home) ---"

    # 1. .zshrc exists
    if [ ! -f "$zshrc" ]; then
        echo "  ❌ No .zshrc found — skipping"
        FAIL=$((FAIL + 1))
        return
    fi

    # 2. Extract REQUESTS_CA_BUNDLE path from .zshrc
    bundle=$(grep '^export REQUESTS_CA_BUNDLE=' "$zshrc" 2>/dev/null | head -1 | sed 's/^export REQUESTS_CA_BUNDLE=//' | tr -d '"' | tr -d "'")
    node_bundle=$(grep '^export NODE_EXTRA_CA_CERTS=' "$zshrc" 2>/dev/null | head -1 | sed 's/^export NODE_EXTRA_CA_CERTS=//' | tr -d '"' | tr -d "'")

    # 3. Check env vars in .zshrc
    for var in NODE_USE_SYSTEM_CA NODE_EXTRA_CA_CERTS UV_NATIVE_TLS UV_SYSTEM_CERTS REQUESTS_CA_BUNDLE; do
        val=$(grep "^export ${var}=" "$zshrc" 2>/dev/null | head -1)
        if [ -n "$val" ]; then
            check "$var set" 1 ""
        else
            check "$var set" 0 "not found in $zshrc"
        fi
    done

    # 4. Bundle file exists and has certs
    target="${bundle:-$node_bundle}"
    if [ -z "$target" ]; then
        check "Bundle path found" 0 "no bundle path found in .zshrc"
        return
    fi

    if [ ! -f "$target" ]; then
        check "Bundle file exists" 0 "$target not found"
        return
    fi
    check "Bundle file exists ($target)" 1 ""

    # 5. Cert count (should be > 100 for system roots + enterprise CAs)
    cert_count=$(grep -c 'BEGIN CERTIFICATE' "$target" 2>/dev/null || echo 0)
    if [ "$cert_count" -gt 100 ]; then
        check "Bundle has $cert_count certs (>100 = Keychain roots + enterprise CAs)" 1 ""
    elif [ "$cert_count" -gt 1 ]; then
        warn "Bundle has $cert_count certs — expected >100. May be built from /etc/ssl/cert.pem instead of Keychain."
    else
        check "Bundle has >1 cert" 0 "only $cert_count cert(s) — likely missing system roots (REQUESTS_CA_BUNDLE will break pip/poetry/twine)"
    fi

    # 6. Zscaler cert is present
    if command -v openssl >/dev/null 2>&1; then
        has_zscaler=$(openssl storeutl -noout -text -certs "$target" 2>/dev/null | grep -i "zscaler" | head -1)
        if [ -n "$has_zscaler" ]; then
            check "Zscaler cert present in bundle" 1 ""
        else
            check "Zscaler cert in bundle" 0 "not found — re-run install script"
        fi
    else
        warn "openssl not found — skipping cert content checks"
    fi

    # 7. NODE_EXTRA_CA_CERTS and REQUESTS_CA_BUNDLE point to same file
    if [ -n "$bundle" ] && [ -n "$node_bundle" ] && [ "$bundle" != "$node_bundle" ]; then
        warn "REQUESTS_CA_BUNDLE ($bundle) and NODE_EXTRA_CA_CERTS ($node_bundle) point to different files"
    fi
}

echo "=== Certificate Setup Validation ==="

if [ "$ALL_USERS" -eq 1 ]; then
    for homedir in /Users/*; do
        [ "$homedir" = "/Users/Shared" ] && continue
        [ ! -d "$homedir" ] && continue
        owner_uid=$(stat -f '%u' "$homedir" 2>/dev/null) || continue
        [ "$owner_uid" -lt 501 ] && continue
        validate_user "$homedir"
    done
else
    validate_user "$HOME"
fi

echo ""
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Warnings: $WARN"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "❌ Validation FAILED — re-run install_certs_macos.sh"
    exit 1
else
    echo ""
    echo "✅ Validation PASSED"
    exit 0
fi
