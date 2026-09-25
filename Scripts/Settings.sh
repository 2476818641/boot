#!/bin/bash

apply_sed_to_matches() {
	local SEARCH_DIR=$1
	local FILE_NAME=$2
	local SED_EXPR=$3
	local MATCHES

	MATCHES=$(find "$SEARCH_DIR" -type f -name "$FILE_NAME" 2>/dev/null)
	if [ -n "$MATCHES" ]; then
		while IFS= read -r TARGET_FILE; do
			sed -i "$SED_EXPR" "$TARGET_FILE"
		done <<< "$MATCHES"
	fi
}

#移除luci-app-attendedsysupgrade
apply_sed_to_matches "./feeds/luci/collections/" "Makefile" "/attendedsysupgrade/d"

#修改默认主题（本 fork 启用：WRT_THEME 在 QCA-ALL.yml 里是 argon）
#上游这三行原本是注释掉的 —— 不启用的话 WRT_THEME 只是个摆设，界面永远是 bootstrap
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#下面这行是"换回 bootstrap"的备用写法，保持注释
#sed -i "s/luci-theme-.*$/luci-theme-bootstrap/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")

#修改immortalwrt.lan关联IP
apply_sed_to_matches "./feeds/luci/modules/luci-mod-system/" "flash.js" "s/192\\.168\\.[0-9]*\\.[0-9]*/$WRT_IP/g"
#添加编译日期标识
apply_sed_to_matches "./feeds/luci/modules/luci-mod-status/" "10_system.js" "s/(\\(luciversion || ''\\))/(\\1) + (' \\/ $WRT_MARK-$WRT_DATE')/g"

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" "$WIFI_SH"
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" "$WIFI_SH"
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	#sed -i "s/country='.*'/country='US'/g" $WIFI_UC
	#修改WIFI加密
	#sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG_FILE"
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
#本 fork 启用：主题包与设置页也写进 .config（Config/GENERAL_AX6600.txt 里同样显式选中，双保险）
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find "$DTS_PATH" -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

# =========================================================
# 智能系统调优：优化内存水位线 (min_free_kbytes)
# =========================================================

MIN_FREE_VAL=16384
CONF_FILE="./package/base-files/files/etc/sysctl.conf"

# 提取当前值（只匹配非注释、行首）
CURRENT_VAL=$(sed -n 's/^vm\.min_free_kbytes=\([0-9]\+\).*/\1/p' "$CONF_FILE")

if [ -z "$CURRENT_VAL" ]; then
    echo "" >> "$CONF_FILE"
    echo "vm.min_free_kbytes=$MIN_FREE_VAL" >> "$CONF_FILE"
    echo "Memory patch: value not found, added $MIN_FREE_VAL."
else
    if [ "$CURRENT_VAL" -lt "$MIN_FREE_VAL" ]; then
        sed -i "s/^vm\.min_free_kbytes=.*/vm.min_free_kbytes=$MIN_FREE_VAL/" "$CONF_FILE"
        echo "Memory patch: upgraded $CURRENT_VAL -> $MIN_FREE_VAL."
    else
        echo "Memory patch: current value ($CURRENT_VAL) is sufficient, skipped."
    fi
fi

# ── 本 fork 新增：把校园网 TTL 规则编进固件 ──────────────────────────────────
# 目的：刷完就有 TTL 伪装，不需要额外脚本去写。改值编辑 /etc/nftables.d/10-ttl-fix.nft 后 fw4 reload。
_TTL_SRC="$(cd "$(dirname "$0")/.." && pwd)/files/ttl/10-ttl-fix.nft"
if [ -f "$_TTL_SRC" ]; then
	mkdir -p ./package/base-files/files/etc/nftables.d
	cp -f "$_TTL_SRC" ./package/base-files/files/etc/nftables.d/10-ttl-fix.nft
	echo "TTL: 已编进固件 /etc/nftables.d/10-ttl-fix.nft（值 $(sed -n 's/.*ip ttl set \([0-9]*\).*/\1/p' "$_TTL_SRC" | head -1)）"
else
	echo "⚠️  没找到 $_TTL_SRC —— TTL 规则不会被编进固件"
fi

# ── 本 fork：把 LuCI 默认主题设成 Argon（与 Q30 Pro 同款）─────────────────────
# 装包只让 argon"可选"；LuCI 的默认主题由 luci.main.mediaurlbase 决定，
# luci-base 默认写 /luci-static/bootstrap —— 所以还要这个 uci-defaults 兜底。
_LT_SRC="$(cd "$(dirname "$0")/.." && pwd)/files/luci/99-luci-theme"
if [ -f "$_LT_SRC" ]; then
	mkdir -p ./package/base-files/files/etc/uci-defaults
	cp -f "$_LT_SRC" ./package/base-files/files/etc/uci-defaults/99-luci-theme
	chmod +x ./package/base-files/files/etc/uci-defaults/99-luci-theme
	echo "Theme: 已编入 uci-defaults（默认主题 Argon）"
else
	echo "⚠️  没找到 $_LT_SRC —— 默认主题仍是 bootstrap"
fi

# ── 本 fork：默认只开一个 AP（radio2 5G），SSID=imm 密码=liuasd111 ──────────────
_WR_SRC="$(cd "$(dirname "$0")/.." && pwd)/files/luci/99-wifi-radio"
if [ -f "$_WR_SRC" ]; then
	mkdir -p ./package/base-files/files/etc/uci-defaults
	cp -f "$_WR_SRC" ./package/base-files/files/etc/uci-defaults/99-wifi-radio
	chmod +x ./package/base-files/files/etc/uci-defaults/99-wifi-radio
	echo "WiFi: 已编入 uci-defaults（只开 radio2，SSID=imm）"
else
	echo "⚠️  没找到 $_WR_SRC —— WiFi 默认值不会被改"
fi
