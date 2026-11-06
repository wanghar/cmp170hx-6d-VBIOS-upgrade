#!/bin/bash
# Post-reboot verification. Read-only; runs a load test only when asked.
#   --bench            run the bandwidth/compute benchmark if available
#   --stress SECONDS   run a data-integrity stress test on every GPU (needs python3 + torch)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

BENCH=0
STRESS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bench)  BENCH=1; shift ;;
        --stress) STRESS="${2:-60}"; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done

AS_ROOT=0; [[ "${EUID}" -eq 0 ]] && AS_ROOT=1
D=""
if (( AS_ROOT )); then D="$(dmesg 2>/dev/null)"; else D="$(sudo -n dmesg 2>/dev/null || true)"; fi
q() { grep -q "$1" <<< "${D}"; }
sec() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

mapfile -t BDFS < <(gpu_bdfs)
NGPU=${#BDFS[@]}
if (( NGPU == 0 )); then warn "no GPU detected by nvidia-smi"; exit 1; fi

sec "A. identity (${NGPU} card(s))"
nvidia-smi --query-gpu=name,driver_version,vbios_version,memory.total,power.limit,power.max_limit,clocks.max.sm,clocks.current.memory --format=csv
for i in $(seq 0 $((NGPU-1))); do
    g() { nvidia-smi -i "$i" --query-gpu="$1" --format=csv,noheader,nounits 2>/dev/null | tr -d ' '; }
    VB="$(g vbios_version)"; MEM="$(g memory.total)"; SM_MAX="$(g clocks.max.sm)"
    PMX="$(g power.max_limit | cut -d. -f1)"; MMEM="$(g clocks.current.memory | cut -d. -f1)"
    pfx="GPU${i} (${BDFS[$i]})"
    [[ "${VB}" == *"6D"* ]] && ok "${pfx}: VBIOS 6D accepted (${VB})" || warn "${pfx}: VBIOS is ${VB} (override not accepted?)"
    (( MEM >= 60000 )) && ok "${pfx}: framebuffer unlocked (${MEM} MiB)" || warn "${pfx}: framebuffer ${MEM} MiB (unlock not applied?)"
    (( SM_MAX >= 1600 )) && ok "${pfx}: SM clock unlocked (max ${SM_MAX} MHz)" || warn "${pfx}: max SM ${SM_MAX} MHz"
    (( PMX >= 290 )) && ok "${pfx}: power max limit ${PMX} W" || warn "${pfx}: power max ${PMX} W"
    (( MMEM >= 1700 )) && ok "${pfx}: memory clock ${MMEM} MHz (raised)" || warn "${pfx}: memory clock ${MMEM} MHz (trained value or NDIV not applied)"
done

sec "B. override staging"
if q "vbios_override: GPU .* staged for GSP"; then
    echo "${D}" | grep "vbios_override" | sed 's/^/  /'
    ok "override staged (host side)"
else
    warn "no vbios_override staging line in dmesg"
fi

sec "C. HBM clock"
if q "HBMPLL_OC: post-GSP POST"; then
    echo "${D}" | grep "HBMPLL_OC" | tail -$((NGPU*2)) | sed 's/^/  /'
    LOCKS=$(grep -c "lock=1" <<< "${D}")
    (( LOCKS >= NGPU )) && ok "PLL locked on ${LOCKS} of ${NGPU} card(s)" || warn "only ${LOCKS} lock=1 line(s) for ${NGPU} card(s)"
else
    warn "no post-GSP HBMPLL_OC line (memory clock not raised)"
fi

sec "D. module source"
modinfo -F filename nvidia 2>/dev/null | sed 's/^/  /'
modinfo -F filename nvidia 2>/dev/null | grep -q "updates/cmpunlocker" && ok "custom module in use" || warn "stock module in use"

sec "E. ECC / Xid"
if (( AS_ROOT )); then
    nvidia-smi -q -d ECC 2>/dev/null | grep -E "DRAM (Correctable|Uncorrectable)" | sed 's/^/  /'
    nvidia-smi -q -d ECC 2>/dev/null | grep -qE "DRAM (Correctable|Uncorrectable)\s*:\s*[1-9]" && warn "DRAM ECC errors present" || ok "no DRAM ECC errors"
    q "Xid" && warn "Xid entries in dmesg" || ok "no Xid"
fi

sec "F. PCIe"
nvidia-smi --query-gpu=pci.bus_id,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader 2>/dev/null | sed 's/^/  /'

sec "G. power / temperature"
nvidia-smi --query-gpu=pci.bus_id,power.draw,power.limit,temperature.gpu --format=csv,noheader 2>/dev/null | sed 's/^/  /'

if (( BENCH )); then
    sec "H. benchmark"
    BIN="${BENCH_BIN:-$(command -v nvidia_bench 2>/dev/null || true)}"
    if [[ -n "${BIN}" ]]; then "${BIN}"; else warn "no nvidia_bench (set BENCH_BIN=/path)"; fi
fi

if (( STRESS > 0 )); then
    sec "I. stability ${STRESS}s per GPU"
    PY=""
    for c in python3 /opt/sglang-venv/bin/python3; do
        command -v "${c}" >/dev/null 2>&1 && { "${c}" -c "import torch" >/dev/null 2>&1 && PY="${c}" && break; }
    done
    [[ -n "${PY}" ]] || die "python3 + torch required for --stress"
    TMP="$(mktemp /tmp/cmp-stress-XXXX.py)"
    cat > "${TMP}" <<'PYEOF'
import sys, time, torch
torch.cuda.init()
secs, dev = int(sys.argv[1]), int(sys.argv[2])
torch.cuda.set_device(dev)
n = 8192
a = torch.randn(n, n, dtype=torch.float16, device='cuda')
b = torch.randn(n, n, dtype=torch.float16, device='cuda')
ref = (a @ b).clone()
scratch = torch.empty(1 << 28, dtype=torch.float16, device='cuda')
t0 = time.time(); it = bad = 0
while time.time() - t0 < secs:
    if not torch.equal(a @ b, ref): bad += 1
    scratch.copy_(scratch)
    it += 1
torch.cuda.synchronize()
print(f"GPU{dev}: iters={it} mismatches={bad}")
sys.exit(1 if bad else 0)
PYEOF
    rc=0
    for i in $(seq 0 $((NGPU-1))); do
        "${PY}" "${TMP}" "${STRESS}" "${i}" || rc=1
    done
    rm -f "${TMP}"
    (( rc == 0 )) && ok "stress test clean on all cards" || warn "stress test reported mismatches"
    if (( AS_ROOT )); then
        nvidia-smi -q -d ECC 2>/dev/null | grep -E "DRAM (Correctable|Uncorrectable)" | tail -$((NGPU*2)) | sed 's/^/  /'
        grep -ci "Xid" <<< "${D}" | sed 's/^/  Xid count: /'
    fi
fi

echo
ok "verification finished (${NGPU} card(s))"
