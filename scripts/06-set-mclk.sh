#!/bin/bash
# Set/clear the HBM FBPA PLL NDIV registry key (takes effect at next boot).
# Works with any number of GPUs: the key is applied to every pci= scope.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root

VAL="${1:-}"
[[ -f "${CONF}" ]] || die "missing ${CONF} - run scripts/04-install.sh first"

case "${VAL}" in
    --off|"")
        VAL="off"
        ;;
    *)
        [[ "${VAL}" =~ ^[0-9]+$ ]] || die "NDIV must be an integer (30..80)"
        (( VAL >= 30 && VAL <= 80 )) || die "NDIV out of range (30..80)"
        ;;
esac

python3 - "${CONF}" "${VAL}" <<'PY'
import re, sys
path, val = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
out = []
touched = False
for line in lines:
    m = re.search(r'(options\s+nvidia\s+NVreg_RegistryDwordsPerDevice=")(.*)(".*)$', line)
    if not m:
        out.append(line)
        continue
    body = m.group(2)
    if body.count("RmHbmPllNdiv"):
        touched = True
    if val == "off":
        body = re.sub(r';RmHbmPllNdiv=\d+', '', body)
    elif "RmHbmPllNdiv" in body:
        body = re.sub(r'RmHbmPllNdiv=\d+', f'RmHbmPllNdiv={val}', body)
        touched = True
    else:
        segs = [s.rstrip(';') for s in body.split("pci=")[1:]]
        if not segs:
            raise SystemExit("no pci= scope found in NVreg_RegistryDwordsPerDevice")
        body = ";".join(f"pci={s};RmHbmPllNdiv={val}" for s in segs)
        touched = True
    out.append(m.group(1) + body + m.group(3))
open(path, "w").write("\n".join(out))
print(f"scopes updated: {touched}")
PY

if [[ "${VAL}" == "off" ]]; then
    ok "RmHbmPllNdiv removed from every GPU (memory returns to the trained clock)"
else
    ok "RmHbmPllNdiv=${VAL} (~$((VAL*27)) MHz) applied to every GPU"
fi
cat "${CONF}"
echo
log "takes effect after: sudo reboot"
