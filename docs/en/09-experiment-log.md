# 09 — Experiment Log (including failed paths, to avoid repeating mistakes)

**English** | [简体中文](../zh-CN/09-experiment-log.md)

Records all measurements on this machine (CMP 170HX 8 GB SKU, `10de:20c2`).

## 1. VBIOS Override Image Size Sweep

payload is always **original 6D bytes + FF padding**, only the size changes (staged = payload − 0x5E00):

| payload | Staged | Result |
|---|---|---|
| bank1 standard | 369152 | ✅ 6D / 300W / 1695 |
| bank1 + 4KB FF | 373248 | ✅ |
| bank1 + 64KB FF | 434688 | ✅ |
| bank1 + 128KB FF (512KB payload) | 499712 | ✅ |
| staged exactly 0x80000 | 524288 | ✅ |
| staged 541696 | 541696 | ❌ falls back to 67 / 250W |
| bank1 + 256KB FF (640KB) | 631296 | ❌ |
| bank1 + bank2 (original bytes, image intact) | 762368 | ❌ |
| bank1 + all FF padded to 0xFF000 | 1020416 | ❌ |
| original full ROM (after parser relaxation) | 1020416 | ❌ |
| bank1 + FF + 8KB trailing header | 1020416 | ❌ |
| bank1 + FF (image area) + trailing section as-is | 1020416 | ❌ |
| trailing section moved forward (NPDS/JFFS+BBX, within window) | 524288 | ✅ but VRAM still 1458 |

**Conclusion**: the firmware's hard limit on the override image is **a staged size of 512 KiB**. Beyond that the firmware silently ignores it and
falls back to the EEPROM VBIOS, while the host side still prints `staged` (the driver only confirms staging). Content beyond bank1 does not affect
acceptance (FF padding and a moved-forward trailing section are both accepted); **rejection is determined by size alone**.

Also: the BBX/InfoROM trailing section of the 6D ROM is at offset 0xBA200 within the image, **always outside the 512 KiB window**;
forcing the trailing section forward into the window is accepted, but the VRAM frequency is unaffected (see section 3).

## 2. Differences Between the Two VBIOS Versions

- power table: 67 has `90 D0 03` (250W) at `0x45E45`; 6D has `E0 93 04` (300W) at `0x46045`
- strap (board config): 67 @ `0x41D53`, 6D @ `0x41F53`
- **the strap/board config region (0x41D40–0x41D70 vs 0x41F40–0x41F70) is byte-identical**
  → the VRAM frequency difference is not caused by strap
- largest difference block: BBX region `0xC2000–0xD6A00` (84480 bytes, of which 53632 differ)

## 3. VRAM Frequency: pre-GSP vs post-GSP

| NDIV | Path | VRAM | Theoretical | Global Read | Efficiency |
|---|---|---|---|---|---|
| 30 | pre | 810 | 829 | 573 | 69% |
| 54 | trained value | 1458 | 1493 | 1377 | 92% |
| 64 | pre-GSP only | 1728 | 1769 | **1387** | 78% |
| 70 | pre-GSP only | 1890 | 1935 | **1387** | 72% |
| 70 | **pre + post-GSP** | 1890 | 1935 | **1826** | 94% |

**Conclusion**: the pre-GSP path alone is ineffective (the register is written and NVML reads back the new NDIV, but the memory controller still runs at
the trained rate); only the post-GSP path (multicast COEFF + PRI fence + polling lock=1) makes the frequency actually
reach the datapath. At NDIV=30 the bandwidth drops correspondingly to 573 — proving that the FBPA PLL really drives DRAM.

## 4. Stability (NDIV=70, 1890 MHz)

- 9499 repeated fp16 matmuls: **0 mismatch**
- DRAM ECC correctable / uncorrectable: **0 / 0**
- dmesg Xid: **0**
- power 245–251 W (250 W cap), temperature 59–63 °C
- memory latency 352.9 ns (reference card at 1728 MHz is 364.8 ns)

## 5. Performance Comparison (same benchmark)

| Item | Stock 67 (1458) | 6D + NDIV=70 (1890) | Reference card native 6D (1728) |
|---|---|---|---|
| Global Read | 1377 | **1825** | 1675 |
| Global Write | 1359 | 1297 | 1285 |
| Global Copy | 1220 | **1623** | 1447 |
| Global Triad | 1289 | **1740** | 1582 |
| cudaMemcpy D2D | — | **1756** | 1583 |
| Latency | — | **352.9 ns** | 364.8 ns |
| FP32 | — | 13.92 | 13.78 |
| BF16 | — | 210.91 | 208.79 |

## 6. The PCIe Gen2 Pitfall

After the patch enables Gen2, `nvidia-smi` shows Gen2, but the measured value is still Gen1 (H2D 0.81 / D2H 0.84 GB/s).
Root cause: the patch retrains only the GPU side; **the root port is still at 2.5 GT/s**. Write
`CAP_EXP+0x30.w=0x0002` (target rate) to the root port, then trigger a retrain with `CAP_EXP+0x10.w=0x0020`;
it immediately becomes Gen2 x4 (H2D 1.63 / D2H 1.68 GB/s, 95% of the theoretical value).
This is now an automatic service at boot (`scripts/05-pcie-gen2.sh`).

## 7. GSP Firmware Logs

The 615.71.09 installer on this machine **does not ship `gsp_log_*.bin`**; `NVreg_EnableGpuFirmwareLogs=1`
only prints `RmFetchGspRmImages: Failed to load gsp_log_*.bin`. So the accept/reject details on the firmware side cannot be seen, and can only be
inferred backwards from the VBIOS version reported by `nvidia-smi`.

## 8. Power/Temperature (300 W Cap)

- stress test average 281 W, peak 323 W, 92% of samples >250 W
- max temperature 76 °C (slowdown threshold 95 °C), Xid 0
- 28 GiB fp16 allocation works normally, `mem_get_info` 63.4 GiB

## 9. Pitfalls Encountered

| Pitfall | Symptom | Resolution |
|---|---|---|
| `install-merged.sh` default payload is stock 250W | after reinstalling the module the 6D is swapped out, SM limit 1410 | it no longer overwrites the firmware without arguments; install explicitly with `install_payload.sh <6D.bin>` |
| patch installed under the modules directory but depmod forgotten | still stock after reboot | `sudo depmod -a` |
| `--open` argument | installer rejects it | use `--kernel-module-type=open` |
| ncurses installer UI hangs without a TTY | installer waits for input | add `--silent ... < /dev/null` |
| full ROM fed directly (1020416 B) | firmware silently falls back | feed only bank1 (393216 B) |
