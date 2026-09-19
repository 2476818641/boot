#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 校验「选中的包」是否真的进了配置 / 固件 —— 防止云端构建静默丢包。
#
# 用法：
#   bash scripts/check-package-selection.sh --config <期望的.config> <defconfig后的.config>
#   bash scripts/check-package-selection.sh --manifest bin/targets/mediatek/filogic/*.manifest
#
# 两种模式都会读取 scripts/required-packages.txt，任何一项缺失即 exit 1（CI 直接失败）。
# --config 模式还会打印「被 make defconfig 丢掉的包」全表，便于定位原因。
#
set -eu

TOPDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TOPDIR"
REQ="scripts/required-packages.txt"
[ -f "$REQ" ] || { echo "找不到 $REQ" >&2; exit 1; }

required() {
	grep -v '^[[:space:]]*#' "$REQ" | grep -v '^[[:space:]]*$' | tr -d '\r'
}
sel() {	# sel <config> -> 每行一个被选中的包名（CONFIG_PACKAGE_x=y）
	awk '/^CONFIG_PACKAGE_.*=y$/ { n=$0; sub(/^CONFIG_PACKAGE_/,"",n); sub(/=y$/,"",n); print n }' "$1" | sort -u
}
man() {	# man <manifest> -> 每行一个已安装包名（manifest 格式：name - version）
	awk 'NF && $0 !~ /^#/ { print $1 }' "$1" | sort -u
}

MODE="${1:-}"
case "$MODE" in
--config)
	WANT="${2:?用法: --config <期望的.config> <实际的.config>}"
	GOT="${3:?用法: --config <期望的.config> <实际的.config>}"
	[ -f "$WANT" ] && [ -f "$GOT" ] || { echo "配置文件不存在" >&2; exit 1; }
	sel "$WANT" > /tmp/.sel.want; sel "$GOT" > /tmp/.sel.got
	WANTN=$(wc -l < /tmp/.sel.want); GOTN=$(wc -l < /tmp/.sel.got)
	DROPPED=$(comm -23 /tmp/.sel.want /tmp/.sel.got)
	echo "选中包数：期望 $WANTN -> 实际 $GOTN"
	if [ -n "$DROPPED" ]; then
		echo "⚠️ 以下 $(printf '%s\n' "$DROPPED" | wc -l) 个包被丢弃了（这就是『静默丢包』）："
		printf '%s\n' "$DROPPED" | sed 's/^/    - /'
	else
		echo "✅ 没有任何被选中的包被丢弃"
	fi
	LIST="$GOT"
	;;
--manifest)
	M="${2:?用法: --manifest <manifest 文件>}"
	[ -f "$M" ] || { echo "manifest 不存在: $M" >&2; exit 1; }
	man "$M" > /tmp/.sel.got
	echo "固件实际包含 $(wc -l < /tmp/.sel.got) 个包（$M）"
	LIST=/tmp/.sel.got
	;;
*)
	sed -n '4,12p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
	;;
esac

FAIL=0
echo "必须存在的包："
{
	for p in $(required); do
		case "$MODE" in
		--config)   grep -qxF "CONFIG_PACKAGE_$p=y" "$LIST" || echo "  ❌ 缺失: $p" ;;
		--manifest) grep -qxF "$p" "$LIST"                || echo "  ❌ 缺失: $p" ;;
		esac
	done
} > /tmp/.chk.out 2>&1 || true
cat /tmp/.chk.out
if grep -q '❌' /tmp/.chk.out; then FAIL=1; else echo "  ✅ 全部存在（$(required | wc -l) 项）"; fi

if [ "$FAIL" = 1 ]; then
	cat <<'EOF'

!!! 关键包缺失，判定为构建不可用。
    配置模式：说明 make defconfig 把这些包丢了 —— 常见原因是 feeds 没装全/网络中断，
              或某个依赖包在 feeds 里不存在（看 defconfig 输出的 WARNING 行）。
    产物模式：说明包虽然选中，但没进最终镜像（未编译 / 依赖被裁掉）。
EOF
	exit 1
fi
