#!/bin/bash
# ReSukiSU AVD Kernel Build Script
# Builds a GKI x86_64 kernel with ReSukiSU for Android Virtual Device (goldfish/emulator)
#
# Prerequisites:
#   1. repo sync (kernel source in common/)
#   2. bash setup.sh (integrate ReSukiSU)
#   3. Run this script from the repo root
#
# Usage: bash build.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="${ROOT_DIR}/common"
OUT_DIR="${ROOT_DIR}/out/android14-6.1/common"
DIST_DIR="${ROOT_DIR}/dist"
MODULES_DIR="${ROOT_DIR}/common-modules/virtual-device"

# Toolchain configuration (from build.config.constants + build.config.x86_64)
CLANG_VERSION="r487747c"
ARCH="x86_64"
CLANG_PREBUILT="${ROOT_DIR}/prebuilts/clang/host/linux-x86/clang-${CLANG_VERSION}/bin"
# GCC and build-tools are optional (used for host tooling, not strictly needed with LLVM=1)
GCC_PREBUILT="${ROOT_DIR}/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/bin"
BUILDTOOLS_BIN="${ROOT_DIR}/build/kernel/build-tools/path/linux-x86"

# Check prerequisites
if [ ! -d "${KERNEL_DIR}" ]; then
    echo "ERROR: Kernel source not found at ${KERNEL_DIR}"
    echo "Run 'repo sync' first."
    exit 1
fi

if [ ! -d "${KERNEL_DIR}/drivers/resukisu" ]; then
    echo "ERROR: ReSukiSU not integrated. Run 'bash setup.sh' first."
    exit 1
fi

if [ ! -d "${CLANG_PREBUILT}" ]; then
    echo "ERROR: Clang prebuilts not found at ${CLANG_PREBUILT}"
    echo "Run 'repo sync' to download prebuilts. (repo sync prebuilts/clang/host/linux-x86)"
    exit 1
fi

echo "=== ReSukiSU AVD Kernel Build ==="
echo "Kernel: $(cd ${KERNEL_DIR} && git log --oneline -1)"
echo "Arch: ${ARCH}"
echo "Clang: ${CLANG_VERSION}"
echo ""

# Set up QEMU for x86_64 cross-build on ARM64
ARCH_HOST=$(uname -m)
if [ "${ARCH_HOST}" = "aarch64" ] || [ "${ARCH_HOST}" = "arm64" ]; then
    export QEMU_LD_PREFIX=/opt/aosp-x86_64-sysroot
    export QEMU_X86_64=/usr/local/bin/qemu-x86_64
    if [ ! -f "${QEMU_X86_64}" ]; then
        echo "WARNING: QEMU x86_64 not found at ${QEMU_X86_64}"
        echo "x86_64 clang binaries may not work on this ARM64 host."
    fi
fi

# Set up PATH (only include directories that exist)
NEW_PATH="${CLANG_PREBUILT}:${PATH}"
[ -d "${GCC_PREBUILT}" ] && NEW_PATH="${GCC_PREBUILT}:${NEW_PATH}"
[ -d "${BUILDTOOLS_BIN}" ] && NEW_PATH="${BUILDTOOLS_BIN}:${NEW_PATH}"
export PATH="${NEW_PATH}"
export LLVM=1

# Create output directories
mkdir -p "${OUT_DIR}"
mkdir -p "${DIST_DIR}"

# --- Step 1: Merge kernel configs ---
echo "[1/4] Merging kernel configs..."
DEFCONFIG="vd_x86_64_ksu_defconfig"
MERGED_CONFIG="${OUT_DIR}/arch/x86/configs/${DEFCONFIG}"

mkdir -p "$(dirname "${MERGED_CONFIG}")"

CONFIG_FRAGMENTS=(
    "${KERNEL_DIR}/arch/x86/configs/gki_defconfig"
    "${MODULES_DIR}/virtual_device_core.fragment"
    "${MODULES_DIR}/virtual_device.fragment"
    "${ROOT_DIR}/ksu.fragment"
)

KCONFIG_CONFIG="${MERGED_CONFIG}" \
    "${KERNEL_DIR}/scripts/kconfig/merge_config.sh" -m -r \
    "${CONFIG_FRAGMENTS[@]}"

echo "      Merged config written to ${MERGED_CONFIG}"
echo ""

# --- Step 2: Build GKI kernel ---
echo "[2/4] Building GKI kernel (bzImage + modules)..."
make -C "${KERNEL_DIR}" \
    O="${OUT_DIR}" \
    ARCH="${ARCH}" \
    KCFLAGS="-D__ANDROID_COMMON_KERNEL__" \
    ${DEFCONFIG}

make -C "${KERNEL_DIR}" \
    O="${OUT_DIR}" \
    ARCH="${ARCH}" \
    KCFLAGS="-D__ANDROID_COMMON_KERNEL__" \
    -j$(nproc) bzImage modules

echo "      Kernel build complete."
echo ""

# --- Step 3: Build virtual-device external modules ---
echo "[3/4] Building virtual-device external modules..."
EXT_MODULES_OUT="${ROOT_DIR}/out/android14-6.1/virtual-device"

if [ -f "${MODULES_DIR}/Kbuild" ] || [ -f "${MODULES_DIR}/Makefile" ]; then
    make -C "${KERNEL_DIR}" \
        O="${OUT_DIR}" \
        ARCH="${ARCH}" \
        M="${MODULES_DIR}" \
        INSTALL_MOD_PATH="${EXT_MODULES_OUT}" \
        KCFLAGS="-D__ANDROID_COMMON_KERNEL__" \
        -j$(nproc) modules

    # Install modules
    make -C "${KERNEL_DIR}" \
        O="${OUT_DIR}" \
        ARCH="${ARCH}" \
        M="${MODULES_DIR}" \
        INSTALL_MOD_PATH="${EXT_MODULES_OUT}" \
        INSTALL_MOD_STRIP=1 \
        modules_install 2>/dev/null || true
    echo "      External modules built."
else
    echo "      No external modules to build (no Kbuild/Makefile in ${MODULES_DIR})."
fi
echo ""

# --- Step 4: Collect artifacts ---
echo "[4/4] Collecting build artifacts..."

KERNEL_IMAGE="${OUT_DIR}/arch/x86/boot/bzImage"
VMLINUX="${OUT_DIR}/vmlinux"
SYSTEM_MAP="${OUT_DIR}/System.map"

# Collect in dist/
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

if [ -f "${KERNEL_IMAGE}" ]; then
    cp "${KERNEL_IMAGE}" "${DIST_DIR}/"
    echo "      [OK] bzImage"
else
    echo "      [FAIL] bzImage not found!"
fi

if [ -f "${VMLINUX}" ]; then
    cp "${VMLINUX}" "${DIST_DIR}/"
    echo "      [OK] vmlinux"
else
    echo "      [WARN] vmlinux not found"
fi

if [ -f "${SYSTEM_MAP}" ]; then
    cp "${SYSTEM_MAP}" "${DIST_DIR}/"
    echo "      [OK] System.map"
fi

# Collect all .ko modules
echo "      Collecting kernel modules..."
find "${OUT_DIR}" -name "*.ko" -exec cp {} "${DIST_DIR}/" \; 2>/dev/null || true
find "${EXT_MODULES_OUT}" -name "*.ko" -exec cp {} "${DIST_DIR}/" \; 2>/dev/null || true

KO_COUNT=$(find "${DIST_DIR}" -name "*.ko" | wc -l)
echo "      Found ${KO_COUNT} kernel modules"

# Write build info
cat > "${DIST_DIR}/build-info.txt" << EOF
ReSukiSU AVD Kernel Build
=========================
Build date: $(date -u)
Target AVD: 6.1.23-android14-4 (build ab9964412)
Kernel commit: $(cd ${KERNEL_DIR} && git rev-parse HEAD)
Kernel branch: android14-6.1
Clang: ${CLANG_VERSION}
Arch: ${ARCH}
ReSukiSU commit: $(cd ${ROOT_DIR}/resukisu-kernel && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
EOF

echo ""
echo "=== Build Complete ==="
if [ -f "${KERNEL_IMAGE}" ]; then
    echo "Artifacts in: ${DIST_DIR}/"
    ls -lh "${DIST_DIR}/"
    echo ""
    echo "Deploy bzImage to AVD and load modules to enable root."
else
    echo "WARNING: bzImage was not built. Check the build output above for errors."
    exit 1
fi
