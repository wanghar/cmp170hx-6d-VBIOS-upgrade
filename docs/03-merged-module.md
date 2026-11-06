# 03 — 构建合并模块（解锁 + VBIOS 覆盖 + HBM 时钟）

目标产物：一个 `nvidia.ko`，同时包含

1. cmpunlocker 的 14 个解锁补丁（显存几何、SM 频率、ECC、Gen2…）
2. nvidia-linux-vbios-vix-loader 的 VBIOS 覆盖补丁（GSP 启动时用我们的镜像）
3. 本仓库的两个补丁：单链 legacy 镜像解析放宽 + FBPA PLL NDIV 改写（HBM 时钟）

## 1. 取上游源码与补丁

```bash
cd <repo>/work

# 上游解锁仓库（615.71.09 支持）
git clone https://github.com/amoghmunikote/cmpunlocker.git cmpunlocker

# 上游 VBIOS 覆盖仓库（615.x）
git clone https://github.com/Panchovix/nvidia-linux-vbios-vix-loader.git vix-loader
cd vix-loader && git checkout 7bf011e3a6100fd6b470917256f73cc18bda0586 && cd ..

# NVIDIA open 模块源码（与已装驱动版本严格一致）
curl -L --fail -o ogkm-615.71.09.tar.gz \
  https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/615.71.09.tar.gz
tar -xzf ogkm-615.71.09.tar.gz
mv open-gpu-kernel-modules-615.71.09 open-gpu-kernel-modules-615.71.09
```

## 2. 打 cmpunlocker 补丁

`cmpunlocker/driver/build.sh` 会自动下载源码、按顺序打 14 个补丁并编译安装。
我们只需要它的**补丁后的源码树**；也可以手工按 `build.sh` 里的 `PATCH_ORDER` 顺序
`patch -p1`：

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

手工应用：

```bash
cd open-gpu-kernel-modules-615.71.09
for p in sec2-postbl-plm-ss-cfg booter-verify late-pma bar0-pramin-clamp \
         ce-scrub-workarounds persistent-sw-state pcie-gen2 pcie-gen2-probe-retrain \
         name-string bar1-resize-unlock cmp-sku-mask ecc-enable ecc-fbpa-static ecc-reporting; do
  patch -p1 < ../cmpunlocker/driver/patches/$p.patch
done
```

> 内存几何：615 分支的 `cmp-sku-mask` 补丁在**运行时按 device-id**决定几何
> （`SEC2_POSTBL_TIMING_CMP_170HX_*` 标记），8 GB 卡 → 64 GB。若你用的版本需要
> 构建期写死，用 `cmpunlocker/driver/build.sh` 并设 `CMPUNLOCKER_CARD_PROFILE=8gb`。

## 3. 叠加 vix-loader 覆盖层

```bash
cd <repo>/work
./vix-loader/nvbios driver prepare \
    --source open-gpu-kernel-modules-615.71.09 \
    --destination merged --json
cd merged
./../vix-loader/nvbios driver apply .
```

`prepare` 会复制源码树并生成补丁清单，`apply` 把补丁真正写进去。
等价的手工方式：`patch -p1 < vix-loader/patches/615-vbios-override-per-gpu.patch`
和 `patch -p1 < vix-loader/patches/per-device-binary-loader-backport.patch`。

## 4. 叠加本仓库两个补丁

```bash
cd <repo>/work/merged
patch -p1 < <repo>/patches/0001-vix-loader-accept-first-legacy-image.patch
patch -p1 < <repo>/patches/0002-hbm-pll-ndiv-overclock.patch
```

- **0001**：vix-loader 的解析器原本要求镜像里**恰好一个**合法 legacy 镜像；
  放宽为接受**第一个**（双 bank ROM 在 +0x60000 有镜像副本）。只影响 host 侧暂存校验。
- **0002**：
  - `plmTable` 增加三个 FBPA PLL PLM（`0x009a3c7c/80/84` ← `0xffffffff`），打开 PLL 写权限
  - SEC2 阶段（pre-GSP）：NDIV 改写 + 自刷新 + DDLL 触发
  - GSP 启动后（post-GSP）：多播 COEFF `0x0098BC98` + PRI fence `0x001211FC` + 轮询锁定

## 5. 编译

```bash
cd <repo>/work/merged
make -j$(nproc) modules SYSSRC=/usr/src/linux-headers-$(uname -r)
```

产物：`kernel-open/nvidia.ko`、`nvidia-modeset.ko`、`nvidia-uvm.ko`、
`nvidia-drm.ko`、`nvidia-peermem.ko`。

## 6. 校验补丁确实生效

```bash
grep -c "HBMPLL_OC" kernel-open/../src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c   # >= 4
grep -c "RmLinuxVbiosOverride" src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c        # >= 1
nm -C kernel-open/nvidia.ko | grep -c kgspVbiosOverride                          # >= 1
```
