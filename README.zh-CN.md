# CMP 170HX：67 → 6D（300 W）升级 + 64 GB 解锁 + HBM 1728/1890 MHz（不刷 EEPROM）

[English](README.md) | **简体中文**

在 Linux 上把 NVIDIA CMP 170HX（GA100）从原厂 `92.00.67.00.01`（250 W）升级成
`92.00.6D.00.0A`（300 W 上限）的等效状态，保留驱动侧解锁，并把 HBM 时钟从 1458 MHz
提到 1728 MHz（= 6D 原厂同频）或更高，**全程不写 EEPROM、不碰 nvflash**，随时可回滚。

> English TL;DR: this repo reproduces a CMP 170HX upgrade to the 300 W `92.00.6D.00.0A`
> VBIOS behaviour, 64 GB framebuffer and a raised HBM clock (FBPA PLL NDIV), entirely in
> driver/firmware memory — the card's flash chip is never written.

---

## 1. 本机实测结果

同一台机器、同一张卡（8 GB SKU，`10de:20c2`），不同阶段跑同一 benchmark
（`scripts/99-verify.sh` 里的 `nvidia_bench`，512 MiB 缓冲区，128 B stride）：

| 项目 | 原厂 67（250 W） | 本方案：6D + NDIV=64 | 本方案：6D + NDIV=70 | 参考卡：原生刷 6D（1728） |
|---|---|---|---|---|
| VBIOS | 92.00.67.00.01 | 92.00.6D.00.0A | 92.00.6D.00.0A | 92.00.6D.00.0A |
| 显存容量 | 64 GB（解锁后） | 64 GB | 64 GB | 64 GB |
| 功耗上限 | 250 W | 250 W 默认 / 300 W 上限 | 250 W 默认 / 300 W 上限 | 250 W 默认 / 300 W 上限 |
| SM 上限 | 1410 MHz | 1695 MHz | 1695 MHz | 1482 MHz（实测满载） |
| 显存时钟 | 1458 MHz | **1728 MHz** | **1890 MHz** | 1728 MHz |
| Theoretical BW | 1493 GB/s | 1769 GB/s | 1935 GB/s | 1769 GB/s |
| Global Read | 1377 GB/s | ≈1670 GB/s（预计） | **1825 GB/s** | 1675 GB/s |
| Global Write | 1359 GB/s | — | 1297 GB/s | 1285 GB/s |
| Global Copy | 1220 GB/s | — | **1623 GB/s** | 1447 GB/s |
| Global Triad | 1289 GB/s | — | **1740 GB/s** | 1582 GB/s |
| cudaMemcpy D2D | — | — | **1756 GB/s** | 1583 GB/s |
| 内存延迟 | — | — | **352.9 ns** | 364.8 ns |
| FP32 / BF16 | — | — | 13.92 / 210.91 TFLOPS | 13.78 / 208.79 TFLOPS |
| PCIe | Gen2 x4（槽位限制） | Gen2 x4 | Gen2 x4 | Gen2 x4 |

稳定性（NDIV=70 那一档实测）：重复 fp16 matmul **9499 次 0 错误**、DRAM ECC
correctable/uncorrectable **0/0**、**Xid 0**、功耗 245–251 W、温度 59–63 °C。

---

## 2. 原理：三层各自独立、可分别回滚

1. **驱动解锁（cmpunlocker，14 个内核补丁）**
   去掉固件/OTP 对 CMP 170HX 的限制：SM 频率解锁、显存几何解锁（8 GB SKU → 64 GB、
   10 GB SKU → 128 GB）、ECC、PCIe Gen2、持久化 SW state 等。这是**驱动侧**改动，
   不碰 VBIOS。

2. **VBIOS 内存覆盖（nvidia-linux-vbios-vix-loader）**
   让 GSP 固件在启动时用我们提供的 6D 镜像（而不是 EEPROM 里的 67），从而获得
   300 W 功耗表、1695 MHz 的 SM 频率表。镜像只暂存在内存里，**EEPROM 永远不动**。
   - GSP 固件只接受**单链 legacy 镜像**（一个 55AA + PCIR，校验和为 0），
     且**暂存大小 ≤ 512 KiB**（超过会静默回落到 EEPROM 里的 VBIOS）。
   - 因此 payload = 6D ROM 的 bank1（文件偏移 0x0–0x60000，393216 字节）。

3. **HBM 时钟（FBPA PLL NDIV，post-GSP 路径）**
   HBM 时钟 = FBPA PLL 的 `NDIV × 27 MHz`。原厂 67 VBIOS 训练在 NDIV=54（1458 MHz），
   6D 训练在 NDIV=64（1728 MHz）。驱动在 GSP 启动后改写 FBPA PLL 的 COEFF：
   多播写 `0x0098BC98` + PRI fence `0x001211FC` + 轮询 `0x00903C90` bit5 锁定，
   即可让显存真正跑在新频率上（实测 `lock=1`）。
   - **只有 post-GSP 路径有效**：pre-GSP 路径单独跑时寄存器写进去了、NVML 也读得到
     新 NDIV，但内存控制器仍按训练速率工作，带宽卡在 ~1387 GB/s（详见
     `docs/zh-CN/09-experiment-log.md`）。

---

## 3. 环境要求

- NVIDIA CMP 170HX（原厂 67 VBIOS），`10de:20c2`（8 GB）或 `10de:2082`（10 GB）
- Linux 发行版，x86_64，Secure Boot 关闭（或自签模块签名）
- 内核头文件：`/usr/src/linux-headers-$(uname -r)`（Debian/Ubuntu：`linux-headers-$(uname -r)`）
- **NVIDIA 615.71.09 open kernel modules**（`--kernel-module-type=open`）
- `build-essential`、`git`、`curl`、`python3`、`python3-yaml`、`patch`
- 6D VBIOS dump：`268495.rom`
  （来源：TechPowerUp VBIOS 数据库，`92.00.6D.00.0A`，md5 `a58aae86e72b13d50603c15653350664`）
  ——出于版权原因，本仓库不附带 ROM 文件，请自行获取并核对 md5。

---

## 4. 快速开始

```bash
git clone https://github.com/wanghar/cmp170hx-6d-VBIOS-upgrade.git
cd cmp170hx-6d-VBIOS-upgrade

# 0) 检查环境（不修改系统）
sudo bash scripts/00-check-host.sh

# 1) 安装 615.71.09 open 驱动（已安装可跳过）
sudo bash scripts/01-driver.sh /path/to/NVIDIA-Linux-x86_64-615.71.09.run

# 2) 构建合并模块（cmpunlocker 解锁 + vix-loader 覆盖 + 本仓库补丁）
sudo bash scripts/02-build.sh

# 3) 用你的 6D ROM 生成并安装 payload（会自动校验 legacy 镜像与大小）
sudo bash scripts/03-payload.sh /path/to/268495.rom

# 4) 安装模块 + 配置 registry（HBM NDIV 默认 64 = 1728 MHz）
sudo bash scripts/04-install.sh --ndiv 64

# 5) 可选：PCIe Gen2 根端口重训（开机自动，见 docs/zh-CN/06-pcie-gen2.md）
sudo bash scripts/05-pcie-gen2.sh

# 6) 重启（本仓库脚本从不自动重启）
sudo reboot

# 7) 验证
sudo bash scripts/99-verify.sh
```

想试更高显存频率（1890 MHz）：`sudo bash scripts/06-set-mclk.sh 70` 再重启。

---

## 5. 手动步骤（与脚本等价，便于逐步核查）

完整命令、预期输出和坑都写在 `docs/` 里，按顺序读：

| 文档 | 内容 |
|---|---|
| `docs/zh-CN/01-prerequisites.md` | 硬件/驱动/内核准备，`nvidia-smi` 基线 |
| `docs/zh-CN/02-driver-upgrade.md` | 610 → 615.71.09 open 驱动安装 |
| `docs/zh-CN/03-merged-module.md` | cmpunlocker 14 补丁 + vix-loader 覆盖 + 本仓库 2 个补丁 + 编译 |
| `docs/zh-CN/04-vbios-payload.md` | 6D ROM → 单链 legacy payload（bank1，512 KiB 上限） |
| `docs/zh-CN/05-hbm-clock.md` | FBPA PLL NDIV、post-GSP 路径、NDIV 选值、稳定性验证 |
| `docs/zh-CN/06-pcie-gen2.md` | Gen2 解锁后为什么仍是 x4 Gen1：根端口重训（关键坑） |
| `docs/zh-CN/07-verify.md` | 验证清单与每项预期输出 |
| `docs/zh-CN/08-rollback.md` | 分阶段回滚（只退 HBM / 只退 VBIOS / 全退） |
| `docs/zh-CN/09-experiment-log.md` | 全部实验记录（含失败的路线，避免踩坑） |

---

## 6. 验证清单（`scripts/99-verify.sh` 会逐项打印）

- [ ] `nvidia-smi` 显示 `92.00.6D.00.0A`
- [ ] 显存 64 GB（8 GB SKU）/ 128 GB（10 GB SKU）
- [ ] 功耗：当前 250 W，上限 300 W（`nvidia-smi -q -d POWER`）
- [ ] `clocks.max.sm` = 1695 MHz
- [ ] `clocks.current.memory` = 1728（NDIV=64）或 1890（NDIV=70）
- [ ] dmesg 有 `vbios_override: GPU ... selected: 369152 bytes from offset 0x5e00 staged for GSP`
- [ ] dmesg 有 `HBMPLL_OC: post-GSP POST: ... lock=1`
- [ ] `nvidia-smi -q -d ECC` 里 DRAM Correctable/Uncorrectable 全 0，dmesg 无 Xid
- [ ] (`lspci -vv -s <BDF>` / `nvidia-smi --query-gpu=pcie.link.gen.current`) Gen2 x4（如槽位支持）
- [ ] 跑一次 60 s 以上的持续负载，温度/功耗正常

---

## 7. NDIV 选值表（8 GB 卡实测/上游经验）

| NDIV | 显存 | 说明 |
|---|---|---|
| 54 | 1458 | 原厂 67 训练值 |
| 64 | 1728 | **6D 原厂同频，推荐“真 6D”** |
| 70 | 1890 | 上游称约 60% 的 8 GB 卡可稳；本卡实测稳定（0 ECC / 0 Xid） |
| 73 | 1971 | 上游称“体质好的卡”才行 |
| 30 | 810 | 降频，用于排查/降压 |

> 每一档都要跑 `scripts/99-verify.sh` 里的稳定性测试：重复 matmul 结果逐位一致、
> ECC 0/0、Xid 0。不稳定就降一档。

---

## 8. 回滚（任选一层）

```bash
# 只退 HBM 超频（回到 1458/1728，模块保留）
sudo bash scripts/06-set-mclk.sh 54     # 或 --off

# 只退 VBIOS 覆盖（回到 EEPROM 的 67 表；64 GB 解锁仍保留）
sudo bash scripts/98-rollback.sh --vbios

# 全退（回到 stock 615 驱动、8 GB、250 W）
sudo bash scripts/98-rollback.sh --all
```

之后 `sudo reboot`。**在 Xorg 起不来的情况下**：`Ctrl+Alt+F3` 进控制台执行
`sudo bash scripts/98-rollback.sh --all && sudo reboot`。

---

## 9. 已知限制与结论

- **GSP 覆盖镜像硬上限 512 KiB（暂存字节数）**。超了就静默回落 EEPROM VBIOS，
  主机侧仍打印 `staged`（驱动只确认暂存，不确认固件接受）。所以 6D ROM 的尾部
  （BBX/InfoROM @0xC2000 起）永远送不进去，但**显存频率不靠镜像**，靠第 3 层的 PLL 路径。
- **两版 VBIOS 的 strap/board-config 区（0x41D40–0x41D70 vs 0x41F40–0x41F70）逐字节相同**
  → 显存频率差异不是 strap 造成的。
- **pre-GSP 路径单独无效**（寄存器写了但带宽不变）；**必须 post-GSP**（多播 + PRI fence）。
- **PCIe Gen2**：cmpunlocker 的补丁只重训 GPU 端，**必须同时重训根端口**，否则仍跑
  Gen1（带宽 1.63/1.68 GB/s vs 0.81/0.84 GB/s）。`scripts/05-pcie-gen2.sh` 会装一个
  开机自动重训的服务。
- GSP 固件日志在本机不可用（安装包无 `gsp_log_*.bin`）。
- 本卡 PCIe 插槽电气 x4，Gen2 下 ~1.7 GB/s 已是上限；要更高需 x8/x16 插槽。

---

## 10. 目录结构

```
cmp170hx-6d-upgrade/
├── README.md
├── docs/
│   ├── en/                   # 逐步操作文档（英文）
│   └── zh-CN/                # 逐步操作文档（中文）
├── scripts/                  # 可执行脚本（不自动重启）
│   ├── 00-check-host.sh
│   ├── 01-driver.sh
│   ├── 02-build.sh
│   ├── 03-payload.sh
│   ├── 03-make-payload.py    # payload 生成器（校验 + 只取 bank1）
│   ├── 04-install.sh
│   ├── 05-pcie-gen2.sh
│   ├── 06-set-mclk.sh
│   ├── 98-rollback.sh
│   └── 99-verify.sh
├── patches/                  # 相对上游 vix-loader / cmpunlocker 的本地补丁
│   ├── 0001-vix-loader-accept-first-legacy-image.patch
│   └── 0002-hbm-pll-ndiv-overclock.patch
└── config/                   # modprobe / systemd 模板
```

---

## 11. 来源与致谢

- [amoghmunikote/cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) —— 驱动解锁
- [Panchovix/nvidia-linux-vbios-vix-loader](https://github.com/Panchovix/nvidia-linux-vbios-vix-loader) ——
  VBIOS 内存覆盖（含 @pantsoftime 的 `vbios_override` 原始补丁）
- [asm64-hooligan/cmpunlocker](https://github.com/asm64-hooligan/cmpunlocker/tree/mem_overclock) ——
  HBM 时钟（FBPA PLL NDIV）思路与寄存器常量
- [promisezackr/cmp170hx-ga100-300w-vbios](https://github.com/promisezackr/cmp170hx-ga100-300w-vbios) ——
  300 W VBIOS 资料
- TechPowerUp VBIOS Database —— `92.00.6D.00.0A` dump 来源

本仓库只包含我们自己的补丁、脚本与文档；不含 NVIDIA 专有源码或 VBIOS 二进制。

---

## 12. 免责声明

修改显卡固件行为（功耗上限、频率、显存几何）有风险：可能不稳定、报错、损坏数据甚至
硬件损伤。请自行评估并保留回滚手段。本仓库的所有改动都在**内存/驱动层**，EEPROM
不写、nvflash 不用；但**不要**在未备份的情况下自行刷写 VBIOS。
