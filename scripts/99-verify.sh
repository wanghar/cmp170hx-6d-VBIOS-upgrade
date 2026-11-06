#!/bin/bash
# Post-reboot verification. Read-only; runs a load test only when asked.
#   --bench            run the bandwidth/compute benchmark if available
#   --stress SECONDS   run a data-integrity stress test (needs python3 + torch)
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
q() { grep -q "$1" <<< "${D}"; }
sec() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

sec "A. identity"
nvidia-smi --query-gpu=name,driver_version,vbios_version,memory.total,power.limit,power.max_limit,clocks.max.sm,clocks.current.memory --format=csv
VB="$(nvidia-smi --query-gpu=vbios_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')"
MEM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')"
SM_MAX="$(nvidia-smi --query-gpu=clocks.max.sm --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')"
PMX="$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' | cut -d. -f1)"
[[ "${VB}" == *"6D"* ]] && ok "VBIOS 6D accepted (${VB})" || warn "VBIOS is ${VB} (override not accepted?)"
(( MEM >= 60000 )) && ok "framebuffer unlocked (${MEM} MiB)" || warn "framebuffer ${MEM} MiB (unlock not applied?)"
(( SM_MAX >= 1600 )) && ok "SM clock unlocked (max ${SM_MAX} MHz)" || warn "max SM ${SM_MAX} MHz"
(( PMX >= 290 )) && ok "power max limit ${PMX} W" || warn "power max ${PMX} W"

sec "B. override staging"
D=""
if (( AS_ROOT )); then D="$(dmesg 2>/dev/null)"; else D="$(sudo -n dmesg 2>/dev/null || true)"; fi
if q "vbios_override: GPU .* staged for GSP"; then
    echo "${D}" | grep "vbios_override" | tail -1 | sed 's/^/  /'
    ok "override staged (host side)"
else
    warn "no vbios_override staging line in dmesg"
fi

sec "C. HBM clock"
if q "HBMPLL_OC: post-GSP POST"; then
    echo "${D}" | grep "HBMPLL_OC" | tail -3 | sed 's/^/  /'
    q "lock=1" && ok "PLL locked (lock=1)" || warn "PLL not locked (lock=0 / missing)"
else
    warn "no post-GSP HBMPLL_OC line (memory clock not raised)"
fi

sec "D. module source"
modinfo -F filename nvidia 2>/dev/null | sed 's/^/  /'
modinfo -F filename nvidia 2>/dev/null | grep -q "updates/cmpunlocker" && ok "custom module in use" || warn "stock module in use"

sec "E. ECC / Xid"
if (( AS_ROOT )); then
    nvidia-smi -q -d ECC 2>/dev/null | grep -E "DRAM (Correctable|Uncorrectable)" | head -4 | sed 's/^/  /'
    nvidia-smi -q -d ECC 2>/dev/null | grep -qE "DRAM (Correctable|Uncorrectable)\s*:\s*[1-9]" && warn "DRAM ECC errors" || ok "no DRAM ECC errors"
    q "Xid" && warn "Xid entries in dmesg" || ok "no Xid"
fi

sec "F. PCIe"
nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv 2>/dev/null

sec "G. power / temperature"
nvidia-smi --query-gpu=power.draw,power.limit,temperature.gpu --format=csv 2>/dev/null

if (( BENCH )); then
    sec "H. benchmark"
    BIN="${BENCH_BIN:-$(command -v nvidia_bench 2>/dev/null || true)}"
    if [[ -n "${BIN}" ]]; then "${BIN}"; else warn "no nvidia_bench (set BENCH_BIN=/path)"; fi
fi

if (( STRESS > 0 )); then
    sec "I. stability ${STRESS}s"
    PY=""
    for c in python3 /opt/sglang-venv/bin/python3; do
        command -v "${c}" >/dev/null 2>&1 && { "${c}" -c "import torch" >/dev/null 2>&1 && PY="${c}" && break; }
    done
    [[ -n "${PY}" ]] || die "python3 + torch required for --stress"
    TMP="$(mktemp /tmp/cmp-stress-XXXX.py)"
    cat > "${TMP}" <<'PYEOF'
import sys, time, torch
torch.cuda.init()
secs = int(sys.argv[1]); n = 8192
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
print(f"iters={it} mismatches={bad}")
print(f"free/total GiB = {[round(x/(1<<30),1) for x in torch.cuda.mem_get_info()]}")
sys.exit(1 if bad else 0)
PYEOF
    "${PY}" "${TMP}" "${STRESS}" && ok "stress test clean" || warn "stress test reported mismatches"
    rm -f "${TMP}"
    if (( AS_ROOT )); then
        nvidia-smi -q -d ECC 2>/dev/null | grep -E "DRAM (Correctable|Uncorrectable)" | tail -2 | sed 's/^/  /'
        dmesg | grep -ci "Xid" | sed 's/^/  Xid count: /'
    fi
fi

echo
ok "verification finished"
