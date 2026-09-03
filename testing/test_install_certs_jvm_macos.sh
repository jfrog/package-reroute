#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Smoke matrix for install_certs_jvm_macos.sh + validate_certs_jvm_macos.sh.
#
# Run as root from the repo root (matches macos-latest CI usage):
#   sudo ./testing/test_install_certs_jvm_macos.sh
#
# Targets the SUDO_USER's per-user files. `cleanup` runs at the start of
# fresh-state cases and via `trap EXIT`. The test runner builds a keychain-only
# JKS via build_jvm_truststore_macos.sh, then imports a lab CA into that fixture
# so --expected-subject stays deterministic. Tests seed the JKS at the
# system path (the same location Jamf's .pkg payload uses); the installer
# only wires ~/.zshrc.
#
# Invariants exercised:
#   1. Positive install + validate (subject substring match)
#   2. Subject mismatch -> exit 1
#   3. Idempotent re-install (copied JKS checksum stable; .zshrc export replaced)
#   4. Missing JKS at the system path is rejected; Jamf's positional prefix
#      ($1=/ $2=computer $3=user) and blank script parameters 4-11 are ignored
#   5. --use-pkg is rejected (Jamf installs the .pkg; this script only wires env)
#   6. ~/.zshrc exports JAVA_TOOL_OPTIONS pointing at the installed JKS
#   7. --all-users iterates /Users/* and installs into every eligible account
#      (covers the iter_all_users filter + per-user chown contract)
#   8. Installed JKS preserves public roots from the bundled truststore
#   9. JAVA_TOOL_OPTIONS round-trips through JVM tokenizer

set -euo pipefail
fail_msg() { echo "BUG: $1" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: this test runner must be run as root. Use: sudo $0" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Identify the test user. CI calls `sudo ./test_install_certs_jvm_macos.sh`
# from an interactive account, so SUDO_USER is set; locally same. Fall back
# to the GUI console user for JAMF-style flows.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TEST_USER="$SUDO_USER"
else
    TEST_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
fi
if [[ -z "$TEST_USER" || "$TEST_USER" == "root" ]]; then
    fail_msg "cannot determine non-root test user (no SUDO_USER, no console user)"
fi

TEST_HOME="$(dscl . -read "/Users/${TEST_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -d "$TEST_HOME" ]] || fail_msg "home directory not found for $TEST_USER"
TEST_UID="$(id -u "$TEST_USER")"

JKS_DIR="/Library/Application Support/JFrog/package-route-jvm"
JKS="${JKS_DIR}/truststore.jks"
ZSHRC="${TEST_HOME}/.zshrc"
BUNDLE_JKS="/tmp/jvm-mac-bundled-truststore.jks"
ZSHRC_BACKUP=""

echo "Test user: $TEST_USER (uid=$TEST_UID, home=$TEST_HOME)"

# Preserve the developer's real .zshrc across the smoke run, then strip only
# the JAVA_TOOL_OPTIONS line we may have written during tests.
backup_zshrc() {
    if [[ -f "$ZSHRC" && -z "$ZSHRC_BACKUP" ]]; then
        ZSHRC_BACKUP="$(mktemp /tmp/jvm-mac-zshrc-backup.XXXXXX)"
        cp "$ZSHRC" "$ZSHRC_BACKUP"
    fi
}

restore_zshrc() {
    if [[ -n "$ZSHRC_BACKUP" && -f "$ZSHRC_BACKUP" ]]; then
        cp "$ZSHRC_BACKUP" "$ZSHRC"
        chown "$TEST_USER" "$ZSHRC" 2>/dev/null || true
        rm -f "$ZSHRC_BACKUP"
        ZSHRC_BACKUP=""
    elif [[ -f "$ZSHRC" ]]; then
        # No prior .zshrc existed; remove any JAVA_TOOL_OPTIONS we added, or
        # the empty file we created.
        if grep -qE '^export JAVA_TOOL_OPTIONS=' "$ZSHRC" 2>/dev/null; then
            local tmp
            tmp="$(mktemp)"
            grep -vE '^export JAVA_TOOL_OPTIONS=' "$ZSHRC" > "$tmp" || true
            if [[ -s "$tmp" ]]; then
                cat "$tmp" > "$ZSHRC"
            else
                rm -f "$ZSHRC"
            fi
            rm -f "$tmp"
            [[ -f "$ZSHRC" ]] && chown "$TEST_USER" "$ZSHRC" 2>/dev/null || true
        fi
    fi
}

strip_jto_from_zshrc() {
    if [[ -f "$ZSHRC" ]] && grep -qE '^export JAVA_TOOL_OPTIONS=' "$ZSHRC" 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"
        grep -vE '^export JAVA_TOOL_OPTIONS=' "$ZSHRC" > "$tmp" || true
        cat "$tmp" > "$ZSHRC"
        rm -f "$tmp"
        chown "$TEST_USER" "$ZSHRC" 2>/dev/null || true
    fi
}

cleanup() {
    rm -rf "$JKS_DIR"
    strip_jto_from_zshrc
}

final_cleanup() {
    cleanup
    restore_zshrc
    rm -f "$BUNDLE_JKS"
}
backup_zshrc
trap final_cleanup EXIT

# Pick an OpenSSL implementation that supports `-addext` reliably.
# macos-latest CI's default `openssl` is LibreSSL, which silently mis-handles
# -addext and emits PEM bytes keytool then rejects with "Input not an X.509
# certificate". Homebrew's openssl@3 is preinstalled on GHA macos-latest.
OPENSSL=""
for cand in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" version 2>/dev/null | grep -q '^OpenSSL '; then
        OPENSSL="$cand"
        break
    fi
done
[[ -n "$OPENSSL" ]] || fail_msg "no real OpenSSL on PATH (need OpenSSL 3.x; LibreSSL does not support -addext)"
echo "Using openssl: $OPENSSL ($("$OPENSSL" version))"

require_keytool() {
    command -v keytool >/dev/null 2>&1 || fail_msg "keytool not on PATH (validator/test fixture requires a JDK)"
}

build_bundle_truststore() {
    local ca_path="$1"
    rm -f "$BUNDLE_JKS"
    # Builder is keychain-only; inject the lab CA into the fixture so
    # --expected-subject stays deterministic on CI (no ZCC / enterprise CA).
    OPENSSL="$OPENSSL" ./build_jvm_truststore_macos.sh \
        --output "$BUNDLE_JKS" >/dev/null
    keytool -importcert -noprompt -storetype JKS \
        -alias "lab-jvm-mac-ca-test" \
        -file "$ca_path" \
        -keystore "$BUNDLE_JKS" \
        -storepass changeit >/dev/null
    echo "Bundled truststore fixture: $BUNDLE_JKS"
}

# Mimic Jamf installing the truststore package: payload already at JKS_PATH.
seed_installed_jks() {
    mkdir -p "$JKS_DIR"
    cp "$BUNDLE_JKS" "$JKS"
    chmod 0755 "$JKS_DIR"
    chmod 0644 "$JKS"
}

# Generate the lab CA used by all positive cases.
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout /tmp/jvm-mac-test-k.pem -out /tmp/jvm-mac-test-ca.pem -days 7 \
    -subj "/CN=Lab JVM mac CA Test/O=JFrog" \
    -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null

require_keytool
build_bundle_truststore /tmp/jvm-mac-test-ca.pem

# Capture combined stdout/stderr to a tempfile and only dump it on an
# *unexpected* exit. Negative tests need silence on the expected-fail path
# but diagnostic output when the installer surprises us. Keeps CI logs
# tight in the green-run case (the iteration-1 debug cycle showed how
# painful the silent-on-failure pattern is).
install_as_test_user() {
    # The `if cmd; then …; fi` pattern reports $?=0 of the if-statement, not
    # the command. `if ! cmd` also doesn't help (the `!` operator itself
    # returns 0). Reliable capture: pre-set rc=0 and use `cmd || rc=$?`.
    local log rc=0
    log="$(mktemp)"
    SUDO_USER="$TEST_USER" ./install_certs_jvm_macos.sh "$@" >"$log" 2>&1 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        rm -f "$log"
    else
        _LAST_LOG="$log"
    fi
    return "$rc"
}

validate_as_test_user() {
    local log rc=0
    log="$(mktemp)"
    SUDO_USER="$TEST_USER" ./validate_certs_jvm_macos.sh "$@" >"$log" 2>&1 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        rm -f "$log"
    else
        _LAST_LOG="$log"
    fi
    return "$rc"
}

dump_last_log() {
    [[ -n "${_LAST_LOG:-}" && -f "$_LAST_LOG" ]] || return 0
    echo "--- captured output ---"
    cat "$_LAST_LOG"
    echo "--- end captured output ---"
    rm -f "$_LAST_LOG"
    unset _LAST_LOG
}

get_zshrc_jto() {
    local line
    [[ -f "$ZSHRC" ]] || return 1
    line="$(grep -E '^export JAVA_TOOL_OPTIONS=' "$ZSHRC" | head -1 || true)"
    [[ -n "$line" ]] || return 1
    line="${line#export JAVA_TOOL_OPTIONS=}"
    if [[ "$line" == \'*\' ]]; then
        line="${line:1:${#line}-2}"
    elif [[ "$line" == \"*\" ]]; then
        line="${line:1:${#line}-2}"
        line="${line//\\\"/\"}"
        line="${line//\\\\/\\}"
    fi
    printf '%s' "$line"
}

# The export must source in zsh (nested unescaped "…" does not) and leave
# inner double quotes for the JVM tokenizer (single quotes do not group).
assert_zshrc_jto_sources() {
    local raw jto_from_zsh
    raw="$(grep -E '^export JAVA_TOOL_OPTIONS=' "$ZSHRC" | head -1 || true)"
    [[ -n "$raw" ]] || fail_msg ".zshrc missing export JAVA_TOOL_OPTIONS"
    [[ "$raw" == export\ JAVA_TOOL_OPTIONS=\'*\' ]] \
        || fail_msg "expected outer single quotes around JAVA_TOOL_OPTIONS (got: $raw)"
    jto_from_zsh="$(zsh -c "$raw"$'\n''print -r -- $JAVA_TOOL_OPTIONS' 2>&1)" \
        || fail_msg "zsh rejected JAVA_TOOL_OPTIONS export: $jto_from_zsh"
    case "$jto_from_zsh" in
        *"trustStore=\"${JKS}\""*) ;;
        *) fail_msg "after zsh source, JAVA_TOOL_OPTIONS missing inner double quotes around JKS (got: $jto_from_zsh)" ;;
    esac
}

#-----------------------------------------------------------------------------
echo
echo "=== 1. positive: install + validate ==="
cleanup
seed_installed_jks
# Positive cases let stdout through so a CI failure shows a useful log; only
# negative cases (where we *expect* exit 1) silence both streams.
SUDO_USER="$TEST_USER" ./install_certs_jvm_macos.sh
SUDO_USER="$TEST_USER" ./validate_certs_jvm_macos.sh --expected-subject "Lab JVM mac CA Test"
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 2. negative: subject mismatch must exit 1 ==="
if validate_as_test_user --expected-subject "Microsoft Root CA NoMatch"; then
    fail_msg "validator should have exited 1 on subject mismatch"
fi
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 3. idempotency: 2nd install preserves bundled JKS / single .zshrc export ==="
install_as_test_user
validate_as_test_user --expected-subject "Lab JVM mac CA Test"

bundle_sha="$(shasum -a 256 "$BUNDLE_JKS" | awk '{print $1}')"
installed_sha="$(shasum -a 256 "$JKS" | awk '{print $1}')"
[[ "$installed_sha" == "$bundle_sha" ]] || fail_msg "installed JKS checksum differs from bundled truststore"
alias_count=$(keytool -list -keystore "$JKS" -storepass changeit 2>/dev/null \
    | grep -c "trustedCertEntry" || true)
alias_count=${alias_count:-0}
[[ "$alias_count" -ge 100 ]] || fail_msg "expected JKS to include macOS system roots (>=100 aliases), got $alias_count"
jto_count=$(grep -cE '^export JAVA_TOOL_OPTIONS=' "$ZSHRC" || true)
[[ "$jto_count" -eq 1 ]] || fail_msg "expected exactly 1 JAVA_TOOL_OPTIONS export in .zshrc, got $jto_count"
jto="$(get_zshrc_jto)" || fail_msg ".zshrc missing export JAVA_TOOL_OPTIONS"
case "$jto" in
    *"trustStore=\"${JKS}\""*|*"trustStore=${JKS}"*) ;;
    *) fail_msg ".zshrc JAVA_TOOL_OPTIONS mismatch after re-install (got: $jto)" ;;
esac
assert_zshrc_jto_sources
echo "  ok (alias_count=$alias_count, sha=$installed_sha)"

#-----------------------------------------------------------------------------
echo
echo "=== 4. negative: missing JKS at system path is rejected ==="
cleanup
if install_as_test_user; then
    dump_last_log
    fail_msg "installer should have rejected a missing truststore at $JKS"
fi
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 4b. Jamf prefix args (\$1=/ \$2=computer \$3=user) succeed ==="
cleanup
seed_installed_jks
if ! install_as_test_user / "jamf-test-mac" "$TEST_USER"; then
    dump_last_log
    fail_msg "Jamf-style invocation with / computer user should succeed"
fi
validate_as_test_user --expected-subject "Lab JVM mac CA Test" || { dump_last_log; fail_msg "validate after Jamf-style install failed"; }
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 4c. Jamf blank script parameters 4-11 are ignored ==="
# Jamf hands every unset script parameter to the script as an empty string, so
# the parser must skip them instead of reporting "Unknown option: ".
cleanup
seed_installed_jks
if ! install_as_test_user / "jamf-test-mac" "$TEST_USER" "" "" "" "" "" "" "" ""; then
    dump_last_log
    fail_msg "Jamf-style invocation with blank trailing parameters should succeed"
fi
validate_as_test_user --expected-subject "Lab JVM mac CA Test" || { dump_last_log; fail_msg "validate after blank-parameter install failed"; }
if ! install_as_test_user / "jamf-test-mac" "" "" "" "" "" "" "" "" ""; then
    dump_last_log
    fail_msg "Jamf-style invocation with an empty user and blank parameters should succeed"
fi
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 5. negative: --use-pkg is rejected ==="
seed_installed_jks
if install_as_test_user --use-pkg /tmp/ignored.pkg; then
    dump_last_log
    fail_msg "installer should have rejected --use-pkg (Jamf installs the pkg; this script only wires env)"
fi
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 6. ~/.zshrc exports JAVA_TOOL_OPTIONS pointing at the installed JKS ==="
cleanup
seed_installed_jks
install_as_test_user
jto="$(get_zshrc_jto)" || fail_msg ".zshrc missing export JAVA_TOOL_OPTIONS"
case "$jto" in
    *"trustStore=\"${JKS}\""*|*"trustStore=${JKS}"*) ;;
    *) fail_msg ".zshrc JAVA_TOOL_OPTIONS mismatch (got: $jto)" ;;
esac
assert_zshrc_jto_sources
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 7. --all-users iterates eligible accounts ==="
cleanup
seed_installed_jks
# CI runners only have a single user (`runner`, uid 501). That's enough to
# verify iter_all_users does at least one iteration through the filter +
# per-user-chown path; multi-user is covered by the local dev Mac smoke.
# Run without SUDO_USER set so the installer takes the --all-users branch.
out="$(./install_certs_jvm_macos.sh --all-users 2>&1)"
echo "$out" | grep -q "=== User: ${TEST_USER}" \
    || { echo "$out" | tail -20; fail_msg "--all-users did not iterate ${TEST_USER}"; }
echo "$out" | grep -qE "Installed for [0-9]+ user\(s\)" \
    || { echo "$out" | tail -20; fail_msg "--all-users summary line missing"; }
# Per-user files should be owned by the target user (not root).
zshrc_owner="$(stat -f '%Su' "$ZSHRC")"
[[ "$zshrc_owner" == "$TEST_USER" ]] \
    || fail_msg ".zshrc owner=$zshrc_owner, expected $TEST_USER (chown failed silently?)"
echo "  ok"

#-----------------------------------------------------------------------------
# Re-install once so the next three invariants observe the final end state.
cleanup
seed_installed_jks
SUDO_USER="$TEST_USER" ./install_certs_jvm_macos.sh >/dev/null

echo
echo "=== 8. JKS extends bundled public roots ==="
# Regression guard for the "trustStore replaces, not extends" footgun.
# -Djavax.net.ssl.trustStore in OpenJDK swaps the JVM's trust source; a JKS
# holding only the corporate CA would break every public-CA TLS handshake
# (Maven Central, Gradle plugin portal, Let's Encrypt-fronted mirrors).
# The shipped bundle must therefore include public roots before install.
alias_count="$(keytool -list -keystore "$JKS" -storepass changeit 2>/dev/null | grep -c 'trustedCertEntry' || true)"
alias_count="${alias_count:-0}"
[[ "$alias_count" -ge 100 ]] \
    || fail_msg "JKS has $alias_count aliases; expected >= 100 (macOS system roots + corporate CA)"
echo "  ok ($alias_count aliases)"

echo
echo "=== 9. JKS contains a well-known public root (DigiCert family) ==="
# Spot-check the merge actually happened. DigiCert root certs ship in every
# macOS system trust bundle under several names; case-insensitive substring
# match catches the family.
keytool -list -v -keystore "$JKS" -storepass changeit 2>/dev/null \
    | grep -qi 'digicert' \
    || fail_msg "JKS missing the DigiCert family of public roots; the system-root bundle is incomplete"
echo "  ok"

echo
echo "=== 10. JAVA_TOOL_OPTIONS round-trips through JVM tokenizer ==="
# Direct repro of the "Application Support" space-tokenisation bug. Spawn a
# child java -version with the .zshrc export value and assert the JVM does
# NOT print "Unrecognized option" — that's what an unquoted trustStore path
# produced before the quoting fix.
jto_seen="$(get_zshrc_jto)" || fail_msg ".zshrc missing JAVA_TOOL_OPTIONS for tokenizer check"
java_out="$(JAVA_TOOL_OPTIONS="$jto_seen" java -version 2>&1 || true)"
if grep -q 'Unrecognized option' <<<"$java_out"; then
    printf '%s\n' "$java_out" | head -10
    echo "JTO seen: $jto_seen"
    fail_msg "java -version reported 'Unrecognized option' — JAVA_TOOL_OPTIONS tokenization is broken (likely missing inner quotes around the JKS path)"
fi
echo "  ok (java -version accepted JTO=$jto_seen)"

echo
echo "================================================================="
echo "ALL SMOKE TESTS PASSED"
echo "================================================================="
