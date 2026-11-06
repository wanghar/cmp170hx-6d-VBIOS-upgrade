#!/bin/bash
# Install an at-boot PCIe Gen2 retrain (GPU end + root port) and run it now.
# Root cause behind this: cmpunlocker's gen2 patch retrains only the GPU end,
# so the link stays at 2.5 GT/s until the root port is retrained too.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root

cat > "${RETRAIN_BIN}" <<'RETRAIN'
#!/bin/bash
# Set 5 GT/s (Gen2) target speed on GPU and root port, then retrain the root port.
set -uo pipefail
find_gpu() {
    local b p
    b="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')"
    if [[ -n "${b}" ]]; then echo "${b#00000000:}"; return; fi
    p="$(lspci -D -d 10de:20c2: 2>/dev/null | head -1 | awk '{print $1}')"
    if [[ -n "${p}" ]]; then echo "${p#0000:}"; return; fi
    p="$(lspci -D -d 10de:2082: 2>/dev/null | head -1 | awk '{print $1}')"
    [[ -n "${p}" ]] && echo "${p#0000:}"
}
BDF="$(find_gpu)"
[[ -n "${BDF}" ]] || { echo "no CMP 170HX found"; exit 0; }
GCD="$(readlink -f "/sys/bus/pci/devices/0000:${BDF}")"
RP="$(basename "$(dirname "${GCD}")")"
[[ -e "/sys/bus/pci/devices/${RP}/config" ]] || { echo "root port of ${BDF} not found"; exit 0; }

# compatibility: some older ports do not expose Link Control 2 at +0x30
setpci -s "${RP}"  CAP_EXP+0x30.w=0x0002 2>/dev/null || true   # root port LC2 target speed = 2 (5 GT/s)
setpci -s "${BDF}" CAP_EXP+0x30.w=0x0002 2>/dev/null || true   # GPU LC2 target speed = 2 (5 GT/s)
setpci -s "${RP}"  CAP_EXP+0x10.w=0x0020 2>/dev/null || true   # root port Link Control: retrain (bit5)
sleep 1
echo "GPU ${BDF} root port ${RP}"
lspci -vv -s "${BDF}" 2>/dev/null | grep -E "LnkSta:" | sed 's/^/  /'
RETRAIN
chmod 755 "${RETRAIN_BIN}"
ok "installed ${RETRAIN_BIN}"

cat > "${RETRAIN_UNIT}" <<'UNIT'
[Unit]
Description=Retrain CMP 170HX PCIe link to Gen2 (GPU + root port)
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cmp-pcie-gen2-retrain.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
ok "installed ${RETRAIN_UNIT}"

systemctl daemon-reload
systemctl enable "${RETRAIN_UNIT##*/}" >/dev/null 2>&1 || true
log "retraining now"
"${RETRAIN_BIN}" || true
echo
log "verify: nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv"
