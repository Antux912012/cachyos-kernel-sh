#!/usr/bin/env bash
# ==============================================================================
# CachyOS Linux Kernel Installer, Updater & Manager for Debian
# Pure, lightweight Shell implementation (.sh)
# Compatible with Debian Bookworm (12), Trixie (13), Sid & derivatives
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Global Paths & Defaults
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}"
BUILD_CACHE_DIR="${CACHE_BASE}/cachy-kernel-build"

CONFIG_BASE="${XDG_CONFIG_HOME:-$HOME/.config}"
PERSISTENT_CONFIG_DIR="${CONFIG_BASE}/cachy-kernel-updater"
SAVED_CONFIG_FILE="${PERSISTENT_CONFIG_DIR}/kernel.config"

OUTPUT_BASE_DIR="$HOME/kernel-build-deb"

CONTAINER_IMAGE_TAG="cachyos-kernel-builder:debian"

# URLs
CACHY_RELEASES_API="https://api.github.com/repos/CachyOS/linux/releases?per_page=30"
CACHY_PKGBUILD_RAW="https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/linux-cachyos/PKGBUILD"
CACHY_CONFIG_RAW="https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/linux-cachyos/config"

# Dependencies
REQUIRED_BUILD_DEPS=(
    build-essential
    libncurses-dev
    bison
    flex
    libssl-dev
    libelf-dev
    libdw-dev
    bc
    rsync
    debhelper
    pahole
    kmod
    cpio
    curl
    ca-certificates
    jq
    zstd
    tar
    xz-utils
)

# Terminal Styling
if [ -t 1 ]; then
    COLOR_RESET="\033[0m"
    COLOR_BOLD="\033[1m"
    COLOR_RED="\033[1;31m"
    COLOR_GREEN="\033[1;32m"
    COLOR_YELLOW="\033[1;33m"
    COLOR_BLUE="\033[1;34m"
    COLOR_MAGENTA="\033[1;35m"
    COLOR_CYAN="\033[1;36m"
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_MAGENTA=""
    COLOR_CYAN=""
fi

# ------------------------------------------------------------------------------
# Helper Logging Functions
# ------------------------------------------------------------------------------
log_info()    { echo -e "${COLOR_BLUE}[*]${COLOR_RESET} $*"; }
log_step()    { echo -e "\n${COLOR_CYAN}==>${COLOR_RESET} ${COLOR_BOLD}$*${COLOR_RESET}"; }
log_success() { echo -e "${COLOR_GREEN}[✓]${COLOR_RESET} $*"; }
log_warn()    { echo -e "${COLOR_YELLOW}[!]${COLOR_RESET} $*"; }
log_error()   { echo -e "${COLOR_RED}[-] Error:${COLOR_RESET} $*" >&2; }

print_banner() {
    cat << "EOF"
  ____            _               ___  ____  
 / ___|__ _  ___| |__  _   _   / _ \/ ___| 
| |   / _` |/ __| '_ \| | | | | | | \___ \ 
| |__| (_| | (__| | | | |_| | | |_| |___) |
 \____\__,_|\___|_| |_|\__, |  \___/|____/ 
                       |___/               
    Debian Kernel Installer & Updater (Shell Edition)
EOF
}

# ------------------------------------------------------------------------------
# Privilege Escalation Helper
# ------------------------------------------------------------------------------
run_as_root() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif command -v pkexec >/dev/null 2>&1; then
        pkexec "$@"
    else
        log_error "Root privileges required, but neither sudo nor pkexec is available."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Version Detection & Comparison
# ------------------------------------------------------------------------------
get_running_kernel() {
    uname -r
}

fetch_latest_cachy_release() {
    local target_tag=""
    local target_ver=""
    local download_url=""

    # 1. Try querying GitHub API using curl + jq
    if command -v curl >/dev/null 2>&1; then
        local api_json
        api_json=$(curl -fsSL -H "User-Agent: CachyOS-Kernel-SH" "$CACHY_RELEASES_API" 2>/dev/null || true)
        if [ -n "$api_json" ] && command -v jq >/dev/null 2>&1; then
            # Find the latest release tag starting with cachyos- and not an -rc
            target_tag=$(echo "$api_json" | jq -r '
                [.[] | select(.tag_name | startswith("cachyos-") and (contains("-rc") | not))]
                | first | .tag_name // empty
            ' 2>/dev/null || true)

            if [ -n "$target_tag" ]; then
                target_ver="${target_tag#cachyos-}"
                download_url=$(echo "$api_json" | jq -r --arg tag "$target_tag" '
                    .[] | select(.tag_name == $tag) | .assets[]
                    | select(.name | endswith(".tar.gz") and (endswith(".asc") | not))
                    | .browser_download_url
                ' | head -n 1 2>/dev/null || true)
            fi
        fi
    fi

    # 2. Fallback: Check PKGBUILD on raw GitHub
    if [ -z "$target_ver" ]; then
        local pkgbuild
        pkgbuild=$(curl -fsSL "$CACHY_PKGBUILD_RAW" 2>/dev/null || true)
        if [ -n "$pkgbuild" ]; then
            local major minor tagrel
            major=$(echo "$pkgbuild" | grep -E '^\s*_major=' | head -n 1 | cut -d '=' -f2 | tr -d ' "')
            minor=$(echo "$pkgbuild" | grep -E '^\s*_minor=' | head -n 1 | cut -d '=' -f2 | tr -d ' "')
            tagrel=$(echo "$pkgbuild" | grep -E '^\s*_tagrel=' | head -n 1 | cut -d '=' -f2 | tr -d ' "')
            [ -z "$tagrel" ] && tagrel="1"
            if [ -n "$major" ] && [ -n "$minor" ]; then
                target_ver="${major}.${minor}-${tagrel}"
                target_tag="cachyos-${target_ver}"
                download_url="https://github.com/CachyOS/linux/releases/download/${target_tag}/${target_tag}.tar.gz"
            fi
        fi
    fi

    if [ -z "$target_ver" ]; then
        log_error "Could not detect the latest CachyOS release. Check internet connection or GitHub API limits."
        return 1
    fi

    if [ -z "$download_url" ]; then
        download_url="https://github.com/CachyOS/linux/releases/download/${target_tag}/${target_tag}.tar.gz"
    fi

    echo "$target_ver|$target_tag|$download_url"
}

check_update_status() {
    log_step "Checking Kernel Versions"
    local running
    running=$(get_running_kernel)
    echo -e "Currently running kernel : ${COLOR_BOLD}${running}${COLOR_RESET}"

    local release_info
    release_info=$(fetch_latest_cachy_release)
    local latest_ver latest_tag download_url
    IFS='|' read -r latest_ver latest_tag download_url <<< "$release_info"

    echo -e "Latest CachyOS release   : ${COLOR_BOLD}${COLOR_GREEN}${latest_ver}${COLOR_RESET} (${latest_tag})"

    local base_ver
    base_ver="${latest_ver%%-*}"

    if [[ "$running" == *"$base_ver"* && "$running" == *"cachy"* ]]; then
        log_success "You are running the latest CachyOS kernel series (${running})!"
        return 0
    else
        log_warn "A newer CachyOS kernel is available or you are currently on stock Debian kernel."
        echo -e "  Update target: ${COLOR_CYAN}${latest_ver}${COLOR_RESET}"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Dependency Management
# ------------------------------------------------------------------------------
get_container_engine() {
    if command -v podman >/dev/null 2>&1; then
        echo "podman"
    elif command -v docker >/dev/null 2>&1; then
        echo "docker"
    else
        echo ""
    fi
}

check_dependencies() {
    local use_container="${1:-false}"
    local missing=()

    for pkg in "${REQUIRED_BUILD_DEPS[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            missing+=("$pkg")
        fi
    done

    if [ "$use_container" = "true" ]; then
        local engine
        engine=$(get_container_engine)
        if [ -z "$engine" ]; then
            missing+=("podman")
        fi
    fi

    echo "${missing[@]}"
}

install_dependencies() {
    local use_container="${1:-false}"
    log_step "Checking & Installing Build Dependencies"

    local missing
    missing=$(check_dependencies "$use_container")

    if [ -n "$missing" ]; then
        log_info "Missing dependencies: ${COLOR_YELLOW}${missing}${COLOR_RESET}"
        log_info "Requesting root permissions to install packages via APT..."
        run_as_root apt-get update
        # shellcheck disable=SC2086
        run_as_root apt-get install -y $missing
        log_success "System build dependencies installed successfully."
    else
        log_success "All required system build packages are already installed."
    fi

    if [ "$use_container" = "true" ]; then
        ensure_container_image
    fi
}

# ------------------------------------------------------------------------------
# Container Build Engine
# ------------------------------------------------------------------------------
ensure_container_image() {
    local engine
    engine=$(get_container_engine)
    if [ -z "$engine" ]; then
        log_error "Neither podman nor docker was found. Please install podman or docker."
        return 1
    fi

    log_step "Verifying Container Builder Image (${CONTAINER_IMAGE_TAG})"
    local image_exists=false
    if [ "$engine" = "podman" ]; then
        if podman image exists "$CONTAINER_IMAGE_TAG" 2>/dev/null; then
            image_exists=true
        fi
    else
        if docker inspect --type=image "$CONTAINER_IMAGE_TAG" >/dev/null 2>&1; then
            image_exists=true
        fi
    fi

    if [ "$image_exists" = "true" ]; then
        # Check that libdw-dev exists in container image
        if "$engine" run --rm "$CONTAINER_IMAGE_TAG" dpkg-query -W -f='${Status}' libdw-dev 2>/dev/null | grep -q "install ok installed"; then
            log_success "Container image '${CONTAINER_IMAGE_TAG}' is up to date."
            return 0
        fi
    fi

    log_info "Building Debian Bookworm builder image '${CONTAINER_IMAGE_TAG}' using ${engine}..."
    local containerfile="${SCRIPT_DIR}/Containerfile"
    if [ ! -f "$containerfile" ]; then
        containerfile="${BUILD_CACHE_DIR}/Containerfile"
        mkdir -p "$BUILD_CACHE_DIR"
        cat << 'EOF' > "$containerfile"
FROM docker.io/library/debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    bc \
    bison \
    flex \
    libelf-dev \
    libssl-dev \
    libncurses-dev \
    libdw-dev \
    rsync \
    kmod \
    cpio \
    pahole \
    zstd \
    tar \
    xz-utils \
    dpkg-dev \
    debhelper \
    python3 \
    gcc \
    make \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
EOF
    fi

    "$engine" build -t "$CONTAINER_IMAGE_TAG" -f "$containerfile" "$(dirname "$containerfile")"
    log_success "Builder container '${CONTAINER_IMAGE_TAG}' prepared successfully."
}

# ------------------------------------------------------------------------------
# Cache Management & Persistent Config
# ------------------------------------------------------------------------------
backup_saved_config() {
    local source_config="$1"
    if [ -f "$source_config" ] && [ "$(stat -c%s "$source_config")" -gt 1000 ]; then
        mkdir -p "$PERSISTENT_CONFIG_DIR"
        cp -f "$source_config" "$SAVED_CONFIG_FILE"
        log_success "Preserved kernel configuration to ${SAVED_CONFIG_FILE}"
    fi
}

cleanup_cache() {
    log_step "Cleaning Build Cache"
    if [ ! -d "$BUILD_CACHE_DIR" ]; then
        log_info "Build cache directory ${BUILD_CACHE_DIR} is already clean."
        return 0
    fi

    # Check for active build lock
    local lock_file="${BUILD_CACHE_DIR}/.building"
    if [ -f "$lock_file" ]; then
        local lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null || true)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log_warn "A kernel build process (PID ${lock_pid}) is actively running. Skipping cleanup."
            return 0
        fi
    fi

    # Search for generated .config to preserve it
    local found_config
    found_config=$(find "$BUILD_CACHE_DIR" -type f -name ".config" -size +1000c | head -n 1 || true)
    if [ -n "$found_config" ]; then
        backup_saved_config "$found_config"
    fi

    log_info "Removing build artifacts in ${BUILD_CACHE_DIR}..."
    chmod -R u+rwX "$BUILD_CACHE_DIR" 2>/dev/null || true
    rm -rf "$BUILD_CACHE_DIR"
    log_success "Build cache cleaned successfully."
}

# ------------------------------------------------------------------------------
# Kernel Download & Extraction
# ------------------------------------------------------------------------------
download_and_extract_kernel() {
    local target_ver="$1"
    local target_tag="$2"
    local download_url="$3"

    mkdir -p "$BUILD_CACHE_DIR"

    # Set active building lockfile
    echo "$$" > "${BUILD_CACHE_DIR}/.building"

    local archive_name="${target_tag}.tar.gz"
    local archive_path="${BUILD_CACHE_DIR}/${archive_name}"
    local part_path="${BUILD_CACHE_DIR}/${archive_name}.part"

    log_step "Downloading CachyOS Kernel Source (${target_tag})"

    is_archive_valid() {
        [ -f "$1" ] && [ "$(stat -c%s "$1")" -gt 10000000 ] && tar -tzf "$1" >/dev/null 2>&1
    }

    if ! is_archive_valid "$archive_path"; then
        rm -f "$archive_path"
        log_info "Downloading from ${download_url}..."
        if command -v curl >/dev/null 2>&1; then
            curl -f -L -C - --progress-bar -o "$part_path" "$download_url"
        else
            wget -c --show-progress -O "$part_path" "$download_url"
        fi

        if ! is_archive_valid "$part_path"; then
            rm -f "$part_path"
            log_error "Downloaded archive is corrupted or incomplete. Please check your network connection."
            return 1
        fi
        mv -f "$part_path" "$archive_path"
        log_success "Download completed and verified."
    else
        log_success "Existing verified archive found: ${archive_name}"
    fi

    local extract_dir="${BUILD_CACHE_DIR}/${target_tag}"
    if [ ! -d "$extract_dir" ] || [ ! -f "${extract_dir}/Makefile" ]; then
        log_step "Extracting ${archive_name}..."
        rm -rf "$extract_dir"
        tar -xf "$archive_path" -C "$BUILD_CACHE_DIR"
        log_success "Archive extracted."
    else
        log_success "Existing extracted source tree verified: ${extract_dir}"
    fi

    # Download official CachyOS config if needed
    local cachy_config_cache="${BUILD_CACHE_DIR}/config"
    if [ ! -f "$cachy_config_cache" ] || [ "$(stat -c%s "$cachy_config_cache")" -lt 1000 ]; then
        log_info "Fetching official CachyOS kernel config..."
        curl -fsSL -o "$cachy_config_cache" "$CACHY_CONFIG_RAW" 2>/dev/null || true
    fi

    if [ ! -d "$extract_dir" ]; then
        local fallback
        fallback=$(find "$BUILD_CACHE_DIR" -maxdepth 1 -type d -name "*cachy*" | head -n 1)
        if [ -n "$fallback" ]; then
            extract_dir="$fallback"
        else
            log_error "Extracted kernel directory not found in ${BUILD_CACHE_DIR}"
            return 1
        fi
    fi

    echo "$extract_dir"
}

# ------------------------------------------------------------------------------
# Kernel Configuration Tweaks for Debian
# ------------------------------------------------------------------------------
prepare_kernel_config() {
    local kernel_dir="$1"
    local config_dst="${kernel_dir}/.config"

    log_step "Configuring Kernel for Debian"

    if [ -f "$SAVED_CONFIG_FILE" ] && [ "$(stat -c%s "$SAVED_CONFIG_FILE")" -gt 1000 ]; then
        log_info "Restoring saved kernel configuration from: ${SAVED_CONFIG_FILE}"
        cp -f "$SAVED_CONFIG_FILE" "$config_dst"
    else
        local running_kernel
        running_kernel=$(get_running_kernel)
        local boot_config="/boot/config-${running_kernel}"
        if [ -f "$boot_config" ] && [[ "$running_kernel" == *"cachy"* ]]; then
            log_info "Using configuration from running CachyOS kernel: ${boot_config}"
            cp -f "$boot_config" "$config_dst"
        elif [ -f "${BUILD_CACHE_DIR}/config" ]; then
            log_info "Applying official CachyOS default configuration."
            cp -f "${BUILD_CACHE_DIR}/config" "$config_dst"
        else
            log_info "Downloading official CachyOS configuration..."
            curl -fsSL -o "$config_dst" "$CACHY_CONFIG_RAW"
        fi
    fi

    # Crucial Debian Build Tweaks:
    # 1. Disable trusted and revocation keys (causes build errors on Debian without local canonical certs)
    "${kernel_dir}/scripts/config" --file "$config_dst" --disable SYSTEM_TRUSTED_KEYS || true
    "${kernel_dir}/scripts/config" --file "$config_dst" --disable SYSTEM_REVOCATION_KEYS || true

    # 2. Disable heavy debug symbols to prevent 40GB+ deb packages and out-of-disk crashes
    "${kernel_dir}/scripts/config" --file "$config_dst" --disable CONFIG_DEBUG_INFO || true
    "${kernel_dir}/scripts/config" --file "$config_dst" --disable CONFIG_DEBUG_INFO_DWARF5 || true
    "${kernel_dir}/scripts/config" --file "$config_dst" --disable CONFIG_DEBUG_INFO_DWARF4 || true
    "${kernel_dir}/scripts/config" --file "$config_dst" --disable CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT || true
    "${kernel_dir}/scripts/config" --file "$config_dst" --enable CONFIG_DEBUG_INFO_NONE || true

    # 3. Disable enterprise virtualization server-only features that fail on desktop toolchains
    "${kernel_dir}/scripts/config" --file "$config_dst" --disable CONFIG_INTEL_TDX_HOST || true
    "${kernel_dir}/scripts/config" --file "$config_dst" --disable CONFIG_KVM_INTEL_TDX || true

    # 4. Set clean Debian localversion
    "${kernel_dir}/scripts/config" --file "$config_dst" --set-str CONFIG_LOCALVERSION "-cachyos-debian" || true

    log_success "Configuration adjusted for Debian compilation."
}

# ------------------------------------------------------------------------------
# Kernel Compilation & Packaging
# ------------------------------------------------------------------------------
build_kernel() {
    local use_container="${1:-false}"
    local custom_threads="${2:-}"
    local custom_version="${3:-}"

    local release_info
    if [ -n "$custom_version" ]; then
        local tag="cachyos-${custom_version#cachyos-}"
        local ver="${tag#cachyos-}"
        local url="https://github.com/CachyOS/linux/releases/download/${tag}/${tag}.tar.gz"
        release_info="${ver}|${tag}|${url}"
    else
        release_info=$(fetch_latest_cachy_release)
    fi

    local target_ver target_tag download_url
    IFS='|' read -r target_ver target_tag download_url <<< "$release_info"

    log_info "Target Kernel Release: ${COLOR_BOLD}${COLOR_GREEN}${target_ver}${COLOR_RESET}"

    # Install dependencies
    install_dependencies "$use_container"

    # Download & Extract
    local kernel_dir
    kernel_dir=$(download_and_extract_kernel "$target_ver" "$target_tag" "$download_url")

    # Configure
    prepare_kernel_config "$kernel_dir"

    local threads
    threads="${custom_threads:-$(nproc)}"
    log_info "Using ${threads} CPU threads for compilation."

    local output_dir="${OUTPUT_BASE_DIR}/Linux-kernel-CachyOS-${target_ver}-debian"
    mkdir -p "$output_dir"

    # Run olddefconfig & compilation
    log_step "Compiling Kernel (make bindeb-pkg)"
    if [ "$use_container" = "true" ]; then
        local engine
        engine=$(get_container_engine)
        local rel_kernel
        rel_kernel=$(realpath --relative-to="$BUILD_CACHE_DIR" "$kernel_dir")

        local container_cmd=(
            "$engine" run --rm
        )
        if [ "$engine" = "podman" ]; then
            container_cmd+=(--userns=keep-id)
        else
            container_cmd+=(-u "$(id -u):$(id -g)")
        fi
        container_cmd+=(
            -v "${BUILD_CACHE_DIR}:/workspace:z"
            -w "/workspace/${rel_kernel}"
            -e KBUILD_BUILD_USER=cachyos
            -e KBUILD_BUILD_HOST=debian
            "$CONTAINER_IMAGE_TAG"
        )

        log_info "Running 'make olddefconfig' inside container..."
        "${container_cmd[@]}" make olddefconfig

        # Save config back
        backup_saved_config "${kernel_dir}/.config"

        log_info "Starting multi-threaded compilation inside container..."
        "${container_cmd[@]}" make -j"${threads}" bindeb-pkg
    else
        log_info "Running 'make olddefconfig' on host..."
        (cd "$kernel_dir" && make olddefconfig)

        # Save config back
        backup_saved_config "${kernel_dir}/.config"

        log_info "Starting multi-threaded compilation on host system..."
        (cd "$kernel_dir" && make -j"${threads}" bindeb-pkg)
    fi

    # Clean up lockfile
    rm -f "${BUILD_CACHE_DIR}/.building"

    # Collect .deb packages
    log_step "Collecting Debian Packages into: ${output_dir}"
    local copied_count=0
    for f in "${BUILD_CACHE_DIR}"/linux-*.deb "${BUILD_CACHE_DIR}"/*.changes "${BUILD_CACHE_DIR}"/*.buildinfo "${kernel_dir}"/linux-*.deb; do
        if [ -f "$f" ]; then
            cp -f "$f" "$output_dir/"
            log_info "  • $(basename "$f")"
            ((copied_count++)) || true
        fi
    done

    if [ -f "${kernel_dir}/.config" ]; then
        cp -f "${kernel_dir}/.config" "${output_dir}/kernel.config"
        log_info "  • kernel.config"
    fi

    # Generate standalone install.sh helper
    cat << EOF > "${output_dir}/install.sh"
#!/usr/bin/env bash
# Autogenerated CachyOS Kernel Installer for Linux-kernel-CachyOS-${target_ver}-debian
set -e
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
echo "=== Installing Linux-kernel-CachyOS-${target_ver}-debian ==="

DEBS=()
for f in "\$DIR"/linux-image-*.deb "\$DIR"/linux-headers-*.deb; do
    if [ -f "\$f" ] && [[ "\$f" != *"-dbg"* ]]; then
        DEBS+=("\$f")
    fi
done

if [ \${#DEBS[@]} -eq 0 ]; then
    echo "[-] Error: No linux-image or linux-headers .deb packages found in \$DIR"
    exit 1
fi

echo "Installing: \${DEBS[*]}"
if [ "\$EUID" -eq 0 ]; then
    dpkg -i "\${DEBS[@]}"
    update-grub
elif command -v sudo >/dev/null 2>&1; then
    sudo dpkg -i "\${DEBS[@]}"
    sudo update-grub
elif command -v pkexec >/dev/null 2>&1; then
    pkexec dpkg -i "\${DEBS[@]}"
    pkexec update-grub
fi

echo "=========================================================="
echo "Installation complete! Reboot your computer to run the new kernel."
echo "=========================================================="
EOF
    chmod +x "${output_dir}/install.sh"
    log_info "  • Generated standalone install.sh helper"

    log_success "Compilation and packaging complete! Saved to: ${output_dir}"
    echo "$output_dir"
}

# ------------------------------------------------------------------------------
# Kernel Installation
# ------------------------------------------------------------------------------
install_kernel_debs() {
    local target_dir="${1:-}"
    log_step "Installing CachyOS Kernel Packages"

    # Search for debian packages
    local search_dirs=()
    if [ -n "$target_dir" ] && [ -d "$target_dir" ]; then
        search_dirs+=("$target_dir")
    fi

    # Add output directories
    if [ -d "$OUTPUT_BASE_DIR" ]; then
        while IFS= read -r dir; do
            search_dirs+=("$dir")
        done < <(find "$OUTPUT_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)
    fi
    search_dirs+=("$BUILD_CACHE_DIR")

    local debs_to_install=()
    local chosen_dir=""
    for sdir in "${search_dirs[@]}"; do
        local candidates=()
        for f in "$sdir"/linux-image-*.deb "$sdir"/linux-headers-*.deb; do
            if [ -f "$f" ] && [[ "$f" != *"-dbg"* ]]; then
                candidates+=("$f")
            fi
        done
        if [ ${#candidates[@]} -gt 0 ]; then
            debs_to_install=("${candidates[@]}")
            chosen_dir="$sdir"
            break
        fi
    done

    if [ ${#debs_to_install[@]} -eq 0 ]; then
        log_error "No compiled linux-image or linux-headers .deb packages found. Please build the kernel first."
        return 1
    fi

    log_info "Found packages in: ${chosen_dir}"
    for deb in "${debs_to_install[@]}"; do
        echo "  • $(basename "$deb")"
    done

    log_info "Installing packages via dpkg and updating GRUB..."
    run_as_root dpkg -i "${debs_to_install[@]}"
    run_as_root update-grub

    log_success "Kernel packages installed and GRUB updated successfully!"

    # Check Secure Boot status and offer signing
    if command -v mokutil >/dev/null 2>&1; then
        local sb_status
        sb_status=$(mokutil --sb-state 2>/dev/null || true)
        if [[ "$sb_status" == *"SecureBoot enabled"* ]]; then
            log_warn "Secure Boot is ENABLED on this system."
            log_info "Your system requires newly compiled kernels to be signed with a Machine Owner Key (MOK)."
            sign_installed_kernel
        fi
    fi
}

# ------------------------------------------------------------------------------
# Secure Boot Kernel Signing (MOK)
# ------------------------------------------------------------------------------
sign_installed_kernel() {
    log_step "UEFI Secure Boot Kernel Signing"

    # Check / install prerequisites
    local missing_sb=()
    command -v sbsign >/dev/null 2>&1 || missing_sb+=("sbsigntool")
    command -v openssl >/dev/null 2>&1 || missing_sb+=("openssl")
    command -v mokutil >/dev/null 2>&1 || missing_sb+=("mokutil")

    if [ ${#missing_sb[@]} -gt 0 ]; then
        log_info "Installing Secure Boot signing tools: ${missing_sb[*]}..."
        run_as_root apt-get update
        # shellcheck disable=SC2086
        run_as_root apt-get install -y ${missing_sb[*]}
    fi

    # Locate or generate MOK
    local mok_dirs=(
        "${PERSISTENT_CONFIG_DIR}/mok"
        "/etc/secureboot/mok"
        "/var/lib/shim-signed/mok"
        "$HOME/.mok"
        "/root/.mok"
        "$SCRIPT_DIR"
    )

    local key_file=""
    local cert_file=""

    for d in "${mok_dirs[@]}"; do
        if [ -f "$d/MOK.priv" ] && [ -f "$d/MOK.pem" ]; then
            key_file="$d/MOK.priv"
            cert_file="$d/MOK.pem"
            break
        elif [ -f "$d/MOK.key" ] && [ -f "$d/MOK.crt" ]; then
            key_file="$d/MOK.key"
            cert_file="$d/MOK.crt"
            break
        fi
    done

    local new_key_generated=false
    if [ -z "$key_file" ] || [ -z "$cert_file" ]; then
        local mok_target_dir="${PERSISTENT_CONFIG_DIR}/mok"
        mkdir -p "$mok_target_dir"
        key_file="${mok_target_dir}/MOK.priv"
        cert_file="${mok_target_dir}/MOK.pem"
        local der_file="${mok_target_dir}/MOK.der"

        log_info "No existing Machine Owner Key (MOK) found. Generating new 2048-bit RSA key pair..."
        openssl req -new -x509 -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" \
            -nodes -days 3650 -subj "/CN=CachyOS Custom Kernel MOK/" 2>/dev/null
        openssl x509 -in "$cert_file" -outform DER -out "$der_file"
        chmod 600 "$key_file"
        new_key_generated=true
        log_success "Generated MOK key pair in: ${mok_target_dir}"
    fi

    # Find the newest installed CachyOS vmlinuz in /boot
    local kernel_image
    kernel_image=$(find /boot -maxdepth 1 -type f -name "vmlinuz*cachy*" | sort -V | tail -n 1)

    if [ -z "$kernel_image" ]; then
        kernel_image=$(find /boot -maxdepth 1 -type f -name "vmlinuz*" | sort -V | tail -n 1)
    fi

    if [ -z "$kernel_image" ]; then
        log_error "No vmlinuz kernel binary found in /boot."
        return 1
    fi

    log_info "Signing kernel image: ${COLOR_BOLD}${kernel_image}${COLOR_RESET}"
    run_as_root sbsign --key "$key_file" --cert "$cert_file" --output "$kernel_image" "$kernel_image"
    log_success "Kernel successfully signed with MOK: ${kernel_image}"

    if [ "$new_key_generated" = "true" ]; then
        local der_file="${PERSISTENT_CONFIG_DIR}/mok/MOK.der"
        log_step "First-Time Secure Boot MOK Enrollment Required"
        echo -e "${COLOR_YELLOW}Since a new MOK key pair was generated, you must enroll it into your UEFI firmware:${COLOR_RESET}"
        echo -e "  Run the following command:"
        echo -e "    ${COLOR_BOLD}sudo mokutil --import \"${der_file}\"${COLOR_RESET}"
        echo -e "  Enter a temporary enrollment password when prompted."
        echo -e "  Reboot your system, and in the blue ${COLOR_BOLD}MOKManager${COLOR_RESET} screen:"
        echo -e "    Select: ${COLOR_CYAN}Enroll MOK${COLOR_RESET} -> ${COLOR_CYAN}Continue${COLOR_RESET} -> Enter your password."
    fi
}

# ------------------------------------------------------------------------------
# Kernel Rollback & Management
# ------------------------------------------------------------------------------
rollback_kernels() {
    log_step "Installed Kernel Management & Rollback"

    local running
    running=$(get_running_kernel)
    echo -e "Currently running kernel : ${COLOR_BOLD}${running}${COLOR_RESET}\n"

    local installed=()
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && [[ "$pkg" != *"-dbg"* ]] && installed+=("$pkg")
    done < <(dpkg-query -W -f='${binary:Package}\n' 'linux-image-*' 2>/dev/null | grep -E '^linux-image-[0-9]' || true)

    if [ ${#installed[@]} -le 1 ]; then
        log_warn "Only ${#installed[@]} kernel package is installed (${installed[*]}). Rollback is not recommended."
        return 0
    fi

    echo "Installed Kernel Packages:"
    local i=1
    for pkg in "${installed[@]}"; do
        local tag=""
        if [[ "$pkg" == *"$running"* ]]; then
            tag=" ${COLOR_GREEN}(currently running - PROTECTED)${COLOR_RESET}"
        elif [[ "$pkg" != *"cachy"* ]]; then
            tag=" ${COLOR_CYAN}(stock Debian kernel - RECOMMENDED FALLBACK)${COLOR_RESET}"
        fi
        echo -e "  [$i] ${pkg}${tag}"
        ((i++))
    done

    echo ""
    read -rp "Enter the number of the kernel package to REMOVE (or 0 to cancel): " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#installed[@]} ]; then
        local target_pkg="${installed[$((choice - 1))]}"
        if [[ "$target_pkg" == *"$running"* ]]; then
            log_error "Cannot remove the currently active/running kernel. Boot into another kernel first."
            return 1
        fi

        read -rp "Are you SURE you want to remove ${target_pkg}? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Purging ${target_pkg} and updating GRUB..."
            run_as_root apt-get purge -y "$target_pkg"
            run_as_root update-grub
            log_success "${target_pkg} removed successfully."
        else
            log_info "Operation cancelled."
        fi
    else
        log_info "No changes made."
    fi
}

# ------------------------------------------------------------------------------
# Interactive Menu
# ------------------------------------------------------------------------------
interactive_menu() {
    while true; do
        clear
        print_banner
        echo -e "\n  Current Kernel: ${COLOR_CYAN}$(get_running_kernel)${COLOR_RESET}"
        echo -e "  Saved Config  : ${SAVED_CONFIG_FILE}\n"
        echo -e "  ${COLOR_BOLD}Actions:${COLOR_RESET}"
        echo "  [1] Check for latest CachyOS Kernel release"
        echo "  [2] Install build dependencies (Host tools & APT)"
        echo "  [3] Build CachyOS Kernel (Native Host Compiler)"
        echo "  [4] Build CachyOS Kernel (Isolated Container: Podman/Docker)"
        echo "  [5] Install compiled kernel packages (.deb) & Update GRUB"
        echo "  [6] Sign installed kernel for UEFI Secure Boot (MOK)"
        echo "  [7] Rollback / Remove installed kernel packages"
        echo "  [8] Clean build cache (Preserves saved .config)"
        echo "  [9] Full Upgrade (Check -> Build Host -> Install -> Sign)"
        echo "  [0] Exit"
        echo ""
        read -rp "Select an option [0-9]: " opt
        echo ""

        case "$opt" in
            1)
                check_update_status || true
                ;;
            2)
                install_dependencies false
                ;;
            3)
                build_kernel false
                ;;
            4)
                build_kernel true
                ;;
            5)
                install_kernel_debs
                ;;
            6)
                sign_installed_kernel
                ;;
            7)
                rollback_kernels
                ;;
            8)
                cleanup_cache
                ;;
            9)
                check_update_status || true
                build_kernel false
                install_kernel_debs
                ;;
            0)
                echo "Goodbye!"
                exit 0
                ;;
            *)
                log_error "Invalid option selected."
                ;;
        esac

        echo ""
        read -rp "Press [Enter] to return to the menu..." _
    done
}

# ------------------------------------------------------------------------------
# CLI Flag Parser
# ------------------------------------------------------------------------------
show_help() {
    print_banner
    cat << EOF

Usage: $(basename "$0") [OPTIONS]

Options:
  -c, --check             Check running kernel against latest CachyOS release
  -d, --deps              Install kernel build dependencies via APT
  -b, --build             Download, configure, and compile kernel (Host mode)
      --container         Compile kernel inside isolated Debian container (Podman/Docker)
  -i, --install           Install generated .deb packages and update GRUB
  -s, --sign              Sign installed kernel for UEFI Secure Boot (MOK)
  -r, --rollback          Interactive rollback and purge older kernel packages
      --clean             Clean build cache (~/.cache) while preserving saved config
  -a, --all               Full automated workflow: build, install, and sign
  -j, --threads <N>       Number of CPU threads to compile with (default: $(nproc))
  -v, --version <VER>     Specify CachyOS kernel version to build (e.g. 7.2.9-2)
  -h, --help              Show this help menu

Examples:
  ./$(basename "$0")                     # Launch interactive menu
  ./$(basename "$0") --check             # Check version without building
  ./$(basename "$0") --build             # Build on host system
  ./$(basename "$0") --build --container # Build inside isolated container
  ./$(basename "$0") --install           # Install previously compiled .deb
  ./$(basename "$0") --all               # Full end-to-end upgrade

EOF
}

main() {
    local opt_check=false
    local opt_deps=false
    local opt_build=false
    local opt_container=false
    local opt_install=false
    local opt_sign=false
    local opt_rollback=false
    local opt_clean=false
    local opt_all=false
    local custom_threads=""
    local custom_version=""

    if [ $# -eq 0 ]; then
        interactive_menu
        exit 0
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--check)
                opt_check=true
                shift
                ;;
            -d|--deps)
                opt_deps=true
                shift
                ;;
            -b|--build)
                opt_build=true
                shift
                ;;
            --container)
                opt_container=true
                shift
                ;;
            -i|--install)
                opt_install=true
                shift
                ;;
            -s|--sign)
                opt_sign=true
                shift
                ;;
            -r|--rollback)
                opt_rollback=true
                shift
                ;;
            --clean)
                opt_clean=true
                shift
                ;;
            -a|--all)
                opt_all=true
                shift
                ;;
            -j|--threads)
                custom_threads="$2"
                shift 2
                ;;
            -v|--version)
                custom_version="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [ "$opt_clean" = "true" ]; then
        cleanup_cache
    fi

    if [ "$opt_check" = "true" ]; then
        check_update_status || true
    fi

    if [ "$opt_deps" = "true" ]; then
        install_dependencies "$opt_container"
    fi

    if [ "$opt_all" = "true" ]; then
        check_update_status || true
        build_kernel "$opt_container" "$custom_threads" "$custom_version"
        install_kernel_debs
        exit 0
    fi

    if [ "$opt_build" = "true" ]; then
        build_kernel "$opt_container" "$custom_threads" "$custom_version"
    fi

    if [ "$opt_install" = "true" ]; then
        install_kernel_debs
    fi

    if [ "$opt_sign" = "true" ]; then
        sign_installed_kernel
    fi

    if [ "$opt_rollback" = "true" ]; then
        rollback_kernels
    fi
}

main "$@"
