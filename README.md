# Certificate installation scripts

This document describes the certificate installation and validation scripts for **macOS** and **Windows**.

| Script | Platform | Purpose |
|--------|----------|---------|
| **install_certs_macos.sh** | macOS | Install cert and set env vars (Node/Python) |
| **validate_install_macos.sh** | macOS | Validate PEM and env config |
| **install_certs_windows.ps1** | Windows | Install cert and set env vars (Node/Python) |
| **validate_install_windows.ps1** | Windows | Validate PEM and env config |

The same environment variables are used on both platforms:

| Variable | Used by | Purpose |
|----------|--------|---------|
| `NODE_USE_SYSTEM_CA=1` | Node/npm | Use system CA store in addition to extra certs |
| `NODE_EXTRA_CA_CERTS=<path>` | Node/npm | Path to PEM file (single file, can contain multiple certs) |
| `REQUESTS_CA_BUNDLE=<path>` | Python/requests | Path to PEM bundle for TLS verification |

---

## macOS: install_certs_macos.sh

### Overview

`install_certs_macos.sh` configures **Node/npm** and/or **Python/pip** on macOS to use a custom CA certificate (e.g. for corporate proxy or package routing). It:

- Runs **only as root** (e.g. `sudo`).
- Either **extracts** one certificate from the macOS Keychain (by name pattern) and writes it to a PEM file, or **uses an existing** PEM file you provide.
- For **each user** in `/Users/*`, writes or updates the certificate file and sets environment variables in that user’s `~/.zshrc` so Node and Python use the certificate.

The PEM file written is named **package-route.pem** under the directory you choose.

### Requirements

- **macOS** (script uses `security` for Keychain when extracting by cert name).
- **Root** (script exits with an error and suggests `sudo` if not root).
- **openssl** on `PATH`. Optional: use `--install-dependencies` to install it via Homebrew in the same run if missing.
- When using **--cert-name**: the **security** (Keychain) tool must be available (system tool; `/usr/bin` is prepended to `PATH` by the script).

---

### How to use

#### Basic usage

```bash
sudo ./install_certs_macos.sh [OPTIONS]
```

#### Options

| Option | Required | Description |
|--------|----------|-------------|
| `--package <npm\|pip\|all>` | No (default: **all**) | What to configure: **npm** (Node), **pip** (Python/requests), or **all**. |
| `--cert-name <pattern>` | Yes* | Regex pattern to match **exactly one** certificate in the Keychain (subject). Requires `--extract-path`. |
| `--extract-path <path>` | Yes* | Directory where **package-route.pem** will be written. Absolute or relative to each user’s home. Requires `--cert-name`. |
| `--use-cert <path>` | Yes* | Use this existing PEM file instead of extracting from Keychain. Cannot be used with `--cert-name` / `--extract-path`. |
| `--install-dependencies` | No | If **openssl** is missing, install it via Homebrew and continue in the same run. |
| `-h`, `--help` | — | Print usage and exit. |

\* You must use **either** (`--cert-name` and `--extract-path`) **or** `--use-cert`, not both and not neither.

#### Examples

**1. Extract cert from Keychain and configure npm + pip for all users**

Certificate subject must match the pattern (e.g. "My CA"). PEM is written under each user’s home (e.g. `~/opt/certs/package-route.pem` for `--extract-path /opt/certs`) and each user’s `.zshrc` is updated:

```bash
sudo ./install_certs_macos.sh \
  --package all \
  --cert-name "My CA" \
  --extract-path /opt/certs
```

**2. Use an existing PEM file (e.g. from IT)**

No Keychain access; same PEM path is set for every user:

```bash
sudo ./install_certs_macos.sh \
  --package all \
  --use-cert /opt/certs/company-ca.pem
```

**3. Only configure pip (REQUESTS_CA_BUNDLE)**

```bash
sudo ./install_certs_macos.sh \
  --package pip \
  --cert-name "My CA" \
  --extract-path certs
```

With a relative `--extract-path`, each user gets their own file, e.g. `/Users/jane/certs/package-route.pem`.

**4. Install openssl if missing, then run (single run)**

```bash
sudo ./install_certs_macos.sh \
  --install-dependencies \
  --package all \
  --cert-name "My CA" \
  --extract-path /opt/certs
```

---

### Install validation

**validate_install_macos.sh** checks that the certificate installation succeeded: PEM file(s) exist and are valid (via `openssl x509`). It does **not** require root unless you use `--all-users`.

| Option | Description |
|--------|--------------|
| *(none)* | Read `NODE_EXTRA_CA_CERTS` and `REQUESTS_CA_BUNDLE` from the current user’s `~/.zshrc` (with `~` expanded), then validate each referenced PEM file. |
| `--all-users` | **(Root only.)** For each user in `/Users/*`, read their `~/.zshrc`, resolve cert paths, and validate each PEM. Use: `sudo ./validate_install_macos.sh --all-users`. |
| `--expected-subject <pattern>` | Require at least one cert in each PEM file (bundle) to have a subject matching `<pattern>` (case-insensitive). All certs in the file are checked. |

**Requirements:** `openssl` on `PATH` (same paths as the install script are prepended).

**Exit code:** 0 if all checks pass, 1 if any check fails.

```bash
# After install: validate current user’s config and cert path(s)
./validate_install_macos.sh --expected-subject Zscaler

# Validate every user’s config (run as root)
sudo ./validate_install_macos.sh --expected-subject Zscaler --all-users
```

---

### Testing

Tests live in **scripts/testing/**.

**test_install_certs_macos.sh** runs automated tests for **install_certs_macos.sh** (CLI and argument validation), **validate_install_macos.sh** (validation with a temp PEM and mock home), and fingerprint/merge logic (same fingerprint → dedupe, different fingerprint → append). No root required.

**Requirements:** `openssl` on `PATH` (for generating a temporary cert in tests).

```bash
# From repo root
./scripts/testing/test_install_certs_macos.sh

# Or from scripts/
cd scripts && ./testing/test_install_certs_macos.sh
```

Exit code 0 if all tests pass, 1 otherwise.

#### Test coverage

| Area | Covered | Not covered |
|------|--------|-------------|
| **install_certs_macos.sh** | **CLI and pre-root:** `--help`; unknown option; invalid `--package`; `--cert-name` without `--extract-path` (and reverse); no cert source; `--use-cert` + `--cert-name` conflict; `--use-cert` with missing file; non-root exit and message. **--use-cert:** valid PEM path and `--package npm`/`pip` (non-root → run as root); invalid PEM content rejected with "Invalid or missing PEM" when run as root (tested when passwordless sudo available). **Fingerprint/merge (no root):** same fingerprint → one cert (dedupe); different fingerprint → both certs appended; `bundle_contains_pem` and merge logic exercised via test helpers. | **Post-root:** PATH/openssl, `--install-dependencies` (Homebrew); Keychain extraction; per-user loop; writing PEM and updating `.zshrc`. Requires root and/or Keychain; not run in CI. |
| **validate_install_macos.sh** | **CLI:** unknown option (exit 1); missing `--expected-subject` (exit 1). **Main paths:** default with mock `HOME` and `.zshrc`; missing PEM in `.zshrc` (exit 1); `--all-users` without root (exit 1). Covers `validate_pem`, `get_export_path`, `validate_user_config`. | Multi-cert bundle in `validate_pem`; `--all-users` as root. |

Tests are black-box (exit codes and stderr).

#### Windows tests

**test_install_certs_windows.ps1** runs automated tests for **install_certs_windows.ps1** (CLI and parameter validation) and **validate_install_windows.ps1** (-ExpectedSubject required, env-based validation: valid PEM, missing file, invalid PEM, subject match and no-match). No admin required; the script uses a temp directory and creates a valid PEM (self-signed from cert store when possible, or an embedded minimal PEM if store access is denied, e.g. on some VMs).

**Requirements:** Windows with PowerShell. The install and validate scripts must be in the parent of `testing/` (i.e. **scripts/**).

```powershell
# From repo root (PowerShell on Windows)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/testing/test_install_certs_windows.ps1

# Or from scripts/
powershell -NoProfile -ExecutionPolicy Bypass -File testing/test_install_certs_windows.ps1
```

From a non-Windows host you can run the tests on a Windows VM via SSH (e.g. copy the scripts and invoke the same command over `ssh jump-windows`).

Exit code 0 if all tests pass, 1 otherwise. Output shows pass/fail per test and a final count.

| Area | Covered |
|------|--------|
| **install_certs_windows.ps1** | No cert source (parameter set error); invalid `-Package`; `-CertName` without `-ExtractPath` (and reverse); `-UseCert` and `-CertName` together; `-UseCert` with nonexistent file; `-UseCert` with invalid PEM; `-UseCert` with valid PEM (no "not a file" or "Invalid PEM" error). |
| **validate_install_windows.ps1** | `-ExpectedSubject` required (exit 1 if missing); current user env (no paths → exit 0); env path to valid PEM (exit 0), missing file (exit 1), invalid PEM (exit 1); subject mismatch (exit 1, FAIL message). |

Tests are black-box (exit codes and stdout/stderr). Paths are passed to the validate script via a temp file when invoking as a child process to avoid command-line parsing issues with backslashes.

---

### Logic in detail

#### 1. Argument handling

- **--package** defaults to `all` if omitted; must be `npm`, `pip`, or `all`.
- **Cert source** is one of:
  - **Extract:** `--cert-name` and `--extract-path` must both be set; `--use-cert` must not be set.
  - **Use file:** `--use-cert` set; `--cert-name` and `--extract-path` must not be set.
- Script exits with an error if:
  - Only one of `--cert-name` / `--extract-path` is set, or
  - Both extract and `--use-cert` are used, or
  - Neither cert source is provided.

#### 2. Root and dependencies

- Script must run as root; otherwise it prints an error and suggests `sudo $0 [options]`.
- Prepends `/usr/bin` and common Homebrew paths to `PATH` so `openssl` and `security` are found.
- If `--install-dependencies` is set and `openssl` is not on `PATH`:
  - Tries Homebrew (`/opt/homebrew/bin/brew` or `/usr/local/bin/brew`).
  - Runs `brew install openssl`, then adds the new `openssl` to `PATH` and **continues** in the same run.
- If `openssl` is still missing after that (or without the flag), script exits with an error.
- If cert source is **extract** (`--cert-name`), script checks that `security` is available; if not, it exits (system tool, cannot be installed).

#### 3. Certificate source

- **--use-cert:** Validates the file with `openssl x509 -noout` and uses it as the certificate for all users. No Keychain access.
- **--cert-name + --extract-path:**
  - Reads system Keychains (`System.keychain`, `SystemRootCertificates.keychain`).
  - Exports all certs, then filters by subject using the `--cert-name` regex.
  - Requires **exactly one** match; errors if 0 or &gt;1. The matched cert is stored in memory as PEM.

#### 4. Per-user loop

For each directory in `/Users/*` (skipping `Shared` and non-directories):

- **Cert file path:**
  - If **--use-cert:** use that path for every user.
  - If **--extract-path:** use `<homedir>/<extract-path with leading / stripped>/package-route.pem` (e.g. `/opt/certs` → `~/opt/certs/package-route.pem`, `certs` → `~/certs/package-route.pem`). Script creates the directory, writes the PEM, and `chown`s to that user.
- For each user that has a **~/.zshrc**, the script calls `add_exports_to_file` with that file and the user’s cert path.

#### 5. add_exports_to_file (per user, per shell file)

For **npm** (if `--package` is `npm` or `all`):

- Read the first `export NODE_EXTRA_CA_CERTS=...` line (if any) and resolve the path (including `~`).
- **If no existing export:** append a blank line, `export NODE_USE_SYSTEM_CA=1`, and `export NODE_EXTRA_CA_CERTS="<cert_path>"`.
- **If export already exists:**  
  - Replace that line so it points to the **admin’s** cert path (the one we’re configuring).  
  - Ensure `export NODE_USE_SYSTEM_CA=1` exists (append if missing).  
  - **Merge PEMs:** read the **old** bundle file (previous path); append every cert from it into the **new** cert file, **except**: (1) certs with the same fingerprint as the one we’re installing, (2) certs already present in the new file (by fingerprint). So the new file ends up with: **our cert first**, then any other CAs from the old file that aren’t duplicates.

For **pip** (if `--package` is `pip` or `all`):

- Same idea for `REQUESTS_CA_BUNDLE`: add export if missing, or replace the path and merge the old bundle into the new cert file (again skipping duplicates by fingerprint).

Fingerprints are SHA-256 via `openssl x509 -fingerprint -sha256 -noout`.

---

#### Flowchart

<img src="images/flowchart.svg" width="700" alt="install_certs_macos.sh flowchart" />

---

#### Summary (macOS)

- **One run as root** (optionally with `--install-dependencies` to install openssl).
- **One cert source:** either Keychain (--cert-name + --extract-path) or existing file (--use-cert).
- **Per user:** one PEM path per user (or shared if extract-path is absolute); env vars in `~/.zshrc` point to that path.
- **If user already had a different path:** script replaces it with the admin’s path and merges other certs from the old file into the new one (no duplicate certs by fingerprint).

Users must open a **new terminal** (or `source ~/.zshrc`) for the new environment variables to take effect.

---

## Windows: install_certs_windows.ps1

### Overview

`install_certs_windows.ps1` configures **Node/npm** and/or **Python/pip** on Windows to use a custom CA certificate. It:

- Either **extracts** one certificate from the Windows cert store (LocalMachine\Root or CurrentUser\Root by context) by **subject name pattern**, or **uses an existing** PEM file you provide.
- When run as **admin (or SYSTEM):** writes **package-route.pem** per user under each user’s profile and sets **User**-level env vars in the registry for each user.
- When run as **normal user:** writes to the current user’s profile and sets **User**-level env vars for the current user only.
- When run with **-UseCert:** does **not** write a PEM file; sets **Machine**-level env vars (if admin) or **User**-level (if not). When setting Machine, the script **deletes** User-level cert vars (`NODE_EXTRA_CA_CERTS`, `NODE_USE_SYSTEM_CA`, `REQUESTS_CA_BUNDLE`) so that only Machine settings apply (User would otherwise override Machine on Windows).

Re-runs **merge** certs: if the target file already exists, the script saves its content, overwrites with the new cert, then appends other certs from the saved copy (dedupe by SHA-256 fingerprint). So running with a second cert adds it to the bundle instead of replacing it.

### Requirements

- **Windows** with PowerShell.
- **Admin** (or SYSTEM) for per-user install and for Machine-level env when using **-UseCert**.
- When using **-CertName:** the certificate must exist in the store and match **exactly one** cert by subject substring.

### How to use

Run from a directory that contains the script (or use full path):

```powershell
powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package all -CertName Zscaler -ExtractPath certs\npm
# Or use an existing PEM:
powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package all -UseCert C:\path\to\ca.pem
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Package` | No (default: **all**) | `npm`, `pip`, or `all`. |
| `-CertName` | Yes* | Substring to match **exactly one** cert subject in the store. Requires `-ExtractPath`. Cannot be used with `-UseCert`. |
| `-ExtractPath` | Yes* | Directory for the PEM (writes `<path>\package-route.pem`); relative to each user’s profile or absolute. Requires `-CertName`. |
| `-UseCert` | Yes* | Path to an existing PEM file. Cannot be used with `-CertName` / `-ExtractPath`. |

\* Use **either** (`-CertName` and `-ExtractPath`) **or** `-UseCert`.

### Examples

**Extract from store and configure all users (run as admin):**

```powershell
.\install_certs_windows.ps1 -Package all -CertName Zscaler -ExtractPath certs\npm
```

**Use an existing PEM (Machine-level env; User-level cert vars are deleted):**

```powershell
.\install_certs_windows.ps1 -Package all -UseCert C:\Users\Administrator\other-ca\company-ca.pem
```

**Only npm:**

```powershell
.\install_certs_windows.ps1 -Package npm -CertName "Amazon Root CA 1" -ExtractPath certs\npm
```

### Summary (Windows)

- **Cert source:** either store (`-CertName` + `-ExtractPath`) or file (`-UseCert`).
- **Extract path:** per-user **package-route.pem** and User-level env; re-runs merge and dedupe by fingerprint. Machine-level cert vars are **cleared** so only User applies (avoids duplication if you previously used -UseCert).
- **UseCert:** no PEM written; Machine (if admin) or User env set; when Machine is set, User-level cert vars are **deleted** so only Machine applies.

Users must start a **new terminal** for env changes to take effect.

---

### Windows: validate_install_windows.ps1

**validate_install_windows.ps1** checks that the certificate installation is valid: PEM file(s) exist and are valid (same validation as the install script). **-ExpectedSubject is required.** It does **not** require admin unless you use `-AllUsers`.

| Parameter | Description |
|-----------|-------------|
| `-ExpectedSubject <pattern>` | **Required.** Require at least one cert in each PEM file (bundle) to have a subject matching `<pattern>` (case-insensitive). All certs in the file are checked. |
| `-AllUsers` | **(Admin only.)** For each user in `C:\Users\*`, read their User registry env, resolve cert paths, and validate each PEM. |
| *(no path param)* | Read `NODE_EXTRA_CA_CERTS` and `REQUESTS_CA_BUNDLE` from the current user's environment (User then Machine), then validate each referenced PEM file. |

**Exit code:** 0 if all checks passed, 1 if any check failed.

```powershell
# After install: validate current user's env and cert path(s)
.\validate_install_windows.ps1 -ExpectedSubject Zscaler

# Validate every user's config (run as Administrator)
.\validate_install_windows.ps1 -ExpectedSubject Zscaler -AllUsers
```
