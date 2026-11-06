#!/bin/bash
# Set/clear the HBM FBPA PLL NDIV registry key (takes effect at next boot).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root

VAL="${1:-}"
[[ -f "${CONF}" ]] || die "missing ${CONF} - run scripts/04-install.sh first"

case "${VAL}" in
    --off|"")
        if grep -q "RmHbmPllNdiv" "${CONF}"; then
            sed -i -E 's/;RmHbmPllNdiv=[0-9]+//' "${CONF}"
            ok "RmHbmPllNdiv removed (memory returns to the trained clock)"
        else
            warn "RmHbmPllNdiv already absent"
        fi
        ;;
    *)
        [[ "${VAL}" =~ ^[0-9]+$ ]] || die "NDIV must be an integer (30..80)"
        (( VAL >= 30 && VAL <= 80 )) || die "NDIV out of range (30..80)"
        if grep -q "RmHbmPllNdiv" "${CONF}"; then
            sed -i -E "s/RmHbmPllNdiv=[0-9]+/RmHbmPllNdiv=${VAL}/" "${CONF}"
        else
            sed -i -E "s/(RmLinuxVbiosOverrideSize=[0-9]+)\"/\1;RmHbmPllNdiv=${VAL}\"/" "${CONF}"
            grep -q "RmHbmPllNdiv" "${CONF}" || die "could not add key; edit ${CONF} manually"
        fi
        ok "RmHbmPllNdiv=${VAL} (~$((VAL*27)) MHz)"
        ;;
esac
cat "${CONF}"
echo
log "takes effect after: sudo reboot"
