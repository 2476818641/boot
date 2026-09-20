# ImmortalWrt MT798x · JCG Q30 Pro / Q30 · 硬刷方案

面向 **MediaTek MT7981** 平台的自编译 ImmortalWrt 分支，主力机型 **JCG Q30 Pro / Q30**
（同一块板，兼容 CMCC MR3000D-CIq），集成**校园网 UA3F 防检测**所需组件
（UA 改写 + L3 重写：TTL / IPID / TCP 时间戳 / TCP 初始窗口 + Desync）。

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
| 关键组件 | **`UA3F 3.6.0`**（高级 HTTP(S) 重写代理：UA 改写 + L3 重写 TTL/IPID/TCP 时间戳/初始窗口 + Desync，LuCI 在「服务 → UA3F」）；mtwifi 私有驱动；HNAT 硬件加速；mwan3 / passwall / smartdns / turboacc-mtk |
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

### 常见问题：从原厂系统装这个版本，还要不要走"别人的跳板"？

看机器现在是什么状态，分三种情况：

| 现在的状态 | 要不要跳板 | 怎么做 |
|---|---|---|
| **已经是本方案的引导**（OpenWrt U-Boot + `fit` 卷，也就是已经刷过本固件） | **完全不用**，串口和 TFTP 都不用 | LuCI → 系统 → 备份/刷写固件，直接上传 `*-squashfs-sysupgrade.itb`（sysupgrade 会自己写 `fit` 卷） |
| **原厂系统，或别人的旧布局**（`kernel` + `rootfs` 卷） | **不需要别人的跳板** —— 但**必须换引导**，这一步只能靠串口 | 走本 README 的"硬刷四步"：CH340 串口 + `mtk_uartboot`（BROM 级，工具全公开）灌入我们的 U-Boot → `mtd write fip` → 建 `fit` 卷 → 写固件。全程不依赖任何第三方固件 |
| **原厂系统，且坚决不动串口焊盘** | **才需要"跳板"**：先刷一个能过原厂校验的第三方固件/U-Boot，拿到能写 flash 的环境 | 但要注意：跳板的 U-Boot（`kernel`/`rootfs` 布局）**跑不了我们的固件**（`wrong file` 或卡 `Waiting for root device /dev/fit0`），所以跳完仍然要**把引导换成我们的**（写 `fip`）。若那个跳板是网页 U-Boot 且支持上传 bootloader/fip，可能不用串口；**这条路本仓库没有实测过**（我们只验证过：它拒绝我们的 sysupgrade 镜像） |

结论：

- **一次硬刷，之后永远软刷。** 换引导只写 `fip`（BL2/preloader 一般完好不动），写完这台机器以后所有升级都是 LuCI 一键，不再需要串口、也不需要任何跳板。
- **"硬刷"不等于"走别人的跳板"**：本方案的硬刷是 BROM 级自举（`mtk_uartboot` 把 U-Boot 灌进内存），这个能力正是它敢硬刷的底气 —— BL2/U-Boot 全坏也能救回来。
- 想在原厂系统里 `mtd write` 免拆换引导，需要先拿到原厂 shell（默认 telnet/漏洞之类），**本仓库没验证过**，而且引导写坏就直接变砖（最后还是得 BROM 救）—— 不如一开始就上串口。

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
进系统后：`passwd` 设密码 → **服务 → UA3F → 启用**。

> **只换 `fip`，通常不写 `bl2`**：BL2 一般完好，少写一次少一层风险。
> 写 `bl2` 前请确认 DDR 类型（本机为 DDR3）。

---

## ☁️ 云端编译（GitHub Actions）—— 不需要本地环境

**修改配置 → 云端出固件**，适合没有 Linux 编译环境的用户。

### 用法

1. **Fork** 本仓库（或在本仓库直接改）
2. 在网页上编辑 **`.config`**（例如换机型、加减包）。注：UA 串不用改 .config —— UA3F 是运行时在
   「服务 → UA3F」里配的
3. 提交后 **自动开始编译**（改动 `.config` / `feeds.conf` 会触发）；也可以去
   **Actions → Build ImmortalWrt (JCG Q30 Pro / Q30) → Run workflow** 手动触发
4. 约 **3~5 小时**后（含精简 recovery 的第二遍编译），在该次运行的 **Artifacts** 里下载，
   或在 **Releases** 里下载（默认会发 Release）

### 触发方式

| 方式 | 说明 |
|---|---|
| 改 `.config` / `feeds.conf` / 精简脚本并提交到 `main` | 自动编译 |
| Actions 页面 → Run workflow | 手动编译（可填 tag、可选是否发 Release）|
| 推送 `v*` tag | 编译并发布 |

### CI 环境的特殊处理（无需你操作，工作流自动做）

- **临时移除镜像补丁**：`scripts/download.pl` 里的 ghproxy 改写、`feeds.conf` 的镜像地址会在 CI 里被替换为**直连 GitHub** ——
  GitHub runner 在海外，直连比镜像快几十倍（实测镜像仅 61 KB/s）
- **释放磁盘空间**：删掉 runner 上无用的 Android/dotnet 工具链，腾出 ~25GB 供编译
- **缓存 `dl/`**：源码包缓存复用，第二次构建显著加快
- **自动产出精简 recovery**：正式构建后追加一遍 `scripts/build-recovery-slim.sh --slim-only`（复用工具链，
  +20~40 分钟），把 29MB 原版 recovery 换成 **9.0MB 精简版**并重建 `sha256sums`，
  工作流还会校验体积（>12MB 直接判失败）
- **防静默丢包**：工作流在 `feeds update/install` 前后备份并还原 `.config`（否则被 `refresh_config`
  里的 defconfig 吃掉），再用 `scripts/check-package-selection.sh` 在 `make defconfig` 之后和产物出来后
  各查一次（对照 `scripts/required-packages.txt`），缺 `ua3f` 等关键包**直接让构建失败**，
  而不是发一个没有防检测功能的固件
- **编译失败时**自动上传 `build.log` 与 `logs/` 供排查

> ⚠️ **重要：`scripts/feeds update -a` 会静默改写 `.config`（云端构建因此丢过 ua2f，当时的 UA 方案）。**
> 这个命令结尾会调用 `refresh_config()`，也就是偷偷跑一次 `make defconfig`；而全新检出里
> `package/feeds/` 还不存在（被 .gitignore 忽略），于是**所有"来自 feed 的已选包"被静默删掉
> （380 → 292）**，之后 `feeds install` 和正式 `make defconfig` 都救不回来。
> 2026-09-19 的第一次云端构建（release `build-20260919-0910`）就是这样发了一个**没有 `ua2f`** 的固件，
> 而工作流一路绿灯（同 .config 本地编译是 352 个包 / 33.9MB，云端只有 299 个包 / 19.0MB）。
>
> 现在工作流已在 feeds 步骤前后备份/还原 `.config`，并用 `scripts/check-package-selection.sh`
> 把"丢包"变成硬失败（defconfig 之后 + 产物 manifest 之后各查一次）。
> 自己下固件后也可以核对：`grep '^ua3f ' *.manifest`。
>
> 提示：本仓库只存源码，CI 需要完整跑一次工具链 + 378 个包，首次较慢属正常。

---

## 编译（本地：自己出固件）

**默认就是一条命令 —— 它一次产出正式固件 + 精简 recovery**（详细说明见
[docs/jcg-q30-pro/RECOVERY-SLIM-PLAN.md](docs/jcg-q30-pro/RECOVERY-SLIM-PLAN.md)）：

```bash
export FORCE_UNSAFE_CONFIGURE=1          # root 身份编译必需，否则 tools/tar 会失败
export GOPROXY=https://goproxy.cn,direct # UA3F 是 Go 项目：proxy.golang.org 国内不通
bash scripts/build-recovery-slim.sh      # 正式构建 → 精简 recovery → 汇总到 recovery-slim-out/
# 只想重做精简 recovery（正式产物已在）：bash scripts/build-recovery-slim.sh --slim-only
```

首次编译约 1~2 小时。⚠️ 不要只用裸 `make -j$(nproc)` 就收工：那样产出的 recovery 是 29MB 原版，
在 256MB 内存上**必然 OOM**（本脚本会用 9.0MB 精简版覆盖它）。

产物在 `bin/targets/mediatek/filogic/`，脚本另外汇总一份可直接丢进 TFTP 目录的到 `recovery-slim-out/`：

| 文件 | 大小 | 用途 |
|---|---|---|
| `...-squashfs-sysupgrade.itb` | 33866011 | 正式固件 → 写 `fit` 卷（或 LuCI 升级）|
| `...-initramfs-recovery.itb` | 9437184 | 内存系统，**已是精简版**（原版 29MB 解包 ~95MB → OOM；精简版解包仅 20.5MB）|
| `...-bl31-uboot.fip` | 1073444 | U-Boot 本体 → 写 `fip` 分区 |
| `...-preloader.bin` | 230232 | BL2 → 写 `bl2` 分区（通常不用）|
| `mt7981-ram-ddr3-bl2.bin` | 210368 | **给 mtk_uartboot 的 RAM BL2**（不是 preloader！）|

sha256：

```
89c93f384470bfa7abecb16d62637dd8d5c3dd44deff11631db4660fd7c23f4f  ...-squashfs-sysupgrade.itb
33bcb1f709fcc27599bb69b49a802288a61750973117f7e28ef0b87572ed3553  ...-initramfs-recovery.itb   （精简版）
f06f684fe85b6ec1279c55b042f9143d40bbd848f3005b8af7562f6ddb4f9de3  ...-bl31-uboot.fip
bf9724f7eb8c0ddddf1f8fc9d6c104d892c09621125ada137ca6b7447543cc7d  ...-preloader.bin
9e5431cce4ec06afde6bf216c8d31fdfa1b8ef3443aa6c86523ad22a1a12b059  mt7981-ram-ddr3-bl2.bin
```

> ⚠️ 上面是**本地这次构建**的校验值。`fip` / `preloader` / RAM-BL2 / 内核里内嵌了编译时间戳
> （`strings bl2 | grep Built` → `Built : 08:30:16, Sep 19 2026`），所以**你重新编译后哈希会变**，
> 体积基本不变；**云端（GitHub Actions）编出来的哈希也一定与这里不同**（同样的字节数、不同的 sha256）。
> 判断文件对不对看体积 + 来源，校验一律以**你下载的那个 Release 里的 `sha256sums`**（或自己构建目录里的
> `sha256sums`）为准。

---

## 仓库内容说明

**本仓库只放源码与构建配方，不含任何编译产物。**

- ✅ 包含：完整 ImmortalWrt 源码树（已导入 MTK mt798x feeds）、`.config`（构建配方）、`feeds.conf`、镜像补丁、`docs/`、精简 recovery 构建脚本
- ❌ 不含：`bin/` `build_dir/` `staging_dir/` `dl/` `tmp/` `logs/` `feeds/` `*.itb` `*.ipk` `build.log`、任何密钥

### 相关仓库（校园网登录那套脚本**不在本仓库**）

固件之外的"上网辅助"工具单独放，避免和编译/刷机内容混在一起：

| 仓库 | 内容 |
|---|---|
| [2476818641/Login-edu](https://github.com/2476818641/Login-edu) | 校园网登录/认证工具集。目前含 `openwrt/` 两个脚本：主脚本 `campus-net-setup.sh`（配置 MAC 克隆 / TTL / MTU / UA + PPPoE 拨号，不做认证）、认证脚本 `campus-portal-auth.sh`（按抓包生成，`--install-hook` 装开机自动认证）；另有抓包清单与使用文档 |

---

## 救砖三层保险

| 手段 | 用法 | 适用 |
|---|---|---|
| **3 秒启动菜单** | 上电按任意键 → `0. Exit` 进命令行 | 日常首选 |
| **菜单写 NAND** | `5` 写正式固件 / `6` 写 recovery / `7` 写 FIP / `8` 写 BL2 | 不想敲命令 |
| **mtk_uartboot** | 本 README「快速开始」第 1 步 | **终极保命**，BL2/FIP 全坏也能救 |

⚠️ **「按住 reset」救砖用的是编译产物里的精简 recovery，不是原版 29MB**：

OpenWrt 默认让 recovery 与正式固件共用同一套包（本仓库 380 个）→ 29MB、解包 ~95MB，
本机 256MB 内存**必然 OOM**，会陷入「启动 → 崩溃 → 再启动」循环并反复写 NAND。
本仓库的默认构建（`bash scripts/build-recovery-slim.sh`）已经把 recovery 换成
**9.0MB 精简版**（只含 44 个包，解包仅 20.5MB），无需额外操作。

把产物里的 `...-initramfs-recovery.itb` 放进 TFTP 目录，即可：
**按住 reset → U-Boot 自动 TFTP 拉取 → 进内存系统 → 浏览器刷固件（全程不需要串口）**。
进系统后可用 `free -m` 自检（期望 ≥150MB 可用）。

详见 [docs/jcg-q30-pro/RECOVERY-SLIM-PLAN.md](docs/jcg-q30-pro/RECOVERY-SLIM-PLAN.md)。

---

## 上游与致谢

- 源码基线：[ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 25.12.4 + [MTK OpenWrt Feeds](https://git01.mediatek.com/plugins/gitiles/openwrt/feeds/mtk-openwrt-feeds/)
- 本仓库的 rebase 依托：[chasey-dev/immortalwrt-mt798x-rebase](https://github.com/chasey-dev/immortalwrt-mt798x-rebase)
- 外部设备 HNAT 支持移植自 [Padavanonly's repo](https://github.com/padavanonly/immortalwrt-mt798x-6.6)
- BROM 恢复工具：[981213/mtk_uartboot](https://github.com/981213/mtk_uartboot)
- UA3F（当前使用）：[SunBK201/UA3F](https://github.com/SunBK201/UA3F) —— 前身是 [Zxilly/UA2F](https://github.com/Zxilly/UA2F)，本方案已从 UA2F 换成 UA3F（UA2F 只做 UA 改写，UA3F 多了 L3 重写与 Desync）

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
