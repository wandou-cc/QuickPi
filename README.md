# Quick Pi

## 发布 macOS 更新

应用使用 GitHub Releases 和 Sparkle 2 检查、验证并安装更新。Apple Silicon 与 Intel 安装包包含不同的 Pi Runtime，因此每种架构使用独立的 appcast。

首次发布前，本机钥匙串中必须存在更新签名私钥。项目当前使用的钥匙串账户是 `dev.pi.quick`，公开密钥已经写入 `resources/Info.plist`。私钥不能提交到 Git；请通过 `.cache/sparkle-2.9.4/tools/bin/generate_keys --account dev.pi.quick -x <仓库外的安全路径>` 单独备份。

每次发布按以下步骤操作：

1. 在 `resources/Info.plist` 中更新 `CFBundleShortVersionString`，并递增 `CFBundleVersion`。
2. 在对应架构的 Mac 上执行 `scripts/package-mac.sh`。
3. 执行 `scripts/create-update.sh`，为该架构生成签名后的 appcast。
4. 在 `wandou-cc/QuickPi` 创建标签为 `v<版本号>` 的非预发布 GitHub Release。
5. 上传该架构生成的两个文件：`Quick-Pi-<版本号>-<架构>.zip` 和 `appcast-<架构>.xml`。

首次执行 `scripts/create-update.sh` 时，macOS 会请求读取钥匙串中的更新私钥；选择“始终允许”，后续发布即可直接签名。

若同时发布 Apple Silicon 和 Intel 版本，两个架构的四个文件必须放在同一个 Release。GitHub 的 `latest` Release 必须保持为正式版本，应用中的固定更新地址才能解析到最新 appcast。
