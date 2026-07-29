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
- 支持按运行目录隔离的持久化多轮会话，可命名、克隆、分叉、压缩或导出。
- 输入 `/` 可搜索应用、扩展、技能和提示模板命令，并查看命令说明与来源。
- 支持 Pi RPC 扩展 UI 的通知、状态、文本 Widget、窗口标题、编辑器文本与交互对话框。
- 开放 Pi 内置工具和扩展注册的工具，包括终端与文件系统工具。
- 回答区域可折叠，并可查看本机 CPU、内存和系统运行状态。
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

每轮回答都可单独复制。对于已经写入会话的提问，还可以从该轮分叉出新会话，原提问会
放回输入框供修改后重新发送。折叠回答区域不会停止正在生成的内容。

在输入框键入 `/` 会打开命令列表，可继续输入名称筛选，并用方向键和 Return 选择。Quick Pi
提供以下不经过模型执行的应用命令，这些命令不接受附件：

| 命令 | 作用 |
| --- | --- |
| `/new` | 新建会话 |
| `/settings` | 打开设置 |
| `/copy` | 复制最近一条非空回答 |
| `/name 会话名称` | 设置当前会话名称 |
| `/session` | 查看消息、工具调用、Token、费用和上下文占用 |
| `/compact [附加要求]` | 压缩当前上下文，可附加摘要要求 |
| `/clone` | 将当前会话分支克隆为新会话 |
| `/export` | 将当前会话导出为 HTML，并显示文件路径 |

Quick Pi 使用 Pi 原生的资源发现规则。用户级扩展、技能、提示模板以及通过 `pi install`
安装的 npm/git/local package 均读取自 `~/.pi/agent/`；工作区级资源读取项目中的
`.pi/settings.json`、`.pi/extensions/`、`.pi/skills/` 和 `.pi/prompts/`。选择工作区时，
Quick Pi 会让 Pi 信任并直接加载该项目的 `.pi` 内容。输入 `/reload` 可调用 Pi 重新加载
这些资源，随后可直接输入列表中注册的 `/命令`。

Quick Pi 是基于 Pi RPC 模式的原生客户端，接入 RPC 协议支持的 `notify`、`setStatus`、
`setWidget`、`setTitle`、编辑器文本和四类交互请求。Pi 文档中明确限定为 TUI 的
`ctx.ui.custom()`、组件工厂和自定义终端渲染器不能在 RPC 客户端中执行；扩展应通过
`ctx.mode` 区分 TUI 专属界面，并为 RPC 模式提供标准文本或交互请求。
Quick Pi 还会识别自定义消息的 `details.qrUrl` 字段；任意扩展都可以提供 HTTP(S)
地址，由原生客户端在本地生成二维码，不会请求远程图片。

每次提问最多添加 5 个附件，每个文件不得超过 10 MB；文本内容不得超过 200,000
字符。图片会在本地转换并缩放，PDF、DOCX 与文本文件会在本地提取文字后发送给模型。

## 本地数据

Quick Pi 自身的应用设置、自定义 Provider 配置与凭证、独立会话保存在：

```text
~/Library/Application Support/Quick Pi/
```

应用设置位于 `settings.json`，自定义 Provider 的模型配置与凭证分别位于 `pi/models.json`
与 `pi/auth.json`，会话位于 `pi/sessions/`。Pi 内置 Provider 的登录凭证、全局设置和已安装
package 仍使用 `~/.pi/agent/`，因此终端 Pi 与 Quick Pi 会加载同一套全局能力。凭证文件
仅允许当前用户访问，请勿提交或分享。

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

脚本会下载并校验对应架构的 Pi Runtime，将 HTML 导出器和应用资源一并打包，构建
Release 版本，并输出到 `release/native-<架构>/`。构建脚本固定使用
`/Applications/Xcode.app` 中的 Swift 工具链。

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
