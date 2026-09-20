# 精简 recovery 镜像 —— 方案与实施记录

> 状态：**已实施并集成进默认构建**，`make` / CI 产出的 `-initramfs-recovery.itb` 已经是精简版；
> **待真机 TFTP 实测**（编译产物已核对：9.0MB / 解包 20.5MB / 117 包）
> 相关文件：`scripts/build-recovery-slim.sh`、`scripts/recovery-slim-packages.txt`

目标：把 `-recovery.itb` 从 **29MB（解包约 95MB）** 降到 **9.0MB（解包 20.5MB）**，
让 256MB 内存的机器也能跑起来，从而恢复「按住 reset 就能救砖」这条最省事的路径。

---

## 0. 怎么编译（默认就是精简的）

```bash
cd /root/immortalwrt-mt798x-rebase
export FORCE_UNSAFE_CONFIGURE=1

bash scripts/build-recovery-slim.sh              # 默认：正式构建 → 精简 recovery → 装配产物集
bash scripts/build-recovery-slim.sh --slim-only  # 正式产物已存在，只重做精简 recovery（CI 走这条）
```

脚本做的事（**源码树零修改，rebase 上游零冲突**）：

1. 备份 `.config` → `.config.production`（并装 `trap`，失败 / Ctrl-C 也会自动还原）
2. 【默认模式】`make` 正式构建，把 `bin/targets/.../` 里除 recovery、`sha256sums` 外的产物先存起来
   然后检查这份「正式固件」的大小：**小于 20MB 直接拒绝继续**（那说明它其实是精简配置编出来的，
   正常 380 包配置约 33.9MB；确实要硬来就加 `FORCE_SLIM_OK=1`）
3. 按 `scripts/recovery-slim-packages.txt`（44 项保留清单）生成 `.config.slim`，`make defconfig` 自动补齐依赖
4. 切到精简配置再 `make`（复用工具链与 `dl/` 缓存；world —— **本树没有 `image` 目标**）
5. 装配最终产物：正式固件/fip/preloader 放回，**精简 recovery 覆盖同名文件**，重建 `sha256sums`
6. 汇总到 `recovery-slim-out/`：`recovery-slim.itb`、`recovery-slim.manifest`、其余产物 + `sha256sums`
7. 还原正式 `.config`

冒烟自测（不编译，只验证逻辑与配置生成）：

```bash
sh -n scripts/build-recovery-slim.sh               # 语法
bash scripts/build-recovery-slim.sh --help         # 用法
```

---

## 1. 问题：为什么原来的 recovery 用不了

| 项 | 现状 |
|---|---|
| `...-initramfs-recovery.itb` | **29,360,128 字节** |
| 它包含什么 | 和正式固件**同一套 380 个包**（initramfs 就是把整套 rootfs 塞进内存）|
| 解包后占用 | **约 95MB**（实测内核报 `shmem:97564kB`）|
| 结果 | init 阶段 OOM：`cp invoked oom-killer` → `Kernel panic - not syncing: System is deadlocked on memory` |
| 连带后果 | ① reset 键恢复不可用 ② TFTP 兜底循环拉到它就 panic ③ panic 在 ramoops 留下记录 → `bootcmd` 的 `pstore check` 被劫持 → 启动死循环（还要 `setenv bootcmd 'run boot_ubi'` 才能修） |

**内存账（256MB）**：内核+保留 ≈48MB，initramfs 解包 ≈95MB，剩下的还要给 tmpfs `/tmp` 和服务 →
不够，必然 OOM。

---

## 2. 目标与验收标准

| 指标 | 目标值 | 实测 |
|---|---|---|
| 镜像大小 | ≤ 12MB | ✅ 9.0MB |
| 解包占用 | ≤ 35MB | ✅ 20.5MB |
| 启动后可用内存 | ≥ 120MB（`free` 实测） | ⏳ 待真机验证 |
| 必须能做的事 | ① 串口控制台 ② LAN 起网（192.168.1.1）③ **网页/SSH 刷固件** ④ 写 `fit` 卷 ⑤ 写 `fip` 分区 | ✅ 组件齐全（见 §3 预检） |
| 不需要的东西 | WiFi 驱动、代理/分流插件、多拨、主题美化、UA3F 本身 | ✅ 已剔除 |

**验收方式**：通过 TFTP 启动它 → `free -m` 看内存 → 用 LuCI 上传正式固件刷一遍 → 重启进正式系统。

---

## 3. 实测结果（编译通过，产物已核对）

| 指标 | 正式版 | **精简版** | 改善 |
|---|---|---|---|
| `.itb` 体积 | 29.0 MB | **9.0 MB** | **−69%** |
| 内核（lzma） | 6.0 MB | 4.33 MB | −28% |
| initrd（XZ 压缩后） | 24.7 MB | **4.61 MB** | −81% |
| **解包后（= 启动内存占用）** | **≈95 MB**（OOM） | **20.5 MB** | **−78%** |
| 包数 | 352 | 117 | −67% |
| FIT 配置名 | `config-1` | `config-1` ✅ | U-Boot `bootm ...#config-1` 兼容 |

```
sha256  33bcb1f709fcc27599bb69b49a802288a61750973117f7e28ef0b87572ed3553  recovery-slim.itb
```

内存估算（256MB）：内核+保留 ≈48MB，initramfs 展开 20.5MB → 剩余 ≈190MB 给 tmpfs 与服务 ✅
（正式版：48 + 95 → 只剩 117MB，且 init 阶段还要复制 → 实测 OOM）

### 完整性与工具预检

| 检查 | 结果 |
|---|---|
| 脚本语法 `sh -n` | ✅ 通过 |
| 保留清单名字是否都存在 | ✅ 0 个缺失（44 项全部命中 `.config`）|
| 保留清单未命中 `.config` 的条目 | 无 |
| 关键刷机工具 | ✅ `mtd` `ubi-utils` `nand-utils` `fitblk` `kmod-mtd-rw` `uboot-envtools` `fstools` |
| 引导产物包 | ✅ `trusted-firmware-a-mt7981-spim-nand-ddr3` / `-ram-ddr3` / `-ram-ddr4`、`u-boot-mt7981_jcg_q30-pro` |
| 网页刷机组件 | ✅ `uhttpd` `rpcd` `luci-base` `luci-mod-system` + 主题 + 中文包 |
| 大户是否关闭 | ✅ `kmod-mt_wifi` `wpad-openssl` `ua3f` `passwall` `smartdns` `mwan3` `turboacc` `ttyd` `argon` `upnp` `hnat-detect` `dnsmasq-full` 全部关闭 |

### 首次编译失败与修复（记录）

第一次运行在**最开始阶段**就失败（日志只有 32 行，OpenWrt 的 `-j` + `-s` 会吞掉真实报错）：

| 原因 | 说明 |
|---|---|
| ❌ 转换脚本把**生成引导产物所需的包**也关掉了 | `trusted-firmware-a-mt7981-spim-nand-ddr3`（提供 `preloader.bin` 所需的 bl2）与 `u-boot-mt7981_jcg_q30-pro`（提供 `bl31-uboot.fip`）被置为 `not set` → image 阶段找不到 staged 文件，直接失败 |
| ❌ 失败后没有恢复 `.config` | `set -e` 直接退出，跳过了最后一步，`.config` 停在精简版 |
| ❌ 第二次：`make image` 报 `No rule to make target 'image'` | **本树没有 `image` 目标**，镜像由 `world` 的 `target/stamp-install` 阶段生成 → 改为直接 `make` |

**已修复**：
1. 保留清单加入 4 个引导产物包（`trusted-firmware-a-mt7981-spim-nand-ddr3`、`-ram-ddr3`、`-ram-ddr4`、`u-boot-mt7981_jcg_q30-pro`）
2. 脚本加 `trap ... EXIT HUP INT TERM`：**失败 / Ctrl-C 也会自动恢复正式 `.config`**（已生效，实测触发过）
3. 构建命令由 `make image` 改为 `make`（= world，本树无 `image` 目标）
4. 构建失败时**自动用 `-j1 V=s` 增量重跑**并打印最后 60 行真实报错（日志存 `recovery-slim-build.log`）
5. 默认模式下先备份正式产物、最后再装回去 → 精简那一遍不会污染正式固件（`sha256sums` 也会按
   OpenWrt 风格重建：`sha256sum -b` 生成 `<hash> *<file>`）

---

## 4. 方案对比（为什么选 A）

### 方案 A（**已采用**）：裁剪包列表 + 二次 `make`

**思路**：不动源码树，纯配置层面；用一份"精简包列表"再跑一次镜像生成，覆盖产出精简版 `-recovery.itb`。

**关键点**：
- OpenWrt 的 `-recovery.itb` 与正式 rootfs **共用同一套已选包**，所以必须换一套包列表再生成一次
- 不 patch `target/linux/.../filogic.mk`，rebase 上游时**零冲突**
- 第二次 `make` 复用已建好的工具链与 `dl/` 缓存（约 20~40 分钟，含一次内核重配）

### 方案 B：`CONFIG_TARGET_PER_DEVICE_ROOTFS` + 新增 recovery 设备 profile

- 一次 `make` 同时产出正式与精简两个 rootfs（各设备独立包列表）
- **代价**：要 patch `filogic.mk` 新增一个 `Device/jcg_q30-pro-recovery`，
  rebase 上游会持续冲突；且新 profile 会出现在 `profiles.json` 与 menuconfig 里，**用户可能误刷**
- 结论：**不推荐**（维护成本 + 误用风险）

### 方案 C：直接裁剪现有 initramfs 再打包（不编译）

- 把 `.itb` 里的 `initrd-1`（cpio）解开 → 删文件 → 重新打包成 FIT
- 几分钟出结果，但**极易删错依赖导致二进制崩溃**，且不可重复（每次正式固件更新都要手工做一遍）
- 结论：只适合应急试验，**不做正式方案**

---

## 5. 精简包列表

见 `scripts/recovery-slim-packages.txt`（44 项，保留清单；其余 `CONFIG_PACKAGE_*=y` 一律置 n）。

**保留（核心）**

| 分类 | 包 |
|---|---|
| 基础 | `base-files` `libc` `libgcc` `kernel` `busybox` `procd` `ubus` `uci` `libubox` `libubus` `logd` `urandom-seed` `urngd` |
| 网络 | `netifd` `dnsmasq`（非 full）`odhcp6c` `odhcpd-ipv6only` `firewall4` `nftables` |
| **刷机工具（关键）** | `mtd` `ubi-utils` `nand-utils` `fitblk` **`kmod-mtd-rw`** `uboot-envtools` `fstools` |
| 远程/网页 | `dropbear` `uhttpd` `rpcd` `luci-base` `luci-mod-system` `luci-mod-network` `luci-mod-status` `luci-theme-bootstrap` `luci-i18n-base-zh-cn` |
| 目标必需 | `kmod-leds-gpio` `kmod-gpio-button-hotplug` `mtk-smp` `l1util` `default-settings-chn` `ca-bundle` |
| **引导产物（必需）** | `trusted-firmware-a-mt7981-spim-nand-ddr3` `-ram-ddr3` `-ram-ddr4`、`u-boot-mt7981_jcg_q30-pro` |

**移除（体积/内存大户）**

`kmod-mt_wifi`（MTK 私有 WiFi 驱动，最大头）、`wpad-openssl`、`ua3f`、
`luci-app-passwall`、`luci-app-smartdns` + `smartdns`、`mwan3` + `luci-app-mwan3`、
`luci-app-turboacc-mtk`、`luci-app-upnp` + `miniupnpd-nftables`、`luci-app-ttyd` + `ttyd`、
`luci-theme-argon` + `luci-app-argon-config`、`luci-app-watchcat`、`dnsmasq-full`→`dnsmasq`、
`hnat-detect`、`kmod-usb-*`、`ppp*`（如不需要 PPPoE 救砖）

---

## 6. 集成方式（关键：产物名不变）

**保持文件名完全不变**：`immortalwrt-mediatek-filogic-jcg_q30-pro-initramfs-recovery.itb`

这样以下全都不用改，天然可用：

| 依赖它的东西 | 说明 |
|---|---|
| U-Boot 内置变量 `bootfile=` | TFTP 兜底循环 / 按住 reset 的恢复路径 |
| 启动菜单 `4`/`6` | Boot recovery / Load recovery via TFTP + write NAND |
| 现有文档与流程 | HUMAN-GUIDE / AI-CONTEXT 里的命令一字不用改 |
| `pstore` 恢复链 | recovery 不再 OOM → 自动恢复链路重新变可靠 |

**GitHub Actions**：在正式构建之后追加精简一遍（复用工具链，+20~40 分钟），
用精简版**覆盖** Release 里的 recovery 文件：

```yaml
- name: 精简 recovery 镜像（默认构建的一部分）
  run: bash scripts/build-recovery-slim.sh --slim-only
- name: 校验产物
  run: ls -l recovery-slim-out/ && sha256sum -c recovery-slim-out/sha256sums
```

**刷机闭环收益**（做完之后）：

```
按住 reset 上电 → U-Boot 用 TFTP 拉精简 recovery（9.0MB）→ 进内存系统
   → 浏览器 192.168.1.1 上传正式固件 → 完成救砖（全程不需要串口！）
```

---

## 7. 风险与对策

| 风险 | 对策 |
|---|---|
| 精简后缺依赖 → 起不来/工具缺失 | 建成后**先用 TFTP 试跑**，检查 `free`、`ubinfo`、`mtd`、`sysupgrade -h` 是否正常 |
| `kmod-mtd-rw` 未选 → 无法从 Linux 写 `fip` | 先确认（当前 `.config` 已有该符号），并加入保留清单 ✅ |
| kconfig 反向依赖（取消某包导致其它包被连带取消） | 每次改动后 `make defconfig` 让 kconfig 自动补齐，再检查 `manifest` 差异 |
| 切换 `.config` 导致内核重配、编译时间变长 | 接受（约 20~40 分钟）；CI 里已作为固定步骤 |
| CI 时间翻倍 | 复用同一份工具链与缓存；只在 `main` 上跑 |
| 与正式固件混淆 | 产物名不变、文档明确 recovery ≠ 正式固件；`recovery-slim.manifest` 可核对包列表 |
| 本地 `build_dir` 被清理 | 重编会重建（约 16GB）；或直接交给 GitHub Actions |

---

## 8. 剩余工作

- [x] 写 `scripts/build-recovery-slim.sh`（配置生成 + 构建 + 取产物 + 恢复）
- [x] 本地跑通，产出 `recovery-slim.itb`，核对体积与包清单
- [x] 集成进默认构建（脚本默认模式；CI 调 `--slim-only`）
- [x] 更新文档：把「别用按住 reset（会 OOM）」改为「reset + TFTP 即可进精简 recovery」
- [ ] **真机 TFTP 实跑**：`free -m`（期望 ≥150MB 可用）/ `ubinfo -a` / `mtd -h` / `sysupgrade -h`，
      再用 LuCI 刷一次正式固件验证闭环 —— 通过后把文档里的"已编译验证"改成"已实测通过"

---

## 9. 时间记录

| 阶段 | 实际 |
|---|---|
| 写脚本 + 生成精简配置 | 20 分钟 |
| 首次精简构建（本地，工具链需重建） | 40~70 分钟 |
| 装配/文档/CI 集成 | 20 分钟 |
| **合计（不含真机验证）** | **约 1.5 小时**（大部分是等编译）|
