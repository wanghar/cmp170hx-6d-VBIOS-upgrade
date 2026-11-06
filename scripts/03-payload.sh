#!/bin/bash
# Build (and optionally install) the VBIOS-override payload from a 6D ROM dump.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ROM="${1:-}"
INSTALL=0
shift || true
for a in "$@"; do
    case "${a}" in
        --install) INSTALL=1 ;;
        *) die "unknown option: ${a}" ;;
    esac
done
[[ -n "${ROM}" ]] || die "usage: $0 /path/to/268495.rom [--install]"

mkdir -p "${WORK_DIR}"
OUT="${WORK_DIR}/payload-300w.bin"
python3 "$(dirname "$0")/03-make-payload.py" "${ROM}" -o "${OUT}" \
    --expect-md5 "${EXPECT_MD5:-a58aae86e72b13d50603c15653350664}"

if [[ ${INSTALL} -eq 1 ]]; then
    need_root
    FW="$(fw_dir)"
    install -d "${FW}"
    install -m 644 "${OUT}" "${FW}/vbios.bin"
    ok "installed $(stat -c %s "${OUT}") bytes -> ${FW}/vbios.bin"
    echo "next: sudo bash $(dirname "$0")/04-install.sh"
else
    log "payload built at ${OUT}; add --install to copy it to $(fw_dir)"
fi
