# 第三方组件与许可

本仓库是**配方仓库**（配置 + 脚本 + 文档），构建时由 CI 拉取上游源码树。
下面列出仓库内直接包含、或构建时会被拉取的第三方组件及其许可。

## 仓库内直接包含

| 组件 | 许可 | 位置 | 说明 |
|---|---|---|---|
| **UA-Mask**（[Zesuy/UA-Mask](https://github.com/Zesuy/UA-Mask)，commit `83846d3780b1e30f87816310ae75d95798a5bd4d`） | **GPL-3.0-only** | `package/UA-Mask/` | 以**源码形式** vendored 进来，含上游 `LICENSE` 原件；本地改动记录见 `package/UA-Mask/LOCAL-NOTES.md` |
| **campus-onekey.sh / easytier-onekey.sh** | **MIT** | `files/scripts/` | 来自 [2476818641/Login-edu](https://github.com/2476818641/Login-edu)（`school-onekey` 分支）的副本，上游为 MIT 许可 |

> 因为仓库内以源码形式分发了 GPL-3.0-only 的 UA-Mask，本仓库自有内容同样以 **GPL-3.0-only** 发布（见 `LICENSE.md`），
> 以避免授权冲突。MIT 组件的许可声明保留在本文件中。

## 构建时拉取（不在本仓库内）

| 组件 | 许可 | 获取方式 |
|---|---|---|
| [EasyTier/EasyTier](https://github.com/EasyTier/EasyTier) v2.6.4 | **LGPL-3.0** | `Scripts/Packages.sh` 从 Releases 拉预编译产物 |
| [EasyTier/luci-app-easytier](https://github.com/EasyTier/luci-app-easytier) v2.6.4 | **Apache-2.0** | 同上 |
| [unraveloop/JDC-AX6600-Athena-LED-Controller](https://github.com/unraveloop/JDC-AX6600-Athena-LED-Controller) v2.4.0 | **Apache-2.0** | 同上（预编译 Rust 产物） |
| [vernesong/OpenClash](https://github.com/vernesong/OpenClash) | **MIT** | 同上 |
| [AdguardTeam/AdGuardHome](https://github.com/AdguardTeam/AdGuardHome) | **GPL-3.0** | 由基础源码树 / feeds 提供 |
| 基础源码树 [ones20250/immortalwrt_ipq](https://github.com/ones20250/immortalwrt_ipq) | 继承 OpenWrt / ImmortalWrt | **不在本仓库内**，编译时由 CI 拉取 |
| OpenWrt / ImmortalWrt / LuCI 及其 feeds | GPL-2.0 / Apache-2.0 / MIT 等 | 同上 |
| 内核与驱动（含 Qualcomm NSS 二进制固件） | 各自许可（含闭源固件） | 同上 |

## 分发说明

- 本仓库**不包含**任何上游源码树、内核或固件二进制；产物（固件镜像）里的第三方组件版权归各自作者所有
- 固件内**不包含**任何账号、密码、房间密钥等个人凭据
- vendored 组件在同步上游时请一并更新其 `LICENSE` 与许可声明
