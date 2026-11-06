# 08 — 回滚

三层改动互相独立，可以只退其中一层。

## 1. 只退 HBM 超频

```bash
sudo bash scripts/06-set-mclk.sh --off     # 删除 RmHbmPllNdiv
sudo reboot
```

重启后显存回到 Booter 训练值（67 VBIOS → 1458 MHz；若覆盖的是 6D → 1728 MHz）。
模块和 VBIOS 覆盖保留。

## 2. 只退 VBIOS 覆盖（回到 EEPROM 的 67）

```bash
sudo bash scripts/98-rollback.sh --vbios
sudo reboot
```

做法：把 `/lib/firmware/nvidia/615.71.09/vbios-override/vbios.bin` 换成原厂镜像
（`stock-loader.bin`，本仓库提供生成方式见 `docs/04`）并把
`RmLinuxVbiosOverrideSize` 改回对应值；或直接把 `RmLinuxVbiosOverride` 键删掉。

结果：VBIOS 回到 `92.00.67.00.01`、功耗上限 250 W、SM 上限 1410 MHz；
**显存解锁（64 GB）仍然保留**（那是驱动侧补丁）。

## 3. 全退（回到 stock 615 驱动）

```bash
sudo bash scripts/98-rollback.sh --all
sudo reboot
```

做法：

```bash
sudo rm -rf /lib/modules/$(uname -r)/updates/cmpunlocker
sudo rm -f  /etc/modprobe.d/90-cmp-vbios-override.conf
sudo rm -f  /etc/systemd/system/cmp-pcie-gen2-retrain.service
sudo systemctl disable --now cmp-pcie-gen2-retrain.service 2>/dev/null || true
sudo rm -f  /usr/local/bin/cmp-pcie-gen2-retrain.sh
sudo depmod -a
```

结果：回到 stock 615 驱动 —— 8 GB（未解锁）、250 W、SM 1410 MHz、无 VBIOS 覆盖。

## 4. Xorg 起不来时的控制台恢复

`Ctrl+Alt+F3` 进入文本控制台：

```bash
sudo bash /path/to/repo/scripts/98-rollback.sh --all
sudo depmod -a
sudo reboot
```

若连控制台也进不去（例如模块把显示搞挂）：用 Live USB 挂载根分区后删除
`/lib/modules/<kernel>/updates/cmpunlocker/` 与 `/etc/modprobe.d/90-cmp-vbios-override.conf`，
再启动即可回 stock。

## 5. 关于 EEPROM

本方案**从不写 EEPROM**，所以不存在“刷坏需要救砖”的场景；EEPROM 里的原厂 67 VBIOS
始终完好，是最后的安全网。**不要**在未备份的情况下用 nvflash 刷写。
