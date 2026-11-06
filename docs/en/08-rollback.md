# 08 — Rollback

**English** | [简体中文](../zh-CN/08-rollback.md)

The three layers of changes are independent; any single layer can be reverted on its own.

## 1. Revert Only the HBM Overclock

```bash
sudo bash scripts/06-set-mclk.sh --off     # removes RmHbmPllNdiv
sudo reboot
```

After reboot, VRAM returns to the Booter-trained value (67 VBIOS → 1458 MHz; if a 6D image is overridden → 1728 MHz). The module and VBIOS override are kept.

## 2. Revert Only the VBIOS Override (back to the 67 in EEPROM)

```bash
sudo bash scripts/98-rollback.sh --vbios
sudo reboot
```

How: replace `/lib/firmware/nvidia/615.71.09/vbios-override/vbios.bin` with the stock image
(`stock-loader.bin`; this repository documents how to generate it in `04-vbios-payload.md`) and set
`RmLinuxVbiosOverrideSize` back to the corresponding value; or simply delete the `RmLinuxVbiosOverride` key.

Result: VBIOS returns to `92.00.67.00.01`, power limit 250 W, SM limit 1410 MHz;
**the VRAM unlock (64 GB) is still kept** (that is a driver-side patch).

## 3. Full Revert (back to the stock 615 driver)

```bash
sudo bash scripts/98-rollback.sh --all
sudo reboot
```

How:

```bash
sudo rm -rf /lib/modules/$(uname -r)/updates/cmpunlocker
sudo rm -f  /etc/modprobe.d/90-cmp-vbios-override.conf
sudo rm -f  /etc/systemd/system/cmp-pcie-gen2-retrain.service
sudo systemctl disable --now cmp-pcie-gen2-retrain.service 2>/dev/null || true
sudo rm -f  /usr/local/bin/cmp-pcie-gen2-retrain.sh
sudo depmod -a
```

Result: back to the stock 615 driver — 8 GB (not unlocked), 250 W, SM 1410 MHz, no VBIOS override.

## 4. Console Recovery When Xorg Will Not Start

`Ctrl+Alt+F3` to enter the text console:

```bash
sudo bash /path/to/repo/scripts/98-rollback.sh --all
sudo depmod -a
sudo reboot
```

If even the console is unreachable (for example, the module breaks the display): boot a Live USB, mount the root partition, delete
`/lib/modules/<kernel>/updates/cmpunlocker/` and `/etc/modprobe.d/90-cmp-vbios-override.conf`,
then reboot to return to stock.

## 5. About the EEPROM

This approach **never writes the EEPROM**, so there is no "bricked card needing recovery" scenario; the stock 67 VBIOS
in the EEPROM always remains intact and is the final safety net. **Do not** flash with nvflash without a backup.
