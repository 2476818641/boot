# 关于这个目录（vendored）

本目录是 [SunBK201/UA3F](https://github.com/SunBK201/UA3F) 的源码（`openwrt/` 是它的 OpenWrt 包定义），
按上游 README 的推荐方式直接放在 `package/UA3F`。

- 版本：3.6.0（`openwrt/Makefile` 里的 `PKG_VERSION`）
- 本地改动只有一处：`openwrt/Makefile` 的 `PKG_BUILD_DEPENDS` 加了 `luci-base/host`
  原因：它的 `Build/Prepare` 调用 `po2lmo`（由 luci-base 的 host 构建产出），上游没声明这个依赖，
  声明后能保证构建顺序，避免并行编译时找不到 po2lmo。
- 更新方式：直接覆盖本目录（保留上面这行改动），或按上游 README 用 git clone 到 `package/UA3F`。
- 许可：GPL-3.0-only（见 `LICENSE`），与上游一致。
