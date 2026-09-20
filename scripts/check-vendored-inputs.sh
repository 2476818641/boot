#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 校验「编译需要、但很容易被 .gitignore 吃掉」的文件确实进了 git 仓库。
#
# 为什么需要这个脚本（2026-09-20 CI run #5 实测）：
#   package/UA3F 的 Go 代码用 `//go:embed tc_bpfeb.o` 把 eBPF 目标文件编进二进制，
#   但这 4 个 .o 被仓库根 .gitignore 的 `*.o` 规则忽略了 ——
#   本地树里文件在（能编过），仓库里没有（CI 干净检出 3 秒就失败：
#   `pattern tc_bpfel.o: no matching files found`）。
#   这类「本地能编、云端编不过」的故障只看报错几乎查不出来，所以在这里一次性挡住。
#
# 用法：bash scripts/check-vendored-inputs.sh
# 退出码：0 全部就位；1 有缺失/未入库

set -u

FAIL=0

note() { printf '%s\n' "$*"; }

# ---------- 必须存在的「非源码编译输入」清单 ----------
# 每行一个路径（文件或目录）。目录只要仓库里有至少一个文件就算通过。
REQUIRED="
package/UA3F/go.mod
package/UA3F/go.sum
package/UA3F/main.go
package/UA3F/cmd
package/UA3F/internal
package/UA3F/internal/bpf/tc/tc_bpfeb.o
package/UA3F/internal/bpf/tc/tc_bpfel.o
package/UA3F/internal/bpf/sockmap/sockmap_bpfeb.o
package/UA3F/internal/bpf/sockmap/sockmap_bpfel.o
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

if [ "$FAIL" = 1 ]; then
	note ""
	note "!!! 有编译输入缺失或未入库 —— 现在失败，好过云端编一小时后失败。"
	exit 1
fi

note ""
note "全部就位（本地 = 仓库，云端不会再因为这个原因失败）"
exit 0
