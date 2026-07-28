# Quick Pi

Quick Pi 是一款 macOS 菜单栏 AI 助手。它将 [Pi](https://github.com/earendil-works/pi)
运行时打包在应用内，可以通过全局快捷键随时打开一个轻量问答窗口。

## 主要功能

- 使用全局快捷键或菜单栏图标快速打开问答窗口。
- 支持流式 Markdown 回答，并展示思考过程、工具执行状态、Token 用量与费用。
- 支持 Pi 内置 Provider 的 API Key 或 OAuth 登录。
- 支持添加 OpenAI Responses 和 Anthropic Messages 兼容的自定义 Provider。
- 支持图片、PDF、DOCX、常见文本及代码文件附件。
- 可选择并记住一个项目工作区，让 Pi 以项目根目录运行并读取项目说明。
- 支持持久化多轮会话，可新建、切换或删除全部会话。
- 自动加载 Pi 扩展、技能和提示模板，可直接执行已注册的 `/命令`。
- 开放 Pi 内置工具和扩展注册的工具，包括终端与文件系统工具。
- 支持登录后自动启动和 Sparkle 应用内更新。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon 或 Intel Mac
- 从源码构建时需要安装 Xcode

## 安装

从项目的 [GitHub Releases](https://github.com/wandou-cc/QuickPi/releases) 下载与 Mac
架构匹配的 `Quick-Pi-<版本号>-<架构>.zip`，解压后打开 `Quick Pi.app`。

## 使用

1. 打开 Quick Pi，进入“设置 > Provider”。
2. 登录 Pi 提供的内置 Provider，或添加自定义 Provider 并同步模型列表。
3. 需要处理项目时，从问答窗口选择工作区。
4. 从问答窗口选择模型，然后输入问题并按 Return 发送。
5. 默认快捷键是 `Command + Shift + Space`，可在“设置 > 通用”中修改。

工作区决定 Pi 的项目根目录和相对路径，并在下次启动时恢复。它不是文件访问沙箱；Pi
及其扩展以当前用户权限运行，可访问当前用户有权访问的文件并执行命令。

会话由 Pi 按运行目录保存。未选择工作区时只显示用户主目录下的普通会话；选择工作区后
只显示该项目的会话，两者不会混在同一个列表中。新问题会继续当前会话并保留前文；可从
问答窗口顶部新建或切换会话。“删除全部会话”会同时删除普通会话及所有工作区会话。

用户级扩展、技能和提示模板分别放在
`~/Library/Application Support/Quick Pi/pi/extensions/`、`skills/` 和 `prompts/`。
工作区级资源分别放在项目的 `.pi/extensions/`、`.pi/skills/` 和 `.pi/prompts/`。
输入 `/reload` 可重新加载这些资源，随后可直接输入列表中注册的 `/命令`。

每次提问最多添加 5 个附件，每个文件不得超过 10 MB；文本内容不得超过 200,000
字符。图片会在本地转换并缩放，PDF、DOCX 与文本文件会在本地提取文字后发送给模型。

## 本地数据

应用设置、Provider 配置和凭证保存在：

```text
~/Library/Application Support/Quick Pi/
```

Pi 会话保存在上述目录的 `pi/sessions/` 中。设置目录和凭证文件仅允许当前用户访问。
请勿提交或分享该目录中的凭证文件。

## 开发

项目使用 Swift Package Manager，主要依赖 Swift Markdown UI 和 Sparkle 2。

```bash
swift build
swift test
```

`swift build` 生成的可执行文件不包含 Pi Runtime 和应用资源。需要生成可直接运行的
macOS 应用时，执行：

```bash
scripts/package-mac.sh
```

脚本会下载并校验对应架构的 Pi Runtime，构建 Release 版本，并输出到
`release/native-<架构>/`。构建脚本固定使用 `/Applications/Xcode.app` 中的 Swift
工具链。

## 许可证

Quick Pi 使用 [MIT License](LICENSE) 开源。项目所使用的第三方组件及其许可证见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

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
