#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# campus-portal-autologin.sh —— WAN 一上线就自动跑校园网网页认证
#
# 装到路由器上的位置（必须是这个路径，hotplug 才会执行）：
#   wget -O /etc/hotplug.d/iface/99-campus-portal <本文件地址>
#   chmod +x /etc/hotplug.d/iface/99-campus-portal
#
# 原理：netifd 在接口 up/down 时会调用 /etc/hotplug.d/iface/ 下所有脚本，
#       环境变量给 ACTION（ifup/ifdown/ifupdate）和 INTERFACE（网络名）。
#       这里在 WAN 侧接口 ifup 时后台跑认证脚本，失败重试 3 次。
#
# 配合定时兜底（可选，防掉线后 ifup 不再触发）：
#   echo '*/5 * * * * /etc/campus-portal-auth.sh --quiet' >> /etc/crontabs/root
#   /etc/init.d/cron restart
#
# 不想用就删掉本文件（或 chmod -x）。

[ "${ACTION:-}" = "ifup" ] || exit 0

# 哪些接口算 WAN 侧：默认 wan / wwan；可用 uci campus.main.iface 改
WANIF="$(uci -q get campus.main.iface 2>/dev/null)"
case "${INTERFACE:-}" in
	wan|wwan) ;;
	"$WANIF") ;;
	*) exit 0 ;;
esac

[ -x /etc/campus-portal-auth.sh ] || {
	logger -t campus-portal "接口 $INTERFACE 上线了，但 /etc/campus-portal-auth.sh 不存在或不可执行"
	exit 0
}

logger -t campus-portal "接口 $INTERFACE 上线，开始认证"
(
	i=1
	while [ "$i" -le 3 ]; do
		sleep 5
		if /etc/campus-portal-auth.sh --quiet; then
			logger -t campus-portal "认证成功（第 $i 次）"
			exit 0
		fi
		logger -t campus-portal "第 $i 次认证失败，重试"
		i=$((i + 1))
	done
	logger -t campus-portal "认证 3 次都失败，看 logread | grep campus-portal"
) &
