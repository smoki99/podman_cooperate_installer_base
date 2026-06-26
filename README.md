# 🚀 Enterprise Podman Desktop Deployment for Windows 11

This repository contains a **Zero-Touch, Enterprise-Grade Deployment Solution** for Podman Desktop and WSL2 on Windows 11. 

It is specifically engineered for highly regulated corporate environments that utilize **Transparent Proxies (with SSL Inspection)**, **Strict VPNs (like Cisco AnyConnect)**, enforce **No Local Admin Rights** for developers, and require a **Zero-Trust Container Registry Architecture**.

## ✨ Key Features

*   **Zero-Touch User Experience:** Developers do not see setup wizards, telemetry prompts, or EULAs. Everything is pre-configured silently.
*   **Zero-Trust Registry Enforcement:** Modifies the internal Linux `policy.json` to block all external registries (like Docker Hub or GHCR) and forces image pulls *only* from your approved corporate registry.
*   **Transparent Proxy & SSL Inspection Bypass:** Automatically injects your Corporate Root CA into the WSL machine so `podman pull` doesn't fail with `x509: unknown authority` errors.
*   **Cisco VPN Compatibility:** Enforces WSL2 **Mirrored Networking** and **DNS Tunneling** to prevent IP/Subnet collisions with corporate VPNs.
*   **Self-Healing Architecture:** A SYSTEM-level scheduled task runs at every boot to enforce `.wslconfig` limits (saving RAM) and clear stuck `wslhost.exe` processes.
*   **Socket Emulation:** Automatically sets the `DOCKER_HOST` environment variable so developer IDEs (VS Code, IntelliJ) and tools like Testcontainers work out-of-the-box.

---

## 📁 Repository Structure

Your deployment package must contain the following files in a single folder:

```text
📁 Podman-Deployment/
 ┣ 📜 README.md                     (This file)
 ┣ 📜 podman-desktop-setup.exe      (The official offline installer for WSL2)
 ┣ 📜 podman-installer-windows-amd64.msi  (Podman CLI MSI installer - see Preparation section below)
 ┣ 📜 CorporateRootCA.cer           (OPTIONAL: Your company's Base64 Root CA)
 ┣ 📜 podman-config.json            (Central configuration file)
 ┣ 📜 Install-Master.ps1            (Phase 1: SYSTEM context installer)
 ┣ 📜 Init-PodmanUser.ps1           (Phase 2: USER context initializer)
 ┣ 📜 SelfHeal-Podman.ps1           (Phase 3: Boot-time maintenance script)
 ┣ 📜 PreReboot-Checklist.md        (Pre-reboot validation guide)
 ┗ 📜 Run-Test.cmd                  (Helper script for local manual testing)
```

---

## 🛠️ Preparation & Prerequisites

Before deploying this package via Microsoft Intune, SCCM, or testing it locally, you must prepare the payload:

1. **Download the Podman Desktop Installer:**
   Download the latest `.exe` installer from the [Podman Desktop Website](https://podman-desktop.io/) and place it in this directory. Ensure it is named exactly `podman-desktop-setup.exe`.
2. **Download the Podman CLI MSI Installer (Required):**
   The Podman CLI is NOT included with Podman Desktop installation. You must download it separately:
   * Go to [Podman GitHub Releases](https://github.com/containers/podman/releases)
   * Download `podman-installer-windows-amd64.msi` from the latest release (note: only Windows AMD64 MSI installers are available for WSL2)
   * Place `podman-installer-windows-amd64.msi` in this directory (same folder as `podman-desktop-setup.exe`)
3. **Export your Corporate Root CA (Optional but recommended):**
   If your company uses a Transparent Proxy that performs SSL Inspection, export your Root CA certificate as a Base64 encoded `.cer` file. Name it `CorporateRootCA.cer` and place it in this folder.
4. **Configure `podman-config.json`:**
   Open the JSON file and adjust it to your corporate standards.
   ```json
   {
       "CorporateSettings": {
           "MaxMemory": "8GB",
           "Processors": "4",
           "MTU": 1350
       },
       "Registries": {
           "AllowedSearchRegistry": "registry.your-company.com"
       },
       "Paths": {
           "SecureStorage": "C:\\ProgramData\\CorporateIT\\Podman"
       }
   }
   ```
   * `MaxMemory` / `Processors`: Limits WSL so developer laptops don't freeze.
   * `MTU`: **Crucial for VPNs.** Low MTU prevents `podman pull` from hanging. `1350` is a safe default; use `1300` if issues persist inside Cisco AnyConnect.
   * `AllowedSearchRegistry`: The only registry developers can pull from (Zero-Trust whitelist). **Replace `registry.your-company.com` with your actual registry before deployment.**
   * `SecureStorage`: The target directory where scripts are copied by `Install-Master.ps1`. All other scripts derive this path from the config automatically.

---

## 🚀 How to Use / Test Manually

If you are the IT administrator testing this package on a test machine:

1. Log into the Windows 11 machine.
2. Open the `Podman-Deployment` folder.
3. Double-click the **`Run-Test.cmd`** file.
4. Accept the UAC (Admin prompt).
5. Watch the blue PowerShell console output. It will activate WSL features, copy the payload to a secure location (`C:\ProgramData\...`), install Podman Desktop silently, and register the background tasks.
6. **OPTIONAL: Pre-Reboot Validation** - Before rebooting, you can run the automated validation script from `PreReboot-Checklist.md` to verify all components were installed correctly.
7. **REBOOT THE PC.** (Mandatory to initialize Windows Virtual Machine Platform).
8. Log in as a standard, non-admin Developer.
9. Wait ~30 seconds for the background `Podman-User-Init` task to finish.
10. Open Podman Desktop. It is fully configured and ready.

---

## 🏢 Enterprise Deployment (Intune / SCCM)

To deploy this across your organization using Microsoft Intune:

1. Package this entire directory using the **Microsoft Win32 Content Prep Tool** (`IntuneWinAppUtil.exe`) into a `.intunewin` file.
2. Create a new Win32 App in Intune.
3. **Install Command:** 
   `powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File ".\Install-Master.ps1"`
4. **Uninstall Command:** 
   `"%ProgramFiles%\Podman Desktop\Uninstall Podman Desktop.exe" /S`
   > ⚠️ The uninstall command removes the application binary but does **not** clean up scheduled tasks or the `SecureStorage` directory. After uninstalling, manually remove:
   > * Scheduled tasks `Podman-User-Init` and `Podman-SelfHeal` (via `schtasks /delete`)
   > * The directory defined in `Paths.SecureStorage` (default: `C:\ProgramData\CorporateIT\Podman`)
   > * The `DOCKER_HOST` machine environment variable
5. **Install Behavior:** `System` (Very important!)
6. **Device Restart Behavior:** `Determine behavior based on return codes` (Force a restart so WSL initializes).
   * Add return code **`3010`** → "Soft reboot required". `Install-Master.ps1` exits with this code so Intune knows to schedule a restart.
7. **Detection Rule:**
   * Rule type: File/Folder
   * Path: `C:\Program Files\Podman Desktop`
   * File/Folder: `Podman Desktop.exe`
   * Method: File/Folder exists

---

## 🧠 Under the Hood (Architecture Details)

Podman deployment is notoriously difficult because the application is installed as `SYSTEM`, but the Linux VM (`podman machine`) must belong to the standard `USER`. This solution bridges that gap using three scheduled scripts:

### Phase 1: `Install-Master.ps1` (SYSTEM Context)
Executed by your deployment tool. It enables Windows features (Hyper-V/WSL), installs the `.exe` silently to `C:\Program Files\`, and creates two Scheduled Tasks. It stores the corporate scripts in a protected directory so users cannot tamper with them.

### Phase 2: `Init-PodmanUser.ps1` (USER Context)
Triggered once via a Logon Task when the developer logs in. It runs completely silently without requiring admin rights.
* Writes a pre-configured `settings.json` to bypass UI pop-ups and enable Windows Certificate Syncing.
* Runs `podman machine init` and `start`.
* Uses `wsl -u root` to inject `CorporateRootCA.cer` into the Linux trust store.
* Overwrites `/etc/containers/policy.json` to block default registries and enforce your private registry.
* Translates unqualified image pulls (e.g., `podman pull nginx`) to route to your private registry (e.g., `registry.your-company.com/nginx`).

### Phase 3: `SelfHeal-Podman.ps1` (SYSTEM Context)
Runs at System Startup. Developer environments break often (stuck network routes, manipulated config files).
* Forces the deployment of the `.wslconfig` file into `C:\Users\%USERNAME%\`. It enforces `networkingMode=mirrored` and memory limits. If a developer attempts to give WSL 32GB of RAM, this script resets it to the corporate standard upon next boot.
* Ensures the `DOCKER_HOST` environment variable is always correctly pointed to the Podman named pipe.

---

## ⚠️ Troubleshooting

* **Issue: `podman pull` is rejected.**
  * *Reason:* The Zero-Trust policy is active. You must pull from the registry defined in `podman-config.json`. You cannot pull from `docker.io` unless you change the policy logic.
* **Issue: `podman pull` hangs at 99% or times out inside the Cisco VPN.**
  * *Fix:* The Cisco VPN MTU might be lower than 1350. Adjust the `"MTU"` value in `podman-config.json` to `1300` and redeploy.
* **Issue: IDEs (VS Code/IntelliJ) say "Docker is not running".**
  * *Fix:* Ensure the `DOCKER_HOST` system environment variable is set to `npipe:////./pipe/podman-machine-default`. A system restart usually fixes this if the variable hasn't propagated to the IDE yet.