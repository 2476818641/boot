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
| `immortalwrt-mediatek-filogic-jcg_q30-pro-initramfs-recovery.itb` | 9437184 (9.0 MB) | `33bcb1f709fcc27599bb69b49a802288a61750973117f7e28ef0b87572ed3553` |
| `recovery-slim.itb` (same bytes as the row above; exported to `recovery-slim-out/`) | 9437184 | `33bcb1f7…` |
| *stock* (unslimmed) recovery — what the file is called **before** the slim pass, **never boot it on this board** | 29360128 | `569936a52dfc54eb7194fbe0d145808fe3ecc40cbfffc167dc48b48c7a88f8ee` |
| `immortalwrt-mediatek-filogic-jcg_q30-pro-bl31-uboot.fip` | 1073444 | `f06f684fe85b6ec1279c55b042f9143d40bbd848f3005b8af7562f6ddb4f9de3` |
| `immortalwrt-mediatek-filogic-jcg_q30-pro-preloader.bin` | 230232 | `bf9724f7eb8c0ddddf1f8fc9d6c104d892c09621125ada137ca6b7447543cc7d` |
| `mt7981-ram-ddr3-bl2.bin` (for mtk_uartboot) | 210368 | `9e5431cce4ec06afde6bf216c8d31fdfa1b8ef3443aa6c86523ad22a1a12b059` |

**Hash stability:** `fip` / `preloader` / RAM-BL2 embed a build timestamp
(`strings mt7981-ram-ddr3-bl2.bin | grep Built` → `Built : 08:30:16, Sep 19 2026`), so their sha256 changes
on every rebuild while the size stays the same. Treat the hashes above as "this build", and trust the
per-build `sha256sums` / `recovery-slim-out/sha256sums` instead. (A RAM BL2 circulated earlier with
`bdb2493e…` — same size, earlier build; it is never written to NAND, so either loads fine.)

Version string: `ImmortalWrt 25.12-SNAPSHOT r38026-5e20cf34aa`, kernel `6.12.87`.
U-Boot banner: `U-Boot 2025.10-ImmortalWrt-r38026-5e20cf34aa (May 25 2026 - 10:39:51 +0000)`.

**Critical distinction:** `preloader.bin` (230232, NAND BL2) is **NOT** interchangeable with
`mt7981-ram-ddr3-bl2.bin` (210368, RAM BL2). mtk_uartboot takes the *RAM* one.

**The default build emits the slim recovery** (§10b): `scripts/build-recovery-slim.sh` (and therefore the
GitHub Actions workflow) rebuilds the recovery with the 44-entry keep list and drops the 9.0 MB result under
the canonical `...-initramfs-recovery.itb` name. Ship that, not the 29 MB one.

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
`passwd`, enable UA-Mask in LuCI (Services → UA MASK), then `reboot` and confirm autoboot works with keyboards untouched.

### Hardening (recommended once a unit is up)

```text
setenv flag_recover
setenv replacevol
setenv noboot
setenv bootcmd 'run boot_ubi'     # immune to stale pstore records
saveenv                           # if it fails with "Volume ubootenv2 not found": ubi create ubootenv2 0x100000 dynamic
mw.b 0x42ff0000 0 0x10000         # clear ramoops crash record
```
Also make sure the TFTP root holds the **slim** `...-initramfs-recovery.itb` (9.0 MB — the default build
product), so the reset-button / `boot_tftp_forever` fallback converges instead of OOM-looping. If all you have
is a stock 29 MB recovery image, rename it in the TFTP root (e.g. append `.disabled`): the fallback loop then
fails cleanly (no OOM panic, no repeated `ubi write`) instead of rewriting NAND forever.

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

Anti-pattern: **do not boot the stock 29 MB recovery image** on this board (29 MB initramfs expands to
~95 MB → guaranteed OOM loop, see §7). Use the **slim recovery** instead — it is what the default build
produces (`bash scripts/build-recovery-slim.sh`): 9.0 MB artifact, 20.5 MB unpacked, sha256 `33bcb1f7…`.
That makes the reset+TFTP recovery path viable (statically verified; on-device run still pending).

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
| `shmem:97564kB` … `Kernel panic - not syncing: System is deadlocked on memory` | **stock** 29 MB initramfs + 256 MiB RAM | use the slim recovery (9.0 MB, default build product); flashing to NAND also avoids initramfs entirely |
| `hostname=(none)`, `passwd: Read-only file system`, no `/overlay` | booted right after `boot_tftp_production` (no `ubi_prepare_rootfs`) | `run boot_production` or reboot |
| boot keeps TFTP-ing recovery + `Creating dynamic volume recovery` | stale pstore → `bootcmd` diverts; `replacevol` set | `setenv bootcmd 'run boot_ubi'`, `saveenv`, `mw.b 0x42ff0000 0 0x10000` |
| `Saving Environment to UBI... Volume ubootenv2 not found! Failed (1)` | redundant env volume missing | `ubi create ubootenv2 0x100000 dynamic` then `saveenv` |
| menu reappears / never boots | stray keystrokes from terminal, or `flag_recover` set | detach terminal or stop touching keys; `setenv flag_recover; saveenv` |
| system fine but `http://192.168.1.1` unreachable | **cable in WAN port** (br-lan = lan1..3) | move cable; verify `ip neigh show` / `cat /tmp/dhcp.leases` from console |

Useful in-system checks: `df -h`, `mount | grep overlay`, `ubinfo -a`, `ip -4 addr show br-lan`,
`ps | grep uhttpd`, `netstat -ltnp | grep :80`, `logread | tail -20`.

---

## 8. UA-Mask (the actual purpose of the build)

Replaced UA3F with **UA-Mask** (2026-09-22). Both are REDIRECT transparent proxies for rewriting the
HTTP `User-Agent`, but UA3F hijacks **all TCP except port 22**
(`tcp dport != {22} redirect to :1080`) into a user-space Go process, which broke real clients; UA-Mask
defaults to bypassing 22 **and 443**, lets you extend that bypass list, and — the reason for the switch —
can **offload non-HTTP destinations into an nftables set** so that traffic (game accelerators, Steam,
P2P) stops entering user space entirely. See `package/UA-Mask/LOCAL-NOTES.md` for the full rationale.

| item | value |
|---|---|
| upstream | [Zesuy/UA-Mask](https://github.com/Zesuy/UA-Mask) 0.4.3, GPL-3.0-only, Go |
| upstream commit | `83846d3780b1e30f87816310ae75d95798a5bd4d` (2026-08-02) |
| in this tree | vendored at `package/UA-Mask/` (`Makefile` at the package root, Go sources in `core/`, OpenWrt assets in `openwrt/`) |
| package symbol | `CONFIG_PACKAGE_uamask` (**lowercase**, unlike upstream's `UAmask`) |
| fixed names | the binary must be `/usr/bin/UAmask` and the UCI file `/etc/config/UAmask` — the init script (`NAME=UAmask`, `PROG=/usr/bin/$NAME`) and the LuCI CBI page hardcode them. Only the *package* name is lowercased. |
| deps | `$(GO_ARCH_DEPENDS) +libubox +luci-compat` (`libubox` → `jshn.sh`; `luci-compat` → the Lua/CBI page) |
| conflicts | `ua3f ua3f-tproxy ua3f-tproxy-ipt` → Kconfig `depends on m || (PACKAGE_ua3f != y)` |
| LuCI | ships its own page inside the package: **Services → UA MASK** (Lua/CBI) |
| build target | `make package/UA-Mask/compile` — **the directory path, not the package name** |

UCI schema (`/etc/config/UAmask`, shipped `enabled=0`; the init script renders these into
`/var/run/UAmask/config.json` via `jshn` and validates with `UAmask -check-config`):

```text
UAmask.enabled.enabled        0          # must be enabled
UAmask.main.port              12032
UAmask.main.ua                FFF        # replacement UA string
UAmask.main.match_mode        keywords   # keywords | regex
UAmask.main.keywords          iPhone,iPad,Android,Macintosh,Windows
UAmask.main.ua_regex          (iPhone|iPad|Android|Macintosh|Windows|Linux|Apple|Mac OS X|Mobile)
UAmask.main.replace_method    full       # full | partial
UAmask.main.whitelist         ''         # UA keywords never rewritten
UAmask.main.iface             br-lan
UAmask.main.bypass_ports      '22 443'   # != semantics: listed ports are NOT proxied
UAmask.main.bypass_ips        private ranges
UAmask.main.proxy_host        0          # also proxy the router's own output
UAmask.main.enable_firewall_set  1       # ← we changed the upstream default (was 0)
UAmask.main.Firewall_ua_bypass   1       # ← we changed the upstream default (was 0); non-HTTP offload
UAmask.main.Firewall_ua_whitelist ''     # (capital F — LuCI quirk)
UAmask.main.Firewall_drop_on_match 0
UAmask.main.operating_profile Medium  / cache_size 2000 / buffer_size 8192 / gogc_value 100
UAmask.main.log_level info / log_file /tmp/UAmask/UAmask.log
```

The two `1`s are local deviations: with them off, the whole "traffic offload" feature is inert and the
accelerator problem comes straight back.

Runtime checks: `/etc/init.d/UAmask status`, `pgrep -a UAmask`,
`nft list table inet fw4 | grep -i uamask`, `nft list set inet fw4 UAmask_bypass_set`
(learned `ip . port` pairs that no longer enter the proxy), `logread -e UAmask`.

Notes / gotchas:
- The firewall rules live **inside `table inet fw4`** as an fw4 include (`uci firewall.UAmask.path=/tmp/UAmask_rules.nft`),
  not in a private table, and `stop_service()` deletes the chains/set and runs `fw4 reload`. UA3F had no
  `stop_service`, so stopping it left `tcp dport != {22} redirect to :1080` behind → **all TCP blackholed
  while ICMP still worked** ("停掉 UA3F 电脑无网"). Never reintroduce that pattern.
- Offload mechanism: `nft add set inet fw4 UAmask_bypass_set { type ipv4_addr . inet_service ; timeout 10m ;}`
  plus `ip daddr . tcp dport @UAmask_bypass_set return` placed **before** the redirect in
  `UAmask_prerouting_before` / `UAmask_output_after`.
- **No L3 rewriting at all**: no TTL/IPID/TCP-timestamp/TCP-window/QUIC-block/Desync/MitM. That is a
  feature, not a gap: `block_quic` drops all UDP/443 and the Desync options shuffle TCP, both of which
  kill accelerators and QUIC. **TTL spoofing is the kernel nft rule's job**
  ([Login-edu](https://github.com/2476818641/Login-edu) → `/etc/nftables.d/10-ttl-fix.nft`).
- HNAT / flow offload can bypass user-space rewriting — same caveat as with UA2F/UA3F.
- Go toolchain: `golang/host` (feed `packages/lang/golang`, Go 1.26) already built; modules must exist in
  `dl/go-mod-cache` (see §10e).
- Upstream commits a 6.5 MB **x86-64 prebuilt binary at `core/UAmask`** — deliberately not vendored, and
  `scripts/check-vendored-inputs.sh` now fails if it reappears.

## 9. BUILD ENVIRONMENT (on the VPS, `/root/immortalwrt-mt798x-rebase`)

```yaml
repo: ImmortalWrt rebase (MTK mt798x), branch 25.12, remote chasey-dev via ghproxy
tree_state: HEAD == origin/25.12; only local edit = scripts/download.pl (ghproxy rewrite, now https?)
build_cmd: export FORCE_UNSAFE_CONFIGURE=1 && export GOPROXY=https://goproxy.cn,direct && make -j$(nproc) V=s
           # FORCE_UNSAFE_CONFIGURE: root build, GNU tar configure refuses otherwise
           # GOPROXY: UA-Mask is a Go package; proxy.golang.org is unreachable from this host, goproxy.cn works
           # but for UA-Mask the modules are already populated into dl/go-mod-cache, so the build is offline (see §10e)
           # Go toolchain itself is already in dl/ (go1.26.3.src.tar.gz, hash matches the feed) → no extra download
config: .config = mediatek/filogic/jcg_q30-pro + 378 packages; target device jcg_q30-pro only
feeds: feeds.conf (untracked, gitignored) points all 5 feeds at https://cf.liuass.eu.org/ghproxy/https://github.com/...
artifacts: bin/targets/mediatek/filogic/ (+ sha256sums, profiles.json, .manifest)
rescue_dir: bin/tftp-stage/  (artifact hardlinks under candidate names, SHA256SUMS.txt, docs)
cache: dl/ (~1.7 GB) warm; full build ~1–3 h, ~19 GB disk

Kernel-state trap (hit 2026-09-20): kmod `KCONFIG` symbols are merged into the kernel config **only
during the kernel build** (`include/kernel-defaults.mk:120-121` -> `package-metadata.pl kconfig` ->
`.config.override`), and `$(STAMP_CONFIGURED)` is refreshed solely when `target/linux/compile` runs.
Therefore, right after switching `.config` (production <-> slim recovery, or ua3f -> uamask):

- `make -j$(nproc)` (world) OK: reconfigures the kernel and rebuilds the modules
- `make package/<something>/compile` FAILS: it does not enter `target/linux/compile`, so kmod packaging
  runs against a stale kernel config and dies with e.g.
  `ERROR: module '.../arch/arm64/crypto/sha512-arm64.ko' is missing.` -> `package/kernel/linux failed to build`
  (exactly what happened when validating UA3F in 2026-09; same trap applies to any kmod switch: the previous slim pass had left
  `# CONFIG_CRYPTO_SHA512_ARM64 is not set`, while `CONFIG_PACKAGE_kmod-crypto-sha512=y` was back on)

Safe fast path after a config switch: run `make target/linux/compile -j$(nproc)` first (refreshes the
kernel config + builds every module), then `make package/<something>/compile`.
Sanity check: `grep CONFIG_CRYPTO_SHA512_ARM64 build_dir/target-*/linux-*/linux-*/.config` (expect `=m`
in the production config).
```

Rebuild knobs discussed but NOT yet done:
1. **TTL rule baked into the image** (`files/` + `iptables`/`nft ip ttl set 64`) against Dr.Com-style
   UA+TTL detection.

---

## 10. ANTI-PATTERNS / DO-NOT LIST

- Do not flash our `sysupgrade.itb` through a foreign/vendor or hanwckf Web-failsafe page
  (`Something went wrong during update … chosen wrong file`) — it accepts only its own layout.
- Do not put the FIT in `kernel`/`rootfs` volumes; `fit` is mandatory.
- Do not delete `ubootenv`/`ubootenv2`.
- Do not type numeric sizes into U-Boot `mtd` (hex!); use `$filesize`.
- Do not power off while `mtd erase/write` or `ubi write` is running.
- Do not boot the stock 29 MB recovery initramfs on this board (guaranteed OOM loop) — the default build
  already replaces it with the 9.0 MB slim one.
- Do not rely on keystroke interruption of autoboot (`bootstopkey` empty); use the 3 s menu or mtk_uartboot.
- Do not insert the WAN port for TFTP/flashing; U-Boot works on any port, Linux only on lan1..3 — the
  mismatch produces a very convincing "everything is fine but no web UI" symptom.
- Treat any "impossible" serial behaviour (no echo, keys lost, `0xa0 mismatch`) as **physical contact first**.

## 10b. SLIM RECOVERY IMAGE (29 MB → 9.0 MB) — **part of the default build**

Built and statically verified 2026-09-19; **runtime (on-device) validation still pending**.

```bash
bash scripts/build-recovery-slim.sh              # default: production build, then slim recovery pass, then assemble
bash scripts/build-recovery-slim.sh --slim-only  # only redo the slim recovery (production artifacts already present; used by CI)
make -j"$(nproc)"                                # for humans this is equivalent: the repo's default path ends in the same artifact set
```

| metric | stock recovery | slim recovery |
|---|---|---|
| `.itb` size | 29,360,128 B | **9,437,184 B (9.0 MB)** |
| kernel (lzma) | 6.0 MB | 4.33 MB |
| initrd (XZ) | 24.7 MB | **4.61 MB** |
| **unpacked (= RAM cost)** | **~95 MB → OOM** | **20.5 MB** |
| packages | 352 | 117 |
| FIT config name | `config-1` | `config-1` (compatible with `bootm $loadaddr#config-1`) |

Mechanism: the `-recovery.itb` shares the production package set, so the script temporarily swaps `.config`
with the 44-entry keep list (`scripts/recovery-slim-packages.txt`), runs `make` (world — note: **this tree has no
`image` target**), then restores `.config` via a `trap` (fires on failure/Ctrl-C too). No source-tree patches.
In default mode it backs up the production artifacts first, re-copies them over the slim build's output, then
puts the slim `...-initramfs-recovery.itb` back under its canonical name and regenerates `sha256sums`;
the final set lands in `recovery-slim-out/`.

Keep-list must include the **boot artifact packages** or the image build fails immediately:
`trusted-firmware-a-mt7981-spim-nand-ddr3` (→ `preloader.bin`), `u-boot-mt7981_jcg_q30-pro` (→ `bl31-uboot.fip`).

Verify on device: boot it via TFTP (boot menu `2. Boot system via TFTP` = `tftpboot $bootfile && bootm`),
then `free -m` (expect ≥150 MB free), `ubinfo -a`, `mtd -h`, `sysupgrade -h`, and a LuCI sysupgrade round-trip.
Only after that may the docs change from "statically verified" to "on-device verified".

## 10c. ⚠️ `scripts/feeds update` SILENTLY WIPES YOUR PACKAGE SELECTION (ua2f was lost this way)

**Root cause (confirmed 2026-09-19, Actions run #2):**

`./scripts/feeds update -a` finishes by calling `refresh_config()` (in `scripts/feeds`, tail of `sub update`),
which runs **`make defconfig` on the existing `.config`**. On a fresh checkout `package/feeds/` does not exist
yet (it is `.gitignore`d), so that defconfig only sees in-tree packages and **silently deletes every
`CONFIG_PACKAGE_<feed-package>=y` line**: 380 → **292**. `./scripts/feeds install -a` then populates
`package/feeds/`, but the selection is already gone; the workflow's own `make defconfig` afterwards can only
re-add defaults (→ **334**), never the user's picks. `refresh_config()` is invisible — it swallows output
(`>/dev/null 2>&1`) and only touches `.config`.

Timeline of the two cloud runs:

| | run #1 (`2cbe18ff`, release `build-20260919-0910`) | run #2 (`9e84508b`, guard added) |
|---|---|---|
| `.config` before feeds step | 380 packages (`ua2f=y`, `luci-app-passwall=y` — verified via raw.githubusercontent) | 380 |
| after `feeds update -a` | **292** (silent, nothing logged) | **292** (guard now prints it) |
| after workflow `make defconfig` | 334 | 334 |
| shipped image | **299 packages, no `ua2f` / `luci-app-ua2f` / `luci-app-passwall` / `mwan3` / `smartdns` / `luci-theme-argon`**, sysupgrade 19.0 MB vs 33.9 MB locally | **build failed** (`❌ 缺失: ua2f …`) ✅ |

Guard output that exposed it:
`选中包数：期望 292 -> 实际 334` + `❌ 缺失: ua2f, luci-app-ua2f, luci-theme-argon, luci-app-passwall, mwan3, smartdns`.

Local confirmation of the intermediate number: `make defconfig` in a tree **without** `package/feeds`
(= exactly the state `feeds update` defconfigs in) keeps **292** packages — same figure.

**Fix applied in `.github/workflows/build.yml`:**

```yaml
cp -f .config .config.committed      # before feeds
./scripts/feeds update -a
./scripts/feeds install -a
cmp -s .config .config.committed || cp -f .config.committed .config   # undo the silent rewrite
make defconfig
bash scripts/check-package-selection.sh --config .config.committed .config
```

**Verified end-to-end by Actions run #3 (`44b71204`, 2026-09-19), actual log lines:**

```text
[step 7] ##[warning]scripts/feeds 改写了 .config（内部 refresh_config 跑了 defconfig）
         改写前选中包数: 380
         改写后选中包数: 292          <- matches the prediction exactly
[step 9] 选中包数：期望 380 -> 实际 381
         ✅ 全部存在（15 项）
[step 12] 精简构建：选中包数 121
release build-20260919-1049:
   production manifest 353 packages  (broken run #1: 299)
   ua2f / luci-app-ua2f / luci-app-passwall / mwan3 / smartdns / luci-theme-argon / kmod-mt_wifi ... all present
   sysupgrade 33,796,372 B  (run #1: 19,005,716 B)
   recovery 9,437,184 B (= slim, 117 packages, mtd / ubi-utils / fitblk / kmod-mtd-rw / uboot-envtools present,
   kmod-mt_wifi and ua2f correctly absent)
```

`build-20260919-0910` (run #1) is a **broken release — do not flash it**: the firmware has no `ua2f`.

**CI vs local artifact hashes:** the kernel/U-Boot/BL2 embed build timestamps, so CI-built `.itb`/`.fip`/`.bin`
hashes never match the locally built ones (same byte sizes, different sha256). Always compare against the
`sha256sums` of the release you downloaded, never against the numbers in the README.

Rules for anything that touches the build:
- **Never let `scripts/feeds update` run on a `.config` you care about** without a backup/restore around it
  (same for `./scripts/feeds uninstall`, which also calls `refresh_config()`).
- After a cloud build, verify the produced `*.manifest`: `grep '^ua2f ' *.manifest`
  or `bash scripts/check-package-selection.sh --manifest <file>`.
- Local builds are unaffected as long as packages were installed from feeds **before** `.config` was edited
  (the user's own tree is in that state), but a fresh clone + `feeds update -a` will eat the config.

---

## 10d. ⚠️ CI run #5 FAILURE (2026-09-20, UA3F era — kept as a lesson): a `.gitignore`d build input exists only on your machine

**Symptom (Actions run #5, `8326fd0a`):** the `编译` step reported **success**, the job then died in
`校验产物` with a manifest of **117 packages** (the slim recovery count) instead of ~350, and
`❌ 缺失: ua3f` plus 9 other packages. The real build error was nowhere in `build.log`.

**Two independent bugs, one masking the other:**

1. **Root cause — 4 eBPF object files were never committed.**
   `make -r world` had actually failed, at `make[3] -C package/UA3F/openwrt compile`, after ~3 seconds:

   ```text
    make[3] -C package/UA3F/openwrt compile
       ERROR: package/UA3F/openwrt failed to build.
   make -r world: build failed. Please re-run make with -j1 V=s or V=sc for a higher verbosity level
   ```

   (UA3F-era) UA3F embeds eBPF objects with `//go:embed tc_bpfeb.o` (upstream commits them; they are **build inputs**,
   not leftovers). The repo root `.gitignore` line 1 is `*.o`, so a plain `git add` silently skipped them:
   `git ls-tree -r HEAD package/UA3F | grep -c '\.o$'` → **0**, while the local tree had 285 files vs 281 tracked.
   Proof of mechanism (reproduced locally with the vendored source, no OpenWrt build needed):

   ```text
   $ find . -name '*.o' -delete        # = what CI's clean checkout has
   $ staging_dir/hostpkg/bin/go1.26 build ./...
   internal/bpf/sockmap/sockmap_bpfel.go:138:12: pattern sockmap_bpfel.o: no matching files found
   internal/bpf/tc/tc_bpfel.go:142:12: pattern tc_bpfel.o: no matching files found
   $ cp <the 4 .o back> && go build ./internal/bpf/...   → exit 0
   ```

   This class of bug **cannot** be found by building locally: the files are present on the machine that
   has ever copied the vendored tree, and absent in every clean clone. CI-only, always.

2. **Masking bug — `make ... | tee build.log` returns tee's exit code (0).**
   The workflow's compile step therefore never failed; the pipeline went on to the slim pass. At that point
   `bin/targets/.../` had **no** `*-squashfs-sysupgrade.itb` at all, and `build-recovery-slim.sh --slim-only`
   only *warned* about it (`没找到 ... 跳过正式产物合理性检查`) — so the slim pass then produced an 11 MB
   sysupgrade from the **44-package slim config**, which was collected and would have been released as the
   "production" firmware. Only the package-count check at the end caught it.

**Fixes applied:**

```text
# (UA3F-era; UA3F is gone, the guard script now covers package/UA-Mask)
git add -f package/UA3F/internal/bpf/tc/tc_bpfeb.o tc_bpfel.o \
           package/UA3F/internal/bpf/sockmap/sockmap_bpfeb.o sockmap_bpfel.o
scripts/check-vendored-inputs.sh          # NEW: verifies each build input exists AND is tracked by git;
                                          #      runs as CI step 2 (fails in ~1 s, not after an hour)
.github/workflows/build.yml:
  set -o pipefail                         # on 应用 .config / 编译 / 精简 recovery steps
  编译 step on failure: make -j1 V=s 2>&1 | tail -120 | tee -a build.log ; exit 1
                                          # parallel builds print only "ERROR: package/x failed to build."
                                          # incremental, so this is cheap and yields the real error
scripts/build-recovery-slim.sh:
  check_production_size(): missing production sysupgrade is now a HARD failure
  (unless FORCE_SLIM_OK=1) instead of a warning
```

**Rules for anything that touches the build (append to the §10 list):**
- Any file the build *reads* must be tracked by git, not merely present on disk. Vendored trees with
  binary artifacts (`.o`, `.a`, `.syso`, `vendor/`) are the usual victims of a broad `.gitignore`.
  Run `bash scripts/check-vendored-inputs.sh` before pushing; compare
  `git ls-files <dir> | wc -l` against `find <dir> -type f | wc -l`.
- Never pipe `make` through `tee` without `set -o pipefail` — the failure disappears and you ship a
  wrong artifact with a green checkmark.
- When a step "succeeds" but a later step reports a suspiciously small manifest, check the *number of
  entries* first: 117 = slim recovery, ~350 = production. That single number localizes the failure fast.

---

## 10e. UA3F -> UA-Mask switch (2026-09-22): why, and five traps

**Why we left UA3F.** Not a rewrite-quality problem — an interception-scope problem. Conntrack on the
live router showed the accelerator (奇游) using UDP `43.139.213.13:9993/9995/9997` (which worked: replies
came back, so the client reached "connected") plus a **TCP tunnel to the same host on a high port** — and
the TCP half is exactly what UA3F's `tcp dport != {22} redirect to :1080` pulls into its user-space proxy.
Symptom: connected but node latency never measured / earlier `-08`. Node IPs rotate, so IP allow-listing
is not a fix; the interception scope itself had to change. A second UA3F defect surfaced during
diagnosis: it has no `stop_service`, so after `stop` the redirect rule persists and **all TCP is
blackholed while ping still works** (that is why "停掉 ua3f 电脑无网" while `ping -f -l 1472` was 100% clean).
UA-Mask fixes both by design (configurable bypass + offload to an nft set + clean teardown).

**Trap 1 — `include/scan.awk` dedupes packages by the *last* path component.**
`PKGS[$NF]=$0` means two package directories whose basename collides (e.g. `package/UA3F/openwrt` and
`package/UA-Mask/openwrt` — both `openwrt`) silently overwrite each other in `tmp/.packagedeps`.
The loser disappears from `tmp/.packageinfo`, `make defconfig` then **deletes its `CONFIG_PACKAGE_x=y`
line without any error**, and `make package/<name>/compile` says `No rule to make target`.
Diagnosis: `grep -c '^Package: uamask$' tmp/.packageinfo`. Fix: give the package directory a unique
name (`package/UA-Mask/Makefile`, not `.../openwrt/Makefile`). Also note a **two-pass effect**: after
adding a directory, the first `make defconfig` only refreshes the file list; the per-directory DUMP file
(`tmp/info/.packageinfo-<dir>`) appears on the next run.

**Trap 2 — `make defconfig` deletes `=y` for symbols it cannot see.** If you write
`CONFIG_PACKAGE_uamask=y` before the package is registered (see trap 1), defconfig rewrites the line to
`# CONFIG_PACKAGE_uamask is not set` and the next runs happily keep it disabled. Always re-check with
`grep -n CONFIG_PACKAGE_uamask .config` after registering a new package.

**Trap 3 — Go modules must be pre-populated into `dl/go-mod-cache`.** The build sets
`GOMODCACHE=$(DL_DIR)/go-mod-cache`, `GOENV=off`, `GOTOOLCHAIN=local` and does **not** set `GOPROXY`, so
any module missing from that cache makes Go reach for `proxy.golang.org` — which fails on this host with
`tls: failed to verify certificate: x509: certificate has expired` (the network's TLS-interception cert
expired 2026-09-19). Populate the shared cache with the *same* layout before building:

```sh
cd package/UA-Mask/core
GOMODCACHE=$TOPDIR/dl/go-mod-cache GOCACHE=/tmp/gocache GOENV=off GOTOOLCHAIN=local \
  GOFLAGS=-modcacherw GOSUMDB=off GOPROXY=http://goproxy.cn,direct go mod download
# UA-Mask needs: logrus v1.9.3, golang.org/x/sys v0.30.0, hashicorp/golang-lru/v2 v2.0.7,
#                gopkg.in/natefinch/lumberjack.v2 v2.2.1 (dlark/regexp2 v1.11.5 was already there)
```

Verify offline before touching the buildroot: `GOPROXY=off go build -o /tmp/UAmask ./cmd/UAmask`.

**Trap 4 — package build targets are directory paths, not package names.**
`make package/UA-Mask/compile` works; `make package/uamask/compile` fails with `No rule to make target`.
(`tmp/.packagedeps` line: `package-$(CONFIG_PACKAGE_uamask) += UA-Mask`.)

**Trap 5 — the `.ipk` from upstream releases cannot be installed here.** ImmortalWrt 25.12 uses **apk**;
upstream publishes opkg `.ipk`. Always build from the vendored source in-tree.

**Offline self-tests for the vendored package (no OpenWrt build needed, ~20 s):**

```sh
sh package/UA-Mask/openwrt/tests/config-generation-test.sh   # 5 assertions: UCI -> config.json
sh package/UA-Mask/openwrt/tests/procd-contract-test.sh      # start_service contract
```
Both pass with the local defaults (they build the Go binary themselves — export `GOMODCACHE`/`GOPROXY=off`
as in trap 3 if the host has no network).

---

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
  /etc/init.d/UAmask status ; nft list table inet fw4 | grep -i uamask ; pgrep -a UAmask
Reboot test: power-cycle, do not touch keys, expect autoboot into the system in ~20 s.
```

Status at time of writing: **unit 1 and unit 2 both PASS** (overlay mounted ~62 MiB, Web UI reachable,
password set). Remaining optional work: TTL rule; on-device validation of the slim recovery.
