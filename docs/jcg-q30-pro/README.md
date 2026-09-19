# JCG Q30 Pro / Q30 刷机与救砖资料

本目录记录把自编译的 ImmortalWrt（OpenWrt U-Boot 2025.10 + fit 布局）
刷入 JCG Q30 Pro / Q30 的完整过程，以及踩过的全部坑与解决办法。

| 文件 | 面向 | 内容 |
|---|---|---|
| [HUMAN-GUIDE.md](HUMAN-GUIDE.md) | 人 | 硬件/软件准备、10 步刷机流程、配置、三层救砖手段、问题解决大表、名词解释 |
| [AI-CONTEXT.md](AI-CONTEXT.md) | AI | 设备与分区事实、产物哈希、U-Boot 环境变量语义、命令序列、诊断决策树、反模式、验收清单 |
| [RECOVERY-SLIM-PLAN.md](RECOVERY-SLIM-PLAN.md) | 方案 | 精简 recovery 镜像（29MB → 9.0MB，解包 95MB → 20.5MB）：包清单、构建脚本、集成方式、失败记录与实测数据 |

## 一句话结论

- 入口：`mtk_uartboot`（BROM 级，万能）> 串口 3 秒菜单 > U-Boot 网页（不可靠）
- 布局：FIT **必须**在名为 `fit` 的 UBI 卷里（内核据此生成 `/dev/fit0`）
- 通常**只换 `fip` 分区**即可（BL2 保留，少写一次少一层风险）
- U-Boot 里 `mtd` 的数字参数是**十六进制**，一律用 `$filesize`
- 刷完必须用 `run boot_production` 再启动一次，否则没有 overlay（只读系统）
- 「按住 reset」救砖必须配 **精简 recovery**（9.0MB）：`bash scripts/build-recovery-slim.sh`

## 硬件

MT7981B + DDR3 256MB（Nanya NT5CC128M16JR-EK）+ Winbond 128MB SPI-NAND + MT7531 交换芯片，
串口 115200 8N1 3.3V（焊盘空焊，需探针/飞线）。
