# CachyOS Kernel Installer & Updater (Shell Edition)

A lightweight, dependency-free, pure **Bash (.sh)** tool for Debian systems to check, download, configure, compile, install, sign, and rollback performance-optimized **CachyOS Linux Kernels**.

![Debian](https://img.shields.io/badge/Debian-Bookworm%20%2F%20Trixie%20%2F%20Sid-A81D33?logo=debian&logoColor=white)
![Shell](https://img.shields.io/badge/Language-Bash%20Shell-4EAA25?logo=gnu-bash&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-blue.svg)

---

## 💡 Why the Shell Edition?

When building the original [Debian CachyOS Kernel Updater](https://github.com/Antux912012/debian-cachy-kernel-updater), we built a full GTK4 / Libadwaita Python application, complete with AppImage bundling and APT repository pipelines. 

While the GUI looks modern, **kernel management is fundamentally a command-line and system task**. Rebuilding this from scratch as a shell script yields tremendous advantages:

| Feature / Aspect | GTK4 Python App | Shell Script Edition (`.sh`) |
| :--- | :--- | :--- |
| **Dependencies** | Requires GTK4, Libadwaita, PyGObject, Cairo (`~150MB+` dependencies) | Standard POSIX tools: `bash`, `curl`, `tar`, `make` |
| **Headless / Server Support** | ❌ Requires X11/Wayland display server | ✅ Works everywhere: headless, SSH, tty, servers, containers |
| **Startup Overhead** | ~1–2 seconds to initialize Python runtime & GTK | **Instantaneous (0 ms)** |
| **Packaging Burden** | Complex AppImage builds (54 MB) & Debian packaging | **Zero packaging needed** — run directly from script |
| **Reproducibility** | Depends on desktop environment runtime libraries | Transparent, self-contained shell commands |
| **Automation** | Difficult to script or run in headless CI/CD | Full CLI flags (`--all`, `--check`, `--build`, etc.) |

---

## 🚀 Features

1. **Official CachyOS Version Checking:** Queries the official CachyOS GitHub API and upstream PKGBUILD to detect the latest stable release (e.g. `7.2.9-2`).
2. **System Comparison:** Automatically verifies whether your currently running kernel matches the latest CachyOS release.
3. **Dual Build Modes:**
   - **Host Mode:** Multi-threaded native compilation (`make -j$(nproc) bindeb-pkg`).
   - **Container Mode (`--container`):** Clean, isolated compilation inside a `debian:bookworm-slim` container using **Podman** or **Docker**.
   - *Note: Kernel compilation is an intensive workload and can take a while (typically 15 to 45+ minutes) depending on your system's processing power, CPU core count, and cooling.*
4. **Automated Debian Kernel Tweaks:**
   - Disables Debian trusted keys (`SYSTEM_TRUSTED_KEYS`) to prevent certificate build failures.
   - Disables excessive debug info (`CONFIG_DEBUG_INFO_NONE=y`) to prevent massive 40GB+ debug packages and disk exhaustion.
   - Disables enterprise virtualization features (`CONFIG_INTEL_TDX_HOST`) that fail on desktop toolchains.
   - Sets custom localversion: `-cachyos-debian`.
   - Runs `make olddefconfig` smoothly.
5. **Organized Output in `~/kernel-build-deb/`:**
   - Generates and organizes all `.deb` packages (`linux-image`, `linux-headers`, `linux-libc-dev`), `kernel.config`, and a self-contained `install.sh` helper in:
     `~/kernel-build-deb/Linux-kernel-CachyOS-<version>-debian/`
6. **Automatic Installation & GRUB Update:**
   - Installs the generated `.deb` packages using `dpkg` and updates GRUB configuration.
7. **UEFI Secure Boot (MOK) Signing:**
   - Automatically detects if Secure Boot is enabled (`mokutil --sb-state`).
   - Locates or generates a Machine Owner Key (MOK) pair.
   - Signs the newly installed `/boot/vmlinuz-*` binary using `sbsign`.
8. **Kernel Rollback & Management:**
   - Safely lists installed `linux-image-*` packages.
   - Protects the currently active running kernel from accidental deletion.
   - Purges selected older kernels and runs `update-grub`.
9. **Persistent Config Backup:**
   - Preserves generated kernel configuration to `~/.config/cachy-kernel-updater/kernel.config` across builds and updates.

---

## 📦 Quick Start

### 1. Run Interactively (Menu-Driven)
Simply run the script with no arguments:

```bash
cd ~/cachyos-kernel-sh
./cachyos-kernel.sh
```

You will be greeted with an intuitive terminal menu:
```text
  Actions:
  [1] Check for latest CachyOS Kernel release
  [2] Install build dependencies (Host tools & APT)
  [3] Build CachyOS Kernel (Native Host Compiler)
  [4] Build CachyOS Kernel (Isolated Container: Podman/Docker)
  [5] Install compiled kernel packages (.deb) & Update GRUB
  [6] Sign installed kernel for UEFI Secure Boot (MOK)
  [7] Rollback / Remove installed kernel packages
  [8] Clean build cache (Preserves saved .config)
  [9] Full Upgrade (Check -> Build Host -> Install -> Sign)
  [0] Exit
```

---

## ⚙️ Command-Line Flags (Scripting & Automation)

You can also run specific tasks directly or script the workflow:

| Flag | Description |
| :--- | :--- |
| `-c`, `--check` | Check if an update is available against the currently running kernel |
| `-d`, `--deps` | Verify and install missing build packages via APT |
| `-b`, `--build` | Download, configure, and compile the kernel on the host system |
| `--container` | Compile inside an isolated Debian container (`podman` or `docker`) |
| `-i`, `--install` | Install compiled `.deb` packages and run `update-grub` |
| `-s`, `--sign` | Sign the installed kernel binary for UEFI Secure Boot |
| `-r`, `--rollback` | Launch the interactive kernel rollback tool |
| `--clean` | Clean up `~/.cache/cachy-kernel-build` while preserving `.config` |
| `-a`, `--all` | Full end-to-end run (Check → Build → Install → Sign) |
| `-j`, `--threads <N>` | Number of CPU threads for `make` (default: all CPU cores) |
| `-v`, `--version <VER>` | Specify a specific CachyOS kernel version (e.g. `7.2.9-2`) |
| `-h`, `--help` | Display usage and help manual |

### Examples:

```bash
# Check version status
./cachyos-kernel.sh --check

# Compile inside isolated Podman/Docker container
./cachyos-kernel.sh --build --container

# Compile on host with 8 CPU threads
./cachyos-kernel.sh --build -j 8

# Install previously compiled packages
./cachyos-kernel.sh --install

# One-command full automated upgrade
./cachyos-kernel.sh --all
```

---

## 🔐 Secure Boot & MOK Signing

If your system has UEFI Secure Boot enabled, the script will automatically detect it and sign the kernel:

1. If you don't have a MOK key pair, the script automatically generates one in `~/.config/cachy-kernel-updater/mok/`.
2. First-time MOK enrollment requires importing the public certificate once:
   ```bash
   sudo mokutil --import ~/.config/cachy-kernel-updater/mok/MOK.der
   ```
3. Set a simple temporary password, reboot, and in the blue **MOKManager** screen:
   * Select **Enroll MOK** → **Continue** → Enter password → **Reboot**.
4. Future kernel upgrades are signed automatically with your key without needing to re-enroll!

---

## 📄 License
This project is licensed under the GPL-3.0 License.
