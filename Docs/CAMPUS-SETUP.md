# 校园网使用说明（本 fork 的改动）

本 fork 基于 [ones20250/Openwrt-AX6600](https://github.com/ones20250/Openwrt-AX6600)（JDCloud RE-CS-02 / 雅典娜 AX6600，
**高通 IPQ6010 / QUALCOMMAX** 平台，1GB 内存 + 128GB eMMC，带 NSS 硬件加速），只加了一件事：

> **把 UA-Mask 编进固件**，用于校园网的 UA 伪装（防"多设备共享"检测）。

## 一、加了什么

> **PLUS 档去掉了 PassWall2**（功能与 OpenClash 重叠，只留 OpenClash）。连带去掉 `v2ray-geoip` /
> `v2ray-geosite` / `geoview`（它们原本是为 PW2 显式加的；OpenClash 自己会下载 geo 数据），
> 以及构建时只为它加的 `passwall_packages` feed。要恢复：改
> `Config/GENERAL_AX6600_PLUS.txt` 对应行 + `Scripts/Packages.sh` 的 UPDATE_PACKAGE 行 +
> `.github/workflows/WRT-CORE.yml` 里那行 feed。


> **默认只开一个 WiFi**：`imm` / `liuasd111`（5G 的 radio2，QCN6024，ch36 非 DFS）。
> 另外两个 radio 默认关闭：`radio0`（5G ch100，DFS 信道，默认本来就禁用）、`radio1`（2.4G）。
> 想开 2.4G（智能插座等）：LuCI → 网络 → 无线 → 启用 radio1，或
> `uci set wireless.radio1.disabled='0'; uci commit wireless; wifi reload`（它的 SSID 也是 `imm`）。


> **默认 LuCI 主题 = Argon**（与 JCG Q30 Pro 那台固件同款）：`luci-theme-argon` +
> 设置页 `luci-app-argon-config`，默认值由 `files/luci/99-luci-theme`（uci-defaults 改
> `luci.main.mediaurlbase`）保证。想换回去：LuCI → 系统 → 系统 → 语言和界面，
> 或 `uci set luci.main.mediaurlbase='/luci-static/bootstrap'; uci commit luci`。


| 位置 | 内容 |
|---|---|
| `package/UA-Mask/` | [Zesuy/UA-Mask](https://github.com/Zesuy/UA-Mask) 0.4.3 源码（vendored，GPL-3.0-only，upstream commit `83846d3`）+ 我们的 OpenWrt 打包适配与默认配置，见包内 `LOCAL-NOTES.md` |
| `Config/GENERAL_AX6600.txt` 末尾 | `CONFIG_PACKAGE_uamask=y` + `luci-compat`/`luci-lua-runtime`/`curl`/`openssl-util` |

**为什么是 UA-Mask 而不是 UA3F**（这是实测+读源码得出的结论）：

- UA3F 的 REDIRECT 模式生成 `tcp dport != {22} redirect to :1080` —— **除 22 外全部 TCP 都被交给用户态的 Go 代理转发**。
  低速率控制通道（心跳/上报）扛得住，但**高速率长连接扛不住**：Steam 下载会"有速度然后掉到 0"。
- UA3F 规则表里的 `DIRECT` **只是"不改写 UA"，并不绕过代理**（源码 `internal/rewrite/rule.go` 不设 `NeedSkip`）；
  只有 GLOBAL 模式对 `Valve/Steam HTTP Client 1.0` 有硬编码的 IP 级跳过。
- UA-Mask 默认就把 **22/443 排除在代理之外**（443 是 TLS，本来就看不到 UA），并且能把
  「确认不是 HTTP」的目标**卸载到内核**（`ip daddr . tcp dport @UAmask_bypass_set return`）——
  隧道类/大流量从此不进用户态。**Steam 下载正常、加速器可用，靠的就是这个机制。**

## 二、编译

云端（推荐，与上游一致）：fork 本仓库 → **Actions → QCA-ALL → Run workflow**。
本 fork **默认只编 `PLUS` 档**（含 OpenClash / PassWall2 / AdGuard Home；**Docker 整套已去掉**）。
想要纯净版：把 `.github/workflows/QCA-ALL.yml` 里 `PROFILE: [PLUS]` 改成 `[PURE, PLUS]`。
`Config/GENERAL_AX6600.txt` 对所有档都生效；只对某一档生效的写进 `Config/GENERAL_AX6600_<档名>.txt`。

**接线方式**：本仓库自带的 `package/UA-Mask/` 不会被构建系统自动看到（这是配方仓库，不是完整源码树），
所以 `Scripts/Packages.sh` 末尾加了一段：把 `<仓库根>/package/UA-Mask` 拷进构建树的 `wrt/package/`。
它跑在 `wrt/package/` 目录下（见 `WRT-CORE.yml` 的「Custom Packages」步骤），之后才是 `make defconfig`。

本地编译（需要一台 Linux，源码用上游那个 IPQ fork）：

```sh
git clone --depth=1 -b main https://github.com/ones20250/immortalwrt_ipq.git wrt
cp -r package/UA-Mask wrt/package/UA-Mask                       # 就是 Packages.sh 干的事
cd wrt
cat ../Config/IPQ60XX-WIFI-YES.txt ../Config/GENERAL_AX6600.txt >> .config
export FORCE_UNSAFE_CONFIGURE=1
make defconfig
grep -qE '^CONFIG_PACKAGE_uamask=y' .config || echo "❌ uamask 被 defconfig 丢了：检查 package/UA-Mask 是否就位"
make -j$(nproc) download
make -j$(nproc) 2>&1 | tee build.log
```

编译产物在 `bin/targets/qualcommax/*/`（sysupgrade 镜像 + manifest）。**下固件后核对 `grep '^uamask ' *.manifest`**。

## 三、刷机

> 刷完后的默认地址是 **192.168.1.1**（本 fork 把上游的 192.168.10.1 改掉了；
> 实现在 `Settings.sh` 里 sed `package/base-files/files/bin/config_generate`），
> WiFi 默认 `OWRT` / `12345678`，root 无密码（**第一时间设密码**）。


用上游的配套资源，不要照搬联发科那套流程（**平台完全不同**）：

- 仓库内教程：[`Docs/刷机救砖教程.md`](刷机救砖教程.md)（图文，含 TTL 接线图）
- Release「刷机救砖全家桶」：不死 U-Boot（亚瑟/雅典娜通用）、双分区 GPT 分区表、原厂还原固件、
  **USB 9008 救砖工具**

| | JCG Q30 Pro（联发科 MT7981） | AX6600 雅典娜（高通 IPQ6010） |
|---|---|---|
| 底层救砖 | BROM + `mtk_uartboot`（串口） | **USB 9008 / EDL** |
| 引导 | U-Boot + UBI 卷（`fit`/`rootfs_data`） | 不死 U-Boot + **GPT 双分区** |
| 恢复镜像 | 需要 9MB 精简 initramfs（256MB 内存会 OOM） | **不需要**（1GB 内存，原版 recovery 直接跑） |
| 内存压力 | 常态只剩 8MB，必须开 zram | 1GB，无需 zram/精简 |

## 四、刷完之后：校园网一键配置

固件里已经有 UA-Mask，但**默认是关的**（`UAmask.enabled.enabled=0`），也没有账号密码 ——
用单文件脚本一次配好（伪装 + 登录 + 开机自动登录）：

```sh
wget -O /root/campus-onekey.sh https://cdn.jsdelivr.net/gh/2476818641/Login-edu@school-onekey/campus-onekey.sh
chmod +x /root/campus-onekey.sh
sh /root/campus-onekey.sh 你的学号 你的密码
```

它按顺序做三件事：

1. **伪装**：写 UA-Mask 全套配置（UA 串 / `match_mode=regex` 正表 / 放行名单 `QeeYouAcceler,Valve/Steam,HttpDns,Microsoft-CryptoAPI,Microsoft NCSI` / 非 HTTP 自动卸载调优 / `bypass_ports='22 443'`），
   并写 TTL 内核规则（`/etc/nftables.d/10-ttl-fix.nft`，默认 128 = Windows 人设；用 Android UA 时给 64）；
   顺手停用并清掉旧方案 UA3F（如果之前装过）
2. **认证**：本校 RAAS 门户三步接口（`login.php` → `stat.php` → `ack_auth.php`），`pass` 用 AES-128-ECB 加密
3. **启动项**：`/etc/init.d/campus-onekey`（开机，LuCI 系统→启动项可见）+ hotplug（网口上线）+ cron（每 5 分钟兜底）

以后：`/root/campus-onekey.sh --status` / `--auth` / `--uninstall`。

### 验证（30 秒）

```sh
/root/campus-onekey.sh --status
nft list chain inet fw4 UAmask_prerouting_before   # 应看到 tcp dport != { 22, 443 } redirect to :12032
nft list set inet fw4 UAmask_bypass_set            # 大流量跑一会儿后会出现 目标IP.端口
```
- **UA 是否真被改**：用**电脑/手机**打开 <http://ua-check.stagoh.com/> 看显示的 User-Agent
  （**别**用路由器自己 curl 判断 —— UA-Mask 只处理 LAN 侧进来的流量）
- **TTL 是否真被改**：`WAN=$(uci get network.wan.device || echo wan); tcpdump -ni "$WAN" -c 5 -v icmp`，
  同时从电脑 `ping 223.5.5.5`，看 `ttl 128`

## 四之二、TTL 已经编进固件了

`files/ttl/10-ttl-fix.nft` 由 `Settings.sh` 拷进构建树的
`package/base-files/files/etc/nftables.d/10-ttl-fix.nft`，所以**刷完就有 TTL 伪装，不用脚本去写**：

```
chain ttl_fix { type filter hook postrouting priority mangle + 1; policy accept;
                oifname != { br-lan } ip ttl set 128
                oifname != { br-lan } ip6 hoplimit set 128 }
```

- **为什么 128**：伪装人设是 Windows。UA 说自己是哪个系统，TTL 就该对应（Windows=128；Android/Linux/macOS=64），
  两者矛盾本身就是 DPI 会抓的特征。
- **改值**：编辑 `/etc/nftables.d/10-ttl-fix.nft` 后 `fw4 reload`；或跑 `campus-onekey.sh` 时给 `TTL_VALUE=64`
  （脚本检测到固件已有规则就不动它，只在显式给了 `TTL_VALUE` 时才覆盖）。
- **验证**：`WAN=$(uci get network.wan.device || echo wan); tcpdump -ni "$WAN" -c 5 -v icmp`，
  同时从电脑 `ping 223.5.5.5`，看输出里的 `ttl 128`。
- **注意**：NSS 硬件加速卸载后的流可能绕过 netfilter，TTL 改写对这些流未必生效 —— 必须用上面的 tcpdump 实测确认。

## 四之三、版本标注与包源（apk）

- **固件版本**在 `Config/GENERAL_AX6600.txt` 里标注为 `ax6600-snapshot-25.12`
  （源码是 main/snapshot 分支、内核 6.18，比 25.12 正式线的新；上游默认版本串是裸 `SNAPSHOT`，看不出东西）。
  查看：`cat /etc/openwrt_release` 或 LuCI 概览页。
- **默认包源已换成南大镜像**：`https://mirror.nju.edu.cn/immortalwrt/snapshots`
  （构建时由 `CONFIG_VERSION_REPO` 决定，落地到 `/etc/apk/repositories.d/distfeeds.list`）。
- 这份固件用 **apk** 不是 opkg。常用命令：

```sh
cat /etc/apk/repositories.d/distfeeds.list      # 看当前源
apk update                                       # 更新索引
apk add htop                                     # 装包（纯用户态的随便装）
apk add --allow-untrusted /tmp/xxx.apk           # 装自编译/未签名的包
```

- **换回官方源**（镜像偶尔滞后或缺包时）：
```sh
cp /etc/apk/repositories.d/distfeeds.list /root/distfeeds.list.bak
sed -i 's|mirror\.nju\.edu\.cn/immortalwrt|downloads.immortalwrt.org|g' /etc/apk/repositories.d/distfeeds.list
apk update
```
- **⚠️ snapshot 固件的坑**：源里的包会随内核一起滚动，所以 `kmod-*`（内核模块）过几天就可能版本不匹配、
  `apk add` 直接失败 —— 这类东西**别在线装，编进固件最稳**（本 fork 加 UA-Mask / TTL / nft-nat 就是这么做的）。
  纯用户态包（curl、htop、nano、luci 插件…）没这个问题。

## 五、这张平台特有的两个注意点

1. **NSS / ECM 硬件加速可能绕过 netfilter**：被 NSS 卸载的流不再经过 nftables，TTL 改写对**这些流**
   可能不生效（UA-Mask 的重定向发生在连接首包，一般还能抓住）。刷完请按上面 tcpdump 的办法实测；
   若发现 TTL 不合预期，可考虑对 WAN 关闭 NSS 卸载，或接受只对部分流生效。
2. **雅典娜点阵屏 / 分区扩容**：上游已有 `athena-led` 驱动与 `luci-app-partexp`（PLUS 档预置），
   128GB eMMC 可扩容 overlay 后当存储用 —— 与校园网配置无冲突。

## 六、原上游说明

本 fork 只加 UA-Mask 与本文档，其余（NSS 优化、无线调优、刷机资源、PURE/PLUS 划分）均为上游
[ones20250/Openwrt-AX6600](https://github.com/ones20250/Openwrt-AX6600) 的内容，看它的 README。
