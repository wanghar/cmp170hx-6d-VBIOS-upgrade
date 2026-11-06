#!/bin/bash
# CMP 170HX: after the driver cleared the GPU-side "disable Gen2" bit, retrain the
# *root port* as well. The driver's own retrain only touches the GPU end, which
# leaves the link trained down at 2.5 GT/s. Handles every CMP 170HX in the system.
set -uo pipefail

list_gpus() {
    local b
    if command -v nvidia-smi >/dev/null 2>&1; then
        b="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | tr -d ' ')"
        if [[ -n "${b}" ]]; then
            while IFS= read -r line; do echo "${line#00000000:}"; done <<< "${b}"
            return
        fi
    fi
    lspci -D -d 10de:20c2: 2>/dev/null | awk '{print $1}' | sed 's/^0000://'
}

# wait until the driver/GSP is up (GSP boot clears DIS_G2 on the GPU side)
for _ in $(seq 1 120); do
    nvidia-smi -q >/dev/null 2>&1 && break
    sleep 2
done
nvidia-smi -q >/dev/null 2>&1 || { echo "nvidia-smi not ready"; exit 0; }

mapfile -t GPUS < <(list_gpus)
[[ ${#GPUS[@]} -gt 0 ]] || { echo "no CMP 170HX found"; exit 0; }
echo "cards: ${#GPUS[@]} (${GPUS[*]})"

for BDF in "${GPUS[@]}"; do
    GPU_PATH="/sys/bus/pci/devices/0000:${BDF}"
    [[ -e "${GPU_PATH}" ]] || { echo "skip 0000:${BDF} (not present)"; continue; }
    RP="$(basename "$(dirname "$(readlink -f "${GPU_PATH}")")")"
    [[ -e "/sys/bus/pci/devices/${RP}/config" ]] || { echo "skip 0000:${BDF} (no root port)"; continue; }

    # target link speed = 5 GT/s (Gen2) on both ends
    setpci -s "0000:${BDF}" CAP_EXP+0x30.w=0x0002 2>/dev/null || true
    setpci -s "${RP}"       CAP_EXP+0x30.w=0x0002 2>/dev/null || true
    # trigger retrain: GPU end first, then the root port (the step the driver omits)
    setpci -s "0000:${BDF}" CAP_EXP+0x10.w=0x0020 2>/dev/null || true
    setpci -s "${RP}"       CAP_EXP+0x10.w=0x0020 2>/dev/null || true
    sleep 2

    sta="$(setpci -s "0000:${BDF}" CAP_EXP+0x12.w 2>/dev/null || echo '?')"
    echo "0000:${BDF} root port ${RP}: link status = ${sta} (expect ...2 for 5GT/s)"
done

# summarize
nvidia-smi --query-gpu=pci.bus_id,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader 2>/dev/null
exit 0
