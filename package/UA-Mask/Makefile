#
# UA-Mask 的 OpenWrt 包定义（本仓库适配版）
#
# 与上游 openwrt/package/Makefile 的差异（同目录 Makefile.upstream 是上游原件，便于比对）：
#   1. 上游把包定义放在 <repo>/openwrt/package/ 下，靠 PACKAGE_DIR/REPO_ROOT 反推源码目录；
#      本仓库把它放在 package/UA-Mask/Makefile（包目录根），路径统一用 ./core 与 ./openwrt/root、./openwrt/luci。
#      ⚠️ 为什么不能沿用 package/UA3F/openwrt/Makefile 那种布局：OpenWrt 的 include/scan.awk
#      用「目录名的最后一段」当 key 去重（PKGS[$NF]），两个包目录都叫 openwrt 时会互相覆盖 ——
#      实测表现是其中一个包在 `make defconfig` 里被静默丢掉、metadata 里查不到。
#      包目录名保持唯一（UA-Mask）才是稳的。
#   2. 包名用 OpenWrt 惯例的小写 uamask（上游是 UAmask）。二进制仍叫 /usr/bin/UAmask、
#      配置仍是 /etc/config/UAmask —— 这两个名字被 init 脚本和 LuCI 页面写死，不能改。
#   3. 去掉 UAMASK_PREBUILT（用预编译二进制打包）那条支路：本仓库一律从源码编译，少一条路径少一个坑。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=uamask
# 与 ../VERSION 保持一致（写死而不用 $(shell cat ../VERSION)：包元数据扫描阶段的
# 工作目录不保证是包目录，相对路径读文件会偶发失败。更新 vendor 时两处一起改。）
PKG_VERSION:=0.4.3
PKG_RELEASE:=1

PKG_MAINTAINER:=Zesuy <hongri580@gmail.com>
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=UAmask
GO_PKG_BUILD_PKG:=$(GO_PKG)/cmd/UAmask
GO_PKG_LDFLAGS_X:=main.version=v$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/uamask
	SECTION:=net
	CATEGORY:=Network
	SUBMENU:=Web Servers/Proxies
	TITLE:=High performance User-Agent rewriting transparent proxy
	URL:=https://github.com/Zesuy/UA-Mask
	# libubox 提供 jshn.sh（init 脚本用它把 UCI 渲染成 core 的 config.json）
	# luci-compat 提供这套 Lua CBI 页面运行所需的兼容层
	DEPENDS:=$(GO_ARCH_DEPENDS) +libubox +luci-compat
	CONFLICTS:=ua3f ua3f-tproxy ua3f-tproxy-ipt
endef

define Package/uamask/description
	UA-Mask 是一个面向 OpenWrt 的高性能、低占用 User-Agent 修改透明代理，
	用于规避校园网对多设备共享上网的检测。
	核心特性：REDIRECT 透明代理；关键词/正则两种匹配；UA 白名单 +
	非 HTTP 目标自动卸载到 nftables 集合（命中后流量不再进入用户态代理）；
	停止服务时自动清理防火墙规则。
endef

define Build/Prepare
	$(CP) ./core/go.mod ./core/go.sum ./core/cmd ./core/internal $(PKG_BUILD_DIR)/
	$(CP) ./LICENSE $(PKG_BUILD_DIR)/
endef

define Package/uamask/conffiles
/etc/config/UAmask
endef

define Package/uamask/install
	$(call GoPackage/Package/Install/Bin,$(PKG_INSTALL_DIR))

	$(INSTALL_DIR) $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/UAmask $(1)/usr/bin/UAmask

	$(INSTALL_DIR) $(1)/etc/init.d/
	$(INSTALL_BIN) ./openwrt/root/etc/init.d/UAmask $(1)/etc/init.d/UAmask

	$(INSTALL_DIR) $(1)/etc/config/
	$(INSTALL_CONF) ./openwrt/root/etc/config/UAmask $(1)/etc/config/UAmask

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/
	$(INSTALL_DATA) ./openwrt/luci/model/cbi/UAmask.lua $(1)/usr/lib/lua/luci/model/cbi/UAmask.lua

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DATA) ./openwrt/luci/controller/UAmask.lua $(1)/usr/lib/lua/luci/controller/UAmask.lua
endef

define Package/uamask/postrm
#!/bin/sh
uci -q set UAmask.enabled.enabled=0
uci -q commit UAmask
[ -f "/etc/config/ucitrack" ] && {
	uci -q delete ucitrack.UAmask
	uci -q commit ucitrack
}
exit 0
endef

$(eval $(call GoBinPackage,uamask))
$(eval $(call BuildPackage,uamask))
