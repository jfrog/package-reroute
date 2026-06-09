#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Smoke matrix for install_certs_jvm_macos.sh + validate_certs_jvm_macos.sh.
#
# Run as root from the repo root (matches macos-latest CI usage):
#   sudo ./testing/test_install_certs_jvm_macos.sh
#
# Targets the SUDO_USER's per-user files. `cleanup` runs at the start of
# cases 1, 4, 10, 11 (the positive / fresh-state cases) and via `trap EXIT`.
# Cases 2 (subject mismatch), 3 (idempotency), 5-8 (negative arg / cert),
# 9 (getenv) and 12 (validate_pem warns) deliberately reuse the prior install
# state because they assert behavior ON TOP of an installed system.
#
# Invariants exercised:
#   1. Positive install + validate (subject substring match)
#   2. Subject mismatch -> exit 1
#   3. Idempotent re-install (single JKS alias after 2 runs; plist replaced)
#   4. Custom --cert-name round-trips (alias inside JKS = cert-name)
#   5. Path-traversal --cert-name rejected
#   6. Malformed PEM rejected
#   7. Expired CA rejected (skip if openssl can't produce one verifiably-expired)
#   8. Leaf cert (CA:FALSE) rejected
#   9. After bootstrap, launchctl getenv JAVA_TOOL_OPTIONS in gui/<uid> returns
#      the JKS path (skip on CI runners with no GUI session)
#  10. Plist content is well-formed XML and points at the expected JKS path
#      (covers the install path even when launchctl can't be verified)
#  11. --all-users iterates /Users/* and installs into every eligible account
#      (covers the iter_all_users filter + per-user chown contract)
#  12. validate_pem warn paths: 30-day-expiry warn + multi-cert bundle warn

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

JKS="${TEST_HOME}/Library/Application Support/JFrog/package-route-jvm/truststore.jks"
JKS_DIR="${TEST_HOME}/Library/Application Support/JFrog/package-route-jvm"
PLIST="${TEST_HOME}/Library/LaunchAgents/com.jfrog.package-reroute.jto-env.plist"
LABEL="com.jfrog.package-reroute.jto-env"

echo "Test user: $TEST_USER (uid=$TEST_UID, home=$TEST_HOME)"

cleanup() {
    launchctl bootout "gui/${TEST_UID}/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST"
    rm -rf "$JKS_DIR"
    launchctl asuser "${TEST_UID}" launchctl unsetenv JAVA_TOOL_OPTIONS 2>/dev/null || true
}
trap cleanup EXIT

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

# Generate the lab CA used by all positive cases.
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout /tmp/jvm-mac-test-k.pem -out /tmp/jvm-mac-test-ca.pem -days 7 \
    -subj "/CN=Lab JVM mac CA Test/O=JFrog" \
    -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null

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

#-----------------------------------------------------------------------------
echo
echo "=== 1. positive: install + validate ==="
cleanup
# Positive cases let stdout through so a CI failure shows a useful log; only
# negative cases (where we *expect* exit 1) silence both streams.
SUDO_USER="$TEST_USER" ./install_certs_jvm_macos.sh --use-cert /tmp/jvm-mac-test-ca.pem
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
echo "=== 3. idempotency: 2nd install produces single alias / single plist ==="
install_as_test_user --use-cert /tmp/jvm-mac-test-ca.pem
validate_as_test_user --expected-subject "Lab JVM mac CA Test"

alias_count=$(keytool -list -keystore "$JKS" -storepass changeit 2>/dev/null \
    | grep -c "trustedCertEntry" || true)
alias_count=${alias_count:-0}
# JKS extends the JDK's bundled cacerts (~150 public roots) plus exactly one
# corporate-CA alias. After two installs, the corporate alias count must be
# exactly 1; the JDK-supplied aliases stay constant.
corp_count=$(keytool -list -keystore "$JKS" -storepass changeit 2>/dev/null \
    | grep -cE "^${CERT_BASENAME:-package-route-custom-ca}[,[:space:]]" || true)
corp_count=${corp_count:-0}
[[ "$corp_count" -eq 1 ]] || fail_msg "expected exactly 1 corporate-CA alias after 2 installs, got $corp_count"
[[ "$alias_count" -ge 100 ]] || fail_msg "expected JKS to extend default cacerts (>=100 aliases), got $alias_count"
[[ -f "$PLIST" ]] || fail_msg "plist missing after 2nd install"
echo "  ok (alias_count=$alias_count)"

#-----------------------------------------------------------------------------
echo
echo "=== 4. custom --cert-name round-trips (alias inside JKS = cert-name) ==="
cleanup
install_as_test_user --use-cert /tmp/jvm-mac-test-ca.pem --cert-name zscaler-root
keytool -list -keystore "$JKS" -storepass changeit 2>/dev/null \
    | grep -q "^zscaler-root," \
    || fail_msg "expected JKS alias 'zscaler-root' (got: $(keytool -list -keystore "$JKS" -storepass changeit 2>/dev/null | grep trustedCertEntry))"
validate_as_test_user --expected-subject "Lab JVM mac CA Test"
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 5. negative: path-traversal --cert-name rejected ==="
if install_as_test_user --use-cert /tmp/jvm-mac-test-ca.pem --cert-name '../etc/pwned'; then
    dump_last_log
    fail_msg "installer should have rejected path-traversal --cert-name"
fi
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 6. negative: malformed PEM rejected ==="
echo "not a certificate" > /tmp/jvm-mac-bad.pem
if install_as_test_user --use-cert /tmp/jvm-mac-bad.pem; then
    dump_last_log
    fail_msg "installer should have rejected malformed PEM"
fi
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 7. negative: expired CA rejected ==="
rm -f /tmp/jvm-mac-expired.pem
# Try OpenSSL 3.2+'s `-not_before / -not_after`; fall back to negative `-days`.
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout /tmp/jvm-mac-expired-k.pem -out /tmp/jvm-mac-expired.pem \
    -subj "/CN=Expired/O=JFrog" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -not_before 20200101000000Z -not_after 20200201000000Z 2>/dev/null \
|| "$OPENSSL" x509 -req -in <("$OPENSSL" req -new -key /tmp/jvm-mac-test-k.pem -subj "/CN=Expired") \
       -signkey /tmp/jvm-mac-test-k.pem -days -1 -out /tmp/jvm-mac-expired.pem 2>/dev/null \
|| true

if [[ ! -f /tmp/jvm-mac-expired.pem ]] || "$OPENSSL" x509 -in /tmp/jvm-mac-expired.pem -checkend 0 -noout >/dev/null 2>&1; then
    echo "  SKIP: cannot produce a verifiably expired cert with the installed openssl ($(openssl version))"
else
    if install_as_test_user --use-cert /tmp/jvm-mac-expired.pem; then
        dump_last_log
        fail_msg "installer should have rejected expired CA"
    fi
    echo "  ok"
fi

#-----------------------------------------------------------------------------
echo
echo "=== 8. negative: leaf cert (CA:FALSE) rejected ==="
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout /tmp/jvm-mac-leaf-k.pem -out /tmp/jvm-mac-leaf.pem -days 7 \
    -subj "/CN=Leaf Not CA" \
    -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
if install_as_test_user --use-cert /tmp/jvm-mac-leaf.pem; then
    dump_last_log
    fail_msg "installer should have rejected leaf cert (CA:FALSE)"
fi
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 9. launchctl getenv JAVA_TOOL_OPTIONS in gui/<uid> ==="
cleanup
install_as_test_user --use-cert /tmp/jvm-mac-test-ca.pem
if launchctl print "gui/${TEST_UID}" >/dev/null 2>&1; then
    # Mirror the installer's 20x100ms retry: bootstrap returns the moment
    # the agent is loaded, but the launchctl-setenv ProgramArguments runs
    # asynchronously. Without a retry the assertion would flake on GUI
    # runners under load.
    jto=""
    # 20 retries × 100ms = ~2s total — mirrors installer's bootstrap_launch_agent
    # to cover the async-setenv window even under EDR load.
    # shellcheck disable=SC2034
    for _i in $(seq 1 20); do
        jto="$(launchctl asuser "${TEST_UID}" launchctl getenv JAVA_TOOL_OPTIONS 2>/dev/null || true)"
        [[ -n "$jto" ]] && break
        sleep 0.1
    done
    # Accept both quoted and unquoted forms. The post-fix installer writes
    # the quoted form so JVM tokenization handles the "Application Support"
    # space; older installs left it unquoted.
    case "$jto" in
        *"trustStore=\"${JKS}\""*|*"trustStore=${JKS}"*) echo "  ok" ;;
        *) fail_msg "launchctl getenv mismatch (got: $jto)" ;;
    esac
else
    echo "  SKIP: gui/${TEST_UID} not active (CI runner with no GUI session is fine — plist will load at login)"
fi

#-----------------------------------------------------------------------------
echo
echo "=== 10. plist is well-formed XML and points at the expected JKS ==="
# Reuses the install from step 9 (no cleanup). Independent of whether
# launchctl bootstrap succeeded — validates the write_launch_agent_plist
# code path even on headless CI runners.
plutil -lint "$PLIST" >/dev/null
# Confirm the JTO value inside the plist actually references the expected
# JKS path. plutil -extract pulls the 4th element of ProgramArguments
# (index 3) which is the `-Djavax.net.ssl.trustStore=… …` arg string.
jto_in_plist="$(plutil -extract ProgramArguments.3 raw "$PLIST" 2>/dev/null)"
case "$jto_in_plist" in
    *"trustStore=\"${JKS}\""*|*"trustStore=${JKS}"*) echo "  ok" ;;
    *) fail_msg "plist JTO arg doesn't point at $JKS (got: $jto_in_plist)" ;;
esac

#-----------------------------------------------------------------------------
echo
echo "=== 11. --all-users iterates eligible accounts ==="
cleanup
# CI runners only have a single user (`runner`, uid 501). That's enough to
# verify iter_all_users does at least one iteration through the filter +
# per-user-chown path; multi-user is covered by the local dev Mac smoke.
# Run without SUDO_USER set so the installer takes the --all-users branch.
out="$(./install_certs_jvm_macos.sh --use-cert /tmp/jvm-mac-test-ca.pem --all-users 2>&1)"
echo "$out" | grep -q "=== User: ${TEST_USER}" \
    || { echo "$out" | tail -20; fail_msg "--all-users did not iterate ${TEST_USER}"; }
echo "$out" | grep -qE "Installed for [0-9]+ user\(s\)" \
    || { echo "$out" | tail -20; fail_msg "--all-users summary line missing"; }
# Per-user files should be owned by the target user (not root).
plist_owner="$(stat -f '%Su' "$PLIST")"
[[ "$plist_owner" == "$TEST_USER" ]] \
    || fail_msg "plist owner=$plist_owner, expected $TEST_USER (chown failed silently?)"
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 12. validate_pem warn paths: 30-day-expiry + bundle ==="
# Short-validity CA (1 day) — within 30 days, should produce the expiry warn
# but install succeed.
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout /tmp/jvm-mac-soon-k.pem -out /tmp/jvm-mac-soon.pem -days 1 \
    -subj "/CN=Soon to Expire/O=JFrog" \
    -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
out="$(SUDO_USER="$TEST_USER" ./install_certs_jvm_macos.sh --use-cert /tmp/jvm-mac-soon.pem 2>&1)"
echo "$out" | grep -q "certificate expires within 30 days" \
    || { echo "$out" | tail -20; fail_msg "30-day expiry warn missing"; }

# Multi-cert bundle: append a second cert to the test CA. The installer
# warns and imports only the first; install must still succeed.
cat /tmp/jvm-mac-test-ca.pem /tmp/jvm-mac-soon.pem > /tmp/jvm-mac-bundle.pem
out="$(SUDO_USER="$TEST_USER" ./install_certs_jvm_macos.sh --use-cert /tmp/jvm-mac-bundle.pem 2>&1)"
echo "$out" | grep -qE "PEM file contains [0-9]+ certificates" \
    || { echo "$out" | tail -20; fail_msg "multi-cert bundle warn missing"; }
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 13. negative: missing keytool fails cleanly ==="
# I3 cross-platform parity: build an isolated bin/ containing symlinks to
# every /usr/bin and /bin tool EXCEPT keytool, plus openssl from its real
# location. Then run the installer with PATH=<isolated bin>. macOS-latest
# CI has /usr/bin/keytool from the Apple-bundled JavaAppletPlugin, and
# setup-java prepends $JAVA_HOME/bin — neither survives this isolated PATH.
nokey_bin="$(mktemp -d)"
for d in /usr/bin /bin /usr/sbin /sbin; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
        base="$(basename "$f")"
        [[ "$base" == keytool ]] && continue
        ln -sf "$f" "$nokey_bin/$base" 2>/dev/null || true
    done
done
# openssl may live outside /usr/bin (Homebrew on macOS GHA puts it in
# /opt/homebrew/bin). Ensure the isolated bin can find a working openssl.
ln -sf "$OPENSSL" "$nokey_bin/openssl" 2>/dev/null || true
if ! "$nokey_bin/openssl" version >/dev/null 2>&1; then
    rm -rf "$nokey_bin"
    fail_msg "isolated bin missing openssl — cannot exercise missing-keytool path"
fi
if [[ -e "$nokey_bin/keytool" ]] || env -i PATH="$nokey_bin" command -v keytool >/dev/null 2>&1; then
    rm -rf "$nokey_bin"
    fail_msg "isolated bin still has keytool — test setup broken"
fi
if env -i PATH="$nokey_bin" HOME="$HOME" SUDO_USER="$TEST_USER" ./install_certs_jvm_macos.sh --use-cert /tmp/jvm-mac-test-ca.pem >/tmp/jvm-mac-nokey.out 2>&1; then
    cat /tmp/jvm-mac-nokey.out | head -20
    rm -rf "$nokey_bin"
    fail_msg "installer should have rejected missing keytool"
fi
if ! grep -q -i keytool /tmp/jvm-mac-nokey.out; then
    cat /tmp/jvm-mac-nokey.out | head -10
    rm -rf "$nokey_bin"
    fail_msg "missing-keytool error message should mention 'keytool'"
fi
rm -rf "$nokey_bin"
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 14. negative: DER cert rejected (C1 cross-platform parity) ==="
# C1 backport: convert the lab CA to DER, then attempt install — should
# fail with a hint to convert back. Mirrors Linux + Windows behavior.
"$OPENSSL" x509 -in /tmp/jvm-mac-test-ca.pem -outform DER -out /tmp/jvm-mac-test-ca.der 2>/dev/null
if SUDO_USER="$TEST_USER" ./install_certs_jvm_macos.sh --use-cert /tmp/jvm-mac-test-ca.der >/tmp/jvm-mac-der.out 2>&1; then
    cat /tmp/jvm-mac-der.out | head -10
    fail_msg "installer should have rejected DER-encoded cert"
fi
grep -q -i "PEM-encoded" /tmp/jvm-mac-der.out \
    || { cat /tmp/jvm-mac-der.out | head -10; fail_msg "DER reject message should mention 'PEM-encoded'"; }
echo "  ok"

#-----------------------------------------------------------------------------
# Re-install once so the next three invariants observe the post-fix end state.
cleanup
SUDO_USER="$TEST_USER" ./install_certs_jvm_macos.sh --use-cert /tmp/jvm-mac-test-ca.pem >/dev/null

echo
echo "=== 15. JKS extends default cacerts (preserves public roots) ==="
# Regression guard for the "trustStore replaces, not extends" footgun.
# -Djavax.net.ssl.trustStore in OpenJDK swaps the JVM's trust source; a JKS
# holding only the corporate CA would break every public-CA TLS handshake
# (Maven Central, Gradle plugin portal, Let's Encrypt-fronted mirrors).
# Installer must therefore cp $JAVA_HOME/lib/security/cacerts first.
alias_count="$(keytool -list -keystore "$JKS" -storepass changeit 2>/dev/null | grep -c 'trustedCertEntry' || true)"
alias_count="${alias_count:-0}"
[[ "$alias_count" -ge 100 ]] \
    || fail_msg "JKS has $alias_count aliases; expected >= 100 (JDK cacerts ~150 public roots + corporate CA)"
echo "  ok ($alias_count aliases)"

echo
echo "=== 16. JKS contains a well-known public root (DigiCert family) ==="
# Spot-check the merge actually happened. DigiCert root certs ship in every
# JDK's cacerts under several aliases (digicertglobalrootca, digicertglobalrootg2,
# digicerttrustedrootg4, etc.) — case-insensitive substring match catches them all.
keytool -list -keystore "$JKS" -storepass changeit 2>/dev/null \
    | grep -qi 'digicert' \
    || fail_msg "JKS missing the DigiCert family of public roots; the copy-from-JDK step did not run"
echo "  ok"

echo
echo "=== 17. JAVA_TOOL_OPTIONS round-trips through JVM tokenizer ==="
# Direct repro of the "Application Support" space-tokenisation bug. Spawn a
# child java -version with the LaunchAgent's env var and assert the JVM
# does NOT print "Unrecognized option" — that's what an unquoted trustStore
# path produced before the fix.
jto_seen="$(launchctl asuser "$TEST_UID" launchctl getenv JAVA_TOOL_OPTIONS 2>/dev/null || true)"
if [[ -z "$jto_seen" ]]; then
    echo "  SKIP: gui/$TEST_UID is not active (no logged-in GUI session) — cannot exercise the tokenizer round-trip"
else
    java_out="$(JAVA_TOOL_OPTIONS="$jto_seen" java -version 2>&1 || true)"
    if grep -q 'Unrecognized option' <<<"$java_out"; then
        printf '%s\n' "$java_out" | head -10
        echo "JTO seen: $jto_seen"
        fail_msg "java -version reported 'Unrecognized option' — JAVA_TOOL_OPTIONS tokenization is broken (likely missing inner quotes around the JKS path)"
    fi
    echo "  ok (java -version accepted JTO=$jto_seen)"
fi

echo
echo "================================================================="
echo "ALL SMOKE TESTS PASSED"
echo "================================================================="
