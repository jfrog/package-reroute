# (c) JFrog Ltd. (2026)
# Shared constants for install_certs_jvm_macos.sh and validate_certs_jvm_macos.sh.
# Sourced — must NOT be executed directly. Has no shebang on purpose.
#
# Both scripts read this file via:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/_jvm_macos_paths.sh"
#
# Keep installer and validator in lockstep by changing only this file.
#
# Cross-platform siblings (keep CLI shapes and contracts in sync):
#   _jvm_linux_paths.sh      — system anchor (Path A) / JKS+JTO (Path B)
#   _jvm_windows_paths.ps1   — per-user JKS under %LOCALAPPDATA%

# Default base name used as the JKS alias inside the per-user truststore.
# Overridable via --cert-name on the installer (affects ONLY the alias name
# visible in `keytool -list` output — the JKS file path, plist path, and
# LaunchAgent label are all fixed per-user, so a different --cert-name on
# re-run replaces the previous CA rather than installing alongside it).
JVM_MACOS_DEFAULT_CERT_BASENAME="package-route-custom-ca"

# Per-user JKS truststore. macOS convention: per-user resources under the user's
# Library directory so each account stays isolated. Matches the existing
# install_certs_macos.sh pattern (per-user PEM under ~/<extract-path>/).
JKS_RELATIVE_DIR="Library/Application Support/JFrog/package-route-jvm"
JKS_BASENAME="truststore.jks"

# Per-user LaunchAgent that calls `launchctl setenv JAVA_TOOL_OPTIONS=…` at
# RunAtLoad. This is the only macOS recipe that reaches Dock-launched IDEs;
# the ~/.zshrc shortcut silently fails for GUI-spawned subprocesses.
LAUNCH_AGENT_RELATIVE_DIR="Library/LaunchAgents"
LAUNCH_AGENT_LABEL="com.jfrog.package-reroute.jto-env"
LAUNCH_AGENT_BASENAME="${LAUNCH_AGENT_LABEL}.plist"

# OpenJDK convention for cacerts and similar truststores. NOT a secret in
# this script's use case: we import only `trustedCertEntry` records (public
# CA certs), so the password protects file *integrity* via the keystore MAC
# but not any private key material. (A JKS that ever holds a PrivateKeyEntry
# would additionally rely on this password to encrypt the key — not relevant
# here.) Persisted in the LaunchAgent plist via -Djavax.net.ssl.trustStorePassword
# so unattended JVMs can open the store.
JKS_PASSWORD="changeit"
