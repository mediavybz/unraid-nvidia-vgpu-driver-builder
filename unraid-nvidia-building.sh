#!/bin/bash
# SPDX-License-Identifier: GPL-3.0
#
# Optimized NVIDIA vGPU Driver Builder for Unraid
# Credits: midi1996, samicrusader#4026, ich777
#
# This script builds custom NVIDIA vGPU drivers for Unraid systems

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Global variables
declare -g DATA_DIR DATA_TMP NV_TMP_D LOG_F
declare -g CPU_COUNT UNAME LNX_MAJ_NUMBER LNX_FULL_VER
declare -g NV_RUN UNRAID_DIR NV_DRV_V
declare -g SKIP_KERNEL CLEANUP_END
declare -g LIBNVIDIA_CONTAINER_V="1.14.3"
declare -g CONTAINER_TOOLKIT_V="1.14.3"

# Initialize variables
init_vars() {
    DATA_DIR="$(pwd)"
    DATA_TMP="${DATA_DIR}/tmp"
    NV_TMP_D="${DATA_TMP}/NVIDIA"
    LOG_F="${DATA_DIR}/logfile_$(date +'%Y.%m.%d')_${RANDOM}.log"
    CPU_COUNT="$(nproc)"
    SKIP_KERNEL=""
    CLEANUP_END=""
    NV_RUN=""
    UNRAID_DIR=""
    NV_DRV_V=""
}

# Logging functions
log_info() {
    echo " [i] $*" | tee -a "${LOG_F:-/dev/null}"
}

log_success() {
    echo " [✓] $*" | tee -a "${LOG_F:-/dev/null}"
}

log_warning() {
    echo " [!] $*" | tee -a "${LOG_F:-/dev/null}"
}

log_error() {
    echo " [✗] ERROR: $*" | tee -a "${LOG_F:-/dev/null}" >&2
}

log_progress() {
    echo " [>] $*" | tee -a "${LOG_F:-/dev/null}"
}

# Enhanced error handling
handle_error() {
    local exit_code=$?
    local line_number=$1
    log_error "Script failed at line ${line_number} with exit code ${exit_code}"
    cleanup
    exit "${exit_code}"
}

# Set up error trap
trap 'handle_error ${LINENO}' ERR

# Check if running as root
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        cat >&2 <<EOF

 [✗] Not running as root.
 [i] Please run the script again as root:
 [i] sudo bash $(basename "$0") [flags]
 [i] Exiting...

EOF
        exit 1
    fi
}

# Cleanup function
cleanup() {
    echo
    log_progress "Cleaning up temporary files..."
    
    if [[ -d "${DATA_TMP}" ]]; then
        read -p " [?] Remove temporary directory ${DATA_TMP}? (y/N): " -n 1 -r
        echo
        if [[ "${REPLY,,}" == "y" ]]; then
            log_progress "Removing ${DATA_TMP}..."
            rm -rf "${DATA_TMP}" && log_success "Cleanup completed." || log_error "Failed to remove ${DATA_TMP}"
        else
            log_info "Temporary files preserved at: ${DATA_TMP}"
        fi
    fi
}

# Validate dependencies and system requirements
validate_system() {
    log_progress "Validating system requirements..."
    
    # Check required commands
    local required_commands=("wget" "tar" "make" "gcc" "patch" "nproc")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "${cmd}" &> /dev/null; then
            log_error "Required command '${cmd}' not found"
            exit 1
        fi
    done
    
    # Check disk space (7GB minimum)
    local free_space
    free_space=$(df -k --output=avail "${PWD}" | tail -n1)
    if [[ "${free_space}" -lt $((7*1024*1024)) ]]; then
        log_error "Insufficient disk space. Need at least 7GB free."
        exit 1
    fi
    log_success "Sufficient disk space available ($(df -h --output=avail "${PWD}" | tail -n1 | tr -d ' '))"
    
    # Check internet connectivity
    if ! wget -q --spider --timeout=10 https://kernel.org; then
        log_error "No internet connection available"
        exit 1
    fi
    log_success "Internet connectivity verified"
}

# Validate input files
validate_inputs() {
    log_progress "Validating input files..."
    
    # Check NVIDIA driver file
    if [[ ! -f "${DATA_DIR}/${NV_RUN}" ]]; then
        log_error "NVIDIA driver file not found: ${DATA_DIR}/${NV_RUN}"
        exit 1
    fi
    log_success "NVIDIA driver file found: ${NV_RUN}"
    
    # Check Unraid source directory
    if [[ ! -d "${DATA_DIR}/${UNRAID_DIR}" ]]; then
        log_error "Unraid source directory not found: ${DATA_DIR}/${UNRAID_DIR}"
        exit 1
    fi
    log_success "Unraid source directory found: ${UNRAID_DIR}"
    
    # Extract and validate NVIDIA driver version
    log_info "Extracting NVIDIA driver version..."
    if ! NV_DRV_V=$(bash "${DATA_DIR}/${NV_RUN}" --version 2>/dev/null | grep -i version | awk '{print $4}'); then
        log_error "Failed to extract NVIDIA driver version"
        exit 1
    fi
    
    if [[ -z "${NV_DRV_V}" ]]; then
        log_error "Could not determine NVIDIA driver version"
        exit 1
    fi
    log_success "NVIDIA driver version: ${NV_DRV_V}"
}

# Prepare directory structure and log file
prepare_environment() {
    log_progress "Preparing build environment..."
    
    # Create log file
    if ! touch "${LOG_F}"; then
        log_error "Failed to create log file: ${LOG_F}"
        exit 1
    fi
    log_success "Log file created: ${LOG_F}"
    
    # Handle existing temporary directory
    if [[ -z "${SKIP_KERNEL}" ]] && [[ -d "${DATA_TMP}" ]]; then
        log_warning "Existing temporary directory found: ${DATA_TMP}"
        read -p " [?] Remove existing temporary directory? (Y/n): " -n 1 -r
        echo
        if [[ "${REPLY,,}" != "n" ]]; then
            log_progress "Removing existing temporary directory..."
            rm -rf "${DATA_TMP}" || {
                log_error "Failed to remove existing temporary directory"
                exit 1
            }
            log_success "Existing temporary directory removed"
        else
            log_warning "Using existing temporary directory (may cause issues)"
        fi
    fi
    
    # Create directory structure
    log_progress "Creating directory structure..."
    mkdir -p "${DATA_TMP}" \
             "${NV_TMP_D}/usr/lib64/xorg/modules/"{drivers,extensions} \
             "${NV_TMP_D}/usr/bin" \
             "${NV_TMP_D}/etc" \
             "${NV_TMP_D}/lib/modules/${UNAME%/}/kernel/drivers/video" \
             "${NV_TMP_D}/lib/firmware" || {
        log_error "Failed to create directory structure"
        exit 1
    }
    log_success "Directory structure created"
}

# Download and build kernel
build_kernel() {
    log_progress "Building kernel..."
    
    local kernel_archive="linux-${LNX_FULL_VER}.tar.xz"
    local kernel_url="https://mirrors.edge.kernel.org/pub/linux/kernel/v${LNX_MAJ_NUMBER}.x/${kernel_archive}"
    
    cd "${DATA_TMP}"
    
    # Download kernel source
    log_progress "Downloading Linux ${LNX_FULL_VER} source..."
    if ! wget -q -nc -4c --show-progress --progress=bar:force:noscroll "${kernel_url}"; then
        log_error "Failed to download kernel source"
        exit 1
    fi
    log_success "Kernel source downloaded"
    
    # Extract kernel source
    log_progress "Extracting kernel source..."
    if ! tar xf "./${kernel_archive}"; then
        log_error "Failed to extract kernel source"
        exit 1
    fi
    log_success "Kernel source extracted"
    
    cd "./linux-${LNX_FULL_VER}" || {
        log_error "Failed to enter kernel source directory"
        exit 1
    }
    
    # Apply Unraid patches
    log_progress "Applying Unraid patches..."
    cp -r "${DATA_DIR}/${UNRAID_DIR}" "${DATA_TMP}/${UNAME%/}"
    
    local patch_count=0
    while IFS= read -r -d '' patch_file; do
        if patch -p1 -i "${patch_file}" >> "${LOG_F}" 2>&1; then
            ((patch_count++))
            rm "${patch_file}"
        else
            log_error "Failed to apply patch: ${patch_file}"
            exit 1
        fi
    done < <(find "${DATA_TMP}/${UNAME%/}/" -type f -name '*.patch' -print0)
    
    log_success "Applied ${patch_count} Unraid patches"
    
    # Copy Unraid configuration
    log_progress "Copying Unraid configuration..."
    if [[ ! -f "${DATA_TMP}/${UNAME%/}/.config" ]]; then
        log_error "Unraid .config file not found"
        exit 1
    fi
    cp "${DATA_TMP}/${UNAME%/}/.config" . || {
        log_error "Failed to copy .config file"
        exit 1
    }
    
    if [[ -d "${DATA_TMP}/${UNAME%/}/drivers/md" ]]; then
        cp -r "${DATA_TMP}/${UNAME%/}/drivers/md/"* drivers/md/ || {
            log_error "Failed to copy md drivers"
            exit 1
        }
    fi
    log_success "Unraid configuration copied"
    
    # Build kernel
    log_progress "Building kernel (this may take a while)..."
    if ! make -j"${CPU_COUNT}" >> "${LOG_F}" 2>&1; then
        log_error "Kernel build failed. Check ${LOG_F} for details."
        exit 1
    fi
    log_success "Kernel built successfully"
    
    log_progress "Building kernel modules..."
    if ! make -j"${CPU_COUNT}" modules >> "${LOG_F}" 2>&1; then
        log_error "Kernel modules build failed. Check ${LOG_F} for details."
        exit 1
    fi
    log_success "Kernel modules built successfully"
}

# Link kernel source
link_kernel_source() {
    log_progress "Linking kernel source..."
    
    cd "${DATA_TMP}"
    mkdir -p "/lib/modules/${UNAME%/}" || {
        log_error "Failed to create /lib/modules/${UNAME%/}"
        exit 1
    }
    
    ln -sf "${DATA_TMP}/linux-${LNX_FULL_VER}" "/lib/modules/${UNAME%/}/build" || {
        log_error "Failed to link kernel source"
        exit 1
    }
    log_success "Kernel source linked"
}

# Install NVIDIA drivers
install_nvidia_drivers() {
    log_progress "Installing NVIDIA drivers..."
    
    cd "${DATA_DIR}"
    chmod +x "${DATA_DIR}/${NV_RUN}" || {
        log_error "Failed to make NVIDIA installer executable"
        exit 1
    }
    
    # Clean up old installation
    local installer_dir
    installer_dir=$(basename "${NV_RUN}" .run)
    if [[ -d "${installer_dir}" ]]; then
        log_progress "Removing old installer directory..."
        rm -rf "${installer_dir}" || {
            log_error "Failed to remove old installer directory"
            exit 1
        }
    fi
    
    # Clean up old logs
    if [[ -f /var/log/nvidia-installer.log ]]; then
        log_progress "Cleaning up old NVIDIA installer logs..."
        rm -f /var/log/nvidia-installer.log || log_warning "Failed to remove old logs"
        
        cat <<EOF
 [!] WARNING: Installing NVIDIA drivers on a host system with existing
 [!] NVIDIA drivers can cause conflicts and system instability.
 [!] This script should be run in a VM environment.
 [!] 
 [!] The script will attempt to uninstall existing drivers first.
EOF
        read -p " [?] Press Enter to continue or Ctrl+C to abort..."
        
        log_progress "Attempting to uninstall existing NVIDIA drivers..."
        bash "${DATA_DIR}/${NV_RUN}" --uninstall --silent >> "${LOG_F}" 2>&1 || true
        log_info "Uninstall attempt completed (errors are expected if no drivers were installed)"
    fi
    
    # Install NVIDIA drivers
    log_progress "Installing NVIDIA drivers to ${NV_TMP_D}"
    log_info "Monitor progress with: tail -f /var/log/nvidia-installer.log"
    
    bash "${DATA_DIR}/${NV_RUN}" \
        --kernel-name="${UNAME%/}" \
        --no-precompiled-interface \
        --disable-nouveau \
        --x-prefix="${NV_TMP_D}/usr" \
        --x-library-path="${NV_TMP_D}/usr/lib64" \
        --x-module-path="${NV_TMP_D}/usr/lib64/xorg/modules" \
        --opengl-prefix="${NV_TMP_D}/usr" \
        --installer-prefix="${NV_TMP_D}/usr" \
        --utility-prefix="${NV_TMP_D}/usr" \
        --documentation-prefix="${NV_TMP_D}/usr" \
        --application-profile-path="${NV_TMP_D}/usr/share/nvidia" \
        --proc-mount-point="${NV_TMP_D}/proc" \
        --kernel-install-path="${NV_TMP_D}/lib/modules/${UNAME%/}/kernel/drivers/video" \
        --compat32-prefix="${NV_TMP_D}/usr" \
        --compat32-libdir=/lib \
        --install-compat32-libs \
        --no-x-check \
        --no-dkms \
        --no-nouveau-check \
        --skip-depmod \
        --j"${CPU_COUNT}" \
        --silent >> "${LOG_F}" 2>&1 || {
        log_error "NVIDIA driver installation failed"
        exit 1
    }
    
    # Verify installation
    if [[ -f /var/log/nvidia-installer.log ]] && grep -q "installation is now complete" /var/log/nvidia-installer.log; then
        log_success "NVIDIA drivers installed successfully"
    else
        log_warning "NVIDIA driver installation may have failed"
        log_info "Check /var/log/nvidia-installer.log for details"
        read -p " [?] Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ "${REPLY,,}" != "y" ]]; then
            exit 1
        fi
    fi
}

# Copy additional files
copy_additional_files() {
    log_progress "Copying additional files..."
    
    # Copy firmware
    if [[ -d /lib/firmware/nvidia ]]; then
        cp -R /lib/firmware/nvidia "${NV_TMP_D}/lib/firmware/" || log_warning "Failed to copy NVIDIA firmware"
    fi
    
    # Copy essential binaries and configurations
    local files_to_copy=(
        "/usr/bin/nvidia-modprobe:${NV_TMP_D}/usr/bin/"
        "/etc/OpenCL:${NV_TMP_D}/etc/"
        "/etc/vulkan:${NV_TMP_D}/etc/"
        "/etc/nvidia:${NV_TMP_D}/etc/"
        "/usr/lib/nvidia:${NV_TMP_D}/usr/lib/"
        "/usr/share/nvidia:${NV_TMP_D}/usr/share/"
    )
    
    for file_mapping in "${files_to_copy[@]}"; do
        local src="${file_mapping%:*}"
        local dst="${file_mapping#*:}"
        
        if [[ -e "${src}" ]]; then
            cp -R "${src}" "${dst}" >> "${LOG_F}" 2>&1 || log_warning "Failed to copy ${src}"
        else
            log_warning "Source file/directory not found: ${src}"
        fi
    done
    
    log_success "Additional files copied"
}

# Download and install container support
install_container_support() {
    log_progress "Installing container support..."
    
    cd "${DATA_TMP}"
    
    # Download libnvidia-container
    local libnvidia_file="libnvidia-container-v${LIBNVIDIA_CONTAINER_V}.tar.gz"
    local libnvidia_url="https://github.com/ich777/libnvidia-container/releases/download/${LIBNVIDIA_CONTAINER_V}/${libnvidia_file}"
    
    if [[ ! -f "${DATA_TMP}/${libnvidia_file}" ]]; then
        log_progress "Downloading libnvidia-container..."
        wget -q -nc --show-progress --progress=bar:force:noscroll -O "${DATA_TMP}/${libnvidia_file}" "${libnvidia_url}" || {
            log_error "Failed to download libnvidia-container"
            exit 1
        }
    fi
    
    tar -C "${NV_TMP_D}/" -xf "${DATA_TMP}/${libnvidia_file}" || {
        log_error "Failed to extract libnvidia-container"
        exit 1
    }
    
    # Download nvidia-container-toolkit
    local toolkit_file="nvidia-container-toolkit-v${CONTAINER_TOOLKIT_V}.tar.gz"
    local toolkit_url="https://github.com/ich777/nvidia-container-toolkit/releases/download/${CONTAINER_TOOLKIT_V}/${toolkit_file}"
    
    if [[ ! -f "${DATA_TMP}/${toolkit_file}" ]]; then
        log_progress "Downloading nvidia-container-toolkit..."
        wget -q -nc --show-progress --progress=bar:force:noscroll -O "${DATA_TMP}/${toolkit_file}" "${toolkit_url}" || {
            log_error "Failed to download nvidia-container-toolkit"
            exit 1
        }
    fi
    
    tar -C "${NV_TMP_D}/" -xf "${DATA_TMP}/${toolkit_file}" || {
        log_error "Failed to extract nvidia-container-toolkit"
        exit 1
    }
    
    log_success "Container support installed"
}

# Create Slackware package
create_package() {
    log_progress "Creating Slackware package..."
    
    local plugin_name="nvidia-driver"
    local base_dir="${NV_TMP_D}/"
    local tmp_dir="${DATA_TMP}/${plugin_name}_${RANDOM}"
    local version
    version="$(date +'%Y.%m.%d')"
    
    mkdir -p "${tmp_dir}/${version}"
    cd "${tmp_dir}/${version}"
    cp -R "${base_dir}"* "${tmp_dir}/${version}/"
    mkdir "${tmp_dir}/${version}/install"
    
    # Create package description
    cat > "${tmp_dir}/${version}/install/slack-desc" <<EOF
           |-----handy-ruler------------------------------------------------------|
${plugin_name}: ${plugin_name} Package contents:
${plugin_name}:
${plugin_name}: NVIDIA Driver v${NV_DRV_V}
${plugin_name}: libnvidia-container v${LIBNVIDIA_CONTAINER_V}
${plugin_name}: nvidia-container-toolkit v${CONTAINER_TOOLKIT_V}
${plugin_name}:
${plugin_name}:
${plugin_name}: Custom ${plugin_name} for Unraid Kernel v${UNAME%%-*}
${plugin_name}: Built on $(date +'%Y-%m-%d %H:%M:%S')
${plugin_name}:
EOF
    
    # Find or install makepkg
    local makepkg_cmd
    if command -v makepkg &> /dev/null; then
        makepkg_cmd="makepkg"
        log_success "Using system makepkg"
    else
        log_progress "Installing temporary makepkg..."
        local pkgtools_file="pkgtools-15.0-noarch-42.txz"
        local pkgtools_url="https://slackware.uk/slackware/slackware64-15.0/slackware64/a/${pkgtools_file}"
        
        if [[ ! -f "${DATA_TMP}/${pkgtools_file}" ]]; then
            wget -q -nc --show-progress --progress=bar:force:noscroll "${pkgtools_url}" -P "${DATA_TMP}" || {
                log_error "Failed to download pkgtools"
                exit 1
            }
        fi
        
        tar -C "${DATA_TMP}" -xf "${DATA_TMP}/${pkgtools_file}" >> "${LOG_F}" 2>&1
        makepkg_cmd="${DATA_TMP}/sbin/makepkg"
        
        if [[ ! -x "${makepkg_cmd}" ]]; then
            log_error "Failed to install makepkg"
            exit 1
        fi
        log_success "Temporary makepkg installed"
    fi
    
    # Create package
    local package_name="${plugin_name%%-*}-${NV_DRV_V}-${UNAME%/}-1.txz"
    log_progress "Building package: ${package_name}"
    
    "${makepkg_cmd}" -l n -c n "${tmp_dir}/${package_name}" >> "${LOG_F}" 2>&1 || {
        log_error "Package creation failed"
        exit 1
    }
    
    # Create MD5 checksum
    cd "${tmp_dir}"
    md5sum "${package_name}" | awk '{print $1}' > "${package_name}.md5"
    
    # Create output directory and copy package
    mkdir -p "${DATA_DIR}/out"
    cp "${package_name}"* "${DATA_DIR}/out/"
    
    # Display package information
    echo
    log_success "Package created successfully!"
    log_info "Package: ${DATA_DIR}/out/${package_name}"
    log_info "MD5: $(cat "${DATA_DIR}/out/${package_name}.md5")"
    log_info "Size: $(du -h "${DATA_DIR}/out/${package_name}" | cut -f1)"
    echo
}

# Main execution function
main() {
    local start_time end_time duration
    start_time=$(date +%s)
    
    log_progress "Starting NVIDIA vGPU driver build for Unraid"
    log_info "Build started at: $(date)"
    
    validate_system
    validate_inputs
    prepare_environment
    
    if [[ -z "${SKIP_KERNEL}" ]]; then
        build_kernel
    else
        log_info "Skipping kernel build as requested"
    fi
    
    link_kernel_source
    install_nvidia_drivers
    copy_additional_files
    install_container_support
    create_package
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    echo
    log_success "Build completed successfully!"
    log_info "Total build time: $((duration / 60))m $((duration % 60))s"
    log_info "Build completed at: $(date)"
    
    if [[ "${CLEANUP_END}" == "1" ]]; then
        cleanup
    fi
}

# Display usage information
show_usage() {
    cat <<EOF

NVIDIA vGPU Driver Builder for Unraid
=====================================

Usage: sudo bash $(basename "$0") [OPTIONS]

Required Options:
  -n FILE    NVIDIA vGPU driver installer (.run file)
  -u DIR     Unraid kernel source directory (linux-X.XX.XX-Unraid)

Optional Flags:
  -s         Skip kernel building (use only if kernel is already built)
  -c         Clean up temporary files after completion
  -h         Show this help message

Examples:
  sudo bash $(basename "$0") -n NVIDIA-Linux-x86_64-525.85-grid.run -u linux-6.1.15-Unraid
  sudo bash $(basename "$0") -n driver.run -u linux-6.1.15-Unraid -s -c

Requirements:
  - Root privileges
  - 7GB+ free disk space
  - Internet connection
  - Build tools (gcc, make, patch, etc.)

EOF
}

# Parse command line arguments
parse_arguments() {
    while getopts 'n:u:shc' opt; do
        case "${opt}" in
            n)
                NV_RUN="${OPTARG}"
                log_info "NVIDIA driver: ${NV_RUN}"
                ;;
            u)
                UNRAID_DIR="${OPTARG}"
                log_info "Unraid source: ${UNRAID_DIR}"
                ;;
            s)
                SKIP_KERNEL="1"
                log_info "Kernel build will be skipped"
                ;;
            h)
                show_usage
                exit 0
                ;;
            c)
                CLEANUP_END="1"
                log_info "Will clean up after completion"
                ;;
            *)
                log_error "Invalid option: -${OPTARG}"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Validate required arguments
    if [[ -z "${NV_RUN}" ]] || [[ -z "${UNRAID_DIR}" ]]; then
        log_error "Both -n (NVIDIA driver) and -u (Unraid source) are required"
        show_usage
        exit 1
    fi
    
    # Extract kernel version information
    UNAME=$(echo "${UNRAID_DIR}" | sed 's/linux-//')
    LNX_MAJ_NUMBER=$(echo "${UNAME%/}" | cut -d "." -f1)
    LNX_FULL_VER=$(echo "${UNAME%/}" | cut -d "-" -f1)
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Initialize
    init_vars
    check_root
    
    # Parse arguments
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi
    
    parse_arguments "$@"
    
    # Display welcome message
    cat <<EOF

╔═══════════════════════════════════════════════════════════════════════════════╗
║                    NVIDIA vGPU Driver Builder for Unraid                     ║
║                                                                               ║
║  This script builds custom NVIDIA vGPU drivers for Unraid systems.          ║
║  Tested with NVIDIA driver versions: 525.85, 525.105, and newer             ║
║                                                                               ║
║  ⚠️  WARNING: Run this script in a VM to avoid system conflicts!             ║
╚═══════════════════════════════════════════════════════════════════════════════╝

EOF
    
    log_info "Configuration:"
    log_info "  NVIDIA Driver: ${NV_RUN}"
    log_info "  Unraid Source: ${UNRAID_DIR}"
    log_info "  Kernel Version: ${UNAME%/}"
    log_info "  Skip Kernel Build: ${SKIP_KERNEL:-No}"
    log_info "  Cleanup After: ${CLEANUP_END:-No}"
    echo
    
    read -p "Press Enter to continue or Ctrl+C to abort..." -r
    
    # Run main function
    main
    
    echo
    log_success "Script completed successfully!"
fi
