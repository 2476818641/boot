# JCG Q30 Pro / Q30 刷机与救砖指南（给人看的）

> 适用：**JCG Q30 Pro**、**JCG Q30**、CMCC MR3000D-CIq（同一块板，文件通用）
> 固件：本次自行编译的 ImmortalWrt 25.12-SNAPSHOT `r38026-5e20cf34aa`
> 引导：自行编译的 OpenWrt U-Boot 2025.10
> 实战来源：2026-09 两台机器完整走通（一台从别人刷的 24.10 迁移，一台被练手弄坏）

---

## 一、成果速览

| 项目 | 状态 |
|---|---|
| 引导 | **OpenWrt U-Boot 2025.10-ImmortalWrt**（已固化进 flash，断电重启有效） |
| 布局 | `fit` 卷（正式固件，内核据此生成 `/dev/fit0`）+ `rootfs_data`（overlay，60M+） |
| 系统 | ImmortalWrt 25.12-SNAPSHOT，包管理器是 **apk**（不是 opkg） |
| 硬件 | MT7981B + DDR3 256MB + Winbond 128MB SPI-NAND + MT7531 交换芯片 |
| 校园网防封 | `UA-Mask`（UA 改写 + 非 HTTP 流量自动卸载到内核转发，**服务 → UA MASK**）；TTL 伪装由内核 nft 规则兜底 |

成功的样子：**两个蓝灯常亮**，浏览器 `192.168.1.1` 能进 LuCI。

---

## 二、你需要什么

**硬件**
- CH340 USB-TTL 模块（**必须 3.3V 电平**）
- 细探针或飞线（板子上的串口是**空焊盘**，需要顶着或焊上）
- 网线、电脑

**软件**
- 串口终端：iShellPro / PuTTY / Tera Term（115200 8N1，无流控）
- TFTP 服务器：**Tftpd64**（Windows，重点：它的 **Log viewer 会显示请求的文件名**）
- `mtk-uartboot-qt.exe`（BROM 级救砖工具）

**文件（5 个，TFTP 根目录用原名，不要改名）**

| 文件 | 大小 | 用途 |
|---|---|---|
| `...-bl31-uboot.fip` | 1073444 | U-Boot 本体 → 写 `fip` 分区 |
| `...-squashfs-sysupgrade.itb` | 33866011 | 正式固件 → 写 `fit` 卷 |
| `...-initramfs-recovery.itb` | 9437184 | **精简版**内存系统 → 按住 reset 救砖用（`make` 的默认产物就是它） |
| `...-preloader.bin` | 230232 | BL2 → 写 `bl2` 分区（**通常不用写**） |
| `mt7981-ram-ddr3-bl2.bin` | 210368 | **给 mtk_uartboot 用的 RAM BL2**（不是 preloader！）|

---

## 三、刷机总流程（10 步）

### 准备
1. **接线**：只接 3 根 —— 模块 GND→板 GND、模块 TX→板 **RX**、模块 RX→板 **TX**。
   **VCC 永远不接**（用胶带包起来）。115200 8N1、无流控。
2. **找空焊盘引脚**：断电用万用表蜂鸣档找 **GND**（对 SoC 屏蔽罩或接地铜箔）；
   上电测出稳定 3.3V 的是 **VCC**（认出来只为避开）；剩下两脚里，接模块 RX 能看到启动文字的是 **TX**。
3. **电脑网络**：有线网卡静态 IP `192.168.1.254` / `255.255.255.0`，网关 DNS 留空。
   网线插**路由器 LAN 口**（⚠️ WAN 口在 U-Boot 阶段也能跑 TFTP，特别容易搞错）。
4. **Tftpd64**：`Current Directory` 指到放文件那个目录；`Server Interfaces` 选 `192.168.1.254`；
   勾 `Bind TFTP to this address`；**防火墙"专用"和"公用"都要放行**（换网段后 Windows 常重判为"公用"）。

### 进 U-Boot
5. **用 mtk_uartboot 把 U-Boot 灌进内存**（不需要网页、不需要按键，BL2/U-Boot 全坏也能用）：
   ```
   mtk-uartboot-qt.exe -s COM7 -p mt7981-ram-ddr3-bl2.bin -a -f immortalwrt-mediatek-filogic-jcg_q30-pro-bl31-uboot.fip --debug
   ```
   **先把命令跑起来（它在循环握手）→ 再给路由器上电**。一次不中就拔电重上，多试几次。
   成功会看到：`[BROM] handshake done` → `芯片ID: 0x7981` → `send_da 100%` → `[BL2] handshake ok` → `NOTICE: Received FIP`
6. 内存里的 U-Boot 起来后会显示 **3 秒启动菜单**，按任意键 → 选 **`0. Exit`** → 到 `MT7981>` 命令行。

### 写引导和固件
7. 先看清现状（**这一步别省**）：
   ```
   ubi part ubi
   ubi info l
   mtd list
   ```
   记下卷名（旧机器常是 `kernel` / `rootfs` / `rootfs_data` / `ubootenv`）和空闲空间。
8. 腾空间 + 写 U-Boot + 写固件：
   ```
   ubi remove kernel
   ubi remove rootfs

   tftpboot 0x46000000 immortalwrt-mediatek-filogic-jcg_q30-pro-bl31-uboot.fip
   mtd erase fip
   mtd write fip 0x46000000 0 $filesize
   mtd read fip 0x47000000 0 $filesize
   cmp.b 0x46000000 0x47000000 $filesize        # 要显示 Total of ... were the same

   ubi part ubi
   setenv replacevol 1
   run boot_tftp_production
   ```
   ⚠️ `ubi remove` 里**千万别删 `ubootenv` / `ubootenv2`**（你的设置和启动菜单在里面）；
   `rootfs_data` 不用手动删，脚本会处理。

### 收尾（最重要的一步）
9. **用正常启动方式再启动一次** —— `run boot_tftp_production` 是"写完直接启动"，**不会创建 overlay**，
   结果就是只读系统（主机名 `(none)`、改不了密码）：
   ```
   run boot_production
   ```
10. 进系统后验证：
    ```
    df -h | grep overlay        # 要有 /dev/ubi0_x 挂 /overlay，60M+
    hostname                    # 应该是 ImmortalWrt
    passwd                      # 设密码（校园网必做）
    ```
    最后 `reboot` 一次，开机不碰键盘，确认能自动进系统。

---

## 四、刷完之后要做的配置

1. 浏览器 `192.168.1.1` → **服务 → UA MASK** → 打开 **"启用"**（默认是关的）
   - **User-Agent 标识**：填你要伪装成的那一串（默认 `FFF` 太假，建议填常见 Chrome/Windows UA）
   - **匹配规则**：`关键词`（默认 `iPhone,iPad,Android,Macintosh,Windows`）或 `正则`
     （默认覆盖手机+PC 全家族）—— 命中就改写成上面那串，**没命中就原样放行**
   - **网络**页里两个开关**保持打开**（本固件默认已开）：
     **「启用流量卸载」**`enable_firewall_set=1` + **「绕过非 http 流量」**`Firewall_ua_bypass=1`。
     确认不是 HTTP 的目标会被写进 nftables 集合，之后这些目标的流量**不再进用户态代理** ——
     游戏加速器隧道 / Steam 下载 / P2P 就靠这个不被搅坏（节点 IP 会变也没关系，它按 `IP.端口` 自动重新学习）
   - **User-Agent 白名单**（`whitelist`）：不想被改写的 UA 关键词填这里，例如 `QeeYouAcceler,Valve/Steam`
   - **绕过目标端口**默认 `22 443`（443 是 TLS，本来就看不到 UA）
   - ⚠️ 本方案**不再提供** L3 重写（TTL/IPID/删 TCP 时间戳/阻断 QUIC）与 Desync：那是前身 UA3F 的功能，
     实测会把加速器隧道和 QUIC 流量打死（尤其"阻断 QUIC"会丢光 UDP 443）。**TTL 伪装由内核 nft 规则负责**（见第九节）
2. SSH 验证：
   ```sh
   /etc/init.d/UAmask status
   pgrep -a UAmask                              # 进程在跑
   nft list table inet fw4 | grep -i uamask     # 它注册到 fw4 的规则 + 卸载集合
   nft list set inet fw4 UAmask_bypass_set      # 被自动卸载（不再进代理）的目标 IP.端口
   logread -e UAmask                            # 日志；config.json 生成失败会写在这里
   ```
3. 安全：LuCI → **系统 → 管理权** → 关掉 WAN 侧的 SSH / Web 访问
4. 电脑网卡改回自动获取 IP
5. 不需要的插件（`passwall` / `smartdns` / `mwan3`）先停掉，排查网络问题时省事

---

## 五、出问题了怎么救（三层手段）

| 手段 | 怎么做 | 什么时候用 |
|---|---|---|
| **① 3 秒菜单** | 上电后按任意键 → `0. Exit` | **日常首选**，能进命令行看状态、改设置 |
| **② 菜单写 NAND** | 菜单 `5`=TFTP 写正式固件 / `6`=写 recovery / `7`=写 FIP / `8`=写 BL2 | 不想敲命令 |
| **③ mtk_uartboot** | 本文第 5 步那条命令 | **终极保命**：BL2、U-Boot 全坏也能救 |

⚠️ **"按住 reset"救砖能不能成，取决于 recovery 镜像占多少内存**：

OpenWrt 默认让 recovery 和正式固件**共用同一套已选包**（本仓库 380 个）→ initramfs 29MB、
解包约 95MB，而本机只有 256MB 内存 → **必然 OOM 崩溃**，还会连累出启动循环。
本仓库已经把这件事包在**默认编译**里了：正常 `make` 结束时，产物里的 recovery **就是精简版**
（9.0MB / 解包 20.5MB，只含 44 个包），你不需要额外操作：

```bash
make -j"$(nproc)"                                 # 默认编译 → recovery 已是精简版
bash scripts/build-recovery-slim.sh --slim-only   # 只想重做精简 recovery（正式产物已在时）
bash scripts/build-recovery-slim.sh               # 完整重来：正式构建 + 精简 recovery
# 产物汇总在 recovery-slim-out/，含 sha256sums
```

把编译产物里的 `...-initramfs-recovery.itb` 放进 TFTP 目录，就能用最省事的方式救砖：

```
按住 reset 上电 → U-Boot 自动 TFTP 拉取 → 进内存系统 → 浏览器 192.168.1.1 上传固件
（全程不需要串口、不需要 mtk_uartboot）
```

进内存系统后自测：`free -m` 可用内存应 **≥150MB**（原版 29MB 会直接 panic，根本进不去）。

详见 [RECOVERY-SLIM-PLAN.md](RECOVERY-SLIM-PLAN.md)。

---

## 六、踩过的坑与解决办法（照着查，别重复踩）

| 现象 | 真正的原因 | 解决 |
|---|---|---|
| 原厂/旧网页刷机报 `Probably you have chosen wrong file` | 旧 U-Boot（hanwckf 版）只吃**它自己布局**的镜像 | 别用它，走 mtk_uartboot |
| LuCI 刷完卡在 `Waiting for root device /dev/fit0...` | FIT 被放进了 `kernel` 卷，而内核按**卷名 `fit`** 生成 `/dev/fit0` | 建/改名 `fit` 卷（`run boot_tftp_production` 会自动建）|
| **`[BROM] TX 0xa0 echo 0xa0 mismatch` 反复出现** | **探针接触不良**（读到的是自己发出去的字节）| 压紧探针，尤其 GND；拆掉回环测试留下的短接线 |
| 串口按键无效、菜单选不中、`ubi` 敲不进去 | 同上（接触不良） | 同上。**任何反常先查接触** |
| 串口一条日志都没有 | 接触不良 / 串口被别的程序占用 | 关掉占用程序重开；断电重上电看 BL2 是否打印 |
| mtk_uartboot 一直握不上手 | 上电时机不对 / 接触不良 | 先跑命令再上电；拔电重试多次 |
| `mtd write fip 0x46000000 0 10734` 只写了 64KB | 该 U-Boot 的 `mtd` 数字参数是**十六进制**，且命令被吃字符 | **一律写 `$filesize`**，回车前看一眼整行 |
| 内存系统起来后 OOM panic（`shmem:97564kB` → `deadlocked on memory`） | 256MB 内存装不下 29MB initramfs（解包约 95MB） | 用**精简 recovery**（默认编译产物就是 9.0MB / 解包 20.5MB）；或走写 NAND 的路径 |
| 系统只读、主机名 `(none)`、`passwd: Read-only file system` | `boot_tftp_production` **不创建 overlay** | 用 `run boot_production` 或正常重启一次 |
| 启动循环、每轮都 `Creating dynamic volume recovery` | ramoops 里有崩溃记录 → `bootcmd` 的 `pstore check` 跳过正常系统直奔 recovery | `setenv bootcmd 'run boot_ubi'` + `saveenv` + `mw.b 0x42ff0000 0 0x10000` |
| `saveenv` 报 `Volume ubootenv2 not found` / `Failed (1)` | UBI 里缺 `ubootenv2` 冗余卷 | `ubi create ubootenv2 0x100000 dynamic` 后再 `saveenv` |
| 刷完能启动但浏览器打不开 `192.168.1.1` | **网线插在 WAN 口**（U-Boot 阶段任何口都能 TFTP，极具误导） | 插 `lan1`/`lan2`/`lan3` |
| TFTP 报 `File not found` | Tftpd64 的 `Current Directory` 没指对 | 改目录，或先用 `tftp -i 192.168.1.254 GET <文件名>` 自测 |
| TFTP 完全没请求 | 网卡 IP 不对 / 防火墙把新网段判成"公用" | 网卡设 `.254`；防火墙专用+公用都放行 |
| UA-Mask 开了但 UA 没变 | ① 服务没启用（`UAmask.enabled.enabled`）② UA 没命中匹配规则（关键词/正则都不匹配就原样放行，这是设计行为）③ 目标端口在「绕过目标端口」里 | `pgrep -a UAmask`；LuCI 服务→UA MASK 看**运行状态/运行统计**；用 http://ua-check.stagoh.com/ 验证 |
| 开了之后**网页打不开** | 极少见：`generate_core_config` 失败或防火墙规则没清干净。UA-Mask 的 `stop_service` 会自动删链删集合并 `fw4 reload`，所以停服务不该断网 | `logread -e UAmask`；`uci set UAmask.enabled.enabled='0'; uci commit UAmask; /etc/init.d/UAmask stop` 后应能正常上网 |
| **加速器能连上但延迟测不出来 / 报 `-08`** | 隧道流量被代理转坏了。确认「启用流量卸载」+「绕过非 http 流量」都开着；也可把加速器节点**端口**加进「绕过目标端口」 | `nft list set inet fw4 UAmask_bypass_set` 看有没有学到那些 `IP.端口`；LuCI 里改完记得**保存并应用** |
| 以 root 编译报 `tools/tar failed to build` | GNU tar 的 configure 拒绝 root 身份 | `export FORCE_UNSAFE_CONFIGURE=1` 再编译 |
| **云端编译（Actions）出来的固件里没有 UA-Mask（或当年的 ua2f/ua3f）** | **`./scripts/feeds update -a` 结尾会偷偷跑一次 `make defconfig` 改写 `.config`**，而那时 `package/feeds/` 还没建好（全新检出里它被 .gitignore 忽略）→ 所有"来自 feed 的已选包"被静默删掉（380 → 292），后面 install/defconfig 都救不回来。第一次云端构建就是这样发出了一个没有 UA（当时的 ua2f）的固件，工作流还是绿灯 | 仓库已修：工作流在 feeds 步骤前备份 `.config`、之后还原，并用 `scripts/check-package-selection.sh` 两道校验把丢包变成失败。**自己下到固件后先 `grep '^uamask ' *.manifest`** 确认；本地编译则注意"先装 feeds，再改 .config"" |

---

## 七、几个名词，看懂就不慌了

| 名词 | 含义 |
|---|---|
| **FIT / `.itb`** | 一种把内核、设备树、根文件系统打包在一起的镜像格式 |
| **`fit` 卷** | UBI 里存放 FIT 的卷。**内核按这个名字生成 `/dev/fit0`**，名字错了系统就起不来 |
| **`rootfs_data`** | overlay 卷，你的配置（WiFi、UA-Mask 开关）都存在这里；没有它系统就是只读的 |
| **`ubootenv` / `ubootenv2`** | U-Boot 的环境变量仓库（启动参数、菜单设置），**永远不要删** |
| **pstore / ramoops** | 内核崩溃记录区。有记录时 `bootcmd` 会"以为系统崩了"而改走 recovery 路径 |
| **BROM** | 芯片出厂固化的最底层引导，mtk_uartboot 就是跟它对话 → 所以能救一切 |
| **NMBM** | MediaTek 的坏块管理层（旧 U-Boot 用）。本机坏块为 0，和新布局不冲突 |

---

## 八、日常维护建议

- **包管理器是 apk**：`apk add xxx` / `apk del xxx` / `apk update`
- 以后 LuCI 里直接升级固件是**正常可用**的（会自动写 `fit` 卷）
- 备份：LuCI → 系统 → 备份/刷写固件 里导出配置；改了重要东西后导出一次
- **TFTP 目录里的 recovery 镜像请用精简版**：默认编译产物即是（9.0MB）。
  如果你手上还是旧的 29MB 版（或别人给的固件包），把它换成精简版；实在没有，
  就先把 TFTP 目录里的 recovery 改成别的名字（例如加 `.disabled` 后缀），
  这样即使启动失败也只是安静循环，不会 OOM 崩溃 + 反复写 NAND
- 串口探针拆下来前**拍照记录位置**，下次救砖省一半时间

---

## 九、还能做的后续（按需）

1. **TTL 对抗**：内核 nft 规则兜底（`/etc/nftables.d/10-ttl-fix.nft`），生成脚本在
   [Login-edu](https://github.com/2476818641/Login-edu) 仓库的 `campus-net-setup.sh` 里。
   IPID / 删 TCP 时间戳 / 阻断 QUIC / Desync 这类操作**不建议开**：实测会打死加速器与 QUIC 流量
   （UA3F 时代踩过，已随 UA3F 一起弃用）
2. 继续调 `.config` 里那 378 个包，或加你自己的插件

---

## 十、FAQ：从原厂系统开始，要不要走"别人的跳板"？

取决于机器**现在**处于哪种状态：

| 现在是什么状态 | 要不要跳板 | 怎么做 |
|---|---|---|
| **已经是本方案的引导**（OpenWrt U-Boot + `fit` 卷，即刷过本固件） | **不用**，串口/TFTP/跳板全都不需要 | LuCI → 系统 → 备份/刷写固件 → 上传 `*-squashfs-sysupgrade.itb` 完事 |
| **原厂系统 / 别人的旧布局**（`kernel` + `rootfs` 卷，如别人刷的 24.10、hanwckf 系引导） | **不需要别人的跳板**，但**必须换引导**，而换引导这一步只能靠串口 | 走本文第 3~5 步：CH340 串口 + `mtk_uartboot`（BROM 级，工具全公开）→ 灌我们的 U-Boot → `mtd write fip` → 建 `fit` 卷 → 写固件 |
| **原厂系统，且坚决不碰串口焊盘** | **才需要"跳板"**：先刷个能过原厂校验的第三方固件/网页 U-Boot，拿到能写 flash 的环境 | ⚠️ 跳板自带的 U-Boot（`kernel`/`rootfs` 布局）**跑不了我们的固件**（报 `wrong file`，或卡 `Waiting for root device /dev/fit0`）。所以跳完还是得**把引导换成我们的**（写 `fip`）。如果那个网页 U-Boot 支持上传 bootloader/fip，可能能免串口 —— **这条路本仓库没实测过**，我们只验证过它拒绝我们的 sysupgrade 镜像 |
| **原厂系统里已经拿到 root shell**（默认密码/漏洞之类） | 理论上可以免拆：`mtd write bl31-uboot.fip fip` | **没验证过**，而且引导写坏就直接变砖（最后还是回到 BROM）。不如一开始就上串口 |

三句话总结：

1. **一次硬刷，之后永远软刷**：换引导只写 `fip`（`bl2`/preloader 一般完好，不动），这台机器以后所有升级都是 LuCI 一键，不再需要串口，也不需要任何跳板。
2. **"硬刷"≠"走别人的跳板"**：本方案的硬刷是 BROM 级自举（`mtk_uartboot` 把 U-Boot 直接灌进内存），工具全公开、不依赖任何第三方固件 —— 这也正是 BL2/U-Boot 全坏还能救回来的原因。
3. **跳板救不了布局不兼容**：你换到谁的引导都没用，最终必须是"我们的 U-Boot + `fit` 卷"这一套，否则固件起不来。
