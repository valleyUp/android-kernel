#!/usr/bin/env bash
# Integrate SukiSU-Ultra into the repo-synced Android kernel tree.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="${ROOT_DIR}/patches"
KERNEL_DIR="${ROOT_DIR}/common"
KSU_SUBMODULE="${ROOT_DIR}/KernelSU"
KSU_KERNEL_DIR="${KSU_SUBMODULE}/kernel"
TARGET_ENV="${AVD_TARGET_ENV:-${ROOT_DIR}/out/target.env}"
KSU_ENV="${ROOT_DIR}/out/ksu.env"
KSU_REPO_URL="https://github.com/SukiSU-Ultra/SukiSU-Ultra"
KSU_VERSION_BASE=40000
KSU_VERSION_OFFSET=2815
KSU_MANAGER_VERSION="${KSU_MANAGER_VERSION:-40796}"
DRIVER_DIR=""
SYMLINK=""
REPO_BRANCH=""
ACTION="setup"

usage() {
    cat <<'EOF'
Usage:
  bash setup.sh [--manager-version CODE]
  bash setup.sh --cleanup
  bash setup.sh --check

Options:
  --manager-version CODE   Align KernelSU submodule to the git commit that
                           produces this manager versionCode (default: 40796).
                           Same formula as SukiSU-Ultra manager APK:
                           40000 + git rev-list --count HEAD - 2815

Environment:
  KSU_MANAGER_VERSION      Same as --manager-version (CLI takes precedence).
  KSU_MANAGER_APK          Path to prebuilt official manager APK for version check.

Notes:
  - patches/common/ applies to common/.
  - patches/<repo-branch>/ applies to common/ only for that target branch.
  - patches/kernelsu/ applies to KernelSU/.
  - common/drivers/Kconfig and common/drivers/Makefile changes are transient.
  - Use official SukiSU-Ultra GitHub Release APK (ShirkNeko signature).
  - common-android15-6.6 x86_64 requires syscall_hardening=off at boot for KernelSU.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --cleanup) ACTION="cleanup"; shift ;;
            --check) ACTION="check"; shift ;;
            --manager-version)
                [ "$#" -ge 2 ] || { echo "ERROR: --manager-version requires a value" >&2; exit 2; }
                KSU_MANAGER_VERSION="$2"
                shift 2
                ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
        esac
    done
}

init_vars() {
    REPO_BRANCH="${AVD_REPO_BRANCH:-}"
    if [ -f "${TARGET_ENV}" ]; then
        # shellcheck source=/dev/null
        . "${TARGET_ENV}"
        REPO_BRANCH="${AVD_REPO_BRANCH:-}"
    elif [ -f "${ROOT_DIR}/out/target.json" ]; then
        REPO_BRANCH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("repo_branch",""))' "${ROOT_DIR}/out/target.json")"
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

version_to_count() {
    echo $(( KSU_MANAGER_VERSION - KSU_VERSION_BASE + KSU_VERSION_OFFSET ))
}

compute_version_at_head() {
    local count
    count=$(git -C "${KSU_SUBMODULE}" rev-list --count HEAD)
    echo $(( KSU_VERSION_BASE + count - KSU_VERSION_OFFSET ))
}

ensure_submodule_depth() {
    local target="$1" head_count deepen
    head_count=$(git -C "${KSU_SUBMODULE}" rev-list --count HEAD)
    while [ "${head_count}" -lt "${target}" ]; do
        deepen=$(( target - head_count + 50 ))
        echo "[i] Fetching KernelSU history (have ${head_count}, need ${target})..."
        git -C "${KSU_SUBMODULE}" fetch --deepen="${deepen}" origin
        head_count=$(git -C "${KSU_SUBMODULE}" rev-list --count HEAD)
    done
}

resolve_manager_commit() {
    local target head_count skip commit actual c cnt
    target=$(version_to_count)
    head_count=$(git -C "${KSU_SUBMODULE}" rev-list --count HEAD)
    if [ "${target}" -gt "${head_count}" ]; then
        echo "ERROR: manager version ${KSU_MANAGER_VERSION} requires commit count ${target}," >&2
        echo "       but KernelSU HEAD only has ${head_count}." >&2
        echo "Fix: git -C KernelSU fetch origin && git -C KernelSU checkout origin/main" >&2
        exit 1
    fi
    skip=$(( head_count - target ))
    commit=$(git -C "${KSU_SUBMODULE}" rev-list --first-parent --max-count=1 --skip="${skip}" HEAD)
    actual=$(git -C "${KSU_SUBMODULE}" rev-list --count "${commit}")
    if [ "${actual}" -ne "${target}" ]; then
        commit=""
        while IFS= read -r c; do
            cnt=$(git -C "${KSU_SUBMODULE}" rev-list --count "${c}")
            if [ "${cnt}" -eq "${target}" ]; then
                commit="${c}"
                break
            fi
        done < <(git -C "${KSU_SUBMODULE}" rev-list HEAD)
    fi
    if [ -z "${commit}" ]; then
        echo "ERROR: no KernelSU commit found for manager version ${KSU_MANAGER_VERSION}" >&2
        exit 1
    fi
    printf '%s\n' "${commit}"
}

checkout_manager_version() {
    local target commit computed
    target=$(version_to_count)
    ensure_submodule_depth "${target}"
    commit=$(resolve_manager_commit)
    git -C "${KSU_SUBMODULE}" checkout --detach "${commit}" >/dev/null
    computed=$(compute_version_at_head)
    if [ "${computed}" -ne "${KSU_MANAGER_VERSION}" ]; then
        echo "ERROR: post-checkout version mismatch: expected ${KSU_MANAGER_VERSION}, got ${computed}" >&2
        exit 1
    fi
    echo "[+] KernelSU aligned: ${commit} (versionCode=${computed})"
}

common_patch_series() {
    {
        find_patch_files "${PATCHES_DIR}"
        find_patch_files "${PATCHES_DIR}/common"
        if [ -n "${REPO_BRANCH}" ]; then
            find_patch_files "${PATCHES_DIR}/${REPO_BRANCH}"
        fi
    } | sort
}

common_patch_cleanup_series() {
    {
        find_patch_files "${PATCHES_DIR}"
        find_patch_files "${PATCHES_DIR}/common"
        shopt -s nullglob
        for dir in "${PATCHES_DIR}"/common-*; do
            find_patch_files "${dir}"
        done
        shopt -u nullglob
    } | sort
}

ksu_patch_series() {
    find_patch_files "${PATCHES_DIR}/kernelsu"
}

find_patch_files() {
    dir="$1"
    [ -d "${dir}" ] || return 0
    find "${dir}" -maxdepth 1 -type f -name '*.patch' | sort
}

requires_common_patch() {
    case "${REPO_BRANCH}" in
        common-android12) return 0 ;;
        *) return 1 ;;
    esac
}

apply_patch_file() {
    target_dir="$1"
    patch="$2"
    label="$3"
    if (cd "${target_dir}" && git apply --check "${patch}" >/dev/null 2>&1); then
        (cd "${target_dir}" && git apply "${patch}")
        echo "[+] Applied ${label} patch: ${patch#${ROOT_DIR}/}"
    elif (cd "${target_dir}" && git apply -R --check "${patch}" >/dev/null 2>&1); then
        echo "[i] ${label} patch already applied: ${patch#${ROOT_DIR}/}"
    else
        echo "ERROR: ${label} patch cannot be applied cleanly: ${patch#${ROOT_DIR}/}" >&2
        exit 1
    fi
}

reverse_patch_file() {
    target_dir="$1"
    patch="$2"
    label="$3"
    if (cd "${target_dir}" && git apply -R --check "${patch}" >/dev/null 2>&1); then
        (cd "${target_dir}" && git apply -R "${patch}")
        echo "[-] Reversed ${label} patch: ${patch#${ROOT_DIR}/}"
    else
        echo "[i] ${label} patch was not applied: ${patch#${ROOT_DIR}/}"
    fi
}

check_patch_file() {
    target_dir="$1"
    patch="$2"
    label="$3"
    if (cd "${target_dir}" && git apply --check "${patch}" >/dev/null 2>&1); then
        echo "[can-apply] ${label}: ${patch#${ROOT_DIR}/}"
    elif (cd "${target_dir}" && git apply -R --check "${patch}" >/dev/null 2>&1); then
        echo "[applied]   ${label}: ${patch#${ROOT_DIR}/}"
    else
        echo "[conflict]  ${label}: ${patch#${ROOT_DIR}/}"
        return 1
    fi
}

ensure_sukisu_ultra() {
    if [ ! -e "${KSU_SUBMODULE}/.git" ] && [ ! -f "${KSU_SUBMODULE}/.git" ]; then
        if [ -f "${ROOT_DIR}/.gitmodules" ]; then
            git -C "${ROOT_DIR}" submodule update --init KernelSU
        else
            git clone "${KSU_REPO_URL}" "${KSU_SUBMODULE}"
        fi
    fi
    if [ ! -d "${KSU_KERNEL_DIR}" ]; then
        echo "ERROR: KernelSU kernel tree not found at ${KSU_KERNEL_DIR}" >&2
        exit 1
    fi
    local url=""
    url=$(git -C "${KSU_SUBMODULE}" remote get-url origin 2>/dev/null || true)
    if [ -n "${url}" ] && [[ "${url}" != *"SukiSU-Ultra"* ]]; then
        echo "ERROR: KernelSU remote is '${url}', expected SukiSU-Ultra." >&2
        echo "Fix: git submodule deinit -f KernelSU && rm -rf KernelSU .git/modules/KernelSU && git submodule update --init KernelSU" >&2
        exit 1
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

write_ksu_env() {
    mkdir -p "${ROOT_DIR}/out"
    cat > "${KSU_ENV}" <<EOF
# Auto-generated by setup.sh
KSU_MANAGER_VERSION=${KSU_MANAGER_VERSION}
KSU_COMMIT=$(git -C "${KSU_SUBMODULE}" rev-parse HEAD)
KSU_COMPUTED_VERSION=$(compute_version_at_head)
EOF
    echo "[+] Wrote ${KSU_ENV#${ROOT_DIR}/}"
}

remove_ksu_env() {
    if [ -f "${KSU_ENV}" ]; then
        rm -f "${KSU_ENV}"
        echo "[-] Removed ${KSU_ENV#${ROOT_DIR}/}"
    fi
}

verify_prebuilt_apk() {
    local apk="${KSU_MANAGER_APK:-}" candidates=() code=""
    if [ -z "${apk}" ]; then
        shopt -s nullglob
        candidates=( "${ROOT_DIR}"/SukiSU_*.apk )
        shopt -u nullglob
        if [ "${#candidates[@]}" -eq 1 ]; then
            apk="${candidates[0]}"
        elif [ "${#candidates[@]}" -gt 1 ]; then
            echo "[warn] Multiple SukiSU_*.apk files found; set KSU_MANAGER_APK to select one."
            return 0
        fi
    fi
    if [ -z "${apk}" ] || [ ! -f "${apk}" ]; then
        echo "[warn] No prebuilt manager APK found (optional). Use SukiSU-Ultra GitHub Releases."
        return 0
    fi
    if ! command -v aapt >/dev/null 2>&1; then
        echo "[warn] aapt not found; skipping APK versionCode check."
        return 0
    fi
    code=$(aapt dump badging "${apk}" 2>/dev/null | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p" | head -1)
    if [ -z "${code}" ]; then
        echo "[warn] Could not read versionCode from ${apk}"
        return 0
    fi
    if [ "${code}" != "${KSU_MANAGER_VERSION}" ]; then
        echo "ERROR: APK versionCode=${code} does not match KSU_MANAGER_VERSION=${KSU_MANAGER_VERSION}" >&2
        exit 1
    fi
    echo "[+] Prebuilt APK versionCode verified: ${code} (${apk##*/})"
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
    if [ -f "${KSU_ENV}" ]; then
        echo "[state] ksu.env: present ($(grep -E '^KSU_' "${KSU_ENV}" | tr '\n' ' '))"
    else
        echo "[state] ksu.env: absent"
    fi
    if [ -d "${KSU_SUBMODULE}/.git" ] || [ -f "${KSU_SUBMODULE}/.git" ]; then
        local computed
        computed=$(compute_version_at_head 2>/dev/null || echo unknown)
        echo "[state] KernelSU HEAD: $(git -C "${KSU_SUBMODULE}" rev-parse --short HEAD 2>/dev/null || echo unknown) (versionCode=${computed})"
    fi
}

setup() {
    init_vars
    ensure_sukisu_ultra
    echo "Target repo branch: ${REPO_BRANCH:-unknown}"
    echo "Manager version: ${KSU_MANAGER_VERSION}"
    echo "=== Aligning KernelSU submodule ==="
    checkout_manager_version
    echo "=== Applying kernel patch series ==="
    mapfile -t common_patches < <(common_patch_series)
    if [ "${#common_patches[@]}" -eq 0 ]; then
        if requires_common_patch; then
            echo "ERROR: no common patch found for ${REPO_BRANCH}. Expected patches/${REPO_BRANCH}/" >&2
            exit 1
        fi
        echo "[i] No common patches selected for ${REPO_BRANCH:-unknown}."
    fi
    for patch in "${common_patches[@]}"; do
        [ -n "${patch}" ] && apply_patch_file "${KERNEL_DIR}" "${patch}" "common"
    done
    echo "=== Applying SukiSU-Ultra patch series ==="
    while IFS= read -r patch; do
        [ -n "${patch}" ] && apply_patch_file "${KSU_SUBMODULE}" "${patch}" "kernelsu"
    done < <(ksu_patch_series)
    ensure_driver_entries
    create_symlink
    write_ksu_env
    verify_prebuilt_apk
    if [ "${REPO_BRANCH}" = "common-android15-6.6" ]; then
        echo "[i] common-android15-6.6 x86_64: boot AVD with syscall_hardening=off (see package.sh deploy files)."
    fi
    echo "[OK] SukiSU-Ultra integration ready."
}

cleanup() {
    init_vars
    if [ -L "${SYMLINK}" ]; then
        rm "${SYMLINK}"
        echo "[-] Removed symlink: common/drivers/kernelsu"
    fi
    remove_driver_entries
    remove_ksu_env
    if [ -d "${KSU_SUBMODULE}" ]; then
        echo "=== Reversing SukiSU-Ultra patch series ==="
        while IFS= read -r patch; do
            [ -n "${patch}" ] && reverse_patch_file "${KSU_SUBMODULE}" "${patch}" "kernelsu"
        done < <(ksu_patch_series | sort -r)
    fi
    echo "=== Reversing kernel patch series ==="
    while IFS= read -r patch; do
        [ -n "${patch}" ] && reverse_patch_file "${KERNEL_DIR}" "${patch}" "common"
    done < <(common_patch_cleanup_series | sort -r)
    echo "[OK] cleanup complete."
}

check() {
    init_vars
    if [ -f "${KSU_ENV}" ]; then
        # shellcheck source=/dev/null
        . "${KSU_ENV}"
        KSU_MANAGER_VERSION="${KSU_MANAGER_VERSION:-40796}"
    fi
    ensure_sukisu_ultra
    echo "Target repo branch: ${REPO_BRANCH:-unknown}"
    echo "Manager version: ${KSU_MANAGER_VERSION}"
    failed=0
    mapfile -t common_patches < <(common_patch_series)
    if [ "${#common_patches[@]}" -eq 0 ]; then
        if requires_common_patch; then
            echo "[missing]  common: expected patches/${REPO_BRANCH}/"
            failed=1
        else
            echo "[state] common patches: none selected"
        fi
    fi
    for patch in "${common_patches[@]}"; do
        [ -n "${patch}" ] && check_patch_file "${KERNEL_DIR}" "${patch}" "common" || failed=1
    done
    while IFS= read -r patch; do
        [ -n "${patch}" ] && check_patch_file "${KSU_SUBMODULE}" "${patch}" "kernelsu" || failed=1
    done < <(ksu_patch_series)
    local computed
    computed=$(compute_version_at_head 2>/dev/null || echo "")
    if [ -n "${computed}" ] && [ "${computed}" != "${KSU_MANAGER_VERSION}" ]; then
        echo "[mismatch] KernelSU versionCode=${computed}, expected ${KSU_MANAGER_VERSION}. Re-run: bash setup.sh --manager-version ${KSU_MANAGER_VERSION}"
        failed=1
    elif [ -n "${computed}" ]; then
        echo "[aligned]  KernelSU versionCode=${computed}"
    fi
    if [ "${REPO_BRANCH}" = "common-android15-6.6" ]; then
        cpufeatures="${KERNEL_DIR}/arch/x86/include/asm/cpufeatures.h"
        if grep -q 'X86_FEATURE_INDIRECT_SAFE' "${cpufeatures}"; then
            echo "[ok]      x86 syscall hardening bypass patch present"
        else
            echo "[missing] x86 syscall hardening bypass: X86_FEATURE_INDIRECT_SAFE not in ${cpufeatures}"
            failed=1
        fi
    fi
    report_driver_state
    exit "${failed}"
}

parse_args "$@"

case "${ACTION}" in
    setup) setup ;;
    cleanup) cleanup ;;
    check) check ;;
esac