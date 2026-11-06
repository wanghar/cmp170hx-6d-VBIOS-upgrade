#!/bin/bash
# CMP 170HX: after the driver has cleared the GPU-side "disable Gen2" bit,
# retrain the *root port* as well. The driver's own retrain only touches the
# GPU end, which leaves the link trained down at 2.5 GT/s.
set -uo pipefail

GPU=""
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')"
    GPU="${GPU#00000000:}"
fi
[[ -n "${GPU}" ]] || GPU="$(lspci -D -d 10de:20c2: 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^0000://')"
[[ -n "${GPU}" ]] || GPU="$(lspci -D -d 10de:2082: 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^0000://')"
[[ -n "${GPU}" ]] || { echo "no CMP 170HX found"; exit 0; }

GPU_PATH="/sys/bus/pci/devices/0000:${GPU}"
[ -e "${GPU_PATH}" ] || { echo "0000:${GPU} not present"; exit 0; }

# wait until the driver/GSP is up (GSP boot clears DIS_G2 on the GPU side)
for _ in $(seq 1 120); do
    nvidia-smi -q >/dev/null 2>&1 && break
    sleep 2
done
nvidia-smi -q >/dev/null 2>&1 || { echo "nvidia-smi not ready"; exit 0; }

RP="$(basename "$(dirname "$(readlink -f "${GPU_PATH}")")")"
echo "endpoint 0000:${GPU} root port ${RP}"

# target link speed = 5 GT/s (Gen2) on both ends
setpci -s "0000:${GPU}" CAP_EXP+0x30.w=0x0002
setpci -s "${RP}"       CAP_EXP+0x30.w=0x0002
# trigger retrain: GPU end first, then the root port (the step the driver omits)
setpci -s "0000:${GPU}" CAP_EXP+0x10.w=0x0020
setpci -s "${RP}"       CAP_EXP+0x10.w=0x0020
sleep 2

sta="$(setpci -s "0000:${GPU}" CAP_EXP+0x12.w)"
echo "link status register = ${sta}  (expect ...2 for 5GT/s)"
if [ "$(nvidia-smi --query-gpu=pcie.link.gen.current --format=csv,noheader 2>/dev/null | tr -d ' ')" = "2" ]; then
    echo "Gen2 link active"
else
    echo "still not Gen2"
fi
exit 0
