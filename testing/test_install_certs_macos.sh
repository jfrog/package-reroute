#!/usr/bin/env bash
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

# When test script runs as root (e.g. sudo run_kcov_macos.sh), install/validate scripts also run as root,
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
assert_stderr "must be npm, pip, or all" "'$INSTALL_SCRIPT' --package foo 2>&1"
assert_exit 1 "'$INSTALL_SCRIPT' --cert-name X 2>/dev/null"
assert_stderr "requires --extract-path" "'$INSTALL_SCRIPT' --cert-name X 2>&1"
assert_exit 1 "'$INSTALL_SCRIPT' --extract-path /tmp 2>/dev/null"
assert_stderr "requires --cert-name" "'$INSTALL_SCRIPT' --extract-path /tmp 2>&1"
assert_exit 1 "'$INSTALL_SCRIPT' --package all 2>/dev/null"
assert_stderr "either.*--cert-name.*--extract-path.*or --use-cert" "'$INSTALL_SCRIPT' --package all 2>&1"
assert_exit 1 "'$INSTALL_SCRIPT' --use-cert /nonexistent --cert-name X 2>/dev/null"
assert_stderr "cannot be used together" "'$INSTALL_SCRIPT' --use-cert /nonexistent --cert-name X 2>&1"
assert_exit 1 "'$INSTALL_SCRIPT' --use-cert /nonexistent 2>/dev/null"
assert_stderr "path is not a file" "'$INSTALL_SCRIPT' --use-cert /nonexistent 2>&1"
# Valid args but not root: must fail with "run as root". When running as root, --use-cert /etc/hosts fails with "Invalid or missing PEM".
if [ "$ARE_ROOT" -eq 0 ]; then
    assert_exit 1 "'$INSTALL_SCRIPT' --use-cert /etc/hosts 2>/dev/null"
    assert_stderr "run as root|must be run as root" "'$INSTALL_SCRIPT' --use-cert /etc/hosts 2>&1"
    assert_exit 1 "'$INSTALL_SCRIPT' --use-cert '$TMP/cert.pem' 2>/dev/null"
    assert_stderr "run as root|must be run as root" "'$INSTALL_SCRIPT' --use-cert '$TMP/cert.pem' 2>&1"
    assert_exit 1 "'$INSTALL_SCRIPT' --package npm --use-cert '$TMP/cert.pem' 2>/dev/null"
    assert_exit 1 "'$INSTALL_SCRIPT' --package pip --use-cert '$TMP/cert.pem' 2>/dev/null"
else
    assert_exit 1 "'$INSTALL_SCRIPT' --use-cert /etc/hosts 2>/dev/null"
    assert_stderr "Invalid or missing PEM" "'$INSTALL_SCRIPT' --use-cert /etc/hosts 2>&1"
    assert_exit 0 "'$INSTALL_SCRIPT' --use-cert '$TMP/cert.pem' 2>/dev/null"
    assert_exit 0 "'$INSTALL_SCRIPT' --package npm --use-cert '$TMP/cert.pem' 2>/dev/null"
    assert_exit 0 "'$INSTALL_SCRIPT' --package pip --use-cert '$TMP/cert.pem' 2>/dev/null"
fi

# --use-cert with invalid PEM (file exists but not valid cert): rejected after root check. Test only when passwordless sudo available.
if sudo -n true 2>/dev/null; then
    assert_exit 1 "sudo -n '$INSTALL_SCRIPT' --use-cert '$TMP/invalid.pem' 2>/dev/null"
    assert_stderr "Invalid or missing PEM" "sudo -n '$INSTALL_SCRIPT' --use-cert '$TMP/invalid.pem' 2>&1"
else
    echo "  SKIP: no passwordless sudo, skipping install_certs_macos.sh invalid PEM test"
fi

# --package npm/pip without cert source: same error as --package all
assert_exit 1 "'$INSTALL_SCRIPT' --package npm 2>/dev/null"
assert_exit 1 "'$INSTALL_SCRIPT' --package pip 2>/dev/null"

echo ""
echo "=== validate_install_macos.sh tests (temp PEM and mock home) ==="

# validate_install_macos.sh CLI
assert_exit 0 "'$VALIDATE_SCRIPT' --help | head -1"
assert_exit 1 "'$VALIDATE_SCRIPT' --unknown 2>/dev/null"
assert_stderr "Unknown option" "'$VALIDATE_SCRIPT' --unknown 2>&1"

# validate_install_macos.sh --cert-path with valid PEM
assert_exit 0 "'$VALIDATE_SCRIPT' --cert-path '$TMP/cert.pem'"
assert_exit 1 "'$VALIDATE_SCRIPT' --cert-path '$TMP/nonexistent.pem' 2>/dev/null"
# --cert-path with existing file but invalid PEM content
assert_exit 1 "'$VALIDATE_SCRIPT' --cert-path '$TMP/invalid.pem' 2>/dev/null"
assert_stderr "not a valid PEM|FAIL" "'$VALIDATE_SCRIPT' --cert-path '$TMP/invalid.pem' 2>&1"

# Mock home with .zshrc pointing at our cert
MOCK_HOME="$TMP/home"
mkdir -p "$MOCK_HOME"
echo "export NODE_EXTRA_CA_CERTS=\"$TMP/cert.pem\"" > "$MOCK_HOME/.zshrc"
assert_exit 0 "HOME='$MOCK_HOME' '$VALIDATE_SCRIPT'"
echo "export REQUESTS_CA_BUNDLE=\"$TMP/cert.pem\"" >> "$MOCK_HOME/.zshrc"
assert_exit 0 "HOME='$MOCK_HOME' '$VALIDATE_SCRIPT'"

# Point .zshrc at missing file: should fail
echo "export NODE_EXTRA_CA_CERTS=\"$TMP/missing.pem\"" > "$MOCK_HOME/.zshrc"
assert_exit 1 "HOME='$MOCK_HOME' '$VALIDATE_SCRIPT' 2>/dev/null"

# --all-users without root: must fail; when root it succeeds
if [ "$ARE_ROOT" -eq 0 ]; then
    assert_exit 1 "'$VALIDATE_SCRIPT' --all-users 2>/dev/null"
    assert_stderr "requires root|--all-users requires root" "'$VALIDATE_SCRIPT' --all-users 2>&1"
else
    assert_exit 0 "'$VALIDATE_SCRIPT' --all-users 2>/dev/null"
fi

echo ""
echo "=== Fingerprint and merge tests (same / different cert) ==="

# Helpers matching install_certs_macos.sh (for testing without root)
pem_fingerprint() {
    local pem="$1"
    echo "$pem" | openssl x509 -out /dev/stdout 2>/dev/null | openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/.*=//'
}
read_blocks_from_file() {
    local path="$1"
    [ ! -f "$path" ] && return 1
    awk '/-----BEGIN CERTIFICATE-----/{p=1; b=$0"\n"; next} p{b=b $0 "\n"} /-----END CERTIFICATE-----/{if(p){p=0; printf "%s%c", b, 0}}' "$path" 2>/dev/null
}
bundle_contains_pem() {
    local bundle_path="$1" our_pem="$2"
    local our_fp fp
    our_fp=$(pem_fingerprint "$our_pem")
    [ -z "$our_fp" ] && return 1
    [ ! -f "$bundle_path" ] && return 1
    while IFS= read -r -d '' block; do
        [ -z "$block" ] && continue
        fp=$(pem_fingerprint "$block")
        [ "$fp" = "$our_fp" ] && return 0
    done < <(read_blocks_from_file "$bundle_path" 2>/dev/null)
    return 1
}
merge_certs_into_target_test() {
    local source_file="$1" target_path="$2" our_pem="$3" block_dir
    local our_fp fp f appended=0
    [ ! -f "$source_file" ] || [ ! -s "$source_file" ] && return 0
    our_fp=$(pem_fingerprint "$our_pem")
    [ -z "$our_fp" ] && return 0
    block_dir="$TMP/fp_merge_blocks"
    rm -rf "$block_dir" 2>/dev/null
    mkdir -p "$block_dir"
    awk -v tmp="$block_dir" '
        /-----BEGIN CERTIFICATE-----/{p=1; n++; b=$0"\n"; next}
        p{b=b $0 "\n"}
        /-----END CERTIFICATE-----/{if(p){p=0; f=tmp "/block_" n ".pem"; print b > f; close(f)}}
    ' "$source_file" 2>/dev/null
    for f in "$block_dir"/block_*.pem; do
        [ -f "$f" ] || continue
        fp=$(pem_fingerprint "$(cat "$f")")
        [ -z "$fp" ] && continue
        [ "$fp" = "$our_fp" ] && continue
        bundle_contains_pem "$target_path" "$(cat "$f")" >/dev/null 2>&1 && continue
        cat "$f" >> "$target_path"
        appended=$((appended + 1))
    done
    rm -rf "$block_dir" 2>/dev/null
}

count_pem_blocks() {
    grep -c "BEGIN CERTIFICATE" "$1" 2>/dev/null || echo 0
}

# Second cert (different subject => different fingerprint)
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$TMP/key2.pem" -out "$TMP/cert2.pem" \
    -subj "/CN=other-cert" -days 1 2>/dev/null
[ -f "$TMP/cert2.pem" ] || { echo "Failed to create cert2"; exit 1; }
cp "$TMP/cert.pem" "$TMP/cert1_dup.pem"

CERT1=$(cat "$TMP/cert.pem")
CERT2=$(cat "$TMP/cert2.pem")
CERT1_DUP=$(cat "$TMP/cert1_dup.pem")

FP1=$(pem_fingerprint "$CERT1")
FP2=$(pem_fingerprint "$CERT2")
FP1_DUP=$(pem_fingerprint "$CERT1_DUP")

# Same cert (or copy) => same fingerprint
assert_eq "$FP1" "$FP1_DUP" "same fingerprint (cert and duplicate)"

# Different certs => different fingerprint
[ "$FP1" != "$FP2" ] || { RUN=$((RUN+1)); echo "  FAIL ($RUN): different certs should have different fingerprints"; FAIL=$((FAIL+1)); }
[ "$FP1" != "$FP2" ] && { RUN=$((RUN+1)); echo "  OK ($RUN): different fingerprint (cert1 vs cert2)"; PASS=$((PASS+1)); }

# Bundle with cert1 contains cert1 and duplicate, not cert2
cp "$TMP/cert.pem" "$TMP/bundle.pem"
bundle_contains_pem "$TMP/bundle.pem" "$CERT1_DUP" && bc_same=1 || bc_same=0
bundle_contains_pem "$TMP/bundle.pem" "$CERT2" && bc_diff=1 || bc_diff=0
RUN=$((RUN + 1))
if [ "$bc_same" -eq 1 ] && [ "$bc_diff" -eq 0 ]; then
    echo "  OK ($RUN): bundle contains same-fp cert, not different-fp cert"
    PASS=$((PASS + 1))
else
    echo "  FAIL ($RUN): bundle_contains_pem same=$bc_same diff=$bc_diff"
    FAIL=$((FAIL + 1))
fi

# bundle_contains_pem: non-existent bundle path => false (return 1)
bundle_contains_pem "$TMP/nonexistent.pem" "$CERT1" && bc_missing=1 || bc_missing=0
RUN=$((RUN + 1))
[ "$bc_missing" -eq 0 ] && { echo "  OK ($RUN): bundle_contains_pem nonexistent path → false"; PASS=$((PASS + 1)); } || { echo "  FAIL ($RUN): bundle_contains_pem nonexistent path should be false"; FAIL=$((FAIL + 1)); }

# bundle_contains_pem: invalid/empty our_pem (empty fingerprint) => false
bundle_contains_pem "$TMP/bundle.pem" "not a cert" && bc_invalid=1 || bc_invalid=0
RUN=$((RUN + 1))
[ "$bc_invalid" -eq 0 ] && { echo "  OK ($RUN): bundle_contains_pem invalid PEM → false"; PASS=$((PASS + 1)); } || { echo "  FAIL ($RUN): bundle_contains_pem invalid PEM should be false"; FAIL=$((FAIL + 1)); }

# read_blocks_from_file: non-existent path => return 1 (capture exit code without triggering set -e)
rbf_ret=0; read_blocks_from_file "$TMP/nonexistent.pem" 2>/dev/null || rbf_ret=$?
RUN=$((RUN + 1))
[ "$rbf_ret" -eq 1 ] && { echo "  OK ($RUN): read_blocks_from_file nonexistent path → return 1"; PASS=$((PASS + 1)); } || { echo "  FAIL ($RUN): read_blocks_from_file nonexistent should return 1, got $rbf_ret"; FAIL=$((FAIL + 1)); }

# bundle_contains_pem: cert not in bundle (empty bundle) => false
touch "$TMP/empty.pem"
bundle_contains_pem "$TMP/empty.pem" "$CERT1" && bc_empty=1 || bc_empty=0
RUN=$((RUN + 1))
[ "$bc_empty" -eq 0 ] && { echo "  OK ($RUN): bundle_contains_pem empty bundle → false"; PASS=$((PASS + 1)); } || { echo "  FAIL ($RUN): bundle_contains_pem empty bundle should be false"; FAIL=$((FAIL + 1)); }

# Merge source with same fingerprint as "our" cert => no append (dedupe)
cp "$TMP/cert.pem" "$TMP/bundle.pem"
cp "$TMP/cert1_dup.pem" "$TMP/source_same.pem"
merge_certs_into_target_test "$TMP/source_same.pem" "$TMP/bundle.pem" "$CERT1"
n=$(count_pem_blocks "$TMP/bundle.pem")
RUN=$((RUN + 1))
if [ "$n" -eq 1 ]; then
    echo "  OK ($RUN): merge same fingerprint → 1 cert (dedupe)"
    PASS=$((PASS + 1))
else
    echo "  FAIL ($RUN): merge same fingerprint expected 1 block, got $n"
    FAIL=$((FAIL + 1))
fi

# Merge source with different fingerprint => append
cp "$TMP/cert.pem" "$TMP/bundle.pem"
cp "$TMP/cert2.pem" "$TMP/source_diff.pem"
merge_certs_into_target_test "$TMP/source_diff.pem" "$TMP/bundle.pem" "$CERT1"
n=$(count_pem_blocks "$TMP/bundle.pem")
RUN=$((RUN + 1))
if [ "$n" -eq 2 ]; then
    echo "  OK ($RUN): merge different fingerprint → 2 certs"
    PASS=$((PASS + 1))
else
    echo "  FAIL ($RUN): merge different fingerprint expected 2 blocks, got $n"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "---------------------------------------------------"
echo "Result: $PASS passed, $FAIL failed (total $RUN)"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
