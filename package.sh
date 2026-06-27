#!/usr/bin/env bash
# Collect a deployable tarball from an existing dist/ directory.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
DEPLOY_DIR="${DEPLOY_DIR:-${ROOT_DIR}/avd-sukisu-deploy}"
TARBALL="${TARBALL:-${ROOT_DIR}/avd-sukisu-deploy.tar.gz}"
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage:
  bash package.sh [--dry-run]

Requires a completed build in dist/. This script does not compile.
EOF
}

run() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

if [ ! -f "${DIST_DIR}/bzImage" ]; then
    if [ "${DRY_RUN}" -eq 1 ]; then
        echo "[dry-run] ${DIST_DIR}/bzImage is not present yet; package would require a completed build."
    else
        echo "ERROR: ${DIST_DIR}/bzImage not found. Run build.sh after prepare/setup." >&2
        exit 1
    fi
fi

run rm -rf "${DEPLOY_DIR}"
run mkdir -p "${DEPLOY_DIR}/kernel" "${DEPLOY_DIR}/modules/all_modules" "${DEPLOY_DIR}/modules/ramdisk_modules"
if [ -f "${DIST_DIR}/bzImage" ]; then
    run cp "${DIST_DIR}/bzImage" "${DEPLOY_DIR}/kernel/"
else
    run cp "${DIST_DIR}/bzImage" "${DEPLOY_DIR}/kernel/"
fi

if [ -d "${DIST_DIR}" ]; then
    while IFS= read -r ko; do
        run cp "${ko}" "${DEPLOY_DIR}/modules/all_modules/"
    done < <(find "${DIST_DIR}" -name '*.ko' -type f | sort)
fi

for ko in \
    virtio-rng.ko virtio_blk.ko virtio_console.ko virtio_dma_buf.ko \
    virtio_pci.ko virtio_pci_legacy_dev.ko virtio_pci_modern_dev.ko \
    vmw_vsock_virtio_transport.ko virtio_net.ko virtio_input.ko \
    net_failover.ko failover.ko; do
    if [ -f "${DEPLOY_DIR}/modules/all_modules/${ko}" ]; then
        run cp "${DEPLOY_DIR}/modules/all_modules/${ko}" "${DEPLOY_DIR}/modules/ramdisk_modules/"
    else
        echo "[warn] missing expected ramdisk module: ${ko}"
    fi
done

if [ -f "${ROOT_DIR}/out/target.json" ]; then
    run cp "${ROOT_DIR}/out/target.json" "${DEPLOY_DIR}/target.json"
fi

KSU_ENV="${ROOT_DIR}/out/ksu.env"
KSU_MANAGER_VERSION=""
if [ -f "${KSU_ENV}" ]; then
    # shellcheck source=/dev/null
    . "${KSU_ENV}"
    run cp "${KSU_ENV}" "${DEPLOY_DIR}/ksu.env"
fi

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[dry-run] would write ${DEPLOY_DIR}/kernel.parameters"
else
    printf 'syscall_hardening=off\n' > "${DEPLOY_DIR}/kernel.parameters"
fi

deploy_txt="${DEPLOY_DIR}/AVD_DEPLOY.txt"
if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[dry-run] would write ${deploy_txt}"
else
    cat > "${deploy_txt}" <<EOF
AVD SukiSU-Ultra kernel deploy
===============================

1. Replace the AVD kernel with kernel/bzImage from this package.

2. Pass syscall_hardening=off at boot (required for KernelSU on x86_64 6.6):
   - config.ini: kernel.parameters = syscall_hardening=off
   - or emulator:  -append syscall_hardening=off

3. Verify after boot:
   cat /sys/devices/system/cpu/syscall_hardening
   Expected: Disabled

4. Install the official SukiSU manager APK (ShirkNeko signature) with
   versionCode=${KSU_MANAGER_VERSION:-unknown} (see ksu.env).
EOF
fi

run tar -C "${ROOT_DIR}" -czf "${TARBALL}" "$(basename "${DEPLOY_DIR}")"
if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[dry-run] package would be: ${TARBALL}"
else
    echo "[OK] package: ${TARBALL}"
fi
echo "[i] AVD boot requires kernel cmdline: syscall_hardening=off"
