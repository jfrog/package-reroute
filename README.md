# Certificate installation scripts

Scripts to install a CA certificate and configure Node/npm and Python/pip (and related TLS clients).

This document describes the certificate installation and validation scripts for **macOS**, **Linux (Debian/Ubuntu)**, and **Windows**.

| Script | Platform | Purpose |
|--------|----------|---------|
| **install_certs_macos.sh** | macOS | Install cert and set env vars (Node/Python) |
| **validate_install_macos.sh** | macOS | Validate PEM and env config |
| **install_certs_debian_ubuntu.sh** | Debian/Ubuntu | Install cert into system trust + profile.d + user shell rc |
| **validate_certs_debian_ubuntu.sh** | Debian/Ubuntu | Validate PEM and env config |
| **install_certs_windows.ps1** | Windows | Install cert and set env vars (Node/Python) |
| **validate_install_windows.ps1** | Windows | Validate PEM and env config |

Environment variables by platform (see each section for details):

| Variable | Typical use | Notes |
|----------|-------------|--------|
| `NODE_USE_SYSTEM_CA=1` | Node/npm | When **npm** (or **all**) is configured |
| `NODE_EXTRA_CA_CERTS=<path>` | Node/npm | PEM bundle path |
| `UV_NATIVE_TLS` | Python **uv** | macOS install uses **`1`** in `.zshrc`; Debian/Ubuntu and Windows use **`true`** when **python**/**all** is configured |
| `UV_SYSTEM_CERTS=true` | Python **uv** | Debian/Ubuntu and Windows (**python**/**all**); not set by macOS install |
| `REQUESTS_CA_BUNDLE=<path>` | Python TLS clients | Combined bundle path (per platform) |
| `SSL_CERT_FILE=<path>` | OpenSSL-backed tools | Debian/Ubuntu (**python**/**all**); system CA bundle path |
| `HF_HUB_DISABLE_XET=1` | Hugging Face Hub | **python**/**all** (all platforms where the install script supports it) |
| `HF_HUB_ETAG_TIMEOUT=86400` | Hugging Face Hub | Same as `HF_HUB_DISABLE_XET` |
| `HF_HUB_DOWNLOAD_TIMEOUT=86400` | Hugging Face Hub | Same as `HF_HUB_DISABLE_XET` |

---

## macOS: install_certs_macos.sh

### Overview

`install_certs_macos.sh` configures **Node/npm** and/or **Python/pip** on macOS to use a custom CA certificate (e.g. for corporate proxy or package routing). It:

- Runs **only as root** (e.g. `sudo`).
- Either **extracts** one certificate from the macOS Keychain (by name pattern) and writes it to a PEM file, or **uses an existing** PEM file you provide.
- For **each user** in `/Users/*`, writes or updates the certificate file and sets environment variables in that user’s `~/.zshrc` so Node and Python use the certificate.

With **Keychain extraction**, each user gets **package-route.pem** under `~/<extract-path>/`. With **`--use-cert`**, the install uses your PEM path as-is for every user.

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
| `--extract-path <path>` | Yes* | Directory **under each user’s home** where **package-route.pem** is written: `~/<path with leading / stripped>/package-route.pem` (e.g. `opt/certs` → `~/opt/certs/...`, `certs` → `~/certs/...`). Requires `--cert-name`. |
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

**3. Only configure pip (UV_NATIVE_TLS, REQUESTS_CA_BUNDLE)**

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

**validate_install_macos.sh** checks that the certificate installation succeeded: PEM file(s) exist and are valid (via `openssl x509`). **`--expected-subject` is required** for every invocation. It does **not** require root unless you use `--all-users`.

| Option | Description |
|--------|--------------|
| `--expected-subject <pattern>` | **Required.** At least one cert in each PEM file (bundle) must have a subject matching `<pattern>` (case-insensitive). |
| *(default scope)* | Read `NODE_EXTRA_CA_CERTS` and `REQUESTS_CA_BUNDLE` from the current user’s `~/.zshrc` (with `~` expanded), validate each referenced PEM file, and if `HF_HUB_*` exports are present in `.zshrc`, check they match the install script (`HF_HUB_DISABLE_XET=1`, timeouts `86400`). **`UV_NATIVE_TLS` is not validated.** |
| `--all-users` | **(Root only.)** For each user in `/Users/*`, read their `~/.zshrc`, resolve cert paths, and validate each PEM. Use: `sudo ./validate_install_macos.sh --expected-subject <pattern> --all-users`. |

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

Tests live in **testing/**. Automated tests cover **macOS** and **Windows** only (not Debian/Ubuntu).

**test_install_certs_macos.sh** runs automated tests for **install_certs_macos.sh** (CLI and argument validation), **validate_install_macos.sh** (validation with a temp PEM and mock home, including **`HF_HUB_*` value checks** when those exports appear in `.zshrc`), fingerprint/merge logic (same fingerprint → dedupe, different fingerprint → append), **NODE_USE_SYSTEM_CA** / **UV_NATIVE_TLS** ensure logic (add if missing, replace if value ≠ 1, leave as-is if 1), and **`ensure_hf_hub_*`**-style logic for Hugging Face Hub env vars. No root required.

**Requirements:** `openssl` on `PATH` (for generating a temporary cert in tests). Some environments (e.g. restricted sandboxes) may need a normal shell so `openssl` can generate distinct keys for fingerprint tests.

```bash
# From repo root
./testing/test_install_certs_macos.sh

# Or from repo root with testing as current dir
cd testing && ./test_install_certs_macos.sh
```

Exit code 0 if all tests pass, 1 otherwise.

#### Test coverage

| Area | Covered | Not covered |
|------|--------|-------------|
| **install_certs_macos.sh** | **CLI and pre-root:** `--help`; unknown option; invalid `--package`; `--cert-name` without `--extract-path` (and reverse); no cert source; `--use-cert` + `--cert-name` conflict; `--use-cert` with missing file; non-root exit and message. **--use-cert:** valid PEM path and `--package npm`/`pip` (non-root → run as root); invalid PEM content rejected with "Invalid or missing PEM" when run as root (tested when passwordless sudo available). **Fingerprint/merge (no root):** same fingerprint → one cert (dedupe); different fingerprint → both certs appended; `bundle_contains_pem` and merge logic exercised via test helpers. **NODE_USE_SYSTEM_CA / UV_NATIVE_TLS ensure logic:** add if missing; replace if value ≠ 1; leave as-is if 1; idempotent (run twice → single line). **HF_HUB_* ensure tests:** mirror `install_certs_macos.sh` (add three exports; correct a wrong timeout). | **Post-root:** PATH/openssl, `--install-dependencies` (Homebrew); Keychain extraction; per-user loop; writing PEM and updating `.zshrc`. Requires root and/or Keychain; not run in CI. |
| **validate_install_macos.sh** | **CLI:** unknown option (exit 1); missing `--expected-subject` (exit 1). **Main paths:** default with mock `HOME` and `.zshrc`; missing PEM in `.zshrc` (exit 1); invalid `HF_HUB_*` when present (exit 1); valid `HF_HUB_*` with cert path (exit 0); `--all-users` without root (exit 1). Covers `validate_pem`, `get_export_path`, `get_export_value`, `validate_hf_if_present`, `validate_user_config`. | Multi-cert bundle in `validate_pem`; `--all-users` as root. |

Tests are black-box (exit codes and stderr).

#### Windows tests

**test_install_certs_windows.ps1** runs automated tests for **install_certs_windows.ps1** (invalid `-Package`; **`-CertName`** with a pattern that matches nothing in **LocalMachine\Root**; **`-Package python`** and **`-Package all`** with **`-BundlePath`** under a temp dir—exporting the store to a PEM and setting **Machine**-level `NODE_*` / `REQUESTS_CA_BUNDLE` / `UV_NATIVE_TLS` / `UV_SYSTEM_CERTS` / **`HF_HUB_*`** as appropriate) and **validate_install_windows.ps1** (`-ExpectedSubject` required; env-based PEM checks; invalid **User** `HF_HUB_DISABLE_XET` with a valid cert path → exit 1). **Run the test script as Administrator** so install and validate tests can read **LocalMachine\Root**, write the bundle, and set **Machine** environment variables; tests **save and restore** prior Machine values. The script uses a temp directory and an embedded PEM.

**Requirements:** Windows with PowerShell, **elevated** session. The install and validate scripts must be in the parent of `testing/` (repo root).

```powershell
# From repo root (PowerShell on Windows, as Administrator)
powershell -NoProfile -ExecutionPolicy Bypass -File testing/test_install_certs_windows.ps1
```

From a non-Windows host you can run the tests on a Windows VM via SSH (e.g. copy the scripts and invoke the same command over `ssh jump-windows`).

Exit code 0 if all tests pass, 1 otherwise. Output shows pass/fail per test and a final count.

| Area | Covered |
|------|--------|
| **install_certs_windows.ps1** | When run as admin: invalid `-Package`; `-CertName` that matches no cert in **LocalMachine\Root** (exit 1); **`-Package python`** + **`-BundlePath`**: bundle file written; Machine `REQUESTS_CA_BUNDLE`, `UV_NATIVE_TLS` / `UV_SYSTEM_CERTS` = `true`, `HF_HUB_DISABLE_XET` = `1`, etag/download timeouts `86400`; npm Machine vars unset. **`-Package all`** + **`-BundlePath`**: npm and Python/HF Machine vars point at the same bundle. Default **`-BundlePath`** (implicit `-Package all`): exports store, exits 0. Saves/restores eight Machine vars (including **`HF_HUB_*`**) around the install tests. |
| **validate_install_windows.ps1** | `-ExpectedSubject` required (exit 1 if missing); current user env (no paths → exit 0); env path to valid PEM (exit 0), missing file (exit 1), invalid PEM (exit 1); subject mismatch (exit 1); system-level (Machine) env when run as admin; **User `HF_HUB_DISABLE_XET` ≠ `1`** with valid PEM → exit 1. `-AllUsers` checks Machine bundle paths and UV/HF, then per-user User env for PEM paths. |

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
- **If no existing export:** append a blank line, ensure `NODE_USE_SYSTEM_CA=1` (add if missing), and `export NODE_EXTRA_CA_CERTS="<cert_path>"`.
- **If export already exists:** replace that line so it points to the **admin’s** cert path; ensure `NODE_USE_SYSTEM_CA=1` (add if missing, replace if value ≠ 1, leave if already 1).
- **Merge PEMs:** read the **old** bundle file (previous path); append every cert from it into the **new** cert file, **except**: (1) certs with the same fingerprint as the one we’re installing, (2) certs already present in the new file (by fingerprint). So the new file ends up with: **our cert first**, then any other CAs from the old file that aren’t duplicates.

For **pip** (if `--package` is `pip` or `all`):

- Ensure `UV_NATIVE_TLS=1`: add if missing, replace if value ≠ 1, leave as-is if already 1.
- Same idea for `REQUESTS_CA_BUNDLE`: add export if missing, or replace the path and merge the old bundle into the new cert file (again skipping duplicates by fingerprint).

Fingerprints are SHA-256 via `openssl x509 -fingerprint -sha256 -noout`.

---

#### Flowchart

<img src="images/flowchart.svg" width="700" alt="install_certs_macos.sh flowchart" />

---

#### Summary (macOS)

- **One run as root** (optionally with `--install-dependencies` to install openssl).
- **One cert source:** either Keychain (--cert-name + --extract-path) or existing file (--use-cert).
- **Per user:** PEM at `~/<extract-path>/package-route.pem` for each user (leading `/` on `--extract-path` is stripped); env vars in `~/.zshrc` point to that path. With `--use-cert`, the same PEM path is used for every user.
- **If user already had a different path:** script replaces it with the admin’s path and merges other certs from the old file into the new one (no duplicate certs by fingerprint).

Users must open a **new terminal** (or `source ~/.zshrc`) for the new environment variables to take effect.

---

## Linux (Debian/Ubuntu): install_certs_debian_ubuntu.sh

### Overview

`install_certs_debian_ubuntu.sh` installs a PEM/CRT into the **Debian/Ubuntu system trust store** (`update-ca-certificates`), writes a managed file under **`/etc/profile.d/package-route-certs.sh`**, and updates the **invoking non-root user’s** shell rc (`~/.zshrc` or `~/.bashrc`, depending on their login shell). It **only** supports an existing certificate file (**`--use-cert`**); there is no Keychain or cert-store extraction on Linux in this repo.

- **npm:** `NODE_USE_SYSTEM_CA=1` and `NODE_EXTRA_CA_CERTS` point at the **system** CA bundle (`/etc/ssl/certs/ca-certificates.crt`) after `update-ca-certificates`, so Node trusts the same combined bundle as the OS.
- **Python / Hugging Face / uv:** `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`, `UV_NATIVE_TLS=true`, `UV_SYSTEM_CERTS=true`, and **`HF_HUB_DISABLE_XET`**, **`HF_HUB_ETAG_TIMEOUT`**, **`HF_HUB_DOWNLOAD_TIMEOUT`** (when `--package` includes **python** or **all**) use the same combined bundle and Hub timeout/disable flags as in the install script.

### Requirements

- **Debian or Ubuntu** (script checks `/etc/os-release`).
- **Root** (`sudo`).
- **`openssl`** and **`update-ca-certificates`** on `PATH`.

### Options

| Option | Required | Description |
|--------|----------|-------------|
| `--use-cert <path>` | **Yes** | Path to an existing PEM/CRT file. |
| `--package npm\|python\|all` | No (default: **all**) | What to configure: npm, Python tooling (including **`HF_HUB_*`** when enabled), or both. |
| `--cert-name <name>` | No (default: `package-route-custom-ca`) | Base name for the file installed under `/usr/local/share/ca-certificates/<name>.crt` (not a Keychain/subject pattern). |
| `-h`, `--help` | — | Usage. |

### Examples

```bash
sudo ./install_certs_debian_ubuntu.sh --use-cert /tmp/company-ca.pem
sudo ./install_certs_debian_ubuntu.sh --use-cert /tmp/company-ca.pem --package npm
sudo ./install_certs_debian_ubuntu.sh --use-cert /tmp/company-ca.pem --package python
sudo ./install_certs_debian_ubuntu.sh --use-cert /tmp/company-ca.pem --cert-name my-org-ca
```

### Validation: validate_certs_debian_ubuntu.sh

**`--expected-subject` is required.** Checks PEM paths from the current user’s `~/.bashrc` / `~/.zshrc` and, when present, **`/etc/profile.d/package-route-certs.sh`** (`NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`). If **`UV_NATIVE_TLS` / `UV_SYSTEM_CERTS`** or **`HF_HUB_*`** appear in those files, values must match the install script (`UV_*` = `true`; `HF_HUB_DISABLE_XET` = `1`; timeouts = `86400`). With **`--all-users`** (root only), validates `/home/*` users’ rc files.

```bash
./validate_certs_debian_ubuntu.sh --expected-subject "O=Example"
sudo ./validate_certs_debian_ubuntu.sh --all-users --expected-subject "O=Example"
```

---

## Windows: install_certs_windows.ps1

### Overview

`install_certs_windows.ps1` configures **Node/npm** and/or **Python** tooling on Windows to trust a **combined CA bundle** for redirected package traffic. **It must be run as Administrator;** the script exits with an error otherwise.

- Exports **all** certificates from **LocalMachine\Root** into a **single PEM file** (default **`C:\ProgramData\JFrog\corporate-certs\ca-bundle.pem`**, overridable with **`-BundlePath`**). That file is the effective trust bundle (public roots plus corporate roots already in the store).
- Optionally **`-CertName`** (substring): verifies that at least one cert in **LocalMachine\Root** matches before export; the script still exports the **entire** Root store, not one cert.
- Sets **Machine**-level environment variables (new processes pick them up after a new terminal or sign-in):
  - **npm:** `NODE_USE_SYSTEM_CA=1`, `NODE_EXTRA_CA_CERTS` = bundle path.
  - **python** (`-Package python` or `all`): `REQUESTS_CA_BUNDLE` = bundle path, `UV_NATIVE_TLS` / `UV_SYSTEM_CERTS` = `true`, **`HF_HUB_DISABLE_XET=1`**, **`HF_HUB_ETAG_TIMEOUT`** / **`HF_HUB_DOWNLOAD_TIMEOUT`** = `86400`.

### Requirements

- **Windows** with PowerShell.
- **Run as Administrator.** The script checks and exits with an error if not elevated.

### How to use

Run from a directory that contains the script (or use full path):

```powershell
powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package all
powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package python -BundlePath C:\ProgramData\MyOrg\ca-bundle.pem
powershell -ExecutionPolicy Bypass -File install_certs_windows.ps1 -Package all -CertName Zscaler
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Package` | No (default: **all**) | `npm`, `python`, or `all`. |
| `-CertName` | No | If set, substring match against cert **Subject** in **LocalMachine\Root**; errors if no match. Does not change export behavior (full store is still exported). |
| `-BundlePath` | No | Output PEM path (default: `C:\ProgramData\JFrog\corporate-certs\ca-bundle.pem`). Parent directory is created if needed. |

### Examples

**Export LocalMachine\Root and configure npm + Python (run as admin):**

```powershell
.\install_certs_windows.ps1 -Package all
```

**Python tooling only, custom bundle path:**

```powershell
.\install_certs_windows.ps1 -Package python -BundlePath D:\certs\corp-bundle.pem
```

**Require a corporate root to be present in the store before export:**

```powershell
.\install_certs_windows.ps1 -Package all -CertName Zscaler
```

**Only npm:**

```powershell
.\install_certs_windows.ps1 -Package npm
```

### Summary (Windows)

- **Admin required.**
- **One PEM bundle** from **LocalMachine\Root**; **`NODE_EXTRA_CA_CERTS`** / **`REQUESTS_CA_BUNDLE`** point at that file when the matching `-Package` set is enabled.
- **Python package** also sets **`UV_*`** and **`HF_HUB_*`** as documented above.

Users must start a **new terminal** (or sign out/in) for Machine env changes to take effect.

---

### Windows: validate_install_windows.ps1

**validate_install_windows.ps1** checks that PEM path(s) from **`NODE_EXTRA_CA_CERTS`** / **`REQUESTS_CA_BUNDLE`** (User then Machine) exist, are valid, and contain a cert whose subject matches **`-ExpectedSubject`**. If **`UV_NATIVE_TLS`** / **`UV_SYSTEM_CERTS`** or **`HF_HUB_*`** are set in the effective environment, values must match the install script (`UV_*` = `true`; `HF_HUB_DISABLE_XET` = `1`; timeouts = `86400`). **`-ExpectedSubject` is required.** Admin is only required for **`-AllUsers`**.

| Parameter | Description |
|-----------|-------------|
| `-ExpectedSubject <pattern>` | **Required.** At least one cert in each PEM file (bundle) must have a subject matching `<pattern>` (case-insensitive). |
| *(default scope)* | Resolve cert paths from the current user’s environment (User overrides Machine for each variable), validate PEMs. |
| `-AllUsers` | **(Admin only.)** Validates Machine-level bundle paths and UV/HF, then walks **`C:\Users\*`** profiles for User-level overrides and PEM paths. |

**Exit code:** 0 if all checks passed, 1 if any check failed.

```powershell
# After install: validate current user's env and cert path(s)
.\validate_install_windows.ps1 -ExpectedSubject Zscaler

# Validate every user's config (run as Administrator)
.\validate_install_windows.ps1 -ExpectedSubject Zscaler -AllUsers
```

---

## Continuous integration

On **push** and **pull request** to `main` or `master`, GitHub Actions runs:

| Job | Runner | Command |
|-----|--------|---------|
| Test (macOS) | `macos-latest` | `sudo ./testing/test_install_certs_macos.sh` |
| Test (Windows) | `windows-latest` | `./testing/test_install_certs_windows.ps1` (PowerShell) |

There is no CI job for the Debian/Ubuntu scripts in this workflow.
