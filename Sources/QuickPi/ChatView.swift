import AppKit
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

private let chatMessageFontSize: CGFloat = 13

extension Notification.Name {
    static let quickPiFocusInput = Notification.Name("quickPiFocusInput")
}

struct ChatView: View {
    @ObservedObject var state: AppState
    @FocusState private var promptFocused: Bool
    @State private var confirmsDeletingSessions = false
    @State private var sessionsPresented = false

    var body: some View {
        VStack(spacing: 0) {
            inputBar
            if state.showsResultPanel {
                Divider()
                    .padding(.horizontal, 14)
                resultPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.primary.opacity(0.1))
        }
        .sheet(isPresented: Binding(
            get: { state.extensionPrompt != nil },
            set: { presented in
                if !presented && state.extensionPrompt != nil {
                    state.cancelExtensionPrompt()
                }
            }
        )) {
            if let prompt = state.extensionPrompt {
                ExtensionPromptView(state: state, prompt: prompt)
            }
        }
        .alert("删除全部会话？", isPresented: $confirmsDeletingSessions) {
            Button("取消", role: .cancel) {}
            Button("删除全部", role: .destructive) {
                Task { await state.deleteAllSessions() }
            }
        } message: {
            Text("这会删除主目录以及所有工作区中的全部会话，且无法撤销。")
        }
        .preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: .quickPiFocusInput)) { _ in
            promptFocused = true
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            contextBar

            if !state.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(state.attachments) { attachment in
                            HStack(spacing: 5) {
                                Image(systemName: "doc")
                                    .font(.caption)
                                Text(attachment.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Button {
                                    state.removeAttachment(id: attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .help("移除附件")
                            }
                            .foregroundStyle(.secondary)
                            .padding(.leading, 9)
                            .padding(.trailing, 6)
                            .frame(height: 26)
                            .background(
                                .primary.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .scrollIndicators(.hidden)
                .frame(height: 38)
            }

            HStack(spacing: 8) {
                TextField("问点什么", text: $state.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .frame(minWidth: 120)
                    .focused($promptFocused)
                    .onSubmit {
                        Task { await state.send() }
                    }

                Button {
                    chooseAttachments()
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .foregroundStyle(.secondary)
                .help("添加附件")

                Menu {
                    if state.modelOptions.isEmpty {
                        Text("未配置模型")
                    } else {
                        ForEach(state.modelOptions, id: \.selectionKey) { model in
                            Button {
                                Task { await state.selectModel(selectionKey: model.selectionKey) }
                            } label: {
                                if state.settings.selectedModel == model.selection {
                                    Label("\(model.providerName) · \(model.name)", systemImage: "checkmark")
                                } else {
                                    Text("\(model.providerName) · \(model.name)")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if state.runtimeStarting {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        (
                            Text(state.selectedModel?.name ?? "选择模型")
                                + Text(" ")
                                + Text(Image(systemName: "chevron.down"))
                                .font(.system(size: 9, weight: .semibold))
                        )
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(
                        .primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 170)
                .disabled(!state.runtimeReady || state.isAnswering || state.sessionChanging)

                Button {
                    Task { await state.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .disabled(
                    state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !state.runtimeReady
                        || state.isAnswering
                        || state.sessionChanging
                )
                .help("发送")

                Button {
                    state.presentSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .foregroundStyle(.secondary)
                .help("设置")
            }
            .padding(.horizontal, 18)
            .frame(height: 64)
        }
        .frame(height: state.attachments.isEmpty ? 102 : 140)
    }

    private var contextBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    chooseWorkspace()
                } label: {
                    Label(
                        state.settings.workspacePath == nil ? "选择工作区…" : "更换工作区…",
                        systemImage: "folder"
                    )
                }
                if state.settings.workspacePath != nil {
                    Divider()
                    Button {
                        state.setWorkspace(nil)
                    } label: {
                        Label("返回主目录", systemImage: "house")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: state.settings.workspacePath == nil ? "house" : "folder.fill")
                    Text(state.scopeTitle)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(width: 150, height: 28, alignment: .leading)
                .background(
                    .primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 150)
            .disabled(state.isAnswering || state.sessionChanging)
            .help(state.settings.workspacePath ?? "主目录")

            Spacer(minLength: 40)

            Button {
                sessionsPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    if state.sessionChanging {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    Text(state.activeSession.map { state.title(for: $0) } ?? "会话")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(width: 180, height: 28, alignment: .leading)
                .background(
                    .primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .frame(width: 180)
            .disabled(!state.runtimeReady || state.isAnswering || state.sessionChanging)
            .help("切换会话")
            .popover(isPresented: $sessionsPresented, arrowEdge: .top) {
                VStack(spacing: 0) {
                    if state.sessions.isEmpty {
                        Text("暂无会话")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(state.sessions) { session in
                                    Button {
                                        sessionsPresented = false
                                        Task { await state.switchSession(id: session.id) }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "checkmark")
                                                .opacity(session.id == state.activeSessionID ? 1 : 0)
                                                .frame(width: 12)
                                            Text(state.title(for: session))
                                                .lineLimit(1)
                                            Spacer(minLength: 8)
                                        }
                                        .contentShape(Rectangle())
                                        .padding(.horizontal, 10)
                                        .frame(height: 32)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollIndicators(.visible)
                        .frame(height: min(CGFloat(state.sessions.count) * 32, 256))
                    }

                    Divider()

                    Button(role: .destructive) {
                        sessionsPresented = false
                        confirmsDeletingSessions = true
                    } label: {
                        Label("删除全部会话…", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                }
                .frame(width: 260)
            }

            Button {
                Task { await state.createSession() }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .frame(width: 30, height: 28)
            .foregroundStyle(.secondary)
            .disabled(!state.runtimeReady || state.isAnswering || state.sessionChanging)
            .help("新建会话")
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(state.conversationAnswers) { answer in
                            let tools = answer.sections.compactMap { section in
                                if case .tool(let tool) = section.content {
                                    return tool
                                }
                                return nil
                            }

                            questionView(answer.question)

                            ForEach(answer.sections) { section in
                                AnswerSectionView(section: section, tools: tools)
                            }

                            if answer.id == state.answer?.id && answer.sections.isEmpty && state.isAnswering {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(answer.status == .waiting ? "正在连接模型" : "正在思考")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let retry = answer.retryMessage {
                                Label(retry, systemImage: "arrow.clockwise")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }
                            if let error = answer.error {
                                Label(error, systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            } else if answer.status == .stopped {
                                Label("已停止", systemImage: "stop.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            answerMetadata(answer)
                        }

                        if let runtimeError = state.runtimeError {
                            Label(runtimeError, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("answer-bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.conversationAnswers) { _, _ in
                    proxy.scrollTo("answer-bottom", anchor: .bottom)
                }
            }

            Divider()

            HStack(spacing: 14) {
                if state.isAnswering {
                    Button {
                        Task { await state.abort() }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.plain)
                    .help("停止回答")
                }

                Spacer()

                if let text = state.conversationAnswers.last?.answerText, !text.isEmpty {
                    Button {
                        copy(text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("复制回答")
                }

                Button {
                    Task { await state.clearAnswer() }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("收起结果")
            }
            .font(.caption)
            .padding(.horizontal, 18)
            .frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Renders the submitted question and its attachment names without repeating extracted content.
    private func questionView(_ question: SubmittedQuestion) -> some View {
        HStack {
            Spacer(minLength: 72)
            VStack(alignment: .leading, spacing: 5) {
                Text(question.text)
                    .font(.system(size: chatMessageFontSize))
                    .textSelection(.enabled)
                if let workspacePath = question.workspacePath {
                    Label(
                        URL(fileURLWithPath: workspacePath, isDirectory: true).lastPathComponent,
                        systemImage: "folder"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(workspacePath)
                }
                if !question.attachmentNames.isEmpty {
                    Label(question.attachmentNames.joined(separator: " · "), systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                .primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }

    // Shows model, token, cost, and non-normal stop metadata after assistant turns arrive.
    @ViewBuilder
    private func answerMetadata(_ answer: AnswerSession) -> some View {
        if answer.model != nil || answer.usage.totalTokens > 0 || answer.stopReason == "length" {
            HStack(spacing: 10) {
                if let model = answer.model {
                    Text(model)
                }
                if answer.usage.totalTokens > 0 {
                    Text("\(answer.usage.totalTokens.formatted()) tokens")
                }
                if answer.usage.cost > 0 {
                    Text(answer.usage.cost, format: .currency(code: "USD"))
                }
                if answer.stopReason == "length" {
                    Label("达到输出上限", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
    }

    // Opens the native picker and passes only the user's explicit selections to the loader.
    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .pdf, .plainText, .data]
        guard panel.runModal() == .OK else {
            return
        }
        Task { await state.addAttachments(urls: panel.urls) }
    }

    // Opens the native directory picker at the current project root and persists one selection.
    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = state.settings.workspaceURL
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        state.setWorkspace(url)
    }

    // Replaces the general pasteboard with the selected answer or code content.
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ExtensionPromptView: View {
    @ObservedObject var state: AppState
    let prompt: ExtensionPrompt
    @State private var value: String

    init(state: AppState, prompt: ExtensionPrompt) {
        self.state = state
        self.prompt = prompt
        _value = State(initialValue: prompt.prefill ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.title)
                .font(.headline)

            if let message = prompt.message {
                Text(message)
                    .foregroundStyle(.secondary)
            }

            switch prompt.method {
            case "select":
                ForEach(prompt.options, id: \.self) { option in
                    Button(option) {
                        state.respondToExtensionPrompt(value: option)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button("取消") {
                        state.cancelExtensionPrompt()
                    }
                }
            case "confirm":
                Spacer()
                HStack {
                    Spacer()
                    Button("否") {
                        state.respondToExtensionPrompt(confirmed: false)
                    }
                    Button("确认") {
                        state.respondToExtensionPrompt(confirmed: true)
                    }
                    .buttonStyle(.borderedProminent)
                }
            case "editor":
                TextEditor(text: $value)
                    .font(.system(.body, design: .monospaced))
                    .padding(6)
                    .background(
                        .primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                submitRow
            default:
                TextField(prompt.placeholder ?? "", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Spacer(minLength: 0)
                submitRow
            }
        }
        .padding(20)
        .frame(width: 420, height: prompt.method == "editor" ? 360 : 280)
        .background(Color.white)
        .preferredColorScheme(.light)
    }

    private var submitRow: some View {
        HStack {
            Spacer()
            Button("取消") {
                state.cancelExtensionPrompt()
            }
            Button("继续") {
                submit()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // Returns the exact input or edited text requested by the extension.
    private func submit() {
        state.respondToExtensionPrompt(value: value)
    }
}

private struct AnswerSectionView: View {
    let section: AnswerSection
    let tools: [ToolActivity]

    var body: some View {
        switch section.content {
        case .markdown(let text):
            AnswerMarkdownView(source: text)
        case .thinking(let text):
            DisclosureGroup {
                AnswerMarkdownView(source: text)
                    .padding(.top, 6)
            } label: {
                Label("思考过程", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .tool(let tool):
            if tool.callId == tools.first?.callId {
                ToolActivityGroupView(tools: tools)
            }
        }
    }
}

private struct ToolActivityGroupView: View {
    let tools: [ToolActivity]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(tools, id: \.callId) { tool in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            switch tool.status {
                            case .running:
                                ProgressView()
                                    .controlSize(.mini)
                            case .completed:
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.green)
                            case .failed:
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.red)
                            }
                            Text(tool.name)
                                .font(.caption.weight(.medium))
                        }

                        Text("输入")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        monospaced(tool.input)
                        if !tool.output.isEmpty {
                            Text("输出")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            monospaced(tool.output)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                if tools.contains(where: { $0.status == .running }) {
                    ProgressView()
                        .controlSize(.mini)
                } else if tools.contains(where: { $0.status == .failed }) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                Text("工具调用（\(tools.count)）")
                    .font(.caption.weight(.medium))
            }
        }
    }

    // Displays tool JSON and output in a stable horizontally scrollable monospace region.
    private func monospaced(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(9)
        }
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct AnswerMarkdownView: View {
    let source: String

    var body: some View {
        // Asset-only providers prevent untrusted model output from issuing remote image requests.
        Markdown(source)
            .markdownTextStyle(\.text) { FontSize(chatMessageFontSize) }
            .markdownTheme(.gitHub)
            .markdownImageProvider(AssetImageProvider())
            .markdownInlineImageProvider(AssetInlineImageProvider())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
