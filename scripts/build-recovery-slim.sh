#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 默认构建入口：正式固件 + **精简 recovery 镜像**
# ===============================================================
# 背景：OpenWrt 的 -initramfs-recovery.itb 与正式 rootfs **共用同一套已选包**，
#       本仓库选了 380 个包 → initramfs 29MB、解包约 95MB，
#       在只有 256MB 内存的 JCG Q30 Pro/Q30 上 init 阶段必然 OOM panic。
#       本脚本额外跑一次「只含 44 个包」的精简构建，并把它的 recovery 装回产物集，
#       这样 **默认编译出来的 recovery 就是精简版（9.0MB / 解包 20.5MB）**，
#       「按住 reset 上电 → TFTP 自动拉取 → 网页刷固件」这条救砖路直接可用。
#
# 用法：
#   bash scripts/build-recovery-slim.sh              # 默认：正式构建 + 精简 recovery（推荐）
#   bash scripts/build-recovery-slim.sh --slim-only  # 只生成精简 recovery（正式产物已存在时，CI 用这个）
#
# 产物（都在 recovery-slim-out/，可直接放进 TFTP 目录）：
#   ...-squashfs-sysupgrade.itb   正式固件
#   ...-initramfs-recovery.itb    **精简版**内存系统（9.0MB）
#   ...-bl31-uboot.fip            U-Boot 本体
#   ...-preloader.bin             BL2
#   mt7981-ram-ddr3-bl2.bin       mtk_uartboot 用的 RAM BL2
#   sha256sums                    校验值
#
# 说明：只处理配置层面，**不 patch 源码树**，rebase 上游零冲突。
#
set -eu

TOPDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TOPDIR"

# Go 模块代理：UA-Mask 是 Go 项目，编译时要拉依赖模块。
# proxy.golang.org 在国内（本机）不通，这里兜底用 goproxy.cn；CI（海外）走它也没问题。
# 想用别的代理：GOPROXY=... bash scripts/build-recovery-slim.sh
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

KEEP_FILE="scripts/recovery-slim-packages.txt"
BAK=".config.production"
SLIM=".config.slim"
OUTDIR="recovery-slim-out"
ART_BAK="$OUTDIR/production-artifacts"
DEVICE_DIR="bin/targets/mediatek/filogic"
BUILD_LOG="recovery-slim-build.log"      # 精简那一遍的日志
PROD_LOG="build-production.log"          # 正式那一遍的日志（默认模式）
TMPREC="$OUTDIR/.slim-recovery.tmp"      # 精简 recovery 的暂存（装配阶段用）

MODE="full"
case "${1:-}" in
	""|--full)    MODE="full" ;;
	--slim-only)  MODE="slim-only" ;;
	-h|--help)    sed -n '4,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)            printf '未知参数: %s（用 --help 查看用法）\n' "$1" >&2; exit 1 ;;
esac

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

[ -f .config ]      || die "找不到 .config —— 请在 OpenWrt 源码根目录运行"
[ -f "$KEEP_FILE" ] || die "找不到 $KEEP_FILE"

# 本树没有 `image` 目标（会报 "No rule to make target 'image'"），
# 镜像是 world 里的 target/stamp-install 阶段生成的，所以一律直接 make。
build() {
	_log="$1"
	if ! make -j"$(nproc)" > "$_log" 2>&1; then
		warn "并行构建失败 —— 自动用 -j1 V=s 重跑以拿到真实报错（增量续编，不会重做已完成的）"
		if ! make -j1 V=s >> "$_log" 2>&1; then
			printf '\n----- %s 最后 60 行（真实报错在这里）-----\n' "$_log"
			tail -60 "$_log"
			die "构建失败。完整日志：$_log —— 请把上面这段发给 AI 助手"
		fi
	fi
}

# 保存/取回正式产物。恢复时**跳过 recovery**：它最终要用精简版替换
save_artifacts() {
	rm -rf "$1"; mkdir -p "$1"
	[ -d "$DEVICE_DIR" ] || return 0
	for f in "$DEVICE_DIR"/*; do
		case "$(basename "$f")" in
			*initramfs-recovery.itb|sha256sums) continue ;;
		esac
		cp -f "$f" "$1/" 2>/dev/null || true
	done
}
restore_artifacts() {
	[ -d "$1" ] || return 0
	cp -f "$1"/* "$DEVICE_DIR/" 2>/dev/null || true
}
# 按 OpenWrt 风格重建 sha256sums（二进制模式：<hash> *<file>）
regen_sums() {
	( cd "$1" && \
	  find . -maxdepth 1 -type f ! -name sha256sums -printf '%f\n' | sort | \
	  while read -r f; do sha256sum -b "$f"; done > sha256sums )
}

# 合理性检查：正式固件不该这么小。
# 教训（2026-09-19）：以前脚本不会保护正式产物，一次精简 pass 之后
# bin/targets/.../ 里躺着的是**精简配置**编出来的 11.4MB "正式固件"，
# 而 380 包正式配置的产物是 33.9MB。若此时用 --slim-only，脚本会把这份
# 11.4MB 当成"正式产物"再装回去 —— 装配出来的固件缺 wifi/UA-Mask 等一大堆包。
check_production_size() {
	SU="$(ls -1 "$1"/*-squashfs-sysupgrade.itb 2>/dev/null | head -1)" || true
	if [ -z "${SU:-}" ]; then
		# 教训（2026-09-20 CI run #5）：正式 make 失败被 `| tee` 吞掉（管道退出码是 tee 的 0），
		# 流程继续走到精简 pass，此时 bin/targets 里**根本没有**正式固件；装配阶段
		# 就把 11MB 的精简固件当成"正式固件"收集上传。这里必须硬失败。
		warn "没找到 *-squashfs-sysupgrade.itb —— 正式固件根本没编出来"
		warn "  常见原因：上一步 make 失败但被管道吞掉了退出码（make | tee 的退出码默认取 tee 的 0，要 set -o pipefail）"
		[ "${FORCE_SLIM_OK:-0}" = "1" ] || die "拒绝继续（确实只想产出精简 recovery 就加 FORCE_SLIM_OK=1 重跑）"
		warn "FORCE_SLIM_OK=1：按你的要求继续 —— 产物集里的『正式固件』将不可用。"
		return 0
	fi
	SZ=$(stat -c%s "$SU")
	echo "    正式固件：$(basename "$SU") = $SZ 字节"
	if [ "$SZ" -lt 20000000 ]; then
		warn "这份『正式固件』只有 $SZ 字节（< 20MB），看起来是**精简配置**编出来的："
		warn "  380 包正式配置的 sysupgrade 约 33.9MB；精简配置只有 ~11MB。"
		warn "  继续下去，装配出的产物集里『正式固件』会缺 wifi / UA-Mask / passwall 等包。"
		warn "  建议先跑默认模式完整编译：bash scripts/build-recovery-slim.sh"
		[ "${FORCE_SLIM_OK:-0}" = "1" ] || die "拒绝继续（确实想这么做就加 FORCE_SLIM_OK=1 重跑）"
		warn "FORCE_SLIM_OK=1：按你的要求继续。"
	fi
}

TOTAL=6
[ "$MODE" = "slim-only" ] && TOTAL=5
step() { printf '\n\033[1;32m==> %s/%s %s\033[0m\n' "$1" "$TOTAL" "$2"; }

# ---------- 0. 备份 ----------
step 0 "备份正式配置（模式：$MODE）"
cp -f .config "$BAK"
mkdir -p "$OUTDIR"
echo "    正式配置 → $BAK"

# 无论成功、失败还是 Ctrl-C，都保证正式 .config 被恢复
RESTORED=0
cleanup() {
	[ "$RESTORED" = 1 ] && return 0
	[ -f "$BAK" ] && cp -f "$BAK" .config && printf '\n\033[1;33m[!] 已自动恢复正式 .config\033[0m\n'
}
trap cleanup EXIT HUP INT TERM

# ---------- 1~2. 正式构建（默认模式）----------
N=1
if [ "$MODE" = "full" ]; then
	step $N "正式构建（production，首次约 1~2 小时）"; N=$((N+1))
	build "$PROD_LOG"
	step $N "保存正式产物（recovery 稍后用精简版替换）"; N=$((N+1))
	save_artifacts "$ART_BAK"
	check_production_size "$ART_BAK"
	ls -1 "$ART_BAK" 2>/dev/null | sed 's/^/    /' || true
else
	step $N "检查已有正式产物（--slim-only 模式）"; N=$((N+1))
	[ -d "$DEVICE_DIR" ] || warn "$DEVICE_DIR 不存在：将只产出精简 recovery，产物集不完整"
	save_artifacts "$ART_BAK"
	check_production_size "$ART_BAK"
fi

# ---------- 生成精简配置 ----------
step $N "由保留清单生成精简配置"; N=$((N+1))
python3 - "$KEEP_FILE" "$BAK" "$SLIM" <<'PY'
import re, sys
keep_file, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
keep = [l.strip() for l in open(keep_file) if l.strip() and not l.lstrip().startswith('#')]
keepset = set(keep)
lines = open(src).read().splitlines()
present, out = set(), []
SET_RE = re.compile(r'^(?:# )?CONFIG_PACKAGE_([^=]+)=')
OFF_RE = re.compile(r'^# CONFIG_PACKAGE_(\S+) is not set$')
for line in lines:
	m = SET_RE.match(line)
	if m:
		n = m.group(1); present.add(n)
		out.append('CONFIG_PACKAGE_%s=y' % n if n in keepset else '# CONFIG_PACKAGE_%s is not set' % n)
		continue
	m = OFF_RE.match(line)
	if m:
		n = m.group(1); present.add(n)
		out.append('CONFIG_PACKAGE_%s=y' % n if n in keepset else line)
		continue
	out.append(line)
open(dst, 'w').write('\n'.join(out) + '\n')
missing = [k for k in keep if k not in present]
print('    保留 %d 个包 → %s' % (len(keep), dst))
if missing:
	print('    ⚠️ 以下名字在 .config 中不存在（可能拼写错误，或该目标没有此包）：')
	print('       ' + ', '.join(missing))
PY

# ---------- 切换配置 ----------
step $N "切换配置并归一化（make defconfig 自动补齐依赖）"; N=$((N+1))
cp -f "$SLIM" .config
make defconfig >/dev/null
grep -q '^CONFIG_TARGET_ROOTFS_INITRAMFS=y' .config || die "initramfs 未启用，请检查 .config"
echo "    目标: $(grep -m1 '^CONFIG_TARGET_PROFILE=' .config)"
echo "    选中包数: $(grep -c '^CONFIG_PACKAGE_.*=y' .config)"

# ---------- 精简构建 ----------
step $N "精简构建（约 20~40 分钟）"; N=$((N+1))
build "$BUILD_LOG"

# ---------- 装配最终产物集 ----------
step $N "装配最终产物集（正式固件 + 精简 recovery）"
REC="$(ls -1 "$DEVICE_DIR"/*-initramfs-recovery.itb 2>/dev/null | head -1)" || true
[ -n "${REC:-}" ] || die "没有产出 *-initramfs-recovery.itb，请检查 $BUILD_LOG"
cp -f "$REC" "$TMPREC"
# 精简版的包清单（正式版 manifest 马上会被还原覆盖，所以先留一份用于核对）
cat "$DEVICE_DIR"/*.manifest > "$OUTDIR/recovery-slim.manifest" 2>/dev/null || true
restore_artifacts "$ART_BAK"                                  # 正式固件/fip/preloader 放回
cp -f "$TMPREC" "$DEVICE_DIR/$(basename "$REC")"              # recovery 用精简版（文件名不变）
regen_sums "$DEVICE_DIR"

# 导出干净的一份：先清掉上次的导出，再拷正式产物（含被替换过的 recovery）
rm -f "$OUTDIR"/*.itb "$OUTDIR"/*.fip "$OUTDIR"/*.bin "$OUTDIR"/*.sha256 "$OUTDIR"/sha256sums 2>/dev/null || true
cp -f "$DEVICE_DIR"/*.itb "$DEVICE_DIR"/*.fip "$DEVICE_DIR"/*.bin "$OUTDIR/" 2>/dev/null || true
cp -f "$DEVICE_DIR"/sha256sums "$OUTDIR/" 2>/dev/null || true
# 再放一份好认的别名（必须在上面 rm 之后，否则会被删掉）
cp -f "$TMPREC" "$OUTDIR/recovery-slim.itb"
rm -f "$TMPREC"
# OUTDIR 里没有 manifest/profiles.json，所以它自己的校验文件要按实际内容重建
regen_sums "$OUTDIR"

# ---------- 恢复配置 ----------
cp -f "$BAK" .config
make defconfig >/dev/null
RESTORED=1
echo "    正式配置已恢复"

log "完成"
printf '  精简 recovery : %s（正式版 29MB；解包 95MB -> 本版 20.5MB）\n' "$(du -h "$OUTDIR/recovery-slim.itb" | cut -f1)"
printf '  sha256        : %s\n' "$(sha256sum "$OUTDIR/recovery-slim.itb" | cut -d' ' -f1)"
printf '  产物目录      : %s/\n\n' "$OUTDIR"
ls -lh "$OUTDIR" | grep -vE '^total|production-artifacts' || true
cat <<'EOF'
结果说明：
  bin/targets/mediatek/filogic/ 里的 ...-initramfs-recovery.itb 已经**就是精简版**（文件名没变，
  U-Boot 的 bootfile= 直接指向它），recovery-slim-out/ 里是同一份拷贝 + sha256sums。

下一步（真机验证，只读内存、不写 NAND）：
  1) 把 recovery-slim.itb 复制进 TFTP 根目录，命名为
     immortalwrt-mediatek-filogic-jcg_q30-pro-initramfs-recovery.itb
  2) 路由器上电 -> 3 秒菜单按任意键 -> 2. Boot system via TFTP
  3) 进系统后检查： free -m （期望可用内存 >=150MB）、ubinfo -a、mtd -h、sysupgrade -h
EOF
