#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Install a bundled JVM truststore on macOS for JVM clients (Maven, Gradle,
# sbt, Apache Ivy).
#
# Single path: copy a supplied JKS truststore to
#   ~/Library/Application Support/JFrog/package-route-jvm/truststore.jks
# then install a per-user LaunchAgent at
#   ~/Library/LaunchAgents/com.jfrog.package-reroute.jto-env.plist
# that runs `launchctl setenv JAVA_TOOL_OPTIONS=…` at RunAtLoad. This is the
# ONLY recipe that reaches Dock-launched IDE builds — the ~/.zshrc shortcut
# silently fails for GUI-spawned subprocesses, and macOS-specific
# KeychainStore is broken per JDK-8321045.
#
# Run:
#   sudo bash install_certs_jvm_macos.sh --use-truststore /path/to/truststore.jks
#       [--all-users]
#
# Notes:
#   - macOS only.
#   - Must run as root (so per-user files can be chown'd to the target user).
#   - JVM trust only — does not configure npm/Python/HF and does not touch
#     Docker credentials. Pair with install_certs_macos.sh if you need those.
#   - Existing Dock-launched apps must be restarted after install: macOS does
#     not re-poll the launchd domain env on app relaunch unless the agent
#     was bootstrapped before app launch.
#   - JAMF / kiosk caveat: gui/<uid> is the GUI-session launchd domain. On a
#     host with NO user logged in (mac-mini in a rack, fresh JAMF bootstrap
#     before first login), `launchctl bootstrap gui/<uid>` either fails or
#     loads into a non-running domain. In that case the agent loads on next
#     interactive login. Operators provisioning headless machines should
#     also seed the JKS via a separate non-GUI mechanism (e.g. system-wide
#     /Library/LaunchDaemons running as root) before any user logs in.
#
# Cross-platform siblings (keep CLI shapes and contracts in sync):
#   install_certs_jvm_linux.sh       — update-ca-trust OR JKS+JAVA_TOOL_OPTIONS
#   install_certs_jvm_windows.ps1    — HKCU\Environment + per-user JKS
#
# Research / rationale: see the JVM client-onboarding wiki page
#   https://jfrog-int.atlassian.net/wiki/spaces/RTFACT/pages/2440101931/

set -euo pipefail

# Keep this installer self-contained: it is often copied/run as a standalone
# script during onboarding, so avoid requiring sibling files for constants.
JKS_RELATIVE_DIR="Library/Application Support/JFrog/package-route-jvm"
JKS_BASENAME="truststore.jks"
LAUNCH_AGENT_RELATIVE_DIR="Library/LaunchAgents"
LAUNCH_AGENT_LABEL="com.jfrog.package-reroute.jto-env"
LAUNCH_AGENT_BASENAME="${LAUNCH_AGENT_LABEL}.plist"
JKS_PASSWORD="changeit"

USE_TRUSTSTORE=""
ALL_USERS=0

usage() {
    cat <<EOF
Usage:
  sudo $0 --use-truststore <path> [--all-users]

Options:
  --use-truststore <path>
                         Path to an existing JVM truststore (JKS/PKCS12-compatible)
                         to copy into each target user's fixed JKS location.
                         The truststore must be readable by JVMs with password
                         '${JKS_PASSWORD}'.
  --all-users            Iterate /Users/* (UID >= 501, skip Shared) and install
                         a LaunchAgent + JKS for every account. Default = only
                         SUDO_USER (or the console-user under JAMF).
  -h, --help             Show this help.

Note: unlike the Linux sibling, macOS has only one install path (JKS +
per-user LaunchAgent setting JAVA_TOOL_OPTIONS). There is no --mode flag
because the KeychainStore truststoreType is broken (JDK-8321045) and no
OS-trust fallback exists.

Examples:
  sudo $0 --use-truststore /tmp/package-route-truststore.jks
  sudo $0 --use-truststore /tmp/package-route-truststore.jks --all-users
EOF
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Error: this script must be run as root." >&2
        echo "Use: sudo $0 --use-truststore <path> [--all-users]" >&2
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --use-truststore)
                USE_TRUSTSTORE="${2:?Error: --use-truststore requires a value}"
                shift 2
                ;;
            --all-users)
                ALL_USERS=1
                shift
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

    if [[ -z "$USE_TRUSTSTORE" ]]; then
        echo "Error: --use-truststore is required." >&2
        usage >&2
        exit 1
    fi

    if [[ ! -f "$USE_TRUSTSTORE" ]]; then
        echo "Error: truststore file not found: $USE_TRUSTSTORE" >&2
        exit 1
    fi

    if [[ ! -r "$USE_TRUSTSTORE" ]]; then
        echo "Error: truststore file is not readable: $USE_TRUSTSTORE" >&2
        exit 1
    fi

    if [[ ! -s "$USE_TRUSTSTORE" ]]; then
        echo "Error: truststore file is empty: $USE_TRUSTSTORE" >&2
        exit 1
    fi
}

check_os() {
    local os
    os="$(uname -s)"
    if [[ "$os" != "Darwin" ]]; then
        echo "Error: this script supports macOS only (detected: $os)." >&2
        exit 1
    fi
}

jks_path_for_user() {
    local user_home="$1"
    echo "${user_home}/${JKS_RELATIVE_DIR}/${JKS_BASENAME}"
}

install_truststore_for_user() {
    local target_user="$1" user_home="$2"
    local jks_dir="${user_home}/${JKS_RELATIVE_DIR}"
    local jks_path="${jks_dir}/${JKS_BASENAME}"

    echo "  [JKS] Installing truststore at $jks_path"

    # macOS mkdir -p will create the intermediate "Application Support" /
    # "JFrog" / "package-route-jvm" tree if missing. Quote the path because
    # "Application Support" contains a space.
    mkdir -p "$jks_dir"

    # The installer deliberately treats the supplied truststore as final. The
    # release process that builds it owns root selection and CA contents.
    cp "$USE_TRUSTSTORE" "$jks_path"

    chmod 0755 "$jks_dir"
    chmod 0644 "$jks_path"

    # Hand ownership back to the target user so they (and their LaunchAgent
    # running in gui/<uid>) can read it without needing sudo to manage it.
    # A silent chown failure would leave root-owned files in $target_user's
    # home — launchd refuses to load root-owned LaunchAgents, so the install
    # would appear to succeed and never activate.
    local chown_err
    if ! chown_err="$(chown -R "$target_user" "$jks_dir" 2>&1)"; then
        echo "Error: chown $target_user $jks_dir failed: $chown_err" >&2
        exit 1
    fi

    echo "  [JKS] OK"
}

# Determine the single non-root target user when --all-users is NOT set.
# Fallback order matches install_certs_macos.sh:314-328: SUDO_USER first,
# then /dev/console owner (the JAMF / GUI-elevated case), then `logname` as a
# last resort. `loginwindow` is the special user that owns /dev/console at
# the login screen — must be filtered or we'd install into a non-account.
get_single_target_user() {
    local candidate

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        candidate="$SUDO_USER"
    else
        candidate="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
        if [[ -z "$candidate" || "$candidate" == "root" || "$candidate" == "loginwindow" ]]; then
            candidate="$(logname 2>/dev/null || true)"
        fi
    fi

    if [[ -z "$candidate" || "$candidate" == "root" || "$candidate" == "loginwindow" ]]; then
        return 0
    fi

    # Reject users that don't exist on the box.
    if ! id -u "$candidate" >/dev/null 2>&1; then
        return 0
    fi

    echo "$candidate"
}

get_user_home() {
    local user="$1"
    # `dscl . -read /Users/$user NFSHomeDirectory` is the macOS canonical
    # source of truth (passwd is a synthetic view). Fall back to dscacheutil
    # if dscl is unavailable (sandboxed CI images, OpenDirectory hiccups).
    # Avoid `eval echo "~$user"` — even with the upstream id-validation it
    # makes the next maintainer's eyes water and would be unsafe if the
    # validation is ever loosened.
    local home
    home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    if [[ -z "$home" ]] && command -v dscacheutil >/dev/null 2>&1; then
        home="$(dscacheutil -q user -a name "$user" 2>/dev/null | awk '/^dir:/ {print $2}')"
    fi
    echo "$home"
}

launch_agent_path_for_user() {
    local user_home="$1"
    echo "${user_home}/${LAUNCH_AGENT_RELATIVE_DIR}/${LAUNCH_AGENT_BASENAME}"
}

# XML-escape a single value to make it safe inside a <string>…</string> node.
# JKS paths contain spaces ("Application Support") but spaces in XML text are
# fine; the only chars that must be escaped are &, <, >.
plist_xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    # `"` inside <string> PCDATA is technically valid XML, but we escape it
    # for defence-in-depth: the JTO value embeds literal `"` chars to quote
    # the trustStore path against JVM whitespace tokenisation, and plutil
    # versions on older macOS releases have been finicky about unescaped
    # quotes inside <string>. Escaping is safe across plist consumers.
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

write_launch_agent_plist() {
    local target_user="$1" user_home="$2"
    local plist_path
    plist_path="$(launch_agent_path_for_user "$user_home")"
    local plist_dir
    plist_dir="$(dirname "$plist_path")"

    local jks_path
    jks_path="$(jks_path_for_user "$user_home")"

    # The JKS path is under ~/Library/Application Support/ — the embedded
    # space breaks unquoted JAVA_TOOL_OPTIONS at the JVM tokenizer (which
    # splits on whitespace and only honours `"…"` grouping). Without these
    # inner quotes a Dock-launched JVM sees two tokens, the second of which
    # starts with `Support/…` and aborts with "Unrecognized option". The
    # plist <string> carries the value verbatim through launchctl setenv,
    # so the literal quote characters reach the JVM tokenizer and correctly
    # group the path. plist_xml_escape converts `"` → `&quot;` for the XML.
    local jto_value="-Djavax.net.ssl.trustStore=\"${jks_path}\" -Djavax.net.ssl.trustStorePassword=\"${JKS_PASSWORD}\""
    local jto_escaped
    jto_escaped="$(plist_xml_escape "$jto_value")"

    local uid
    uid="$(id -u "$target_user")"
    local log_out="/tmp/${LAUNCH_AGENT_LABEL}-${uid}.out.log"
    local log_err="/tmp/${LAUNCH_AGENT_LABEL}-${uid}.err.log"

    echo "  [Agent] Writing plist: $plist_path"

    mkdir -p "$plist_dir"

    # Atomic write via mktemp + mv in the same directory so a half-written
    # plist can never be picked up by launchd.
    local tmp
    tmp="$(mktemp "${plist_dir}/.${LAUNCH_AGENT_BASENAME}.XXXXXX")"
    cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/launchctl</string>
        <string>setenv</string>
        <string>JAVA_TOOL_OPTIONS</string>
        <string>${jto_escaped}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${log_out}</string>
    <key>StandardErrorPath</key>
    <string>${log_err}</string>
</dict>
</plist>
PLIST

    # plutil -lint catches XML / schema errors before launchd ever sees the file.
    if ! plutil -lint "$tmp" >/dev/null 2>&1; then
        local lint_err
        lint_err="$(plutil -lint "$tmp" 2>&1 || true)"
        rm -f "$tmp"
        echo "Error: generated LaunchAgent plist failed plutil -lint: $lint_err" >&2
        exit 1
    fi

    mv "$tmp" "$plist_path"
    chmod 0644 "$plist_path"

    # launchd refuses to load LaunchAgents owned by root in ~/Library/LaunchAgents/,
    # so a silent chown failure here turns the install into a phantom success.
    local chown_err
    if ! chown_err="$(chown "$target_user" "$plist_dir" "$plist_path" 2>&1)"; then
        echo "Error: chown $target_user $plist_path failed: $chown_err" >&2
        exit 1
    fi

    echo "  [Agent] OK"
}

bootstrap_launch_agent() {
    local target_user="$1" user_home="$2"
    local plist_path
    plist_path="$(launch_agent_path_for_user "$user_home")"
    local uid
    uid="$(id -u "$target_user")"
    local domain="gui/${uid}"

    # `gui/<uid>` exists only while the user is logged into a GUI session.
    # Under --all-users this is normally false for everyone except the
    # currently-logged-in account. The plist we already wrote into
    # ~/Library/LaunchAgents/ is loaded automatically by launchd when the
    # user next logs in (RunAtLoad=true), so a missing domain is a soft-fail.
    if ! launchctl print "$domain" >/dev/null 2>&1; then
        echo "  [Agent] $target_user is not in an active GUI session; skipping bootstrap."
        echo "  [Agent] Plist is installed at $plist_path and will activate at next login."
        return 0
    fi

    echo "  [Agent] launchctl bootout (in case already loaded; expected to fail on a fresh install)"
    # `launchctl bootout` returns non-zero when the agent isn't loaded yet.
    # That's the normal first-run case; swallow it.
    launchctl bootout "$domain" "$plist_path" 2>/dev/null || true

    echo "  [Agent] launchctl bootstrap $domain"
    local bootstrap_err
    if ! bootstrap_err="$(launchctl bootstrap "$domain" "$plist_path" 2>&1)"; then
        echo "  [Agent] [warn] launchctl bootstrap failed for $domain: $bootstrap_err" >&2
        echo "                Plist is installed at $plist_path and will activate at next login." >&2
        return 0
    fi

    # Sanity-check that setenv actually fired. `launchctl bootstrap` blocks
    # until the agent is *loaded* but the ProgramArguments exec
    # (`launchctl setenv …`) runs asynchronously after load. Under a quiet
    # box this is microseconds; under EDR agents (CrowdStrike, Spotlight
    # mid-index, Time Machine) the exec latency can climb past a second.
    # Retry up to ~2s (20 × 100ms) so a perfectly-healthy install doesn't
    # produce a misleading warn under load.
    local seen attempt
    for attempt in $(seq 1 20); do
        seen="$(launchctl asuser "$uid" launchctl getenv JAVA_TOOL_OPTIONS 2>/dev/null || true)"
        [[ -n "$seen" ]] && break
        sleep 0.1
    done

    if [[ -z "$seen" ]]; then
        # The env var IS set in the plist on disk and the agent IS loaded.
        # We just couldn't observe the launchctl-setenv side-effect inside
        # our retry window. Surface that without suggesting a logout/login
        # dance the user almost certainly doesn't need.
        echo "  [Agent] [warn] JAVA_TOOL_OPTIONS not observable via launchctl getenv within 2s." >&2
        echo "                Plist is loaded; re-run validate_certs_jvm_macos.sh in a few seconds" >&2
        echo "                to confirm, or open a new Terminal and check \$JAVA_TOOL_OPTIONS." >&2
    else
        echo "  [Agent] launchctl getenv JAVA_TOOL_OPTIONS confirms the value reached gui/${uid}"
    fi
}

install_for_user() {
    local target_user="$1" user_home="$2"

    echo "=== User: $target_user (home: $user_home) ==="
    install_truststore_for_user "$target_user" "$user_home"
    write_launch_agent_plist "$target_user" "$user_home"
    bootstrap_launch_agent  "$target_user" "$user_home"

    echo "  Truststore:  $(jks_path_for_user "$user_home")"
    echo "  LaunchAgent: $(launch_agent_path_for_user "$user_home")"
}

# Outputs `username\thome_dir` lines for every /Users/* directory that
# represents a real account with UID >= 501.
#
# Stricter filter than install_certs_macos.sh:256-261 (which skips only
# /Users/Shared and UID < 501): also skips .localized, and rejects
# directories whose owning user no longer exists in dscl (stale home dirs
# left behind by deleted accounts would otherwise crash chown/launchctl).
iter_all_users() {
    local dir base uid
    for dir in /Users/*; do
        [[ -d "$dir" ]] || continue
        base="$(basename "$dir")"
        [[ "$base" == "Shared" || "$base" == ".localized" ]] && continue
        uid="$(stat -f '%u' "$dir" 2>/dev/null || true)"
        [[ -n "$uid" && "$uid" -ge 501 ]] || continue
        # Reject stale home dirs whose owning user no longer exists in dscl.
        id -u "$base" >/dev/null 2>&1 || continue
        printf '%s\t%s\n' "$base" "$dir"
    done
}

print_caveats() {
    cat <<EOF

Notes:
  - The LaunchAgent runs in gui/<uid> per installed user. New launchd-spawned
    processes (Dock-launched IntelliJ, JetBrains Toolbox, 'open -a …') inherit
    JAVA_TOOL_OPTIONS automatically.
  - Apps that were ALREADY running before the install must be restarted to pick
    up the new env var (LaunchServices does not re-poll the launchd domain on
    Cmd-Tab).
  - Run 'gradle --stop' to refresh the Gradle Daemon if one was already running.
  - The 'Picked up JAVA_TOOL_OPTIONS:' banner on stderr is expected.
EOF
}

main() {
    require_root
    parse_args "$@"
    check_os

    if [[ "$ALL_USERS" -eq 1 ]]; then
        local iter_count=0 user home
        while IFS=$'\t' read -r user home; do
            echo
            install_for_user "$user" "$home"
            iter_count=$((iter_count + 1))
        done < <(iter_all_users)

        if [[ "$iter_count" -eq 0 ]]; then
            echo "Error: --all-users found no eligible accounts under /Users/* (UID >= 501)." >&2
            exit 1
        fi

        echo
        echo "Installed for $iter_count user(s)."
        print_caveats
        return 0
    fi

    local target_user user_home
    target_user="$(get_single_target_user)"
    if [[ -z "$target_user" ]]; then
        echo "Error: could not determine non-root target user." >&2
        echo "       Set SUDO_USER or invoke via sudo from the developer account," >&2
        echo "       or pass --all-users to iterate every eligible account." >&2
        exit 1
    fi
    user_home="$(get_user_home "$target_user")"
    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        echo "Error: home directory not found for $target_user." >&2
        exit 1
    fi

    echo
    install_for_user "$target_user" "$user_home"
    print_caveats
}

main "$@"
