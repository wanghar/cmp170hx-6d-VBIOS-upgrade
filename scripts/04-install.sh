#!/bin/bash
# Install the merged modules, the VBIOS payload and the per-device registry keys.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root

NDIV="64"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ndiv)  NDIV="$2"; shift 2 ;;
        --no-mclk) NDIV=""; shift ;;
        *) die "unknown option: $1" ;;
    esac
done

BDF="$(gpu_bdf)"
DRV="$(driver_version)"
FW="$(fw_dir "${DRV}")"
PAYLOAD_SIZE=0

# --- payload ---
if [[ -f "${WORK_DIR}/payload-300w.bin" ]]; then
    install -d "${FW}"
    install -m 644 "${WORK_DIR}/payload-300w.bin" "${FW}/vbios.bin"
    PAYLOAD_SIZE="$(stat -c %s "${FW}/vbios.bin")"
    ok "payload: ${PAYLOAD_SIZE} bytes -> ${FW}/vbios.bin"
elif [[ -f "${FW}/vbios.bin" ]]; then
    PAYLOAD_SIZE="$(stat -c %s "${FW}/vbios.bin")"
    warn "no new payload built; keeping existing ${FW}/vbios.bin (${PAYLOAD_SIZE} bytes)"
else
    die "no payload: run scripts/03-payload.sh <6D.rom> --install first"
fi

# --- modules ---
[[ -d "${MERGED_DIR}/kernel-open" ]] || die "build first: scripts/02-build.sh"
install -d "${INSTALL_MOD_DIR}"
for ko in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
    src="${MERGED_DIR}/kernel-open/${ko}.ko"
    [[ -f "${src}" ]] || die "missing ${src}"
    install -m 644 "${src}" "${INSTALL_MOD_DIR}/${ko}.ko"
done
printf '%s\n' "${DRV}"        > "${INSTALL_MOD_DIR}/driver_version"
printf '%s\n' "merged-vbios-override" > "${INSTALL_MOD_DIR}/unlock_geometry"
ok "modules -> ${INSTALL_MOD_DIR}"

# --- registry ---
DWORDS="pci=${BDF};RmLinuxVbiosOverride=2;RmLinuxVbiosOverrideSize=${PAYLOAD_SIZE}"
[[ -n "${NDIV}" ]] && DWORDS="${DWORDS};RmHbmPllNdiv=${NDIV}"
cat > "${CONF}" <<CONFEOF
options nvidia NVreg_RegistryDwordsPerDevice="${DWORDS}"
options nvidia NVreg_RegistryBinaryFilePerDevice="pci=${BDF};RmLinuxVbiosOverrideImage=${DRV}/vbios-override/vbios.bin"
CONFEOF
ok "registry: ${CONF}"
cat "${CONF}"

depmod -a "${KVER}"
ok "depmod done"
echo
log "next: sudo reboot   (scripts never reboot for you)"
log "then: sudo bash $(dirname "$0")/99-verify.sh"
