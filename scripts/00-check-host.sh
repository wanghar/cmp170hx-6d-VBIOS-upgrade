#!/bin/bash
# Non-destructive environment check.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

fail=0
chk() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "${name}"; else warn "${name} 缺失"; fail=1; fi; }

log "内核 $(uname -r)"
chk "内核头文件 ${KSRC}" test -d "${KSRC}"
chk "gcc" command -v gcc
chk "make" command -v make
chk "git" command -v git
chk "curl" command -v curl
chk "python3" command -v python3
chk "python3 yaml" python3 -c "import yaml"
chk "patch" command -v patch

if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
        warn "Secure Boot 已开启 —— 需要自签模块签名或关闭 Secure Boot"
        fail=1
    else
        ok "Secure Boot 关闭"
    fi
fi

if command -v nvidia-smi >/dev/null 2>&1; then
    ok "nvidia-smi 可用"
    nvidia-smi --query-gpu=name,driver_version,vbios_version,memory.total,power.limit,power.max_limit,clocks.max.sm --format=csv
    nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader | sed 's/^/  BDF: /'
else
    warn "nvidia-smi 不可用（先装 615.71.09 open 驱动）"
    fail=1
fi

echo
if [[ ${fail} -eq 0 ]]; then ok "环境检查通过"; else warn "有缺失项，先补齐再继续"; fi
exit ${fail}
