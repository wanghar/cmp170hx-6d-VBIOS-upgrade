# 05 — HBM memory overclock (FBPA PLL NDIV)

**English** | [简体中文](../zh-CN/05-hbm-clock.md)

## 1. Principle

The CMP 170HX HBM clock comes from the **FBPA PLL**:

```
HBM clock = NDIV × 27 MHz
```

- Stock 67 VBIOS: Booter/FMC trains at **NDIV=54 → 1458 MHz**
- 6D VBIOS: trains at **NDIV=64 → 1728 MHz**

By rewriting the PLL COEFF register from the driver side (NDIV in bits [15:8],
MDIV/PDIV left untouched), memory can run at the new frequency without changing
the VBIOS.

## 2. Key registers

| Register | Meaning |
|---|---|
| `0x00903c98` | FBPA0 PLL COEFF (NDIV bits[15:8]) |
| `0x00903c90` | PLL CFG (bit5 = lock) |
| `0x00903c7c/80/84` | FBPA PLL0/1/2 PLM (write `0xffffffff` to open access) |
| `0x0098bc98` | multicast COEFF (written to all FBPAs at once) |
| `0x001211fc` | PRI fence (write 0 to flush) |
| `0x009a0590` | MEMCLK_CHANGE_ALERT (bit31) |
| `0x009a031c` | HBM self-refresh control |
| `0x009a11dc` | DDLL control (bit6 triggers calibration) |
| FBPA base | `0x900000` + idx × `0x4000`, 12 slots total (this SKU activates 8) |

## 3. Two paths, only post-GSP works

The module implements two write paths:

**pre-GSP (SEC2 stage)**: open PLM → self-refresh → modify COEFF per FBPA → DDLL →
clear alert. Measured: the registers really do get written, and `nvidia-smi` reads
back the new NDIV, **but bandwidth does not change** (stuck at ~1387 GB/s). This
shows that during subsequent Booter/GSP initialization the memory controller still
runs at the original trained rate; the pre-GSP writes never actually reach the data
path.

**post-GSP (after GSP starts)**: multicast COEFF + **PRI fence** + poll lock →
measured `lock=1`, bandwidth immediately follows (1387 → 1826 GB/s). This is the
path this solution actually uses.

Example log (success):

```
NVRM: HBMPLL_OC: post-GSP PRE: COEFF=0x00014601(NDIV=70) PLM=0xffffffdf devid=0x20c2 vbios=92.00.67.00.01 newCOEFF=0x00014601
NVRM: HBMPLL_OC: post-GSP POST: COEFF=0x00014601(NDIV=70) CFG=0x8000092d lock=1 iter=0
```

## 4. Setting the frequency

registry key `RmHbmPllNdiv` (30–80), written into `NVreg_RegistryDwordsPerDevice` in
`90-cmp-vbios-override.conf`; **a reboot is required for a changed value to take
effect**:

```bash
sudo bash scripts/06-set-mclk.sh 64    # 1728 MHz (same as 6D stock, recommended)
sudo bash scripts/06-set-mclk.sh 70    # 1890 MHz (overclock)
sudo bash scripts/06-set-mclk.sh --off # turn off (back to trained value 1458)
```

After reboot:

```bash
nvidia-smi --query-gpu=clocks.current.memory --format=csv,noheader
# 1728 MHz or 1890 MHz
sudo dmesg | grep HBMPLL_OC | tail -3
```

## 5. NDIV selection (8 GB cards)
With several cards the key must appear in every `pci=` scope; `scripts/06-set-mclk.sh` does that for
you. Validate stability on each card separately: cards differ in binning and may need different NDIV
values.



| NDIV | Memory clock | Recommendation |
|---|---|---|
| 54 | 1458 | Stock trained value; fallback when unstable |
| 64 | 1728 | **Same as 6D stock, recommended** |
| 70 | 1890 | Measured stable on this card; upstream reports about 60% of 8 GB cards work |
| 73 | 1971 | Stable only on cards with good silicon; proceed with caution |
| 30–53 | <1458 | Downclock (for undervolting/troubleshooting) |

## 6. Stability verification (mandatory)

```bash
sudo bash scripts/99-verify.sh --stress 120
```

The script will:

1. Run the same fp16 matmul repeatedly, **comparing results bit by bit** (mismatch = memory error)
2. Sample power/temperature/SM clock
3. Check DRAM Correctable/Uncorrectable from `nvidia-smi -q -d ECC`
4. Check dmesg for Xid

Pass criteria: **0 mismatch, ECC 0/0, Xid 0**.

Measured on this card at 1890 MHz: 9499 runs with 0 mismatch, ECC 0/0, Xid 0,
power 245–251 W, 59–63 °C.

## 7. Common symptoms

| Symptom | Description |
|---|---|
| `nvidia-smi` shows the new memory clock but bandwidth is unchanged | Only the pre-GSP path took effect (check the `lock=1` log) |
| `DDLL cal status 0x00000000` | Those two status registers may be invalid on GA100; does not affect the post-GSP result |
| Bandwidth test jitter | Power/temperature limit; lock the clock or lower NDIV |
| Xid appears / ECC non-zero | Unstable; drop NDIV one step |
