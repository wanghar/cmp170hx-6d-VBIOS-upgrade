# 02 — Install NVIDIA 615.71.09 (open kernel modules)

**English** | [简体中文](../zh-CN/02-driver-upgrade.md)

cmpunlocker's 615 patches target the **615.71.09** open module source.

## 1. Why the open modules are required

- All patches in this approach target the `open` module (`kernel-open/`) source
- You must specify it explicitly at installation: `--kernel-module-type=open`

## 2. Install

```bash
chmod +x NVIDIA-Linux-x86_64-615.71.09.run
sudo ./NVIDIA-Linux-x86_64-615.71.09.run \
    --silent --kernel-module-type=open < /dev/null
```

Notes:
- `--open` is not a valid option; use `--kernel-module-type=open`
- Add `< /dev/null` to keep ncurses from hanging when there is no TTY

## 3. Verify

```bash
nvidia-smi --query-gpu=driver_version --format=csv,noheader   # 615.71.09
grep -i "kernel module type" /var/log/nvidia-installer.log | tail -2
ls /lib/modules/$(uname -r)/kernel/drivers/video/             # nvidia*.ko
```

## 4. Common Issues

- **Secure Boot enabled** → module signing fails, `nvidia-smi` reports `NVIDIA-SMI has failed`.
  Disable Secure Boot or use `--signing-key`.
- **Old driver leftovers** → run `sudo ./NVIDIA-Linux-x86_64-<old>.run --uninstall` first, then install the new version.
- Mixing **DKMS** with `.run` overwrites each other; use `.run` consistently.

> After the upgrade, confirm `nvidia-smi` works before proceeding to `03-merged-module.md`.
