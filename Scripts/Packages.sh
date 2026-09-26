#!/bin/bash

#安装和更新软件包
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local PKG_LIST=("$PKG_NAME" $5)  # 第5个参数为自定义名称列表
	local REPO_NAME=${PKG_REPO#*/}

	echo " "

	# 删除本地可能存在的不同名称的软件包
	for NAME in "${PKG_LIST[@]}"; do
		# 查找匹配的目录
		echo "Search directory: $NAME"
		local FOUND_DIRS
		FOUND_DIRS=$(find ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)

		# 删除找到的目录
		if [ -n "$FOUND_DIRS" ]; then
			while read -r DIR; do
				rm -rf "$DIR"
				echo "Delete directory: $DIR"
			done <<< "$FOUND_DIRS"
		else
			echo "Not found directory: $NAME"
		fi
	done

	# 克隆 GitHub 仓库
	git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git"

	local PKG_COMMIT
	PKG_COMMIT=$(git -C "$REPO_NAME" rev-parse --short HEAD 2>/dev/null || echo unknown)
	if [ -n "$GITHUB_WORKSPACE" ]; then
		echo "$PKG_NAME $PKG_REPO $PKG_BRANCH $PKG_COMMIT" >> "$GITHUB_WORKSPACE/package-versions.txt"
	fi

	# 处理克隆的仓库
	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		find "./$REPO_NAME"/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./ \;
		rm -rf "./$REPO_NAME/"
	elif [[ "$PKG_SPECIAL" == "name" ]]; then
		mv -f "$REPO_NAME" "$PKG_NAME"
	fi
}

# 调用示例
# UPDATE_PACKAGE "OpenAppFilter" "destan19/OpenAppFilter" "master" "" "custom_name1 custom_name2"
# UPDATE_PACKAGE "open-app-filter" "destan19/OpenAppFilter" "master" "" "luci-app-appfilter oaf" 这样会把原有的open-app-filter，luci-app-appfilter，oaf相关组件删除，不会出现coremark错误。

# UPDATE_PACKAGE "包名" "项目地址" "项目分支" "pkg/name，可选，pkg为从大杂烩中单独提取包名插件；name为重命名为包名"
#UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-25.12"
#UPDATE_PACKAGE "aurora" "ones20250/luci-theme-aurora" "master"
#UPDATE_PACKAGE "aurora-config" "ones20250/luci-app-aurora-config" "master"
#UPDATE_PACKAGE "kucat" "sirpdboy/luci-theme-kucat" "master"
#UPDATE_PACKAGE "kucat-config" "sirpdboy/luci-app-kucat-config" "master"

#UPDATE_PACKAGE "homeproxy" "ones20250/homeproxy" "master"
#UPDATE_PACKAGE "momo" "nikkinikki-org/OpenWrt-momo" "main"
#UPDATE_PACKAGE "nikki" "nikkinikki-org/OpenWrt-nikki" "main"
if [[ "${WRT_PROFILE^^}" == "PLUS" ]]; then
	# LuCI 入口随 "pkg" 通配一并提取，依赖包（xray、sing-box、geodata 等）
	# 由 passwall_packages feed 提供，避免同名包双重定义。
	UPDATE_PACKAGE "openclash" "vernesong/OpenClash" "master" "pkg"
	# PassWall / PassWall2：本 fork 已移除（与 OpenClash 功能重叠）。
	# 要恢复：取消下面对应行的注释，并同步启用 Config/GENERAL_AX6600_PLUS.txt 里的配置段
	# 以及 .github/workflows/WRT-CORE.yml 里 passwall_packages 那行 feed。
	#UPDATE_PACKAGE "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"
	#UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"
	# 分区扩容与网络唤醒：源码仅 PLUS 版拉取，PURE 中同名 =y 配置因无源码自动失效
	UPDATE_PACKAGE "partexp" "sirpdboy/luci-app-partexp" "main"
	UPDATE_PACKAGE "viking" "ones20250/packages" "main" "" "luci-app-timewol luci-app-wolplus"
fi

#UPDATE_PACKAGE "mosdns" "sbwml/luci-app-mosdns" "v5" "" "v2dat"

#UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"

#UPDATE_PACKAGE "ddns-go" "sirpdboy/luci-app-ddns-go" "main"
#UPDATE_PACKAGE "diskman" "lisaac/luci-app-diskman" "master"
#UPDATE_PACKAGE "easytier" "EasyTier/luci-app-easytier" "main"
#UPDATE_PACKAGE "gecoosac" "laipeng668/luci-app-gecoosac" "main"
#UPDATE_PACKAGE "netspeedtest" "sirpdboy/netspeedtest" "main" "" "homebox speedtest"
#UPDATE_PACKAGE "openlist2" "sbwml/luci-app-openlist2" "main"
#UPDATE_PACKAGE "partexp" "sirpdboy/luci-app-partexp" "main"
#UPDATE_PACKAGE "qbittorrent" "sbwml/luci-app-qbittorrent" "master" "" "qt6base qt6tools rblibtorrent"
#UPDATE_PACKAGE "qmodem" "FUjr/QModem" "main"
#UPDATE_PACKAGE "quickfile" "sbwml/luci-app-quickfile" "main"
#局域网唤醒
#UPDATE_PACKAGE "viking" "ones20250/packages" "main" "" "luci-app-timewol luci-app-wolplus"
#UPDATE_PACKAGE "vnt" "lmq8267/luci-app-vnt" "main"
#雅典娜的led屏：改用 unraveloop 版（Rust 核心 + LuCI JS 界面，v2.3.0 起拆成 athena-led + luci-app-athena-led 两包）
#为什么要钉 v2.4.0 而不是 main：上游 main 的 Makefile 已 bump 到 PKG_VERSION:=2.5.0，
#但 releases 里最新只有 v2.4.0，跟 main 会在下载阶段 404。
#"pkg" 模式：把仓库里的 athena-led/ 与 luci-app-athena-led/ 提到 package/ 根层；
#第五个参数让删除逻辑顺带清掉 feeds 里的同名残留。
UPDATE_PACKAGE "athena-led" "unraveloop/JDC-AX6600-Athena-LED-Controller" "v2.4.0" "pkg" "luci-app-athena-led"

#基础源码树 ones20250/immortalwrt_ipq 自带一个**同名**的 luci-app-athena-led
#（package/emortal/luci-app-athena-led，1.0-r20260610，内含预编译 Go 二进制、仓库里没有源码）。
#不删掉会出现两个同名包，命中 include/scan.awk 按目录尾名取 key 的坑（静默丢一个），
#而且它的 /usr/sbin/athena-led 会和新包的 /usr/bin/athena-led 并存，init 到底谁生效很难查。
#顺序很关键：先确认新包到位，再删旧包 —— 万一上游下载失败，宁可保留旧实现也不要两头空。
if [ -f ./athena-led/Makefile ] && [ -f ./luci-app-athena-led/Makefile ]; then
	_ATHENA_VER=$(grep -Po '^PKG_VERSION:=\K.*' ./athena-led/Makefile)

	#上游写的是 PKG_HASH:=skip（不校验哈希），这里钉成 v2.4.0 release 的实测 sha256
	#对应文件：athena-led-aarch64-unknown-linux-musl-v2.4.0.tar.gz
	_ATHENA_SHA256="243560a5e6bb52e5a493f7efa528771a6ab26e325a69b6e1d9d89647eaac5f3f"
	sed -i "s|^PKG_HASH:=skip$|PKG_HASH:=$_ATHENA_SHA256|" ./athena-led/Makefile
	if grep -q "PKG_HASH:=$_ATHENA_SHA256" ./athena-led/Makefile; then
		echo "athena-led v$_ATHENA_VER: PKG_HASH 已钉为发布包 sha256"
	else
		echo "⚠️  athena-led: PKG_HASH 既不是 skip 也不是预期值，请人工确认：$(grep -Po '^PKG_HASH:=\K.*' ./athena-led/Makefile)"
	fi

	if [ -d ./emortal/luci-app-athena-led ]; then
		rm -rf ./emortal/luci-app-athena-led
		echo "已移除旧的一体化实现：package/emortal/luci-app-athena-led"
	fi
	if [ -d ./emortal/luci-app-athena-led ]; then
		echo "❌ 旧包仍在 ./emortal/luci-app-athena-led，会与新包同名冲突，拒绝继续"
		exit 1
	fi
	echo "athena-led v$_ATHENA_VER 就位（新界面：服务 → Athena LED）"
else
	echo "❌ athena-led 新包未就位（./athena-led/Makefile 或 ./luci-app-athena-led/Makefile 缺失）"
	echo "   UPDATE_PACKAGE 大概率失败了。请检查上面的 git clone 输出；"
	echo "   若是版本问题，改成本仓库 Scripts/Packages.sh 里的分支参数（上游 releases 现有版本见项目 Releases 页）。"
	echo "   本次直接判失败，避免编出一个 LED 屏还是旧实现的固件。"
	exit 1
fi

#更新软件包版本
UPDATE_VERSION() {
	local PKG_NAME=$1
	local PKG_MARK=${2:-false}
	local PKG_FILES=$(find ./ ../feeds/packages/ -maxdepth 3 -type f -wholename "*/$PKG_NAME/Makefile")

	if [ -z "$PKG_FILES" ]; then
		echo "$PKG_NAME not found!"
		return
	fi

	echo -e "\n$PKG_NAME version update has started!"

	for PKG_FILE in $PKG_FILES; do
		local PKG_REPO=$(grep -Po "PKG_SOURCE_URL:=https://.*github.com/\K[^/]+/[^/]+(?=.*)" $PKG_FILE)
		local PKG_TAG=$(curl -sL "https://api.github.com/repos/$PKG_REPO/releases" | jq -r "map(select(.prerelease == $PKG_MARK)) | first | .tag_name")

		local OLD_VER=$(grep -Po "PKG_VERSION:=\K.*" "$PKG_FILE")
		local OLD_URL=$(grep -Po "PKG_SOURCE_URL:=\K.*" "$PKG_FILE")
		local OLD_FILE=$(grep -Po "PKG_SOURCE:=\K.*" "$PKG_FILE")
		local OLD_HASH=$(grep -Po "PKG_HASH:=\K.*" "$PKG_FILE")

		local PKG_URL=$([[ "$OLD_URL" == *"releases"* ]] && echo "${OLD_URL%/}/$OLD_FILE" || echo "${OLD_URL%/}")

		local NEW_VER=$(echo $PKG_TAG | sed -E 's/[^0-9]+/\./g; s/^\.|\.$//g')
		local NEW_URL=$(echo $PKG_URL | sed "s/\$(PKG_VERSION)/$NEW_VER/g; s/\$(PKG_NAME)/$PKG_NAME/g")
		local NEW_HASH=$(curl -sL "$NEW_URL" | sha256sum | cut -d ' ' -f 1)

		echo "old version: $OLD_VER $OLD_HASH"
		echo "new version: $NEW_VER $NEW_HASH"

		if [[ "$NEW_VER" =~ ^[0-9].* ]] && dpkg --compare-versions "$OLD_VER" lt "$NEW_VER"; then
			sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=$NEW_VER/g" "$PKG_FILE"
			sed -i "s/PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/g" "$PKG_FILE"
			echo "$PKG_FILE version has been updated!"
		else
			echo "$PKG_FILE version is already the latest!"
		fi
	done
}

#UPDATE_VERSION "软件包名" "测试版，true，可选，默认为否"
#UPDATE_VERSION "sing-box"

# ── 本 fork 新增：随仓库分发的 UA-Mask（校园网 UA 伪装）──────────────────────────
# 配方仓库里的 package/ 不会被构建系统自动看到，所以在这里把它拷进构建树。
# 本步骤的 cwd 是 wrt/package/（见 WRT-CORE.yml「Custom Packages」步骤）。
_uamask_repo="$(cd "$(dirname "$0")/.." && pwd)"
if [ -d "$_uamask_repo/package/UA-Mask" ]; then
	rm -rf ./UA-Mask
	cp -r "$_uamask_repo/package/UA-Mask" ./UA-Mask
	echo "UA-Mask(vendored): 已拷入 wrt/package/UA-Mask（$(find ./UA-Mask -type f | wc -l) 个文件）"
	if [ -n "${GITHUB_WORKSPACE:-}" ]; then
		echo "UAmask vendored-in-repo (upstream 83846d3) $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$GITHUB_WORKSPACE/package-versions.txt"
	fi
else
	echo "⚠️  没找到 $_uamask_repo/package/UA-Mask —— uamask 不会被编进固件"
fi
