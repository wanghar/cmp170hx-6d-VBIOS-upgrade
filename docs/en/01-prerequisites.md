# 01 — Prerequisites and Baseline

**English** | [简体中文](../zh-CN/01-prerequisites.md)

## Hardware

- NVIDIA CMP 170HX (GA100)
  - 8 GB SKU: PCI `10de:20c2`, subsystem `10de:1585`
  - 10 GB SKU: PCI `10de:2082`
- Motherboard PCIe slot: this machine has **electrical x4** (Z440 slot 2), capped at ~1.7 GB/s under Gen2;
  higher bandwidth requires an x8/x16 slot.
- The card must work properly and be detected by `nvidia-smi` (including the stock 8/10 GB mode).

## System

- x86_64 Linux with matching kernel headers
- Secure Boot **disabled** (or self-signed module signing configured)
- Disk: source tree + build artifacts ~8–10 GB; recommended on an SSD

```bash
uname -r
ls /usr/src/linux-headers-$(uname -r)     # must exist
mokutil --sb-state 2>/dev/null || true     # should be disabled
```

## Packages (Debian/Ubuntu)

```bash
sudo apt-get update
sudo apt-get install -y build-essential git curl python3 python3-yaml patch \
                        linux-headers-$(uname -r)
```

## Check the GPU

```bash
lspci -nn | grep -i nvidia
# 02:00.0 VGA compatible controller [0300]: NVIDIA Corporation ... [10de:20c2]

nvidia-smi --query-gpu=name,pci.bus_id,vbios_version,memory.total,power.limit,power.max_limit,clocks.max.sm --format=csv
```

Record these baseline values to compare after the upgrade:

| Field | Stock (8 GB SKU with 64 GB unlocked) |
|---|---|
| `vbios_version` | `92.00.67.00.01` |
| `memory.total` | 8192 MiB before unlock / 65536 MiB after unlock |
| `power.limit` / `power.max_limit` | 250 W / 250 W |
| `clocks.max.sm` | 1410 MHz |

## Obtain the 6D VBIOS

- Source: TechPowerUp VBIOS Database (`92.00.6D.00.0A`), or a dump from another native 6D card
- The filename is usually `268495.rom`, size **1044480 bytes**
- Verify: `md5sum 268495.rom` should be `a58aae86e72b13d50603c15653350664`

> This repository does not ship the ROM (copyright reasons). Obtain it yourself and check the md5.

## Directory Conventions

The scripts below assume:

```
<repo>/work/                              # binary and source workspace
<repo>/work/open-gpu-kernel-modules-615.71.09/   # upstream source (after unlock patches)
<repo>/work/merged/                       # + vix-loader overlay + this repo's patches (final build)
<repo>/work/cmpunlocker/                  # upstream unlock repository
<repo>/work/vix-loader/                   # upstream overlay repository
```

Use the environment variable `CMP170HX_WORK=/path` to relocate the workspace.
