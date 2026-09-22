# 关于这个目录（vendored）

本目录是 [Zesuy/UA-Mask](https://github.com/Zesuy/UA-Mask) 的源码，按 `package/UA3F` 的同一套模式
放进 `package/UA-Mask/`，**从源码在固件里编译**（不是装别人的 `.ipk`：ImmortalWrt 25.12 用的是 apk，
上游 Release 发的是 opkg 格式的 `.ipk`，装不进去）。

- 版本：`0.4.3`（见 `VERSION`）
- 上游 commit：`83846d3780b1e30f87816310ae75d95798a5bd4d`（2026-08-02）
- 许可：GPL-3.0-only（见 `LICENSE`）

## 目录映射

| 本目录 | 上游位置 | 说明 |
|---|---|---|
| `core/` | `core/` | Go 源码（module 名就是 `UAmask`，入口 `cmd/UAmask`） |
| `Makefile` | `openwrt/package/Makefile` | **我们的适配版**（见下） |
| `openwrt/Makefile.upstream` | 同上 | 上游原件，留着方便比对/下次同步 |
| `openwrt/root/` | `openwrt/root/` | 装到根文件系统的 `/etc/init.d/UAmask`、`/etc/config/UAmask` |
| `openwrt/luci/` | `openwrt/luci/` | LuCI 控制器 + CBI 页面（Lua，依赖 `luci-compat`） |
| `openwrt/tests/` | `openwrt/tests/` | 上游自带的 init 脚本测试，可离线跑（见文末） |
| `docs/` | `docs/`（去掉 `img/`） | 架构说明、示例配置、教程 |

## 本地改动（同步上游时要保留）

1. **包定义位置与路径**：上游靠 `PACKAGE_DIR/REPO_ROOT` 反推源码目录；本仓库把它放在
   `package/UA-Mask/Makefile`（包目录根），路径写成 `./core` 与 `./openwrt/root`、`./openwrt/luci`。

   ⚠️ **千万不要**把它放成 `package/UA-Mask/openwrt/Makefile`（上游那种 `<repo>/openwrt/package/` 思路的
   变体）：OpenWrt 的 `include/scan.awk` 用**目录名的最后一段**当 key 去重（`PKGS[$NF]`），
   于是两个包目录都叫 `openwrt` 时会互相覆盖 —— 实测表现是其中一个包在 `make defconfig` 里
   **被静默丢掉**、`tmp/.packageinfo` 里查不到、`.config` 里那行 `=y` 也被删掉，而 make 全程不报错。
   （2026-09-22 踩到：UA3F 是 `package/UA3F/openwrt`，UA-Mask 一度也是 `package/UA-Mask/openwrt`。）
   包目录名唯一才稳。
2. **包名小写**：`Package/uamask`（上游是 `UAmask`），符合 OpenWrt 惯例。
   ⚠️ 二进制仍是 `/usr/bin/UAmask`、配置仍是 `/etc/config/UAmask` —— init 脚本里
   `NAME=UAmask` / `PROG=/usr/bin/$NAME` 和 LuCI 页面都写死了这两个名字，不要改。
3. **去掉 `UAMASK_PREBUILT` 支路**（用预编译二进制打包）：本仓库一律从源码编译。
4. **默认配置加了两个开关**（`openwrt/root/etc/config/UAmask`）：
   `enable_firewall_set '1'` 和 `Firewall_ua_bypass '1'`。上游默认关，关掉的话
   "非 HTTP 目标自动卸载"就不工作 —— 而那正是我们换用 UA-Mask 的主要理由。
5. **没有引入的目录**：`docs/img/`（2.6MB 截图）、`core/UAmask`（上游误提交的 **6.5MB x86-64 预编译
   二进制**，对固件毫无用处）、`core/AGENTS.md`（上游给 AI 工具用的开发指引，放进本仓库会干扰
   本仓库的 agent 上下文）、`.github/`、`scripts/`、`go.work`、根目录 `Makefile`。

## 为什么换掉 UA3F（背景，别重复踩坑）

UA3F 的 REDIRECT 模式生成的是 `tcp dport != {22} redirect to :1080`：**除 22 外所有 TCP 都被劫持进
用户态 Go 代理**。实测后果有两个：

- 游戏加速器（奇游）走 TCP 的隧道流量被代理转坏：控制通道（UDP 探测）能通 → 客户端显示"已连接"，
  但节点延迟测不出来；更早还直接报 `-08`。节点 IP 会变，所以"把节点 IP 加进跳过集合"不是长期方案。
- 它的 init 脚本只有 `start_service`，没有 `stop_service`：停服务时 `inet UA3F` 表和那条全量 TCP
  重定向可能残留 → **进程没了、TCP 全被吸进没人监听的 1080 → 电脑"没网"（但 ping 正常）**。

UA-Mask 在这两点上都更好：防火墙规则是 fw4 的 include（`/tmp/UAmask_rules.nft`），
`stop_service()` 会删链删集合并 `fw4 reload`；并且能把"确认不是 HTTP"的目标卸载进 nftables 集合
（`ip daddr . tcp dport @UAmask_bypass_set return`），命中后流量**根本不进用户态代理**。

另外注意：UA-Mask **没有** L3 重写（TTL/IPID/删 TCP 时间戳/阻断 QUIC/desync）——这是好事，
那几个开关在校园网场景里全是坑（尤其"阻断 QUIC"会丢所有 UDP 443，加速器/语音/QUIC 视频全废）。
**TTL 伪装由我们自己的 `/etc/nftables.d/10-ttl-fix.nft` 负责**（`campus-net-setup.sh` 生成），不要指望这里。

## 更新方式

```sh
# 1) 拉上游快照（GitHub 直连不通时用 codeload 或代理）
curl -L -o /tmp/uamask.tar.gz https://codeload.github.com/Zesuy/UA-Mask/tar.gz/refs/heads/main
mkdir -p /tmp/uamask && tar -xzf /tmp/uamask.tar.gz -C /tmp/uamask --strip-components=1
cat /tmp/uamask/VERSION            # 记下新版本号
# 2) 覆盖源码（保留本文件、openwrt/Makefile、openwrt/root/etc/config/UAmask 的本地改动）
cp -r /tmp/uamask/core        package/UA-Mask/core
cp -r /tmp/uamask/openwrt/root package/UA-Mask/openwrt/root
cp -r /tmp/uamask/openwrt/luci package/UA-Mask/openwrt/luci
cp -r /tmp/uamask/openwrt/tests package/UA-Mask/openwrt/tests
cp    /tmp/uamask/VERSION /tmp/uamask/LICENSE /tmp/uamask/README.md package/UA-Mask/
cp    /tmp/uamask/openwrt/package/Makefile package/UA-Mask/openwrt/Makefile.upstream
# 3) 按上面「本地改动 4」重新加回两个开关，并同步 Makefile 里的 PKG_VERSION，最后跑一次测试
```

## 离线自检（改完 init 脚本/默认配置后建议跑）

```sh
cd package/UA-Mask/core && make shell-check   # = sh -n + 上游的 config 生成/procd 契约测试
sh ../openwrt/tests/config-generation-test.sh
sh ../openwrt/tests/procd-contract-test.sh
```
