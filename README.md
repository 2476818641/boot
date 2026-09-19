# ImmortalWrt MT798x · JCG Q30 Pro / Q30 · 硬刷方案

面向 **MediaTek MT7981** 平台的自编译 ImmortalWrt 分支，主力机型 **JCG Q30 Pro / Q30**
（同一块板，兼容 CMCC MR3000D-CIq），集成**校园网 UA2F 防检测**所需组件。

> ## ⚠️ 本项目为「硬刷方案」
>
> 需要 **USB-TTL 串口**，通过 **BROM（`mtk_uartboot`）→ U-Boot → TFTP** 手动写入引导与固件。
>
> - **不依赖**云端 CI，**不需要**旧版网页 U-Boot，**引导写坏也能救回来**（BROM 级恢复）
> - 之所以必须硬刷：本方案使用 **OpenWrt U-Boot + `fit` 布局**，与外厂/hanwckf 系旧引导的
>   卷布局**不兼容** —— 网页刷机会报 `wrong file`，软刷（LuCI）会卡 `Waiting for root device /dev/fit0`
> - **刷完之后**的日常升级是软刷：LuCI → 系统 → 备份/刷写固件（会自动写入 `fit` 卷）
>
> 完整流程见下方文档，**动手前请先读**。

---

## 当前版本

| 项目 | 值 |
|---|---|
| 发行版 | ImmortalWrt **25.12-SNAPSHOT**（banner 代号 `Dave's Guitar`）|
| 版本号 | **r38026-5e20cf34aa** |
| 内核 | Linux **6.12.87** |
| 引导 | OpenWrt U-Boot **2025.10-ImmortalWrt-r38026-5e20cf34aa** |
| 目标 / 机型 | `mediatek` / `filogic` / **`jcg_q30-pro`** |
| 兼容机型 | `jcg,q30-pro`、`jcg,q30`、CMCC `MR3000D-CIq`（同一镜像）|
| 包管理器 | **apk**（OpenWrt 25.x 起由 opkg 切换）|
| 选中包数 | **380** |
| 关键组件 | `ua2f 4.10.2` + 官方 JS 版 `luci-app-ua2f` + 中文界面；mtwifi 私有驱动；HNAT 硬件加速；mwan3 / passwall / smartdns / turboacc-mtk |
| flash 布局 | UBI 卷：`fit`（正式固件）/ `rootfs_data`（overlay）/ `ubootenv`、`ubootenv2` |

### 上游切点

| 来源 | 提交 |
|---|---|
| ImmortalWrt | [`e660cbc`](https://github.com/immortalwrt/immortalwrt/commit/e660cbc917924389164967211777106020b3cd56) — OpenWrt 25.12.4 |
| MTK OpenWrt Feeds | [`9372bc8`](https://git01.mediatek.com/plugins/gitiles/openwrt/feeds/mtk-openwrt-feeds/+/9372bc8b1266463da068e5e9a59136d91fd004fb) |
| l1parser | [`081bb31`](https://github.com/chasey-dev/l1parser/commit/081bb31211efc74594d25bfd1bb5811f3408a205) |
| 本分支基线 | [`chasey-dev/immortalwrt-mt798x-rebase`](https://github.com/chasey-dev/immortalwrt-mt798x-rebase)（MTK mt798x feeds 已导入）|

---

## 📖 文档

| 文档 | 面向 | 内容 |
|---|---|---|
| **[docs/jcg-q30-pro/HUMAN-GUIDE.md](docs/jcg-q30-pro/HUMAN-GUIDE.md)** | **人** | 需要准备什么 → 10 步刷机流程 → 刷完的配置 → 三层救砖手段 → **踩过的坑与解决办法大表** → 名词解释 → 日常维护 |
| **[docs/jcg-q30-pro/AI-CONTEXT.md](docs/jcg-q30-pro/AI-CONTEXT.md)** | **AI** | 设备/分区/产物哈希、U-Boot 环境变量语义、两套已验证命令序列、按症状索引的诊断决策树、恢复矩阵、反模式清单、验收清单 |
| [docs/jcg-q30-pro/README.md](docs/jcg-q30-pro/README.md) | 索引 | 两份文档入口 + 一句话结论 |

> 实操经验全部来自真机（两台 JCG Q30 Pro / Q30 完整走通），包括 15 个真实踩坑与解决办法。

---

## 硬件要求

| 部件 | 规格 |
|---|---|
| SoC | MediaTek **MT7981B**（2×Cortex-A53 @1300MHz）|
| 内存 | **DDR3 256MB**（Nanya NT5CC128M16JR-EK，1866Mbps）|
| 闪存 | **SPI-NAND 128MB**（Winbond，块 128KiB / 页 2048 / OOB 64）|
| 交换芯片 | MT7531（DSA，lan1~lan3 + wan）|
| 串口 | **115200 8N1、3.3V**（板上为空焊盘，需探针或飞线）|

**刷机工具**：CH340 USB-TTL（3.3V）、`mtk-uartboot-qt.exe`、Tftpd64（TFTP 服务器）、串口终端

---

## 为什么必须硬刷（一图说明布局差异）

```
外厂 / hanwckf 旧引导布局：   UBI: kernel(FIT) + rootfs + rootfs_data
本方案（OpenWrt U-Boot）布局：UBI: fit(FIT) + rootfs_data + ubootenv(2)
                                    ↑
        内核按「卷名」生成 /dev/fit0，卷名不是 fit 就永远等不到根文件系统
```

因此：

| 错误做法 | 现象 |
|---|---|
| 用旧网页 U-Boot 刷本镜像 | `Something went wrong during update … chosen wrong file` |
| 在旧引导上用 LuCI 软刷本镜像 | 刷写成功但启动卡 `Waiting for root device /dev/fit0…`，无限重启 |
| 把 FIT 写进 `kernel` 卷 | 同上 |

**正确顺序**：换引导（写 `fip`）→ 建 `fit` 卷 → 启动 → 之后才可以用 LuCI 软刷。

---

## 快速开始（硬刷四步，详见 HUMAN-GUIDE）

```bash
# 0) 电脑：有线网卡静态 192.168.1.254/24，Tftpd64 根目录放产物，防火墙放行（专用+公用）
#    接线：CH340 只接 GND / TX / RX（VCC 永不接），网线接路由器 LAN 口

# 1) BROM 灌入 U-Boot（BL2/U-Boot 全坏也能用；先跑命令，再给路由器上电）
mtk-uartboot-qt.exe -s COM7 -p mt7981-ram-ddr3-bl2.bin -a \
    -f immortalwrt-mediatek-filogic-jcg_q30-pro-bl31-uboot.fip --debug

# 2) 3 秒启动菜单 → 按任意键 → 选 "0. Exit" 进 U-Boot 命令行
ubi part ubi
ubi info l                 # 看清卷名，再决定删哪个
ubi remove kernel          # 腾空间（旧布局残留；绝不要删 ubootenv / ubootenv2）

# 3) 写引导到 flash（⚠️ mtd 的数字参数是十六进制，一律用 $filesize）
tftpboot 0x46000000 immortalwrt-mediatek-filogic-jcg_q30-pro-bl31-uboot.fip
mtd erase fip
mtd write fip 0x46000000 0 $filesize
mtd read fip 0x47000000 0 $filesize
cmp.b 0x46000000 0x47000000 $filesize      # 期望 Total of ... were the same

# 4) 写固件到 fit 卷 → 启动 → 再正常启动一次（关键：这样才会创建 overlay）
ubi part ubi
setenv replacevol 1
run boot_tftp_production
run boot_production
```

启动成功标志：**双蓝灯** + 浏览器 `192.168.1.1` 可访问。
进系统后：`passwd` 设密码 → **网络 → UA2F → 启用**。

> **只换 `fip`，通常不写 `bl2`**：BL2 一般完好，少写一次少一层风险。
> 写 `bl2` 前请确认 DDR 类型（本机为 DDR3）。

---

## 编译（可选：自己出固件）

```bash
# 依赖与 feeds 见 .config / feeds.conf（feeds 走镜像加速）
export FORCE_UNSAFE_CONFIGURE=1        # root 身份编译必需，否则 tools/tar 会失败
make -j$(nproc) V=s
```

产物在 `bin/targets/mediatek/filogic/`：

| 文件 | 大小 | 用途 |
|---|---|---|
| `...-squashfs-sysupgrade.itb` | 33866011 | 正式固件 → 写 `fit` 卷（或 LuCI 升级）|
| `...-initramfs-recovery.itb` | 29360128 | 内存系统（⚠️ 本机 256MB 内存会 OOM，不建议用）|
| `...-bl31-uboot.fip` | 1073444 | U-Boot 本体 → 写 `fip` 分区 |
| `...-preloader.bin` | 230232 | BL2 → 写 `bl2` 分区（通常不用）|
| `mt7981-ram-ddr3-bl2.bin` | 210368 | **给 mtk_uartboot 的 RAM BL2**（不是 preloader！）|

sha256：

```
89c93f384470bfa7abecb16d62637dd8d5c3dd44deff11631db4660fd7c23f4f  ...-squashfs-sysupgrade.itb
569936a52dfc54eb7194fbe0d145808fe3ecc40cbfffc167dc48b48c7a88f8ee  ...-initramfs-recovery.itb
f06f684fe85b6ec1279c55b042f9143d40bbd848f3005b8af7562f6ddb4f9de3  ...-bl31-uboot.fip
bf9724f7eb8c0ddddf1f8fc9d6c104d892c09621125ada137ca6b7447543cc7d  ...-preloader.bin
bdb2493e36a169c652875529ee7d1e8ee7f1f064d5fa526fde36a1980676df35  mt7981-ram-ddr3-bl2.bin
```

---

## 仓库内容说明

**本仓库只放源码与构建配方，不含任何编译产物。**

- ✅ 包含：完整 ImmortalWrt 源码树（已导入 MTK mt798x feeds）、`.config`（构建配方）、`feeds.conf`、镜像补丁、`docs/`
- ❌ 不含：`bin/` `build_dir/` `staging_dir/` `dl/` `tmp/` `logs/` `feeds/` `*.itb` `*.ipk` `build.log`、任何密钥

---

## 救砖三层保险

| 手段 | 用法 | 适用 |
|---|---|---|
| **3 秒启动菜单** | 上电按任意键 → `0. Exit` 进命令行 | 日常首选 |
| **菜单写 NAND** | `5` 写正式固件 / `6` 写 recovery / `7` 写 FIP / `8` 写 BL2 | 不想敲命令 |
| **mtk_uartboot** | 本 README「快速开始」第 1 步 | **终极保命**，BL2/FIP 全坏也能救 |

⚠️ **不要用「按住 reset」救砖**：本机 256MB 内存跑 29MB 的 recovery initramfs 必然 OOM，
会陷入「启动 → 崩溃 → 再启动」循环，还会反复写 NAND。

---

## 上游与致谢

- 源码基线：[ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 25.12.4 + [MTK OpenWrt Feeds](https://git01.mediatek.com/plugins/gitiles/openwrt/feeds/mtk-openwrt-feeds/)
- 本仓库的 rebase 依托：[chasey-dev/immortalwrt-mt798x-rebase](https://github.com/chasey-dev/immortalwrt-mt798x-rebase)
- 外部设备 HNAT 支持移植自 [Padavanonly's repo](https://github.com/padavanonly/immortalwrt-mt798x-6.6)
- BROM 恢复工具：[981213/mtk_uartboot](https://github.com/981213/mtk_uartboot)
- UA2F：[Zxilly/UA2F](https://github.com/Zxilly/UA2F)

### 外部设备 HNAT 说明（沿用上游）

> [!WARNING]
> Current HNAT support for external devices is basic and lack of complete test for various types. Please use with caution.

> [!IMPORTANT]
> Please keep interface `rxppd` in your bridge device (e.g. `br-lan`) while using external device HNAT.

| | Ext as WAN | Ext as LAN |
| :---: | :---: | :---: |
| **Ethernet** | ✔️ | ❌ |
| **AP/ApCli** | ✔️ | ⚠️(Untested) |

---

## 免责声明

刷机（尤其是写 `bl2` / `fip` 引导分区）存在变砖风险。请先完整阅读
[docs/jcg-q30-pro/HUMAN-GUIDE.md](docs/jcg-q30-pro/HUMAN-GUIDE.md)，
准备好串口与 `mtk_uartboot` 保命手段后再动手。因操作不当造成的任何损失由操作者自行承担。
