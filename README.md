<p align="center">
  <img src="resources/icon.png" width="112" alt="Quick Pi 图标">
</p>

<h1 align="center">Quick Pi</h1>

<p align="center">
  随时唤起、能理解项目并执行任务的原生 macOS AI 助手
</p>

<p align="center">
  <a href="https://github.com/wandou-cc/QuickPi/releases">下载安装</a>
  ·
  <a href="#核心功能">核心功能</a>
  ·
  <a href="#快速开始">快速开始</a>
  ·
  <a href="#本地数据与权限">数据与权限</a>
  ·
  <a href="#开发">开发</a>
</p>

Quick Pi 是一款常驻菜单栏的原生 macOS AI 助手。发布版内置
[Pi](https://github.com/earendil-works/pi) Runtime，无需单独安装命令行环境；按下全局快捷键即可开始问答，也可以选择一个项目目录，让 Pi 读取代码、编辑文件、调用工具并持续处理任务。

## 核心优势

| 优势 | 实际价值 |
| --- | --- |
| 原生且随手可用 | 常驻菜单栏，通过全局快捷键快速呼出；支持所有桌面与全屏空间，并可选择失焦后自动隐藏。 |
| 不只是聊天 | 选择工作区后，Pi 会以项目根目录运行，可使用终端、文件系统及扩展提供的工具完成实际任务。 |
| Provider 不绑定 | 既支持 Pi 内置 Provider 的 API Key/OAuth 登录，也支持 OpenAI Responses 和 Anthropic Messages 兼容服务。 |
| 会话持续且可并行 | 会话自动保存并按项目隔离；需要隔离 Git 改动时可通过 `/worktree` 创建专属 Worktree，切换后正在执行的任务仍可继续运行。 |
| 执行过程透明 | 回答期间可继续输入并选择插队或排队；实时展示 Markdown、思考过程、分组后的工具调用、Token 明细与费用。 |
| 沿用 Pi 生态 | 可直接加载 Pi 的扩展、Skill、提示模板、项目上下文文件及已安装 package。 |
| 数据位置明确 | 应用设置、自定义 Provider 和会话保存在本机固定目录，凭证文件限制为当前用户访问。 |

## 核心功能

### 快速问答

- 点击菜单栏图标或使用全局快捷键打开悬浮问答窗口；右键菜单栏图标可进入设置、检查更新或退出应用。
- 默认快捷键为 `Command + Shift + Space`，也可改为其他预设组合。
- 在其他应用中复制一段新文本后按全局快捷键，Quick Pi 会打开窗口并直接将该文本作为问题发送；没有新复制内容时只会打开窗口并聚焦输入框。
- 输入框支持多行内容并会随文本自动增高，按 `Shift + Return` 换行，按 `Return` 发送。
- 支持流式 Markdown、代码块复制、停止生成，以及回答区域展开或收起。
- 回答生成期间可以继续编辑下一条问题，并选择“插队”在当前工具调用结束后优先发送，或选择“排队”在当前回答完成后发送。
- 工具调用按回答阶段分组显示，运行时保持展开，完成后可折叠查看输入与输出。
- 每个问题和回答都可单独复制；任意已完成回答都可克隆为新会话并在当前窗口继续。
- 可设置登录后自动启动、首页系统状态显示，以及主窗口失焦后是否自动隐藏。

### 模型与 Provider

- 使用 Pi 内置 Provider，并按 Provider 能力选择 API Key 或 OAuth 登录。
- 添加、编辑或删除 OpenAI Responses / Anthropic Messages 兼容的自定义 Provider。
- 从 Provider 的 `/models` 接口同步模型列表，并记住当前模型。
- 在主窗口快速切换已配置模型；图片只会提交给支持图片输入的模型。

### 工作区与 Agent 工具

- 选择并记住一个项目工作区，Pi 会以该目录作为真实运行目录。
- 顶部展示当前会话的 Git 分支；点击后可提交、提交并推送、推送、新建或切换本地分支，并查看 Diff 与最近 Log。
- 右上角新建按钮和 `/new` 只在当前运行目录中新建会话，不会执行 Git 操作。
- 在 Git 工作区中执行 `/worktree`，Quick Pi 会从当前 `HEAD` 创建独立的 detached Worktree；未选择工作区或当前工作区不是 Git 仓库时会明确拒绝执行。
- 新 Worktree 会带入主工作区中已跟踪文件的本地改动，以及未被 Git 忽略的未跟踪普通文件；Git 忽略文件不会复制。
- 开放 Pi 内置的终端、文件系统等工具，以及扩展注册的工具。
- 自动加载项目中的 Pi 配置、扩展、Skill、提示模板和上下文说明。
- 未选择工作区时，以用户主目录运行，并使用通用问答模式。

工作区用于确定 Pi 的项目根目录和相对路径，但它不是文件访问沙箱。Pi 及其扩展以当前用户权限运行，能够访问当前用户有权访问的其他文件和命令。加载不可信项目的 `.pi` 内容前，请先检查其来源。

### 多会话与上下文管理

- 按运行目录保存多轮会话，主空间与各工作区的会话互不混合。
- 支持新建、切换、命名和删除单个非活动会话，并在重新启动后恢复对话、工具记录及状态。
- 一个会话执行时可以切换到另一个会话继续工作；列表会显示运行状态和未读完成状态。
- 支持克隆整个当前分支，也可保留到某一轮回答并在当前窗口的新会话中继续；克隆会话与来源会话共享同一个 Worktree。
- Worktree 初始处于 detached HEAD。使用 `/branch <分支名>` 可在当前提交创建并切换到长期分支；会话列表会显示当前分支状态。
- 可查看消息数、工具调用、输入/输出及缓存 Token 明细、费用和上下文占用，也可压缩上下文或导出 HTML。

删除 Worktree 的最后一个会话时，Quick Pi 会同时清理该 Worktree。存在未提交改动时会拒绝删除；如果 detached HEAD 上已有新提交，会先创建 `quick-pi/<worktree-id>` 保护分支。用户通过 `/branch` 创建的分支会保留。“删除全部会话”会先检查所有托管 Worktree，确认均可安全清理后才继续；会话删除不可撤销。

### 附件

- 支持图片、PDF、DOCX、常见文本格式及代码文件；也可直接粘贴剪贴板中的图片。
- 每次最多添加 5 个附件，每个文件不超过 10 MB，单个文本内容不超过 200,000 字符。
- 图片会在本地转换为 JPEG，并将最长边限制为 2,048 像素。
- PDF、DOCX 与文本文件会先在本地提取文字，再随问题发送给所选模型。

### 命令、扩展与 Skill

在输入框键入 `/` 即可搜索应用命令、扩展命令、Skill 和提示模板；支持继续输入筛选，并使用方向键与 Return 选择。Quick Pi 自带以下不经过模型执行的应用命令，这些命令不接受附件：

| 命令 | 作用 |
| --- | --- |
| `/new` | 在当前会话的运行目录中新建会话，不创建新的 Worktree |
| `/worktree` | 从所选 Git 工作区创建独立 Worktree，并在其中新建会话 |
| `/settings` | 打开设置 |
| `/copy` | 复制最近一条非空回答 |
| `/name 会话名称` | 设置当前会话名称 |
| `/session` | 查看消息、工具调用、Token、费用和上下文占用 |
| `/compact [附加要求]` | 压缩当前上下文，可附加摘要要求 |
| `/clone` | 将当前会话分支克隆为新会话 |
| `/branch 分支名` | 为当前托管 Worktree 创建并切换到分支 |
| `/export` | 将当前会话导出为 HTML，并显示可打开的文件链接 |

发布版还会加载当前 Pi Runtime 自带的官方 Plan Mode 扩展：

- `/plan` 在只读规划模式与正常模式之间切换。规划模式禁用内置写入工具，并限制 Bash 为只读命令。
- 规划完成后，原生界面会显示“执行、保持规划或继续调整”的选择；执行期间会展示步骤和完成进度。
- `/todos` 显示当前计划的待办状态。Plan mode 状态随 Pi 会话保存，切换或重新打开会话后可以恢复。

Quick Pi 使用 Pi 原生的资源发现规则：

- 用户级扩展、Skill、提示模板和通过 `pi install` 安装的 package 位于 `~/.pi/agent/`。
- 工作区级资源位于项目的 `.pi/settings.json`、`.pi/extensions/`、`.pi/skills/` 和 `.pi/prompts/`。
- 输入 `/reload` 可重新加载这些资源，随后即可使用其中注册的命令。

作为 Pi RPC 原生客户端，Quick Pi 支持扩展发送通知、状态、编辑器上下 Widget、窗口标题和编辑器文本，也支持 `input`、`select`、`confirm`、`editor` 四类交互请求。扩展还可通过自定义消息的 `details.qrUrl` 提供 HTTP(S) 地址，由客户端在本地生成二维码。

Pi 中仅面向 TUI 的 `ctx.ui.custom()`、组件工厂和自定义终端渲染器无法在 RPC 客户端中运行。扩展应通过 `ctx.mode` 区分运行环境，并为 RPC 模式提供标准文本或交互请求。

### 系统与应用集成

- 首页可用一行摘要查看 CPU、内存和磁盘占用，点击后查看容量与系统运行时间。
- 系统状态可在设置中关闭，关闭后不会继续采集。
- 支持 Sparkle 应用内检查和安装更新。
- 支持 Apple Silicon 与 Intel Mac 的独立原生安装包。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon 或 Intel Mac
- 从源码构建时需要完整安装 Xcode

## 快速开始

1. 从 [GitHub Releases](https://github.com/wandou-cc/QuickPi/releases) 下载与 Mac 架构匹配的 `Quick-Pi-<版本号>-<架构>.zip`。
2. 解压并打开 `Quick Pi.app`。
3. 进入“设置 > Provider”，登录一个 Pi 内置 Provider，或添加自定义 Provider 并同步模型。
4. 回到主窗口选择模型；需要处理项目时，再选择对应工作区。
5. 输入问题并按 Return 发送。也可以在其他应用中复制文本，再按默认全局快捷键 `Command + Shift + Space` 直接提问；如果剪贴板没有新文本，快捷键只会打开 Quick Pi。

## 本地数据与权限

Quick Pi 自身的数据保存在：

```text
~/Library/Application Support/Quick Pi/
```

| 路径 | 内容 |
| --- | --- |
| `settings.json` | 快捷键、登录启动、工作区、当前模型和自定义 Provider 配置 |
| `pi/models.json` | 自定义 Provider 的 Pi 模型配置 |
| `pi/auth.json` | 自定义 Provider 凭证 |
| `pi/sessions/` | 主空间及所有工作区的 Quick Pi 会话 |
| `worktrees.json` | 托管 Worktree 与项目目录的对应关系及分支状态 |
| `worktrees/` | Quick Pi 创建的 Git Worktree 工作目录 |

Pi 内置 Provider 的凭证、全局设置和已安装 package 仍位于 `~/.pi/agent/`，因此终端 Pi 与 Quick Pi 会共用这些全局能力。应用会将自身设置、模型配置与凭证文件权限设为仅当前用户可读写；这些文件仍包含敏感信息，请勿提交或分享。

问题、附件处理结果和工具输出会按所选模型与 Provider 的协议发送。使用第三方或自定义 Provider 前，应确认其数据处理政策。

## 开发

项目使用 Swift Package Manager，主要依赖 Swift Markdown UI 和 Sparkle 2。

```bash
swift build
swift test
```

`swift build` 生成的可执行文件不包含 Pi Runtime、Sparkle Framework 和完整应用资源。生成可直接运行的 macOS 应用需要执行：

```bash
scripts/package-mac.sh
```

打包脚本固定使用 `/Applications/Xcode.app` 的 Swift 工具链，下载并校验当前架构的 Pi Runtime，打包 HTML 导出器、官方 Plan Mode 扩展、应用资源、第三方许可证和 Sparkle，最终输出到 `release/native-<架构>/`。

## 发布 macOS 更新

Quick Pi 使用 GitHub Releases 和 Sparkle 2 分发更新。Apple Silicon 与 Intel 安装包包含不同架构的 Pi Runtime，因此各自使用独立 appcast。

1. 在 `resources/Info.plist` 中更新 `CFBundleShortVersionString`，并递增 `CFBundleVersion`。
2. 在对应架构的 Mac 上执行 `scripts/package-mac.sh`。
3. 执行 `scripts/create-update.sh`，生成该架构签名后的 appcast。
4. 在 `wandou-cc/QuickPi` 创建标签为 `v<版本号>` 的正式 GitHub Release。
5. 上传 `Quick-Pi-<版本号>-<架构>.zip` 和 `appcast-<架构>.xml`。

首次发布前，钥匙串中必须存在 Sparkle 更新签名私钥。当前账户名为 `dev.pi.quick`，公开密钥已写入 `resources/Info.plist`；私钥不得提交到 Git。可使用 `.cache/sparkle-2.9.4/tools/bin/generate_keys --account dev.pi.quick -x <仓库外的安全路径>` 单独备份。首次运行更新脚本时，macOS 会请求读取私钥，选择“始终允许”后即可自动签名。

同时发布两种架构时，需要将两个 ZIP 和两个 appcast 放入同一个正式 Release，并确保 GitHub 的 `latest` 始终指向正式版本。

## 许可证

Quick Pi 使用 [MIT License](LICENSE) 开源。第三方组件及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
