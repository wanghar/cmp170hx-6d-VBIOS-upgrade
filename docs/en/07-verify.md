# 07 — Verification Checklist

**English** | [简体中文](../zh-CN/07-verify.md)

Check in order after reboot. `sudo bash scripts/99-verify.sh` runs all of them at once and prints the results.

## A. Basic Identity

```bash
nvidia-smi --query-gpu=name,driver_version,vbios_version,memory.total,power.limit,power.max_limit,clocks.max.sm,clocks.current.memory --format=csv
```

Expected:

| Field | Expected value |
|---|---|
| `driver_version` | 615.71.09 |
| `vbios_version` | **92.00.6D.00.0A** |
| `memory.total` | 65536 MiB (8 GB SKU) / 131072 MiB (10 GB SKU) |
| `power.limit` | **250 W** (default, meeting the "does not automatically go to 300W at boot" requirement) |
| `power.max_limit` | **300 W** |
| `clocks.max.sm` | **1695 MHz** |
| `clocks.current.memory` | **1728 MHz** (NDIV=64) or 1890 (NDIV=70) |

## B. Override Image Accepted by the Firmware

```bash
sudo dmesg | grep -i "vbios_override"
```

Expected one line:

```
NVRM: vbios_override: GPU 0000:02:00 selected: 369152 bytes from offset 0x5e00 staged for GSP
```

If VBIOS is still `92.00.67.00.01`: the firmware fell back; see the troubleshooting table in `04-vbios-payload.md`.

## C. HBM Clock Actually Takes Effect

```bash
sudo dmesg | grep HBMPLL_OC | tail -4
```

Expected:

```
HBMPLL_OC: start NDIV 54->64 (1458->1728 MHz) ...
HBMPLL_OC: post-GSP PRE: COEFF=0x...401(NDIV=64) ... 
HBMPLL_OC: post-GSP POST: COEFF=0x...401(NDIV=64) CFG=0x8000092d lock=1 iter=...
```

`lock=1` is the hard requirement; a missing line or `lock=0` means the PLL is not locked (the frequency does not actually take effect).

## D. Bandwidth and Compute

```bash
sudo bash scripts/99-verify.sh --bench
```

Expected (NDIV=64, 1728 MHz):

| Item | Expected |
|---|---|
| Theoretical BW | 1769 GB/s |
| Global Read | ~1670 GB/s |
| FP32 | 13.9 TFLOPS |
| BF16 Tensor | ~210 TFLOPS |

(NDIV=70/1890: Theoretical 1935, Read 1825, D2D 1756 — measured on this machine)

## E. Stability

```bash
sudo bash scripts/99-verify.sh --stress 120
```

Expected: `mismatches=0`, ECC 0/0, Xid 0.

## F. PCIe

```bash
nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv
sudo lspci -vv -s 02:00.0 | grep LnkSta
```

Expected: Gen2 x4 (if the slot is x4). If it shows Gen1, retrain the root port per `06-pcie-gen2.md`.

## G. Power/Temperature

```bash
nvidia-smi -q -d POWER,TEMPERATURE | grep -E "Power Limit|Power Draw|GPU Current Temp|Slowdown Temp|Shutdown Temp"
```

At the 250 W cap, sustained load is about 230–250 W and below 85 °C is normal; at the 300 W cap the measured peak is 323 W / 76 °C.

## H. Quick Regression Self-Check

| Check | Command | Pass criteria |
|---|---|---|
| Module comes from updates | `modinfo -F filename nvidia` | `/lib/modules/$KVER/updates/cmpunlocker/nvidia.ko` |
| VRAM geometry | `nvidia-smi --query-gpu=memory.total` | 65536 MiB |
| ECC enabled | `nvidia-smi -q -d ECC \| grep -i "enabled"` | Enabled |
| Persistence SW state | `nvidia-smi --query-gpu=persistence_mode` | Enabled |
