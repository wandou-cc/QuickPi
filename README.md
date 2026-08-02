<p align="center">
  <img src="resources/icon.png" width="112" alt="Quick Pi 图标">
</p>

<h1 align="center">Quick Pi</h1>

<p align="center">
  原生、常驻菜单栏的 macOS AI 助手
</p>

<p align="center">
  <a href="https://github.com/wandou-cc/QuickPi/releases">下载安装</a>
  ·
  <a href="#核心能力">核心能力</a>
  ·
  <a href="#快速开始">快速开始</a>
  ·
  <a href="#开发">开发</a>
</p>

Quick Pi 是 [Pi](https://github.com/earendil-works/pi) 的原生 macOS 客户端。它可以随时从菜单栏唤起，也可以进入项目目录读取代码、修改文件、运行命令，并持续完成开发任务。

发布版已内置 Pi Runtime，无需另外安装命令行工具。

## 0.5.1 更新

- 新增可编辑的操作审批规则，可按工具名、危险 Shell 关键字或全部 Shell 命令要求确认。
- 审批请求直接显示在回答正文中，用户可查看工作目录和完整参数后选择“通过”或“不通过”。
- 图片附件改为后台降采样和转码，降低大图处理时的内存占用与界面阻塞。
- 合并高频流式输出刷新，提升长回答、思考过程和工具输出的渲染流畅度。
- 精简各架构安装包中的 Sparkle 二进制与调试符号，减小下载体积。

## 核心能力

### 原生问答体验

- 通过菜单栏图标或全局快捷键打开，默认快捷键为 `Command + Shift + Space`。
- 支持多行输入、流式 Markdown、代码块、思考过程、工具调用和停止生成。
- 任务执行期间仍可提交后续问题，并选择插队或排队；尚未执行的问题可以编辑或取消。
- 已完成的问题可以修改并重新生成后续内容，也可以从任意回答创建新的会话分支。
- 支持跟随系统、浅色和深色主题，可设置登录时启动及窗口失焦后的行为。

### 项目与 Git

- 选择工作区后，Pi 会以项目目录作为运行目录，使用终端、文件系统及扩展提供的工具完成任务。
- 显示当前 Git 分支，可提交并推送更改、切换或创建分支，以及查看 Diff 和最近提交。
- 可为任务创建独立 Git Worktree，让多个会话在不同工作目录中并行执行。
- 自动加载项目中的 Pi 配置、扩展、Skill、提示模板和上下文说明。

工作区用于确定项目根目录，但不是文件访问沙箱。Pi 及其扩展以当前用户权限运行，请只加载可信项目和扩展。

### 会话与上下文

- 会话按运行目录保存，主空间、工作区和 Worktree 之间互不混合。
- 支持新建、切换、命名、克隆和删除会话，重新打开应用后可继续先前任务。
- 一个会话执行任务时，可以切换到其他会话继续工作；会话列表会显示运行及未读状态。
- 可查看 Token、费用和上下文占用，压缩长对话或将会话导出为 HTML。
- 删除托管 Worktree 前会检查未提交改动，并保护 detached HEAD 上的新提交。

### 模型与 Provider

- 支持 Pi 内置 Provider 的 API Key 或 OAuth 登录。
- 支持 OpenAI Responses 和 Anthropic Messages 协议的自定义 Provider。
- 可同步 Provider 的模型列表，并按模型配置推理强度和图片输入能力。
- 会记住当前模型及推理强度，切换会话后无需重复配置。

### 附件

- 支持图片、PDF、DOCX、常见文本格式及代码文件。
- 每次最多添加 5 个附件，每个文件不超过 10 MB，单个文本文件不超过 200,000 字符。
- 附件随会话保存，切换会话或重新启动后仍可继续查看和使用。

### Pi 生态

- 支持 Pi 扩展、Skill、提示模板、项目上下文文件及通过 `pi install` 安装的 package。
- 在输入框键入 `/` 可搜索应用命令、扩展命令、Skill 和提示模板。
- 内置 Plan Mode，可先进行只读分析和任务规划，再确认是否执行。
- 支持扩展发起通知、状态更新、问卷和确认等原生交互。
- 可在设置中编辑全局 `~/.pi/agent/AGENTS.md`，统一约束后续任务的工作方式。

### 系统集成

- 可选显示 CPU、内存和磁盘状态。
- 支持 Sparkle 应用内更新。
- 提供 Apple Silicon 与 Intel Mac 的独立原生安装包。

## 快速开始

1. 从 [GitHub Releases](https://github.com/wandou-cc/QuickPi/releases) 下载与 Mac 架构匹配的安装包。
2. 解压并打开 `Quick Pi.app`。
3. 在“设置 > Provider”中登录 Provider，或添加自定义 Provider 并同步模型。
4. 回到主窗口选择模型。需要处理项目时，再选择对应工作区。
5. 输入问题并按 Return 发送。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon 或 Intel Mac

## 数据与权限

Quick Pi 的应用设置、会话和托管 Worktree 保存在：

```text
~/Library/Application Support/Quick Pi/
```

Pi 内置 Provider 的凭证、全局设置、`AGENTS.md` 和已安装 package 位于：

```text
~/.pi/agent/
```

Quick Pi 会限制自身设置及凭证文件仅供当前用户访问。对话、附件和工具输出会按照所选模型与 Provider 的协议发送；使用第三方 Provider 前，请确认其数据处理政策。

## 开发

项目使用 Swift Package Manager，需要完整安装 Xcode。构建和测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

生成包含 Pi Runtime、Sparkle 和完整应用资源的 macOS 应用：

```bash
scripts/package-mac.sh
```

构建产物位于 `release/native-<架构>/`。Apple Silicon 与 Intel 版本需要分别构建。

## 许可证

Quick Pi 使用 [MIT License](LICENSE) 开源。第三方组件及许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
