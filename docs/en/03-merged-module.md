# 03 — Build the Merged Module (Unlock + VBIOS Override + HBM Clock)

**English** | [简体中文](../zh-CN/03-merged-module.md)

Target artifact: a single `nvidia.ko` that contains

1. cmpunlocker's 14 unlock patches (memory geometry, SM clocks, ECC, Gen2…)
2. nvidia-linux-vbios-vix-loader's VBIOS override patch (uses our image at GSP boot)
3. Two patches from this repository: relaxed single-chain legacy image parsing + FBPA PLL NDIV rewrite (HBM clock)

## 1. Fetch Upstream Source and Patches

```bash
cd <repo>/work

# Upstream unlock repository (supports 615.71.09)
git clone https://github.com/amoghmunikote/cmpunlocker.git cmpunlocker

# Upstream VBIOS override repository (615.x)
git clone https://github.com/Panchovix/nvidia-linux-vbios-vix-loader.git vix-loader
cd vix-loader && git checkout 7bf011e3a6100fd6b470917256f73cc18bda0586 && cd ..

# NVIDIA open module source (must exactly match the installed driver version)
curl -L --fail -o ogkm-615.71.09.tar.gz \
  https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/615.71.09.tar.gz
tar -xzf ogkm-615.71.09.tar.gz
mv open-gpu-kernel-modules-615.71.09 open-gpu-kernel-modules-615.71.09
```

## 2. Apply the cmpunlocker Patches

`cmpunlocker/driver/build.sh` downloads the source, applies the 14 patches in order, and builds/installs.
We only need its **patched source tree**; you can also apply them manually with `patch -p1`
following the `PATCH_ORDER` sequence in `build.sh`:

```
sec2-postbl-plm-ss-cfg.patch
booter-verify.patch
late-pma.patch
bar0-pramin-clamp.patch
ce-scrub-workarounds.patch
persistent-sw-state.patch
pcie-gen2.patch
pcie-gen2-probe-retrain.patch
name-string.patch
bar1-resize-unlock.patch
cmp-sku-mask.patch
ecc-enable.patch
ecc-fbpa-static.patch
ecc-reporting.patch
```

Manual application:

```bash
cd open-gpu-kernel-modules-615.71.09
for p in sec2-postbl-plm-ss-cfg booter-verify late-pma bar0-pramin-clamp \
         ce-scrub-workarounds persistent-sw-state pcie-gen2 pcie-gen2-probe-retrain \
         name-string bar1-resize-unlock cmp-sku-mask ecc-enable ecc-fbpa-static ecc-reporting; do
  patch -p1 < ../cmpunlocker/driver/patches/$p.patch
done
```

> Memory geometry: the 615 branch's `cmp-sku-mask` patch decides geometry **at runtime by device-id**
> (`SEC2_POSTBL_TIMING_CMP_170HX_*` markers), 8 GB card → 64 GB. If the version you use needs it
> hard-coded at build time, use `cmpunlocker/driver/build.sh` with `CMPUNLOCKER_CARD_PROFILE=8gb`.

## 3. Layer the vix-loader Overlay

```bash
cd <repo>/work
./vix-loader/nvbios driver prepare \
    --source open-gpu-kernel-modules-615.71.09 \
    --destination merged --json
cd merged
./../vix-loader/nvbios driver apply .
```

`prepare` copies the source tree and generates a patch list; `apply` actually writes the patches in.
Equivalent manual approach: `patch -p1 < vix-loader/patches/615-vbios-override-per-gpu.patch`
and `patch -p1 < vix-loader/patches/per-device-binary-loader-backport.patch`.

## 4. Layer This Repository's Two Patches

```bash
cd <repo>/work/merged
patch -p1 < <repo>/patches/0001-vix-loader-accept-first-legacy-image.patch
patch -p1 < <repo>/patches/0002-hbm-pll-ndiv-overclock.patch
```

- **0001**: vix-loader's parser originally required **exactly one** valid legacy image in the payload;
  relaxed to accept the **first** one (dual-bank ROMs carry an image copy at +0x60000). Only affects the host-side staging check.
- **0002**:
  - `plmTable` gains three FBPA PLL PLM entries (`0x009a3c7c/80/84` ← `0xffffffff`), opening PLL write access
  - SEC2 stage (pre-GSP): NDIV rewrite + self-refresh + DDLL trigger
  - After GSP boot (post-GSP): multicast COEFF `0x0098BC98` + PRI fence `0x001211FC` + poll for lock

## 5. Build

```bash
cd <repo>/work/merged
make -j$(nproc) modules SYSSRC=/usr/src/linux-headers-$(uname -r)
```

Artifacts: `kernel-open/nvidia.ko`, `nvidia-modeset.ko`, `nvidia-uvm.ko`,
`nvidia-drm.ko`, `nvidia-peermem.ko`.

## 6. Confirm the Patches Are Actually in Effect

```bash
grep -c "HBMPLL_OC" kernel-open/../src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c   # >= 4
grep -c "RmLinuxVbiosOverride" src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c        # >= 1
nm -C kernel-open/nvidia.ko | grep -c kgspVbiosOverride                          # >= 1
```
