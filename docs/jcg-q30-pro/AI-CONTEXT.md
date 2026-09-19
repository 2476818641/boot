# AI CONTEXT — JCG Q30 Pro/Q30 ImmortalWrt build, bootloader migration & recovery

Purpose: give an AI agent everything needed to operate on these two routers **without re-deriving anything**.
All facts below were empirically verified in a real session (2026-09); each has the evidence that proved it.

---

## 1. DEVICE / TARGET FACTS (verified)

```yaml
board: JCG Q30 Pro  (= JCG Q30 = CMCC MR3000D-CIq, same board, same images)
soc: MediaTek MT7981B, 2x Cortex-A53 @1300MHz
ram: 256 MiB DDR3 @1866Mbps   # Nanya NT5CC128M16JR-EK (physical check)
flash: 128 MiB Winbond SPI-NAND, block 128KiB, page 2048, OOB 64
switch: MT7531 (DSA), lan1..lan3 + wan
uart: 115200 8N1, 3.3V, pads unpopulated (need probe/wire), console ttyS0
openwrt_target: mediatek/filogic
openwrt_profile: jcg_q30-pro
supported_devices: ["jcg,q30-pro", "jcg,q30"]
package_manager: apk   # NOT opkg
```

### Flash / MTD layout (identical in U-Boot DTS and Linux DTS)

| partition | offset | size |
|---|---|---|
| `bl2` | 0x000000 | 1 MiB |
| `u-boot-env` (U-Boot DTS calls it `orig-env`) | 0x100000 | 512 KiB |
| `Factory` (U-Boot DTS: `factory`) | 0x180000 | 2 MiB |
| `fip` | 0x380000 | 2 MiB |
| `ubi` | 0x580000 | 112 MiB (U-Boot/NMBM view reports 110 MiB) |

Linux sees ubi as `mtd4`; stock/hanwckf U-Boot saw it as `mtd6` with 110 MiB (NMBM reservation). 0 bad blocks on both units.

### Target UBI volume layout (after successful migration)

| volume | purpose |
|---|---|
| `fit` | production FIT (kernel+dtb+rootfs). Kernel derives `/dev/fit0` **from this volume name** |
| `rootfs_data` | ubifs overlay, mounted at `/overlay` (~62 MiB usable) |
| `ubootenv` | U-Boot env (primary) — **never delete** |
| `ubootenv2` | U-Boot env (redundant) — required by `CONFIG_ENV_UBI_VOLUME_REDUND`; **never delete** |
| `layout volume` | UBI internal |

Legacy/foreign layouts seen on the two units (before migration):
- unit 1: `kernel` (FIT here!), `rootfs_data`, `ubootenv`
- unit 2: `kernel`, `rootfs`, `rootfs_data`, `ubootenv`, later a stray `recovery`

---

## 2. ARTIFACTS (exact, from `bin/targets/mediatek/filogic/`)

| file | bytes | sha256 |
|---|---|---|
| `immortalwrt-mediatek-filogic-jcg_q30-pro-squashfs-sysupgrade.itb` | 33866011 | `89c93f384470bfa7abecb16d62637dd8d5c3dd44deff11631db4660fd7c23f4f` |
| `immortalwrt-mediatek-filogic-jcg_q30-pro-initramfs-recovery.itb` | 29360128 | `569936a52dfc54eb7194fbe0d145808fe3ecc40cbfffc167dc48b48c7a88f8ee` |
| `immortalwrt-mediatek-filogic-jcg_q30-pro-bl31-uboot.fip` | 1073444 | `f06f684fe85b6ec1279c55b042f9143d40bbd848f3005b8af7562f6ddb4f9de3` |
| `immortalwrt-mediatek-filogic-jcg_q30-pro-preloader.bin` | 230232 | `bf9724f7eb8c0ddddf1f8fc9d6c104d892c09621125ada137ca6b7447543cc7d` |
| `mt7981-ram-ddr3-bl2.bin` (for mtk_uartboot) | 210368 | `bdb2493e36a169c652875529ee7d1e8ee7f1f064d5fa526fde36a1980676df35` |

Version string: `ImmortalWrt 25.12-SNAPSHOT r38026-5e20cf34aa`, kernel `6.12.87`.
U-Boot banner: `U-Boot 2025.10-ImmortalWrt-r38026-5e20cf34aa (May 25 2026 - 10:39:51 +0000)`.

**Critical distinction:** `preloader.bin` (230232, NAND BL2) is **NOT** interchangeable with
`mt7981-ram-ddr3-bl2.bin` (210368, RAM BL2). mtk_uartboot takes the *RAM* one.

---

## 3. U-BOOT ENVIRONMENT REFERENCE (built-in defaults, from `defenvs/jcg_q30-pro_env`)

```
ipaddr=192.168.1.1        serverip=192.168.1.254      loadaddr=0x46000000
bootconf=config-1
bootcmd=if pstore check ; then run boot_recovery ; else run boot_ubi ; fi
bootfile=...-initramfs-recovery.itb        bootfile_upg=...-squashfs-sysupgrade.itb
bootfile_fip=...-bl31-uboot.fip            bootfile_bl2=...-preloader.bin
bootled_pwr=blue:status   bootled_rec=red:status
bootdelay=0               bootmenu_delay=0
bootmenu_0=Initialize environment.=run _firstboot
bootmenu_0d=Run default boot command.=run boot_default
bootmenu_1..9 = TFTP/production/recovery/write-FIP/write-BL2/reboot/factory-reset
boot_first=if button reset ; then led $bootled_rec on ; run boot_tftp_recovery ; setenv flag_recover 1 ; run boot_default ; fi ; bootmenu
boot_default=if env exists flag_recover ; then else run bootcmd ; fi ; run boot_recovery ; setenv replacevol 1 ; run boot_tftp_forever
boot_ubi=run boot_production ; run boot_recovery ; run boot_tftp_forever
boot_production=led $bootled_pwr on ; run ubi_read_production && bootm $loadaddr#$bootconf ; led $bootled_pwr off
boot_recovery=led $bootled_rec on ; run ubi_read_recovery && bootm $loadaddr#$bootconf ; led $bootled_rec off
boot_tftp_production=tftpboot $loadaddr $bootfile_upg && env exists replacevol && iminfo $loadaddr && run ubi_write_production ; if env exists noboot ; then else bootm $loadaddr#$bootconf ; fi
boot_tftp_recovery=tftpboot $loadaddr $bootfile && env exists replacevol && iminfo $loadaddr && run ubi_write_recovery ; if env exists noboot ; then else bootm $loadaddr#$bootconf ; fi
boot_tftp_forever=led $bootled_rec on ; while true ; do run boot_tftp_recovery ; sleep 1 ; done
ubi_read_production=ubi read $loadaddr fit && iminfo $loadaddr && run ubi_prepare_rootfs
ubi_prepare_rootfs=if ubi check rootfs_data ; then else ... ubi create rootfs_data - dynamic ... ; fi
ubi_write_production=ubi check fit && ubi remove fit ; run ubi_remove_rootfs ; ubi create fit $filesize dynamic && ubi write $loadaddr fit $filesize
ubi_remove_rootfs=ubi check rootfs_data && ubi remove rootfs_data
mtd_write_fip=mtd erase fip && mtd write fip $loadaddr
mtd_write_bl2=mtd erase bl2 && mtd write bl2 $loadaddr
ubi_create_env=ubi check ubootenv || ubi create ubootenv 0x100000 dynamic || run ubi_format ; ubi check ubootenv2 || ubi create ubootenv2 0x100000 dynamic || run ubi_format
_firstboot=setenv _firstboot ; run ethaddr_factory ; run _switch_to_menu ; run _init_env ; run boot_first
_switch_to_menu=... setenv bootdelay 3 ; setenv bootmenu_delay 3 ; setenv bootmenu_0 $bootmenu_0d ; setenv bootmenu_0d ; ...
```

Config facts that matter:
- `CONFIG_ENV_IS_IN_UBI=y`, `ENV_UBI_VOLUME=ubootenv`, `ENV_UBI_VOLUME_REDUND=ubootenv2`
- `CONFIG_CMD_PSTORE=y`, `CMD_PSTORE_MEM_ADDR=0x42ff0000`, `MEM_SIZE=0x10000`, ECC size 0
- `AUTOBOOT_KEYED=y` with **empty** `AUTOBOOT_STOP_STR` → **keystrokes cannot interrupt autoboot**
- `CONFIG_AUTOBOOT_MENU_SHOW=y` → bootmenu is the autoboot UI; its delay comes from env

### Semantics you must not get wrong

1. **`mtd` numeric arguments are HEX** in this U-Boot (empirical: `10734` → written as `0x10734`).
   → always use `$filesize` (set by the preceding `tftpboot`).
2. Menu numbering **shifts by one after `_switch_to_menu`** (menu_1..9 → positions 2..a, plus `0. Exit`).
   After a normal `_firstboot`, the interactive menu shows: `0.Exit 1.Run default boot command 2.Boot via TFTP
   3.Boot production 4.Boot recovery 5.Load production via TFTP+write 6.Load recovery via TFTP+write
   7.Load BL31+U-Boot FIP via TFTP+write 8.Load BL2 via TFTP+write 9.Reboot a.Factory reset`.
3. **`boot_tftp_production` does NOT create the overlay** (it skips `ubi_prepare_rootfs`) →
   booting straight after it yields a read-only system (`hostname=(none)`, `passwd` fails, no `/overlay`).
   → always follow with `run boot_production` / a normal reboot.
4. `pstore check` in `bootcmd` **diverts to recovery whenever ramoops holds a crash record** →
   self-sustaining boot loop if the recovery image panics. Fix by rewriting `bootcmd`.
5. `boot_recovery`/`boot_tftp_recovery` need the `recovery` UBI volume OR the TFTP recovery file;
   with `replacevol` set they **write to NAND** (so a loop also wears flash).
6. `/dev/fit0` only appears when a UBI volume named **`fit`** exists (DTS `volname = "fit"` +
   `chosen/rootdisk`); kernel cmdline is `root=/dev/fit0 rootwait`.

---

## 4. PROVEN PROCEDURE A — migrate a foreign-bootloader unit (both units went through this)

Preconditions: CH340 serial at 115200 attached; PC wired NIC = `192.168.1.254/24`; Tftpd64 serving the
4 artifacts; cable in a **LAN** port.

```text
# 1. Load OUR U-Boot into RAM via BROM (works even with broken BL2/FIP)
mtk-uartboot-qt.exe -s COM7 -p mt7981-ram-ddr3-bl2.bin -a -f <...>-bl31-uboot.fip --debug
#    start the tool FIRST, then power the router. Success: [BROM] handshake done / 芯片ID: 0x7981
#    / send_da 100% / [BL2] handshake ok / [BL2] send_fip done / NOTICE: Received FIP

# 2. In the boot menu (3s) press a key -> 0. Exit   (get MT7981> prompt)

# 3. Recon
version
ubi part ubi
ubi info l          # note volume names + free PEBs
mtd list            # expect bl2 / orig-env / factory / fip / ubi

# 4. Free space (NEVER remove ubootenv/ubootenv2)
ubi remove kernel
ubi remove rootfs

# 5. Write OUR U-Boot into flash fip
tftpboot 0x46000000 <...>-bl31-uboot.fip          # expect Bytes transferred = 1073444 (106124 hex)
mtd erase fip
mtd write fip 0x46000000 0 $filesize
mtd read fip 0x47000000 0 $filesize
cmp.b 0x46000000 0x47000000 $filesize             # expect "Total of ... were the same"

# 6. Write firmware into the fit volume and boot
ubi part ubi
setenv replacevol 1
run boot_tftp_production                          # expects Bytes transferred = 33866011

# 7. Create/refresh overlay and boot normally
run boot_production
```

Then in Linux: `df -h | grep overlay` (expect `/dev/ubi0_1` → `/overlay`, ~62 MiB), `hostname` = ImmortalWrt,
`passwd`, enable UA2F in LuCI (Network → UA2F), then `reboot` and confirm autoboot works with keyboards untouched.

### Hardening (recommended once a unit is up)

```text
setenv flag_recover
setenv replacevol
setenv noboot
setenv bootcmd 'run boot_ubi'     # immune to stale pstore records
saveenv                           # if it fails with "Volume ubootenv2 not found": ubi create ubootenv2 0x100000 dynamic
mw.b 0x42ff0000 0 0x10000         # clear ramoops crash record
```
Also rename `...-initramfs-recovery.itb` in the TFTP root (e.g. append `.disabled`) so the fallback loop can
never boot the 29 MB initramfs (guaranteed OOM on 256 MiB RAM) and cannot rewrite NAND in a loop.

---

## 5. PROCEDURE B — normal reflash / upgrade of an already-migrated unit

- From Linux: LuCI → System → Backup/Flash firmware, feed `...-squashfs-sysupgrade.itb`
  (this target's sysupgrade writes the FIT to the `fit` volume via `CI_KERNPART` resolved from the DTS
  `chosen/rootdisk` volname — verified in `package/utils/fitblk/files/fit.sh`).
- Without Linux: boot menu `5` (TFTP load production + write NAND) then boot normally (`3`).
- **Never** put a FIT into a volume other than `fit`.

## 6. RECOVERY MATRIX

| situation | action |
|---|---|
| system boots | LuCI sysupgrade, or menu `5` + `3` |
| system won't boot, U-Boot alive | 3 s menu → `3`/`4` (boot from NAND) or `0.Exit` → console → fix |
| `fip` corrupted | `0.Exit` → `tftpboot ...bl31-uboot.fip` → `mtd erase fip` → `mtd write fip 0x46000000 0 $filesize` |
| BL2 + FIP both dead | **mtk_uartboot** (BROM) — Procedure A step 1 |
| whole flash layout wrong | Procedure A from step 4 |

Anti-pattern: **do not use the reset-button recovery path** on this board (29 MB initramfs → OOM loop, see §7).

---

## 7. DIAGNOSTIC DECISION TREES (exact strings from real logs)

### A. mtk_uartboot
| observed | meaning | action |
|---|---|---|
| `[BROM] handshake byte N: TX 0xa0 echo 0xa0 mismatch, reset` repeatedly | reading its own TX → **probe contact / shorted TX-RX** | reseat probes (esp. GND), remove loopback jumper |
| no `[BROM]` lines at all | tool not talking to BROM (timing/contact) | start tool first, then power; retry; check port not held by another app |
| `BootROM握手成功` then `send_da` stalls | serial link degraded | reseat; retry |
| BL2 reports EMI/DDR failure | wrong RAM BL2 variant | try `mt7981-ram-ddr4-bl2.bin` |

### B. TFTP stage
| observed | meaning | action |
|---|---|---|
| `TFTP error: 'File not found' (1)` | server root wrong | fix Tftpd64 `Current Directory`; self-test with `tftp -i 192.168.1.254 GET <name>` |
| no request reaches the server | PC NIC IP / firewall / LAN port | NIC = 192.168.1.254, firewall allow private+public, cable in lan1..3 |
| `Wrong Image Type for bootm command` / `ERROR -91` | consequence of the failed fetch (script still calls `bootm`) | harmless, ignore |

### C. Boot stage
| observed | meaning | action |
|---|---|---|
| `Waiting for root device /dev/fit0...` then reboot loop | FIT lives in the wrong UBI volume (`kernel`) | create/populate `fit` (run `boot_tftp_production`) |
| `shmem:97564kB` … `Kernel panic - not syncing: System is deadlocked on memory` | 29 MB initramfs + 256 MiB RAM, no overlay space | do not boot the recovery initramfs; flash to NAND instead |
| `hostname=(none)`, `passwd: Read-only file system`, no `/overlay` | booted right after `boot_tftp_production` (no `ubi_prepare_rootfs`) | `run boot_production` or reboot |
| boot keeps TFTP-ing recovery + `Creating dynamic volume recovery` | stale pstore → `bootcmd` diverts; `replacevol` set | `setenv bootcmd 'run boot_ubi'`, `saveenv`, `mw.b 0x42ff0000 0 0x10000` |
| `Saving Environment to UBI... Volume ubootenv2 not found! Failed (1)` | redundant env volume missing | `ubi create ubootenv2 0x100000 dynamic` then `saveenv` |
| menu reappears / never boots | stray keystrokes from terminal, or `flag_recover` set | detach terminal or stop touching keys; `setenv flag_recover; saveenv` |
| system fine but `http://192.168.1.1` unreachable | **cable in WAN port** (br-lan = lan1..3) | move cable; verify `ip neigh show` / `cat /tmp/dhcp.leases` from console |

Useful in-system checks: `df -h`, `mount | grep overlay`, `ubinfo -a`, `ip -4 addr show br-lan`,
`ps | grep uhttpd`, `netstat -ltnp | grep :80`, `logread | tail -20`.

---

## 8. UA2F (the actual purpose of the build)

- Packages in image: `ua2f 4.10.2-r1`, `luci-app-ua2f` (official JS version from `immortalwrt/luci`),
  `luci-i18n-ua2f-zh-cn`.
- LuCI page: **Network → UA2F** (`admin/network/ua2f`).
- Shipped `/etc/config/ua2f` defaults: `enabled=0` (must be enabled), `handle_fw=1`,
  `handle_tls=0`, `handle_intranet=1`, `custom_ua=''`, `disable_connmark='0'`.
- Compiled-in UA (used when `custom_ua` is empty) = `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36
  (KHTML, like Gecko) Chrome/112.0.0.0 Safari/537.36 Edg/112.0.1722.68` (verified with `strings /usr/bin/ua2f`).
- Runtime verification: `/etc/init.d/ua2f status`, `nft list table inet ua2f`
  (expect postrouting chain, `queue num 10010`, `ct mark set 44` for tcp/80).
- Kernel deps present: `kmod-nft-queue`, `kmod-nfnetlink-queue`, `nftables-json`, `libnetfilter-queue1`.

### Build-tree note (package override trap)

`package/luci-app-ua2f/` (user's AGPL fork, Lua/CBI) is **NOT** the package that ships.
`include/scan.awk` filters out core packages that a feed also provides (feature:
"allow openwrt.git packages to be replaced by feeds"), so `feeds/luci/luci-app-ua2f` (official JS) wins.
Verified via `tmp/.packagedeps` and `make package/luci-app-ua2f/clean` entering
`feeds/luci/applications/luci-app-ua2f`. To build the fork instead: `./scripts/feeds uninstall luci-app-ua2f`.

---

## 9. BUILD ENVIRONMENT (on the VPS, `/root/immortalwrt-mt798x-rebase`)

```yaml
repo: ImmortalWrt rebase (MTK mt798x), branch 25.12, remote chasey-dev via ghproxy
tree_state: HEAD == origin/25.12; only local edit = scripts/download.pl (ghproxy rewrite, now https?)
build_cmd: export FORCE_UNSAFE_CONFIGURE=1 && make -j$(nproc) V=s   # root build: GNU tar configure refuses otherwise
config: .config = mediatek/filogic/jcg_q30-pro + 380 packages; target device jcg_q30-pro only
feeds: feeds.conf (untracked, gitignored) points all 5 feeds at https://cf.liuass.eu.org/ghproxy/https://github.com/...
artifacts: bin/targets/mediatek/filogic/ (+ sha256sums, profiles.json, .manifest)
rescue_dir: bin/tftp-stage/  (artifact hardlinks under candidate names, SHA256SUMS.txt, docs)
cache: dl/ (~1.7 GB) warm; full build ~1–3 h, ~19 GB disk
```

Rebuild knobs discussed but NOT yet done:
1. **slim recovery image** (~8–10 MB) to make the reset/TFTP recovery path usable on 256 MiB RAM.
2. **TTL rule baked into the image** (`files/` + `iptables`/`nft ip ttl set 64`) against Dr.Com-style
   UA+TTL detection.

---

## 10. ANTI-PATTERNS / DO-NOT LIST

- Do not flash our `sysupgrade.itb` through a foreign/vendor or hanwckf Web-failsafe page
  (`Something went wrong during update … chosen wrong file`) — it accepts only its own layout.
- Do not put the FIT in `kernel`/`rootfs` volumes; `fit` is mandatory.
- Do not delete `ubootenv`/`ubootenv2`.
- Do not type numeric sizes into U-Boot `mtd` (hex!); use `$filesize`.
- Do not power off while `mtd erase/write` or `ubi write` is running.
- Do not boot the 29 MB recovery initramfs on this board (guaranteed OOM loop).
- Do not rely on keystroke interruption of autoboot (`bootstopkey` empty); use the 3 s menu or mtk_uartboot.
- Do not insert the WAN port for TFTP/flashing; U-Boot works on any port, Linux only on lan1..3 — the
  mismatch produces a very convincing "everything is fine but no web UI" symptom.
- Treat any "impossible" serial behaviour (no echo, keys lost, `0xa0 mismatch`) as **physical contact first**.

## 11. VERIFICATION CHECKLIST (per unit)

```text
U-Boot (from 3s menu -> 0.Exit, or `version` right after reboot):
  version                -> U-Boot 2025.10-ImmortalWrt-r38026-5e20cf34aa
  printenv bootcmd       -> run boot_ubi                (= hardened)
  ubi info l             -> fit / rootfs_data / ubootenv / ubootenv2
Linux:
  cat /etc/openwrt_release   -> ImmortalWrt 25.12-SNAPSHOT r38026-5e20cf34aa
  hostname / df -h | grep overlay / mount | grep overlay
  lsmod | grep -E 'hnat|mt_wifi'      (HNAT + MTK wifi driver loaded)
  /etc/init.d/ua2f status ; nft list table inet ua2f
Reboot test: power-cycle, do not touch keys, expect autoboot into the system in ~20 s.
```

Status at time of writing: **unit 1 and unit 2 both PASS** (overlay mounted ~62 MiB, Web UI reachable,
password set). Remaining optional work: slim recovery image, TTL rule.
