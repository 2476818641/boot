# 精简 recovery 镜像 —— 设计方案

> 状态：**已编译通过，待真机 TFTP 验证**（2026-09-19）
> `scripts/build-recovery-slim.sh` + `scripts/recovery-slim-packages.txt` 已实现并通过静态预检，
> 等待本地编译验证。目标：把 `-recovery.itb` 从 29MB 降到 8~12MB，
> 让 256MB 内存的机器也能跑起来，从而恢复「按住 reset 就能救砖」的能力。

## 0. 怎么编译（本地手动）

```bash
cd /root/immortalwrt-mt798x-rebase
bash scripts/build-recovery-slim.sh 2>&1 | tee recovery-slim-build.log
```

脚本会：备份 `.config` → 生成精简 `.config`（只留 40 个包）→ `make`（world，本树没有 image 目标）→ 取产物 →
**自动恢复正式配置**。源码树不做任何修改。

产物在 `recovery-slim-out/`：`recovery-slim.itb` / `.sha256` / `.manifest`

### 首次编译失败与修复（记录）

第一次运行 `make image` 在**最开始阶段**就失败（日志只有 32 行，OpenWrt 的 `-j` + `-s` 会吞掉真实报错）：

| 原因 | 说明 |
|---|---|
| ❌ 转换脚本把**生成引导产物所需的包**也关掉了 | `trusted-firmware-a-mt7981-spim-nand-ddr3`（提供 `preloader.bin` 所需的 bl2）与 `u-boot-mt7981_jcg_q30-pro`（提供 `bl31-uboot.fip`）被置为 `not set` → image 阶段找不到 staged 文件，直接失败 |
| ❌ 失败后没有恢复 `.config` | `set -e` 直接退出，跳过了第 5 步，`.config` 停在精简版 |
| ❌ 第二次：`make image` 报 `No rule to make target 'image'` | **本树没有 `image` 目标**，镜像由 `world` 的 `target/stamp-install` 阶段生成 → 改为直接 `make` |

**已修复**：
1. 保留清单加入 4 个引导产物包（`trusted-firmware-a-mt7981-spim-nand-ddr3`、`-ram-ddr3`、`-ram-ddr4`、`u-boot-mt7981_jcg_q30-pro`）
2. 脚本加 `trap ... EXIT HUP INT TERM`：**失败 / Ctrl-C 也会自动恢复正式 `.config`**（已生效，实测触发过）
2b. 构建命令由 `make image` 改为 `make`（= world，本树无 `image` 目标）
3. 构建失败时**自动用 `-j1 V=s` 增量重跑**并打印最后 60 行真实报错（日志存 `recovery-slim-build.log`）

### ✅ 实测结果（编译通过）

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

**结果文件**：`recovery-slim-out/recovery-slim.itb`、`.sha256`、`.manifest`（117 个包）

### 静态预检结果（编译前已完成，不需要重复）

| 检查 | 结果 |
|---|---|
| 脚本语法 `sh -n` | ✅ 通过 |
| 保留清单名字是否都存在 | ✅ 0 个缺失 |
| 生成后选中包数 | **40**（正式配置为 380）|
| 关键工具是否保留 | ✅ `mtd` `ubi-utils` `nand-utils` `fitblk` `kmod-mtd-rw` `uboot-envtools` `fstools` |
| 网页刷机组件 | ✅ `uhttpd` `rpcd` `luci-base` `luci-mod-system` + 主题 + 中文包 |
| 大户是否关闭 | ✅ `kmod-mt_wifi` `wpad-openssl` `ua2f` `passwall` `smartdns` `mwan3` `turboacc` `ttyd` `argon` `upnp` `hnat-detect` `dnsmasq-full` 全部关闭 |

---

## 1. 问题：为什么现在的 recovery 用不了

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

| 指标 | 目标值 |
|---|---|
| 镜像大小 | **≤ 12MB**（越小越好，TFTP 传输也更快）|
| 解包占用 | **≤ 35MB** |
| 启动后可用内存 | **≥ 120MB**（`free` 实测）|
| 必须能做的事 | ① 串口控制台 ② LAN 起网（192.168.1.1）③ **网页/SSH 刷固件** ④ 写 `fit` 卷 ⑤ 写 `fip` 分区 |
| 不需要的东西 | WiFi 驱动、代理/分流插件、多拨、主题美化、UA2F 本身 |

**验收方式**：通过 TFTP 启动它 → `free` 看内存 → 用 LuCI 上传正式固件刷一遍 → 重启进正式系统。

---

## 3. 方案对比

### 方案 A（**推荐**）：裁剪包列表 + 二次 `make image`

**思路**：不动源码树，纯配置层面；用一份"精简包列表"再跑一次镜像生成，覆盖产出精简版 `-recovery.itb`。

**关键点**：
- OpenWrt 的 `-recovery.itb` 与正式 rootfs **共用同一套已选包**，所以必须换一套包列表再生成一次
- 不 patch `target/linux/.../filogic.mk`，rebase 上游时**零冲突**
- 第二次 `make image` 复用已建好的工具链与 `dl/` 缓存（约 20~40 分钟，含一次内核重配）

**步骤草案**（脚本 `scripts/build-recovery-slim.sh`）：
```sh
# 1) 备份正式配置
cp .config .config.production

# 2) 生成精简配置：保留精选包，其余 CONFIG_PACKAGE_* 全部置 n
#    （依赖由 kconfig 自动补齐：make defconfig 会把必需依赖重新选上）
./scripts/config/conf --file .config --set-val CONFIG_TARGET_ROOTFS_SQUASHFS n   # 只要 initramfs
#    → 把第 4 节的"保留清单"设为 y，其余 CONFIG_PACKAGE_*=y 设为 n
make defconfig

# 3) 生成镜像（复用工具链）
make -j$(nproc) image

# 4) 取出精简 recovery，恢复正式配置与产物
cp bin/targets/mediatek/filogic/*-initramfs-recovery.itb  ../recovery-slim.itb
cp .config.production .config
```

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

## 4. 精简包列表（草案）

**保留（核心）**

| 分类 | 包 |
|---|---|
| 基础 | `base-files` `libc` `libgcc` `kernel` `busybox` `procd` `ubus` `uci` `libubox` `libubus` `logd` `urandom-seed` `urngd` |
| 网络 | `netifd` `dnsmasq`（非 full）`odhcp6c` `odhcpd-ipv6only` `firewall4` `nftables` |
| **刷机工具（关键）** | `mtd` `ubi-utils` `nand-utils` `fitblk` **`kmod-mtd-rw`** `uboot-envtools` `fstools` |
| 远程/网页 | `dropbear` `uhttpd` `rpcd` `luci-base` `luci-mod-system` `luci-mod-network` `luci-mod-status` `luci-theme-bootstrap` `luci-i18n-base-zh-cn` |
| 目标必需 | `kmod-leds-gpio` `kmod-gpio-button-hotplug` `mtk-smp` `l1util` `default-settings-chn` `ca-bundle` |

**移除（体积/内存大户）**

`kmod-mt_wifi`（MTK 私有 WiFi 驱动，最大头）、`wpad-openssl`、`ua2f` + `luci-app-ua2f`、
`luci-app-passwall`、`luci-app-smartdns` + `smartdns`、`mwan3` + `luci-app-mwan3`、
`luci-app-turboacc-mtk`、`luci-app-upnp` + `miniupnpd-nftables`、`luci-app-ttyd` + `ttyd`、
`luci-theme-argon` + `luci-app-argon-config`、`luci-app-watchcat`、`dnsmasq-full`→`dnsmasq`、
`hnat-detect`、`kmod-usb-*`、`ppp*`（如不需要 PPPoE 救砖）

> 预估：压缩后 **8~12MB**，解包 **25~35MB** → 启动后可用内存 **≥120MB** ✅

---

## 5. 集成方式（关键：产物名不变）

**保持文件名完全不变**：`immortalwrt-mediatek-filogic-jcg_q30-pro-initramfs-recovery.itb`

这样以下全都不用改，天然可用：

| 依赖它的东西 | 说明 |
|---|---|
| U-Boot 内置变量 `bootfile=` | TFTP 兜底循环 / 按住 reset 的恢复路径 |
| 启动菜单 `4`/`6` | Boot recovery / Load recovery via TFTP + write NAND |
| 现有文档与流程 | HUMAN-GUIDE / AI-CONTEXT 里的命令一字不用改 |
| `pstore` 恢复链 | recovery 不再 OOM → 自动恢复链路重新变可靠 |

**GitHub Actions**：在同一个 job 内、正式构建完成之后追加一次精简 `make image`
（复用工具链，+20~40 分钟），用精简版**覆盖** Release 里的 recovery 文件：
```yaml
- name: 生成精简 recovery 镜像
  run: |
    bash scripts/build-recovery-slim.sh
- name: 用精简版替换 recovery
  run: |
    cp recovery-slim.itb out/*-initramfs-recovery.itb
    sha256sum out/* > out/sha256sums
```

**刷机闭环收益**（做完之后）：

```
按住 reset 上电 → U-Boot 用 TFTP 拉精简 recovery（8~12MB）→ 进内存系统
   → 浏览器 192.168.1.1 上传正式固件 → 完成救砖（全程不需要串口！）
```

---

## 6. 风险与对策

| 风险 | 对策 |
|---|---|
| 精简后缺依赖 → 起不来/工具缺失 | 建成后**先用 TFTP 试跑**，检查 `free`、`ubinfo`、`mtd`、`sysupgrade -h` 是否正常 |
| `kmod-mtd-rw` 未选 → 无法从 Linux 写 `fip` | 先确认（当前 `.config` 已有该符号），并加入保留清单 |
| kconfig 反向依赖（取消某包导致其它包被连带取消） | 每次改动后 `make defconfig` 让 kconfig 自动补齐，再检查 `.manifest` 差异 |
| 切换 `.config` 导致内核重配、编译时间变长 | 接受（约 20~40 分钟）；CI 里可评估是否值得 |
| CI 时间翻倍 | 只在需要时触发；或把精简构建做成"手动触发"的可选步骤 |
| 与正式固件混淆 | 产物名不变、文档明确 recovery ≠ 正式固件；`.manifest` 可核对包列表 |
| 本地 `build_dir` 已清理（16GB 已删） | 本地重编会重建约 16GB（当前可用 38GB ✅）；或直接交给 GitHub Actions |

---

## 7. 实施步骤（待执行）

1. 写 `scripts/build-recovery-slim.sh`（配置生成 + 构建 + 取产物 + 恢复）
2. 本地跑一次，产出 `recovery-slim.itb`，核对 `size` 与 `.manifest`
3. **TFTP 试跑**：`free` / `ubinfo -a` / `mtd -h` / `sysupgrade -h`；再用 LuCI 刷一次正式固件验证闭环
4. 通过后：更新 GitHub Actions（追加精简构建并替换产物）
5. 更新文档：把「别用按住 reset（会 OOM）」改为「reset + TFTP 即可进精简 recovery」
   （涉及 `README.md`、`HUMAN-GUIDE.md`、`AI-CONTEXT.md`）
6. 把本方案文档从"规划中"改为"已实施"，并记录实测内存与体积

---

## 8. 工作量预估

| 阶段 | 时间 |
|---|---|
| 写脚本 + 生成精简配置 | 20 分钟 |
| 首次精简构建（本地，工具链需重建） | 40~70 分钟 |
| TFTP 试跑 + 闭环验证 | 20 分钟 |
| CI 集成 + 文档更新 | 20 分钟 |
| **合计** | **约 1.5~2 小时**（其中大部分是等编译）|

> 备选：**只交给 GitHub Actions 做**（本地不重建 16GB `build_dir`），
> 代价是每次改脚本都要跑一次 CI（2~4 小时）才知道结果，迭代慢。
