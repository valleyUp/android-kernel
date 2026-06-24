#!/bin/bash
# ReSukiSU Kernel Integration Setup
# Run this script AFTER 'repo sync' to integrate ReSukiSU into the kernel source.
#
# Usage: bash setup.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="${ROOT_DIR}/common"
RESUKISU_SRC="${ROOT_DIR}/resukisu-kernel"
PATCHES_DIR="${ROOT_DIR}/patches"

echo "=== ReSukiSU Kernel Integration Setup ==="
echo "Root dir: ${ROOT_DIR}"
echo "Kernel dir: ${KERNEL_DIR}"
echo ""

# Check prerequisites
if [ ! -d "${KERNEL_DIR}" ]; then
    echo "ERROR: Kernel source not found at ${KERNEL_DIR}"
    echo "Run 'repo sync' first to download the kernel source."
    exit 1
fi

if [ ! -d "${RESUKISU_SRC}/kernel" ]; then
    echo "ERROR: ReSukiSU kernel source not found at ${RESUKISU_SRC}"
    echo "Clone it first: git submodule update --init"
    exit 1
fi

# Step 1: Copy ReSukiSU kernel source into the kernel drivers directory
echo "[1/3] Copying ReSukiSU kernel source into drivers/resukisu/..."
if [ -d "${KERNEL_DIR}/drivers/resukisu" ]; then
    echo "      Removing existing drivers/resukisu/..."
    rm -rf "${KERNEL_DIR}/drivers/resukisu"
fi
cp -r "${RESUKISU_SRC}/kernel" "${KERNEL_DIR}/drivers/resukisu"
echo "      Done."

# Step 2: Apply integration patches (Kconfig, Makefile)
echo "[2/3] Applying integration patches..."
for patch in "${PATCHES_DIR}"/*.patch; do
    if [ -f "$patch" ]; then
        echo "      Applying: $(basename "$patch")"
        (cd "${KERNEL_DIR}" && git apply --check "$patch" 2>&1) || {
            echo "      WARNING: Patch $(basename "$patch") may already be applied or conflicts exist."
            echo "      Trying to apply anyway..."
            (cd "${KERNEL_DIR}" && git apply "$patch" 2>&1) || {
                echo "      ERROR: Failed to apply patch. Kernel source may have changed."
                echo "      Check ${patch} and apply manually if needed."
            }
        }
    fi
done
echo "      Done."

# Step 3: Verify integration
echo "[3/3] Verifying integration..."
if grep -q "resukisu/kernel/Kconfig" "${KERNEL_DIR}/drivers/Kconfig"; then
    echo "      [OK] drivers/Kconfig updated"
else
    echo "      [WARNING] drivers/Kconfig may not be updated correctly"
fi

if grep -q "resukisu/kernel/" "${KERNEL_DIR}/drivers/Makefile"; then
    echo "      [OK] drivers/Makefile updated"
else
    echo "      [WARNING] drivers/Makefile may not be updated correctly"
fi

if [ -f "${KERNEL_DIR}/drivers/resukisu/Kconfig" ]; then
    echo "      [OK] ReSukiSU kernel source in place"
else
    echo "      [WARNING] ReSukiSU kernel source not found at expected path"
fi

echo ""
echo "=== Setup complete ==="
echo "Next: bash build.sh"
