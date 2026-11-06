# 01 — 环境准备与基线

## 硬件

- NVIDIA CMP 170HX（GA100）
  - 8 GB SKU：PCI `10de:20c2`，subsystem `10de:1585`
  - 10 GB SKU：PCI `10de:2082`
- 主板 PCIe 槽位：本机为 **电气 x4**（Z440 slot 2），Gen2 下上限 ~1.7 GB/s；
  想要更高带宽需要 x8/x16 槽位。
- 显卡必须能正常工作、`nvidia-smi` 能识别（包括原厂 8/10 GB 模式）。

## 系统

- x86_64 Linux，内核带对应头文件
- Secure Boot **关闭**（或配置自签模块签名）
- 磁盘：源码树 + 编译产物约 8–10 GB；建议放在 SSD

```bash
uname -r
ls /usr/src/linux-headers-$(uname -r)     # 必须存在
mokutil --sb-state 2>/dev/null || true     # 应为 disabled
```

## 软件包（Debian/Ubuntu）

```bash
sudo apt-get update
sudo apt-get install -y build-essential git curl python3 python3-yaml patch \
                        linux-headers-$(uname -r)
```

## 检查 GPU

```bash
lspci -nn | grep -i nvidia
# 02:00.0 VGA compatible controller [0300]: NVIDIA Corporation ... [10de:20c2]

nvidia-smi --query-gpu=name,pci.bus_id,vbios_version,memory.total,power.limit,power.max_limit,clocks.max.sm --format=csv
```

记下这些基线值，升级后对比：

| 字段 | 原厂（8 GB SKU 已解锁 64 GB 时） |
|---|---|
| `vbios_version` | `92.00.67.00.01` |
| `memory.total` | 解锁前 8192 MiB / 解锁后 65536 MiB |
| `power.limit` / `power.max_limit` | 250 W / 250 W |
| `clocks.max.sm` | 1410 MHz |

## 获取 6D VBIOS

- 来源：TechPowerUp VBIOS Database（`92.00.6D.00.0A`），或从另一张原生 6D 卡 dump
- 文件名通常为 `268495.rom`，大小 **1044480 字节**
- 校验：`md5sum 268495.rom` 应为 `a58aae86e72b13d50603c15653350664`

> 本仓库不附带 ROM（版权原因）。请自行获取并核对 md5。

## 目录约定

后面脚本默认使用：

```
<repo>/work/                              # 二进制与源码工作区
<repo>/work/open-gpu-kernel-modules-615.71.09/   # 上游源码（unlock 补丁后）
<repo>/work/merged/                       # + vix-loader 覆盖 + 本仓库补丁（最终编译）
<repo>/work/cmpunlocker/                  # 上游解锁仓库
<repo>/work/vix-loader/                   # 上游覆盖仓库
```

可用环境变量 `CMP170HX_WORK=/path` 改写工作区位置。
