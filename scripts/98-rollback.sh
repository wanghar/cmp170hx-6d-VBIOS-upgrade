#!/bin/bash
# Staged rollback.
#   --mclk   remove the HBM NDIV key only
#   --vbios  disable the VBIOS override only (keeps the memory unlock)
#   --all    remove everything: unlock modules, override conf, gen2 service
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root

MODE="${1:-}"
case "${MODE}" in
    --mclk)
        sed -i -E 's/;RmHbmPllNdiv=[0-9]+//' "${CONF}" 2>/dev/null || true
        ok "HBM NDIV override removed"
        ;;
    --vbios)
        [[ -f "${CONF}" ]] || die "missing ${CONF}"
        sed -i -E '/RmLinuxVbiosOverride/d' "${CONF}"
        ok "VBIOS override disabled (memory unlock untouched)"
        ;;
    --all)
        rm -rf "${INSTALL_MOD_DIR}"
        rm -f  "${CONF}"
        systemctl disable --now "${RETRAIN_UNIT##*/}" >/dev/null 2>&1 || true
        rm -f  "${RETRAIN_UNIT}" "${RETRAIN_BIN}"
        systemctl daemon-reload >/dev/null 2>&1 || true
        depmod -a "${KVER}"
        ok "rolled back to the stock driver (8/10 GB, 250 W)"
        ;;
    *)
        die "usage: $0 --mclk | --vbios | --all"
        ;;
esac
log "then reboot to apply: sudo reboot"
