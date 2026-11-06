#!/bin/bash
# Install NVIDIA 615.71.09 open kernel modules (idempotent-ish; skips if already installed).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root

RUNFILE="${1:-}"
if [[ -z "${RUNFILE}" ]]; then
    die "usage: sudo $0 /path/to/NVIDIA-Linux-x86_64-${OGKM_VERSION}.run"
fi
[[ -f "${RUNFILE}" ]] || die "not found: ${RUNFILE}"

if nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | grep -q "${OGKM_VERSION}"; then
    ok "driver ${OGKM_VERSION} already installed"
else
    log "installing ${RUNFILE} (open modules)"
    chmod +x "${RUNFILE}"
    "${RUNFILE}" --silent --kernel-module-type=open < /dev/null
    ok "driver installed"
fi

nvidia-smi --query-gpu=driver_version --format=csv,noheader
grep -i "kernel module type" /var/log/nvidia-installer.log 2>/dev/null | tail -1 || true
