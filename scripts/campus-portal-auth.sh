#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# campus-portal-auth.sh —— 校园网网页认证脚本（骨架 / 模板）
#
# 装到路由器上的位置：/etc/campus-portal-auth.sh
#   wget -O /etc/campus-portal-auth.sh <本文件地址>
#   chmod +x /etc/campus-portal-auth.sh
#
# 谁调用它：
#   - campus-net-setup.sh（配置完网络后，不通就调它，最多 3 次）
#   - /etc/hotplug.d/iface/99-campus-portal（WAN 一上线自动调，见 campus-portal-autologin.sh）
#   - 定时兜底：crontab 里每 5 分钟一次
#
# 约定（务必遵守，调用方按这个判断）：
#   成功 → exit 0（并且外网真的能通）
#   失败 → exit 非 0（调用方会重试）
#   已经在线 → exit 0，什么都不做（幂等，方便定时任务反复跑）
#   参数：--force 强制走一次登录流程，即使当前已经在线
#
# 可用的环境变量 / UCI 配置（env 优先）：
#   AUTH_URL   认证接口地址        uci get campus.main.auth_url
#   CHECK_URL  联网判定用地址      uci get campus.main.check_url   （默认 204 接口）
#   CAMPUS_USER 账号               uci get campus.main.user
#   CAMPUS_PASS 密码               uci get campus.main.pass
#   UA         伪造的 User-Agent   uci get campus.main.ua          （留空=不改）
#   WANIF      上网接口名          uci get campus.main.iface       （默认 wan）
#
# 抓包要填的地方都标了 “← 抓包”：
#   1) 认证接口地址（含端口）
#   2) 请求方法（GET 还是 POST）与字段名（user? username? 学号字段叫什么）
#   3) 成功判定标志（响应里出现什么算成功）
#   4) 是否需要先 GET 一次认证页拿 cookie / token
#
set -u

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
log() { logger -t campus-portal "$*" 2>/dev/null || true; }
ug()  { uci -q get "$1" 2>/dev/null; }
env_or_uci() {	# env_or_uci <变量名> <uci键> <默认值>
	eval "_v=\"\${$1:-}\""
	[ -z "$_v" ] && _v="$(ug "$2")"
	[ -z "$_v" ] && _v="$3"
	eval "$1=\"\$_v\""
}

env_or_uci AUTH_URL   campus.main.auth_url   ''						# ← 抓包：认证接口
env_or_uci CHECK_URL  campus.main.check_url  'http://connect.rom.miui.com/generate_204'
env_or_uci CAMPUS_USER campus.main.user      ''
env_or_uci CAMPUS_PASS campus.main.pass      ''
env_or_uci UA         campus.main.ua         ''
env_or_uci WANIF      campus.main.iface      'wan'

COOKIE="${COOKIE:-/tmp/campus-portal.cookie}"

# --- 联网判定：先看是否已经在线（幂等，定时任务反复跑也没事）
online() {
	[ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$CHECK_URL" 2>/dev/null)" = "204" ] && return 0
	ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && return 0
	return 1
}
if [ "$FORCE" != 1 ] && online; then
	say "已经在线，不用登录"
	exit 0
fi

[ -n "$AUTH_URL" ] || { say "没配 AUTH_URL：先跑 campus-net-setup.sh，或 uci set campus.main.auth_url=..."; exit 2; }
[ -n "$CAMPUS_USER" ] || { say "没配账号：uci set campus.main.user=学号"; exit 2; }

# 用函数而不是拼字符串：UA 里有空格，拼字符串会被 shell 拆成多个参数（真实踩过）
curl_auth() {
	if [ -n "$UA" ]; then curl -s -m 15 -k -A "$UA" "$@"
	else curl -s -m 15 -k "$@"; fi
}

# --- 1)（可选）先 GET 认证页，拿 cookie / 内嵌 token
#     有些认证页要先访问一次才给会话；抓包时如果看到先有 GET 再 POST，就把这行打开：
# curl_auth -c "$COOKIE" "$AUTH_URL" >/dev/null

# --- 2) 提交账号密码  ← 抓包：把 URL / 方法 / 字段名 换成你抓到的
RESP="$(curl_auth -b "$COOKIE" -c "$COOKIE" \
	-X POST "$AUTH_URL" \
	--data-urlencode "user=$CAMPUS_USER" \
	--data-urlencode "pass=$CAMPUS_PASS" \
	2>/dev/null)"
say "认证响应: $(printf '%s' "$RESP" | head -c 300)"

# --- 3) 判定成功  ← 抓包：把下面的关键字换成你抓到的成功标志
case "$RESP" in
	*'"result":"1"'*|*'success'*|*'登录成功'*|*'认证成功'*)
		say "响应看起来是成功";;
	*)
		# 响应里没有成功标志时，用真实连通性兜底
		say "响应里没有成功标志，用连通性兜底判断…"
		sleep 2
		if online; then
			say "按连通性判定：成功"
		else
			say "认证失败：检查账号密码 / 字段名 / 是否需要先 GET 拿 cookie / 响应格式"
			log "auth failed: $RESP"
			exit 1
		fi
		;;
esac

# --- 4) 最后再用连通性确认一次
sleep 2
if online; then
	say "认证成功 ✅"
	log "auth ok (user=$CAMPUS_USER iface=$WANIF)"
	exit 0
fi
say "提交了但还不通，检查账号密码/字段名（可用 --force 强制重试）"
log "auth submitted but still offline"
exit 1
