#!/bin/sh
# ReSukiSU Kernel Integration Setup
# ===================================
# Integrates the ReSukiSU kernel module into the Android Common Kernel tree.
#
# This script:
#   1. Initializes the ReSukiSU git submodule (KernelSU/)
#   2. Creates a symlink: common/drivers/kernelsu -> ../../KernelSU/kernel
#   3. Appends build entries to common/drivers/Kconfig and common/drivers/Makefile
#
# The modifications to common/ are intentionally left as uncommitted working-tree
# changes — they do NOT pollute the upstream AOSP kernel git history.
#
# Usage:
#   bash setup.sh                  # Integrate ReSukiSU
#   bash setup.sh --cleanup        # Remove ReSukiSU integration
#   bash setup.sh --help           # Show help
#
# Reference: https://resukisu.github.io/guide/build.html

set -eu

GKI_ROOT="$(cd "$(dirname "$0")" && pwd)"

display_usage() {
	echo "Usage: $0 [--cleanup | --help]"
	echo "  --cleanup     Cleans up previous modifications made by the script."
	echo "  -h, --help    Displays this usage information."
	echo "  (no args)     Sets up ReSukiSU integration."
}

initialize_variables() {
	if [ -d "$GKI_ROOT/common/drivers" ]; then
		 DRIVER_DIR="$GKI_ROOT/common/drivers"
	elif [ -d "$GKI_ROOT/drivers" ]; then
		 DRIVER_DIR="$GKI_ROOT/drivers"
	else
		 echo '[ERROR] "drivers/" directory not found.'
		 exit 127
	fi

	KSU_SUBMODULE="$GKI_ROOT/KernelSU"
	KSU_KERNEL_DIR="$KSU_SUBMODULE/kernel"
	DRIVER_MAKEFILE="$DRIVER_DIR/Makefile"
	DRIVER_KCONFIG="$DRIVER_DIR/Kconfig"
	SYMLINK="$DRIVER_DIR/kernelsu"
}

# Reverts modifications made by this script
perform_cleanup() {
	echo "[+] Cleaning up ReSukiSU integration..."
	if [ -L "$SYMLINK" ]; then
		rm "$SYMLINK" && echo "[-] Symlink removed."
	fi
	if grep -q "kernelsu" "$DRIVER_MAKEFILE" 2>/dev/null; then
		sed -i '/kernelsu/d' "$DRIVER_MAKEFILE" && echo "[-] Makefile reverted."
	fi
	if grep -q "drivers/kernelsu/Kconfig" "$DRIVER_KCONFIG" 2>/dev/null; then
		sed -i '/drivers\/kernelsu\/Kconfig/d' "$DRIVER_KCONFIG" && echo "[-] Kconfig reverted."
	fi
	echo '[+] Cleanup complete.'
}

# Sets up ReSukiSU integration
setup_kernelsu() {
	echo "[+] Setting up ReSukiSU integration..."

	# 1. Initialize the git submodule
	if [ ! -d "$KSU_KERNEL_DIR" ]; then
		echo "[+] Initializing ReSukiSU submodule..."
		git -C "$GKI_ROOT" submodule update --init KernelSU
		echo "[+] Submodule initialized."
	else
		echo "[i] KernelSU submodule already present at $KSU_SUBMODULE"
	fi

	# 2. Create symlink
	if [ -L "$SYMLINK" ]; then
		echo "[i] Symlink already exists: $SYMLINK -> $(readlink "$SYMLINK")"
	else
		REL_PATH=$(realpath --relative-to="$DRIVER_DIR" "$KSU_KERNEL_DIR")
		ln -sf "$REL_PATH" "$SYMLINK"
		echo "[+] Symlink created: drivers/kernelsu -> $REL_PATH"
	fi

	# 3. Append to drivers/Makefile (if not already present)
	if grep -q "kernelsu" "$DRIVER_MAKEFILE" 2>/dev/null; then
		echo "[i] Makefile already has kernelsu entry."
	else
		printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DRIVER_MAKEFILE"
		echo "[+] Appended to drivers/Makefile."
	fi

	# 4. Append to drivers/Kconfig (if not already present)
	if grep -q "drivers/kernelsu/Kconfig" "$DRIVER_KCONFIG" 2>/dev/null; then
		echo "[i] Kconfig already has kernelsu entry."
	else
		sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$DRIVER_KCONFIG"
		echo "[+] Appended to drivers/Kconfig."
	fi

	echo '[+] ReSukiSU integration complete.'
	echo ''
	echo '    Next: bash build.sh'
}

# Process command-line arguments
if [ "$#" -eq 0 ]; then
	initialize_variables
	setup_kernelsu
elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
	display_usage
elif [ "$1" = "--cleanup" ]; then
	initialize_variables
	perform_cleanup
else
	echo "Unknown argument: $1"
	display_usage
	exit 1
fi
