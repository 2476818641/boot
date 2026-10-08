# AX6600（京东云雅典娜）校园网定制固件 · 配方仓库

面向 **JDCloud RE-CS-02 / 京东云雅典娜 AX6600** 的 ImmortalWrt 云编译配方。
本仓库是配方（Config + Scripts + files），**不含 OpenWrt 源码** —— 编译时由 CI 拉取上游源码树，再套用这里的配置与改动。

- 设备：IPQ6010 + QCN9074 + NSS 硬件卸载，1GB DDR4 / 128GB eMMC
- 系统：ImmortalWrt 25.12-SNAPSHOT（kernel 6.18.x，apk 包管理）
- 分支：`ax6600`（本分支）

---

## 一、基于什么修改

| 项 | 来源 |
|---|---|
| 配方模板 | [`ones20250/Openwrt-AX6600`](https://github.com/ones20250/Openwrt-AX6600)（本仓库是它的 fork，改动都在 `ax6600` 分支） |
| 源码树 | [`ones20250/immortalwrt_ipq`](https://github.com/ones20250/immortalwrt_ipq) `main`（ImmortalWrt 25.12-SNAPSHOT + NSS 支持） |
| 编译 | GitHub Actions：`.github/workflows/QCA-ALL.yml` → 复用 `WRT-CORE.yml`；矩阵 `IPQ60XX-WIFI-YES` + `PLUS` |
| 一键脚本源 | [`2476818641/Login-edu`](https://github.com/2476818641/Login-edu) `school-onekey` 分支（本仓库内 `files/scripts/` 是快照） |

---

## 二、做了什么

### 1. 设备默认值（刷完开箱即用的那一套）

| 项 | 值 |
|---|---|
| LAN | `192.168.1.1` |
| WiFi | **只开一个 AP**：radio2（5G），SSID `imm` / 密码 `liuasd111` |
| 主题 | Argon（config + luci collection + `uci-defaults` 三重保证） |
| 版本标识 | `ax6600-snapshot-25.12` |
| 软件源 | 南大镜像（NJU snapshots） |

### 2. 精简

去 Docker、去 PassWall2（保留 OpenClash）、去掉 `v2ray-geo*` / `geoview` 等用不到的分流组件。
（`Config/GENERAL_AX6600_PLUS.txt` 里以 `=n` 显式关闭，避免被依赖链重新拉回。）

### 3. 雅典娜 LED 点阵屏换成 unraveloop 版

基础源码树自带的是"预编译 Go 二进制 + 旧 i18n 包"的一体化实现（仓库里没有源码）。
改为 [`unraveloop/JDC-AX6600-Athena-LED-Controller`](https://github.com/unraveloop/JDC-AX6600-Athena-LED-Controller) **v2.4.0**：

- `athena-led`（Rust 核心，预编译产物，无需 Rust 工具链）+ `luci-app-athena-led`（LuCI JS 界面）
- 同时**删掉**基础树里的旧包，以及设备 profile（`target/linux/qualcommax/image/ipq60xx.mk`）里硬编码的旧 `luci-i18n-athena-led-zh-cn`
- 上游 `PKG_HASH:=skip` 换成实测 sha256

### 4. 校园网适配（本仓库改动的重点）

**TTL 双向伪装** —— `/etc/nftables.d/10-ttl-fix.nft`

- 出站：除 `br-lan` 外所有出口，IPv4 TTL / IPv6 hoplimit 统一为 `128`（与 Windows UA 人设自洽）
- **入站：把经 NAT 的客户端入站包里被网关改成 `1` 的 TTL 补回 `64`（TCP 与 UDP 都要）**

> 为什么必须入站也修：校园网关把客户端（经 NAT 转发）入站包的 TTL 改成 1，转发时减 1 归零 → 内核直接丢弃。
> 现象是"**路由器自己 curl 正常，但客户端 HTTPS 全超时**"；而**只修 TCP 时网页恢复、游戏（LoL / Steam / ARK）仍然全挂** —— UDP 同样被标记。

**UA 伪装** —— `UA-Mask`（vendored 源码，`package/UA-Mask/`）

- 统一 UA 人设；默认**绕过 443**（TLS 没有明文 UA）与 EasyTier 端口
- 非 HTTP 目标自动卸载回内核转发；停止服务时清理防火墙规则

### 5. DNS：内置可用的 AdGuard Home

- `/etc/adguardhome/adguardhome.yaml`：5625 端口、bind `127.0.0.1 + 192.168.1.1`、Ali/Tencent DoH 上游、国内 bootstrap、
  `ratelimit: 0`、`enable_dnssec: false`、**`os.rlimit_nofile: 0`**
- `uci-defaults` 自动接线：启用 AGH + `dnsmasq → 127.0.0.1#5625` + `noresolv=1`

> 两个必须照抄的坑：AGH 跑在 procd jail 里，`rlimit_nofile` 非 0 会 `setrlimit EPERM` 直接 `[fatal]` 退出；
> dnsmasq 转发让 AGH 把全屋当单一客户端，默认 20 qps 会变成全局限速。

### 6. 联机：EasyTier 编入固件

- `easytier` 2.6.4 + `luci-app-easytier`（提供 `/etc/init.d/easytier` 与 LuCI 界面）+ `kmod-tun`
- **隧道端点放在路由器上** → 出站不再被路由器二次端口翻译 → 校园网关看到的 NAT 类型恢复为单层 **NAT3**（实测与手机 4G 建立了 P2P 直连）
- `uci-defaults` 首次开机修正 `/etc/init.d/easytier` 权限（该包 `postinst` 在镜像装配时被 `--no-scripts` 跳过，镜像里是 0644）

### 7. 两个一键脚本编进固件

| 固件内路径 | 用途 |
|---|---|
| `/etc/campus-onekey.sh` | 校园网：UA 伪装 + 门户认证 + 双向 TTL + 启动项（开机 / 网口 up / cron 每 5 分钟）。**门户接口按本校写死，换校需改「本校参数」** |
| `/etc/easytier-onekey.sh` | 联机：EasyTier 配置（生成 `/etc/easytier/config.toml` + 钉住 uci `etcmd`）+ 游戏端口转发 + 内网路由下发 |

---

## 三、如何使用

### 1. 刷机

从 [Releases](https://github.com/2476818641/boot/releases) 下载（**取列表最上方**，可用 `PLUS` 关键词过滤）：

| 文件 | 用途 |
|---|---|
| `...-squashfs-factory-*.bin` | 全新刷机（USB 9008 / EDL，或不死 U-Boot） |
| `...-squashfs-sysupgrade-*.bin` | 已有 OpenWrt 时升级（可保留配置） |

刷机与救砖步骤见 `Docs/刷机救砖教程.md`。

### 2. 刷完的默认状态

| 项 | 值 |
|---|---|
| 管理界面 | `http://192.168.1.1`（**用 http，别让浏览器自动跳 https**） |
| WiFi | SSID `imm` / 密码 `liuasd111`（5G；radio0/1 默认关闭） |
| 主题 | Argon |
| DNS | `dnsmasq → AdGuard Home(5625) → 加密上游`；AGH 界面 `http://192.168.1.1:3000` |
| LED 屏 | LuCI → 服务 → Athena LED（浏览器建议 Ctrl+F5 强刷一次） |

### 3. 校园网接入

> ⚠️ **不要直接照抄这个脚本！**
> 脚本里的**门户地址、三个接口路径、表单字段名、AES 密钥**都是按**本校**门户接口写死的
> （见脚本开头「本校参数」段）。**换学校直接跑必然认证失败**，而且失败原因不会提示得很清楚。
>
> 正确做法：
> 1. 到 [`Login-edu`](https://github.com/2476818641/Login-edu) 读文档 —— **通用版、抓包流程、给 AI 的提示词都在 `main` 分支**；
> 2. 按 [`Docs/CAMPUS-SETUP.md`](Docs/CAMPUS-SETUP.md) 里的「换学校要改什么」对照表，改脚本开头的「本校参数」段；
> 3. 用 `DRY_RUN=1` 先干跑看清要改什么，再 `--auth` 单独试认证，通了再跑全流程。

```sh
# 伪装 + 认证 + 启动项（幂等，可反复跑）—— 确认「本校参数」已按你学校改好
sh /etc/campus-onekey.sh 学号 密码

# 状态：外网 / 认证 / 启动项 / UA-Mask / TTL / 入站修复
/etc/campus-onekey.sh --status

# 只刷新 TTL 规则（补/修入站 TCP+UDP 修复，不动 UA-Mask、不认证）
/etc/campus-onekey.sh --ttl

# 只认证 / 卸载启动项 / 干跑预览
/etc/campus-onekey.sh --auth
/etc/campus-onekey.sh --uninstall
DRY_RUN=1 /etc/campus-onekey.sh 学号 密码
```

### 4. 虚拟局域网与游戏联机

```sh
# 首次最省事：直接粘对方的 Astral 分享链接（房间号/密码/服务器全自动读出来）
sh /etc/easytier-onekey.sh --astral 'astral://room?code=H4sI…'
# 也接受单独一串分享码（H4sI 开头）、甚至整段分享文本；不给参数就交互式粘贴

# 或者手填：房间号与密码（= Astral 房间 ID 与密码）、本机虚拟 IP、子网代理
sh /etc/easytier-onekey.sh --room
# （--room 的第一个提问同样可以直接粘分享链接，后面就只剩虚拟 IP 和子网代理两个问题）

# 最常用：改游戏端口转发（外部端口 → 内网机器）
sh /etc/easytier-onekey.sh --ports tcp/25565,udp/19132
sh /etc/easytier-onekey.sh --ports 25565@192.168.1.5      # 指定目标机器
sh /etc/easytier-onekey.sh --ports                          # 交互式

# 换引导/中转节点、看现状、清空转发
sh /etc/easytier-onekey.sh --node tcp://public.easytier.top:11010
sh /etc/easytier-onekey.sh --show
sh /etc/easytier-onekey.sh --toml        # 手改过 config.toml 后：校验 + 重启
sh /etc/easytier-onekey.sh --clear
```

> 分享码是 `base64url(gzip(json))`，解出来是房间名 / 房间号 / 密码 / 对方用的服务器列表，
> 只用到 `base64` + `gzip`，路由器上不用另装东西。字段含义按 Astral 上游源码对齐
> （`room_share_codec.dart` 的 `n/r/p/s`，以及 `simple.rs` 里的 `NetworkIdentity::new(房间号, 密码)`）。

验证：

```sh
easytier-cli peer       # 对端列表：tunnel=udp 即 P2P 直连
easytier-cli route      # 子网代理网段
```

> **配置到底放在哪（踩过坑，值得看一眼）**
> `/etc/init.d/easytier` 按 uci `easytier.@easytier[0].etcmd` 三选一：
> `config` → 读 `/etc/easytier/config.toml`；`etcmd` → 用 uci 字段拼命令行；
> **空值 → 两条分支都不进**，进程照样起来但一个参数都没有 —— tun0 不创建、房间不进、
> `easytier-cli peer` 里 ipv4 空白，而 `easytier-cli` 本身还能回话（很像"在跑"）。
> `easytier-onekey.sh` 会同时写好 uci 与 `config.toml`，并把 `etcmd` 钉成 `config`；
> 手工配的话记得 `uci set easytier.@easytier[0].etcmd=config && uci commit easytier`。
> 另：`config.toml` 里 `ipv4` / `dhcp` / `listeners` 在**顶层**，`dev_name` / `mtu` 才在 `[flags]`，
> 写错位置 EasyTier 会静默丢弃（`--check-config` 也不报错）。

### 5. 自己编译

- **云编译**：向 `ax6600` 分支 push 即触发（只改 `Docs/**`、`**.md` 不触发，见 workflow 的 `paths-ignore`）
- **本地复现**：把 `Config/`（`IPQ60XX-WIFI-YES.txt` + `GENERAL_AX6600.txt` + `GENERAL_AX6600_PLUS.txt`）与 `Scripts/`（`Packages.sh` 拉外部包、`Settings.sh` 打配置与文件补丁）套用到 `ones20250/immortalwrt_ipq`

---

## 四、文档

| 文档 | 内容 |
|---|---|
| [`Docs/刷机救砖教程.md`](Docs/刷机救砖教程.md) | 刷机、救砖、双系统 GPT 分区、U-Boot 与 EDL 流程、本 fork 的差异说明 |
| [`Docs/CAMPUS-SETUP.md`](Docs/CAMPUS-SETUP.md) | 校园网接入整体方案（伪装 / 认证 / TTL / 联机 / DNS） |
| [`Docs/校园网检测项自查.md`](Docs/校园网检测项自查.md) | **排查手册**：如果出现问题请自行查看|
| [`Login-edu`](https://github.com/2476818641/Login-edu) | 两个一键脚本的源头与用法（固件内是快照）。**认证脚本是本校专用的**：换学校请先看该仓库 `main` 分支的通用版与抓包流程，改好「本校参数」再跑 |

---

## 五、注意

- 校园网策略各校不同，本仓库结论来自**单校实测**；换环境请先按 `Docs/校园网检测项自查.md` 自行验证
- 固件内**不包含**任何账号、密码、房间密钥；相关配置由脚本交互式写入 `/etc/config`
- 涉及多设备与大带宽使用时请遵守学校网络管理规定
- 固件里的脚本是**快照**：想用最新版就在路由器上 `wget` 覆盖，或重新编译

---

## 六、许可证与第三方组件

本仓库（配方、脚本、文档）以 **GPL-3.0-only** 发布，全文见 [`LICENSE.md`](LICENSE.md)。

**为什么是 GPL-3.0**：仓库内以源码形式分发了 [UA-Mask](https://github.com/Zesuy/UA-Mask)（GPL-3.0-only），
采用同一许可最省事、也避免授权冲突。第三方组件（EasyTier / athena-led / OpenClash / AdGuard Home 等）
各自保留原许可，完整清单见 [`THIRD-PARTY.md`](THIRD-PARTY.md)。
