# 关于这个目录（vendored）

本目录是 [SunBK201/UA3F](https://github.com/SunBK201/UA3F) 的源码（`openwrt/` 是它的 OpenWrt 包定义），
按上游 README 的推荐方式直接放在 `package/UA3F`。

- 版本：3.6.0（`openwrt/Makefile` 里的 `PKG_VERSION`）
- 本地改动只有一处：`openwrt/Makefile` 的 `PKG_BUILD_DEPENDS` 加了 `luci-base/host`
  原因：它的 `Build/Prepare` 调用 `po2lmo`（由 luci-base 的 host 构建产出），上游没声明这个依赖，
  声明后能保证构建顺序，避免并行编译时找不到 po2lmo。
- ⚠️ **`internal/bpf/{tc,sockmap}/*.o` 必须留在仓库里（用 `git add -f` 强制入库）**
  这 4 个 eBPF 目标文件由上游提交进仓库，Go 代码用 `//go:embed tc_bpfeb.o` 把它们编进二进制。
  但仓库根 `.gitignore` 第一条是 `*.o`，普通 `git add` **加不进来** ——
  后果是「本地能编、云端编不过」：本地树里文件在，CI 干净检出没有，编译 3 秒就报
  `pattern tc_bpfel.o: no matching files found`（2026-09-20 run #5 实测）。
  校验：`bash scripts/check-vendored-inputs.sh`（CI 每次构建前都会跑）。
  更新本目录时若发现这几个 `.o` 又变回未跟踪状态，重新 `git add -f` 它们。
- 更新方式：直接覆盖本目录（保留上面这行改动），或按上游 README 用 git clone 到 `package/UA3F`。
- 许可：GPL-3.0-only（见 `LICENSE`），与上游一致。
