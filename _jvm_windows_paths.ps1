# (c) JFrog Ltd. (2026)
# Shared constants for install_certs_jvm_windows.ps1 and validate_certs_jvm_windows.ps1.
# Dot-sourced from both scripts; not directly executable.
#
# IMPORTANT for future maintainers: keep all .ps1 files in this set saved as
# UTF-8 WITH BOM and use ASCII-only content. Windows PowerShell 5.1 reads
# files without a BOM as Windows-1252; an em-dash (U+2014) bytes
# (e2 80 94) then decode as "a-tilde, euro, right-double-quote" -- the
# trailing U+201D quote terminates string literals mid-line and the parser
# reports a confusing error 100+ lines later. The BOM forces UTF-8 parsing.
# ASCII-only content avoids the issue regardless.
#
# Both scripts read this file via:
#   $ScriptDir = Split-Path -Parent $PSCommandPath
#   . (Join-Path $ScriptDir '_jvm_windows_paths.ps1')
#
# Keep installer and validator in lockstep by changing only this file.
#
# Cross-platform siblings (keep CLI shapes and contracts in sync):
#   _jvm_linux_paths.sh      - system anchor (Path A) / JKS+JTO (Path B)
#   _jvm_macos_paths.sh      - per-user JKS under ~/Library

# Default base name used as the JKS alias inside the per-user truststore.
# Overridable via -CertName on the installer (affects ONLY the alias name
# visible in `keytool -list` output -- the JKS file path and the User-scope
# JAVA_TOOL_OPTIONS env var name are fixed, so a different -CertName on
# re-run replaces the previous CA rather than installing alongside it).
$JvmWindowsDefaultCertBasename = 'package-route-custom-ca'

# Per-user JKS truststore under %LOCALAPPDATA% so the User-scope env var
# can point at it without crossing user boundaries. Matches the per-user
# scope of the HKCU\Environment write.
$JvmWindowsJksRelativeDir = 'JFrog\package-route-jvm'
$JvmWindowsJksBasename = 'truststore.jks'

# Function: returns $env:LOCALAPPDATA-relative JKS path. The validator and
# installer both derive their target path through this helper so the
# shape stays in lockstep across files.
function Get-JvmWindowsJksPath {
    Join-Path $env:LOCALAPPDATA (Join-Path $JvmWindowsJksRelativeDir $JvmWindowsJksBasename)
}

# OpenJDK convention for cacerts and similar truststores. NOT a secret in
# this script's use case: we import only `trustedCertEntry` records (public
# CA certs), so the password protects file *integrity* via the keystore MAC
# but not any private key material. A JKS holding PrivateKeyEntry would
# additionally rely on this password to encrypt the key -- not relevant here.
# Persisted in JAVA_TOOL_OPTIONS via -Djavax.net.ssl.trustStorePassword so
# unattended JVMs can open the store.
$JvmWindowsJksPassword = 'changeit'

# Environment variable name. Fixed because the install path doesn't multi-cert.
$JvmWindowsEnvVarName = 'JAVA_TOOL_OPTIONS'
