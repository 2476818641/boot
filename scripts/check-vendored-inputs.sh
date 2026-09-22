#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 校验「编译需要、但很容易被 .gitignore 吃掉」的文件确实进了 git 仓库。
#
# 为什么需要这个脚本（2026-09-20 CI run #5 实测）：
#   当时 vendored 的 package/UA3F 用 `//go:embed tc_bpfeb.o` 把 eBPF 目标文件编进二进制，
#   但那 4 个 .o 被仓库根 .gitignore 的 `*.o` 规则忽略了 ——
#   本地树里文件在（能编过），仓库里没有（CI 干净检出 3 秒就失败：
#   `pattern tc_bpfel.o: no matching files found`）。
#   这类「本地能编、云端编不过」的故障只看报错几乎查不出来，所以在这里一次性挡住。
#   （UA3F 已被 UA-Mask 取代，但这条教训通用：凡是非标准源码的编译输入都必须入库。）
#
# 用法：bash scripts/check-vendored-inputs.sh
# 退出码：0 全部就位；1 有缺失/未入库

set -u

FAIL=0

note() { printf '%s\n' "$*"; }

# ---------- 必须存在的「非源码编译输入」清单 ----------
# 每行一个路径（文件或目录）。目录只要仓库里有至少一个文件就算通过。
REQUIRED="
package/UA-Mask/VERSION
package/UA-Mask/LICENSE
package/UA-Mask/LOCAL-NOTES.md
package/UA-Mask/core/go.mod
package/UA-Mask/core/go.sum
package/UA-Mask/core/cmd/UAmask/main.go
package/UA-Mask/core/internal
package/UA-Mask/Makefile
package/UA-Mask/openwrt/root/etc/init.d/UAmask
package/UA-Mask/openwrt/root/etc/config/UAmask
package/UA-Mask/openwrt/luci/controller/UAmask.lua
package/UA-Mask/openwrt/luci/model/cbi/UAmask.lua
"

IN_GIT=1
git rev-parse --git-dir >/dev/null 2>&1 || IN_GIT=0
[ "$IN_GIT" = 1 ] || note "⚠️ 当前不是 git 仓库，只校验文件是否存在（跳过入库检查）"

tracked() {	# tracked <path> —— 仓库里有没有这个路径
	[ "$IN_GIT" = 1 ] || return 0
	[ -n "$(git ls-files -- "$1" 2>/dev/null)" ]
}

note "校验编译输入（共 $(printf '%s\n' $REQUIRED | grep -c .) 项）："
for p in $REQUIRED; do
	if [ ! -e "$p" ]; then
		note "  ❌ 磁盘上就不存在：$p"
		note "     → 上游源码不完整，重新覆盖该目录（见 package/UA3F/LOCAL-NOTES.md）"
		FAIL=1
	elif ! tracked "$p"; then
		note "  ❌ 文件在本地、但**没进 git 仓库**：$p"
		note "     → 这是最阴的一种：本地能编过，CI 干净检出必失败"
		note "     → 修：git add -f $p"
		FAIL=1
	else
		note "  ✅ $p"
	fi
done

# ---------- 反向校验：不该入库的东西 ----------
# UA-Mask 上游把编译好的 x86-64 二进制误提交在 core/UAmask（6.5MB），
# 对固件编译毫无用处、还会白白撑大仓库，所以明确禁止它出现在这里。
if [ -e package/UA-Mask/core/UAmask ]; then
	note "  ❌ package/UA-Mask/core/UAmask 不该存在（上游误提交的 x86-64 预编译产物，6.5MB）"
	note "     → rm -f package/UA-Mask/core/UAmask"
	FAIL=1
else
	note "  ✅ package/UA-Mask/core/UAmask 不存在（已剔除上游误提交的预编译产物）"
fi

if [ "$FAIL" = 1 ]; then
	note ""
	note "!!! 有编译输入缺失或未入库 —— 现在失败，好过云端编一小时后失败。"
	exit 1
fi

note ""
note "全部就位（本地 = 仓库，云端不会再因为这个原因失败）"
exit 0
