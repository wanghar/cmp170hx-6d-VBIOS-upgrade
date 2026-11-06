#!/bin/bash
# Build the merged module: cmpunlocker unlock + vix-loader VBIOS override + local patches.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# --- 1. NVIDIA open kernel module source (must match the installed driver) ---
INSTALLED="$(driver_version)"
if [[ "${INSTALLED}" != "${OGKM_VERSION}" ]]; then
    warn "installed driver is ${INSTALLED}, building against ${OGKM_VERSION}"
    warn "set OGKM_VERSION=${INSTALLED} if you want to match the installed driver exactly"
fi
if [[ ! -d "${SRC_DIR}" ]]; then
    log "downloading open-gpu-kernel-modules ${OGKM_VERSION}"
    curl -L --fail -o "ogkm-${OGKM_VERSION}.tar.gz" \
        "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${OGKM_VERSION}.tar.gz"
    tar -xzf "ogkm-${OGKM_VERSION}.tar.gz"
    [[ -d "${SRC_DIR}" ]] || die "extracted tree not found: ${SRC_DIR}"
    ok "sources: ${SRC_DIR}"
else
    ok "reusing sources: ${SRC_DIR}"
fi

# --- 2. cmpunlocker (unlock patches) ---
if [[ ! -d "${CMPUNLOCKER_DIR}" ]]; then
    log "cloning cmpunlocker"
    git clone https://github.com/amoghmunikote/cmpunlocker.git "${CMPUNLOCKER_DIR}"
    git -C "${CMPUNLOCKER_DIR}" checkout "${CMPUNLOCKER_COMMIT}" || \
        warn "commit ${CMPUNLOCKER_COMMIT} not found, using HEAD"
fi

# --- 3. apply unlock patches (in upstream PATCH_ORDER) ---
GSP_C="${SRC_DIR}/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
if grep -q "SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID" "${GSP_C}" 2>/dev/null; then
    ok "unlock patches already applied"
else
    log "applying cmpunlocker patches"
    cd "${SRC_DIR}"
    for p in sec2-postbl-plm-ss-cfg booter-verify late-pma bar0-pramin-clamp \
             ce-scrub-workarounds persistent-sw-state pcie-gen2 pcie-gen2-probe-retrain \
             name-string bar1-resize-unlock cmp-sku-mask ecc-enable ecc-fbpa-static ecc-reporting; do
        [[ -f "${CMPUNLOCKER_DIR}/driver/patches/${p}.patch" ]] || die "missing patch ${p}.patch"
        patch -p1 --forward < "${CMPUNLOCKER_DIR}/driver/patches/${p}.patch" >/dev/null
        echo "  ${p}"
    done
    ok "unlock patches applied"
fi

# --- 4. vix-loader (in-memory VBIOS override) ---
if [[ ! -d "${VIX_DIR}" ]]; then
    log "cloning nvidia-linux-vbios-vix-loader"
    git clone https://github.com/Panchovix/nvidia-linux-vbios-vix-loader.git "${VIX_DIR}"
    git -C "${VIX_DIR}" checkout "${VIX_COMMIT}" || \
        warn "commit ${VIX_COMMIT} not found, using HEAD"
fi

# --- 5. merged tree = unlock tree + vix override layer ---
if [[ ! -d "${MERGED_DIR}" ]]; then
    log "preparing merged tree with vix-loader"
    if "${VIX_DIR}/nvbios" driver prepare --source "${SRC_DIR}" --destination "${MERGED_DIR}" >/dev/null 2>&1; then
        ( cd "${MERGED_DIR}" && "${VIX_DIR}/nvbios" driver apply . >/dev/null 2>&1 ) || \
            die "nvbios driver apply failed - see docs/03-merged-module.md for the manual patch route"
        ok "vix override layer applied via nvbios"
    else
        warn "nvbios prepare failed; applying vix patch files manually"
        cp -a "${SRC_DIR}" "${MERGED_DIR}"
        ( cd "${MERGED_DIR}" \
          && patch -p1 --forward < "${VIX_DIR}/patches/615-vbios-override-per-gpu.patch" >/dev/null \
          && patch -p1 --forward < "${VIX_DIR}/patches/per-device-binary-loader-backport.patch" >/dev/null )
        ok "vix override layer applied manually"
    fi
    [[ -f "${MERGED_DIR}/src/nvidia/inc/kernel/gpu/gsp/vbios_override_image.h" ]] || \
        die "override header missing after patching"
else
    ok "reusing merged tree: ${MERGED_DIR}"
fi

# --- 6. local patches: legacy-image parser relaxation + HBM PLL NDIV ---
GSP_M="${MERGED_DIR}/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
if grep -q "HBMPLL_OC" "${GSP_M}" 2>/dev/null; then
    ok "local patches already applied"
else
    log "applying local patches"
    ( cd "${MERGED_DIR}" \
      && patch -p1 --forward < "${REPO_ROOT}/patches/0001-vix-loader-accept-first-legacy-image.patch" \
      && patch -p1 --forward < "${REPO_ROOT}/patches/0002-hbm-pll-ndiv-overclock.patch" )
    ok "local patches applied"
    grep -q "HBMPLL_OC" "${GSP_M}" || die "HBM PLL patch did not apply"
fi

# --- 7. build ---
log "building modules against ${KSRC}"
cd "${MERGED_DIR}"
make -j"$(nproc)" modules SYSSRC="${KSRC}"
[[ -f "${MERGED_DIR}/kernel-open/nvidia.ko" ]] || die "build failed: nvidia.ko missing"
ok "built: ${MERGED_DIR}/kernel-open/nvidia.ko ($(stat -c %s "${MERGED_DIR}/kernel-open/nvidia.ko") bytes)"
