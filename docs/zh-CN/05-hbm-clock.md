# 05 — HBM 显存超频（FBPA PLL NDIV）

[English](../en/05-hbm-clock.md) | **简体中文**

## 1. 原理

CMP 170HX 的 HBM 时钟来自 **FBPA PLL**：

```
HBM 时钟 = NDIV × 27 MHz
```

- 原厂 67 VBIOS：Booter/FMC 训练在 **NDIV=54 → 1458 MHz**
- 6D VBIOS：训练在 **NDIV=64 → 1728 MHz**

驱动侧改写 PLL 的 COEFF 寄存器（NDIV 在 bits [15:8]，MDIV/PDIV 保持不动），
就能让显存在不改 VBIOS 的情况下跑新频率。

## 2. 关键寄存器

| 寄存器 | 含义 |
|---|---|
| `0x00903c98` | FBPA0 PLL COEFF（NDIV bits[15:8]） |
| `0x00903c90` | PLL CFG（bit5 = lock） |
| `0x00903c7c/80/84` | FBPA PLL0/1/2 PLM（写 `0xffffffff` 打开访问） |
| `0x0098bc98` | 多播 COEFF（一次写给所有 FBPA） |
| `0x001211fc` | PRI fence（写 0 刷新） |
| `0x009a0590` | MEMCLK_CHANGE_ALERT（bit31） |
| `0x009a031c` | HBM 自刷新控制 |
| `0x009a11dc` | DDLL 控制（bit6 触发校准） |
| FBPA 基址 | `0x900000` + idx × `0x4000`，共 12 槽（本 SKU 激活 8 个） |

## 3. 两条路径，只有 post-GSP 有效

模块里实现了两条写入路径：

**pre-GSP（SEC2 阶段）**：PLM 打开 → self-refresh → 逐 FBPA 改 COEFF → DDLL → 清 alert。
实测：寄存器确实写进去了、`nvidia-smi` 也读得到新 NDIV，**但带宽不变**（卡在 ~1387 GB/s）。
说明 Booter/GSP 后续初始化时内存控制器仍按原训练速率工作，pre-GSP 的写入没有真正
落到数据通路。

**post-GSP（GSP 启动之后）**：多播 COEFF + **PRI fence** + 轮询 lock → 实测 `lock=1`，
带宽立刻到位（1387 → 1826 GB/s）。这是本方案实际使用的路径。

日志示例（成功）：

```
NVRM: HBMPLL_OC: post-GSP PRE: COEFF=0x00014601(NDIV=70) PLM=0xffffffdf devid=0x20c2 vbios=92.00.67.00.01 newCOEFF=0x00014601
NVRM: HBMPLL_OC: post-GSP POST: COEFF=0x00014601(NDIV=70) CFG=0x8000092d lock=1 iter=0
```

## 4. 设置频率

registry 键 `RmHbmPllNdiv`（30–80），写在 `90-cmp-vbios-override.conf` 的
`NVreg_RegistryDwordsPerDevice` 里，**改值后需要重启生效**：

```bash
sudo bash scripts/06-set-mclk.sh 64    # 1728 MHz（6D 原厂同频，推荐）
sudo bash scripts/06-set-mclk.sh 70    # 1890 MHz（超频）
sudo bash scripts/06-set-mclk.sh --off # 关掉（回到训练值 1458）
```

重启后：

```bash
nvidia-smi --query-gpu=clocks.current.memory --format=csv,noheader
# 1728 MHz 或 1890 MHz
sudo dmesg | grep HBMPLL_OC | tail -3
```

## 5. NDIV 选值（8 GB 卡）
多卡时该键必须出现在每个 `pci=` 作用域里，`scripts/06-set-mclk.sh` 会自动处理。稳定性要
**逐卡验证**：不同卡体质不同，可能需要不同的 NDIV 值。



| NDIV | 显存 | 建议 |
|---|---|---|
| 54 | 1458 | 原厂训练值；不稳定时的回退档 |
| 64 | 1728 | **6D 原厂同频，推荐** |
| 70 | 1890 | 本卡实测稳定；上游称约 60% 的 8 GB 卡可行 |
| 73 | 1971 | 只有“体质好”的卡才稳，谨慎 |
| 30–53 | <1458 | 降频（降压/排查用） |

## 6. 稳定性验证（必须做）

```bash
sudo bash scripts/99-verify.sh --stress 120
```

脚本会：

1. 连续跑同一 fp16 matmul，**逐位比较结果**（不一致 = 显存出错）
2. 采样功耗/温度/SM 时钟
3. 检查 `nvidia-smi -q -d ECC` 的 DRAM Correctable/Uncorrectable
4. 检查 dmesg 是否出现 Xid

合格标准：**0 mismatch、ECC 0/0、Xid 0**。

本卡 1890 MHz 实测：9499 次 0 mismatch、ECC 0/0、Xid 0、功耗 245–251 W、59–63 °C。

## 7. 常见现象

| 现象 | 说明 |
|---|---|
| `nvidia-smi` 显存显示新频率，但带宽不变 | 只有 pre-GSP 路径生效（检查 `lock=1` 日志） |
| `DDLL cal status 0x00000000` | GA100 上这两个状态寄存器可能无效；不影响 post-GSP 结果 |
| 带宽测试抖动 | 功耗墙/温度墙；锁频或降 NDIV |
| 出现 Xid / ECC 非 0 | 不稳定，降一档 NDIV |
