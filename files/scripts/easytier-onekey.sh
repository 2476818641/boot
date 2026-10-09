#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# easytier-onekey.sh —— 虚拟局域网（EasyTier）+ 游戏端口转发 一键配置
#
# 干什么：
#   ① 问中转/引导节点地址（EasyTier 的 -p/-e，用来自动发现房间里的其他节点）
#   ② 问房间名与密钥（= Astral 房间 ID 与密码，源码里就是 NetworkIdentity::new(房间名, 密码)）
#   ③ 问要把哪些端口转发给内网的哪台机器（今天 MC 明天别的游戏，跑一次改一次）
#   ④ 顺手把内网路由下发（DHCP option 121）、UA-Mask 豁免 EasyTier 端口
#   ⑤ 生成 /etc/easytier/config.toml 并把 uci 的 etcmd 钉成 config（真正让它生效的那步，见下）
#
# Astral 分享链接：
#   对方在 Astral 里点"分享"给的链接（astral://room?code=…）可以直接喂给 --astral；
#   跑 --room 时粘到第一个提问里也行 —— 房间号、房间密码、对方用的服务器全自动读出来。
#   也接受只粘那串 H4sI 开头的分享码，甚至整段分享文本（会自动从里面叼出码）。
#   分享码 = base64url(gzip(json))：gzip/zcat 固件里有，base64 上游 busybox **默认没编**
#   （BUSYBOX_DEFAULT_BASE64=n），所以解码器按 base64 → openssl base64 -d -A → busybox base64
#   依次自测挑选；固件那边也把 applet 打开了（CONFIG_BUSYBOX_CONFIG_BASE64=y）。
#
# 用法：
#   sh easytier-onekey.sh                     # 全流程（节点 → 房间 → 端口）
#   sh easytier-onekey.sh --astral 'astral://room?code=H4sI…'   # ★最省事：粘链接一键进房间
#   sh easytier-onekey.sh --astral             # 不给参数就交互式粘贴
#   sh easytier-onekey.sh --ports             # ★只改转发端口（最常用）
#   sh easytier-onekey.sh --ports tcp/25565,udp/19132    # 免交互直接改
#   sh easytier-onekey.sh --node              # 只改中转/引导节点
#   sh easytier-onekey.sh --show              # 看现状（模式 / 配置 / 转发 / 对端 / 实际启动参数）
#   sh easytier-onekey.sh --toml              # 手改过 config.toml 后：校验 + 重启
#   sh easytier-onekey.sh --clear             # 清空全部端口转发
#   DRY_RUN=1 sh easytier-onekey.sh --ports tcp/25565    # 只打印要改什么
#
# ★ 配置是怎么生效的（换机器 / 重刷固件后必看）
#   luci-app-easytier 的 /etc/init.d/easytier 按 uci 的 etcmd 三选一：
#     etcmd=config → easytier-core -c /etc/easytier/config.toml   ← 本脚本用这条
#     etcmd=etcmd  → 把 uci 字段拼成 --network-name / -p / -n ... 命令行（LuCI 里叫"默认"）
#     etcmd 为空   → 两条分支都不进，进程照样起来但**一个参数都没有**：
#                    tun0 不创建、房间不进、easytier-cli 里 ipv4 空白、日志没有"开始运行"。
#   所以本脚本同时写 uci（给 LuCI / --show 看）和 config.toml（真正生效的那份），
#   并把 etcmd 钉成 config。旧版本只写 uci 且没写 etcmd —— 在全新刷机的机器上必然踩空。
#
# 端口写法（多个用逗号或空格分隔）：
#   25565            等价 tcp/25565
#   25565/udp        或 udp/25565
#   tcp/25565,udp/19132
#   25565>25566      外部 25565 转到内网的 25566
#   25565@192.168.1.9    转到另一台机器（同端口）
#   udp/19132@192.168.1.9:19133   完整形式
#
# 常见游戏：
#   我的世界 Java   tcp/25565          我的世界 基岩版 udp/19132
#   幻兽帕鲁        udp/8211           泰拉瑞亚        tcp/7777
#   饥荒联机版      udp/10999          星露谷物语      tcp/24642
#   求生之路2/CS    tcp/27015,udp/27015   英灵神殿     udp/2456,udp/2457,udp/2458
#   木筏求生        udp/27015
#
# 只用 POSIX sh（路由器上是 ash），不依赖 bash / jq / python。
set -u

CONF_DIR=/etc/easytier
CONF="$CONF_DIR/forwards.conf"
TOML="$CONF_DIR/config.toml"          # etcmd=config 模式下真正被读取的配置
NFT_FILE=/etc/nftables.d/20-easytier-dnat.nft
UA_BYPASS_DEFAULT='22 443 11010-11013'
UA_INIT="${UA_INIT:-/etc/init.d/UAmask}"   # 可覆盖（仅测试用）
DRY_RUN="${DRY_RUN:-0}"
FWD_LANIP=''   # 由 load_conf 填充
FWD_RULES=''

say()  { printf '\033[32m==>\033[0m %s\n' "$*"; }
# warn/die 一律走 stderr：parse_many 的 stdout 会被 $(...) 捕获当规则用，
# 警告文字混进去会变成非法 nft 规则（实测踩过）
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
# 缺项：正常路径直接退出；DRY_RUN 时只提示（预演本来就不落盘，别被自己的校验拦住）
miss() { [ "$DRY_RUN" = 1 ] && { warn "$1（dry-run 按当前 uci 预览）"; return 0; }; die "$1"; }
has()  { command -v "$1" >/dev/null 2>&1; }

# 统一出口：DRY_RUN 时只打印
run() {
	if [ "$DRY_RUN" = 1 ]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
}

# 用法＝文件头那段注释（只有一个定义点，改行数时只改这里）
usage() { sed -n '2,57p' "$0"; }
# -h 不依赖 uci：在电脑 / 其它机器上也能读用法
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

has uci || die "找不到 uci —— 这脚本要在 OpenWrt 路由器上跑"

# ──────────────────────────────────── 读取现状
et_get()  { uci -q get "easytier.@easytier[0].$1" 2>/dev/null; }
et_set()  { run uci set "easytier.@easytier[0].$1=$2"; }
et_list() {  # 清掉旧的再用 add_list —— init 只认 list 型，set 会被静默忽略
	local key="$1"; shift
	run uci -q delete "easytier.@easytier[0].$key"
	local v
	for v in "$@"; do [ -n "$v" ] && run uci add_list "easytier.@easytier[0].$key=$v"; done
}
lan_ip()  { uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1; }
lan_net() { local l; l="$(lan_ip)"; printf '%s.0/24' "${l%.*}"; }
tun_dev() { local t; t="$(et_get tunname)"; [ -n "$t" ] && echo "$t" || echo tun0; }
toml_ipv4() { [ -f "$TOML" ] && sed -n 's/^ipv4 *= *"\([^"]*\)".*/\1/p' "$TOML" 2>/dev/null | head -1; }
# 本机虚拟 IP：uci 优先，其次现成的 config.toml（手工删过 uci 也别让人重填），最后给默认
cur_ipaddr() {
	local v
	v="$(et_get ipaddr)"; v="${v%%/*}"
	[ -n "$v" ] || v="$(toml_ipv4)"
	[ -n "$v" ] || v='192.168.10.1'
	printf '%s' "$v"
}
# 规范化引导节点地址：补协议前缀与端口。
# 为什么必须做：EasyTier 的 -p 需要完整 URL，写成 "vs.example.com" 会解析失败、
# 进程直接退出，现象是 easytier-cli 里 ipv4 列空白、"启动命令行"也打不出来（实测踩过）。
norm_peer() {
	local u="$1"
	u="$(printf '%s' "$u" | tr -d ' \t')"
	[ -n "$u" ] || return 1
	case "$u" in
		*://*) : ;;
		*)     u="tcp://$u" ;;
	esac
	# 取 :// 之后的部分，看有没有端口（含 IPv6 方括号的情况一并照顾）
	local rest="${u#*://}" host part
	case "$rest" in
		\[*\]:*) : ;;                                  # [v6]:port
		\[*\])   u="$u:11010" ;;                        # [v6]
		*:*) : ;;                                        # host:port
		*)     u="$u:11010" ;;                           # host → 补默认端口
	esac
	printf '%s' "$u"
}

first_peer() {
	local p
	# 只取第一个：peeradd 是 uci list，多条时 `uci get` 会用空格拼成一整串，
	# 而 norm_peer 会 tr -d 空格 —— 直接喂进去会粘成 "tcp://a:11010udp://b:11010"（实测踩过）
	p="$(uci -q get easytier.@easytier[0].peeradd 2>/dev/null | awk '{print $1}')"
	[ -n "$p" ] || p="$(et_get external_node | awk '{print $1}')"
	[ -n "$p" ] || p="tcp://public.easytier.top:11010"
	norm_peer "$p" || printf '%s' "$p"
}

ask() {  # ask "提示" "默认值" → 结果在 REPLY
	printf '%s' "$1"
	[ -n "${2:-}" ] && printf ' [%s]' "$2"
	printf ': '
	IFS= read -r REPLY || REPLY=''
	[ -n "$REPLY" ] || REPLY="${2:-}"
}
ask_yn() {
	local a
	ask "$1 (y/n)" "$2"
	a="$(printf '%s' "$REPLY" | tr 'A-Z' 'a-z')"
	[ "$a" = y ] || [ "$a" = yes ]
}

# ──────────────────────────────────── 生成配置文件（真正生效的那份）
# 两个坑，都实测踩过：
#  1) uci 的 etcmd 不写 → init 两条分支都不进，easytier-core 起成一条没参数的命令行；
#  2) TOML 里 ipv4 / hostname / dhcp / listeners 是**顶层**字段，dev_name / mtu 才在
#     [flags] 里。位置写错 EasyTier 不报错（flags 是白名单式合并，不认识的 key 直接丢），
#     `--check-config` 也只校验语法 —— 现象是"能启动，但节点没有虚拟 IP"。
valid_ipv4() {
	local a b c d rest o
	IFS=. read -r a b c d rest <<EOF
$1
EOF
	[ -z "${rest:-}" ] || return 1
	for o in "$a" "$b" "$c" "$d"; do
		case "$o" in ''|*[!0-9]*) return 1 ;; esac
		[ "$o" -le 255 ] || return 1
	done
	return 0
}

toml_body() {   # 只往 stdout 写文件内容；要提示人一律用 warn（走 stderr，别污染 $(...)）
	local name secret ip tun peers proxy iid np
	name="$(et_get network_name)"
	secret="$(et_get network_secret)"
	ip="$(cur_ipaddr)"
	tun="$(tun_dev)"
	peers="$(uci -q get easytier.@easytier[0].peeradd 2>/dev/null)"
	proxy="$(uci -q get easytier.@easytier[0].proxy_network 2>/dev/null)"
	# instance_id 沿用旧文件里的，节点身份稳定一点（没有就现生成一个）
	iid="$(sed -n 's/^instance_id *= *"\(.*\)"$/\1/p' "$TOML" 2>/dev/null | head -1)"
	[ -n "$iid" ] || iid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"

	cat <<EOF
# 由 easytier-onekey.sh 自动生成 —— 要改请改 uci 后跑 --room / --node 重新生成，
# 或直接改这里再跑 --toml（会校验语法并重启）。
instance_name = "default"
EOF
	[ -n "$iid" ] && printf 'instance_id = "%s"\n' "$iid"
	cat <<EOF
dhcp = false
ipv4 = "$ip"
listeners = [
    "tcp://0.0.0.0:11010",
    "udp://0.0.0.0:11010",
    "ws://0.0.0.0:11011",
    "wss://0.0.0.0:11012",
    "wg://0.0.0.0:11011",
    "quic://0.0.0.0:11012",
]

[network_identity]
network_name = "$name"
network_secret = "$secret"
EOF
	if [ -n "$peers" ]; then
		for np in $peers; do
			np="$(norm_peer "$np")" || { warn "跳过看不懂的引导节点：$np"; continue; }
			printf '\n[[peer]]\nuri = "%s"\n' "$np"
		done
	else
		warn "没有任何引导节点 —— 房间里的设备互相发现不了（跑 --node 加一个）"
	fi
	case "$proxy" in
		'') warn "没有子网代理网段 —— 房间里的其他设备访问不到本机内网" ;;
		*)  for np in $proxy; do printf '\n[[proxy_network]]\ncidr = "%s"\n' "$np"; done ;;
	esac
	cat <<EOF

[flags]
# dev_name：init 从下面这行 grep 出网卡名，用来绑 network.EasyTier 与防火墙 zone
dev_name = "$tun"
mtu = 1380
EOF
}

need_config() {   # 在子 shell 外调用，缺项直接 die（放 $(...) 里只会杀掉子 shell）
	local name ip lan_pre
	name="$(et_get network_name)"
	ip="$(cur_ipaddr)"
	[ -n "$name" ] || miss "还没设房间名（network_name）—— 先跑：sh $0 --room 或 --astral 'astral://room?code=…'"
	[ -n "$(et_get network_secret)" ] || miss "还没设房间密钥（network_secret）—— 先跑：sh $0 --room 或 --astral '…'"
	valid_ipv4 "$ip" || miss "虚拟 IPv4 不合法：'$(et_get ipaddr)'（去掉 /24 之类的后缀；先跑：sh $0 --room）"
	lan_pre="$(lan_ip)"; lan_pre="${lan_pre%.*}"
	case "$ip" in
		"$lan_pre".*) warn "虚拟 IP $ip 与本机 LAN（$lan_pre.0/24）同网段 —— 路由会打架，建议换成 10.10.10.1 这种" ;;
	esac
}

toml_write() {   # 生成 → 校验 → 落盘 → 钉住 etcmd（不重启，重启由调用方决定）
	local body tmp=/tmp/.et-config.toml
	need_config
	# 一个引导节点都没有的话，房间里的设备互相发现不了（只能等别人来连）。
	# 兜底用官方公共节点：它只负责牵线，数据仍然 P2P/走房间内其他节点。
	if [ -z "$(uci -q get easytier.@easytier[0].peeradd 2>/dev/null)" ]; then
		warn "没有引导节点，兜底用 tcp://public.easytier.top:11010（想换成自建/朋友的跑 --node）"
		et_list peeradd 'tcp://public.easytier.top:11010'
		et_set external_node 'tcp://public.easytier.top:11010'
	fi
	body="$(toml_body)"
	[ -n "$body" ] || die "生成的配置是空的，已放弃写入"
	if [ "$DRY_RUN" = 1 ]; then
		printf '    [dry-run] 写 %s：\n' "$TOML"
		printf '%s\n' "$body" | sed 's/^/      | /'
		return 0
	fi
	mkdir -p "$CONF_DIR"
	printf '%s\n' "$body" > "$tmp"
	# 安全网：语法错了就别装上去，否则 tun 不创建，还得回头翻日志
	if has easytier-core; then
		if ! easytier-core --check-config --config-file "$tmp" >/tmp/.et-check.log 2>&1; then
			rm -f "$tmp"
			die "生成的 config.toml 过不了 easytier-core --check-config：
$(sed 's/^/      /' /tmp/.et-check.log)"
		fi
	fi
	[ -f "$TOML" ] && cp -f "$TOML" "$TOML.bak"
	cat "$tmp" > "$TOML"; rm -f "$tmp"
	# 里面有房间密钥 —— 别让全机可读（init / easytier-core / LuCI 都以 root 读，不影响）
	chmod 600 "$TOML"
	info "已写入 $TOML（旧文件备份为 $TOML.bak）"

	# ★ 下面这几行是"能不能生效"的关键，别删
	et_set etcmd 'config'              # 空着 → init 用一条没有参数的命令行启动 easytier-core
	et_set enabled '1'
	et_set interface_netmask '255.255.255.0'   # 别留 /8：会与 LAN / 对端子网代理前缀撞车
	# 顺手把"默认(etcmd)"分支缺的字段补上：那边会把空值拼成 `--default-protocol`（缺参数，
	# clap 直接报错退出）或 `--no-listener`，人在 LuCI 里切过去就会踩空
	et_set listenermode 'ON'
	et_set default_protocol '-'
	et_set rpc_portal '15888'
	run uci commit easytier
	run /etc/init.d/easytier enable
}

# ──────────────────────────────────── Astral 分享链接 / 分享码
# 分享码 = base64url(gzip(json))，json 形如：
#   {"n":"xyw","r":"618870","p":"773468","m":"","e":1,
#    "s":["tcp://38.55.199.242","udp://38.55.199.242"],"c":"1791466192255"}
# 字段含义按上游源码确认（github.com/ldoubil/astral）：
#   lib/core/room/room_share_codec.dart → n 房间名 / r 房间号 / p 密码 / m 消息密钥 /
#                                         e 是否加密房间 / s 该房间的服务器列表
#   rust/src/api/simple.rs:536          → NetworkIdentity::new(room_name, room_password)
# 即 r → network_name、p → network_secret（和"手机能进房间"的实测一致）。
# 链接形如 astral://room?code=<分享码>；整段分享文本、单独一串分享码都认。
ASTRA_NAME='' ASTRA_ID='' ASTRA_PASS='' ASTRA_SERVERS='' ASTRA_ENC=0

# base64 补 '=' 到 4 的倍数（busybox 的 base64 -d 对长度挑剔）
base64_pad() {
	case $(( ${#1} % 4 )) in
		0) printf '%s' "$1" ;;
		2) printf '%s==' "$1" ;;
		3) printf '%s=' "$1" ;;
		*) return 1 ;;   # 余 1 不可能是合法 base64
	esac
}

# base64 → 二进制（stdin→stdout）。
# ★ 固件的 busybox **默认没编 base64**（上游 Config-defaults.in 里 BUSYBOX_DEFAULT_BASE64=n，
#   实测就是 "base64: not found"），所以必须有回退，否则 --astral 直接失效：
#     base64 -d  →  openssl base64 -d -A  →  busybox base64 -d
#   openssl-util 本来就在固件里（校园脚本认证要用 AES），所以这条回退一直能用。
#   注意 openssl 必须带 -A：不带时它按 76 列折行解析，而我们这串是单行不折行 → 解不出来（实测）。
B64_DECODER=''
astral_b64_pick() {	# 自测出本机可用的解码器，缓存进 B64_DECODER
	[ -n "$B64_DECODER" ] && return 0
	if has base64 && [ "$(printf 'aGVsbG8=' | base64 -d 2>/dev/null)" = hello ]; then
		B64_DECODER='base64 -d'; return 0
	fi
	if has openssl && [ "$(printf 'aGVsbG8=' | openssl base64 -d -A 2>/dev/null)" = hello ]; then
		B64_DECODER='openssl base64 -d -A'; return 0
	fi
	if has busybox && [ "$(printf 'aGVsbG8=' | busybox base64 -d 2>/dev/null)" = hello ]; then
		B64_DECODER='busybox base64 -d'; return 0
	fi
	return 1
}
astral_b64d() {
	astral_b64_pick || return 1
	$B64_DECODER 2>/dev/null
}

# 分享码 → json 文本。
# 注意必须用管道直接把字节喂给 gzip：shell 变量存不住 NUL，先 $() 抓一遍会解压失败。
astral_gunzip() {
	local code
	code="$(printf '%s' "$1" | tr -d ' \t\r\n')"
	code="$(base64_pad "$code")" || return 1
	if has gzip; then
		printf '%s' "$code" | tr '_-' '/+' | astral_b64d | gzip -dc 2>/dev/null
	elif has zcat; then
		printf '%s' "$code" | tr '_-' '/+' | astral_b64d | zcat 2>/dev/null
	else
		return 1
	fi
}

# 从"链接 / 整段分享文本 / 纯分享码"里把码抠出来
astral_extract() {
	local in="$1" code
	# 浏览器复制来的链接可能把 + / = 转义了
	in="$(printf '%s' "$in" | tr -d '\r' | sed -e 's/%3[dD]/=/g' -e 's/%2[bB]/+/g' -e 's#%2[fF]#/#g')"
	case "$in" in
		*code=*) code="${in#*code=}"; code="${code%%&*}" ;;
		*)       code="$in" ;;
	esac
	# 只保留开头那段合法 base64 字符：整段分享文本的换行/说明文字会被切掉
	code="$(printf '%s' "$code" | sed -n 's/^[[:space:]]*\([A-Za-z0-9_+/=-]*\).*/\1/p' | head -1)"
	case "$code" in
		H4sI*) : ;;   # gzip 魔数的 base64 前缀，正常
		*)      code="$(printf '%s' "$in" | sed -n 's/.*\(H4sI[A-Za-z0-9_+/=-]*\).*/\1/p' | head -1)" ;;
	esac
	printf '%s' "$code"
}

json_str() {   # json_str <key> <json> → 字符串值（键名唯一时可靠）
	printf '%s' "$2" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}
json_arr() {   # json_arr <key> <json> → 数组里的各元素（空格分隔，去掉引号与逗号）
	printf '%s' "$2" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | head -1 | tr -d '"' | tr ',' ' '
}

is_astral_input() {   # 用户粘的东西像不像 Astral 链接/分享码（房间号那种纯数字不会被误判）
	case "$1" in
		*astral://*) return 0 ;;
		*H4sI*)      return 0 ;;
	esac
	return 1
}

# 解析并落到 uci（房间号/密码/引导节点）。成功 0，失败 1（失败原因自己 warn 过了）
astral_apply() {
	local in="$1" code json one norm list=''
	code="$(astral_extract "$in")"
	[ -n "$code" ] || { warn "里面没找到分享码 —— 要 astral://room?code=… 或那串 H4sI 开头的码"; return 1; }
	if ! astral_b64_pick; then
		# 实测本固件 busybox 默认没编 base64（BUSYBOX_DEFAULT_BASE64=n）
		warn "这台机器上找不到可用的 base64 解码器（busybox 默认没编 base64）"
		warn "  · 有 openssl 就行（固件里通常有）：openssl version"
		warn "  · 或 apk add coreutils-base64"
		warn "  · 两条路都没有时，用 --room 手填房间号与密码即可（分享码解出来就是这两样 + 服务器）"
		return 1
	fi
	if ! has gzip && ! has zcat; then
		warn "系统里没有 gzip/zcat，解不了分享码（apk add gzip；或用 --room 手填）"; return 1
	fi
	json="$(astral_gunzip "$code")"
	if [ -z "$json" ]; then
		warn "分享码解不开 —— 多半是复制时漏字或被聊天软件改过（实测踩过：一个字符错就全废）"
		return 1
	fi
	ASTRA_NAME="$(json_str n "$json")"
	ASTRA_ID="$(json_str r "$json")"
	ASTRA_PASS="$(json_str p "$json")"
	ASTRA_SERVERS="$(json_arr s "$json")"
	case "$json" in *'"e":1'*) ASTRA_ENC=1 ;; *) ASTRA_ENC=0 ;; esac

	info "分享码解出来："
	info "  房间名：${ASTRA_NAME:-（空）}    （只是显示名，EasyTier 认的是房间号）"
	info "  房间号：${ASTRA_ID:-（空）}  → network_name"
	if [ -n "$ASTRA_PASS" ]; then
		info "  房间密码：读到 ${#ASTRA_PASS} 位 → network_secret（不回显，--show 能看）"
	else
		info "  房间密码：（空）"
	fi
	[ "$ASTRA_ENC" = 1 ] && info "  类型：加密房间"
	[ -n "$ASTRA_SERVERS" ] && info "  服务器：$ASTRA_SERVERS"
	[ -n "$ASTRA_ID" ] || { warn "分享码里没有房间号 —— 让对方用『公开房间』重新分享一次"; return 1; }
	[ -z "$ASTRA_PASS" ] && warn "分享码里没有房间密码 —— 对方若设了密码，连上也会被拒"

	et_set network_name "$ASTRA_ID"
	et_set network_secret "$ASTRA_PASS"
	if [ -n "$ASTRA_SERVERS" ]; then
		for one in $ASTRA_SERVERS; do
			norm="$(norm_peer "$one")" || { warn "看不懂这个服务器地址，已跳过：$one"; continue; }
			list="$list${list:+ }$norm"
		done
		if [ -n "$list" ]; then
			et_list peeradd $list
			et_set external_node "$(printf '%s' "$list" | awk '{print $1}')"
			info "  引导节点已设为：$list"
		fi
	fi
	et_set ip_dhcp '0'
	run uci commit easytier
	return 0
}

# --astral：一条命令进房间，全程不问人
do_astral() {
	say "① Astral 分享链接 → 房间配置"
	local in="${1:-}" ip proxy
	if [ -z "$in" ]; then
		ask "粘贴 Astral 分享链接或分享码" ''
		in="$REPLY"
	fi
	[ -n "$in" ] || die "没给链接也没粘码。用法：sh $0 --astral 'astral://room?code=…'"
	astral_apply "$in" || die "分享链接/分享码没解析成功（原因见上）"

	# 虚拟 IP 与子网代理沿用现状；uci 里缺了就补上（失败时退回 config.toml / 默认值）
	ip="$(cur_ipaddr)"
	et_set ipaddr "$ip"
	proxy="$(uci -q get easytier.@easytier[0].proxy_network 2>/dev/null | awk '{print $1}')"
	[ -n "$proxy" ] || proxy="$(lan_net)"
	et_list proxy_network "$proxy"
	info "本机虚拟 IP：$ip    子网代理：$proxy"
	run uci commit easytier
	toml_write
}

# ──────────────────────────────────── 端口规则解析
# 一条 token → "proto port ip dport"；解析失败返回 1
parse_one() {
	local tok="$1" defip="$2" default_proto="${3:-tcp}"
	local ip="$defip" dport='' proto=''

	# @IP[:PORT] 覆盖目标
	case "$tok" in
		*@*)
			local tail="${tok##*@}"
			tok="${tok%@*}"
			ip="${tail%%:*}"
			case "$tail" in
				*:*) dport="${tail##*:}" ;;
			esac
			;;
	esac
	# >DPORT 覆盖目标端口
	case "$tok" in
		*\>*)
			dport="${tok##*>}"
			tok="${tok%%>*}"
			;;
	esac
	# 协议前缀 / 后缀
	case "$tok" in
		tcp/*) proto=tcp; tok="${tok#tcp/}" ;;
		udp/*) proto=udp; tok="${tok#udp/}" ;;
		*/*)   proto="${tok##*/}"; tok="${tok%%/*}" ;;
		*)     proto="$default_proto" ;;
	esac
	case "$proto" in tcp|udp) : ;; *) return 1 ;; esac

	# 端口号校验
	case "$tok" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$tok" -ge 1 ] 2>/dev/null && [ "$tok" -le 65535 ] || return 1
	[ -n "$dport" ] || dport="$tok"
	case "$dport" in ''|*[!0-9]*) return 1 ;; esac

	# IP 校验（宽松：至少含点且各段数字）
	case "$ip" in
		*[!0-9.]*|'') return 1 ;;
	esac

	printf '%s %s %s %s\n' "$proto" "$tok" "$ip" "$dport"
}

parse_many() {  # parse_many "token列表(逗号/空格)" defip → 每行一条
	local list="$1" defip="$2" out
	# 逗号与空格都当分隔符
	out="$(printf '%s' "$list" | tr ', ' '\n\n')"
	printf '%s\n' "$out" | while IFS= read -r t; do
		[ -n "$t" ] || continue
		parse_one "$t" "$defip" || { warn "看不懂这条规则，已跳过：$t"; continue; }
	done
}

load_conf() {  # 读回历史清单（含 lanip）
	FWD_LANIP=''
	FWD_RULES=''
	[ -f "$CONF" ] || return 0
	while IFS= read -r line; do
		case "$line" in
			'# lanip '*) FWD_LANIP="${line#\# lanip }" ;;
			'#'*|'') ;;
			*) FWD_RULES="${FWD_RULES}${FWD_RULES:+
}${line}" ;;
		esac
	done < "$CONF"
}

# ──────────────────────────────────── 防火墙转发规则
write_nft() {  # 入参：规则行（"proto port ip dport"），空则删除文件
	local rules="$1" tun body='' n=0
	tun="$(tun_dev)"
	if [ -n "$rules" ]; then
		body="chain easytier_dnat {
    type nat hook prerouting priority dstnat; policy accept;
"
		while IFS=' ' read -r proto port ip dport; do
			[ -n "${proto:-}" ] || continue
			body="${body}    iifname \"$tun\" $proto dport $port dnat ip to $ip:$dport
"
			n=$((n + 1))
		done <<EOF
$rules
EOF
		body="${body}}
"
	fi
	if [ "$DRY_RUN" = 1 ]; then
		if [ -n "$rules" ]; then
			printf '    [dry-run] 写 %s（%d 条规则）：\n' "$NFT_FILE" "$n"
			printf '%s\n' "$body" | sed 's/^/      | /'
		else
			printf '    [dry-run] 删除 %s（不再转发任何端口）\n' "$NFT_FILE"
		fi
		return 0
	fi
	if [ -n "$rules" ]; then
		mkdir -p "$(dirname "$NFT_FILE")"
		# 安全网：先让 nft 干跑一遍。/etc/nftables.d/ 里的文件语法一错，
		# fw4 reload 会整体失败 → 防火墙起不来。宁可放弃也不能写坏它。
		if has nft; then
			{ echo 'table inet fw4 {'; printf '%s' "$body"; echo '}'; } > /tmp/.et-dnat.check.nft
			if ! nft -c -f /tmp/.et-dnat.check.nft 2>/tmp/.et-dnat.err; then
				die "生成的规则语法不合法，已放弃写入（原文件未改动）：
$(sed 's/^/      /' /tmp/.et-dnat.err)"
			fi
			rm -f /tmp/.et-dnat.check.nft /tmp/.et-dnat.err
		fi
		printf '%s' "$body" > "$NFT_FILE"
	else
		rm -f "$NFT_FILE"
	fi
	has fw4 && run fw4 reload
}

save_conf() {  # 入参：lanip rules
	local ip="$1" rules="$2"
	[ "$DRY_RUN" = 1 ] && { info "[dry-run] 写 $CONF"; return 0; }
	mkdir -p "$CONF_DIR"
	{
		echo "# easytier-onekey.sh 生成：转发清单（proto port ip dport）"
		[ -n "$ip" ] && echo "# lanip $ip"
		[ -n "$rules" ] && printf '%s\n' "$rules"
	} > "$CONF"
}

# ──────────────────────────────────── 三个配置动作
do_node() {
	say "① 中转 / 引导节点"
	info "作用：让本节点找到房间里的其他设备。多台不通用逗号分隔。"
	info "官方共享节点：tcp://public.easytier.top:11010"
	local nodes="${1:-}"
	if [ -z "$nodes" ]; then
		ask "节点地址（留空＝不改）" "$(first_peer)"
		nodes="$REPLY"
	fi
	[ -n "$nodes" ] || { warn "跳过"; return 0; }
	# 逐个规范化（补 tcp:// 与 :11010），避免写成 "host" 让进程起不来
	local list='' one norm
	for one in $(printf '%s' "$nodes" | tr ',' ' '); do
		norm="$(norm_peer "$one")" || { warn "看不懂这个节点地址，已跳过：$one"; continue; }
		[ "$norm" != "$one" ] && info "已补全地址：$one → $norm"
		list="$list${list:+ }$norm"
	done
	[ -n "$list" ] || { warn "没有可用的节点地址"; return 0; }
	et_list peeradd $list
	et_set external_node "$(printf '%s' "$list" | awk '{print $1}')"
	run uci commit easytier
	info "已设置：$list"
	# 房间已配好时顺手把实际生效的 config.toml 一起刷新；只改了节点就不动它（等 --room 一起写）
	if [ -n "$(et_get network_name)" ]; then
		toml_write
	else
		info "房间还没配，等 ② 一起写进 $TOML"
	fi
}

do_room() {
	say "② 房间（与 Astral 房间 ID / 密码一致）"
	ask "房间名/ID（也可以直接粘贴 Astral 分享链接 / 分享码）" "$(et_get network_name)"
	local name="$REPLY" secret=''
	if is_astral_input "$name"; then
		# 粘了分享链接：房间号、密码、对方用的服务器一次全配好，后面只问虚拟 IP 与子网代理
		say "识别到 Astral 分享链接，自动读取房间信息"
		astral_apply "$name" || die "分享链接没解析成功（原因见上）；想手填就重新跑 --room 并输入房间号"
		name="$(et_get network_name)"; secret="$(et_get network_secret)"
	else
		local tries=0
		while : ; do
			ask "房间密钥" "$(et_get network_secret)"
			secret="$REPLY"
			case "$secret" in
				''|mysecret|easytier-password)
					warn "      密钥看起来是空的或界面的示例值 —— 必须填对端房间的真实密码" ;;
				"$name")
					warn "      ⚠️ 密钥与房间名相同（$name）—— 大概率是填串了。"
					warn "         Astral 的『房间 ID』是 network_name、『房间密码』才是 network_secret，两者不同" ;;
				*) break ;;
			esac
			tries=$((tries + 1))
			[ "$tries" -ge 3 ] && { warn "      已连续 3 次有问题，先按你填的继续（可随时用 --room 再改）"; break; }
		done
	fi
	ask "本机虚拟 IPv4" "$(cur_ipaddr)"
	local ip="$REPLY"
	local defproxy proxy lnet
	lnet="$(lan_net)"
	defproxy="$(et_get proxy_network | awk '{print $1}')"
	[ -n "$defproxy" ] || defproxy="$lnet"
	ask "要导出给房间的内网网段（子网代理，留空＝不导出）" "$defproxy"
	proxy="$REPLY"
	# 明显不是网段的先拦下（真塞进 TOML 会被 EasyTier 的 --check-config 拦住，但那个报错不好懂）
	case "$proxy" in
		'') : ;;
		*[!0-9./[:space:]]*) warn "子网代理长得不像网段（形如 192.168.1.0/24），已忽略：$proxy"; proxy='' ;;
	esac
	[ -n "$name" ] && et_set network_name "$name"
	[ -n "$secret" ] && et_set network_secret "$secret"
	[ -n "$ip" ] && et_set ipaddr "${ip%%/*}"
	et_set ip_dhcp '0'
	et_set interface_netmask '255.255.255.0'   # 别用 /8：会与 LAN / 对端子网代理前缀撞车
	et_set enabled '1'
	if [ -n "$proxy" ]; then et_list proxy_network "$proxy"; else et_list proxy_network; fi
	run uci commit easytier
	# uci 只是给人看的副本，config.toml 才是 init 真正读的那份 —— 必须一起写
	toml_write
}

do_ports() {
	say "③ 端口转发（外部 → 内网机器）"
	load_conf
	local defip="$FWD_LANIP"
	# 清单文件是文本，可能被手改坏 —— 别把一个不像 IP 的东西当默认值再传下去
	valid_ipv4 "$defip" || defip=''
	[ -n "$defip" ] || defip='192.168.1.5'

	if [ -n "${1:-}" ]; then
		PORTS_IN="$1"
	else
		info "常见游戏端口：MC Java tcp/25565 │ MC 基岩 udp/19132 │ 帕鲁 udp/8211 │ 泰拉瑞亚 tcp/7777"
		info "               饥荒 udp/10999 │ 星露谷 tcp/24642 │ 求生之路/CS tcp/27015,udp/27015"
		info "写法：25565 或 25565/udp 或 tcp/25565,udp/19132 或 25565>25566 或 25565@192.168.1.9"
		ask "转发到哪台内网机器" "$defip"
		defip="$REPLY"
		ask "要转发的端口（逗号/空格分隔，留空＝清空全部）" ''
		PORTS_IN="$REPLY"
	fi

	if [ -z "$PORTS_IN" ]; then
		write_nft ''
		save_conf "$defip" ''
		warn "已清空所有端口转发"
		return 0
	fi

	local rules
	rules="$(parse_many "$PORTS_IN" "$defip")"
	[ -n "$rules" ] || { warn "没有解析出任何有效规则，未改动"; return 0; }
	printf '%s\n' "$rules" | while IFS=' ' read -r p po i dp; do
		info "  $p $po → $i:$dp"
	done
	write_nft "$rules"
	save_conf "$defip" "$rules"
}

do_common() {
	say "④ 配套设置"
	# 内网路由下发：让宿舍里所有设备自动知道虚拟网段走本机
	local vnet lan
	vnet="$(et_get ipaddr)"
	lan="$(lan_ip)"
	case "$vnet" in
		*/*) vnet="$vnet" ;;
		*.*.*.*) vnet="${vnet%.*}.0/24" ;;
		*) vnet='' ;;
	esac
	if [ -n "$vnet" ]; then
		run uci -q delete dhcp.@dnsmasq[0].dhcp_option
		run uci add_list "dhcp.@dnsmasq[0].dhcp_option=121,$vnet,$lan"
		run uci commit dhcp
		info "DHCP 下发路由：$vnet → $lan"
	fi
	# UA-Mask 豁免 EasyTier 的 TCP 端口（UDP 本来就不经 UA-Mask）
	if [ -x "$UA_INIT" ]; then
		local bp
		bp="$(uci -q get UAmask.main.bypass_ports)"
		case "$bp" in
			*11010*) info "UA-Mask 已豁免 EasyTier 端口 ✓" ;;
			*)
				et_ua="$bp"
				[ -n "$et_ua" ] || et_ua="$UA_BYPASS_DEFAULT"
				run uci set "UAmask.main.bypass_ports=$et_ua 11010-11013"
				run uci set UAmask.main.firewall_decision_delay='2'
				run uci set UAmask.main.Firewall_drop_on_match='0'
				run uci commit UAmask
				run /etc/init.d/UAmask restart
				info "UA-Mask：已加入 11010-11013 豁免 + 判断延迟 2 秒"
				;;
		esac
	fi
}

restart_et() {
	[ "$DRY_RUN" = 1 ] && { info "[dry-run] /etc/init.d/easytier restart"; return 0; }
	/etc/init.d/easytier restart >/dev/null 2>&1
	sleep 8
	say "⑤ 验证"
	local pid cmdline
	# ★ 看进程的**真实参数**，别看日志有没有"开始运行"那一行：
	#   uci 的 etcmd 为空时 init 照样把进程拉起来，只是参数一个都没有，
	#   现象是"进程在、15888 在监听、easytier-cli 能回话，但 tun0 不存在"。
	pid="$(pidof easytier-core 2>/dev/null)"
	if [ -n "$pid" ]; then
		cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
		info "实际启动参数（pid $pid）：$cmdline"
	else
		cmdline=''
		warn "easytier-core 没在跑（/etc/init.d/easytier status 看下）"
	fi
	case "$cmdline" in
		*"-c $TOML"*) info "配置文件已生效（命令行带 -c $TOML）✓" ;;
		*"--network-name"*) info "uci 方式生效（命令行带 --network-name）✓" ;;
		*) warn "命令行里既没有 -c $TOML 也没有 --network-name —— 房间/密钥根本没被读取！
      修：sh $0 --room（本脚本会把 uci 的 etcmd 钉成 config 并生成 $TOML）" ;;
	esac
	info "对端列表（tunnel 列 = udp 即 P2P 直连）："
	has easytier-cli && easytier-cli peer 2>/dev/null | sed 's/^/      /'
	info "路由（应含子网代理网段）："
	has easytier-cli && easytier-cli route 2>/dev/null | sed 's/^/      /'

	# 健康检查：tun 设备在不在。ipv4 列空白 + 没有 tun = 进程没带配置起来
	if ! ip link show "$(tun_dev)" >/dev/null 2>&1; then
		warn "没找到 tun 设备（$(tun_dev)）—— 守护进程很可能没起来"
		info "本次日志最后 15 行："
		tail -n 15 /tmp/easytier.log 2>/dev/null | sed 's/^/      /'
		info "常见原因（按概率）："
		info "  1) 启动参数里没有 -c（见上）—— uci 的 etcmd 不是 config"
		info "  2) 引导节点地址不完整 —— 必须是 tcp://主机:端口（少了前缀或端口会解析失败）"
		info "  3) 房间密钥填错 —— 与房间名混淆；密钥是 Astral 的『房间密码』"
		info "  4) /etc/init.d/easytier 没有执行权限（ls -l 看是否为 755，不是就 chmod 0755）"
		info "  5) 引导节点不可达 —— 可换 tcp://public.easytier.top:11010 验证"
	fi
}

show_all() {
	local etm pid cmdline
	say "启动模式（uci etcmd）"
	etm="$(et_get etcmd)"
	case "$etm" in
		config) info "config → 读 $TOML ✓" ;;
		etcmd)  info "etcmd → 用 uci 字段拼命令行（LuCI 里叫『默认』）" ;;
		'')     warn "空的！init 会用一条**没有参数**的命令行启动 easytier-core：
      进程在、15888 在监听、easytier-cli 能回话，但 tun0 不存在、房间不进。
      修：sh $0 --room（或 sh $0 --toml 重新生成配置）" ;;
		*)      info "$etm（非标准值，init 只会走空参数分支）" ;;
	esac
	pid="$(pidof easytier-core 2>/dev/null)"
	if [ -n "$pid" ]; then
		cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
		info "实际启动参数：$cmdline"
	fi
	say "配置文件（$TOML）"
	[ -f "$TOML" ] && sed 's/^/    /' "$TOML" || info "（不存在 —— 跑 --room 生成）"
	say "uci（给人看的副本，config 模式下不生效）"
	uci show easytier 2>/dev/null | grep -vE "\.log_display=" | sed 's/^/    /'
	say "转发清单（$CONF）"
	[ -f "$CONF" ] && sed 's/^/    /' "$CONF" || info "（不存在）"
	say "内核里的转发规则（$NFT_FILE）"
	if [ -f "$NFT_FILE" ]; then
		nft list chain inet fw4 easytier_dnat 2>/dev/null | sed 's/^/    /' || sed 's/^/    /' "$NFT_FILE"
	else
		info "（不存在 = 没有端口转发）"
	fi
	say "运行状态"
	info "tun 设备：$(ip -br addr show "$(tun_dev)" 2>/dev/null | sed 's/^/      /' || echo 未创建)"
	has easytier-cli && easytier-cli peer 2>/dev/null | sed 's/^/    /'
}

# ──────────────────────────────────── 主流程
MODE=all
case "${1:-}" in
	--ports) MODE=ports; shift ;;
	--node)  MODE=node;  shift ;;
	--room)  MODE=room;  shift ;;
	--astral) MODE=astral; shift ;;
	--show)  MODE=show;  shift ;;
	--toml)  MODE=toml;  shift ;;
	--clear) MODE=clear; shift ;;
	-h|--help) usage; exit 0 ;;
	--*) die "未知参数：$1" ;;
esac
ARG1="${1:-}"
[ $# -gt 0 ] && shift

has nft || warn "没有 nft 命令，转发规则不会生效"

case "$MODE" in
	show)  show_all; exit 0 ;;
	clear)
		load_conf
		write_nft ''
		save_conf "$FWD_LANIP" ''
		warn "已清空所有端口转发"
		exit 0
		;;
	node)   do_node "$ARG1"; restart_et; exit 0 ;;
	room)   do_room; restart_et; exit 0 ;;
	astral) do_astral "$ARG1"; restart_et; exit 0 ;;
	toml)   toml_write; restart_et; exit 0 ;;
	ports)  load_conf; do_ports "$ARG1"; do_common; exit 0 ;;
	all)
		load_conf
		do_node
		do_room
		do_ports "$ARG1"
		do_common
		restart_et
		info "以后改端口只需：sh $0 --ports"
		;;
esac
