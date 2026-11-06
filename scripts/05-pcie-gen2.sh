#!/bin/bash
# Install an at-boot PCIe Gen2 retrain (GPU end + root port) and run it now.
# Root cause behind this: cmpunlocker's gen2 patch retrains only the GPU end,
# so the link stays at 2.5 GT/s until the root port is retrained too.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root

install -m 755 "${REPO_ROOT}/config/cmp-pcie-gen2-retrain.sh" "${RETRAIN_BIN}"
ok "installed ${RETRAIN_BIN}"

install -m 644 "${REPO_ROOT}/config/cmp-pcie-gen2-retrain.service" "${RETRAIN_UNIT}"
ok "installed ${RETRAIN_UNIT}"

systemctl daemon-reload
systemctl enable "${RETRAIN_UNIT##*/}" >/dev/null 2>&1 || true
log "retraining now"
"${RETRAIN_BIN}" || true
echo
log "verify: nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv"
