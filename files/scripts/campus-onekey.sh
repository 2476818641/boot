#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# campus-onekey.sh —— 本校校园网「单文件版」
#
# 一条命令走完三件事（顺序就是这个顺序：先伪装，再认证，最后装启动项）：
#   ① 伪装   UA-Mask（把各设备的 UA 统一成一台 PC + 协议敏感流量放行/卸载到内核）+ TTL 内核规则
#             TTL 是**双向**的：出站统一成人设值（Windows=128），入站把校园网关改成 1 的
#             TTL 补回来 —— 少了入站那条，客户端 HTTPS 会全部连接超时（见下文 ttl_fix_in）
#   ② 认证   本校门户三步接口 login.php → stat.php → ack_auth.php（pass 用 AES-128-ECB 加密）
#   ③ 启动项 /etc/init.d/campus-onekey（开机）+ hotplug（网口上线）+ cron（每 5 分钟兜底）
#
# 用法：
#   sh campus-onekey.sh 账号 密码            # 全流程（幂等：已在线也会把伪装配置和启动项补齐）
#   sh campus-onekey.sh                      # 交互式问账号密码
#   sh campus-onekey.sh --status             # 状态：外网通不通、启动项装没装、伪装开着没
#   sh campus-onekey.sh --auth               # 只认证（不动伪装配置、不装启动项）
#   sh campus-onekey.sh --auto               # 给 cron/hotplug/init.d 用：静默，只认证
#   sh campus-onekey.sh --uninstall          # 卸掉启动项 + cron + hotplug
#   DRY_RUN=1 sh campus-onekey.sh 账号 密码    # 只打印要做的改动，不落盘
#   SKIP_DISGUISE=1 sh campus-onekey.sh 账号 密码   # 跳过伪装（在别的固件上先只搞认证）
#   TTL_VALUE=64 UA_STR='Mozilla/5.0 (Linux; Android 14; …)' sh campus-onekey.sh 账号 密码
#
# 换学校要改的只有下面「本校参数」那一段（门户地址、三个接口路径、字段名、加密 key）。
# 只用 POSIX sh 语法（路由器上是 dash/ash），不依赖 jq / python / od。
#
# 前提：固件里有 UAmask（本仓库固件内置）。没有也能跑 —— 会跳过伪装那一步并提示。
set -u

# ──────────────────────────────────────────────── 本校参数（换学校只改这一段）
PORTAL="${PORTAL:-http://10.30.100.5}"					# 门户地址
PRE_GET="${PRE_GET:-1}"							# 1=先 GET 首页拿 RAASSESSID 会话 cookie
PRE_PATHS="${PRE_PATHS:-/api/ip.php}"					# 登录前的前置接口（空 body）
API_PATHS="${API_PATHS:-/api/login.php,/api/stat.php,/api/ack_auth.php}"	# 按顺序提交的三步
EXTRA_FIELDS="${EXTRA_FIELDS:-authmode=0&pool=&isp_id=0&pxyacct=}"	# 固定附加字段
USER_FIELD="${USER_FIELD:-user}"
PASS_FIELD="${PASS_FIELD:-pass}"
RAAS_KEY="${RAAS_KEY:-5a3b9f207411a8ed}"				# AES-128-ECB 密钥（门户 JS 里那把）
RET_ACCEPT="${RET_ACCEPT:-0 3 121 122}"					# 这些 ret = 已接受，继续下一步
RET_RETRY="${RET_RETRY:-2 3 4}"						# 这些 ret = 处理中，等一会再问
RET_MAX_TRY="${RET_MAX_TRY:-6}"
RET_SLEEP="${RET_SLEEP:-3}"
# 伪装默认值（TTL 由 UA 人设推导：Windows→128 / Android·Linux·macOS→64）
UAMASK_UA_DEFAULT='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
UAMASK_REGEX='(iPhone|iPad|Android|Macintosh|Windows|Linux|Apple|Mac OS X|Mobile)'
UAMASK_WHITELIST_DEFAULT='QeeYouAcceler,Valve/Steam,HttpDns,Microsoft-CryptoAPI,Microsoft NCSI'
# ────────────────────────────────────────────────

# 可覆盖（测试/多份配置共存用）
TTL_FILE="${TTL_FILE:-/etc/nftables.d/10-ttl-fix.nft}"
SELF_INSTALL="${SELF_INSTALL:-/etc/campus-onekey.sh}"	# cron/hotplug/init.d 引用的固定路径
CRONTAB_FILE="${CRONTAB_FILE:-/etc/crontabs/root}"
HOOKDIR="${HOOKDIR:-/etc/hotplug.d/iface}"
HOOKFILE="$HOOKDIR/99-campus-portal"
INITHOOK="${INITHOOK:-/etc/init.d/campus-onekey}"
CONF="${CAMPUS_UCI_FILE:-/etc/config/campus}"		# 账号密码存这里（600）
COOKIE="${COOKIE:-/tmp/campus-onekey.cookie}"
CHECK_URL="${CHECK_URL:-http://connect.rom.miui.com/generate_204}"
PING_TARGET="${PING_TARGET:-223.5.5.5}"			# PING_TARGET=- 表示不做 ping 判定（测试用）
DRY_RUN="${DRY_RUN:-0}"
QUIET="${QUIET:-0}"
SKIP_DISGUISE="${SKIP_DISGUISE:-0}"
UA_STR="${UA_STR:-}"
UA_MODE="${UA_MODE:-regex}"				# regex（正表，推荐）/ all（全量）
UA_WHITELIST="${UA_WHITELIST:-}"
TTL_VALUE="${TTL_VALUE:-}"

# ──────────────────────────────────────────────── 基础工具
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
info() { [ "$QUIET" = 1 ] || printf '\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[!] %s\033[0m\n' "$*" >&2; exit 1; }
log()  { logger -t campus-onekey "$*" 2>/dev/null || true; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }
has()  { command -v "$1" >/dev/null 2>&1; }
uget() { has uci && uci -q get "$1" 2>/dev/null; }
ask() {	# ask <提示> <默认值> → $REPLY
	printf '%s [%s]: ' "$1" "${2:-}"; if ! read -r REPLY; then REPLY=""; fi
	[ -z "$REPLY" ] && REPLY="${2:-}"
}
online() {	# 外网通不通
	[ "$PING_TARGET" != "-" ] && ping -c 1 -W 2 "$PING_TARGET" >/dev/null 2>&1 && return 0
	_c="$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$CHECK_URL" 2>/dev/null)"
	case "$_c" in 200|204) return 0 ;; esac
	return 1
}
ret_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# 二进制 → 小写 hex。本项目固件的 busybox 没编 od（真机实测 "od: not found"），
# 所以按可用性探测回退：od → hexdump -e → hexdump -C → base64+awk。
hexify() {
	if has od && [ "$(printf '\001' | od -An -tx1 | tr -d ' \n')" = "01" ]; then
		od -An -tx1 | tr -d ' \n'; return 0
	fi
	if has hexdump; then
		if [ "$(printf '\001\002' | hexdump -v -e '1/1 "%02x"' 2>/dev/null)" = "0102" ]; then
			hexdump -v -e '1/1 "%02x"'; return 0
		fi
		if printf '\001\002' | hexdump -v -C 2>/dev/null | grep -q '01 02'; then
			sed 's/^[0-9a-fA-F]*  *//; s/  *|.*$//' | tr -d ' \n'; return 0
		fi
	fi
	if has base64; then
		base64 | awk '
			BEGIN { B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" }
			{
				for (i = 1; i <= length($0); i++) {
					v = index(B64, substr($0, i, 1)) - 1
					if (v < 0) continue
					n = n * 64 + v; bits += 6
					if (bits >= 8) { bits -= 8; printf "%02x", int(n / 2^bits) % 256; n = n % 2^bits }
				}
			}'
		return 0
	fi
	return 1
}

# 0-255 随机数。不能用 `hexdump -e '"%u"'`：它可能输出带前导零的 "081"，
# dash/ash 会当八进制解析而报 "Illegal number: 081"（真机踩过）。
rand_byte() {
	_b="$(head -c 1 /dev/urandom 2>/dev/null | hexify 2>/dev/null)"
	case "$_b" in [0-9a-fA-F][0-9a-fA-F]) printf '%d' "$(( 0x$_b ))"; return 0 ;; esac
	if [ -n "${RANDOM:-}" ]; then printf '%d' "$(( RANDOM % 256 ))"; return 0; fi
	printf '%d' "$(( $$ % 256 ))"
}

# 本校门户的 pass 算法（逆向了 raas.js）：
#   hex( AES-128-ECB( key="5a3b9f207411a8ed", 明文 = 4 个随机字符 + 真实密码, ZeroPadding ) )
# 服务端解出来后会剥掉前 4 个字符。若输入本身已是 32 位 [0-9A-Za-z]，按门户 JS 的语义直接透传。
raas_encode() {	# raas_encode <明文密码> → 32 位 hex；失败原因写进 RAAS_ERR
	RAAS_ERR=""
	case "$1" in
		????????????????????????????????)	# 正好 32 位
			case "$1" in *[!0-9A-Za-z]*) ;; *) printf '%s' "$1"; return 0 ;; esac ;;
	esac
	has openssl || { RAAS_ERR="没有 openssl（固件里要带 openssl-util）"; return 1; }
	_keyhex="$(printf '%s' "$RAAS_KEY" | hexify 2>/dev/null)"
	[ -n "$_keyhex" ] || { RAAS_ERR="没有可用的 hex 转换工具（od/hexdump/base64 都没有）"; return 1; }
	_alpha='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+'
	_nonce=''; _i=0
	while [ "$_i" -lt 4 ]; do
		_r="$(rand_byte)"; case "$_r" in ''|*[!0-9]*) _r=0 ;; esac
		_nonce="$_nonce$(printf '%s' "$_alpha" | cut -c$(( _r % 61 + 1 )))"
		_i=$((_i + 1))
	done
	_plain="$_nonce$1"
	_pad=$(( (16 - ${#_plain} % 16) % 16 ))
	_i=0
	{ printf '%s' "$_plain"; while [ "$_i" -lt "$_pad" ]; do printf '\0'; _i=$((_i + 1)); done; } \
		| openssl enc -aes-128-ecb -K "$_keyhex" -nopad 2>/dev/null | hexify
}

# 账号密码存 /etc/config/campus。**直接写文件**再读回校验：ImmortalWrt 25.12 的 uci CLI
# 在 `uci set campus.main='main'` 这种建段语法上会报 "Entry not found"（真机实测），
# 直接写文件最稳；读回来对得上才算成功，不谎报。
uci_escape() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }
write_conf() {	# write_conf <user> <pass>
	_tmp="$CONF.tmp.$$"
	{
		printf '%s\n' '# 由 campus-onekey.sh 生成（含明文密码，权限 600）'
		printf '%s\n' "config main 'main'"
		printf "\toption user '%s'\n" "$(uci_escape "$1")"
		printf "\toption pass '%s'\n" "$(uci_escape "$2")"
		printf "\toption auth_url '%s'\n" "$(uci_escape "$PORTAL")"
		printf "\toption api_paths '%s'\n" "$(uci_escape "$API_PATHS")"
	} > "$_tmp" || return 1
	mv -f "$_tmp" "$CONF" || { rm -f "$_tmp"; return 1; }
	chmod 600 "$CONF" 2>/dev/null
	if has uci; then
		[ "$(uci -q get campus.main.pass 2>/dev/null)" = "$2" ] || return 1
		uci -q commit campus 2>/dev/null || true
	fi
	return 0
}
read_conf() {	# 从配置里取 user/pass（环境变量优先）
	CAMPUS_USER="${CAMPUS_USER:-$(uget campus.main.user)}"
	CAMPUS_PASS="${CAMPUS_PASS:-$(uget campus.main.pass)}"
}

# ════════════════════════════════════════════════ ① 伪装：UA-Mask + TTL
ua_persona_ttl() {	# 按 UA 人设给 TTL：Windows=128，Android/Linux/macOS=64
	case "$1" in
	*Windows*) printf '128' ;;
	*Android*|*Linux*|*iPhone*|*iPad*|*Macintosh*|*"Mac OS X"*) printf '64' ;;
	*) printf '128' ;;
	esac
}

disable_ua3f() {	# 旧的 UA3F 会和 UA-Mask 抢 TCP，必须停掉并清表
	[ -x /etc/init.d/ua3f ] || [ -n "$(uget ua3f.enabled.enabled)" ] || return 0
	[ "$(uget ua3f.enabled.enabled)" = "0" ] && ! (has nft && nft list table inet UA3F >/dev/null 2>&1) && return 0
	say "    检测到旧方案 UA3F → 停用并清掉它的 nft 表"
	run uci set ua3f.enabled.enabled='0'
	run uci commit ua3f
	run /etc/init.d/ua3f stop
	# ⚠️ 关键：UA3F 的 stop 不清 nft。残留的 `tcp dport != {22} redirect to :1080`
	# 会把除 22 外的所有 TCP 吸进没人监听的端口 → "电脑没网但 ping 正常"
	has nft && run nft delete table inet UA3F
}

lan_dev() {	# TTL 规则要排除的 LAN 网桥
	_d="$(uget network.lan.device)"; _d="${_d%% *}"
	[ -n "$_d" ] || _d="br-lan"
	printf '%s' "$_d"
}

setup_disguise() {
	info "① 伪装：UA-Mask${TTL_VALUE:+ + TTL=$TTL_VALUE}"
	if [ -z "$(uget UAmask.enabled.enabled)" ] && [ ! -x /usr/bin/UAmask ]; then
		warn "    没装 UAmask —— 跳过 UA 改写（本仓库固件内置；老固件可手动装 uamask-*.apk）"
		warn "    仍然会配置 TTL；要跳过整步：SKIP_DISGUISE=1"
	else
		_ua="${UA_STR:-$UAMASK_UA_DEFAULT}"
		_wl="${UA_WHITELIST:-$UAMASK_WHITELIST_DEFAULT}"
		case "$UA_MODE" in all|ALL|blacklist) _mode='all' ;; *) _mode='regex' ;; esac
		disable_ua3f
		if [ "$DRY_RUN" = 1 ]; then
			printf '    [dry-run] uci set UAmask.enabled.enabled=1\n'
			printf '    [dry-run] uci set UAmask.main.ua=%s\n' "$_ua"
			printf '    [dry-run] uci set UAmask.main.match_mode=%s (+ua_regex=%s)\n' "$_mode" "$UAMASK_REGEX"
			printf '    [dry-run] uci set UAmask.main.Firewall_ua_whitelist=%s\n' "$_wl"
			printf '    [dry-run] uci set UAmask.main.enable_firewall_set=1 Firewall_ua_bypass=1 Firewall_drop_on_match=0\n'
			printf '    [dry-run] uci set UAmask.main.firewall_advanced_settings=1 firewall_nonhttp_threshold=1 firewall_decision_delay=10 firewall_timeout=86400\n'
			printf '    [dry-run] uci set UAmask.main.bypass_ports="22 443" proxy_host=0 operating_profile=Medium\n'
		else
			uci set UAmask.main.ua="$_ua" || warn "    uci set UAmask.main.ua 失败"
			uci set UAmask.main.match_mode="$_mode"
			uci set UAmask.main.ua_regex="$UAMASK_REGEX"
			uci set UAmask.main.replace_method='full'
			uci set UAmask.main.keywords=''
			uci set UAmask.main.whitelist=''		# 留空：填了等于让那些 UA 不被统一
			uci set UAmask.main.Firewall_ua_whitelist="$_wl"
			uci set UAmask.main.Firewall_drop_on_match='0'	# 必须 0：1 = 命中就掐断连接
			uci set UAmask.main.enable_firewall_set='1'	# 流量卸载总开关
			uci set UAmask.main.Firewall_ua_bypass='1'	# 非 HTTP 目标自动卸载到内核
			uci set UAmask.main.firewall_advanced_settings='1'
			uci set UAmask.main.firewall_nonhttp_threshold='1'	# 默认 5
			uci set UAmask.main.firewall_decision_delay='10'	# 默认 60
			uci set UAmask.main.firewall_timeout='86400'		# 默认 8h
			uci set UAmask.main.bypass_ports='22 443'	# ★443 不进代理 → Steam 等大流量不受影响
			uci set UAmask.main.bypass_ips='172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16'
			uci set UAmask.main.proxy_host='0'
			uci set UAmask.main.operating_profile='Medium'	# 256MB→Medium / 1GB→High 都行
			uci set UAmask.main.log_level='info'
			uci set UAmask.enabled.enabled='1'
			uci commit UAmask 2>/dev/null || warn "    uci commit UAmask 失败"
		fi
		run /etc/init.d/UAmask restart
		say "    UA-Mask：$_mode 模式，UA=$(printf '%.48s' "$_ua")…"
		say "    放行名单（不改写 + 命中即卸载出代理）：$_wl"
	fi

	# TTL：UA-Mask 没有 L3 功能，交给内核 nft 规则（除 LAN 网桥外所有出口统一）。
	# 固件里可能**已经内置**了这条规则（例如 AX6600 那套 fork 就是编进固件的）——
	# 默认不动它，只在显式给了 TTL_VALUE 时才覆盖，免得脚本和固件互相改。
	#
	# ★ 入站修复链（2026-09 新增，必须保证存在）：
	#   校园网关会把「经 NAT 的客户端」的入站 TCP 的 TTL 改成 1。Linux 转发时
	#   TTL 减 1 → 0 → 内核判定超时直接丢弃，表现为「客户端 HTTPS 全部连接超时，
	#   而路由器自己 curl 同一个站点完全正常」。抓包实锤（AX6600 实测）：
	#       104.69.162.222.443 > 10.30.176.186.56562: Flags [S.], ttl 1
	#       183.240.99.224.443 > 10.30.176.186.52206: Flags [S.], ttl 1
	#   为什么只有客户端 443 中招：本机连接是本地投递不转发；客户端 :80 被 UA-Mask
	#   REDIRECT 到本机中转（由路由器重新发起出网连接）也不算转发；只有被
	#   bypass_ports 豁免的 443 走真正的 NAT 转发路径。
	#   这也解释了历史疑问：「旧路由器单用 UA-Mask 不行、加 UA3F 就行」——UA3F 是
	#   tcp dport != {22}，连 443 也在本机中转，根本不需要 IP 转发。
	#   修法：把入站 TCP 里 ttl <= 2 的异常值补回 64（正常互联网包 50-60，不受影响）。
	_ttl_want="$(ua_persona_ttl "${UA_STR:-$UAMASK_UA_DEFAULT}")"
	_lan="$(lan_dev)"
	_ttl_have=""
	[ -f "$TTL_FILE" ] && _ttl_have="$(sed -n 's/.*ip ttl set \([0-9]*\).*/\1/p' "$TTL_FILE" 2>/dev/null | head -1)"
	if [ -n "$_ttl_have" ] && [ -z "$TTL_VALUE" ]; then
		say "    TTL → 保留固件自带的规则（当前 $_ttl_have；文件 $TTL_FILE）"
		if [ "$_ttl_have" != "$_ttl_want" ]; then
			warn "      注意：它与当前 UA 人设建议的 $_ttl_want 不一致（UA 说自己是哪个系统，TTL 就该对应：Windows=128 / Android·Linux·macOS=64）"
			say  "      要改：TTL_VALUE=$_ttl_want sh $0 …（或直接编辑该文件后 fw4 reload）"
		fi
		_ttl="$_ttl_have"
		# 保留固件规则的同时，确保入站修复链也在（老固件里通常只有出站链）
		if grep -q 'chain[[:space:]]*ttl_fix_in' "$TTL_FILE" 2>/dev/null; then
			say "    入站修复 → 已有 ttl_fix_in 链 ✓"
		elif [ "$DRY_RUN" = 1 ]; then
			printf '    [dry-run] 追加 chain ttl_fix_in 到 %s + fw4 reload\n' "$TTL_FILE"
		else
			cp -f "$TTL_FILE" "$TTL_FILE.bak"
			cat >> "$TTL_FILE" <<-'EOF'

			# 入站：校园网关把经 NAT 的客户端入站 TCP 的 TTL 改成 1，转发减 1 归零会被
			# 内核直接丢弃 → 客户端 HTTPS 全部超时、路由器自己却正常。只补 <=2 的异常值。
			chain ttl_fix_in {
			    type filter hook prerouting priority mangle; policy accept;
			    iifname "wan" ip protocol tcp ip ttl 0-2 ip ttl set 64
			}
			EOF
			has fw4 && run fw4 reload
			say "    入站修复 → 已补上 ttl_fix_in 链（不补的话客户端 HTTPS 会全超时）"
		fi
	elif [ "$DRY_RUN" = 1 ]; then
		_ttl="${TTL_VALUE:-$_ttl_want}"
		printf '    [dry-run] 写 %s: chain ttl_fix { oifname != { %s } ip ttl set %s; ip6 hoplimit set %s }\n' \
			"$TTL_FILE" "$_lan" "$_ttl" "$_ttl"
		printf '    [dry-run]          + chain ttl_fix_in { iifname "wan" ip protocol tcp ip ttl 0-2 ip ttl set 64 }\n'
		printf '    [dry-run] fw4 reload\n'
	else
		_ttl="${TTL_VALUE:-$_ttl_want}"
		mkdir -p "$(dirname "$TTL_FILE")"
		[ -f "$TTL_FILE" ] && cp -f "$TTL_FILE" "$TTL_FILE.bak"
		cat > "$TTL_FILE" <<-EOF
		# campus-onekey.sh 生成：校园网防 TTL 检测（双向）
		# fw4 会把 /etc/nftables.d/*.nft 包含进 table inet fw4。
		# 出站：除 LAN 网桥外所有出口，IPv4 TTL 与 IPv6 hop limit 统一成 $_ttl
		#       （与 UA 人设自洽：Windows=128 / Android·Linux·macOS=64）。
		# 入站：校园网关把经 NAT 的客户端入站 TCP 的 TTL 改成 1，转发减 1 归零会被内核
		#       直接丢弃 —— 表现为客户端 HTTPS 全部超时、而路由器自己 curl 一切正常。
		#       这里只把 ttl <= 2 的异常值补回 64（正常互联网包是 50-60，不受影响）。
		# 改值或关掉：改/删本文件后 fw4 reload
		chain ttl_fix {
		    type filter hook postrouting priority mangle + 1; policy accept;
		    oifname != { $_lan } ip ttl set $_ttl
		    oifname != { $_lan } ip6 hoplimit set $_ttl
		}

		chain ttl_fix_in {
		    type filter hook prerouting priority mangle; policy accept;
		    iifname "wan" ip protocol tcp ip ttl 0-2 ip ttl set 64
		}
		EOF
		has fw4 && run fw4 reload
		say "    TTL → 固定 $_ttl（排除 $_lan）+ 入站修复链，规则 $TTL_FILE"
	fi
}

# ════════════════════════════════════════════════ ② 认证：本校门户三步
curl_auth() { curl -s -m 15 -k "$@"; }	# 不走 UA 伪装（路由器自身流量不经 UA-Mask）

json_strip_jsonp() {
	case "$(printf '%s' "$1" | tr -d ' \t\r\n')" in
		'{'*|'['*) printf '%s' "$1" ;;
		*'('*')'*) printf '%s' "$1" | sed 's/^[^(]*(//; s/)[[:space:]]*;*[[:space:]]*$//' ;;
		*)         printf '%s' "$1" ;;
	esac
}
json_num() { printf '%s' "$1" | tr -d '\n' | sed -n "s/.*\"$2\":\(-\{0,1\}[0-9][0-9]*\).*/\1/p" | head -1; }
json_str() { printf '%s' "$1" | tr -d '\n' | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" | head -1; }

do_login() {
	info "② 认证：$PORTAL"
	read_conf
	if [ -z "${CAMPUS_USER:-}" ] || [ -z "${CAMPUS_PASS:-}" ]; then
		if [ "$QUIET" = 1 ]; then warn "    没有账号密码（跑一次：sh $0 账号 密码）"; return 1; fi
		[ -z "${CAMPUS_USER:-}" ] && ask "    学号/账号" ""
		CAMPUS_USER="$REPLY"
		[ -z "${CAMPUS_PASS:-}" ] && ask "    密码" ""
		CAMPUS_PASS="$REPLY"
	fi
	[ -n "$CAMPUS_USER" ] || { warn "    账号为空"; return 1; }
	_plain="$CAMPUS_PASS"
	PASSV="$(raas_encode "$_plain")" || { warn "    加密失败：$RAAS_ERR"; return 1; }
	# 存账号密码（明文，600），下次 --auto 就不用再给
	if [ "$DRY_RUN" = 1 ]; then
		printf '    [dry-run] 写 %s（user=%s）\n' "$CONF" "$CAMPUS_USER"
	else
		write_conf "$CAMPUS_USER" "$_plain" || warn "    写 $CONF 失败（认证仍会继续）"
	fi

	# ① 前置：GET 首页拿会话 cookie（抓包里三条 POST 都带 RAASSESSID）+ 前置接口
	if [ "$PRE_GET" = 1 ]; then
		[ "$DRY_RUN" = 1 ] || rm -f "$COOKIE"
		if [ "$DRY_RUN" = 1 ]; then
			printf '    [dry-run] GET %s/（拿 cookie）\n' "$PORTAL"
		else
			curl_auth -c "$COOKIE" -b "$COOKIE" -o /dev/null "$PORTAL/" 2>/dev/null \
				&& say "    已 GET $PORTAL/（会话 cookie）" || say "    首页 GET 失败，继续"
		fi
	fi
	for _pre in $(printf '%s' "$PRE_PATHS" | tr ',' ' '); do
		[ -n "$_pre" ] || continue
		case "$_pre" in /*) _purl="$PORTAL$_pre" ;; *) _purl="$PORTAL/$_pre" ;; esac
		if [ "$DRY_RUN" = 1 ]; then printf '    [dry-run] 前置 POST %s\n' "$_pre"; continue; fi
		PRERESP="$(curl_auth -b "$COOKIE" -c "$COOKIE" \
			-H 'X-Requested-With: XMLHttpRequest' -H "Referer: $PORTAL/" -H "Origin: $PORTAL" \
			-X POST --data '' "$_purl" 2>/dev/null)"
		say "    前置 $_pre → $(printf '%s' "$PRERESP" | head -c 120)"
	done
	if [ "$DRY_RUN" = 1 ]; then
		printf '    [dry-run] POST %s（pass=%s，含 4 位随机前缀的 AES 密文）\n' "$API_PATHS" "$PASSV"
		return 0
	fi

	# ② 按顺序提交三步（门户 JS 的语义：ret 0/3/121/122 继续；stat 的 2/3/4 = 处理中要轮询；login 的 4 = 密码错）
	STEP=0; TOTAL_STEPS=$(printf '%s' "$API_PATHS" | tr ',' ' ' | wc -w)
	LAST_MSG=""; LAST_RET=""; OK_MSG=""; FAILED=0
	for _path in $(printf '%s' "$API_PATHS" | tr ',' ' '); do
		[ -n "$_path" ] || continue
		STEP=$((STEP + 1))
		case "$_path" in /*) _url="$PORTAL$_path" ;; *) _url="$PORTAL/$_path" ;; esac
		_try=0
		while :; do
			_try=$((_try + 1))
			RESP="$(curl_auth -b "$COOKIE" -c "$COOKIE" \
				-H 'X-Requested-With: XMLHttpRequest' -H "Referer: $PORTAL/" -H "Origin: $PORTAL" \
				-X POST "$_url" \
				--data-urlencode "$USER_FIELD=$CAMPUS_USER" \
				--data-urlencode "$PASS_FIELD=$PASSV" \
				--data "$EXTRA_FIELDS" 2>/dev/null)"
			RESP="$(json_strip_jsonp "$RESP")"
			RET="$(json_num "$RESP" ret)"; MSG="$(json_str "$RESP" msg)"
			say "    [$STEP/$TOTAL_STEPS] $_path → ret=${RET:-?} msg=${MSG:-（空）}$([ "$_try" -gt 1 ] && echo "（第 $_try 次）")"
			LAST_MSG="$MSG"; LAST_RET="$RET"
			case "$MSG" in *'成功'*|*'success'*|*'已在线'*) OK_MSG="$MSG" ;; esac
			[ -z "$RET" ] && break
			ret_in "$RET" "$RET_ACCEPT" && break
			if [ "$STEP" = 1 ] && [ "$RET" = 4 ]; then
				warn "    账号或密码不正确（ret=4 msg=$MSG）"
				log "auth rejected: ret=4 (bad credentials, user=$CAMPUS_USER)"
				return 1
			fi
			if ret_in "$RET" "$RET_RETRY" && [ "$_try" -lt "$RET_MAX_TRY" ]; then
				say "    处理中（ret=$RET），${RET_SLEEP} 秒后再问"
				sleep "$RET_SLEEP"; continue
			fi
			warn "    认证被拒绝：$_path ret=$RET msg=$MSG"
			log "auth rejected at $_path: ret=$RET msg=$MSG"
			return 1
		done
	done
	[ "$STEP" -gt 0 ] || { warn "    没有可提交的接口"; return 1; }

	# ③ 判定：成功字样或连通性（双保险）
	case "${OK_MSG:-$LAST_MSG}" in
		*'成功'*|*'success'*|*'已在线'*) : ;;
		*)	sleep 2
			online || { warn "    认证失败（ret=${LAST_RET:-?} msg=$LAST_MSG）"; return 1; }
			;;
	esac
	sleep 2
	if online; then
		say "    认证成功 ✅"
		log "auth ok (user=$CAMPUS_USER)"
		return 0
	fi
	warn "    提交了但外网还不通（ret=${LAST_RET:-?} msg=$LAST_MSG）"
	return 1
}

# ════════════════════════════════════════════════ ③ 启动项
install_autostart() {
	info "③ 启动项：开机 / 网口上线 / 每 5 分钟兜底"
	if [ "$DRY_RUN" = 1 ]; then
		printf '    [dry-run] 装自己到 %s\n' "$SELF_INSTALL"
		printf '    [dry-run] 写 %s（rc.common，START=95 → 出现在 LuCI 系统→启动项）\n' "$INITHOOK"
		printf '    [dry-run] 写 %s（ifup 触发，重试 3 次）\n' "$HOOKFILE"
		printf '    [dry-run] cron: */5 * * * * %s --auto\n' "$SELF_INSTALL"
		return 0
	fi
	# ① 把自己放到固定路径（cron/hotplug/init.d 都引用它）
	_me="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
	if [ "$_me" != "$SELF_INSTALL" ]; then
		if cp -f "$_me" "$SELF_INSTALL" 2>/dev/null; then
			chmod +x "$SELF_INSTALL"; say "    已装到 $SELF_INSTALL"
		else
			warn "    复制到 $SELF_INSTALL 失败，启动项仍指向它（请手动放过去）"
		fi
	fi
	[ -x "$SELF_INSTALL" ] || chmod +x "$SELF_INSTALL" 2>/dev/null

	# ② init.d：开机跑一次（LuCI「系统 → 启动项」里能看见并开关）
	cat > "$INITHOOK" <<-EOF
	#!/bin/sh /etc/rc.common
	# 由 campus-onekey.sh 生成：开机自动认证
	START=95
	STOP=10
	start() { ( sleep 8; $SELF_INSTALL --auto ) & }
	EOF
	chmod +x "$INITHOOK"
	[ -x /etc/init.d/campus-onekey ] && /etc/init.d/campus-onekey enable >/dev/null 2>&1

	# ③ hotplug：网口一上线就认证（比等 cron 快）
	mkdir -p "$HOOKDIR"
	cat > "$HOOKFILE" <<-EOF
	#!/bin/sh
	# 由 campus-onekey.sh 生成：WAN 一上线就认证（最多重试 3 次）
	[ "\${ACTION:-}" = "ifup" ] || exit 0
	( i=1; while [ "\$i" -le 3 ]; do
		sleep 5
		$SELF_INSTALL --auto && { logger -t campus-onekey "认证成功（第 \$i 次）"; exit 0; }
		i=\$((i + 1))
	  done ) &
	EOF
	chmod +x "$HOOKFILE"

	# ④ cron：掉线兜底
	mkdir -p "$(dirname "$CRONTAB_FILE")"
	# 去重按"完整命令行"匹配（不要按脚本名匹配：$SELF_INSTALL 的路径可能不含该词）
	grep -qF "$SELF_INSTALL --auto" "$CRONTAB_FILE" 2>/dev/null || \
		echo "*/5 * * * * $SELF_INSTALL --auto >/dev/null 2>&1" >> "$CRONTAB_FILE"
	[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1
	say "    $INITHOOK（开机）+ $HOOKFILE（网口上线）+ cron 每 5 分钟"
}

uninstall_autostart() {
	info "卸载启动项"
	[ -x /etc/init.d/campus-onekey ] && { /etc/init.d/campus-onekey disable >/dev/null 2>&1; /etc/init.d/campus-onekey stop >/dev/null 2>&1; }
	run rm -f "$INITHOOK" "$HOOKFILE"
	# 只删我们加的那一行（按完整命令行匹配，别误删别人的 cron）
	if [ -f "$CRONTAB_FILE" ] && grep -qF "$SELF_INSTALL --auto" "$CRONTAB_FILE"; then
		run sh -c "grep -vF '$SELF_INSTALL --auto' '$CRONTAB_FILE' > '$CRONTAB_FILE.tmp' && mv '$CRONTAB_FILE.tmp' '$CRONTAB_FILE'"
	fi
	[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1
	say "    已移除 init.d / hotplug / cron 三项（账号密码仍在 $CONF）"
}

show_status() {
	printf '外网     : '; if online; then echo '通 ✅'; else echo '不通 ❌'; fi
	printf '账号     : %s\n' "$(uget campus.main.user)"
	printf '启动项   : init.d=%s hotplug=%s cron=%s\n' \
		"$([ -x "$INITHOOK" ] && echo 有 || echo 无)" \
		"$([ -f "$HOOKFILE" ] && echo 有 || echo 无)" \
		"$(grep -qF "$SELF_INSTALL --auto" "$CRONTAB_FILE" 2>/dev/null && echo 有 || echo 无)"
	if [ -x /usr/bin/UAmask ] || [ -n "$(uget UAmask.enabled.enabled)" ]; then
		printf 'UA-Mask  : 启用=%s 匹配=%s UA=%s\n' \
			"$(uget UAmask.enabled.enabled)" "$(uget UAmask.main.match_mode)" "$(printf '%.40s' "$(uget UAmask.main.ua)")"
	else
		printf 'UA-Mask  : 没装\n'
	fi
	if has nft && nft list table inet fw4 2>/dev/null | grep -qi uamask; then
		printf '卸载集合 : %s\n' "$(nft list set inet fw4 UAmask_bypass_set 2>/dev/null | grep -c 'elements' | sed 's/^0$/空（还没有非 HTTP 目标被卸载）/')"
	fi
	printf 'TTL 规则 : %s\n' "$([ -f "$TTL_FILE" ] && sed -n 's/.*ip ttl set \([0-9]*\).*/\1/p' "$TTL_FILE" | head -1 || echo 无)"
	if [ -f "$TTL_FILE" ]; then
		if grep -q 'chain[[:space:]]*ttl_fix_in' "$TTL_FILE" 2>/dev/null; then
			printf '入站修复 : 有 ✅（校园网关把入站 TCP 的 TTL 改成 1，缺了它客户端 HTTPS 会全超时）\n'
		else
			printf '入站修复 : 缺 ⚠️  跑一次本脚本会自动补上（或 sh %s 账号 密码）\n' "$0"
		fi
	fi
}

# ════════════════════════════════════════════════ 主流程
MODE="full"
case "${1:-}" in
--status)    MODE="status"; shift ;;
--auth)      MODE="auth"; shift ;;
--auto)      MODE="auto"; QUIET=1; shift ;;
--uninstall) MODE="uninstall"; shift ;;
--help|-h)   sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
--*)          die "未知参数：$1（试试 --help）" ;;
esac
# 账号密码的位置随用法而变：`… 账号 密码` 与 `… --auth 账号 密码` 都要能用
case "$MODE" in
full|auth)
	[ -n "${1:-}" ] && CAMPUS_USER="$1"
	[ -n "${2:-}" ] && CAMPUS_PASS="$2"
	;;
esac

case "$MODE" in
status)    show_status; exit 0 ;;
uninstall) uninstall_autostart; exit 0 ;;
esac

[ "$DRY_RUN" = 1 ] || [ "$(id -u)" = 0 ] || die "请用 root 运行（要改防火墙和系统配置）"
[ "$DRY_RUN" = 1 ] || has uci || die "找不到 uci —— 这个脚本要在 OpenWrt 路由器上跑"

case "$PORTAL" in http://*|https://*) ;; *) die "门户地址看着不对：$PORTAL" ;; esac

case "$MODE" in
auto)
	# cron/hotplug/init.d 用：已经在线就不做事（幂等，静默）
	if online; then log "already online"; exit 0; fi
	do_login || exit 1
	;;
auth)
	do_login || exit 1
	;;
full)
	info "本校校园网一键：伪装 → 认证 → 启动项（账号 ${CAMPUS_USER:-（配置里/稍后问）}）"
	[ "$SKIP_DISGUISE" = 1 ] && say "（SKIP_DISGUISE=1：跳过伪装）" || setup_disguise
	if online; then
		say "外网已通，跳过认证"
	else
		do_login || { warn "认证没成功：看上面的输出；重试 sh $0 账号 密码"; exit 1; }
	fi
	install_autostart
	info "完成"
	cat <<EOF
    以后：$SELF_INSTALL --status      看状态
          $SELF_INSTALL --auth        手动补一次认证
          $SELF_INSTALL --uninstall   卸掉启动项
    真实 UA 效果要用**电脑/手机**开 http://ua-check.stagoh.com/ 看（路由器自己 curl 不准）
    加速器/Steam 类流量：UA-Mask 会把非 HTTP 目标卸载到内核，跑一会看
      nft list set inet fw4 UAmask_bypass_set
EOF
	;;
esac
exit 0
