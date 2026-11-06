# 07 — 验证清单

[English](../en/07-verify.md) | **简体中文**

重启后按顺序检查。`sudo bash scripts/99-verify.sh` 会一次性跑完并打印结果。

## A. 基础身份

```bash
nvidia-smi --query-gpu=name,driver_version,vbios_version,memory.total,power.limit,power.max_limit,clocks.max.sm,clocks.current.memory --format=csv
```

预期：

| 字段 | 预期值 |
|---|---|
| `driver_version` | 615.71.09 |
| `vbios_version` | **92.00.6D.00.0A** |
| `memory.total` | 65536 MiB（8 GB SKU）/ 131072 MiB（10 GB SKU） |
| `power.limit` | **250 W**（默认，符合“开机不自动上 300W”的要求） |
| `power.max_limit` | **300 W** |
| `clocks.max.sm` | **1695 MHz** |
| `clocks.current.memory` | **1728 MHz**（NDIV=64）或 1890（NDIV=70） |

## B. 覆盖镜像已被固件接受

```bash
sudo dmesg | grep -i "vbios_override"
```

预期有一行：

```
NVRM: vbios_override: GPU 0000:02:00 selected: 369152 bytes from offset 0x5e00 staged for GSP
```

若 VBIOS 仍是 `92.00.67.00.01`：说明固件回落了，见 `04-vbios-payload.md` 排查表。

## C. HBM 时钟真正生效

```bash
sudo dmesg | grep HBMPLL_OC | tail -4
```

预期：

```
HBMPLL_OC: start NDIV 54->64 (1458->1728 MHz) ...
HBMPLL_OC: post-GSP PRE: COEFF=0x...401(NDIV=64) ... 
HBMPLL_OC: post-GSP POST: COEFF=0x...401(NDIV=64) CFG=0x8000092d lock=1 iter=...
```

`lock=1` 是硬指标；没有这一行或 `lock=0` 说明 PLL 未锁定（频率不会真正生效）。

## D. 带宽与算力

```bash
sudo bash scripts/99-verify.sh --bench
```

预期（NDIV=64，1728 MHz）：

| 项 | 预期 |
|---|---|
| Theoretical BW | 1769 GB/s |
| Global Read | ~1670 GB/s |
| FP32 | 13.9 TFLOPS |
| BF16 Tensor | ~210 TFLOPS |

（NDIV=70/1890：Theoretical 1935、Read 1825、D2D 1756 —— 本机实测值）

## E. 稳定性

```bash
sudo bash scripts/99-verify.sh --stress 120
```

预期：`mismatches=0`、ECC 0/0、Xid 0。

## F. PCIe

```bash
nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv
sudo lspci -vv -s 02:00.0 | grep LnkSta
```

预期：Gen2 x4（若插槽为 x4）。若显示 Gen1，按 `06-pcie-gen2.md` 重训根端口。

## G. 功耗/温度

```bash
nvidia-smi -q -d POWER,TEMPERATURE | grep -E "Power Limit|Power Draw|GPU Current Temp|Slowdown Temp|Shutdown Temp"
```

250 W 档持续负载约 230–250 W、<85 °C 正常；300 W 档实测峰值 323 W / 76 °C。

## H. 快速回归自检

| 检查 | 命令 | 通过标准 |
|---|---|---|
| 模块来自 updates | `modinfo -F filename nvidia` | `/lib/modules/$KVER/updates/cmpunlocker/nvidia.ko` |
| 显存几何 | `nvidia-smi --query-gpu=memory.total` | 65536 MiB |
| ECC 开启 | `nvidia-smi -q -d ECC \| grep -i "enabled"` | Enabled |
| 持久化 SW state | `nvidia-smi --query-gpu=persistence_mode` | Enabled |
