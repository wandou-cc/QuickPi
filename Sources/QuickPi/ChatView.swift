import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

private let chatMessageFontSize: CGFloat = 13
private let qrCodeContext = CIContext()

private struct SlashCommandScrollRequest: Equatable {
    let id = UUID()
    let commandName: String
}

extension Notification.Name {
    static let quickPiFocusInput = Notification.Name("quickPiFocusInput")
}

struct ChatView: View {
    @ObservedObject var state: AppState
    @AppStorage("showSystemStatus") private var showSystemStatus = true
    @FocusState private var promptFocused: Bool
    @State private var confirmsDeletingSessions = false
    @State private var sessionsPresented = false
    @State private var selectedSlashCommandIndex = 0
    @State private var slashCommandScrollRequest: SlashCommandScrollRequest?
    @State private var modelMenuPresented = false

    var body: some View {
        VStack(spacing: 0) {
            inputBar
            if !state.slashCommandSuggestions.isEmpty {
                slashCommandMenu
            } else if state.showsResultPanel {
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
            Text("这会删除主空间以及所有工作区中的全部会话，且无法撤销。")
        }
        .preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: .quickPiFocusInput)) { _ in
            promptFocused = true
        }
        .onChange(of: state.draft) { _, _ in
            selectedSlashCommandIndex = 0
            if !state.slashCommandSuggestions.isEmpty {
                modelMenuPresented = false
            }
        }
        .onChange(of: state.slashCommands) { _, _ in
            if !state.slashCommandSuggestions.isEmpty {
                modelMenuPresented = false
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            contextBar

            ForEach(state.extensionWidgets.filter { $0.placement == .aboveEditor }) { widget in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(widget.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
                            .help(line)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .frame(height: CGFloat(widget.lines.count * 16 + 12))
                .background(.primary.opacity(0.025))
            }

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
                TextField(
                    "问点什么",
                    text: Binding(
                        get: { state.draft },
                        set: { state.draft = $0 }
                    )
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .frame(minWidth: 120)
                    .focused($promptFocused)
                    .onSubmit {
                        let suggestions = state.slashCommandSuggestions
                        if suggestions.isEmpty {
                            Task { await state.send() }
                        } else if state.draftMatchesSlashCommand {
                            Task { await state.send() }
                        } else {
                            selectSlashCommand(
                                suggestions[min(selectedSlashCommandIndex, suggestions.count - 1)]
                            )
                        }
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow]) { keyPress in
                        guard keyPress.modifiers.isEmpty else {
                            return .ignored
                        }
                        let suggestions = state.slashCommandSuggestions
                        guard !suggestions.isEmpty else {
                            return .ignored
                        }
                        let nextIndex: Int
                        if keyPress.key == .upArrow {
                            nextIndex = (
                                selectedSlashCommandIndex + suggestions.count - 1
                            ) % suggestions.count
                        } else {
                            nextIndex = (selectedSlashCommandIndex + 1) % suggestions.count
                        }
                        selectedSlashCommandIndex = nextIndex
                        slashCommandScrollRequest = SlashCommandScrollRequest(
                            commandName: suggestions[nextIndex].name
                        )
                        return .handled
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

                Button {
                    modelMenuPresented.toggle()
                } label: {
                    HStack(spacing: 4) {
                        if state.runtimeStarting {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(state.selectedModel?.name ?? "选择模型")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 108)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(
                        .primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!state.runtimeReady || state.hasRunningSessions || state.sessionChanging)
                .help(
                    state.selectedModel.map { "\($0.providerName) · \($0.name)" }
                        ?? "选择模型"
                )
                .popover(
                    isPresented: $modelMenuPresented,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    modelMenu
                }

                Button {
                    Task { await state.send() }
                } label: {
                    if state.extensionCommandRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .disabled(
                    state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !state.runtimeReady
                        || state.isBusy
                        || state.sessionChanging
                )
                .help("发送")

                if !state.showsResultPanel && state.hasResultPanelContent {
                    Button {
                        state.toggleResultPanel()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.secondary)
                    .help("展开结果")
                }

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

            ForEach(state.extensionWidgets.filter { $0.placement == .belowEditor }) { widget in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(widget.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
                            .help(line)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .frame(height: CGFloat(widget.lines.count * 16 + 12))
                .background(.primary.opacity(0.025))
            }
        }
        .frame(height: state.inputBarHeight)
    }

    private var slashCommandMenu: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.slashCommandSuggestions.enumerated()), id: \.element.name) { index, command in
                        Button {
                            selectSlashCommand(command)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("/\(command.name)")
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let description = command.description, !description.isEmpty {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 12)
                                Text(command.source.title)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(
                                index == selectedSlashCommandIndex
                                    ? Color.accentColor.opacity(0.08)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(command.name)
                        .onHover { hovering in
                            if hovering {
                                selectedSlashCommandIndex = index
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.visible)
            .onChange(of: slashCommandScrollRequest) { _, request in
                guard let request else {
                    return
                }
                proxy.scrollTo(request.commandName, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: state.slashCommandMenuHeight)
        .overlay(alignment: .top) {
            Divider()
                .padding(.horizontal, 14)
        }
    }

    private var modelMenuHeight: CGFloat {
        guard !state.modelOptions.isEmpty else {
            return 56
        }
        return min(CGFloat(state.modelOptions.count) * 38 + 8, 240)
    }

    private var modelMenu: some View {
        ScrollView(.vertical) {
            if state.modelOptions.isEmpty {
                Text("未配置模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(state.modelOptions, id: \.selectionKey) { model in
                        Button {
                            modelMenuPresented = false
                            Task { await state.selectModel(selectionKey: model.selectionKey) }
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(model.providerName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if state.settings.selectedModel == model.selection {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
        .scrollIndicators(.visible)
        .frame(width: 280, height: modelMenuHeight)
    }

    // Inserts a Pi command and leaves the cursor ready for any command arguments.
    private func selectSlashCommand(_ command: SlashCommand) {
        state.draft = "/\(command.name) "
        selectedSlashCommandIndex = 0
        promptFocused = true
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
                        Label("返回主空间", systemImage: "house")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(state.scopeTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(width: 116, height: 28, alignment: .leading)
                .background(
                    .primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 116)
            .disabled(state.hasRunningSessions || state.sessionChanging)
            .help(state.settings.workspacePath ?? "主空间")

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
                    Text("会话记录")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(width: 116, height: 28, alignment: .leading)
                .background(
                    .primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .frame(width: 116)
            .disabled(state.sessions.isEmpty || state.sessionChanging)
            .help("查看会话记录")
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
                                            Group {
                                                if state.isSessionRunning(id: session.id) {
                                                    ProgressView()
                                                        .controlSize(.mini)
                                                } else if state.hasUnreadCompletion(id: session.id) {
                                                    Circle()
                                                        .fill(Color.blue)
                                                        .frame(width: 8, height: 8)
                                                } else {
                                                    Image(systemName: "checkmark")
                                                        .opacity(session.id == state.activeSessionID ? 1 : 0)
                                                }
                                            }
                                            .frame(width: 12, height: 12)
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
                    .disabled(state.hasRunningSessions)
                }
                .frame(width: 260)
            }

            if !state.extensionStatuses.isEmpty {
                let statusText = state.extensionStatuses.map(\.text).joined(separator: " · ")
                Label(statusText, systemImage: "puzzlepiece.extension")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                    .help(statusText)
            }

            if showSystemStatus {
                SystemStatusView()
            }

            Spacer(minLength: 0)

            Button {
                Task { await state.createSession() }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .frame(width: 30, height: 28)
            .foregroundStyle(.secondary)
            .disabled(state.activeSessionID == nil || state.runtimeStarting || state.sessionChanging)
            .help("新建会话")
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(state.conversationAnswers) { answer in
                            let tools = answer.sections.compactMap { section in
                                if case .tool(let tool) = section.content {
                                    return tool
                                }
                                return nil
                            }

                            if let question = answer.question {
                                questionView(question)
                            }

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

                            if answer.forkEntryId != nil || !answer.answerText.isEmpty {
                                HStack(spacing: 12) {
                                    if let entryId = answer.forkEntryId {
                                        Button {
                                            Task {
                                                await state.forkSession(from: entryId)
                                                promptFocused = true
                                            }
                                        } label: {
                                            Image(systemName: "arrow.triangle.branch")
                                        }
                                        .buttonStyle(.plain)
                                        .frame(width: 24, height: 24)
                                        .disabled(
                                            !state.runtimeReady
                                                || state.isBusy
                                                || state.sessionChanging
                                        )
                                        .help("从此回复分叉")
                                    }

                                    if !answer.answerText.isEmpty {
                                        Button {
                                            copy(answer.answerText)
                                        } label: {
                                            Image(systemName: "doc.on.doc")
                                        }
                                        .buttonStyle(.plain)
                                        .frame(width: 24, height: 24)
                                        .help("复制此回复")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
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

                Button {
                    state.toggleResultPanel()
                } label: {
                    Image(systemName: "chevron.up")
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
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(question.text)
                        .font(.system(size: chatMessageFontSize))
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
                Button {
                    copy(question.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
                .help("复制问题")
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

private struct SystemStatusSnapshot {
    let cpuUsage: Double?
    let memoryUsage: Double
    let usedMemory: UInt64
    let totalMemory: UInt64
    let storageUsage: Double
    let usedStorage: UInt64
    let totalStorage: UInt64
    let uptime: TimeInterval
}

private struct HostCPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

@MainActor
private final class SystemStatusMonitor: ObservableObject {
    @Published private(set) var snapshot: SystemStatusSnapshot?
    @Published private(set) var errorMessage: String?
    private var previousCPUTicks: HostCPUTicks?

    // Samples host-wide CPU, memory, and startup-volume usage for the status display.
    func refresh() {
        var cpuInfo = host_cpu_load_info_data_t()
        var cpuInfoCount = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let cpuResult = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuInfoCount)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuInfoCount)
            }
        }
        guard cpuResult == KERN_SUCCESS else {
            snapshot = nil
            errorMessage = "无法读取 CPU 状态（\(cpuResult)）"
            return
        }

        let currentCPUTicks = HostCPUTicks(
            user: cpuInfo.cpu_ticks.0,
            system: cpuInfo.cpu_ticks.1,
            idle: cpuInfo.cpu_ticks.2,
            nice: cpuInfo.cpu_ticks.3
        )
        let cpuUsage: Double?
        if let previousCPUTicks {
            let userDelta = UInt64(currentCPUTicks.user &- previousCPUTicks.user)
            let systemDelta = UInt64(currentCPUTicks.system &- previousCPUTicks.system)
            let idleDelta = UInt64(currentCPUTicks.idle &- previousCPUTicks.idle)
            let niceDelta = UInt64(currentCPUTicks.nice &- previousCPUTicks.nice)
            let totalDelta = userDelta + systemDelta + idleDelta + niceDelta
            guard totalDelta > 0 else {
                snapshot = nil
                errorMessage = "CPU 计数器未产生新数据"
                return
            }
            cpuUsage = Double(userDelta + systemDelta + niceDelta) / Double(totalDelta)
        } else {
            cpuUsage = nil
        }

        var memoryInfo = vm_statistics64_data_t()
        var memoryInfoCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let memoryResult = withUnsafeMutablePointer(to: &memoryInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(memoryInfoCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &memoryInfoCount)
            }
        }
        guard memoryResult == KERN_SUCCESS else {
            snapshot = nil
            errorMessage = "无法读取内存状态（\(memoryResult)）"
            return
        }
        guard memoryInfo.purgeable_count <= memoryInfo.internal_page_count else {
            snapshot = nil
            errorMessage = "内存统计数据不一致"
            return
        }

        // Used memory is anonymous non-purgeable memory plus wired and compressed pages.
        let usedPages = UInt64(memoryInfo.internal_page_count - memoryInfo.purgeable_count)
            + UInt64(memoryInfo.wire_count)
            + UInt64(memoryInfo.compressor_page_count)
        let memoryProduct = usedPages.multipliedReportingOverflow(by: UInt64(vm_kernel_page_size))
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        guard !memoryProduct.overflow, memoryProduct.partialValue <= totalMemory else {
            snapshot = nil
            errorMessage = "内存统计数据超出物理内存"
            return
        }

        let storageAttributes: [FileAttributeKey: Any]
        do {
            storageAttributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
        } catch {
            snapshot = nil
            errorMessage = "无法读取磁盘状态：\(error.localizedDescription)"
            return
        }
        guard let totalStorage = (storageAttributes[.systemSize] as? NSNumber)?.uint64Value,
              let freeStorage = (storageAttributes[.systemFreeSize] as? NSNumber)?.uint64Value,
              totalStorage > 0,
              freeStorage <= totalStorage else {
            snapshot = nil
            errorMessage = "磁盘统计数据不一致"
            return
        }
        let usedStorage = totalStorage - freeStorage

        previousCPUTicks = currentCPUTicks
        snapshot = SystemStatusSnapshot(
            cpuUsage: cpuUsage,
            memoryUsage: Double(memoryProduct.partialValue) / Double(totalMemory),
            usedMemory: memoryProduct.partialValue,
            totalMemory: totalMemory,
            storageUsage: Double(usedStorage) / Double(totalStorage),
            usedStorage: usedStorage,
            totalStorage: totalStorage,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        errorMessage = nil
    }
}

private struct SystemStatusView: View {
    @StateObject private var monitor = SystemStatusMonitor()
    @State private var detailsPresented = false
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Button {
            detailsPresented.toggle()
        } label: {
            Group {
                if let snapshot = monitor.snapshot {
                    let memoryText = snapshot.memoryUsage.formatted(
                        .percent.precision(.fractionLength(0))
                    )
                    let storageText = snapshot.storageUsage.formatted(
                        .percent.precision(.fractionLength(0))
                    )
                    Group {
                        if let cpuUsage = snapshot.cpuUsage {
                            let cpuText = cpuUsage.formatted(
                                .percent.precision(.fractionLength(0))
                            )
                            Text("CPU \(cpuText) · 内存 \(memoryText) · 磁盘 \(storageText)")
                        } else {
                            Text("CPU 采集中 · 内存 \(memoryText) · 磁盘 \(storageText)")
                        }
                    }
                    .foregroundStyle(.secondary)
                } else if let errorMessage = monitor.errorMessage {
                    Text("系统状态读取失败")
                        .foregroundStyle(.red)
                        .help(errorMessage)
                } else {
                    Text("系统状态采集中")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: 190, height: 28, alignment: .leading)
            .background(
                .primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .frame(width: 190)
        .help("查看系统状态详情")
        .popover(isPresented: $detailsPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Label("系统状态", systemImage: "gauge")
                    .font(.headline)

                if let snapshot = monitor.snapshot {
                    let uptimeMinutes = Int(snapshot.uptime / 60)
                    let systemVersion = ProcessInfo.processInfo.operatingSystemVersion
                    let memoryText = snapshot.memoryUsage.formatted(
                        .percent.precision(.fractionLength(0))
                    )
                    let storageText = snapshot.storageUsage.formatted(
                        .percent.precision(.fractionLength(0))
                    )

                    LabeledContent("CPU") {
                        if let cpuUsage = snapshot.cpuUsage {
                            Text(cpuUsage, format: .percent.precision(.fractionLength(0)))
                        } else {
                            Text("采集中")
                        }
                    }
                    LabeledContent("内存") {
                        Text(
                            "\(memoryText) · "
                                + "\(snapshot.usedMemory.formatted(.byteCount(style: .memory))) / "
                                + snapshot.totalMemory.formatted(.byteCount(style: .memory))
                        )
                    }
                    LabeledContent("磁盘") {
                        Text(
                            "\(storageText) · "
                                + "\(snapshot.usedStorage.formatted(.byteCount(style: .file))) / "
                                + snapshot.totalStorage.formatted(.byteCount(style: .file))
                        )
                    }

                    Divider()

                    LabeledContent("处理器核心", value: "\(ProcessInfo.processInfo.activeProcessorCount) 个")
                    LabeledContent("系统运行") {
                        Text(
                            uptimeMinutes >= 1_440
                                ? "\(uptimeMinutes / 1_440) 天 \((uptimeMinutes % 1_440) / 60) 小时"
                                : "\(uptimeMinutes / 60) 小时 \(uptimeMinutes % 60) 分钟"
                        )
                    }
                    LabeledContent("操作系统") {
                        Text(
                            "macOS \(systemVersion.majorVersion)."
                                + "\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
                        )
                    }
                } else if let errorMessage = monitor.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else {
                    Text("采集中")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .monospacedDigit()
            .padding(16)
            .frame(width: 330)
        }
        .onAppear {
            monitor.refresh()
        }
        .onReceive(refreshTimer) { _ in
            monitor.refresh()
        }
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
        case .extensionMessage(let text):
            AnswerMarkdownView(source: text)
        case .customMessage(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("[\(message.customType)]")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                switch message.content {
                case .string(let content):
                    AnswerMarkdownView(source: content)
                default:
                    Text(message.content.formattedJSON)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                switch message.qrCode {
                case .absent:
                    EmptyView()
                case .invalid:
                    Label("插件提供的 details.qrUrl 无效", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                case .url(let qrURL):
                    let qrImage: CGImage? = {
                        let filter = CIFilter.qrCodeGenerator()
                        filter.message = Data(qrURL.absoluteString.utf8)
                        filter.correctionLevel = "M"
                        guard let output = filter.outputImage else {
                            return nil
                        }
                        let scale = max(CGFloat(1), floor(220 / output.extent.width))
                        let scaled = output.transformed(
                            by: CGAffineTransform(scaleX: scale, y: scale)
                        )
                        return qrCodeContext.createCGImage(scaled, from: scaled.extent)
                    }()

                    if let qrImage {
                        Image(decorative: qrImage, scale: 1)
                            .interpolation(.none)
                            .padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.primary.opacity(0.12))
                            }
                            .accessibilityLabel("登录二维码")
                    } else {
                        Label("无法生成二维码", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Link(destination: qrURL) {
                        Label("打开备用地址", systemImage: "arrow.up.right.square")
                    }
                    .font(.caption)
                }
                if let details = message.details {
                    DisclosureGroup {
                        Text(details.formattedJSON)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    } label: {
                        Text("插件详情")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .extensionNotification(let notification):
            let presentation: (color: Color, symbol: String) = switch notification.kind {
            case .info:
                (Color.accentColor, "info.circle.fill")
            case .warning:
                (.orange, "exclamationmark.triangle.fill")
            case .error:
                (.red, "xmark.circle.fill")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(presentation.color)
                AnswerMarkdownView(source: notification.message)
            }
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
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(9)
                    .padding(.trailing, 30)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .foregroundStyle(.secondary)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .padding(5)
            .help("复制内容")
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
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
