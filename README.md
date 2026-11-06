# CMP 170HX: 67 → 6D (300 W) upgrade, 64 GB unlock, HBM at 1728/1890 MHz — without flashing the EEPROM

**English** | [简体中文](README.zh-CN.md)

Upgrade an NVIDIA CMP 170HX (GA100) on Linux from the stock `92.00.67.00.01` (250 W) VBIOS
behaviour to the `92.00.6D.00.0A` (300 W cap) behaviour, keep the driver-side unlock, and raise
the HBM clock from 1458 MHz to 1728 MHz (the 6D stock clock) or higher — **without writing the
EEPROM and without nvflash**, with a staged rollback at every layer.

> 中文版见 [README.zh-CN.md](README.zh-CN.md)。

---

## 1. Measured results

Same machine, same card (8 GB SKU, `10de:20c2`), same benchmark at each stage
(`nvidia_bench`, 512 MiB buffers, 128 B stride, run from `scripts/99-verify.sh`):

| Item | Stock 67 (250 W) | This repo: 6D + NDIV=64 | This repo: 6D + NDIV=70 | Reference card: natively flashed 6D (1728) |
|---|---|---|---|---|
| VBIOS | 92.00.67.00.01 | 92.00.6D.00.0A | 92.00.6D.00.0A | 92.00.6D.00.0A |
| Framebuffer | 64 GB (after unlock) | 64 GB | 64 GB | 64 GB |
| Power limit | 250 W | 250 W default / 300 W max | 250 W default / 300 W max | 250 W default / 300 W max |
| SM clock cap | 1410 MHz | 1695 MHz | 1695 MHz | 1482 MHz (measured under load) |
| Memory clock | 1458 MHz | **1728 MHz** | **1890 MHz** | 1728 MHz |
| Theoretical BW | 1493 GB/s | 1769 GB/s | 1935 GB/s | 1769 GB/s |
| Global Read | 1377 GB/s | ≈1670 GB/s (expected) | **1825 GB/s** | 1675 GB/s |
| Global Write | 1359 GB/s | — | 1297 GB/s | 1285 GB/s |
| Global Copy | 1220 GB/s | — | **1623 GB/s** | 1447 GB/s |
| Global Triad | 1289 GB/s | — | **1740 GB/s** | 1582 GB/s |
| cudaMemcpy D2D | — | — | **1756 GB/s** | 1583 GB/s |
| Memory latency | — | — | **352.9 ns** | 364.8 ns |
| FP32 / BF16 | — | — | 13.92 / 210.91 TFLOPS | 13.78 / 208.79 TFLOPS |
| PCIe | Gen2 x4 (slot-limited) | Gen2 x4 | Gen2 x4 | Gen2 x4 |

Stability at NDIV=70: a repeated fp16 matmul compared bit-for-bit over **9499 iterations gave
0 mismatches**, DRAM ECC correctable/uncorrectable **0/0**, **Xid 0**, power 245–251 W,
temperature 59–63 °C.

---

## 2. How it works: three independent layers

1. **Driver unlock (cmpunlocker, 14 kernel patches)**
   Removes the firmware/OTP restrictions of the CMP 170HX: SM clock unlock, framebuffer geometry
   unlock (8 GB SKU → 64 GB, 10 GB SKU → 128 GB), ECC, PCIe Gen2, persistent SW state, etc.
   Purely driver-side; the VBIOS is untouched.

2. **In-memory VBIOS override (nvidia-linux-vbios-vix-loader)**
   Lets the GSP firmware boot from a VBIOS image we supply (the 6D one) instead of the EEPROM's 67,
   which brings the 300 W power table and the 1695 MHz SM clock table. The image lives in memory
   only; **the EEPROM is never written**.
   - The GSP firmware accepts only a **single-chain legacy image** (one `55AA` + `PCIR`, checksum 0)
     and stages at most **512 KiB** (anything larger silently falls back to the EEPROM VBIOS).
   - Hence the payload is bank 0 of the 6D dump (file offset 0x0–0x60000, 393216 bytes).

3. **HBM clock (FBPA PLL NDIV, post-GSP path)**
   The HBM clock is `NDIV × 27 MHz` of the FBPA PLL. The stock 67 VBIOS trains at NDIV=54
   (1458 MHz); the 6D trains at NDIV=64 (1728 MHz). After the GSP is up, the driver rewrites the
   FBPA PLL COEFF registers: a multicast write to `0x0098BC98` plus a PRI fence at `0x001211FC`,
   then polling `0x00903C90` bit 5 for lock. The memory then really runs at the new clock
   (measured `lock=1`).
   - **Only the post-GSP path works.** With the pre-GSP path alone the registers hold the new NDIV
     and NVML reports it, but the memory controller keeps its trained rate and bandwidth stays
     pinned at ~1387 GB/s (see `docs/en/09-experiment-log.md`).

---

## 3. Requirements

- NVIDIA CMP 170HX with the stock 67 VBIOS, `10de:20c2` (8 GB) or `10de:2082` (10 GB)
- x86_64 Linux, Secure Boot off (or a self-signed module key)
- Kernel headers: `/usr/src/linux-headers-$(uname -r)`
- **NVIDIA 615.71.09 open kernel modules** (`--kernel-module-type=open`)
- `build-essential`, `git`, `curl`, `python3`, `python3-yaml`, `patch`
- A 6D VBIOS dump: `268495.rom` (TechPowerUp VBIOS database, `92.00.6D.00.0A`,
  md5 `a58aae86e72b13d50603c15653350664`) — for copyright reasons this repository does not ship
  the ROM; obtain it yourself and verify the md5.

---

## 4. Quick start

```bash
git clone https://github.com/wanghar/cmp170hx-6d-VBIOS-upgrade.git
cd cmp170hx-6d-VBIOS-upgrade

# 0) environment check (read-only)
sudo bash scripts/00-check-host.sh

# 1) install the 615.71.09 open driver (skip if already installed)
sudo bash scripts/01-driver.sh /path/to/NVIDIA-Linux-x86_64-615.71.09.run

# 2) build the merged module (cmpunlocker unlock + vix-loader override + local patches)
sudo bash scripts/02-build.sh

# 3) build and install the payload from your 6D ROM (validates the legacy image and size)
sudo bash scripts/03-payload.sh /path/to/268495.rom --install

# 4) install modules and registry keys (HBM NDIV defaults to 64 = 1728 MHz)
sudo bash scripts/04-install.sh --ndiv 64

# 5) optional: PCIe Gen2 root-port retrain at boot (see docs/en/06-pcie-gen2.md)
sudo bash scripts/05-pcie-gen2.sh

# 6) reboot (none of the scripts ever reboots for you)
sudo reboot

# 7) verify
sudo bash scripts/99-verify.sh
```

To try a higher memory clock (1890 MHz): `sudo bash scripts/06-set-mclk.sh 70`, then reboot.

---

## 5. Manual route (equivalent to the scripts)

Full commands, expected outputs and pitfalls live in `docs/en/` (Chinese originals in
`docs/zh-CN/`), read in order:

| Document | Content |
|---|---|
| `docs/en/01-prerequisites.md` | Hardware/driver/kernel preparation, `nvidia-smi` baseline |
| `docs/en/02-driver-upgrade.md` | Install the 615.71.09 open driver |
| `docs/en/03-merged-module.md` | cmpunlocker's 14 patches + the vix-loader override + the 2 local patches, then build |
| `docs/en/04-vbios-payload.md` | 6D ROM → single-chain legacy payload (bank 0, 512 KiB cap) |
| `docs/en/05-hbm-clock.md` | FBPA PLL NDIV, post-GSP path, NDIV selection, stability testing |
| `docs/en/06-pcie-gen2.md` | Why Gen2 unlocked still runs at x4 Gen1, and the root-port retrain |
| `docs/en/07-verify.md` | Verification checklist with expected outputs |
| `docs/en/08-rollback.md` | Staged rollback (HBM only / VBIOS only / everything) |
| `docs/en/09-experiment-log.md` | All measurements, including the dead ends |

---

## 6. Verification checklist (`scripts/99-verify.sh` prints each item)

- [ ] `nvidia-smi` reports `92.00.6D.00.0A`
- [ ] 64 GB framebuffer (8 GB SKU) / 128 GB (10 GB SKU)
- [ ] Power: 250 W current, 300 W max (`nvidia-smi -q -d POWER`)
- [ ] `clocks.max.sm` = 1695 MHz
- [ ] `clocks.current.memory` = 1728 (NDIV=64) or 1890 (NDIV=70)
- [ ] dmesg has `vbios_override: GPU ... selected: 369152 bytes from offset 0x5e00 staged for GSP`
- [ ] dmesg has `HBMPLL_OC: post-GSP POST: ... lock=1`
- [ ] `nvidia-smi -q -d ECC` shows DRAM Correctable/Uncorrectable all 0, dmesg has no Xid
- [ ] Gen2 x4 where the slot supports it (`nvidia-smi --query-gpu=pcie.link.gen.current`)
- [ ] At least 60 s of sustained load with sane power and temperature

---

## 7. NDIV selection (8 GB cards)

| NDIV | Memory clock | Notes |
|---|---|---|
| 54 | 1458 | Stock 67 trained value |
| 64 | 1728 | **6D stock clock, recommended for a "true 6D"** |
| 70 | 1890 | Upstream reports ~60% of 8 GB cards handle it; stable on this card (0 ECC, 0 Xid) |
| 73 | 1971 | Upstream: only good samples |
| 30 | 810 | Downclock, for troubleshooting |

> Validate every step with the stability test in `scripts/99-verify.sh`: repeated matmul results
> must be bit-identical, ECC 0/0, Xid 0. Step down one notch if unstable.

---

## 8. Rollback (any layer)

```bash
# drop only the HBM overclock (back to the trained clock, module kept)
sudo bash scripts/06-set-mclk.sh 54     # or --off

# drop only the VBIOS override (back to the EEPROM 67 tables; the 64 GB unlock stays)
sudo bash scripts/98-rollback.sh --vbios

# drop everything (back to the stock 615 driver, 8 GB, 250 W)
sudo bash scripts/98-rollback.sh --all
```

Then `sudo reboot`. **If Xorg does not come up**: `Ctrl+Alt+F3` for a text console,
`sudo bash scripts/98-rollback.sh --all && sudo reboot`.

---

## 9. Known limits and findings

- **Hard cap of the GSP override image: 512 KiB of staged bytes.** Above that the firmware silently
  falls back to the EEPROM VBIOS while the host still logs `staged` (the driver only confirms
  staging, not acceptance). So the 6D dump's tail (BBX/InfoROM from 0xC2000 on) can never be
  delivered — but **the memory clock does not depend on the image**; layer 3 handles it.
- **The strap/board-config region of both VBIOS builds (0x41D40–0x41D70 vs 0x41F40–0x41F70) is
  byte-identical**, so the memory clock difference is not a strap setting.
- **The pre-GSP path alone is ineffective** (registers written, bandwidth unchanged); **the post-GSP
  path (multicast + PRI fence) is required**.
- **PCIe Gen2**: the cmpunlocker patch retrains only the GPU end, so **the root port must be
  retrained too**, otherwise the link stays Gen1 (1.63/1.68 GB/s vs 0.81/0.84 GB/s). A boot-time
  service is installed by `scripts/05-pcie-gen2.sh`.
- GSP firmware logs are unavailable on this machine (the driver package ships no `gsp_log_*.bin`).
- The card's PCIe slot is electrically x4: at Gen2 roughly 1.7 GB/s is the ceiling; more needs an
  x8/x16 slot.

---

## 10. Repository layout

```
cmp170hx-6d-VBIOS-upgrade/
├── README.md                 # English (default)
├── README.zh-CN.md           # Chinese
├── docs/
│   ├── en/                   # step-by-step guides (English)
│   └── zh-CN/                # step-by-step guides (Chinese)
├── scripts/                  # executable scripts (never reboot on their own)
│   ├── lib.sh
│   ├── 00-check-host.sh
│   ├── 01-driver.sh
│   ├── 02-build.sh
│   ├── 03-make-payload.py    # payload builder (validation + bank 0 only)
│   ├── 03-payload.sh
│   ├── 04-install.sh
│   ├── 05-pcie-gen2.sh
│   ├── 06-set-mclk.sh
│   ├── 98-rollback.sh
│   └── 99-verify.sh
├── patches/                  # local patches on top of upstream
│   ├── 0001-vix-loader-accept-first-legacy-image.patch
│   └── 0002-hbm-pll-ndiv-overclock.patch
└── config/                   # modprobe / systemd templates
```

---

## 11. Sources and credits

- [amoghmunikote/cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) — driver unlock
- [Panchovix/nvidia-linux-vbios-vix-loader](https://github.com/Panchovix/nvidia-linux-vbios-vix-loader) —
  in-memory VBIOS override (built on @pantsoftime's original `vbios_override` patch)
- [asm64-hooligan/cmpunlocker](https://github.com/asm64-hooligan/cmpunlocker/tree/mem_overclock) —
  HBM clock (FBPA PLL NDIV) approach and register constants
- [promisezackr/cmp170hx-ga100-300w-vbios](https://github.com/promisezackr/cmp170hx-ga100-300w-vbios) —
  300 W VBIOS material
- TechPowerUp VBIOS Database — source of the `92.00.6D.00.0A` dump

This repository contains only our own patches, scripts and documentation; no NVIDIA proprietary
source or VBIOS binary is included.

---

## 12. Disclaimer

Changing GPU firmware behaviour (power limits, clocks, framebuffer geometry) is risky: instability,
errors, data corruption and hardware damage are possible. Evaluate the risk yourself and keep a
rollback path. Every change here is in memory or in the driver — the EEPROM is not written and
nvflash is not used — but **do not** flash a VBIOS without a backup.
