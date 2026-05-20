#!/usr/bin/env bash
# (c) JFrog Ltd. (2026)
# Install a custom CA certificate on Linux for JVM clients (Maven, Gradle, sbt,
# Apache Ivy). Two paths depending on distro + JDK distribution:
#
#   Path A — RHEL/Fedora/CentOS/Amazon-Linux + Red Hat OpenJDK:
#     Drop the cert into /etc/pki/ca-trust/source/anchors/ and run
#     update-ca-trust extract. Red Hat's OpenJDK symlinks its cacerts to the
#     system-managed copy, so system trust IS Java trust.
#
#   Path B — everything else (Debian/Ubuntu, Amazon Corretto, Eclipse Temurin,
#     SDKMAN-installed JDKs, manual .tar.gz installs):
#     Build a JKS truststore at /etc/ssl/package-route-jvm/truststore.jks
#     containing the customer CA and set JAVA_TOOL_OPTIONS in /etc/environment
#     so every JDK on the box picks it up at startup.
#
# Run:
#   sudo bash install_certs_jvm_linux.sh --use-cert /path/to/cert.pem
#       [--mode auto|java-tool-options|update-ca-trust] [--cert-name <name>]
#
# Notes:
#   - Linux only (Debian/Ubuntu and RHEL/Fedora/CentOS/Amazon-Linux families).
#   - Must run as root.
#   - JVM trust only — does not configure npm/Python/HF and does not touch
#     Docker credentials. Pair with install_certs_debian_ubuntu.sh if needed.
#   - GUI-launched IDEs need a logoff/login to pick up /etc/environment.
#
# Cross-platform siblings (keep CLI shapes and contracts in sync):
#   install_certs_jvm_macos.sh       — LaunchAgent + per-user JKS
#   install_certs_jvm_windows.ps1    — HKCU\Environment + per-user JKS
#
# Research / rationale: see the JVM client-onboarding wiki page
#   https://jfrog-int.atlassian.net/wiki/spaces/RTFACT/pages/2440101931/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/_jvm_linux_paths.sh" ]]; then
    echo "Error: _jvm_linux_paths.sh not found next to this installer (${SCRIPT_DIR})." >&2
    echo "       This script reads its constants from a sibling file." >&2
    echo "       Invoke as ./install_certs_jvm_linux.sh — not via 'curl | bash'" >&2
    echo "       or 'sh -c \"\$(cat …)\"' (those lose BASH_SOURCE[0])." >&2
    exit 1
fi
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/_jvm_linux_paths.sh"

USE_CERT=""
MODE_OPT="auto"
CERT_BASENAME="${JVM_LINUX_DEFAULT_CERT_BASENAME}"

# Tracked so install_via_jto's final summary can warn loudly if the per-user
# rc step was skipped (otherwise the [3/4] header reads like a success).
RC_UPDATED=0

usage() {
    cat <<EOF
Usage:
  sudo $0 --use-cert <path> [--mode auto|java-tool-options|update-ca-trust] [--cert-name <name>]

Options:
  --use-cert <path>                                Path to an existing PEM/CRT certificate file (required).
  --mode auto|java-tool-options|update-ca-trust    Override path detection (default: auto).
                                                     auto              - detect by distro + JDK trust integration
                                                     java-tool-options - force JAVA_TOOL_OPTIONS + JKS path
                                                     update-ca-trust   - force RHEL system-trust path
  --cert-name <name>                               Base name for installed cert (default: ${CERT_BASENAME}).
                                                   Applied to the anchor file (Path A) AND the JKS alias (Path B).
  -h, --help                                       Show this help.

Examples:
  sudo $0 --use-cert /tmp/ZscalerRoot0.pem
  sudo $0 --use-cert /tmp/ca.pem --mode java-tool-options
  sudo $0 --use-cert /tmp/ca.pem --cert-name zscaler-root
EOF
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Error: this script must be run as root." >&2
        echo "Use: sudo $0 --use-cert <path> [--mode auto|java-tool-options|update-ca-trust]" >&2
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --use-cert)
                USE_CERT="${2:?Error: --use-cert requires a value}"
                shift 2
                ;;
            --mode)
                MODE_OPT="${2:?Error: --mode requires a value}"
                shift 2
                ;;
            --cert-name)
                CERT_BASENAME="${2:?Error: --cert-name requires a value}"
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

    case "$MODE_OPT" in
        auto|java-tool-options|update-ca-trust) ;;
        *)
            echo "Error: --mode must be auto, java-tool-options, or update-ca-trust (got: $MODE_OPT)." >&2
            exit 1
            ;;
    esac

    if [[ -z "$USE_CERT" ]]; then
        echo "Error: --use-cert is required." >&2
        usage >&2
        exit 1
    fi

    if [[ ! -f "$USE_CERT" ]]; then
        echo "Error: certificate file not found: $USE_CERT" >&2
        exit 1
    fi

    if [[ -z "$CERT_BASENAME" ]]; then
        echo "Error: --cert-name cannot be empty." >&2
        exit 1
    fi

    # Reject path-traversal characters so $CERT_BASENAME stays a single path segment.
    if [[ ! "$CERT_BASENAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "Error: --cert-name must match [A-Za-z0-9._-]+ (got: $CERT_BASENAME)." >&2
        exit 1
    fi
}

check_os() {
    if [[ ! -r /etc/os-release ]]; then
        echo "Error: cannot determine OS." >&2
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    local id="${ID:-}" id_like="${ID_LIKE:-}"
    case "$id" in
        ubuntu|debian|rhel|fedora|centos|rocky|almalinux|amzn) return 0 ;;
    esac
    case "$id_like" in
        *debian*|*rhel*|*fedora*|*centos*) return 0 ;;
    esac

    echo "Error: this script supports Debian/Ubuntu and RHEL/Fedora/CentOS/Amazon-Linux families." >&2
    echo "Detected ID=${id:-unknown}, ID_LIKE=${id_like:-unknown}" >&2
    exit 1
}

check_dependencies() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo "Error: openssl is required but not found." >&2
        exit 1
    fi
    # keytool is needed only by Path B; checked at the install_via_jto entry point.
}

# Locate the JDK's default cacerts file. -Djavax.net.ssl.trustStore in OpenJDK
# REPLACES the JVM trust source rather than extending it — pointing JVMs at a
# JKS containing only the corporate CA breaks every public-CA TLS handshake
# (Maven Central, Gradle plugin portal, Let's Encrypt-fronted artifact mirrors).
# We copy the JDK's bundled cacerts into the target keystore first, then
# `keytool -importcert` appends our CA, so the merged store has ~150 public
# roots PLUS the corporate one.
#
# Resolution precedence:
#   1. $JAVA_HOME/lib/security/cacerts (set by every standard JDK installer)
#   2. $(dirname $(command -v keytool))/../lib/security/cacerts (works for
#      stock Adoptium / Corretto / Microsoft / Zulu / RHEL OpenJDK layouts)
#   3. Hard fail with a clear message.
#
# Echoes the resolved path on stdout; exits non-zero on failure.
find_jdk_cacerts() {
    local candidate=""
    if [[ -n "${JAVA_HOME:-}" && -f "${JAVA_HOME}/lib/security/cacerts" ]]; then
        candidate="${JAVA_HOME}/lib/security/cacerts"
    else
        local keytool_path keytool_dir
        keytool_path="$(command -v keytool 2>/dev/null || true)"
        if [[ -n "$keytool_path" ]]; then
            keytool_dir="$(dirname "$(readlink -f "$keytool_path" 2>/dev/null || echo "$keytool_path")")"
            if [[ -f "${keytool_dir}/../lib/security/cacerts" ]]; then
                candidate="${keytool_dir}/../lib/security/cacerts"
            fi
        fi
    fi
    if [[ -z "$candidate" ]]; then
        echo "Error: cannot locate the JDK's default cacerts file." >&2
        echo "       Set JAVA_HOME, or ensure keytool resolves under a standard JDK bin/ layout." >&2
        echo "       Tried: \$JAVA_HOME/lib/security/cacerts, \$(dirname keytool)/../lib/security/cacerts" >&2
        exit 1
    fi
    echo "$candidate"
}

validate_pem() {
    local path="$1"

    # Require PEM-encoded input (text `-----BEGIN CERTIFICATE-----` block).
    # Cross-platform contract: the Windows sibling auto-detects DER via
    # System.Security.Cryptography.X509Certificates and silently accepts
    # it, but the bash branch only handles PEM. Keep the trilogy honest by
    # rejecting DER everywhere with a clear conversion hint, so the same
    # cert file produces the same outcome regardless of the platform the
    # operator runs the installer on.
    if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$path" 2>/dev/null; then
        echo "Error: certificate is not PEM-encoded: $path" >&2
        echo "       If it's DER, convert first:" >&2
        echo "         openssl x509 -inform der -in $path -out $path.pem" >&2
        echo "         then re-run with --use-cert $path.pem" >&2
        exit 1
    fi

    if ! openssl x509 -in "$path" -noout >/dev/null 2>&1; then
        echo "Error: invalid PEM/CRT certificate file: $path" >&2
        exit 1
    fi

    # Reject expired anchors: keytool -importcert -noprompt accepts them silently
    # and the user gets cryptic CertificateExpiredException at TLS handshake time.
    if ! openssl x509 -in "$path" -checkend 0 -noout >/dev/null 2>&1; then
        echo "Error: certificate has already expired: $path" >&2
        exit 1
    fi

    # Warn (don't fail) on a cert expiring within JVM_LINUX_EXPIRY_WARN_SECONDS
    # (30 days). Threshold is in lockstep with the macOS/Windows siblings.
    if ! openssl x509 -in "$path" -checkend "$JVM_LINUX_EXPIRY_WARN_SECONDS" -noout >/dev/null 2>&1; then
        echo "[warn] certificate expires within 30 days: $path" >&2
    fi

    # Reject leaf certs: a cert without CA:TRUE in basicConstraints will import
    # into a JKS truststore but PKIX path-building won't use it as a trust anchor.
    local bc
    bc="$(openssl x509 -in "$path" -noout -ext basicConstraints 2>/dev/null || true)"
    if [[ -n "$bc" ]] && ! grep -qi 'CA:TRUE' <<<"$bc"; then
        echo "Error: certificate is not a CA (basicConstraints missing CA:TRUE): $path" >&2
        echo "       JKS imports succeed but PKIX rejects non-CA trust anchors." >&2
        exit 1
    fi

    # Warn on bundles: keytool -importcert -noprompt reads only the first cert,
    # silently dropping intermediates. Users should split bundles or supply only the root.
    local count
    count="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$path" 2>/dev/null || echo 0)"
    if [[ "$count" -gt 1 ]]; then
        echo "[warn] PEM file contains $count certificates; only the first will be imported as the JVM trust anchor." >&2
        echo "       Supply only the root CA (or split the bundle) if intermediates are needed." >&2
    fi
}

replace_export_in_file() {
    local file="$1"
    local var="$2"
    local value="$3"
    local tmp escaped

    escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"

    # Place tmp in the same directory as the target so `mv` is rename(2) (atomic)
    # and a cross-filesystem copy can't half-truncate the target on disk-full.
    tmp=$(mktemp -p "$(dirname "$file")")
    awk -v var="$var" -v val="$escaped" '
        $0 ~ "^export " var "=" {
            print "export " var "=\"" val "\""
            next
        }
        { print }
    ' "$file" > "$tmp"
    if [[ ! -s "$tmp" && -s "$file" ]]; then
        rm -f "$tmp"
        echo "Error: awk produced empty output; refusing to overwrite $file" >&2
        exit 1
    fi
    mv "$tmp" "$file"
}

ensure_export_in_file() {
    local file="$1"
    local var="$2"
    local value="$3"

    touch "$file"

    if grep -qE "^export ${var}=" "$file" 2>/dev/null; then
        replace_export_in_file "$file" "$var" "$value"
    else
        printf 'export %s="%s"\n' "$var" "$value" >> "$file"
    fi
}

get_target_user() {
    local candidate

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        candidate="$SUDO_USER"
    else
        candidate="$(logname 2>/dev/null || true)"
        if [[ -z "$candidate" || "$candidate" == "root" ]]; then
            if command -v loginctl >/dev/null 2>&1; then
                candidate="$(loginctl list-sessions --no-legend 2>/dev/null | awk '
                    $2 >= 1000 && $3 != "root" && $4 == "seat0" { print $3; found=1; exit }
                    $2 >= 1000 && $3 != "root" && !fallback { fallback=$3 }
                    END { if (!found && fallback) print fallback }
                ')"
            fi
        fi
    fi

    if [[ -z "$candidate" || "$candidate" == "root" ]]; then
        return 0
    fi

    # Reject users that don't exist in passwd (transient sessions etc.).
    if ! getent passwd "$candidate" >/dev/null 2>&1; then
        return 0
    fi

    echo "$candidate"
}

get_user_home() {
    local user="$1"
    getent passwd "$user" | cut -d: -f6
}

get_user_shell() {
    local user="$1"
    getent passwd "$user" | cut -d: -f7
}

# Stdout contract: exactly one of {java-tool-options, update-ca-trust}.
# Callers MUST equality-match the returned string. Keep in sync with the
# validator's detect_mode (which adds a "none" case when no artifacts exist).
detect_mode() {
    if ! command -v update-ca-trust >/dev/null 2>&1; then
        echo "java-tool-options"
        return
    fi
    if [[ ! -e "$RHEL_JAVA_CACERTS" ]]; then
        echo "java-tool-options"
        return
    fi

    local java_bin java_home cacerts
    java_bin="$(command -v java 2>/dev/null || true)"
    if [[ -z "$java_bin" ]]; then
        # update-ca-trust present and the RHEL system Java cacerts exists, but
        # no JDK is on PATH yet. Pick the system-trust path on the assumption
        # that Red Hat OpenJDK will be installed via dnf. If the user later
        # installs a non-Red-Hat JDK (Corretto, Temurin, SDKMAN), they must
        # re-run with --mode java-tool-options — install_via_update_ca_trust
        # emits a loud end-of-run warning to that effect.
        echo "update-ca-trust"
        return
    fi

    java_home="$(dirname "$(dirname "$(readlink -f "$java_bin")")")"
    cacerts="${java_home}/lib/security/cacerts"
    if [[ "$(readlink -f "$cacerts" 2>/dev/null)" == "$RHEL_JAVA_CACERTS" ]]; then
        echo "update-ca-trust"
    else
        echo "java-tool-options"
    fi
}

install_via_update_ca_trust() {
    local anchor_path="${RHEL_ANCHOR_DIR}/${CERT_BASENAME}.crt"
    local java_present=0
    command -v java >/dev/null 2>&1 && java_present=1

    echo "[1/4] Installing CA into system anchor: $anchor_path"
    mkdir -p "$RHEL_ANCHOR_DIR"

    # Pre-flight: if a file already exists at the anchor path, compare
    # SHA-256 fingerprints. Identical -> idempotent re-run, skip the cp.
    # Different -> warn the operator that we're replacing an existing
    # trust anchor so a silent overwrite (potentially clobbering a CA
    # placed by other tooling under the same --cert-name basename) leaves
    # a clear paper trail.
    if [[ -e "$anchor_path" ]]; then
        local existing_fp installer_fp
        existing_fp="$(openssl x509 -in "$anchor_path" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' || true)"
        installer_fp="$(openssl x509 -in "$USE_CERT" -noout -fingerprint -sha256 | sed 's/.*=//')"
        if [[ "$existing_fp" == "$installer_fp" ]]; then
            echo "      Anchor already present with matching fingerprint; skipping copy."
        else
            echo "      [warn] Replacing existing anchor at $anchor_path" >&2
            echo "             existing fingerprint: $existing_fp" >&2
            echo "             new fingerprint:      $installer_fp" >&2
            cp "$USE_CERT" "$anchor_path"
        fi
    else
        cp "$USE_CERT" "$anchor_path"
    fi
    chmod 0644 "$anchor_path"

    echo "[2/4] Running update-ca-trust extract..."
    update-ca-trust extract

    echo "[3/4] Verifying Java cacerts contains the CA..."
    if ! command -v keytool >/dev/null 2>&1; then
        echo "      [warn] keytool not on PATH; skipping Java-side verification. Install a JDK and re-run validate_certs_jvm_linux.sh." >&2
    else
        local fingerprint listing
        fingerprint="$(openssl x509 -in "$anchor_path" -noout -fingerprint -sha256 | sed 's/.*=//')"

        # Capture keytool's output explicitly so a real keytool failure (wrong
        # password, corrupt store, missing JDK at runtime) is reported as such
        # and not as a misleading "fingerprint not yet visible".
        if ! listing="$(keytool -list -keystore "$RHEL_JAVA_CACERTS" -storepass "$JKS_PASSWORD" 2>&1)"; then
            echo "      [warn] keytool could not read $RHEL_JAVA_CACERTS. Output:" >&2
            printf '%s\n' "$listing" | head -n5 >&2
        elif grep -qiF "$fingerprint" <<<"$listing"; then
            echo "      OK: CA fingerprint visible in $RHEL_JAVA_CACERTS"
        else
            echo "      [warn] CA fingerprint not yet visible in $RHEL_JAVA_CACERTS — system trust may need a fresh login session or a non-Red-Hat JDK is on PATH." >&2
        fi
    fi

    echo "[4/4] Done. No env var needed; Red Hat OpenJDK reads $RHEL_JAVA_CACERTS directly."
    echo
    echo "Installed certificate:"
    echo "  $anchor_path"
    echo "Java trust path:"
    echo "  $RHEL_JAVA_CACERTS"

    if [[ "$java_present" -eq 0 ]]; then
        echo
        echo "WARNING: no JDK is on PATH right now. The system-trust path was picked because"
        echo "         /etc/pki/ca-trust/extracted/java/cacerts exists, assuming Red Hat OpenJDK"
        echo "         will be installed via dnf. If you instead install Corretto, Eclipse Temurin,"
        echo "         or any JDK whose lib/security/cacerts is NOT symlinked to the system store,"
        echo "         this installer will NOT have configured trust for it. Re-run with"
        echo "         --mode java-tool-options in that case." >&2
    fi
}

require_keytool() {
    if ! command -v keytool >/dev/null 2>&1; then
        echo "Error: keytool is required for --mode java-tool-options (provided by any JDK)." >&2
        echo "  Debian/Ubuntu: sudo apt-get install -y default-jdk-headless" >&2
        echo "  RHEL/Fedora:   sudo dnf install -y java-21-openjdk-headless" >&2
        echo "  Manual JDK:    add \$JAVA_HOME/bin to PATH (or symlink keytool into /usr/local/bin)." >&2
        exit 1
    fi
}

ensure_kv_in_environment_file() {
    local key="$1" value="$2" tmp escaped

    touch "$ENVIRONMENT_FILE"

    escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"

    if grep -qE "^${key}=" "$ENVIRONMENT_FILE" 2>/dev/null; then
        # Same-directory mktemp keeps `mv` atomic and avoids cross-fs truncation risk.
        tmp=$(mktemp -p "$(dirname "$ENVIRONMENT_FILE")")
        awk -v k="$key" -v v="$escaped" '
            $0 ~ "^" k "=" { print k "=\"" v "\""; next }
            { print }
        ' "$ENVIRONMENT_FILE" > "$tmp"
        if [[ ! -s "$tmp" && -s "$ENVIRONMENT_FILE" ]]; then
            rm -f "$tmp"
            echo "Error: awk produced empty output; refusing to overwrite $ENVIRONMENT_FILE" >&2
            exit 1
        fi
        mv "$tmp" "$ENVIRONMENT_FILE"
    else
        printf '%s="%s"\n' "$key" "$escaped" >> "$ENVIRONMENT_FILE"
    fi

    chmod 0644 "$ENVIRONMENT_FILE"
}

update_user_shell_rc() {
    local jto_value="$1"
    local target_user user_home user_shell rc_file chown_err

    target_user="$(get_target_user)"
    if [[ -z "$target_user" || "$target_user" == "root" ]]; then
        echo "      [warn] Per-user rc not updated: could not determine non-root target user." >&2
        echo "             Run with sudo as the developer user (or set SUDO_USER) so the current shell" >&2
        echo "             session picks up JAVA_TOOL_OPTIONS without re-login. /etc/environment is" >&2
        echo "             written either way and will reach new login sessions." >&2
        return 0
    fi

    user_home="$(get_user_home "$target_user")"
    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        echo "      [warn] Per-user rc not updated: home not found for $target_user." >&2
        return 0
    fi

    user_shell="$(get_user_shell "$target_user")"
    case "$user_shell" in
        */zsh) rc_file="$user_home/.zshrc" ;;
        *)     rc_file="$user_home/.bashrc" ;;
    esac

    touch "$rc_file"
    ensure_export_in_file "$rc_file" "JAVA_TOOL_OPTIONS" "$jto_value"
    if ! chown_err="$(chown "$target_user":"$target_user" "$rc_file" 2>&1)"; then
        echo "      [warn] chown failed on $rc_file: $chown_err" >&2
    fi

    echo "      Updated $rc_file"
    RC_UPDATED=1
}

install_via_jto() {
    require_keytool

    local src_cacerts
    src_cacerts="$(find_jdk_cacerts)"
    echo "[1/4] Building JKS truststore at $JKS_PATH (extending $src_cacerts)..."
    mkdir -p "$JKS_DIR"
    chmod 0755 "$JKS_DIR"
    # Copy the JDK's bundled cacerts (~150 public root CAs) as the base so the
    # merged store keeps trusting Maven Central, Let's Encrypt, etc. Then
    # keytool -importcert appends the corporate CA next to them. No -storetype
    # flag: modern JDKs default cacerts to PKCS12 and keytool autodetects.
    cp "$src_cacerts" "$JKS_PATH"
    chmod 0644 "$JKS_PATH"
    keytool -importcert -noprompt \
        -alias "$CERT_BASENAME" \
        -file "$USE_CERT" \
        -keystore "$JKS_PATH" \
        -storepass "$JKS_PASSWORD" >/dev/null

    # Note on inner quoting: /etc/environment uses NAME="VALUE" format and
    # treats backslashes literally — there's no way to embed `"` inside the
    # value without breaking the parser. The JKS_PATH and JKS_PASSWORD are
    # space-free by construction (regex on --cert-name enforces no spaces;
    # JKS_DIR is /etc/ssl/package-route-jvm). Adding inner quotes would
    # require an alternate persistence format and is not required for the
    # current spec. The Windows sibling can quote because HKCU\Environment
    # is a registry REG_SZ that stores the value byte-for-byte; macOS plist
    # XML has its own escaping. The bash branch deliberately stays unquoted.
    local jto_value="-Djavax.net.ssl.trustStore=${JKS_PATH} -Djavax.net.ssl.trustStorePassword=${JKS_PASSWORD}"

    echo "[2/4] Writing JAVA_TOOL_OPTIONS to $ENVIRONMENT_FILE..."
    ensure_kv_in_environment_file "JAVA_TOOL_OPTIONS" "$jto_value"

    echo "[3/4] Updating target user's shell rc file..."
    update_user_shell_rc "$jto_value"

    echo "[4/4] Done."
    echo
    echo "Truststore:"
    echo "  $JKS_PATH (alias: $CERT_BASENAME)"
    echo "JAVA_TOOL_OPTIONS:"
    echo "  $jto_value"
    echo
    echo "Notes:"
    echo "  - Log out and log back in for GDM/KDM-launched IDEs to pick up JAVA_TOOL_OPTIONS."
    echo "  - Run 'gradle --stop' to refresh the Gradle Daemon if one was already running."
    echo "  - The 'Picked up JAVA_TOOL_OPTIONS:' banner on stderr is expected."

    if [[ "$RC_UPDATED" -eq 0 ]]; then
        echo
        echo "WARNING: per-user shell rc was NOT updated; existing shells of the developer user"
        echo "         will not see JAVA_TOOL_OPTIONS until they log out and back in (or source"
        echo "         /etc/environment manually). The system-wide change in $ENVIRONMENT_FILE"
        echo "         takes effect on the next fresh login." >&2
    fi
}

main() {
    require_root
    parse_args "$@"
    check_os
    check_dependencies
    validate_pem "$USE_CERT"

    local mode="$MODE_OPT"
    if [[ "$mode" == "auto" ]]; then
        mode="$(detect_mode)"
        echo "Auto-detected mode: $mode"
    else
        echo "Mode (forced via --mode): $mode"
    fi

    case "$mode" in
        update-ca-trust)   install_via_update_ca_trust ;;
        java-tool-options) install_via_jto ;;
        *)
            echo "Error: unexpected mode after detection: $mode" >&2
            exit 1
            ;;
    esac
}

main "$@"
