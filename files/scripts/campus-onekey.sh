#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# campus-onekey.sh —— 本校校园网「单文件版」
#
# 一条命令走完三件事（顺序就是这个顺序：先伪装，再认证，最后装启动项）：
#   ① 伪装   UA-Mask（把各设备的 UA 统一成一台 PC + 协议敏感流量放行/卸载到内核）+ TTL 内核规则
#             TTL 是**双向**的：出站统一成人设值（Windows=128），入站把校园网关改成 1 的
#             TTL 补回来（TCP 与 UDP 都要补）——
#             少了 TCP 那条 → 客户端 HTTPS 全部连接超时；
#             少了 UDP 那条 → LoL/Steam/ARK 这类 UDP 游戏连不上（见下文 ttl_fix_in）
#   ② 认证   本校门户三步接口 login.php → stat.php → ack_auth.php（pass 用 AES-128-ECB 加密）
#   ③ 启动项 /etc/init.d/campus-onekey（开机）+ hotplug（网口上线）+ cron（每 5 分钟兜底）
#
# ★ 判定"上不上得了网"分四层，别混为一谈（混了就会白折腾认证，实测踩过）：
#     ① 校园网放没放行 —— 只看 TCP 能不能出（按 IP 测，不需要 DNS）。本校把 ICMP 挡了，
#        所以 `ping 223.5.5.5` 永远不通，而此刻 `curl http://223.5.5.5/` 是回 404 的（TCP 通）。
#     ② 本机能不能解析域名 —— dnsmasq → AdGuardHome(127.0.0.1:5625)。AGH 一挂，全屋"断网"，
#        但校园网其实好得很；此时去重认证一万次也没用。
#     ③ 出站 443 —— 本校会**临时丢**出站 443（互联网方向；校园网自己的门户 443 是通的）。
#        表现：所有 HTTPS 突然打不开，而门户、HTTP、DNS 一切照常 —— 最像"认证掉了"的一种。
#        它还会连累 AdGuardHome 的 DoH 上游（30 秒超时）→ 全屋 DNS 跟着归零。见 ②。
#     ④ 门户会话 —— logined=1/acct="" 这类陈旧会话，得先注销再登录（门户一般有 /api/logout.php）。
#
# 用法：
#   sh campus-onekey.sh 账号 密码            # 全流程（幂等：已在线也会把伪装配置和启动项补齐）
#   sh campus-onekey.sh                      # 交互式问账号密码
#   sh campus-onekey.sh --status             # 状态：外网通不通、启动项装没装、伪装开着没
#   sh campus-onekey.sh --auth               # 只认证（不动伪装配置、不装启动项）
#   sh campus-onekey.sh --install            # 只装启动项（开机 / 网口上线 / cron 每 5 分钟）
#   sh campus-onekey.sh --ttl                # 只刷新 TTL 规则（补齐入站 TCP/UDP 修复）
#   sh campus-onekey.sh --auto               # 给 cron/hotplug/init.d 用：静默，只认证
#   sh campus-onekey.sh --dns-fallback       # 应急：AdGuardHome 挂了导致全屋解析不了域名时，把 dnsmasq 指回公网 DNS
#   sh campus-onekey.sh --dns-adgh           # 把 dnsmasq 指回 AdGuardHome(127.0.0.1:5625)
#   sh campus-onekey.sh --clock              # 按校园门户的 Date 头校时（不需要外网 NTP；时钟偏移本身是检测项）
#   sh campus-onekey.sh --log                # 只看本脚本留的健康日志（DNS / 443 / 时钟；没输出=正常）
#   sh campus-onekey.sh --probe              # 探测本线路的出站端口策略（判断是"只封 443"还是"白名单受限"）
#   sh campus-onekey.sh --relogin            # ★围墙花园状态自愈：先注销残留会话(api/logoff.php) 再重新认证
#   sh campus-onekey.sh --logout             # 只注销门户会话
#   sh campus-onekey.sh --new-mac            # ★网关单独限制本设备时用：换 WAN MAC → 新 IP → 重新认证
#   sh campus-onekey.sh --mac-restore        # 回退（删掉 MAC 覆盖，恢复硬件 MAC）
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
# --auto（开机/热插拔/cron）发现时钟偏差 >300s 时是否自动按门户校时。1=校（默认），0=只记日志
CLOCK_AUTO="${CLOCK_AUTO:-1}"
# do_login 用：1=被门户明确拒绝（账号密码错等）→ 调用方别去装"每 5 分钟重试"的启动项
AUTH_FATAL=0
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
# 状态变化才写日志（logd 环形缓冲只有 16 KB 左右，每 5 分钟刷屏会把历史冲掉）。
# 用 /tmp 下的标记文件记住"上一次是什么状态"（tmpfs，重启即清空 —— 重启后重新记一次也无妨）。
log_state() {	# log_state <键> <异常时的日志内容>
	[ -f "/tmp/.campus-state-$1" ] && return 0
	: > "/tmp/.campus-state-$1" 2>/dev/null
	log "$2"
}
log_state_clear() {	# log_state_clear <键> <恢复时的日志内容>：恢复正常时补一行，方便算持续多久
	[ -f "/tmp/.campus-state-$1" ] || return 0
	rm -f "/tmp/.campus-state-$1" 2>/dev/null
	log "$2"
}
run()  { if [ "$DRY_RUN" = 1 ]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }
has()  { command -v "$1" >/dev/null 2>&1; }
uget() { has uci && uci -q get "$1" 2>/dev/null; }
ask() {	# ask <提示> <默认值> → $REPLY
	printf '%s [%s]: ' "$1" "${2:-}"; if ! read -r REPLY; then REPLY=""; fi
	[ -z "$REPLY" ] && REPLY="${2:-}"
}
# 按 IP 探测 TCP 出网：**任何** HTTP 状态码（含 404/403）都算通，而且完全不需要 DNS ——
# 这正是"校园网放行了、但本机解析不了域名"时唯一靠得住的判据。
ONLINE_IP_PROBES="${ONLINE_IP_PROBES:-http://223.5.5.5/ http://114.114.114.114/}"
TCP_CODE=''	# tcp_out 成功后填最后一次的 HTTP 状态码（注意：tcp_out 必须在当前 shell 里调，$() 里调是子 shell，看不到）
tcp_out() {
	local u c
	for u in $ONLINE_IP_PROBES; do
		c="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)"
		case "$c" in ''|000) : ;; *) TCP_CODE="$c"; return 0 ;; esac
	done
	return 1
}
# 本机 DNS（dnsmasq → AdGuardHome:5625）能不能解析。跟"校园网放没放行"是两件事，
# 但体感一模一样（都是"上不了网"），所以必须分开判定、分开报。
dns_ok() {
	local n
	if has nslookup; then
		for n in www.baidu.com www.qq.com; do
			nslookup "$n" 127.0.0.1 >/dev/null 2>&1 && return 0
		done
		return 1
	fi
	ping -c 1 -W 3 www.baidu.com >/dev/null 2>&1
}
# ── 出站端口探测 ────────────────────────────────────────────────────
# ★ 方法论警告（我自己踩过，写下来免得再犯）：
#   只能探测**对面确实在监听**的端口，否则结论没意义。
#   223.5.5.5 只开 53/80/443 —— 把 8080/8443/8888/2052 打在它身上，
#   中间设备对"没在听的端口"是**直接丢包**（不是回 RST），于是看起来像"被封"。
#   我据此一度得出"只放行 80/53（白名单受限）"的结论，用户实测高位端口其实能用 → 那是误判。
#   要测某个高位端口，必须有一台"真的有服务在听"的外网机器（自建 VPS 最合适）。
#   探测手段用 curl 的 %{errormsg}：比解析 `curl -v` 的英文文案可靠
#   （实测 -v 的输出在这台机器上匹配不到 "Connected to"，会把 80/443 报成"结果不明"）。
PROBE_HOST="${PROBE_HOST:-223.5.5.5}"	# 只用来测 80/443（这两个它确实在听）
tunnel_up() {	# EasyTier 隧道是否起来（11010 是否可用最直接的证据）
	ip link show "$(et_tun 2>/dev/null)" >/dev/null 2>&1
}
et_tun() {	# 隧道网卡名：优先 uci，其次 /etc/easytier/config.toml 里的 dev_name
	local t
	t="$(uci -q get easytier.@easytier[0].tunname 2>/dev/null)"
	[ -n "$t" ] || t="$(sed -n 's/^dev_name *= *"\([^"]*\)".*/\1/p' /etc/easytier/config.toml 2>/dev/null | head -1)"
	printf '%s' "${t:-tun0}"
}
probe_one() {	# probe_one <host> <port> → open | block | unknown
	local r
	r="$(curl -s -m 4 -o /dev/null -w '%{errormsg}' "http://$1:$2/" 2>/dev/null)"
	case "$r" in
		'')           printf 'open' ;;	# 没报错 = TCP 连上并拿到响应
		*efused*)     printf 'open' ;;	# 对面没服务，但包出去了
		*'Empty reply'*|*'HTTP/0.9'*|*'not allowed'*) printf 'open' ;;	# 连上了，只是对面不说 HTTP（如 TLS 端口）
		*imed*|*imeout*) printf 'block' ;;
		*)            printf 'unknown' ;;
	esac
}
probe_word() { case "$1" in open) printf '放行' ;; block) printf '被挡（超时）' ;; *) printf '结果不明' ;; esac; }
# 线路档位：**按实测**判断，别去猜门户字段（acct 为空在本门户是常态，正常时也空）。
line_tier() {
	if https_out; then printf '正常（HTTPS 可用）'; return 0; fi
	if tunnel_up; then
		printf '⚠️ 出站 443 被挡（HTTPS 全挂），但 EasyTier 隧道还活着 → 只封了 HTTPS'
	else
		printf '⚠️ 出站 443 被挡，且 EasyTier 隧道没起（可能一起被挡，也可能本来没开）'
	fi
}
# 出站 443 通不通（不依赖 DNS，按 IP 打，任何状态码都算通）。
# 本校实测会**临时丢**这个方向的 443：HTTPS 全挂、门户与 HTTP 照常，
# 还会把 AdGuardHome 的 DoH 上游拖成 30 秒超时 → 全屋 DNS 归零。
# 只做观测：留条时间线，下次"突然断网"能直接对上号。
https_out() {
	local c
	c="$(curl -sk -m 6 -o /dev/null -w '%{http_code}' https://${PROBE_HOST:-223.5.5.5}/ 2>/dev/null)"
	case "$c" in ''|000) return 1 ;; *) return 0 ;; esac
}
# 外网通不通。★ 顺序有讲究：本校校园网把 ICMP 挡了，`ping 223.5.5.5` 从来不通，
# 而那时 TCP 明明是通的。老写法（先 ping、再 curl 域名）在"AGH 挂了"时会判成"外网不通"，
# 于是脚本报"认证没成功"，人就去反复重认证 —— 白折腾（实测踩过）。
online() {
	[ "$PING_TARGET" != "-" ] && ping -c 1 -W 2 "$PING_TARGET" >/dev/null 2>&1 && return 0
	tcp_out && return 0
	_c="$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$CHECK_URL" 2>/dev/null)"
	case "$_c" in 200|204) return 0 ;; esac
	return 1
}
# 认证提交后墙要几秒才放开，给它几次机会
online_wait() {
	local i
	for i in 1 2 3 4; do online && return 0; sleep 2; done
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

# 生成完整的 TTL 规则内容（出站统一人设值 + 入站 TCP/UDP 修复）
ttl_file_body() {
	local lan="$1" ttl="$2"
	cat <<EOF
# campus-onekey.sh 生成：校园网防 TTL 检测（双向）
# fw4 会把 /etc/nftables.d/*.nft 包含进 table inet fw4。
# 出站：除 LAN 网桥外所有出口，IPv4 TTL 与 IPv6 hop limit 统一成 $ttl
#       （与 UA 人设自洽：Windows=128 / Android·Linux·macOS=64）。
# 入站：校园网关把经 NAT 的客户端入站包的 TTL 改成 1，转发减 1 归零被内核直接丢弃。
#       TCP 缺了 → 客户端 HTTPS 全超时（路由器自己 curl 却正常）；
#       UDP 缺了 → LoL / Steam / ARK 这类 UDP 游戏连不上（UA-Mask 只碰 TCP，别往那边查）。
#       只补 ttl <= 2 的异常值；正常互联网包是 50-60，不会被碰到。
# 改值或关掉：改/删本文件后 fw4 reload
chain ttl_fix {
    type filter hook postrouting priority mangle + 1; policy accept;
    oifname != { $lan } ip ttl set $ttl
    oifname != { $lan } ip6 hoplimit set $ttl
}

chain ttl_fix_in {
    type filter hook prerouting priority mangle; policy accept;
    iifname "wan" ip protocol tcp ip ttl 0-2 ip ttl set 64
    iifname "wan" ip protocol udp ip ttl 0-2 ip ttl set 64
}
EOF
}

# TTL：出站伪装人设值 + 入站 TCP/UDP 修复。独立成函数，便于 --ttl 单独跑。
setup_ttl() {
	_ttl_want="$(ua_persona_ttl "${UA_STR:-$UAMASK_UA_DEFAULT}")"
	_lan="$(lan_dev)"
	_ttl_have=""
	[ -f "$TTL_FILE" ] && _ttl_have="$(sed -n 's/.*ip ttl set \([0-9]*\).*/\1/p' "$TTL_FILE" 2>/dev/null | head -1)"

	# 「完整」= 出站链 + 入站链 + 入站 UDP 那一行。缺任一条就重写整份
	# （不能在旧文件上追加同名链，nft 会报重复定义）。
	_ttl_complete=0
	if [ -f "$TTL_FILE" ] \
	   && grep -q 'chain[[:space:]]*ttl_fix_in' "$TTL_FILE" 2>/dev/null \
	   && grep -q 'ip protocol udp' "$TTL_FILE" 2>/dev/null; then
		_ttl_complete=1
	fi
	_ttl="${TTL_VALUE:-${_ttl_have:-$_ttl_want}}"

	if [ -n "$_ttl_have" ] && [ -z "$TTL_VALUE" ] && [ "$_ttl_complete" = 1 ]; then
		say "    TTL → 保留固件自带的规则（出站 $_ttl_have；入站 TCP+UDP 齐）✓"
		if [ "$_ttl_have" != "$_ttl_want" ]; then
			warn "      注意：它与当前 UA 人设建议的 $_ttl_want 不一致（UA 说自己是哪个系统，TTL 就该对应：Windows=128 / Android·Linux·macOS=64）"
			say  "      要改：TTL_VALUE=$_ttl_want sh $0 …（或直接编辑该文件后 fw4 reload）"
		fi
	elif [ "$DRY_RUN" = 1 ]; then
		if [ "$_ttl_complete" = 1 ]; then
			printf '    [dry-run] 保留 %s（已完整）\n' "$TTL_FILE"
		else
			printf '    [dry-run] 重写 %s（缺入站 UDP 或整条 ttl_fix_in）：\n' "$TTL_FILE"
			ttl_file_body "$_lan" "$_ttl" | sed 's/^/      | /'
			printf '    [dry-run] fw4 reload\n'
		fi
	else
		mkdir -p "$(dirname "$TTL_FILE")"
		[ -f "$TTL_FILE" ] && cp -f "$TTL_FILE" "$TTL_FILE.bak"
		ttl_file_body "$_lan" "$_ttl" > "$TTL_FILE"
		has fw4 && run fw4 reload
		if [ -n "$_ttl_have" ] && [ "$_ttl_have" = "$_ttl" ]; then
			say "    TTL → 入站修复已补齐 TCP+UDP（出站仍为 $_ttl，人设值未改）"
		else
			say "    TTL → 固定 $_ttl（排除 $_lan）+ 入站 TCP/UDP 修复，规则 $TTL_FILE"
		fi
	fi
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

	# TTL：出站人设值 + 入站 TCP/UDP 修复（见文件末尾的 setup_ttl）
	setup_ttl
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
				AUTH_FATAL=1
				return 1
			fi
			if ret_in "$RET" "$RET_RETRY" && [ "$_try" -lt "$RET_MAX_TRY" ]; then
				say "    处理中（ret=$RET），${RET_SLEEP} 秒后再问"
				sleep "$RET_SLEEP"; continue
			fi
			warn "    认证被拒绝：$_path ret=$RET msg=$MSG"
			log "auth rejected at $_path: ret=$RET msg=$MSG"
			AUTH_FATAL=1
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
	if online_wait; then
		say "    认证成功 ✅"
		log "auth ok (user=$CAMPUS_USER)"
		return 0
	fi
	# 门户说成功、却还是上不了网 —— 必须分清是"校园网没放行"还是"本机 DNS 挂了"：
	# 两者体感一样，但处理方式完全相反（一个是校园网的事，一个是路由器自己的事）。
	if tcp_out; then
		warn "    校园网其实**已经放行**（按 IP 的 TCP 出得去，刚测到 HTTP $TCP_CODE），是本机解析不了域名"
		warn "    → 大概率 dnsmasq → AdGuardHome(127.0.0.1:5625) 挂了。查："
		warn "        pgrep -f AdGuardHome || echo 'AGH 没在跑'"
		warn "        nslookup www.baidu.com 127.0.0.1     # 超时/无响应就是这个原因"
		warn "      应急恢复：sh $0 --dns-fallback（还不行再看 logread | grep -iE 'adguard|dnsmasq'）"
		log "auth ok but local DNS broken (user=$CAMPUS_USER, tcp=$TCP_CODE)"
		return 0	# 认证本身是成功的 —— 返回 0，别让 cron 每 5 分钟反复重登
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

autostart_missing() {	# 三个启动项有缺就返回 0（用来判断"要不要补装"）
	[ -x "$INITHOOK" ] || return 0
	[ -x "$HOOKFILE" ] || return 0
	grep -qF "$SELF_INSTALL --auto" "$CRONTAB_FILE" 2>/dev/null || return 0
	return 1
}

show_log() {	# 只看本脚本留的健康日志
	# ★ `logread -t` 只是**给每行加时间戳**，它不过滤！想按 tag 过滤得用
	#   `logread -e PATTERN` 或 logread | grep。实测踩过：`logread -t campus-onekey | grep 443`
	#   会把 AGH 那些历史 DoH 超时全带出来（几百行），看着像刚出事。
	local n="${1:-40}"
	info "campus-onekey 的健康日志（最近 $n 条；**没有输出就代表一切正常**）"
	logread 2>/dev/null | grep -F 'campus-onekey' | tail -n "$n"
	info "上面只会有这几类行："
	info "  WARN 域名解析不通…   → 本机 DNS 挂了（--dns-fallback 应急）"
	info "  WARN 出站 443 不通…  → 校园网临时丢 443（HTTPS 会全挂，门户/HTTP 照常）"
	info "  WARN 本机时钟与门户差… → NTP 同步不上（--clock 校时）"
	info "  时钟与门户差 Ns，已自动按门户校时 / already online / auth ok"
}

# ── 出站端口策略探测 ────────────────────────────────────────────────
# 什么时候用：--status 里"出站 443 不通"、但 HTTP/DNS 正常，想知道是"只封 443"
# 还是"整条线路被扔进了白名单模式"。后者是大问题（门户里 acct 为空就是它的特征），
# 而且会让隧道（11010）与 HTTPS 一起废掉。
probe_out() {
	local t tier
	info "出站端口检测（只测"对面确实在监听"的端口，否则结论没意义）"
	if [ "$PING_TARGET" != "-" ] && ping -c 1 -W 2 "$PING_TARGET" >/dev/null 2>&1; then
		printf '  ICMP                : 通\n'
	else
		printf '  ICMP                : 不通（本校常挡，单独不能说明问题）\n'
	fi
	printf '  TCP %-15s : %s\n' "$PROBE_HOST:80"  "$(probe_word "$(probe_one "$PROBE_HOST" 80)")"
	printf '  TCP %-15s : %s\n' "$PROBE_HOST:443" "$(probe_word "$(probe_one "$PROBE_HOST" 443)")"
	printf '  EasyTier 隧道 (%s) : %s\n' "$(et_tun)" "$(tunnel_up && echo 在 || echo 不在)"
	for t in ${PROBE_EXTRA:-}; do	# 自建 VPS 上开着的端口这样测，例如 PROBE_EXTRA='1.2.3.4:8443'
		printf '  额外 %-16s : %s\n' "$t" "$(probe_word "$(probe_one "${t%%:*}" "${t##*:}")")"
	done
	info "档位（按实测）：$(line_tier)"
	info "★ 别把高位端口（8080/8443/2052…）打在 $PROBE_HOST 上测 —— 它没在那些端口监听，"
	info "  中间设备会**直接丢包**，看起来像"被封"（我据此误判过一次：其实高位端口是通的）。"
	info "  要测这类端口，得指定一台真的有服务在听的外网机器："
	info "    PROBE_EXTRA='你的VPS:8443' sh $0 --probe"
	info "★ 也别拿门户 acct 是否为空当判据 —— 实测它在本门户常态就是空的（正常时也空）"
}

# ── 门户会话状态 / 注销 ─────────────────────────────────────────────
# 为什么专门做这个：网关把"IP 在线但没绑账号"（acct 为空、logined=1）的会话
# 当**未认证访客**处理 → 只放行围墙花园（门户 + 80 + 53），
# 于是 HTTPS、隧道(11010) 全废，而门户 API 还一路 ret=0、stat 还说"认证成功"，
# 重认证也没用（login.php 看 logined=1 就直接返回，从不重新绑定）。
# 这种状态只有一个解法：**先注销掉这个残留会话，再重新认证**。
# 接口名是从门户的 /assets/js/raas.js 里挖出来的：api/logoff.php（还有 getacct.php 可查绑定）。
portal_state() {	# 输出 "<logined>|<acct>|<sessionlogined>"，拿不到就返回 1
	local r
	r="$(curl_auth -m 6 "$PORTAL/api/ip.php" 2>/dev/null)" || return 1
	r="$(json_strip_jsonp "$r")"
	[ -n "$r" ] || return 1
	printf '%s|%s|%s' "$(json_num "$r" logined)" "$(json_str "$r" acct)" "$(json_num "$r" sessionlogined)"
}
do_logout() {	# 注销门户会话（把残留的"空账号在线"状态清掉）
	local url="$PORTAL${LOGOUT_PATH:-/api/logoff.php}" resp ret msg pw=''
	read_conf
	info "注销门户会话：$url"
	# 与登录同构：user + pass（AES 密文）+ EXTRA_FIELDS。门户的 logoff 一般就吃这一套；
	# 吃不进去（返回空 ret）时用 LOGOUT_PATH / LOGOUT_EXTRA 覆盖着试，
	# 接口定义在 $PORTAL/assets/js/raas.js（搜 logoff）。
	[ -n "${CAMPUS_PASS:-}" ] && pw="$(raas_encode "$CAMPUS_PASS" 2>/dev/null || true)"
	if [ "$DRY_RUN" = 1 ]; then
		printf '    [dry-run] GET %s/（拿 cookie）\n' "$PORTAL"
		printf '    [dry-run] POST %s（user=%s pass=%s + %s）\n' "$url" "${CAMPUS_USER:-?}" "${pw:+<AES>}" "${LOGOUT_EXTRA:-$EXTRA_FIELDS}"
		return 0
	fi
	curl_auth -c "$COOKIE" -b "$COOKIE" -o /dev/null "$PORTAL/" 2>/dev/null || true
	resp="$(curl_auth -b "$COOKIE" -c "$COOKIE" \
		-H 'X-Requested-With: XMLHttpRequest' -H "Referer: $PORTAL/" -H "Origin: $PORTAL" \
		-X POST "$url" \
		--data-urlencode "$USER_FIELD=${CAMPUS_USER:-}" \
		--data-urlencode "$PASS_FIELD=$pw" \
		--data "${LOGOUT_EXTRA:-$EXTRA_FIELDS}" 2>/dev/null)"
	resp="$(json_strip_jsonp "$resp")"
	ret="$(json_num "$resp" ret)"; msg="$(json_str "$resp" msg)"
	say "    ${LOGOUT_PATH:-/api/logoff.php} → ret=${ret:-?} msg=${msg:-（空）}"
	say "    原始响应：$(printf '%s' "$resp" | head -c 160)"
	log "logoff: ret=${ret:-?} msg=${msg:-（空）} user=${CAMPUS_USER:-?}"
	case "${ret:-}" in
		0|3|121|122) say "    注销已提交 ✅（接着 --relogin 重新登录）"; return 0 ;;
		'') warn "    门户没返回 ret —— 接口/字段可能不对（看上面原始响应；raas.js 里搜 logoff）"; return 1 ;;
		*)  warn "    注销被拒：ret=$ret msg=$msg"; return 1 ;;
	esac
}

# ── 换 WAN MAC：对付"网关单独限制这个设备"的档位 ─────────────────────
# 依据（10-10 实测推理链）：
#   · 同账号的手机直连校园网 HTTPS 正常 → **账号没被封**
#   · 本机 --relogin 成功（logoff 回"下线成功"、login 回"认证成功"）后 443 依旧被挡
#     → 不是会话/认证问题
#   · 剩下最可能的就是"网关按设备（MAC/IP）给了限制档位"
#   换掉 WAN MAC → 网关眼里是新设备 → 通常会重新分配 IP、重新认证，限制档位大概率消失。
# 副作用：会占一个"设备数"名额（旧记录过期后释放）；网关/交换机侧可能有 MAC 绑定告警。
# 回退：sh 本脚本 --mac-restore
mac_info() {	# 输出 "<uci段名> <当前MAC> <当前IP>"
	local sec dev mac ip4
	dev="$(uci -q get network.wan.device 2>/dev/null)"; [ -n "$dev" ] || dev=wan
	sec="$(uci show network 2>/dev/null | sed -n "s/^network\.\([A-Za-z0-9_]*\)\.device='$dev'\$/\1/p" | head -1)"
	[ -n "$sec" ] || sec=wan
	mac="$(cat /sys/class/net/$dev/address 2>/dev/null)"
	ip4="$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -1)"
	printf '%s %s %s' "$sec" "${mac:-?}" "${ip4:-无}"
}
do_new_mac() {
	local sec mac ip4 new="${1:-}"
	# ★ 必须先取 $1 再 set --，否则 set -- 会把函数自己的参数覆盖掉（踩过）
	set -- $(mac_info); sec="$1"; mac="$2"; ip4="$3"
	info "换 WAN MAC（段 network.$sec，当前 MAC=$mac IP=$ip4）"
	# 读不到当前 MAC 就别硬造（否则会写出一个畸形 MAC 把 WAN 弄断）
	case "$mac" in
		[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:*) : ;;
		*) die "读不到 WAN 的当前 MAC（拿到的是 '$mac'）—— 先看 uci show network | grep -i wan 确认 device 名" ;;
	esac
	# 新 MAC：保留前四字节（同厂商、不显眼），后两字节随机。
	# 用 rand_byte() 而不是 $RANDOM —— busybox 的 ash 不一定编了 RANDOM，
	# 而脚本是 set -u，直接写 $RANDOM 会在没编的环境里报"参数未设置"直接退出。
	if [ -z "$new" ]; then
		new="$(printf '%s' "$mac" | cut -d: -f1-4):$(printf '%02x' "$(rand_byte)"):$(printf '%02x' "$(rand_byte)")"
	fi
	case "$new" in
		[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) : ;;
		*) die "MAC 格式不对：$new" ;;
	esac
	say "    $mac → $new"
	run uci set "network.$sec.macaddr=$new"
	run uci commit network
	run ifdown wan
	run sleep 3
	run ifup wan
	[ "$DRY_RUN" = 1 ] && return 0
	sleep 12
	ip4="$(ip -4 -o addr show dev wan 2>/dev/null | awk '{print $4}' | head -1)"
	say "    新 IP：${ip4:-还没拿到（再等等，或看 logread）}"
	# 网口 up 会触发 hotplug 自动认证；这里再补一次，然后看档位
	do_login >/dev/null 2>&1 || warn "    自动认证没成功，稍后 cron 会兜（或手动 --auth）"
	sleep 2
	say "    线路档位：$(line_tier)"
	say "    443：$(probe_word "$(probe_one 223.5.5.5 443)")（用 --probe 看全貌）"
	say "    回退：sh $0 --mac-restore"
}
do_mac_restore() {
	local sec
	sec="$(mac_info)"; sec="${sec%% *}"
	info "删掉 WAN MAC 覆盖（network.$sec.macaddr），回到硬件 MAC"
	run uci -q delete "network.$sec.macaddr"
	run uci commit network
	run ifdown wan; run sleep 3; run ifup wan
	[ "$DRY_RUN" = 1 ] && return 0
	sleep 12
	say "    现在：(段 $(mac_info | cut -d' ' -f1) MAC $(mac_info | cut -d' ' -f2) IP $(mac_info | cut -d' ' -f3))"
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

# ── 时钟：门户的 Date 头就是现成的权威时间 ──────────────────────────────
# 为什么专门做这一节：本机时钟偏了不只是日志难对 —— 它**本身就是文档 §7.1 的检测项**
# （NTP 时钟偏移）。而 443/123 被丢的时候 NTP 往往同步不上（实测这台偏了 2 天多，
# 排查时"Oct 7"和"Oct 8"的日志混在一起，白绕了一大圈）。
# 门户是 HTTP、按 IP 访问，walled-garden 里照样打得开 —— 拿它的 Date 头校时最稳，
# 不依赖任何外网 NTP。
portal_date() {	# → "Fri, 09 Oct 2026 03:28:34 GMT"
	curl -sI -m 6 "$PORTAL/" 2>/dev/null | sed -n 's/^[Dd]ate:[[:space:]]*//p' | head -1 | tr -d '\r'
}
portal_iso() {	# 门户的 GMT 时间 → busybox date 认的 "YYYY-MM-DD hh:mm:ss"
	local d m
	d="$(portal_date)"
	[ -n "$d" ] || return 1
	set -- $(printf '%s' "$d" | tr -d ',')
	#    $1=周几  $2=日  $3=月  $4=年  $5=时:分:秒  $6=GMT
	[ -n "${2:-}" ] && [ -n "${4:-}" ] && [ -n "${5:-}" ] || return 1
	case "${3:-}" in
		Jan) m=01 ;; Feb) m=02 ;; Mar) m=03 ;; Apr) m=04 ;; May) m=05 ;; Jun) m=06 ;;
		Jul) m=07 ;; Aug) m=08 ;; Sep) m=09 ;; Oct) m=10 ;; Nov) m=11 ;; Dec) m=12 ;;
		*) return 1 ;;
	esac
	printf '%s-%s-%s %s' "$4" "$m" "$2" "$5"
}
clock_skew() {	# 本机比门户慢多少秒（正=本机偏慢）；拿不到门户时间就返回非 0
	local iso pe
	iso="$(portal_iso)" || return 1
	pe="$(date -u -d "$iso" +%s 2>/dev/null)" || return 1
	[ -n "$pe" ] || return 1
	printf '%s' "$((pe - $(date +%s)))"
}
clock_sync() {	# 按门户时间校时，并写回硬件时钟。成功 0；拿不到门户时间返回 1（不 die，
		# 因为 --auto 也会调它，cron 里不该因为门户一时打不开就报错退出）
	local iso sk
	iso="$(portal_iso)" || return 1
	info "门户说：$(portal_date)"
	info "本机说：$(date '+%F %T %Z')"
	# 门户给的是 GMT，必须带 -u，否则会被当成本地时间（差一个时区）
	run date -u -s "$iso"
	[ -x /sbin/hwclock ] && run hwclock -w
	[ "$DRY_RUN" = 1 ] && return 0
	say "    已校时（UTC $iso），硬件时钟也写了"
	sk="$(clock_skew 2>/dev/null)" || sk=''
	[ -n "$sk" ] && say "    现在与门户相差 ${sk}s（±60 秒内都算正常）"
	return 0
}
# 给 --auto（开机 / 热插拔 / cron 每 5 分钟）用：偏差大了**直接校**（不只是记日志）。
# 不加 CLOCK_AUTO=0 的话默认就校 —— 时钟偏掉本身是检测项（文档 §7.1），而且这网
# 外网 NTP 常常同步不上，靠门户的 Date 头最稳。校时不动任何别的配置，风险极低。
clock_auto() {
	local sk
	sk="$(clock_skew 2>/dev/null)" || return 0
	case "${sk:-}" in ''|-) return 0 ;; esac
	[ "$sk" -lt 0 ] && sk=$((-sk))
	[ "$sk" -gt 300 ] || return 0
	if [ "$CLOCK_AUTO" = 1 ]; then
		if clock_sync; then
			log "时钟与门户差 ${sk}s，已自动按门户校时"
		else
			log "WARN 时钟与门户差 ${sk}s，且拿不到门户时间（$PORTAL 打不开？）"
		fi
	else
		log "WARN 本机时钟与门户差 ${sk}s（NTP 同步不上？应急校时：sh $SELF_INSTALL --clock）"
	fi
	return 0
}

# ── DNS 应急开关 ────────────────────────────────────────
# 固件把 dnsmasq 的上游设成 AdGuardHome(127.0.0.1:5625) + noresolv=1：好处是查询内容走 DoH
# 不外泄，代价是 AGH 一挂**全屋立刻解析不了域名**，体感和"校园网断网"一模一样，
# 很容易误判成认证掉了然后去反复重认证（实测踩过）。
dns_set() {	# $1 = fallback | adgh
	has uci || die "找不到 uci —— 这个脚本要在 OpenWrt 路由器上跑"
	case "$1" in
		fallback)
			info "把 dnsmasq 上游切到公网 DNS（223.5.5.5 / 119.29.29.29）"
			run uci -q delete dhcp.@dnsmasq[0].server
			run uci add_list dhcp.@dnsmasq[0].server='223.5.5.5'
			run uci add_list dhcp.@dnsmasq[0].server='119.29.29.29'
			;;
		adgh)
			info "重启 AdGuardHome，并把 dnsmasq 上游指回 127.0.0.1#5625"
			[ -x /etc/init.d/adguardhome ] && run /etc/init.d/adguardhome restart
			run uci -q delete dhcp.@dnsmasq[0].server
			run uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5625'
			;;
		*)	die "内部用法错误：dns_set $1" ;;
	esac
	run uci set dhcp.@dnsmasq[0].noresolv='1'
	run uci commit dhcp
	run /etc/init.d/dnsmasq restart
	[ "$DRY_RUN" = 1 ] && return 0
	sleep 3
	if dns_ok; then
		say "    域名解析已恢复 ✅"
		[ "$1" = fallback ] && say "    注意：现在是明文 DNS 直连公网；AGH 修好后跑 sh $0 --dns-adgh 切回去"
	else
		warn "    还是解析不了 —— 看 logread | grep -iE 'dnsmasq|adguard'；也可能是 AGH 没起来"
	fi
}

show_status() {
	local sk skabs ps pl pa psl rest
	# 四行分开报：这四种故障体感都是"上不了网"，但修法完全不同（见 §8.1）
	printf '外网(按IP): '; if tcp_out; then echo "通 ✅（HTTP $TCP_CODE）"; else echo '不通 ❌'; fi
	printf '域名解析 : '; if dns_ok; then echo '正常 ✅'; else echo '不通 ❌ → dnsmasq/AdGuardHome 挂了，可用 --dns-fallback 应急'; fi
	if https_out; then
		printf '出站 443 : 通 ✅\n'
	else
		printf '出站 443 : 不通 ❌（HTTPS 全挂；门户/HTTP/DNS 照常，别误判成认证掉了）\n'
		printf '           线路档位：%s\n' "$(line_tier)"
		printf '           先别急着重认证（实测无效）；用 --probe 看全貌、--relogin 清残留会话\n'
	fi
	# 门户会话：**只做记录，不下结论**。
	# 实测教训：acct 为空是本科门户的常态 —— 各项功能全正常时它照样是空的，
	# 拿它当"围墙花园"的判据会误报（我自己就先误报了一次）。
	# 真正的判据是"实测哪些端口能出去"，也就是上面的「线路档位」和 --probe。
	ps="$(portal_state 2>/dev/null)" || ps=''
	if [ -z "$ps" ]; then
		printf '门户会话 : 查不到（$PORTAL 打不开？）\n'
	else
		pl="${ps%%|*}"; rest="${ps#*|}"; pa="${rest%%|*}"; psl="${rest#*|}"
		printf '门户会话 : logined=%s acct=%s session=%s' "$pl" "${pa:-（空）}" "$psl"
		[ "$pl" = 1 ] && [ -z "$pa" ] && printf '（acct 空是本门户常态，不代表故障）'
		printf '\n'
	fi
	printf '时钟     : %s' "$(date '+%F %T %Z')"
	sk="$(clock_skew 2>/dev/null)" || sk=''
	if [ -z "$sk" ]; then
		echo '（拿不到门户时间，无法比对）'
	else
		skabs="$sk"; [ "$sk" -lt 0 ] && skabs=$((-sk))
		if [ "$skabs" -le 60 ]; then
			echo '（与门户一致 ✅）'
		else
			printf '（⚠️ 与门户差 %ss → sh %s --clock 一键校时）\n' "$skabs" "$0"
		fi
	fi
	printf '账号     : %s\n' "$(uget campus.main.user)"
	printf '启动项   : init.d=%s hotplug=%s cron=%s\n' \
		"$([ -x "$INITHOOK" ] && echo 有 || echo 无)" \
		"$([ -x "$HOOKFILE" ] && echo 有 || echo 无)" \
		"$(grep -qF "$SELF_INSTALL --auto" "$CRONTAB_FILE" 2>/dev/null && echo 有 || echo 无)"
	# 缺启动项是很隐蔽的坑：认证当时没成功就没装（旧版会直接 exit），于是重启/掉线后
	# 没人再自动认证、也不会自动校时 —— 但 --status 之外你根本看不出来。
	if autostart_missing; then
		printf '           → ⚠️ 启动项不全：路由器重启/掉线后不会自动认证，也不会自动校时\n'
		printf '             补装：sh %s --install\n' "$SELF_INSTALL"
	fi
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
		if ! grep -q 'chain[[:space:]]*ttl_fix_in' "$TTL_FILE" 2>/dev/null; then
			printf '入站修复 : 缺 ⚠️  跑一次本脚本会自动补上（sh %s --ttl）\n' "$0"
		elif ! grep -q 'ip protocol udp' "$TTL_FILE" 2>/dev/null; then
			printf '入站修复 : 只有 TCP，缺 UDP ⚠️  sh %s --ttl 可补齐（UDP 缺了 LoL/Steam/ARK 连不上）\n' "$0"
		else
			printf '入站修复 : TCP+UDP 齐 ✅（校园网关把入站包 TTL 改成 1，缺了客户端 HTTPS/游戏都会挂）\n'
		fi
	fi
}

# ════════════════════════════════════════════════ 主流程
MODE="full"
case "${1:-}" in
--status)    MODE="status"; shift ;;
--auth)      MODE="auth"; shift ;;
--auto)      MODE="auto"; QUIET=1; shift ;;
--ttl)       MODE="ttl"; shift ;;
--install)   MODE="install"; shift ;;
--dns-fallback) MODE="dnsfb"; shift ;;
--dns-adgh)  MODE="dnsagh"; shift ;;
--clock)     MODE="clock"; shift ;;
--log)       MODE="log"; shift ;;
--probe)     MODE="probe"; shift ;;
--logout)    MODE="logout"; shift ;;
--relogin)   MODE="relogin"; shift ;;
--new-mac)   MODE="newmac"; shift ;;
--mac-restore) MODE="macrestore"; shift ;;
--uninstall) MODE="uninstall"; shift ;;
--help|-h)   sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
install)   install_autostart; exit 0 ;;
ttl)       info "只刷新 TTL 规则（不动 UA-Mask / 不认证）"; setup_ttl; exit 0 ;;
dnsfb)     dns_set fallback; exit 0 ;;
dnsagh)    dns_set adgh; exit 0 ;;
clock)     clock_sync || die "拿不到门户时间 —— $PORTAL 打不开？"; exit 0 ;;
log)       show_log "${1:-}"; exit 0 ;;
probe)     probe_out; exit 0 ;;
newmac)    do_new_mac "${1:-}"; exit 0 ;;
macrestore) do_mac_restore; exit 0 ;;
logout)    do_logout; exit $? ;;
relogin)
	# 围墙花园状态（IP 在线但没绑账号）的自愈顺序：先注销残留会话，再重新认证
	info "① 先注销残留会话（清掉 acct 为空的"在线"状态）"
	do_logout || warn "注销没成功——仍旧继续尝试登录（有些门户允许直接覆盖会话）"
	sleep 2
	info "② 再重新认证"
	do_login || { warn "重登没成功，看上面的输出"; exit 1; }
	ps="$(portal_state 2>/dev/null)" || ps=''
	[ -n "$ps" ] && say "    现在门户状态：logined=${ps%%|*} acct=$(printf '%s' "${ps#*|}" | cut -d'|' -f1)"
	exit 0
	;;
uninstall) uninstall_autostart; exit 0 ;;
esac

[ "$DRY_RUN" = 1 ] || [ "$(id -u)" = 0 ] || die "请用 root 运行（要改防火墙和系统配置）"
[ "$DRY_RUN" = 1 ] || has uci || die "找不到 uci —— 这个脚本要在 OpenWrt 路由器上跑"

case "$PORTAL" in http://*|https://*) ;; *) die "门户地址看着不对：$PORTAL" ;; esac

case "$MODE" in
auto)
	# cron/hotplug/init.d 用：已经在线就不做事（幂等，静默）
	# 启动项被删了、或从来没装上（旧版"认证没成功就 exit"会导致这种），先补回来 ——
	# 否则掉线/重启后再没人自动认证，也不会自动校时。
	if autostart_missing; then
		log "检测到启动项缺失，自动补装"
		install_autostart
	fi
	if online; then
		# 顺手留个健康状况的痕迹（只记不改，脚本不偷偷动 DNS 配置）。
		# ★ 只在"状态变化"时写：logd 的环形缓冲很小（默认 16 KB），每 5 分钟刷一遍
		#   会把别的日志一起冲掉 —— 实测踩过：443 红了几小时，--log 里却什么都看不到。
		if dns_ok; then log_state_clear dns "域名解析恢复"
		else log_state dns "WARN 域名解析不通（本机 dnsmasq/AdGuardHome 挂了？应急：sh $SELF_INSTALL --dns-fallback），但按 IP 的外网是通的"; fi
		if https_out; then log_state_clear https "出站 443 恢复（HTTPS 又能用了）"
		else log_state https "WARN 出站 443 不通（HTTPS 全挂；门户/HTTP/DNS 照常）—— 校园网侧封锁本线路的出站 443，不是认证问题，等它自己恢复"; fi
		clock_auto
		log "already online"; exit 0
	fi
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
		do_login; _rc=$?
		if [ "$_rc" != 0 ]; then
			if [ "$AUTH_FATAL" = 1 ]; then
				warn "认证被门户拒绝（账号密码或门户策略问题）—— 先不装启动项，免得每 5 分钟拿错密码去撞门户"
				warn "    确认账号密码后重跑：sh $0 账号 密码"
				exit 1
			fi
			# 这次没认证成功不等于不用装启动项：真掉线时靠的就是它自动重试。
			# （旧版这里直接 exit 1，于是"认证没成功"= 启动项也没装 = 以后再也不会自动恢复，实测踩过）
			warn "这次没认证成功（看上面的原因），但启动项照装 —— 掉线/重启后它会自动重试"
		fi
	fi
	install_autostart
	info "完成"
	cat <<EOF
    以后：$SELF_INSTALL --status      看状态（外网/DNS/443/时钟 分开报）
          $SELF_INSTALL --auth        手动补一次认证
          $SELF_INSTALL --install     只补启动项（开机/hotplug/cron）
          $SELF_INSTALL --clock       按门户校时（NTP 同步不上时用）
          $SELF_INSTALL --uninstall   卸掉启动项
    真实 UA 效果要用**电脑/手机**开 http://ua-check.stagoh.com/ 看（路由器自己 curl 不准）
    加速器/Steam 类流量：UA-Mask 会把非 HTTP 目标卸载到内核，跑一会看
      nft list set inet fw4 UAmask_bypass_set
EOF
	;;
esac
exit 0
