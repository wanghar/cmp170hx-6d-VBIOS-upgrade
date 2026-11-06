# 04 — 6D ROM → VBIOS override payload

**English** | [简体中文](../zh-CN/04-vbios-payload.md)

## 1. What the payload is

vix-loader mechanism: before GSP starts, the driver hands an image to the firmware,
which uses it instead of the EEPROM VBIOS to initialize the GPU. **EEPROM is not
written**.

Firmware requirements for the image (measured):

| Requirement | Description |
|---|---|
| Single-chain legacy image | One `55AA` + `PCIR` (code type 0), checksum equals 0 |
| Staging size ≤ **512 KiB** | Staged bytes = payload size − 0x5E00; exceeding it makes the firmware **silently fall back** to the EEPROM VBIOS |
| `RmLinuxVbiosOverrideSize` == file length | Driver-side check; mismatch fails immediately |

The 6D ROM (`268495.rom`, 1044480 bytes) is **dual-bank** (bank2 has a mirrored copy
at 0x60000), so the whole image cannot be fed in. Correct approach: **take only bank1
(0x0–0x60000, 393216 bytes)**.

## 2. Generate the payload

```bash
sudo bash scripts/03-payload.sh /path/to/268495.rom
# equivalent to:
python3 scripts/03-make-payload.py /path/to/268495.rom -o work/payload-300w.bin
```

The generator will:

1. Verify ROM length and md5 (optional, `--expect-md5`)
2. Locate the legacy image in the ROM (`55AA` + `PCIR`) and verify the image checksum
3. Take the content from the image start offset to the bank boundary (0x60000) as the payload
4. Verify the payload contains a valid single-chain legacy image
5. Output `payload-300w.bin`, `SIZE=`, `sha256`

Typical measured values:

```
input:  268495.rom  1044480 bytes
image:  legacy @0x000000  (PCIR code type 0, checksum ok)
output: payload-300w.bin  393216 bytes
staged: 393216 - 0x5E00 = 369152 bytes   (< 512 KiB ✓)
sha256: 9eba96103d93fe902dfa7caf562512f61c2e8bc1c33a55e7bbd52f3da7642d8e
```

## 3. Install the payload

```bash
sudo bash scripts/03-payload.sh /path/to/268495.rom --install
```

Or manually:

```bash
sudo mkdir -p /lib/firmware/nvidia/615.71.09/vbios-override
sudo cp work/payload-300w.bin /lib/firmware/nvidia/615.71.09/vbios-override/vbios.bin
```

## 4. registry parameters (per-device)

`/etc/modprobe.d/90-cmp-vbios-override.conf`:

```
options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:02:00.0;RmLinuxVbiosOverride=2;RmLinuxVbiosOverrideSize=393216;RmHbmPllNdiv=64"
options nvidia NVreg_RegistryBinaryFilePerDevice="pci=0000:02:00.0;RmLinuxVbiosOverrideImage=615.71.09/vbios-override/vbios.bin"
```

- `RmLinuxVbiosOverride=2` is the required mode value (1 = off, 2 = on)
- `RmLinuxVbiosOverrideSize` must equal the file's byte count
- `RmLinuxVbiosOverrideImage` is a path relative to `/lib/firmware/nvidia/`
- With multiple GPUs, repeat the key/value pairs as `pci=...;pci=...`

## 5. Verify acceptance

Driver log (host side; only proves **staging** succeeded):

```
NVRM: vbios_override: GPU 0000:02:00 selected: 369152 bytes from offset 0x5e00 staged for GSP
```

Whether the firmware actually used the image: check `nvidia-smi`:

```bash
nvidia-smi --query-gpu=vbios_version,power.max_limit,clocks.max.sm --format=csv
# 92.00.6D.00.0A, 300.00 W, 1695 MHz   ← accepted
# 92.00.67.00.01, 250.00 W, 1410 MHz   ← rejected (firmware fell back to EEPROM)
```

**Failure troubleshooting**:

| Symptom | Cause | Action |
|---|---|---|
| `staged` line present, but VBIOS is still 67 | Firmware rejected it (size over limit / bad image structure) | Shrink the payload; confirm it is a single-chain legacy image |
| No `staged` line | Driver-side check failed | Check `Size` == file length, file path, `mode=2` |
| `rejected override ... using stock VBIOS` | Version/check failure | Confirm driver version matches the image, image checksum is 0 |

## 6. Experimental evidence for the 512 KiB limit

`09-experiment-log.md` has the full table: 369152 ✓, 373248 ✓, 434688 ✓, 499712 ✓,
**524288 ✓**, 541696 ✗, 631296 ✗, 762368 ✗, 1020416 ✗ — rejection is determined by
size alone, independent of content.
