#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Tests for install_certs_macos.sh (CLI and arg validation) and validate_install_macos.sh.
# Run from repo root: ./scripts/testing/test_install_certs_macos.sh  or from scripts/: ./testing/test_install_certs_macos.sh
# No root required; uses a temp dir and a self-signed PEM. Run after changes to install or validate scripts; see scripts/README.md for coverage.

set -e

# Scripts under test live in parent of testing/ (i.e. scripts/)
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
if [ ! -f "$SCRIPT_DIR/install_certs_macos.sh" ]; then
    echo "Error: install_certs_macos.sh not found in $SCRIPT_DIR" >&2
    exit 1
fi
INSTALL_SCRIPT="$SCRIPT_DIR/install_certs_macos.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate_install_macos.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Valid PEM for --use-cert tests and validate/fingerprint sections
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=test-cert" -days 1 2>/dev/null
[ -f "$TMP/cert.pem" ] || { echo "Error: failed to create temp PEM"; exit 1; }
echo "not a certificate" > "$TMP/invalid.pem"

RUN=0
PASS=0
FAIL=0

# When test script runs as root (e.g. sudo ./testing/test_install_certs_macos.sh), install/validate scripts also run as root,
# so we skip tests that expect "run as root" / "exit 1 when not root" and --all-users requiring root.
ARE_ROOT=0
[ "$(id -u)" -eq 0 ] && ARE_ROOT=1

assert_exit() {
    local expected="$1" cmd="$2"
    RUN=$((RUN + 1))
    if eval "$cmd" >/dev/null 2>&1; then got=0; else got=1; fi
    if [ "$got" -eq "$expected" ]; then
        echo "  OK ($RUN): exit $expected"
        PASS=$((PASS + 1))
    else
        echo "  FAIL ($RUN): expected exit $expected, got $got: $cmd"
        FAIL=$((FAIL + 1))
    fi
}

assert_stderr() {
    local pattern="$1" cmd="$2"
    RUN=$((RUN + 1))
    stderr=$(eval "$cmd" 2>&1) || true
    if echo "$stderr" | grep -qE "$pattern"; then
        echo "  OK ($RUN): stderr matches /$pattern/"
        PASS=$((PASS + 1))
    else
        echo "  FAIL ($RUN): stderr did not match /$pattern/: $cmd"
        echo "    stderr: $stderr"
        FAIL=$((FAIL + 1))
    fi
}

# Assert two strings are equal (for fingerprint comparison)
assert_eq() {
    local expected="$1" actual="$2" label="${3:-}"
    RUN=$((RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo "  OK ($RUN): ${label:-equal}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL ($RUN): ${label:-expected} '$expected' != '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== install_certs_macos.sh CLI tests ==="

assert_exit 0 "'$INSTALL_SCRIPT' --help | head -1"
assert_exit 1 "'$INSTALL_SCRIPT' --unknown 2>/dev/null"
assert_exit 1 "'$INSTALL_SCRIPT' --package foo 2>/dev/null"
assert_stderr "must be npm, python, or all" "'$INSTALL_SCRIPT' --package foo 2>&1"
assert_exit 1 "'$INSTALL_SCRIPT' --package all 2>/dev/null"
assert_stderr "either --extract-path or --use-cert" "'$INSTALL_SCRIPT' --package all 2>&1"
assert_exit 1 "'$INSTALL_SCRIPT' --use-cert /nonexistent --extract-path /tmp 2>/dev/null"
assert_stderr "cannot be used together" "'$INSTALL_SCRIPT' --use-cert /nonexistent --extract-path /tmp 2>&1"
assert_exit 1 "'$INSTALL_SCRIPT' --use-cert /nonexistent 2>/dev/null"
assert_stderr "path is not a file" "'$INSTALL_SCRIPT' --use-cert /nonexistent 2>&1"
# Valid args but not root: must fail with "run as root". When running as root, --use-cert /etc/hosts fails with "Invalid or missing PEM".
if [ "$ARE_ROOT" -eq 0 ]; then
    assert_exit 1 "'$INSTALL_SCRIPT' --use-cert /etc/hosts 2>/dev/null"
    assert_stderr "run as root|must be run as root" "'$INSTALL_SCRIPT' --use-cert /etc/hosts 2>&1"
    assert_exit 1 "'$INSTALL_SCRIPT' --use-cert '$TMP/cert.pem' 2>/dev/null"
    assert_stderr "run as root|must be run as root" "'$INSTALL_SCRIPT' --use-cert '$TMP/cert.pem' 2>&1"
    assert_exit 1 "'$INSTALL_SCRIPT' --package npm --use-cert '$TMP/cert.pem' 2>/dev/null"
    assert_exit 1 "'$INSTALL_SCRIPT' --package python --use-cert '$TMP/cert.pem' 2>/dev/null"
else
    assert_exit 1 "'$INSTALL_SCRIPT' --use-cert /etc/hosts 2>/dev/null"
    assert_stderr "Invalid or missing PEM" "'$INSTALL_SCRIPT' --use-cert /etc/hosts 2>&1"
    assert_exit 0 "'$INSTALL_SCRIPT' --use-cert '$TMP/cert.pem' 2>/dev/null"
    assert_exit 0 "'$INSTALL_SCRIPT' --package npm --use-cert '$TMP/cert.pem' 2>/dev/null"
    assert_exit 0 "'$INSTALL_SCRIPT' --package python --use-cert '$TMP/cert.pem' 2>/dev/null"
fi

# --use-cert with invalid PEM (file exists but not valid cert): rejected after root check. Test only when passwordless sudo available.
if sudo -n true 2>/dev/null; then
    assert_exit 1 "sudo -n '$INSTALL_SCRIPT' --use-cert '$TMP/invalid.pem' 2>/dev/null"
    assert_stderr "Invalid or missing PEM" "sudo -n '$INSTALL_SCRIPT' --use-cert '$TMP/invalid.pem' 2>&1"
else
    echo "  SKIP: no passwordless sudo, skipping install_certs_macos.sh invalid PEM test"
fi

# --package npm/python without cert source: same error as --package all
assert_exit 1 "'$INSTALL_SCRIPT' --package npm 2>/dev/null"
assert_exit 1 "'$INSTALL_SCRIPT' --package python 2>/dev/null"

echo ""
echo "=== validate_install_macos.sh tests (temp PEM and mock home) ==="

# validate_install_macos.sh CLI: --expected-subject is required
assert_exit 1 "'$VALIDATE_SCRIPT' 2>/dev/null"
assert_stderr "expected-subject is required" "'$VALIDATE_SCRIPT' 2>&1"
assert_exit 1 "'$VALIDATE_SCRIPT' --unknown 2>/dev/null"
assert_stderr "Unknown option" "'$VALIDATE_SCRIPT' --unknown 2>&1"

# Mock home with .zshrc pointing at our cert
MOCK_HOME="$TMP/home"
mkdir -p "$MOCK_HOME"
echo "export NODE_EXTRA_CA_CERTS=\"$TMP/cert.pem\"" > "$MOCK_HOME/.zshrc"
assert_exit 0 "HOME='$MOCK_HOME' '$VALIDATE_SCRIPT' --expected-subject test-cert"
echo "export REQUESTS_CA_BUNDLE=\"$TMP/cert.pem\"" >> "$MOCK_HOME/.zshrc"
assert_exit 0 "HOME='$MOCK_HOME' '$VALIDATE_SCRIPT' --expected-subject test-cert"

# Point .zshrc at missing file: should fail
echo "export NODE_EXTRA_CA_CERTS=\"$TMP/missing.pem\"" > "$MOCK_HOME/.zshrc"
assert_exit 1 "HOME='$MOCK_HOME' '$VALIDATE_SCRIPT' --expected-subject test-cert 2>/dev/null"

# --all-users without root: must fail; when root it succeeds
if [ "$ARE_ROOT" -eq 0 ]; then
    assert_exit 1 "'$VALIDATE_SCRIPT' --expected-subject test-cert --all-users 2>/dev/null"
    assert_stderr "requires root|--all-users requires root" "'$VALIDATE_SCRIPT' --expected-subject test-cert --all-users 2>&1"
else
    assert_exit 0 "'$VALIDATE_SCRIPT' --expected-subject test-cert --all-users 2>/dev/null"
fi

echo ""
echo "---------------------------------------------------"
echo "Result: $PASS passed, $FAIL failed (total $RUN)"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
