#!/usr/bin/env bash
# Prepare Android kernel sources for a specific AVD /proc/version.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
META_JSON="${ROOT_DIR}/out/target.json"
META_ENV="${ROOT_DIR}/out/target.env"
PROC_VERSION=""
PROC_VERSION_FILE=""
BUILD_ID=""
REPO_BRANCH=""
KERNEL_VERSION=""
COMMON_COMMIT=""
CI_TARGET="kernel_virt_x86_64"
JOBS="${JOBS:-4}"
DO_SYNC=1
DO_CHECKOUT=1
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage:
  bash prepare.sh --proc-version '<adb shell cat /proc/version output>'
  bash prepare.sh --proc-version-file proc-version.txt
  bash prepare.sh --repo-branch common-android14-6.1 --build-id 9964412 --common-commit 7e35917775b8

Options:
  --no-sync          Only parse metadata; do not run repo init/sync.
  --no-checkout      Do not checkout exact commits after sync.
  --dry-run          Print commands without executing repo/git network steps.
  -j, --jobs N       repo sync jobs. Default: 4.
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
        --proc-version) PROC_VERSION="$2"; shift 2 ;;
        --proc-version-file) PROC_VERSION_FILE="$2"; shift 2 ;;
        --build-id) BUILD_ID="$2"; shift 2 ;;
        --repo-branch) REPO_BRANCH="$2"; shift 2 ;;
        --kernel-version) KERNEL_VERSION="$2"; shift 2 ;;
        --common-commit) COMMON_COMMIT="$2"; shift 2 ;;
        --ci-target) CI_TARGET="$2"; shift 2 ;;
        --no-sync) DO_SYNC=0; shift ;;
        --no-checkout) DO_CHECKOUT=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -j|--jobs) JOBS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

mkdir -p "${ROOT_DIR}/out"

META_ARGS=(metadata --ci-target "${CI_TARGET}" --out "${META_JSON}" --env-out "${META_ENV}" --quiet)
[ -n "${PROC_VERSION}" ] && META_ARGS+=(--proc-version "${PROC_VERSION}")
[ -n "${PROC_VERSION_FILE}" ] && META_ARGS+=(--proc-version-file "${PROC_VERSION_FILE}")
[ -n "${BUILD_ID}" ] && META_ARGS+=(--build-id "${BUILD_ID}")
[ -n "${REPO_BRANCH}" ] && META_ARGS+=(--repo-branch "${REPO_BRANCH}")
[ -n "${KERNEL_VERSION}" ] && META_ARGS+=(--kernel-version "${KERNEL_VERSION}")
[ -n "${COMMON_COMMIT}" ] && META_ARGS+=(--common-commit "${COMMON_COMMIT}")

python3 "${ROOT_DIR}/scripts/avd_kernel_meta.py" "${META_ARGS[@]}"

# shellcheck source=/dev/null
. "${META_ENV}"

echo "=== Target AVD kernel ==="
echo "Kernel version : ${AVD_KERNEL_VERSION:-N/A}"
echo "Repo branch    : ${AVD_REPO_BRANCH}"
echo "Build ID       : ${AVD_BUILD_ID:-N/A}"
echo "Common commit  : ${AVD_COMMON_COMMIT:-N/A}"
echo "CI BUILD_INFO  : ${AVD_CI_BUILD_INFO_FOUND}"
echo ""

if [ "${DO_SYNC}" -eq 0 ]; then
    echo "[i] --no-sync set; metadata written to ${META_JSON}"
    exit 0
fi

command -v repo >/dev/null 2>&1 || {
    echo "ERROR: repo command not found. Install it into PATH first." >&2
    exit 1
}

cd "${ROOT_DIR}"
run repo init --depth=1 \
    -u https://android.googlesource.com/kernel/manifest \
    -b "${AVD_REPO_BRANCH}" \
    --repo-rev="${REPO_REV:-v2.16}"

run repo sync -c -j"${JOBS}" --no-tags --fail-fast

if [ "${DO_CHECKOUT}" -eq 0 ]; then
    echo "[i] --no-checkout set; source sync complete."
    exit 0
fi

echo "=== Checkout exact CI commits when available ==="
python3 "${ROOT_DIR}/scripts/avd_kernel_meta.py" checkout-plan --meta "${META_JSON}" --root "${ROOT_DIR}" |
while IFS="$(printf '\t')" read -r repo_name relpath commit; do
    [ -n "${repo_name}" ] || continue
    full_path="${ROOT_DIR}/${relpath}"
    if [ ! -d "${full_path}" ]; then
        echo "[skip] ${repo_name}: ${relpath} missing"
        continue
    fi
    echo "[git] ${repo_name} (${relpath}) -> ${commit}"
    run git -C "${full_path}" fetch --depth=1 aosp "${commit}"
    run git -C "${full_path}" checkout -B avd-exact FETCH_HEAD
done

if [ "${DRY_RUN}" -eq 0 ]; then
    echo "=== Verify exact checkout ==="
    python3 "${ROOT_DIR}/scripts/avd_kernel_meta.py" verify-checkout \
        --meta "${META_JSON}" \
        --root "${ROOT_DIR}" \
        --required kernel/common \
        --required kernel/common-modules/virtual-device \
        --required kernel/build \
        --required kernel/configs
else
    echo "[dry-run] checkout verification skipped."
fi

echo "[OK] prepare complete. Next: bash setup.sh"
