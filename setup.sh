#!/usr/bin/env bash
# Integrate ReSukiSU into the repo-synced Android kernel tree.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="${ROOT_DIR}/patches"
KERNEL_DIR="${ROOT_DIR}/common"
KSU_SUBMODULE="${ROOT_DIR}/KernelSU"
KSU_KERNEL_DIR="${KSU_SUBMODULE}/kernel"
TARGET_ENV="${AVD_TARGET_ENV:-${ROOT_DIR}/out/target.env}"
DRIVER_DIR=""
SYMLINK=""
REPO_BRANCH=""

usage() {
    cat <<'EOF'
Usage:
  bash setup.sh             Add transient ReSukiSU driver entries and symlink.
  bash setup.sh --cleanup   Remove transient entries, symlink, and applied patches.
  bash setup.sh --check     Check patch state and report integration state.

Notes:
  - patches/ may be empty; setup.sh still wires ReSukiSU through a symlink.
  - common/drivers/Kconfig and common/drivers/Makefile changes are transient
    working-tree integration changes. Run --cleanup to return upstream clean.
  - If out/target.env exists, branch-specific patches under patches/<branch>/ are used.
EOF
}

init_vars() {
    if [ -f "${TARGET_ENV}" ]; then
        # shellcheck source=/dev/null
        . "${TARGET_ENV}"
        REPO_BRANCH="${AVD_REPO_BRANCH:-}"
    fi
    if [ ! -d "${KERNEL_DIR}" ]; then
        echo "ERROR: kernel source not found at ${KERNEL_DIR}. Run prepare.sh first." >&2
        exit 1
    fi
    DRIVER_DIR="${KERNEL_DIR}/drivers"
    if [ ! -d "${DRIVER_DIR}" ]; then
        echo "ERROR: drivers directory not found at ${DRIVER_DIR}" >&2
        exit 1
    fi
    SYMLINK="${DRIVER_DIR}/kernelsu"
}

patch_series() {
    {
        find "${PATCHES_DIR}" -maxdepth 1 -type f -name '*.patch' 2>/dev/null
        find "${PATCHES_DIR}/common" -maxdepth 1 -type f -name '*.patch' 2>/dev/null
        if [ -n "${REPO_BRANCH}" ]; then
            find "${PATCHES_DIR}/${REPO_BRANCH}" -maxdepth 1 -type f -name '*.patch' 2>/dev/null
        fi
    } | sort
}

apply_patch_file() {
    patch="$1"
    if (cd "${KERNEL_DIR}" && git apply --check "${patch}" >/dev/null 2>&1); then
        (cd "${KERNEL_DIR}" && git apply "${patch}")
        echo "[+] Applied patch: ${patch#${ROOT_DIR}/}"
    elif (cd "${KERNEL_DIR}" && git apply -R --check "${patch}" >/dev/null 2>&1); then
        echo "[i] Patch already applied: ${patch#${ROOT_DIR}/}"
    else
        echo "ERROR: patch cannot be applied cleanly: ${patch#${ROOT_DIR}/}" >&2
        exit 1
    fi
}

reverse_patch_file() {
    patch="$1"
    if (cd "${KERNEL_DIR}" && git apply -R --check "${patch}" >/dev/null 2>&1); then
        (cd "${KERNEL_DIR}" && git apply -R "${patch}")
        echo "[-] Reversed patch: ${patch#${ROOT_DIR}/}"
    else
        echo "[i] Patch was not applied: ${patch#${ROOT_DIR}/}"
    fi
}

check_patch_file() {
    patch="$1"
    if (cd "${KERNEL_DIR}" && git apply --check "${patch}" >/dev/null 2>&1); then
        echo "[can-apply] ${patch#${ROOT_DIR}/}"
    elif (cd "${KERNEL_DIR}" && git apply -R --check "${patch}" >/dev/null 2>&1); then
        echo "[applied]   ${patch#${ROOT_DIR}/}"
    else
        echo "[conflict]  ${patch#${ROOT_DIR}/}"
        return 1
    fi
}

ensure_resukisu() {
    if [ -d "${KSU_KERNEL_DIR}" ]; then
        echo "[i] ReSukiSU already present: ${KSU_SUBMODULE}"
        return
    fi
    if [ -f "${ROOT_DIR}/.gitmodules" ]; then
        git -C "${ROOT_DIR}" submodule update --init KernelSU
    else
        git clone https://github.com/ReSukiSU/ReSukiSU "${KSU_SUBMODULE}"
    fi
}

create_symlink() {
    rel_path="$(realpath --relative-to="${DRIVER_DIR}" "${KSU_KERNEL_DIR}")"
    if [ -L "${SYMLINK}" ] && [ "$(readlink "${SYMLINK}")" = "${rel_path}" ]; then
        echo "[i] Symlink already exists: common/drivers/kernelsu -> ${rel_path}"
        return
    fi
    rm -rf "${SYMLINK}"
    ln -s "${rel_path}" "${SYMLINK}"
    echo "[+] Created symlink: common/drivers/kernelsu -> ${rel_path}"
}

ensure_driver_entries() {
    driver_makefile="${DRIVER_DIR}/Makefile"
    driver_kconfig="${DRIVER_DIR}/Kconfig"

    if grep -q 'obj-$(CONFIG_KSU).*kernelsu/' "${driver_makefile}"; then
        echo "[i] drivers/Makefile already has kernelsu entry."
    else
        printf 'obj-$(CONFIG_KSU)\t\t+= kernelsu/\n' >> "${driver_makefile}"
        echo "[+] Added kernelsu entry to common/drivers/Makefile"
    fi

    if grep -q 'source "drivers/kernelsu/Kconfig"' "${driver_kconfig}"; then
        echo "[i] drivers/Kconfig already sources kernelsu."
    else
        sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "${driver_kconfig}"
        echo "[+] Added kernelsu source to common/drivers/Kconfig"
    fi
}

remove_driver_entries() {
    driver_makefile="${DRIVER_DIR}/Makefile"
    driver_kconfig="${DRIVER_DIR}/Kconfig"

    if [ -f "${driver_makefile}" ]; then
        sed -i '/kernelsu/d' "${driver_makefile}"
        perl -0pi -e 's/\n+\z/\n/' "${driver_makefile}"
    fi
    if [ -f "${driver_kconfig}" ]; then
        sed -i '/drivers\/kernelsu\/Kconfig/d' "${driver_kconfig}"
        perl -0pi -e 's/\n{3,}endmenu\n/\n\nendmenu\n/' "${driver_kconfig}"
    fi
    echo "[-] Removed transient kernelsu driver entries."
}

report_driver_state() {
    if [ -L "${SYMLINK}" ]; then
        echo "[state] symlink: common/drivers/kernelsu -> $(readlink "${SYMLINK}")"
    else
        echo "[state] symlink: absent"
    fi
    if grep -q 'obj-$(CONFIG_KSU).*kernelsu/' "${DRIVER_DIR}/Makefile"; then
        echo "[state] Makefile entry: present"
    else
        echo "[state] Makefile entry: absent"
    fi
    if grep -q 'source "drivers/kernelsu/Kconfig"' "${DRIVER_DIR}/Kconfig"; then
        echo "[state] Kconfig entry: present"
    else
        echo "[state] Kconfig entry: absent"
    fi
}

setup() {
    init_vars
    ensure_resukisu
    echo "=== Applying kernel patch series ==="
    while IFS= read -r patch; do
        [ -n "${patch}" ] && apply_patch_file "${patch}"
    done < <(patch_series)
    ensure_driver_entries
    create_symlink
    echo "[OK] ReSukiSU integration ready."
}

cleanup() {
    init_vars
    if [ -L "${SYMLINK}" ]; then
        rm "${SYMLINK}"
        echo "[-] Removed symlink: common/drivers/kernelsu"
    fi
    remove_driver_entries
    echo "=== Reversing kernel patch series ==="
    while IFS= read -r patch; do
        [ -n "${patch}" ] && reverse_patch_file "${patch}"
    done < <(patch_series | sort -r)
    echo "[OK] cleanup complete."
}

check() {
    init_vars
    failed=0
    while IFS= read -r patch; do
        [ -n "${patch}" ] && check_patch_file "${patch}" || failed=1
    done < <(patch_series)
    report_driver_state
    exit "${failed}"
}

case "${1:-}" in
    "") setup ;;
    --cleanup) cleanup ;;
    --check) check ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
esac
