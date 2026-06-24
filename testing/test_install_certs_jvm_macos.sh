#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Smoke matrix for install_certs_jvm_macos.sh + validate_certs_jvm_macos.sh.
#
# Run as root from the repo root (matches macos-latest CI usage):
#   sudo ./testing/test_install_certs_jvm_macos.sh
#
# Targets the SUDO_USER's per-user files. `cleanup` runs at the start of
# fresh-state cases and via `trap EXIT`. The test runner builds a bundled
# truststore fixture from the local JDK cacerts plus a lab CA, then verifies the
# installer only copies that ready-made JKS into place and configures launchd.
#
# Invariants exercised:
#   1. Positive install + validate (subject substring match)
#   2. Subject mismatch -> exit 1
#   3. Idempotent re-install (copied JKS checksum stable; plist replaced)
#   4. Missing --use-truststore is rejected
#   5. Missing / empty truststore paths are rejected
#   6. After bootstrap, launchctl getenv JAVA_TOOL_OPTIONS in gui/<uid> returns
#      the JKS path (skip on CI runners with no GUI session)
#   7. Plist content is well-formed XML and points at the expected JKS path
#      (covers the install path even when launchctl can't be verified)
#   8. --all-users iterates /Users/* and installs into every eligible account
#      (covers the iter_all_users filter + per-user chown contract)
#   9. Installed JKS preserves public roots from the bundled truststore
#  10. JAVA_TOOL_OPTIONS round-trips through JVM tokenizer

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
BUNDLE_JKS="/tmp/jvm-mac-bundled-truststore.jks"

echo "Test user: $TEST_USER (uid=$TEST_UID, home=$TEST_HOME)"

cleanup() {
    launchctl bootout "gui/${TEST_UID}/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST"
    rm -rf "$JKS_DIR"
    launchctl asuser "${TEST_UID}" launchctl unsetenv JAVA_TOOL_OPTIONS 2>/dev/null || true
    rm -f /tmp/jvm-mac-empty-truststore.jks
}

final_cleanup() {
    cleanup
    rm -f "$BUNDLE_JKS"
}
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

find_jdk_cacerts() {
    if [[ -n "${JAVA_HOME:-}" && -f "${JAVA_HOME}/lib/security/cacerts" ]]; then
        echo "${JAVA_HOME}/lib/security/cacerts"
        return 0
    fi

    if [[ -x /usr/libexec/java_home ]]; then
        local java_home_out
        java_home_out="$(/usr/libexec/java_home 2>/dev/null || true)"
        if [[ -n "$java_home_out" && -f "${java_home_out}/lib/security/cacerts" ]]; then
            echo "${java_home_out}/lib/security/cacerts"
            return 0
        fi
    fi

    local keytool_path resolved link
    keytool_path="$(command -v keytool 2>/dev/null || true)"
    if [[ -n "$keytool_path" ]]; then
        resolved="$keytool_path"
        local depth=0
        while [[ -L "$resolved" && $depth -lt 16 ]]; do
            link="$(readlink "$resolved")"
            if [[ "$link" = /* ]]; then
                resolved="$link"
            else
                resolved="$(dirname "$resolved")/$link"
            fi
            depth=$((depth + 1))
        done
        local keytool_dir
        keytool_dir="$(cd "$(dirname "$resolved")" 2>/dev/null && pwd -P)"
        if [[ -n "$keytool_dir" && -f "${keytool_dir}/../lib/security/cacerts" ]]; then
            echo "${keytool_dir}/../lib/security/cacerts"
            return 0
        fi
    fi

    fail_msg "cannot locate JDK cacerts for bundled truststore fixture"
}

build_bundle_truststore() {
    local ca_path="$1" src_cacerts
    src_cacerts="$(find_jdk_cacerts)"
    rm -f "$BUNDLE_JKS"
    cp "$src_cacerts" "$BUNDLE_JKS"
    chmod 0644 "$BUNDLE_JKS"
    keytool -importcert -noprompt \
        -alias package-route-custom-ca \
        -file "$ca_path" \
        -keystore "$BUNDLE_JKS" \
        -storepass changeit >/dev/null
    echo "Bundled truststore fixture: $BUNDLE_JKS (base: $src_cacerts)"
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

#-----------------------------------------------------------------------------
echo
echo "=== 1. positive: install + validate ==="
cleanup
# Positive cases let stdout through so a CI failure shows a useful log; only
# negative cases (where we *expect* exit 1) silence both streams.
SUDO_USER="$TEST_USER" ./install_certs_jvm_macos.sh --use-truststore "$BUNDLE_JKS"
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
echo "=== 3. idempotency: 2nd install preserves bundled JKS / single plist ==="
install_as_test_user --use-truststore "$BUNDLE_JKS"
validate_as_test_user --expected-subject "Lab JVM mac CA Test"

bundle_sha="$(shasum -a 256 "$BUNDLE_JKS" | awk '{print $1}')"
installed_sha="$(shasum -a 256 "$JKS" | awk '{print $1}')"
[[ "$installed_sha" == "$bundle_sha" ]] || fail_msg "installed JKS checksum differs from bundled truststore"
alias_count=$(keytool -list -keystore "$JKS" -storepass changeit 2>/dev/null \
    | grep -c "trustedCertEntry" || true)
alias_count=${alias_count:-0}
corp_count=$(keytool -list -keystore "$JKS" -storepass changeit 2>/dev/null \
    | grep -cE "^package-route-custom-ca[,[:space:]]" || true)
corp_count=${corp_count:-0}
[[ "$corp_count" -eq 1 ]] || fail_msg "expected exactly 1 corporate-CA alias after 2 installs, got $corp_count"
[[ "$alias_count" -ge 100 ]] || fail_msg "expected JKS to extend default cacerts (>=100 aliases), got $alias_count"
[[ -f "$PLIST" ]] || fail_msg "plist missing after 2nd install"
echo "  ok (alias_count=$alias_count, sha=$installed_sha)"

#-----------------------------------------------------------------------------
echo
echo "=== 4. negative: missing --use-truststore rejected ==="
if install_as_test_user; then
    dump_last_log
    fail_msg "installer should have rejected missing --use-truststore"
fi
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 5. negative: missing truststore path rejected ==="
if install_as_test_user --use-truststore /tmp/no-such-jvm-truststore.jks; then
    dump_last_log
    fail_msg "installer should have rejected missing truststore path"
fi
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 6. negative: empty truststore rejected ==="
: > /tmp/jvm-mac-empty-truststore.jks
if install_as_test_user --use-truststore /tmp/jvm-mac-empty-truststore.jks; then
    dump_last_log
    fail_msg "installer should have rejected empty truststore"
fi
echo "  ok"

#-----------------------------------------------------------------------------
echo
echo "=== 7. launchctl getenv JAVA_TOOL_OPTIONS in gui/<uid> ==="
cleanup
install_as_test_user --use-truststore "$BUNDLE_JKS"
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
echo "=== 8. plist is well-formed XML and points at the expected JKS ==="
# Reuses the install from step 7 (no cleanup). Independent of whether
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
echo "=== 9. --all-users iterates eligible accounts ==="
cleanup
# CI runners only have a single user (`runner`, uid 501). That's enough to
# verify iter_all_users does at least one iteration through the filter +
# per-user-chown path; multi-user is covered by the local dev Mac smoke.
# Run without SUDO_USER set so the installer takes the --all-users branch.
out="$(./install_certs_jvm_macos.sh --use-truststore "$BUNDLE_JKS" --all-users 2>&1)"
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
# Re-install once so the next three invariants observe the final end state.
cleanup
SUDO_USER="$TEST_USER" ./install_certs_jvm_macos.sh --use-truststore "$BUNDLE_JKS" >/dev/null

echo
echo "=== 10. JKS extends bundled public roots ==="
# Regression guard for the "trustStore replaces, not extends" footgun.
# -Djavax.net.ssl.trustStore in OpenJDK swaps the JVM's trust source; a JKS
# holding only the corporate CA would break every public-CA TLS handshake
# (Maven Central, Gradle plugin portal, Let's Encrypt-fronted mirrors).
# The shipped bundle must therefore include public roots before install.
alias_count="$(keytool -list -keystore "$JKS" -storepass changeit 2>/dev/null | grep -c 'trustedCertEntry' || true)"
alias_count="${alias_count:-0}"
[[ "$alias_count" -ge 100 ]] \
    || fail_msg "JKS has $alias_count aliases; expected >= 100 (JDK cacerts ~150 public roots + corporate CA)"
echo "  ok ($alias_count aliases)"

echo
echo "=== 11. JKS contains a well-known public root (DigiCert family) ==="
# Spot-check the merge actually happened. DigiCert root certs ship in every
# JDK's cacerts under several aliases (digicertglobalrootca, digicertglobalrootg2,
# digicerttrustedrootg4, etc.) — case-insensitive substring match catches them all.
keytool -list -keystore "$JKS" -storepass changeit 2>/dev/null \
    | grep -qi 'digicert' \
    || fail_msg "JKS missing the DigiCert family of public roots; the copy-from-JDK step did not run"
echo "  ok"

echo
echo "=== 12. JAVA_TOOL_OPTIONS round-trips through JVM tokenizer ==="
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
