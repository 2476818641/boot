#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# campus-net-setup.sh —— 校园网接入一键配置（防识别四件套：MAC / TTL / MTU / UA + PPPoE / 网页认证）
#
# 做什么：
#   1) 问接入方式：PPPoE / 网页认证（要验证脚本）/ 我已经用 WiFi 连上了校园网
#   2) 配好上网口的 MAC 克隆、TTL（默认 64）、MTU、UA（UA2F）并生效
#   3) 等 20 秒，ping / curl 试外网
#   4) 不通且是网页认证 → 调用验证脚本登录 → 再测
#
# 用法：
#   sh campus-net-setup.sh                  # 交互式
#   DRY_RUN=1 sh campus-net-setup.sh        # 只打印要做的改动，不落盘、不断网
#   WAIT_SECS=30 sh campus-net-setup.sh     # 改等待秒数（默认 20）
#   WANIF=wwan sh campus-net-setup.sh       # 指定上网接口（默认自动探测 wan / wwan）
#
# 非交互（可选）：
#   CAMPUS_MODE=pppoe CAMPUS_USER=学号 CAMPUS_PASS=密码 sh campus-net-setup.sh
#   CAMPUS_MODE=portal PORTAL_SCRIPT=/etc/campus-portal-auth.sh sh campus-net-setup.sh
#
# 只改 UCI 配置 + 一个 /etc/nftables.d 里的 nft 规则文件，不装任何软件包。
# /etc/nftables.d/ 在 firewall4 的 keep.d 里，所以刷固件升级后 TTL 规则仍在。
#
# 无线上网（STA）注意：必须"路由模式"（wwan 独立接口 + NAT），
# 不能用 relayd/WDS 那种桥接中继 —— 桥接是二层转发、不过 IP 栈，UA2F 与 TTL 都不会生效。

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

run() {	# 干跑模式只打印
	if [ "$DRY_RUN" = 1 ]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
}
log() { [ "$DRY_RUN" = 1 ] || logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }
ask() {	# ask <提示> <默认值> -> $REPLY
	_p="$1"; _d="${2:-}"
	if [ -n "$_d" ]; then printf '%s [%s]: ' "$_p" "$_d"; else printf '%s: ' "$_p"; fi
	if ! read -r REPLY; then REPLY=""; fi
	[ -z "$REPLY" ] && REPLY="$_d"
	return 0
}
uget() { uci -q get "$1" 2>/dev/null; }

[ "$(id -u)" = 0 ] || die "请用 root 运行（需要改网络与防火墙配置）"
command -v uci >/dev/null 2>&1 || die "找不到 uci —— 这个脚本要在 OpenWrt 路由器上运行"

# ---------------------------------------------------------------- 探测现状
# 上网接口：优先 WANIF 环境变量，否则看 wan 有没有设备，再看 wwan（无线 STA）
if [ -z "${WANIF:-}" ]; then
	if [ -n "$(uget network.wan.device)$(uget network.wan.ifname)" ]; then WANIF="wan"
	elif [ -n "$(uget network.wwan.device)$(uget network.wwan.ifname)" ]; then WANIF="wwan"
	else WANIF="wan"; fi
fi
WANDEV="$(uget network.$WANIF.device)"; [ -z "$WANDEV" ] && WANDEV="$(uget network.$WANIF.ifname)"
WANDEV="${WANDEV%% *}"; [ -z "$WANDEV" ] && WANDEV="$WANIF"
OLD_PROTO="$(uget network.$WANIF.proto)"
DEFDEV="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"

# LAN 侧网桥：TTL 规则排除它们，其余出口一律改写 → 网线 / PPPoE / 无线 STA 通吃
LAN_DEVS=""
for _s in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.type='bridge'$/\1/p"); do
	_n="$(uget network.$_s.name)"
	[ -n "$_n" ] && LAN_DEVS="$LAN_DEVS \"$_n\","
done
[ -z "$LAN_DEVS" ] && LAN_DEVS=' "br-lan",'
LAN_DEVS="${LAN_DEVS%,}"
LAN_DEVS="${LAN_DEVS# }"

info "当前状态"
msg "    上网接口     : network.$WANIF（设备 $WANDEV，proto ${OLD_PROTO:-未知}）"
msg "    默认路由出口 : ${DEFDEV:-还没通}"
msg "    当前 WAN MAC : $(cat "/sys/class/net/$WANDEV/address" 2>/dev/null || echo 未知)"
msg "    当前 WAN MTU : $(cat "/sys/class/net/$WANDEV/mtu" 2>/dev/null || echo 未知)"
msg "    TTL 规则     : $([ -f "$TTL_FILE" ] && echo "有（$TTL_FILE，会被覆盖）" || echo 无)"
if [ -x /usr/bin/ua2f ] || [ -n "$(uget ua2f.enabled.enabled)" ]; then
	msg "    UA2F         : 已安装（启用=$([ "$(uget ua2f.enabled.enabled)" = 1 ] && echo 是 || echo 否)）"
else
	msg "    UA2F         : 未安装"
fi
case "$DEFDEV" in
*sta*|wlan*|ra[0-9]*|apcl*)
	warn "默认路由出口 $DEFDEV 是无线（STA）→ 必须是**路由模式**（wwan 独立接口 + NAT），"
	msg "         不能桥接中继（relayd/WDS）：桥接走二层、不过 IP 栈，UA2F 和 TTL 都不会生效"
	;;
esac
if [ "$WANIF" = "wan" ] && [ -r "/sys/class/net/$WANDEV/carrier" ] && \
   [ "$(cat "/sys/class/net/$WANDEV/carrier" 2>/dev/null)" = "0" ]; then
	warn "网口 $WANDEV 没有链路（carrier=0）：如果你是靠 WiFi 上校园网，"
	msg "         请用 WANIF=wwan sh 本脚本，或者选方式 3（脚本才知道该配哪个接口）"
fi

# ---------------------------------------------------------------- 1) 接入方式
info "1/4 选择接入方式"
if [ -z "$CAMPUS_MODE" ]; then
	msg "    1) PPPoE（要账号密码，拨号）"
	msg "    2) 网页认证（DHCP 拿地址后，去认证页登录）"
	msg "    3) 我已经用 WiFi 连上校园网了（uplink 是无线 STA，出口走 wwan）"
	ask "    你的方式" "2"
	case "$REPLY" in
	1|pppoe|PPPoE) CAMPUS_MODE="pppoe" ;;
	2|portal|web|网页|网页认证) CAMPUS_MODE="portal" ;;
	3|wifi|wlan|无线) CAMPUS_MODE="portal"; WIFI_UPLINK=1 ;;
	*) die "没看懂：$REPLY（填 1/2/3）" ;;
	esac
fi
msg "    → $CAMPUS_MODE${WIFI_UPLINK:+（无线上网）}"

if [ -n "${WIFI_UPLINK:-}" ]; then
	ask "    无线上网用哪个接口（已经建好的 STA 网络名）" "wwan"
	WANIF="$REPLY"
	WANDEV="$(uget network.$WANIF.device)"; [ -z "$WANDEV" ] && WANDEV="$WANIF"
	ask "    无线 STA 的 SSID（不填=不改，仅确认用）" ""
	[ -n "$REPLY" ] && msg "    已记录 SSID: $REPLY（脚本不改无线配置；没建好的话见文末命令）"
fi

PPPOE_USER=""; PPPOE_PASS=""
if [ "$CAMPUS_MODE" = "pppoe" ]; then
	PPPOE_USER="${CAMPUS_USER:-}"; PPPOE_PASS="${CAMPUS_PASS:-}"
	[ -z "$PPPOE_USER" ] && { ask "    PPPoE 账号（学号）" ""; PPPOE_USER="$REPLY"; }
	[ -z "$PPPOE_PASS" ] && { ask "    PPPoE 密码" ""; PPPOE_PASS="$REPLY"; }
	[ -n "$PPPOE_USER" ] || die "PPPoE 账号不能为空"
else
	if [ -z "$PORTAL_SCRIPT" ]; then
		msg "    网页认证需要一个「验证脚本」：拿地址 → 提交账号密码 → 判断结果。"
		msg "    没有就先留空，脚本会探测出认证页地址给你（按回车跳过）。"
		ask "    验证脚本路径" ""
		PORTAL_SCRIPT="$REPLY"
	fi
	if [ -n "$PORTAL_SCRIPT" ] && [ ! -f "$PORTAL_SCRIPT" ]; then
		warn "找不到 $PORTAL_SCRIPT —— 先继续配置，稍后放上去再手动跑一次"
		PORTAL_SCRIPT=""
	fi
fi

# ---------------------------------------------------------------- 2) 防识别四件套
info "2/4 配置 MAC / TTL / MTU / UA"

# --- 2.1 MAC 克隆
ask "    要克隆的 MAC（回车=不改，auto=用当前 DHCP 租约里第一台设备）" ""
CLONE_MAC="$REPLY"
case "$CLONE_MAC" in
auto|AUTO)
	CLONE_MAC="$(awk 'NF>=3 && $2 ~ /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/ {print $2; exit}' /tmp/dhcp.leases 2>/dev/null)"
	[ -n "$CLONE_MAC" ] || warn "      /tmp/dhcp.leases 里没找到租约，跳过 MAC 克隆"
	;;
esac
if [ -n "$CLONE_MAC" ]; then
	printf '%s' "$CLONE_MAC" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' \
		|| die "MAC 格式不对：$CLONE_MAC（要 AA:BB:CC:DD:EE:FF）"
	if [ -n "${WIFI_UPLINK:-}" ]; then
		msg "    注意：无线上网的 MAC 通常要写在 wireless 的 wifi-iface 上（驱动可能有限制）"
		msg "          本脚本写的是 network 的 device 段；若无效就手动加："
		msg "          uci set wireless.<STA段>.macaddr='$CLONE_MAC'"
	fi
	DEVSEC="$(uci show network 2>/dev/null | awk -F"'" -v d="$WANDEV" \
		'$1 ~ /\.name=$/ && $2 == d { s=$1; sub(/^network\./,"",s); sub(/\.name=$/,"",s); print s; exit }')"
	if [ -z "$DEVSEC" ]; then
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

# --- 2.2 MTU
DEF_MTU=1500
[ "$CAMPUS_MODE" = "pppoe" ] && DEF_MTU=1492
[ -n "${WIFI_UPLINK:-}" ] && DEF_MTU=keep	# 无线侧 MTU 由 AP 决定，别乱改
ask "    MTU（回车=$DEF_MTU，不想改就填 keep）" "$DEF_MTU"
MTU="$REPLY"
if [ "$MTU" != "keep" ] && [ -n "$MTU" ]; then
	case "$MTU" in *[!0-9]*) die "MTU 必须是数字：$MTU" ;; esac
	run uci set "network.$WANIF.mtu=$MTU"
	[ "$CAMPUS_MODE" = "pppoe" ] && run uci set "network.$WANIF.mru=$MTU"
	msg "    MTU → $MTU"
fi

# --- 2.3 TTL：除了本地网桥，其它出口一律改写
if [ "$DRY_RUN" = 1 ]; then
	printf '    [dry-run] 写 %s：\n' "$TTL_FILE"
	printf '              chain ttl_fix { ... oifname != { %s } ip ttl set %s ... }\n' "$LAN_DEVS" "$TTL_VALUE"
else
	mkdir -p "$(dirname "$TTL_FILE")"
	[ -f "$TTL_FILE" ] && cp -f "$TTL_FILE" "$TTL_FILE.bak"
	cat > "$TTL_FILE" <<-EOF
	# campus-net-setup.sh 生成：校园网防 TTL 检测
	# fw4 会把 /etc/nftables.d/*.nft 包含进 table inet fw4，这里定义一条自己的 postrouting 链
	# （priority mangle + 1，比 fw4 自带的 mangle_postrouting 晚一步执行）。
	# 语义：除本地网桥（LAN）以外的所有出口，IPv4 TTL 与 IPv6 hop limit 都改成 $TTL_VALUE。
	# 要改设备/关掉：改或删掉本文件后执行 fw4 reload
	chain ttl_fix {
	    type filter hook postrouting priority mangle + 1; policy accept;
	    oifname != { $LAN_DEVS } ip ttl set $TTL_VALUE
	    oifname != { $LAN_DEVS } ip6 hoplimit set $TTL_VALUE
	}
	EOF
	msg "    TTL → 固定 $TTL_VALUE（排除 $LAN_DEVS，其余出口全改）"
fi

# --- 2.4 UA（UA2F）
UA2F_ENABLED=""
if [ -x /usr/bin/ua2f ] || [ -n "$(uget ua2f.enabled.enabled)" ]; then
	CUR_EN="$(uget ua2f.enabled.enabled)"; [ -z "$CUR_EN" ] && CUR_EN=1
	CUR_UA="$(uget ua2f.main.custom_ua)"
	CUR_TLS="$(uget ua2f.firewall.handle_tls)"; [ -z "$CUR_TLS" ] && CUR_TLS=0
	CUR_INTRA="$(uget ua2f.firewall.handle_intranet)"; [ -z "$CUR_INTRA" ] && CUR_INTRA=1
	msg "    UA2F 现状：启用=${CUR_EN} 自定义UA=${CUR_UA:-（空=用内置默认）} 处理443=$CUR_TLS 处理内网=$CUR_INTRA"

	ask "    启用 UA2F（改写 User-Agent，校园网防检测核心）" "$CUR_EN"
	case "$REPLY" in
	1|y|Y|yes|是)
		UA2F_ENABLED=1
		msg "    自定义 UA 可填：keep=不改 / empty=清空用内置默认 / win=常见 Chrome UA / 或直接粘贴整串"
		ask "    自定义 UA" "${CUR_UA:-keep}"
		UA_NEW="$REPLY"
		case "$UA_NEW" in
		keep|KEEP) ;;
		empty|EMPTY) run uci set ua2f.main.custom_ua='' ;;
		win|WIN|chrome)
			run uci set ua2f.main.custom_ua='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36' ;;
		*) run uci set "ua2f.main.custom_ua=$UA_NEW" ;;
		esac
		ask "    也处理 443 端口的明文 HTTP（handle_tls，校园网常在 443 上做检测）" "$CUR_TLS"
		case "$REPLY" in 1|y|Y|yes|是) run uci set ua2f.firewall.handle_tls='1' ;; *) run uci set ua2f.firewall.handle_tls='0' ;; esac
		ask "    也处理内网地址流量（handle_intranet；认证页在内网又登不上时改 0）" "$CUR_INTRA"
		case "$REPLY" in 1|y|Y|yes|是) run uci set ua2f.firewall.handle_intranet='1' ;; *) run uci set ua2f.firewall.handle_intranet='0' ;; esac
		run uci set ua2f.firewall.handle_fw='1'		# 必须开，否则 ua2f 不建规则链
		run uci set ua2f.enabled.enabled='1'
		;;
	*)
		UA2F_ENABLED=0
		run uci set ua2f.enabled.enabled='0'
		msg "    UA2F → 关闭"
		;;
	esac
else
	warn "没装 ua2f（/usr/bin/ua2f 不存在）—— 跳过 UA 部分"
	msg "    想装：apk add ua2f luci-app-ua2f（自编译固件建议直接加进 .config 重编）"
fi

# ---------------------------------------------------------------- 3) 应用
info "3/4 应用配置"
if [ "$CAMPUS_MODE" = "pppoe" ]; then
	NEW_PROTO='pppoe'
	run uci set "network.$WANIF.proto=pppoe"
	run uci set "network.$WANIF.username=$PPPOE_USER"
	run uci set "network.$WANIF.password=$PPPOE_PASS"
	run uci set "network.$WANIF.ipv6=1"
	run uci set "network.$WANIF.peerdns=1"
else
	NEW_PROTO='dhcp'
	run uci set "network.$WANIF.proto=dhcp"
fi
run uci commit network
if [ -n "${UA2F_ENABLED:-}" ]; then run uci commit ua2f; fi

if [ "$DRY_RUN" = 1 ]; then
	printf '    [dry-run] /etc/init.d/network %s\n' "$([ "$OLD_PROTO" != "$NEW_PROTO" ] && echo restart || echo reload)"
	printf '    [dry-run] fw4 reload\n'
	[ -n "${UA2F_ENABLED:-}" ] && printf '    [dry-run] /etc/init.d/ua2f %s\n' "$([ "$UA2F_ENABLED" = 1 ] && echo restart || echo stop)"
else
	if [ "$OLD_PROTO" != "$NEW_PROTO" ]; then
		msg "    proto 变了（${OLD_PROTO:-空} → $NEW_PROTO），用 restart"
		run /etc/init.d/network restart
	else
		run /etc/init.d/network reload
	fi
	sleep 2
	command -v fw4 >/dev/null 2>&1 && run fw4 reload
	if [ -n "${UA2F_ENABLED:-}" ]; then
		if [ "$UA2F_ENABLED" = 1 ]; then
			run /etc/init.d/ua2f restart
			sleep 1
			if pgrep -f '[u]a2f' >/dev/null 2>&1; then msg "    ua2f 进程：在跑 ✅"; else warn "    ua2f 没跑起来，看 logread | grep ua2f"; fi
		else
			run /etc/init.d/ua2f stop
		fi
	fi
	log "applied: iface=$WANIF mode=$CAMPUS_MODE mac=${CLONE_MAC:-unchanged} mtu=${MTU:-unchanged} ttl=$TTL_VALUE ua2f=${UA2F_ENABLED:-none}"
fi

# ---------------------------------------------------------------- 4) 等 20 秒 → 测 → 认证
info "4/4 等待 ${WAIT_SECS} 秒后检测外网"
[ "$DRY_RUN" = 1 ] || sleep "$WAIT_SECS"

check_net() {
	ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && return 0
	_c="$(curl -s -m 8 -o /dev/null -w '%{http_code}' http://www.baidu.com 2>/dev/null)"
	[ "$_c" = "200" ] && return 0
	return 1
}
portal_url() {
	curl -s -m 8 -o /dev/null -w '%{redirect_url}' \
		http://connect.rom.miui.com/generate_204 2>/dev/null
}

if check_net; then
	info "外网已通 ✅"
	msg "    出口 IP : $(curl -s -m 8 http://ip.3322.net 2>/dev/null || echo 取不到)"
	[ "${UA2F_ENABLED:-0}" = 1 ] && msg "    验 UA   : 浏览器打开 http://ua-check.stagoh.com/ 看 User-Agent 是否已统一"
else
	warn "还没通"
	if [ "$CAMPUS_MODE" = "portal" ]; then
		U="$(portal_url)"
		[ -n "$U" ] && msg "    认证页地址：$U"
		if [ -n "$PORTAL_SCRIPT" ]; then
			i=1
			while [ "$i" -le 3 ]; do
				info "运行验证脚本（第 $i 次）：$PORTAL_SCRIPT"
				if [ -x "$PORTAL_SCRIPT" ]; then run "$PORTAL_SCRIPT"
				else warn "    没有执行权限，改用 sh 跑（建议 chmod +x）"; run sh "$PORTAL_SCRIPT"; fi
				[ "$DRY_RUN" = 1 ] && break
				sleep 5
				if check_net; then info "认证成功，外网已通 ✅"; log "portal auth ok after $i try"; break; fi
				warn "    还是不通，重试…"
				i=$((i + 1))
			done
			if ! check_net; then
				warn "脚本跑了但还不通，常见原因："
				msg "    1) 认证页在内网、被 UA2F 改了 UA → 把 ua2f.firewall.handle_intranet 设 0 再试"
				msg "    2) MAC 没生效（无线上网要写在 wifi-iface 上）"
				msg "    3) 账号已在别处登录，或需要先在认证页手动登一次"
			fi
		else
			warn "没有验证脚本，只能帮你到这儿。自己去认证页登录一次，或者写一个："
			cat <<-'EOF'
			    验证脚本模板（存成 /etc/campus-portal-auth.sh，然后 chmod +x）：
			      #!/bin/sh
			      # 上面那行就是认证页地址；用 F12 → 网络 抓一次登录请求，照着抄字段：
			      curl -s -o /dev/null -X POST 'http://认证页/登录接口' \
			        -d 'user=学号&pass=密码&…'
			      # 判断成功：拿到 204 就算通
			      curl -s -o /dev/null -w '%{http_code}\n' http://connect.rom.miui.com/generate_204
			EOF
		fi
	else
		warn "PPPoE 没拨上：检查账号密码、是否需要 VLAN、以及 VLAN ID"
		msg "    看日志：logread | tail -30   （找 pppd 报错）"
		msg "    看状态：ifstatus $WANIF | head -40"
	fi
fi

info "完成"
cat <<EOF
    以后要改：LuCI → 网络 → 接口 → 设备（MAC/MTU）／ 网络 → UA2F（UA 相关）
    TTL 规则：$TTL_FILE（改完 fw4 reload；关掉就删掉它再 fw4 reload）
    接入方式：uci set network.$WANIF.proto=... 之后 /etc/init.d/network restart
    无线 STA 还没建好？最小配置（SSID/密码换成你的）：
      uci set wireless.sta=wifi-iface
      uci set wireless.sta.device=radio0
      uci set wireless.sta.mode=sta
      uci set wireless.sta.ssid='校园网 SSID'
      uci set wireless.sta.encryption=none     # 校园网多为开放+网页认证；有密码就写 psk2 并补 key
      uci set wireless.sta.network=wwan
      uci set network.wwan=interface
      uci set network.wwan.proto=dhcp
      uci commit wireless; uci commit network; wifi reload; /etc/init.d/network restart
    注意：wwan 要留在 wan 防火墙区，并且不要用 relayd/WDS 把 lan 和 wwan 桥起来 ——
          桥接走二层、不过 IP 栈，UA2F 与 TTL 都不会生效，要的是路由模式 + NAT。
EOF
