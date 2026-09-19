#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# campus-net-setup.sh —— 校园网接入一键配置（MAC 克隆 / TTL / MTU / PPPoE / 网页认证）
#
# 做什么：
#   1) 问你是 PPPoE 还是网页认证（网页认证要你给一个"验证脚本"路径）
#   2) 先把 WAN 的 MAC 克隆、TTL（默认 64）、MTU 配好并生效
#   3) 等 20 秒，ping / curl 试外网
#   4) 不通且是网页认证 → 调用你的验证脚本登录 → 再测一遍
#
# 用法：
#   sh campus-net-setup.sh                 # 交互式
#   DRY_RUN=1 sh campus-net-setup.sh       # 只打印要做的改动，不落盘、不重启网络
#   WAIT_SECS=30 sh campus-net-setup.sh    # 改等待时间（默认 20 秒）
#
# 非交互（可选）：
#   CAMPUS_MODE=pppoe CAMPUS_USER=学号 CAMPUS_PASS=密码 sh campus-net-setup.sh
#   CAMPUS_MODE=portal PORTAL_SCRIPT=/etc/campus-portal-auth.sh sh campus-net-setup.sh
#
# 说明：只动 UCI 配置 + 一个 /etc/nftables.d 里的 nft 规则文件，不装任何软件包。
#       /etc/nftables.d/ 在 firewall4 的 keep.d 里，所以刷固件升级后规则仍在。

set -u

DRY_RUN="${DRY_RUN:-0}"
WAIT_SECS="${WAIT_SECS:-20}"
TTL_VALUE="${TTL_VALUE:-64}"
TTL_FILE="${TTL_FILE:-/etc/nftables.d/10-ttl-fix.nft}"
LOG_TAG="campus-setup"
PORTAL_SCRIPT="${PORTAL_SCRIPT:-}"
CAMPUS_MODE="${CAMPUS_MODE:-}"

msg()  { printf '%s\n' "$*"; }
info() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[!] %s\033[0m\n' "$*" >&2; exit 1; }

run() {	# 干跑模式下只打印
	if [ "$DRY_RUN" = 1 ]; then
		printf '    [dry-run] %s\n' "$*"
	else
		"$@"
	fi
}
log() { [ "$DRY_RUN" = 1 ] || logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }

ask() {	# ask <提示> <默认值> -> 结果放 $REPLY
	_p="$1"; _d="${2:-}"
	if [ -n "$_d" ]; then printf '%s [%s]: ' "$_p" "$_d"; else printf '%s: ' "$_p"; fi
	if ! read -r REPLY; then REPLY=""; fi
	[ -z "$REPLY" ] && REPLY="$_d"
}

[ "$(id -u)" = 0 ] || die "请用 root 运行（需要改网络与防火墙配置）"
command -v uci >/dev/null 2>&1 || die "找不到 uci —— 这个脚本要在 OpenWrt 路由器上运行"

# ---------------------------------------------------------------- 探测现状
WAN_IF="wan"
if [ -n "$(uci -q get network.wan.device)" ]; then
	WANDEV="$(uci -q get network.wan.device)"
elif [ -n "$(uci -q get network.wan.ifname)" ]; then
	WANDEV="$(uci -q get network.wan.ifname)"
else
	WANDEV="$WAN_IF"
fi
WANDEV="${WANDEV%% *}"			# 只取第一个（多设备时）
OLD_PROTO="$(uci -q get network.wan.proto)"

info "当前状态"
msg "    WAN 接口     : network.wan（设备 $WANDEV，proto ${OLD_PROTO:-未知}）"
msg "    当前 WAN MAC : $(cat /sys/class/net/$WANDEV/address 2>/dev/null || echo 未知)"
msg "    当前 WAN MTU : $(cat /sys/class/net/$WANDEV/mtu 2>/dev/null || echo 未知)"
msg "    已有 TTL 规则: $([ -f "$TTL_FILE" ] && echo "有（$TTL_FILE，会被覆盖）" || echo 无)"

# ---------------------------------------------------------------- 1) 接入方式
info "1/4 选择接入方式"
if [ -z "$CAMPUS_MODE" ]; then
	msg "    1) PPPoE（要账号密码，拨号）"
	msg "    2) 网页认证（DHCP 拿地址后，去认证页登录）"
	ask "    你的方式" "2"
	case "$REPLY" in
	1|pppoe|PPPoE) CAMPUS_MODE="pppoe" ;;
	2|portal|web|网页|网页认证) CAMPUS_MODE="portal" ;;
	*) die "没看懂：$REPLY（填 1 或 2）" ;;
	esac
fi
msg "    → $CAMPUS_MODE"

PPPOE_USER=""; PPPOE_PASS=""
if [ "$CAMPUS_MODE" = "pppoe" ]; then
	PPPOE_USER="${CAMPUS_USER:-}"; PPPOE_PASS="${CAMPUS_PASS:-}"
	[ -z "$PPPOE_USER" ] && { ask "    PPPoE 账号（学号）" ""; PPPOE_USER="$REPLY"; }
	[ -z "$PPPOE_PASS" ] && { ask "    PPPoE 密码" ""; PPPOE_PASS="$REPLY"; }
	[ -n "$PPPOE_USER" ] || die "PPPoE 账号不能为空"
else
	if [ -z "$PORTAL_SCRIPT" ]; then
		msg "    网页认证需要一个「验证脚本」：拿地址 → 提交账号密码 → 判断结果。"
		msg "    没有的话先留空，脚本会探测出认证页地址给你（按回车跳过）。"
		ask "    验证脚本路径" ""
		PORTAL_SCRIPT="$REPLY"
	fi
	if [ -n "$PORTAL_SCRIPT" ] && [ ! -f "$PORTAL_SCRIPT" ]; then
		warn "找不到 $PORTAL_SCRIPT —— 先继续配置，稍后你把脚本放上去再手动跑一次"
		PORTAL_SCRIPT=""
	fi
fi

# ---------------------------------------------------------------- 2) MAC / TTL / MTU
info "2/4 配置 MAC 克隆 / TTL / MTU"

# --- MAC 克隆
ask "    要克隆的 MAC（回车=不改，auto=用当前 DHCP 租约里第一台设备）" ""
CLONE_MAC="$REPLY"
case "$CLONE_MAC" in
	auto|AUTO)
		CLONE_MAC="$(awk 'NF>=3 && $2 ~ /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/ {print $2; exit}' /tmp/dhcp.leases 2>/dev/null)"
		[ -n "$CLONE_MAC" ] || { warn "      /tmp/dhcp.leases 里没找到租约，跳过 MAC 克隆"; }
		;;
esac
if [ -n "$CLONE_MAC" ]; then
	printf '%s' "$CLONE_MAC" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' \
		|| die "MAC 格式不对：$CLONE_MAC（要 AA:BB:CC:DD:EE:FF）"
	# 优先写进 device 段（和 LuCI「网络→接口→设备」一致）
	DEVSEC="$(uci show network 2>/dev/null | awk -F"'" -v d="$WANDEV" \
		'$1 ~ /\.name=$/ && $2 == d { s=$1; sub(/^network\./,"",s); sub(/\.name=$/,"",s); print s; exit }')"
	if [ -z "$DEVSEC" ]; then
		msg "    为设备 $WANDEV 新建 device 段"
		if [ "$DRY_RUN" = 1 ]; then
			printf '    [dry-run] uci add network device; uci set network.<新段>.name=%s macaddr=%s\n' "$WANDEV" "$CLONE_MAC"
		else
			DEVSEC="$(uci add network device)"
			run uci set "network.$DEVSEC.name=$WANDEV"
		fi
	fi
	[ -n "$DEVSEC" ] && run uci set "network.$DEVSEC.macaddr=$CLONE_MAC"
	msg "    MAC 克隆 → $CLONE_MAC"
fi

# --- MTU
DEF_MTU=1500
[ "$CAMPUS_MODE" = "pppoe" ] && DEF_MTU=1492
ask "    MTU（回车=$DEF_MTU，不想改就填 keep）" "$DEF_MTU"
MTU="$REPLY"
if [ "$MTU" != "keep" ] && [ -n "$MTU" ]; then
	case "$MTU" in *[!0-9]*) die "MTU 必须是数字：$MTU" ;; esac
	run uci set "network.wan.mtu=$MTU"
	[ "$CAMPUS_MODE" = "pppoe" ] && run uci set "network.wan.mru=$MTU"
	msg "    MTU → $MTU"
fi

# --- TTL（写进 fw4 的表，匹配 WAN 出方向）
# PPPoE 的 IP 包从 pppoe-<设备> 出去；普通 DHCP 就从 <设备> 出去，两个都写上更保险
TTL_DEVS="\"$WANDEV\""
case "$CAMPUS_MODE" in
pppoe) TTL_DEVS="\"pppoe-$WANDEV\"" ;;
*)     TTL_DEVS="\"$WANDEV\", \"pppoe-$WANDEV\"" ;;	# nft 匿名集合元素要逗号分隔
esac
if [ "$DRY_RUN" = 1 ]; then
	printf '    [dry-run] 写 %s:\n' "$TTL_FILE"
	printf '              chain ttl_fix { type filter hook postrouting priority mangle + 1; policy accept;\n'
	printf '                  oifname { %s } ip ttl set %s\n                  oifname { %s } ip6 hoplimit set %s }\n' \
		"$TTL_DEVS" "$TTL_VALUE" "$TTL_DEVS" "$TTL_VALUE"
else
	mkdir -p "$(dirname "$TTL_FILE")"
	[ -f "$TTL_FILE" ] && cp -f "$TTL_FILE" "$TTL_FILE.bak"
	cat > "$TTL_FILE" <<-EOF
	# campus-net-setup.sh 生成：校园网防 TTL 检测
	# fw4 会把 /etc/nftables.d/*.nft 包含进 table inet fw4，
	# 所以这里定义一条自己的 postrouting 链（比 fw4 自带的 mangle_postrouting 晚 1 步执行）。
	# 要改 WAN 设备名/关掉：改或删掉本文件后执行 fw4 reload
	chain ttl_fix {
	    type filter hook postrouting priority mangle + 1; policy accept;
	    oifname { $TTL_DEVS } ip ttl set $TTL_VALUE
	    oifname { $TTL_DEVS } ip6 hoplimit set $TTL_VALUE
	}
	EOF
	msg "    TTL → 固定 $TTL_VALUE（$TTL_FILE）"
fi

# ---------------------------------------------------------------- 3) 应用
info "3/4 应用配置"
if [ "$CAMPUS_MODE" = "pppoe" ]; then
	NEW_PROTO='pppoe'
	run uci set network.wan.proto='pppoe'
	run uci set "network.wan.username=$PPPOE_USER"
	run uci set "network.wan.password=$PPPOE_PASS"
	run uci set network.wan.ipv6='1'
	run uci set network.wan.peerdns='1'
else
	NEW_PROTO='dhcp'
	run uci set network.wan.proto='dhcp'
fi
run uci commit network

if [ "$DRY_RUN" = 1 ]; then
	printf '    [dry-run] /etc/init.d/network %s\n' "$([ "$OLD_PROTO" != "$NEW_PROTO" ] && echo restart || echo reload)"
	printf '    [dry-run] fw4 reload\n'
else
	if [ "$OLD_PROTO" != "$NEW_PROTO" ]; then
		msg "    proto 变了（$OLD_PROTO → $NEW_PROTO），用 restart"
		run /etc/init.d/network restart
	else
		run /etc/init.d/network reload
	fi
	sleep 2
	command -v fw4 >/dev/null 2>&1 && run fw4 reload
	log "applied: mode=$CAMPUS_MODE mac=${CLONE_MAC:-unchanged} mtu=${MTU:-unchanged} ttl=$TTL_VALUE"
fi

# ---------------------------------------------------------------- 4) 等 20 秒 → 测 → 认证
info "4/4 等待 ${WAIT_SECS} 秒后检测外网"
[ "$DRY_RUN" = 1 ] || sleep "$WAIT_SECS"

check_net() {	# 返回 0=通
	ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && return 0
	_c="$(curl -s -m 8 -o /dev/null -w '%{http_code}' http://www.baidu.com 2>/dev/null)"
	[ "$_c" = "200" ] && return 0
	return 1
}

portal_url() {	# 探测被劫持到哪个认证页（连不上外网时才有意义）
	curl -s -m 8 -o /dev/null -w '%{redirect_url}' \
		http://connect.rom.miui.com/generate_204 2>/dev/null
}

if check_net; then
	info "外网已通 ✅（ping 223.5.5.5 或 curl baidu.com 成功）"
	msg "    出口 IP: $(curl -s -m 8 http://ip.3322.net 2>/dev/null || echo '取不到')"
else
	warn "还没通"
	if [ "$CAMPUS_MODE" = "portal" ]; then
		U="$(portal_url)"
		[ -n "$U" ] && msg "    认证页地址：$U"
		if [ -n "$PORTAL_SCRIPT" ]; then
			i=1
			while [ "$i" -le 3 ]; do
				info "运行验证脚本（第 $i 次）：$PORTAL_SCRIPT"
				if [ -x "$PORTAL_SCRIPT" ]; then
					run "$PORTAL_SCRIPT"
				else
					warn "    没有执行权限，改用 sh 跑（建议 chmod +x）"
					run sh "$PORTAL_SCRIPT"
				fi
				[ "$DRY_RUN" = 1 ] && break
				sleep 5
				if check_net; then
					info "认证成功，外网已通 ✅"
					log "portal auth ok after $i try"
					break
				fi
				warn "    还是不通，重试…"
				i=$((i + 1))
			done
		else
			warn "没有验证脚本，只能帮你到这儿。自己去认证页登录一次，或者写一个："
			cat <<-'EOF'
			    验证脚本模板（存成 /etc/campus-portal-auth.sh 然后 chmod +x）：
			      #!/bin/sh
			      # 1) 看认证页地址（上面那行）
			      # 2) 用 curl 提交账号密码，具体字段 F12 抓一次就知道：
			      curl -s -o /dev/null -X POST 'http://认证页/登录接口' \
			        -d 'user=学号&pass=密码&…'
			      # 3) 判断结果：再拉一次 generate_204，拿到 204 就算成功
			      curl -s -o /dev/null -w '%{http_code}\n' http://connect.rom.miui.com/generate_204
			EOF
		fi
	else
		warn "PPPoE 没拨上：检查账号密码、VLAN 是否需要、以及 VLAN ID"
		msg "    看日志：logread | tail -30   （找 pppd 的报错）"
		msg "    看状态：ifstatus wan | head -40"
	fi
fi

info "完成"
cat <<EOF
    以后要改：LuCI → 网络 → 接口 → 设备（改 MAC/MTU）／直接编辑 $TTL_FILE 后 fw4 reload
    关掉 TTL 改写：rm -f $TTL_FILE && fw4 reload
    接入方式换回/改动：uci set network.wan.proto=... 之后 /etc/init.d/network restart
EOF
