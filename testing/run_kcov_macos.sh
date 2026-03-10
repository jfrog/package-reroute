#!/usr/bin/env bash
# Run install_certs_macos.sh and validate_install_macos.sh under kcov (so they are
# traced; the main test script invokes them as subprocesses so kcov doesn't see them).
# Merges coverage into coverage/ and runs the normal tests.
#
# Requires: kcov on PATH, and run as root (sudo). Sudo is required for full coverage and
# for the test suite to pass (the install script only runs past its root check when this
# script is root; the test suite adapts expectations when run as root).
#
# From repo root: sudo ./testing/run_kcov_macos.sh  (or sudo ./scripts/testing/run_kcov_macos.sh if scripts live in scripts/)
# Opens coverage at coverage/index.html when done. Modifies /Users/* (adds/updates .zshrc and cert path).

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root (sudo) for full coverage and for the test suite to pass." >&2
    echo "Run: sudo $0" >&2
    exit 1
fi

# Allow kcov collect to fail (e.g. validate with invalid PEM exits 1)
run_kcov() {
    kcov "$@" || true
}

# Support both layouts: testing/ at repo root, or scripts/testing/ under repo root
TESTING_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$TESTING_DIR/../install_certs_macos.sh" ]; then
    REPO_ROOT="$(cd "$TESTING_DIR/.." && pwd)"
    SCRIPT_DIR="$REPO_ROOT"
else
    REPO_ROOT="$(cd "$TESTING_DIR/../.." && pwd)"
    SCRIPT_DIR="$REPO_ROOT/scripts"
fi
INSTALL="$SCRIPT_DIR/install_certs_macos.sh"
VALIDATE="$SCRIPT_DIR/validate_install_macos.sh"
COV_ROOT="$REPO_ROOT/coverage"
COV_TMP="$REPO_ROOT/coverage_tmp"

[ -x "$INSTALL" ] || { echo "Error: $INSTALL not found or not executable" >&2; exit 1; }
[ -x "$VALIDATE" ] || { echo "Error: $VALIDATE not found or not executable" >&2; exit 1; }
command -v kcov >/dev/null 2>&1 || { echo "Error: kcov not on PATH (e.g. brew install kcov)" >&2; exit 1; }

# Temp PEM for validate (mock home) runs
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=test-cert" -days 1 2>/dev/null
echo "not a certificate" > "$TMP/invalid.pem"
MOCK_HOME="$TMP/home"
mkdir -p "$MOCK_HOME"
echo "export NODE_EXTRA_CA_CERTS=\"$TMP/cert.pem\"" > "$MOCK_HOME/.zshrc"

rm -rf "$COV_TMP" "$COV_ROOT"
mkdir -p "$COV_TMP"

INCLUDE="--include-path=$SCRIPT_DIR"
# For merged report path when uploading or opening
COV_MERGED="$COV_ROOT/kcov-merged"

echo "Collecting coverage for install_certs_macos.sh (no-root paths)..."
run_kcov $INCLUDE --collect-only "$COV_TMP/install_help" "$INSTALL" --help
run_kcov $INCLUDE --collect-only "$COV_TMP/install_bad_package" "$INSTALL" --package foo
run_kcov $INCLUDE --collect-only "$COV_TMP/install_use_cert" "$INSTALL" --use-cert "$TMP/cert.pem"
# More arg-validation branches (all exit before root check)
run_kcov $INCLUDE --collect-only "$COV_TMP/install_certname_only" "$INSTALL" --cert-name "X"
run_kcov $INCLUDE --collect-only "$COV_TMP/install_extractpath_only" "$INSTALL" --extract-path /tmp
run_kcov $INCLUDE --collect-only "$COV_TMP/install_no_cert_source" "$INSTALL" --package all
run_kcov $INCLUDE --collect-only "$COV_TMP/install_conflict" "$INSTALL" --use-cert "$TMP/cert.pem" --cert-name "X"
run_kcov $INCLUDE --collect-only "$COV_TMP/install_use_cert_missing" "$INSTALL" --use-cert "$TMP/nonexistent.pem"
run_kcov $INCLUDE --collect-only "$COV_TMP/install_package_npm" "$INSTALL" --package npm
run_kcov $INCLUDE --collect-only "$COV_TMP/install_package_pip" "$INSTALL" --package pip
run_kcov $INCLUDE --collect-only "$COV_TMP/install_unknown_option" "$INSTALL" --unknown-option
# Keychain extraction path (no cert matches): covers keychain loop, security find-certificate, match_count=0 exit
run_kcov $INCLUDE --collect-only "$COV_TMP/install_keychain_nomatch" "$INSTALL" --cert-name "NoCertificateMatchesThisPattern123" --extract-path certs
# Keychain success path: when exactly one cert matches, covers write_merged_pem_file, canonical_path, same-path merge. Try several common names so at least one may match on the machine.
for _name in "Amazon Root CA 1" "Apple Root CA" "DigiCert Root"; do
    run_kcov $INCLUDE --collect-only "$COV_TMP/install_keychain_${_name// /_}" "$INSTALL" --cert-name "$_name" --extract-path certs
done
# --package npm/pip only with --use-cert: cover add_exports_to_file branches (do_npm only / do_pip only)
run_kcov $INCLUDE --collect-only "$COV_TMP/install_use_cert_npm_only" "$INSTALL" --package npm --use-cert "$TMP/cert.pem"
run_kcov $INCLUDE --collect-only "$COV_TMP/install_use_cert_pip_only" "$INSTALL" --package pip --use-cert "$TMP/cert.pem"

echo "Collecting coverage for validate_install_macos.sh..."
run_kcov $INCLUDE --collect-only "$COV_TMP/validate_required" $VALIDATE
HOME="$MOCK_HOME" run_kcov $INCLUDE --collect-only "$COV_TMP/validate_mock_home" "$VALIDATE" --expected-subject test-cert

echo "Merging coverage..."
MERGE_DIRS=(
    "$COV_TMP"/install_help "$COV_TMP"/install_bad_package "$COV_TMP"/install_use_cert
    "$COV_TMP"/install_certname_only "$COV_TMP"/install_extractpath_only "$COV_TMP"/install_no_cert_source
    "$COV_TMP"/install_conflict "$COV_TMP"/install_use_cert_missing "$COV_TMP"/install_package_npm "$COV_TMP"/install_package_pip
    "$COV_TMP"/install_unknown_option "$COV_TMP"/install_keychain_nomatch
    "$COV_TMP"/install_keychain_Amazon_Root_CA_1 "$COV_TMP"/install_keychain_Apple_Root_CA "$COV_TMP"/install_keychain_DigiCert_Root
    "$COV_TMP"/install_use_cert_npm_only "$COV_TMP"/install_use_cert_pip_only
    "$COV_TMP"/validate_required "$COV_TMP"/validate_mock_home
)
kcov $INCLUDE --merge "$COV_ROOT" "${MERGE_DIRS[@]}"

rm -rf "$COV_TMP"

echo "Running test suite..."
if [ -f "$REPO_ROOT/testing/test_install_certs_macos.sh" ]; then
    "$REPO_ROOT/testing/test_install_certs_macos.sh"
else
    "$REPO_ROOT/scripts/testing/test_install_certs_macos.sh"
fi

# So the user who ran sudo can open the report without sudo
if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown -R "$SUDO_UID:$SUDO_GID" "$COV_ROOT"
fi

echo ""
echo "Coverage report (merged): $COV_MERGED/index.html"
if [ -f "$COV_MERGED/index.html" ]; then
    open "$COV_MERGED/index.html" 2>/dev/null || true
elif [ -f "$COV_ROOT/index.html" ]; then
    open "$COV_ROOT/index.html" 2>/dev/null || true
fi
