# 06 — PCIe Gen2 unlock (including the root-port retrain pitfall)

**English** | [简体中文](../zh-CN/06-pcie-gen2.md)

## 1. Symptom

After applying the `pcie-gen2` patch with cmpunlocker, `nvidia-smi` shows Gen2 is
enabled, but the link actually still runs Gen1 x4: PCIe bandwidth is only
**0.81 / 0.84 GB/s** (H2D/D2H).

## 2. Root cause

The patch only retrains the **GPU side** of the link. Link speed is **negotiated by
both ends**, and the root port is still at 2.5 GT/s. You must also switch the root
port to 5 GT/s and trigger a retrain.

## 3. Fix (manual)

```bash
BDF=02:00.0        # your GPU
RP=$(basename $(dirname $(readlink -f /sys/bus/pci/devices/0000:$BDF/../)) | sed 's/\..*//')

# set the target speed to 5GT/s on both ends (Link Capabilities field, Gen2=2)
sudo setpci -s $RP.0 CAP_EXP+0x30.w=0x0002
sudo setpci -s $BDF CAP_EXP+0x30.w=0x0002

# trigger link retrain (retrain bit in the root port's Link Control)
sudo setpci -s $RP.0 CAP_EXP+0x10.w=0x0020
```

Verify:

```bash
sudo lspci -vv -s $BDF | grep -E "LnkSta|LnkCap"
# LnkSta: Speed 5GT/s, Width x4
nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv
```

Measured effect: H2D 0.81 → **1.63 GB/s**, D2H 0.84 → **1.68 GB/s**, reaching 95% of
the Gen2 x4 theoretical value.

## 4. Automatic at boot (recommended)

`scripts/05-pcie-gen2.sh` installs:

- `/usr/local/bin/cmp-pcie-gen2-retrain.sh`: automatically finds the GPU BDF and root port, sets 5 GT/s, and retrains
- `/etc/systemd/system/cmp-pcie-gen2-retrain.service`: runs once at boot

```bash
sudo bash scripts/05-pcie-gen2.sh
systemctl status cmp-pcie-gen2-retrain.service
```

> Retraining is idempotent; even if the root port is already Gen2, writing again is harmless.

## 5. Limitations

- This machine's slot is electrically x4 → Gen2 tops out at ~1.7 GB/s, already maxed out
- Higher bandwidth requires an electrically x8/x16 slot (Gen3 there needs hardware support)
