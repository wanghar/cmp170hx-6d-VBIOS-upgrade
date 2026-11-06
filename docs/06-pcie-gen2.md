# 06 — PCIe Gen2 解锁（含根端口重训这个坑）

## 1. 现象

cmpunlocker 打完 `pcie-gen2` 补丁后，`nvidia-smi` 显示 Gen2 已启用，但实际链路仍跑
Gen1 x4：PCIe 带宽只有 **0.81 / 0.84 GB/s**（H2D/D2H）。

## 2. 根因

补丁只重训了 **GPU 端**的链路。而链路速率是**两端协商**的，根端口（root port）
还停在 2.5 GT/s。必须同时把根端口切到 5 GT/s 并触发重训。

## 3. 修复（手动）

```bash
BDF=02:00.0        # 你的 GPU
RP=$(basename $(dirname $(readlink -f /sys/bus/pci/devices/0000:$BDF/../)) | sed 's/\..*//')

# 两端设置目标速率 5GT/s（Link Capabilities 字段，Gen2=2）
sudo setpci -s $RP.0 CAP_EXP+0x30.w=0x0002
sudo setpci -s $BDF CAP_EXP+0x30.w=0x0002

# 触发链路重训（根端口 Link Control 的 retrain bit）
sudo setpci -s $RP.0 CAP_EXP+0x10.w=0x0020
```

验证：

```bash
sudo lspci -vv -s $BDF | grep -E "LnkSta|LnkCap"
# LnkSta: Speed 5GT/s, Width x4
nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv
```

实测效果：H2D 0.81 → **1.63 GB/s**，D2H 0.84 → **1.68 GB/s**，达到 Gen2 x4 理论值的 95%。

## 4. 开机自动（推荐）

`scripts/05-pcie-gen2.sh` 会安装：

- `/usr/local/bin/cmp-pcie-gen2-retrain.sh`：自动找 GPU BDF 与根端口，设置 5 GT/s 并重训
- `/etc/systemd/system/cmp-pcie-gen2-retrain.service`：开机执行一次

```bash
sudo bash scripts/05-pcie-gen2.sh
systemctl status cmp-pcie-gen2-retrain.service
```

> 重训是幂等的；即使根端口本来已是 Gen2，再写一次也无害。

## 5. 限制

- 本机插槽电气 x4 → Gen2 上限 ~1.7 GB/s，已到顶
- 要更高带宽需要 x8/x16 电气插槽（此时 Gen3 需硬件支持）
