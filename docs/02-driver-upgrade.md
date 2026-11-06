# 02 — 安装 NVIDIA 615.71.09（open kernel modules）

cmpunlocker 的 615 补丁针对 **615.71.09** 的 open 模块源码。

## 1. 为什么必须 open 模块

- 本方案的补丁全部针对 `open` 模块（`kernel-open/`）源码
- 安装时必须显式指定：`--kernel-module-type=open`

## 2. 安装

```bash
chmod +x NVIDIA-Linux-x86_64-615.71.09.run
sudo ./NVIDIA-Linux-x86_64-615.71.09.run \
    --silent --kernel-module-type=open < /dev/null
```

注意：
- `--open` 不是有效参数，要用 `--kernel-module-type=open`
- 加 `< /dev/null` 避免 ncurses 在无 TTY 时卡住

## 3. 校验

```bash
nvidia-smi --query-gpu=driver_version --format=csv,noheader   # 615.71.09
grep -i "kernel module type" /var/log/nvidia-installer.log | tail -2
ls /lib/modules/$(uname -r)/kernel/drivers/video/             # nvidia*.ko
```

## 4. 常见问题

- **Secure Boot 开启** → 模块签名失败，`nvidia-smi` 报 `NVIDIA-SMI has failed`。
  关闭 Secure Boot 或用 `--signing-key`。
- **旧驱动残留** → 先 `sudo ./NVIDIA-Linux-x86_64-<old>.run --uninstall` 再装新版。
- **DKMS** 与 `.run` 混用会互相覆盖，统一用 `.run`。

> 升级完成后先确认 `nvidia-smi` 正常，再进入 `docs/03-merged-module.md`。
