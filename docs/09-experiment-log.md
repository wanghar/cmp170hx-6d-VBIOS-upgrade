# 09 — 实验记录（含失败路线，避免重复踩坑）

记录本机（CMP 170HX 8 GB SKU，`10de:20c2`）全部实测。

## 1. VBIOS 覆盖镜像大小扫描

payload 全是**原始 6D 字节 + FF 填充**，只改大小（暂存 = payload − 0x5E00）：

| payload | 暂存 | 结果 |
|---|---|---|
| bank1 标准 | 369152 | ✅ 6D / 300W / 1695 |
| bank1 + 4KB FF | 373248 | ✅ |
| bank1 + 64KB FF | 434688 | ✅ |
| bank1 + 128KB FF (512KB payload) | 499712 | ✅ |
| 暂存恰好 0x80000 | 524288 | ✅ |
| 暂存 541696 | 541696 | ❌ 回落 67 / 250W |
| bank1 + 256KB FF (640KB) | 631296 | ❌ |
| bank1 + bank2（原始字节，镜像完好） | 762368 | ❌ |
| bank1 + 全 FF 填到 0xFF000 | 1020416 | ❌ |
| 原始全 ROM（parser 放宽后） | 1020416 | ❌ |
| bank1 + FF + 尾部头 8KB | 1020416 | ❌ |
| bank1 + FF(镜像区) + 尾部原样 | 1020416 | ❌ |
| 尾部前移（NPDS/JFFS+BBX，窗口内） | 524288 | ✅ 但显存仍 1458 |

**结论**：固件对覆盖镜像的硬上限是**暂存 512 KiB**。超过后固件静默忽略、回落到
EEPROM VBIOS，而 host 侧仍打印 `staged`（驱动只确认暂存）。bank1 之外的内容不影响
接受与否（FF 填充、尾部前移都能被接受），**拒绝只由大小决定**。

另：6D ROM 的 BBX/InfoROM 尾部在镜像内偏移 0xBA200，**永远超出 512 KiB 窗口**；
把尾部强行前移进窗口能被接受，但显存频率不受影响（见第 3 节）。

## 2. 两版 VBIOS 的差异

- 功耗表：67 在 `0x45E45` 是 `90 D0 03`（250W），6D 在 `0x46045` 是 `E0 93 04`（300W）
- strap（board config）：67 @ `0x41D53`，6D @ `0x41F53`
- **strap/board config 区（0x41D40–0x41D70 vs 0x41F40–0x41F70）逐字节相同**
  → 显存频率差异不是 strap 造成的
- 最大差异块：BBX 区 `0xC2000–0xD6A00`（84480 字节，其中 53632 字节不同）

## 3. 显存频率：pre-GSP vs post-GSP

| NDIV | 路径 | 显存 | Theoretical | Global Read | 效率 |
|---|---|---|---|---|---|
| 30 | pre | 810 | 829 | 573 | 69% |
| 54 | 训练值 | 1458 | 1493 | 1377 | 92% |
| 64 | 仅 pre-GSP | 1728 | 1769 | **1387** | 78% |
| 70 | 仅 pre-GSP | 1890 | 1935 | **1387** | 72% |
| 70 | **pre + post-GSP** | 1890 | 1935 | **1826** | 94% |

**结论**：pre-GSP 路径单独无效（寄存器写了、NVML 读得到新 NDIV，但内存控制器仍按
训练速率工作）；post-GSP 路径（多播 COEFF + PRI fence + 轮询 lock=1）才让频率真正
落到数据通路。NDIV=30 时带宽同步下降到 573 —— 证明 FBPA PLL 确实驱动 DRAM。

## 4. 稳定性（NDIV=70，1890 MHz）

- 9499 次重复 fp16 matmul：**0 mismatch**
- DRAM ECC correctable / uncorrectable：**0 / 0**
- dmesg Xid：**0**
- 功耗 245–251 W（250 W 墙），温度 59–63 °C
- 内存延迟 352.9 ns（参考卡 1728 MHz 为 364.8 ns）

## 5. 性能对照（同 benchmark）

| 项 | 原厂 67（1458） | 6D + NDIV=70（1890） | 参考卡原生 6D（1728） |
|---|---|---|---|
| Global Read | 1377 | **1825** | 1675 |
| Global Write | 1359 | 1297 | 1285 |
| Global Copy | 1220 | **1623** | 1447 |
| Global Triad | 1289 | **1740** | 1582 |
| cudaMemcpy D2D | — | **1756** | 1583 |
| 延迟 | — | **352.9 ns** | 364.8 ns |
| FP32 | — | 13.92 | 13.78 |
| BF16 | — | 210.91 | 208.79 |

## 6. PCIe Gen2 的坑

补丁开启 Gen2 后 `nvidia-smi` 显示 Gen2，但实测仍是 Gen1（H2D 0.81 / D2H 0.84 GB/s）。
根因：补丁只重训 GPU 端，**根端口仍在 2.5 GT/s**。对根端口写
`CAP_EXP+0x30.w=0x0002`（目标速率）再触发重训 `CAP_EXP+0x10.w=0x0020`，
立刻变成 Gen2 x4（H2D 1.63 / D2H 1.68 GB/s，达理论值 95%）。
已做成开机自动服务（`scripts/05-pcie-gen2.sh`）。

## 7. GSP 固件日志

本机的 615.71.09 安装包**没有附带 `gsp_log_*.bin`**，`NVreg_EnableGpuFirmwareLogs=1`
只会打印 `RmFetchGspRmImages: Failed to load gsp_log_*.bin`。所以看不到固件侧的
接受/拒绝细节，只能靠 `nvidia-smi` 的 VBIOS 版本反推。

## 8. 功耗/温度（300 W 档）

- 压测平均 281 W，峰值 323 W，92% 采样 >250 W
- 最高温度 76 °C（慢降阈值 95 °C），Xid 0
- 28 GiB fp16 分配正常，`mem_get_info` 63.4 GiB

## 9. 踩过的坑

| 坑 | 现象 | 解决 |
|---|---|---|
| `install-merged.sh` 默认 payload 是 stock 250W | 重装模块后 6D 被换掉，SM 上限 1410 | 不带参数不再覆盖固件；用 `install_payload.sh <6D.bin>` 显式装 |
| 补丁装在 modules 目录但忘了 depmod | 重启后仍是 stock | `sudo depmod -a` |
| `--open` 参数 | 安装器拒绝 | 用 `--kernel-module-type=open` |
| ncurses 安装界面无 TTY 卡住 | 安装器等待输入 | 加 `--silent ... < /dev/null` |
| 全 ROM 直喂（1020416 B） | 固件静默回落 | 只喂 bank1（393216 B） |
