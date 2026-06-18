# (c) JFrog Ltd. (2026)
# Shared constants for install_certs_jvm_linux.sh and validate_certs_jvm_linux.sh.
# Sourced — must NOT be executed directly. Has no shebang on purpose.
#
# Both scripts read this file via:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/_jvm_linux_paths.sh"
#
# Keep installer and validator in lockstep by changing only this file.
#
# Cross-platform siblings (keep CLI shapes and contracts in sync):
#   _jvm_macos_paths.sh     — per-user JKS under ~/Library
#   _jvm_windows_paths.ps1  — per-user JKS under %LOCALAPPDATA%

# Default base name for the installed CA file (Path A) and the JKS alias (Path B).
# Overridable via --cert-name on the installer; the validator must be invoked with
# the same --cert-name when a non-default value was used.
#
# CROSS-PLATFORM NOTE: Linux is the only sibling where --cert-name affects
# a filesystem-visible path (Path A: /etc/pki/ca-trust/source/anchors/${CERT_BASENAME}.crt).
# macOS and Windows treat --cert-name as a JKS-alias-only cosmetic. A fleet
# script that wraps all three installers with the same --cert-name must
# remember to also pass --cert-name to the LINUX validator.
JVM_LINUX_DEFAULT_CERT_BASENAME="package-route-custom-ca"

# Path A — RHEL family with Red Hat OpenJDK. The JDK symlinks its
# lib/security/cacerts to RHEL_JAVA_CACERTS, so system trust IS Java trust.
RHEL_ANCHOR_DIR="/etc/pki/ca-trust/source/anchors"
RHEL_JAVA_CACERTS="/etc/pki/ca-trust/extracted/java/cacerts"

# Path B — JKS truststore + JAVA_TOOL_OPTIONS. Used on Debian/Ubuntu, Amazon
# Corretto, Eclipse Temurin, SDKMAN-installed JDKs, and manual .tar.gz installs.
#
# Note: Linux uses /etc/ssl/package-route-jvm rather than nesting under
# /etc/ssl/JFrog/package-route-jvm (as macOS/Windows do under their per-user
# trees). The flat path matches /etc/ssl conventions; if a future JFrog tool
# needs a sibling dir, it can carve out /etc/ssl/jfrog-<tool>/ alongside.
JKS_DIR="/etc/ssl/package-route-jvm"
JKS_PATH="${JKS_DIR}/truststore.jks"

# OpenJDK convention for cacerts and similar truststores. NOT a secret in
# this script's use case: we import only `trustedCertEntry` records (public
# CA certs), so the password protects file *integrity* via the keystore MAC
# but not any private key material. A JKS that ever holds a PrivateKeyEntry
# would additionally rely on this password to encrypt the key — not relevant
# here. Persisted in /etc/environment via -Djavax.net.ssl.trustStorePassword
# so unattended JVMs can open the store.
JKS_PASSWORD="changeit"

ENVIRONMENT_FILE="/etc/environment"

# 30-day expiry warn threshold (in seconds) — used by validate_pem. Must stay
# in lockstep with the macOS bash sibling (-checkend 2592000) and the Windows
# .NET sibling (AddDays(30)). Do not change without updating all three.
JVM_LINUX_EXPIRY_WARN_SECONDS=2592000
