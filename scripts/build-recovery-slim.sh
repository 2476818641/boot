#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 生成「精简 recovery 镜像」
# ---------------------------------------------------------------
# 背景：OpenWrt 的 -initramfs-recovery.itb 与正式 rootfs **共用同一套已选包**，
#       本仓库选了 380 个包 → initramfs 29MB、解包约 95MB，
#       在只有 256MB 内存的 JCG Q30 Pro/Q30 上 init 阶段必然 OOM panic。
#
# 做法：临时把 .config 换成「精简包列表」（scripts/recovery-slim-packages.txt），
#       重新生成一次镜像，取走精简 recovery 后自动恢复正式配置。
#       **不修改源码树**，rebase 上游零冲突。
#
# 用法：
#   bash scripts/build-recovery-slim.sh
#
# 产物：
#   recovery-slim-out/recovery-slim.itb        精简 recovery（覆盖正式版同名文件使用）
#   recovery-slim-out/recovery-slim.sha256
#   recovery-slim-out/recovery-slim.manifest   精简镜像的包清单（核对用）
#
set -eu

TOPDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TOPDIR"

KEEP_FILE="scripts/recovery-slim-packages.txt"
BAK=".config.production"
SLIM=".config.slim"
OUTDIR="recovery-slim-out"
DEVICE_DIR="bin/targets/mediatek/filogic"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

[ -f .config ]      || die "找不到 .config —— 请在 OpenWrt 源码根目录运行"
[ -f "$KEEP_FILE" ] || die "找不到 $KEEP_FILE"

# ---------- 0. 备份 ----------
log "0/5 备份正式配置（与已有产物）"
cp -f .config "$BAK"
mkdir -p "$OUTDIR"
if [ -d "$DEVICE_DIR" ]; then
	cp -f "$DEVICE_DIR"/*.itb "$DEVICE_DIR"/*.fip "$DEVICE_DIR"/*.bin "$OUTDIR/" 2>/dev/null || true
fi
echo "    正式配置 → $BAK"

# 无论成功、失败还是被 Ctrl-C，都保证正式 .config 被恢复
RESTORED=0
cleanup() {
	[ "$RESTORED" = 1 ] && return 0
	[ -f "$BAK" ] && cp -f "$BAK" .config && printf '\n\033[1;33m[!] 已自动恢复正式 .config\033[0m\n'
}
trap cleanup EXIT HUP INT TERM

# ---------- 1. 生成精简 .config ----------
log "1/5 由保留清单生成精简配置"
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
		name = m.group(1)
		present.add(name)
		out.append('CONFIG_PACKAGE_%s=y' % name if name in keepset
			   else '# CONFIG_PACKAGE_%s is not set' % name)
		continue
	m = OFF_RE.match(line)          # "关闭"状态的包：在保留清单里就主动打开
	if m:
		name = m.group(1)
		present.add(name)
		out.append('CONFIG_PACKAGE_%s=y' % name if name in keepset else line)
		continue
	out.append(line)
open(dst, 'w').write('\n'.join(out) + '\n')
missing = [k for k in keep if k not in present]
print('    保留 %d 个包 → %s' % (len(keep), dst))
if missing:
	print('    ⚠️ 以下名字在 .config 中不存在（可能是拼写错误，或该目标没有此包）：')
	print('       ' + ', '.join(missing))
PY

# ---------- 2. 切换配置 ----------
log "2/5 切换配置并归一化（make defconfig 会自动补齐依赖）"
cp -f "$SLIM" .config
make defconfig >/dev/null
grep -q '^CONFIG_TARGET_ROOTFS_INITRAMFS=y' .config || die "initramfs 未启用，请检查 .config"
echo "    目标: $(grep -m1 '^CONFIG_TARGET_PROFILE=' .config)"
echo "    选中包数: $(grep -c '^CONFIG_PACKAGE_.*=y' .config)"

# ---------- 3. 生成镜像 ----------
# 注意：本树**没有** `image` 这个 make 目标（会报 "No rule to make target 'image'"），
#       镜像是 world 里的 target/stamp-install 阶段生成的，所以这里直接 make（= world）。
log "3/5 生成镜像（复用已有工具链与 dl/ 缓存；首次约 40~70 分钟）"
BUILD_LOG="recovery-slim-build.log"
if ! make -j"$(nproc)" > "$BUILD_LOG" 2>&1; then
	warn "并行构建失败 —— 自动用 -j1 V=s 重跑以拿到真实报错（增量续编，不会重做已完成的）"
	if ! make -j1 V=s >> "$BUILD_LOG" 2>&1; then
		printf '\n----- %s 最后 60 行（真实报错在这里）-----\n' "$BUILD_LOG"
		tail -60 "$BUILD_LOG"
		die "构建失败。完整日志：$BUILD_LOG  —— 请把上面这段发给 AI 助手"
	fi
fi

# ---------- 4. 取产物 ----------
log "4/5 收集精简 recovery"
REC="$(ls -1 "$DEVICE_DIR"/*-initramfs-recovery.itb 2>/dev/null | head -1)" || true
[ -n "${REC:-}" ] || die "没有产出 *-initramfs-recovery.itb，请检查上面的编译输出"
cp -f "$REC" "$OUTDIR/recovery-slim.itb"
if ls -1 "$DEVICE_DIR"/*.manifest >/dev/null 2>&1; then
	cp -f "$DEVICE_DIR"/*.manifest "$OUTDIR/recovery-slim.manifest"
fi
sha256sum "$OUTDIR/recovery-slim.itb" | tee "$OUTDIR/recovery-slim.sha256"
echo "    大小: $(du -h "$OUTDIR/recovery-slim.itb" | cut -f1)  （正式版为 29MB）"
echo "    包数: $(wc -l < "$OUTDIR/recovery-slim.manifest" 2>/dev/null || echo '?')"

# ---------- 5. 恢复 ----------
log "5/5 恢复正式配置"
cp -f "$BAK" .config
make defconfig >/dev/null
RESTORED=1
echo "    正式配置已恢复（下次 make（world）会重新生成正式固件）"
echo "    注意：$DEVICE_DIR 里现在是**精简版**产物，正式固件可用 make 重新生成"

log "完成 → $OUTDIR/"
ls -lh "$OUTDIR/"
cat <<'EOF'

下一步（验证）：
  1) 看体积与包数：应约 8~12MB、包数远小于 380
  2) 通过 TFTP 启动它验证内存：
       U-Boot 菜单 -> 2 (Boot system via TFTP)  或  run boot_tftp
       （TFTP 根目录放 recovery-slim.itb，并改名为
         immortalwrt-mediatek-filogic-jcg_q30-pro-initramfs-recovery.itb）
  3) 进系统后检查：
       free -m ; ubinfo -a ; mtd -h ; sysupgrade -h
     用 LuCI 或 sysupgrade 刷一次正式固件，验证闭环
EOF
