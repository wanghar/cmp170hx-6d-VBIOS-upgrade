#!/bin/bash
# Shared paths/helpers for the CMP 170HX 6D upgrade scripts.
# Source this: . "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${CMP170HX_WORK:-${REPO_ROOT}/work}"
KVER="$(uname -r)"
KSRC="/usr/src/linux-headers-${KVER}"
OGKM_VERSION="${OGKM_VERSION:-615.71.09}"
SRC_DIR="${WORK_DIR}/open-gpu-kernel-modules-${OGKM_VERSION}"
MERGED_DIR="${WORK_DIR}/merged"
CMPUNLOCKER_DIR="${WORK_DIR}/cmpunlocker"
VIX_DIR="${WORK_DIR}/vix-loader"
CMPUNLOCKER_COMMIT="${CMPUNLOCKER_COMMIT:-17535a0}"
VIX_COMMIT="${VIX_COMMIT:-7bf011e3a6100fd6b470917256f73cc18bda0586}"
INSTALL_MOD_DIR="/lib/modules/${KVER}/updates/cmpunlocker"
CONF="/etc/modprobe.d/90-cmp-vbios-override.conf"
RETRAIN_BIN="/usr/local/sbin/cmp-pcie-gen2-retrain.sh"
RETRAIN_UNIT="/etc/systemd/system/cmp-pcie-gen2-retrain.service"

log()  { printf '\033[36m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ "${EUID}" -eq 0 ]] || die "run as root: sudo $0 $*"; }

driver_version() {
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' \
        || echo "${OGKM_VERSION}"
}

fw_dir() { echo "/lib/firmware/nvidia/${1:-$(driver_version)}/vbios-override"; }

# nvidia-smi reports e.g. 00000000:02:00.0 -> pci= form 0000:02:00.0
gpu_bdf() {
    local b
    b="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')"
    [[ -n "${b}" ]] || { echo "${BDF:-0000:02:00.0}"; return; }
    echo "${b#00000000:}"
}

