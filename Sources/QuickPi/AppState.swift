import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    private struct SessionExecution {
        var previousAnswers: [AnswerSession] = []
        var answer: AnswerSession?
        var resultPresented = false
        var draft = ""
        var attachments: [PendingAttachment] = []
        var runtimeError: String?
        var extensionCommandRunning = false
        var agentRunning = false
        var extensionStatuses: [ExtensionStatus] = []
        var extensionWidgets: [ExtensionWidget] = []
        var extensionTitle: String?
        var extensionPrompt: ExtensionPrompt?
        var answerGeneration = 0
        var unreadCompletion = false
        var conversationLoaded = false

        var isAnswering: Bool {
            answer?.status == .waiting || answer?.status == .running
        }

        var isBusy: Bool {
            isAnswering || extensionCommandRunning || agentRunning
        }

        var conversationAnswers: [AnswerSession] {
            previousAnswers + (answer.map { [$0] } ?? [])
        }
    }

    private static let nativeSlashCommands = [
        SlashCommand(name: "new", description: "新建会话", source: .app),
        SlashCommand(name: "settings", description: "打开设置", source: .app),
        SlashCommand(name: "copy", description: "复制最近回答", source: .app),
        SlashCommand(name: "name", description: "设置当前会话名称", source: .app),
        SlashCommand(name: "session", description: "查看当前会话统计", source: .app),
        SlashCommand(name: "compact", description: "压缩当前会话上下文", source: .app),
        SlashCommand(name: "clone", description: "克隆当前会话", source: .app),
        SlashCommand(name: "export", description: "导出当前会话为 HTML", source: .app),
    ]

    @Published private(set) var settings: AppSettings
    @Published private(set) var builtInProviders: [ProviderStatus] = []
    @Published private(set) var builtInModels: [ModelOption] = []
    @Published private(set) var slashCommands = AppState.nativeSlashCommands
    @Published private(set) var sessions: [ConversationSession] = []
    @Published private(set) var activeSessionID: String?
    @Published private(set) var sessionChanging = false
    @Published var shortcutError: String?
    @Published var authSession: AuthSession?
    @Published private var sessionExecutions: [String: SessionExecution] = [:]
    @Published private var readySessionIDs: Set<String> = []
    @Published private var startingSessionIDs: Set<String> = []
    @Published private var initialRuntimeStarting = false
    @Published private var pendingDraft = ""
    @Published private var pendingAttachments: [PendingAttachment] = []
    @Published private var startupRuntimeError: String?
    @Published private var startupResultPresented = false

    private let store: ConfigurationStore
    private let applicationSupportDirectory: URL
    let checkForUpdates: () -> Void
    let presentSettings: () -> Void
    private var runtimes: [String: PiRuntime] = [:]
    private var unboundRuntimes: [ObjectIdentifier: PiRuntime] = [:]
    private var runtimeSessionIDs: [ObjectIdentifier: String] = [:]
    private var pendingRuntimeEvents: [ObjectIdentifier: [PiRuntimeEvent]] = [:]
    private var runtimeGeneration = 0

    var applyShortcut: ((String) throws -> Void)?
    var panelContentChanged: (() -> Void)?

    var providerOptions: [ProviderStatus] {
        let customIds = Set(settings.providers.map(\.id))
        let custom = settings.providers.map {
            ProviderStatus(
                id: $0.id,
                name: $0.name,
                configured: true,
                supportsAPIKeyLogin: false,
                supportsOAuthLogin: false
            )
        }
        return custom + builtInProviders.filter { !customIds.contains($0.id) }
    }

    var modelOptions: [ModelOption] {
        let customIds = Set(settings.providers.map(\.id))
        let authorizedProviderIds = Set(
            builtInProviders.filter { $0.configured }.map(\.id)
        )
        let custom = settings.providers.flatMap { provider in
            provider.models.map {
                ModelOption(
                    id: $0,
                    name: $0,
                    providerId: provider.id,
                    providerName: provider.name,
                    supportsImages: true
                )
            }
        }
        return custom + builtInModels.filter {
            !customIds.contains($0.providerId) && authorizedProviderIds.contains($0.providerId)
        }
    }

    var selectedModel: ModelOption? {
        guard let selection = settings.selectedModel else {
            return nil
        }
        return modelOptions.first {
            $0.providerId == selection.providerId && $0.id == selection.modelId
        }
    }

    var runtimeReady: Bool {
        activeSessionID.map(readySessionIDs.contains) ?? false
    }

    var runtimeStarting: Bool {
        initialRuntimeStarting || activeSessionID.map(startingSessionIDs.contains) == true
    }

    var extensionCommandRunning: Bool {
        activeSessionID.flatMap { sessionExecutions[$0] }?.extensionCommandRunning ?? false
    }

    var previousAnswers: [AnswerSession] {
        activeSessionID.flatMap { sessionExecutions[$0] }?.previousAnswers ?? []
    }

    var answer: AnswerSession? {
        activeSessionID.flatMap { sessionExecutions[$0] }?.answer
    }

    var resultPresented: Bool {
        activeSessionID.flatMap { sessionExecutions[$0] }?.resultPresented ?? startupResultPresented
    }

    var draft: String {
        get {
            activeSessionID.flatMap { sessionExecutions[$0] }?.draft ?? pendingDraft
        }
        set {
            guard let sessionID = activeSessionID else {
                pendingDraft = newValue
                notifyPanel()
                return
            }
            updateSession(sessionID) { $0.draft = newValue }
            notifyPanel()
        }
    }

    var attachments: [PendingAttachment] {
        activeSessionID.flatMap { sessionExecutions[$0] }?.attachments ?? pendingAttachments
    }

    var runtimeError: String? {
        get {
            activeSessionID.flatMap { sessionExecutions[$0] }?.runtimeError ?? startupRuntimeError
        }
        set {
            setRuntimeError(newValue, sessionID: activeSessionID)
        }
    }

    var extensionStatuses: [ExtensionStatus] {
        activeSessionID.flatMap { sessionExecutions[$0] }?.extensionStatuses ?? []
    }

    var extensionWidgets: [ExtensionWidget] {
        activeSessionID.flatMap { sessionExecutions[$0] }?.extensionWidgets ?? []
    }

    var extensionTitle: String? {
        activeSessionID.flatMap { sessionExecutions[$0] }?.extensionTitle
    }

    var extensionPrompt: ExtensionPrompt? {
        activeSessionID.flatMap { sessionExecutions[$0] }?.extensionPrompt
    }

    // Offers commands only while the command name is being entered, before arguments begin.
    var slashCommandSuggestions: [SlashCommand] {
        guard draft.first == "/" else {
            return []
        }
        let query = String(draft.dropFirst())
        guard !query.contains(where: { $0.isWhitespace }) else {
            return []
        }
        guard !query.isEmpty else {
            return slashCommands
        }
        return slashCommands.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var draftMatchesSlashCommand: Bool {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return slashCommands.contains {
            "/\($0.name)".caseInsensitiveCompare(value) == .orderedSame
        }
    }

    var isAnswering: Bool {
        activeSessionID.flatMap { sessionExecutions[$0] }?.isAnswering ?? false
    }

    var isBusy: Bool {
        activeSessionID.flatMap { sessionExecutions[$0] }?.isBusy ?? false
    }

    var hasRunningSessions: Bool {
        sessionExecutions.values.contains(where: \.isBusy)
    }

    var conversationAnswers: [AnswerSession] {
        activeSessionID.flatMap { sessionExecutions[$0] }?.conversationAnswers ?? []
    }

    var activeSession: ConversationSession? {
        guard let activeSessionID else {
            return nil
        }
        return sessions.first { $0.id == activeSessionID }
    }

    var scopeTitle: String {
        settings.workspaceURL?.lastPathComponent ?? "主空间"
    }

    func title(for session: ConversationSession) -> String {
        if session.firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let question = sessionExecutions[session.id]?.conversationAnswers.compactMap({ $0.question?.text }).first {
            return question
        }
        return session.title
    }

    // Reports whether one session still owns a prompt or extension command.
    func isSessionRunning(id: String) -> Bool {
        sessionExecutions[id]?.isBusy ?? false
    }

    // Reports a background completion until the user opens that session.
    func hasUnreadCompletion(id: String) -> Bool {
        sessionExecutions[id]?.unreadCompletion ?? false
    }

    // Matches the fixed SwiftUI bands used by the input bar so AppKit can resize without clipping plugin UI.
    var inputBarHeight: CGFloat {
        var height: CGFloat = attachments.isEmpty ? 102 : 140
        for widget in extensionWidgets {
            height += CGFloat(widget.lines.count * 16 + 12)
        }
        return height
    }

    // Sizes the command list as body content independently from the editor band.
    var slashCommandMenuHeight: CGFloat {
        guard !slashCommandSuggestions.isEmpty else {
            return 0
        }
        return min(CGFloat(slashCommandSuggestions.count) * 44 + 9, 185)
    }

    var hasResultPanelContent: Bool {
        runtimeError != nil || !conversationAnswers.isEmpty
    }

    var showsResultPanel: Bool {
        resultPresented && hasResultPanelContent
    }

    // Loads the settings document and binds desktop actions plus managed Pi process events.
    init(
        applicationSupportDirectory: URL,
        checkForUpdates: @escaping () -> Void,
        presentSettings: @escaping () -> Void
    ) throws {
        self.applicationSupportDirectory = applicationSupportDirectory
        store = ConfigurationStore(applicationSupportDirectory: applicationSupportDirectory)
        settings = try store.load()
        self.checkForUpdates = checkForUpdates
        self.presentSettings = presentSettings
    }

    // Generates Pi configuration, starts the process, and restores the persisted model.
    func start() async {
        runtimeGeneration += 1
        await launchRuntime(generation: runtimeGeneration)
    }

    // Persists the selected model first, then applies that exact disk selection to Pi.
    func selectModel(selectionKey: String) async {
        guard let model = modelOptions.first(where: { $0.selectionKey == selectionKey }) else {
            runtimeError = "所选模型不存在"
            notifyPanel()
            return
        }
        guard runtimeReady else {
            runtimeError = "Pi 尚未就绪"
            notifyPanel()
            return
        }
        guard !hasRunningSessions else {
            runtimeError = "仍有会话正在执行任务，不能切换模型"
            notifyPanel()
            return
        }
        do {
            var next = settings
            next.selectedModel = model.selection
            settings = try store.save(next)
            notifyPanel()
            do {
                for runtime in runtimes.values {
                    try await runtime.selectModel(model.selection)
                }
                runtimeError = nil
            } catch {
                runtimeError = error.localizedDescription
                scheduleRuntimeRestart()
            }
        } catch {
            runtimeError = error.localizedDescription
        }
        notifyPanel()
    }

    // Reads explicitly selected files and appends them in the same order.
    func addAttachments(urls: [URL]) async {
        guard attachments.count + urls.count <= 5 else {
            runtimeError = "一次最多添加 5 个附件"
            notifyPanel()
            return
        }
        do {
            var loaded = attachments
            for url in urls {
                loaded.append(try AttachmentLoader.load(url: url))
            }
            if let sessionID = activeSessionID {
                updateSession(sessionID) { $0.attachments = loaded }
            } else {
                pendingAttachments = loaded
            }
            runtimeError = nil
        } catch {
            runtimeError = error.localizedDescription
        }
        notifyPanel()
    }

    // Removes one attachment before the question is submitted.
    func removeAttachment(id: UUID) {
        if let sessionID = activeSessionID {
            updateSession(sessionID) { execution in
                execution.attachments.removeAll { $0.id == id }
            }
        } else {
            pendingAttachments.removeAll { $0.id == id }
        }
        notifyPanel()
    }

    // Persists the explicitly selected project root and restarts Pi in that directory.
    func setWorkspace(_ url: URL?) {
        guard !hasRunningSessions else {
            runtimeError = "仍有会话正在执行任务，不能切换工作区"
            notifyPanel()
            return
        }
        guard !sessionChanging else {
            runtimeError = "会话切换期间不能切换工作区"
            notifyPanel()
            return
        }

        do {
            var next = settings
            if let url {
                let workspaceURL = url.standardizedFileURL.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: workspaceURL.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    throw QuickPiError.message("所选工作区不是有效目录")
                }
                next.workspacePath = workspaceURL.path
            } else {
                next.workspacePath = nil
            }
            settings = try store.save(next)
            runtimeError = nil
            scheduleRuntimeRestart()
        } catch {
            runtimeError = error.localizedDescription
            notifyPanel()
        }
    }

    // Submits one command or model prompt to the runtime permanently bound to the visible session.
    func send() async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            runtimeError = "请输入问题"
            notifyPanel()
            return
        }
        guard runtimeReady else {
            runtimeError = "Pi 尚未就绪"
            notifyPanel()
            return
        }
        guard !sessionChanging else {
            runtimeError = "会话正在切换"
            notifyPanel()
            return
        }
        guard !isBusy else {
            return
        }
        guard let sessionID = activeSessionID, let runtime = runtimes[sessionID] else {
            runtimeError = "当前会话没有可用的 Pi 进程"
            notifyPanel()
            return
        }
        let commandParts = question.hasPrefix("/")
            ? question.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            : []
        let commandName = commandParts.first.map(String.init)
        let commandArguments = commandParts.count == 2
            ? String(commandParts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if let commandName,
           Self.nativeSlashCommands.contains(where: { $0.name == commandName }) {
            guard attachments.isEmpty else {
                runtimeError = "应用命令不接受附件"
                notifyPanel()
                return
            }
            switch commandName {
            case "settings":
                updateSession(sessionID) { $0.draft = "" }
                presentSettings()
                return
            case "new":
                updateSession(sessionID) { $0.draft = "" }
                await createSession()
                return
            case "copy":
                guard let text = conversationAnswers.reversed().first(where: {
                    $0.question?.text != "/copy" && !$0.answerText.isEmpty
                })?.answerText else {
                    runtimeError = "没有可复制的回答"
                    notifyPanel()
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                presentCommandResult(
                    question: question,
                    markdown: "已复制最近回答。",
                    sessionID: sessionID
                )
                return
            default:
                break
            }

            if commandName == "clone" {
                sessionChanging = true
                setRuntimeError(nil, sessionID: sessionID)
                notifyPanel()
                do {
                    let result = try await runtime.cloneSession()
                    guard !result.cancelled else {
                        throw QuickPiError.message("插件取消了会话克隆")
                    }
                    let snapshot = try await runtime.sessionSnapshot()
                    try validateSessionSnapshot(snapshot)
                    try applySessionSnapshot(snapshot)
                    rebindRuntime(runtime, from: sessionID, to: snapshot.activeSessionId)
                    presentCommandResult(
                        question: question,
                        markdown: "已克隆当前会话。",
                        sessionID: snapshot.activeSessionId
                    )
                } catch {
                    setRuntimeError(error.localizedDescription, sessionID: sessionID)
                }
                sessionChanging = false
                notifyPanel()
                return
            }

            let configurationGeneration = runtimeGeneration
            let generation = beginAnswer(
                sessionID: sessionID,
                question: question,
                attachmentNames: [],
                status: .running
            )
            updateSession(sessionID) { $0.extensionCommandRunning = true }
            notifyPanel()
            do {
                let markdown: String
                switch commandName {
                case "name":
                    guard !commandArguments.isEmpty else {
                        throw QuickPiError.message("用法：/name 会话名称")
                    }
                    try await runtime.setSessionName(commandArguments)
                    let snapshot = try await runtime.sessionSnapshot()
                    try validateSessionSnapshot(snapshot)
                    applySessionList(snapshot.sessions)
                    markdown = "当前会话已命名为 **\(commandArguments)**。"
                case "session":
                    let stats = try await runtime.sessionStats()
                    var lines = [
                        "## 会话统计",
                        "- 用户消息：\(stats.userMessages)",
                        "- 助手消息：\(stats.assistantMessages)",
                        "- 工具调用：\(stats.toolCalls)",
                        "- 总 Token：\(stats.tokens.total.formatted())",
                        "- 费用：$\(stats.cost.formatted(.number.precision(.fractionLength(4))))",
                    ]
                    if let context = stats.contextUsage {
                        let tokens = context.tokens?.formatted() ?? "尚无数据"
                        let percent = context.percent.map {
                            $0.formatted(.number.precision(.fractionLength(1))) + "%"
                        } ?? "尚无数据"
                        lines.append("- 当前上下文：\(tokens) / \(context.contextWindow.formatted())（\(percent)）")
                    }
                    markdown = lines.joined(separator: "\n")
                case "compact":
                    let result = try await runtime.compact(
                        instructions: commandArguments.isEmpty ? nil : commandArguments
                    )
                    markdown = """
                    上下文压缩完成：\(result.tokensBefore.formatted()) → 约 \(result.estimatedTokensAfter.formatted()) Token。

                    ## 摘要

                    \(result.summary)
                    """
                case "export":
                    let result = try await runtime.exportHTML()
                    markdown = "会话已导出到：\n\n`\(result.path)`"
                default:
                    throw QuickPiError.message("未知的应用命令：/\(commandName)")
                }
                guard configurationGeneration == runtimeGeneration,
                      runtimes[sessionID] === runtime,
                      sessionExecutions[sessionID]?.answerGeneration == generation else {
                    return
                }
                updateSession(sessionID) { execution in
                    execution.answer?.sections.append(AnswerSection(
                        id: UUID(),
                        content: .extensionMessage(markdown)
                    ))
                    execution.answer?.status = .completed
                    execution.extensionCommandRunning = false
                }
                finishSessionExecution(sessionID)
            } catch {
                guard sessionExecutions[sessionID]?.answerGeneration == generation else {
                    return
                }
                updateSession(sessionID) { execution in
                    execution.answer?.status = .failed
                    execution.answer?.error = error.localizedDescription
                    execution.extensionCommandRunning = false
                }
                finishSessionExecution(sessionID)
            }
            notifyPanel()
            return
        }
        let isExtensionCommand = slashCommands.contains {
            $0.source == .extension && $0.name == commandName
        }
        let model = selectedModel
        guard isExtensionCommand || model != nil else {
            presentSettings()
            runtimeError = "请先配置 Provider 并选择模型"
            notifyPanel()
            return
        }
        let submittedAttachments = attachments
        let images = submittedAttachments.compactMap { attachment -> ImagePayload? in
            if case let .image(data, mimeType) = attachment.content {
                return ImagePayload(data: data.base64EncodedString(), mimeType: mimeType)
            }
            return nil
        }
        if let model, !images.isEmpty && !model.supportsImages {
            runtimeError = "\(model.name) 不支持图片输入"
            notifyPanel()
            return
        }
        let documentSections = submittedAttachments.compactMap { attachment -> String? in
            if case let .text(text) = attachment.content {
                return "附件：\(attachment.name)\n\n\(text)"
            }
            return nil
        }
        let prompt = documentSections.isEmpty
            ? question
            : "\(question)\n\n---\n\n\(documentSections.joined(separator: "\n\n---\n\n"))"
        let attachmentNames = submittedAttachments.map(\.name)

        if isExtensionCommand {
            let runtimeGeneration = self.runtimeGeneration
            let answerGeneration = beginAnswer(
                sessionID: sessionID,
                question: question,
                attachmentNames: attachmentNames,
                status: .running
            )
            updateSession(sessionID) { $0.extensionCommandRunning = true }
            notifyPanel()
            do {
                try await runtime.prompt(message: prompt, images: images)
                guard runtimeGeneration == self.runtimeGeneration,
                      runtimes[sessionID] === runtime,
                      sessionExecutions[sessionID]?.answerGeneration == answerGeneration else {
                    return
                }
                let snapshot = try await runtime.snapshot()
                guard runtimeGeneration == self.runtimeGeneration,
                      runtimes[sessionID] === runtime,
                      sessionExecutions[sessionID]?.answerGeneration == answerGeneration else {
                    return
                }
                let customIds = Set(settings.providers.map(\.id))
                builtInProviders = snapshot.providers.filter { !customIds.contains($0.id) }
                builtInModels = snapshot.models.filter { !customIds.contains($0.providerId) }
                let nativeNames = Set(Self.nativeSlashCommands.map(\.name))
                slashCommands = Self.nativeSlashCommands + snapshot.commands.filter {
                    !nativeNames.contains($0.name)
                }
                updateSession(sessionID) { execution in
                    execution.extensionCommandRunning = false
                    if !execution.agentRunning,
                       execution.answer?.status == .waiting || execution.answer?.status == .running {
                        execution.answer?.status = .completed
                    }
                }
            } catch {
                guard runtimeGeneration == self.runtimeGeneration,
                      sessionExecutions[sessionID]?.answerGeneration == answerGeneration else {
                    return
                }
                updateSession(sessionID) { execution in
                    execution.extensionCommandRunning = false
                    execution.answer?.status = .failed
                    execution.answer?.error = error.localizedDescription
                }
            }
            finishSessionExecution(sessionID)
            notifyPanel()
            return
        }

        let generation = beginAnswer(
            sessionID: sessionID,
            question: question,
            attachmentNames: attachmentNames,
            status: .waiting
        )
        notifyPanel()

        do {
            try await runtime.prompt(message: prompt, images: images)
            guard runtimes[sessionID] === runtime,
                  sessionExecutions[sessionID]?.answerGeneration == generation else {
                return
            }
        } catch {
            guard sessionExecutions[sessionID]?.answerGeneration == generation else {
                return
            }
            updateSession(sessionID) { execution in
                execution.answer?.status = .failed
                execution.answer?.error = error.localizedDescription
            }
            finishSessionExecution(sessionID)
            notifyPanel()
        }
    }

    // Stops the current answer and leaves completed content available for copying.
    func abort() async {
        guard let sessionID = activeSessionID, let runtime = runtimes[sessionID] else {
            return
        }
        updateSession(sessionID) { $0.answerGeneration += 1 }
        let generation = sessionExecutions[sessionID]?.answerGeneration
        do {
            if let prompt = extensionPrompt {
                try runtime.respondToExtensionPrompt(requestId: prompt.requestId, cancelled: true)
                updateSession(sessionID) { $0.extensionPrompt = nil }
            }
            try await runtime.abort()
            guard generation == sessionExecutions[sessionID]?.answerGeneration else {
                return
            }
            updateSession(sessionID) { execution in
                execution.answer?.status = .stopped
                execution.answer?.retryMessage = nil
                execution.agentRunning = false
                execution.extensionCommandRunning = false
            }
        } catch {
            guard generation == sessionExecutions[sessionID]?.answerGeneration else {
                return
            }
            updateSession(sessionID) { execution in
                execution.answer?.status = .failed
                execution.answer?.error = error.localizedDescription
                execution.agentRunning = false
                execution.extensionCommandRunning = false
            }
        }
        finishSessionExecution(sessionID)
        notifyPanel()
    }

    // Expands or collapses result content without cancelling the active answer.
    func toggleResultPanel() {
        guard hasResultPanelContent else {
            return
        }
        if let sessionID = activeSessionID {
            updateSession(sessionID) { $0.resultPresented.toggle() }
        } else {
            startupResultPresented.toggle()
        }
        notifyPanel()
    }

    // Creates a persistent empty session in the current main-directory or workspace scope.
    func createSession() async {
        guard activeSessionID != nil, !sessionChanging, !initialRuntimeStarting else {
            return
        }
        sessionChanging = true
        let previousSessionID = activeSessionID
        setRuntimeError(nil, sessionID: previousSessionID)
        let sessionID = UUID().uuidString
        let runtime = makeRuntime()
        sessionExecutions[sessionID] = SessionExecution()
        startingSessionIDs.insert(sessionID)
        notifyPanel()
        do {
            let modelError = try await startRuntime(runtime, session: .new(id: sessionID))
            let snapshot = try await runtime.sessionSnapshot()
            try validateSessionSnapshot(snapshot)
            guard snapshot.activeSessionId == sessionID else {
                throw QuickPiError.message("Pi 创建的会话与请求不一致")
            }
            try applySessionSnapshot(snapshot)
            bindRuntime(runtime, to: sessionID)
            if runtimes[sessionID] === runtime {
                readySessionIDs.insert(sessionID)
            }
            startingSessionIDs.remove(sessionID)
            updateSession(sessionID) { execution in
                execution.resultPresented = modelError != nil
                execution.runtimeError = modelError
            }
            if let previousSessionID {
                pruneRuntimeIfIdle(sessionID: previousSessionID)
            }
        } catch {
            removeRuntime(runtime, stopping: true)
            sessionExecutions.removeValue(forKey: sessionID)
            setRuntimeError(error.localizedDescription, sessionID: previousSessionID)
        }
        sessionChanging = false
        notifyPanel()
    }

    // Opens a session through its own RPC process without interrupting work in other sessions.
    func switchSession(id: String) async {
        guard !sessionChanging, !initialRuntimeStarting else {
            return
        }
        if id == activeSessionID, readySessionIDs.contains(id) {
            return
        }
        guard let target = sessions.first(where: { $0.id == id }) else {
            runtimeError = "所选会话不属于当前目录"
            notifyPanel()
            return
        }
        let previousSessionID = activeSessionID
        if sessionExecutions[id] == nil {
            sessionExecutions[id] = SessionExecution()
        }
        activeSessionID = id
        updateSession(id) { $0.unreadCompletion = false }
        if readySessionIDs.contains(id), runtimes[id] != nil {
            if let previousSessionID, previousSessionID != id {
                pruneRuntimeIfIdle(sessionID: previousSessionID)
            }
            notifyPanel()
            return
        }

        sessionChanging = true
        setRuntimeError(nil, sessionID: id)
        let runtime = makeRuntime()
        startingSessionIDs.insert(id)
        notifyPanel()
        do {
            let modelError = try await startRuntime(runtime, session: .existing(path: target.path))
            let snapshot = try await runtime.sessionSnapshot()
            try validateSessionSnapshot(snapshot)
            guard snapshot.activeSessionId == target.id,
                  snapshot.activeSessionPath == target.path else {
                throw QuickPiError.message("Pi 切换后的会话与所选会话不一致")
            }
            try applySessionSnapshot(snapshot, preservingInput: true)
            bindRuntime(runtime, to: id)
            if runtimes[id] === runtime {
                readySessionIDs.insert(id)
            }
            startingSessionIDs.remove(id)
            if let modelError {
                setRuntimeError(modelError, sessionID: id)
            }
            if let previousSessionID, previousSessionID != id {
                pruneRuntimeIfIdle(sessionID: previousSessionID)
            }
        } catch {
            removeRuntime(runtime, stopping: true)
            setRuntimeError(error.localizedDescription, sessionID: id)
        }
        sessionChanging = false
        notifyPanel()
    }

    // Creates a new Pi session before one persisted prompt and restores that prompt for editing.
    func forkSession(from entryId: String) async {
        guard runtimeReady, !isBusy, !sessionChanging else {
            return
        }
        guard let sessionID = activeSessionID, let runtime = runtimes[sessionID] else {
            return
        }
        sessionChanging = true
        setRuntimeError(nil, sessionID: sessionID)
        notifyPanel()
        do {
            let result = try await runtime.fork(entryId: entryId)
            if result.cancelled {
                sessionChanging = false
                setRuntimeError("会话分叉已取消", sessionID: sessionID)
                notifyPanel()
                return
            }
            let snapshot = try await runtime.sessionSnapshot()
            try validateSessionSnapshot(snapshot)
            guard snapshot.activeSessionId != sessionID else {
                throw QuickPiError.message("Pi 没有创建分叉会话")
            }
            try applySessionSnapshot(snapshot)
            rebindRuntime(runtime, from: sessionID, to: snapshot.activeSessionId)
            readySessionIDs.insert(snapshot.activeSessionId)
            updateSession(snapshot.activeSessionId) { $0.draft = result.text }
        } catch {
            removeRuntime(runtime, stopping: true)
            setRuntimeError(error.localizedDescription, sessionID: sessionID)
        }
        sessionChanging = false
        notifyPanel()
    }

    // Deletes normal and workspace sessions, leaving one new empty session in the current scope.
    func deleteAllSessions() async {
        guard runtimeReady, !hasRunningSessions, !sessionChanging else {
            return
        }
        guard let sessionID = activeSessionID, let runtime = runtimes[sessionID] else {
            return
        }
        sessionChanging = true
        setRuntimeError(nil, sessionID: sessionID)
        for otherSessionID in Array(runtimes.keys) where otherSessionID != sessionID {
            removeRuntime(sessionID: otherSessionID, stopping: true)
        }
        notifyPanel()
        do {
            let snapshot = try await runtime.deleteAllSessions()
            try validateSessionSnapshot(snapshot)
            guard snapshot.sessions.count == 1 else {
                throw QuickPiError.message("删除后当前目录仍存在旧会话")
            }
            try applySessionSnapshot(snapshot)
            rebindRuntime(runtime, from: sessionID, to: snapshot.activeSessionId)
            readySessionIDs = [snapshot.activeSessionId]
            if let execution = sessionExecutions[snapshot.activeSessionId] {
                sessionExecutions = [snapshot.activeSessionId: execution]
            }
            updateSession(snapshot.activeSessionId) { $0.resultPresented = false }
        } catch {
            sessionChanging = false
            scheduleRuntimeRestart(reporting: error.localizedDescription)
            return
        }
        sessionChanging = false
        notifyPanel()
    }

    // Saves the desktop shortcut and login-item settings immediately.
    func saveDesktopSettings(
        shortcut: String,
        launchAtLogin: Bool
    ) async throws {
        if shortcut != settings.shortcut {
            try applyShortcut?(shortcut)
            shortcutError = nil
        }
        if launchAtLogin != settings.launchAtLogin {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        }

        var next = settings
        next.shortcut = shortcut
        next.launchAtLogin = launchAtLogin
        settings = try store.save(next)
    }

    // Fetches a model catalog directly from the configured OpenAI or Anthropic-compatible endpoint.
    func syncModels(
        kind: ProviderKind,
        baseURL: String,
        apiKey: String,
        providerId: String
    ) async throws -> [String] {
        var key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            guard settings.providers.contains(where: { $0.id == providerId }) else {
                throw QuickPiError.message("请输入 API Key")
            }
            key = try store.loadAPIKey(providerId: providerId)
        }
        var url = try validatedBaseURL(baseURL)
        if kind == .claudeCode && url.pathComponents.last != "v1" {
            url.append(path: "v1")
        }
        url.append(path: "models")

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        switch kind {
        case .openAI:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .claudeCode:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuickPiError.message("同步模型失败：Provider 没有返回 HTTP 响应")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw QuickPiError.message(
                detail.isEmpty
                    ? "同步模型失败：HTTP \(httpResponse.statusCode)"
                    : "同步模型失败：HTTP \(httpResponse.statusCode)\n\(detail)"
            )
        }
        let catalog = try JSONDecoder().decode(ModelCatalogResponse.self, from: data)
        let models = Array(Set(catalog.data.map(\.id))).sorted()
        guard !models.isEmpty else {
            throw QuickPiError.message("Provider 没有返回可用模型")
        }
        return models
    }

    // Writes the custom Provider, key, generated Pi models, and selected model before restarting Pi.
    func saveProvider(
        _ provider: ProviderConfiguration,
        apiKey: String,
        selectedModelId: String
    ) throws {
        guard !hasRunningSessions else {
            throw QuickPiError.message("仍有会话正在执行任务，不能修改 Provider")
        }
        let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw QuickPiError.message("Provider 名称不能为空")
        }
        let baseURL = try validatedBaseURL(provider.baseURL).absoluteString
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isExistingProvider = settings.providers.contains { $0.id == provider.id }
        if key.isEmpty {
            guard isExistingProvider else {
                throw QuickPiError.message("请输入 API Key")
            }
            _ = try store.loadAPIKey(providerId: provider.id)
        }
        guard provider.models.contains(selectedModelId) else {
            throw QuickPiError.message("请选择已同步的模型")
        }

        let storedProvider = ProviderConfiguration(
            id: provider.id,
            kind: provider.kind,
            name: name,
            baseURL: baseURL,
            models: provider.models
        )
        var next = settings
        if let index = next.providers.firstIndex(where: { $0.id == storedProvider.id }) {
            next.providers[index] = storedProvider
        } else {
            next.providers.append(storedProvider)
        }
        next.selectedModel = ModelSelection(providerId: storedProvider.id, modelId: selectedModelId)

        if !key.isEmpty {
            try store.saveAPIKey(key, providerId: storedProvider.id)
        }
        try store.writeModels(for: next)
        settings = try store.save(next)
        scheduleRuntimeRestart()
    }

    // Deletes a custom Provider from every app-owned disk file and restarts Pi.
    func deleteProvider(id: String) throws {
        guard !hasRunningSessions else {
            throw QuickPiError.message("仍有会话正在执行任务，不能删除 Provider")
        }
        guard settings.providers.contains(where: { $0.id == id }) else {
            throw QuickPiError.message("只能删除用户添加的 Provider")
        }
        var next = settings
        next.providers.removeAll { $0.id == id }
        if next.selectedModel?.providerId == id {
            next.selectedModel = nil
        }

        try store.deleteCredential(providerId: id)
        try store.writeModels(for: next)
        settings = try store.save(next)
        scheduleRuntimeRestart()
    }

    // Starts a built-in Provider login flow owned by Pi.
    func startAuth(provider: ProviderStatus, type: String) {
        guard runtimeReady else {
            runtimeError = "Pi 尚未就绪"
            notifyPanel()
            return
        }
        guard !hasRunningSessions else {
            runtimeError = "仍有会话正在执行任务，不能开始登录"
            notifyPanel()
            return
        }
        guard let sessionID = activeSessionID, let runtime = runtimes[sessionID] else {
            runtimeError = "当前会话没有可用的 Pi 进程"
            notifyPanel()
            return
        }
        authSession = AuthSession(
            providerId: provider.id,
            providerName: provider.name,
            event: nil,
            prompt: nil,
            error: nil
        )
        do {
            try runtime.login(providerId: provider.id, authType: type)
        } catch {
            authSession?.error = error.localizedDescription
        }
    }

    // Returns one authentication field or selection to the active Pi request.
    func respondToAuth(value: String) {
        guard let prompt = authSession?.prompt,
              let sessionID = activeSessionID,
              let runtime = runtimes[sessionID] else {
            return
        }
        do {
            try runtime.respondToAuth(requestId: prompt.requestId, value: value)
            authSession?.prompt = nil
        } catch {
            authSession?.error = error.localizedDescription
        }
    }

    // Returns a value or confirmation to the extension request shown by the native UI.
    func respondToExtensionPrompt(value: String? = nil, confirmed: Bool? = nil) {
        guard let sessionID = activeSessionID,
              let prompt = sessionExecutions[sessionID]?.extensionPrompt,
              let runtime = runtimes[sessionID] else {
            return
        }
        do {
            try runtime.respondToExtensionPrompt(
                requestId: prompt.requestId,
                value: value,
                confirmed: confirmed
            )
            updateSession(sessionID) { $0.extensionPrompt = nil }
        } catch {
            if sessionExecutions[sessionID]?.isAnswering == true {
                updateSession(sessionID) { execution in
                    execution.answer?.status = .failed
                    execution.answer?.error = error.localizedDescription
                }
            } else {
                setRuntimeError(error.localizedDescription, sessionID: sessionID)
            }
        }
        notifyPanel()
    }

    // Cancels the current extension interaction so its command handler can finish.
    func cancelExtensionPrompt() {
        guard let sessionID = activeSessionID,
              let prompt = sessionExecutions[sessionID]?.extensionPrompt,
              let runtime = runtimes[sessionID] else {
            return
        }
        do {
            try runtime.respondToExtensionPrompt(requestId: prompt.requestId, cancelled: true)
            updateSession(sessionID) { $0.extensionPrompt = nil }
        } catch {
            if sessionExecutions[sessionID]?.isAnswering == true {
                updateSession(sessionID) { execution in
                    execution.answer?.status = .failed
                    execution.answer?.error = error.localizedDescription
                }
            } else {
                setRuntimeError(error.localizedDescription, sessionID: sessionID)
            }
        }
        notifyPanel()
    }

    // Cancels authentication by replacing the process that owns the pending prompt.
    func cancelAuth() {
        authSession = nil
        scheduleRuntimeRestart()
    }

    // Removes one built-in Provider credential through Pi, then reloads its Provider snapshot.
    func logout(providerId: String) async {
        guard !hasRunningSessions else {
            runtimeError = "仍有会话正在执行任务，不能退出 Provider"
            notifyPanel()
            return
        }
        guard let sessionID = activeSessionID, let runtime = runtimes[sessionID] else {
            runtimeError = "当前会话没有可用的 Pi 进程"
            notifyPanel()
            return
        }
        do {
            try await runtime.logout(providerId: providerId)
            if settings.selectedModel?.providerId == providerId {
                var next = settings
                next.selectedModel = nil
                settings = try store.save(next)
            }
            scheduleRuntimeRestart()
        } catch {
            runtimeError = error.localizedDescription
            notifyPanel()
        }
    }

    // Opens a validated authentication URL in the user's default browser.
    func openExternal(_ value: String) {
        guard let url = URL(string: value), url.scheme == "https" || url.scheme == "http" else {
            authSession?.error = "只允许打开 HTTP 或 HTTPS 地址"
            return
        }
        NSWorkspace.shared.open(url)
    }

    // Stops the app-owned Pi process during normal application termination.
    func stop() {
        runtimeGeneration += 1
        for runtime in runtimes.values {
            runtime.stop()
        }
        for runtime in unboundRuntimes.values {
            runtime.stop()
        }
        runtimes = [:]
        unboundRuntimes = [:]
        runtimeSessionIDs = [:]
        pendingRuntimeEvents = [:]
    }

    // Runs the deterministic lifecycle only for the latest persisted configuration generation.
    private func launchRuntime(generation: Int) async {
        guard generation == runtimeGeneration else {
            return
        }
        initialRuntimeStarting = true
        startupRuntimeError = nil
        startupResultPresented = false
        builtInProviders = []
        builtInModels = []
        slashCommands = Self.nativeSlashCommands
        sessions = []
        activeSessionID = nil
        sessionExecutions = [:]
        readySessionIDs = []
        startingSessionIDs = []
        notifyPanel()

        let runtime = makeRuntime()
        do {
            try store.writeModels(for: settings)
            let modelError = try await startRuntime(runtime, session: .mostRecent)
            guard generation == runtimeGeneration else {
                removeRuntime(runtime, stopping: true)
                return
            }
            let sessionSnapshot = try await runtime.sessionSnapshot()
            guard generation == runtimeGeneration else {
                removeRuntime(runtime, stopping: true)
                return
            }
            try validateSessionSnapshot(sessionSnapshot)
            try applySessionSnapshot(sessionSnapshot)
            bindRuntime(runtime, to: sessionSnapshot.activeSessionId)
            if runtimes[sessionSnapshot.activeSessionId] === runtime {
                readySessionIDs.insert(sessionSnapshot.activeSessionId)
            }
            if let modelError {
                setRuntimeError(modelError, sessionID: sessionSnapshot.activeSessionId)
            }
        } catch {
            guard generation == runtimeGeneration else {
                removeRuntime(runtime, stopping: true)
                return
            }
            removeRuntime(runtime, stopping: true)
            startupRuntimeError = error.localizedDescription
            startupResultPresented = true
        }
        initialRuntimeStarting = false
        notifyPanel()
    }

    // Invalidates earlier launches, stops their process, and starts Pi from the newest disk settings.
    private func scheduleRuntimeRestart(reporting message: String? = nil) {
        pendingDraft = draft
        pendingAttachments = attachments
        runtimeGeneration += 1
        initialRuntimeStarting = true
        sessions = []
        activeSessionID = nil
        sessionExecutions = [:]
        readySessionIDs = []
        startingSessionIDs = []
        for runtime in runtimes.values {
            runtime.stop()
        }
        for runtime in unboundRuntimes.values {
            runtime.stop()
        }
        runtimes = [:]
        unboundRuntimes = [:]
        runtimeSessionIDs = [:]
        pendingRuntimeEvents = [:]
        notifyPanel()
        let generation = runtimeGeneration
        Task {
            await launchRuntime(generation: generation)
            guard generation == runtimeGeneration, runtimeReady, let message else {
                return
            }
            setRuntimeError(message, sessionID: activeSessionID)
            notifyPanel()
        }
    }

    // Converts and validates the Base URL contract shared by synchronization and persistence.
    private func validatedBaseURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme == "https" || url.scheme == "http",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw QuickPiError.message("Base URL 必须是有效的 HTTP 或 HTTPS 地址")
        }
        return url
    }

    // Restores one process-bound session without discarding transient plugin output already shown by the app.
    func applySessionSnapshot(_ snapshot: SessionSnapshot, preservingInput: Bool = false) throws {
        try validateSessionSnapshot(snapshot)
        let answers = try restoredAnswers(from: snapshot.messages)
        let wasWaitingForInitialSession = activeSessionID == nil
        applySessionList(snapshot.sessions)
        var execution = sessionExecutions[snapshot.activeSessionId] ?? SessionExecution()
        let draft = execution.draft
        let attachments = execution.attachments
        let preservesLoadedConversation = preservingInput && execution.conversationLoaded
        if !preservesLoadedConversation {
            execution.previousAnswers = answers
            execution.answer = nil
            execution.resultPresented = !answers.isEmpty
        }
        execution.runtimeError = nil
        execution.extensionCommandRunning = false
        execution.agentRunning = false
        execution.unreadCompletion = false
        execution.conversationLoaded = true
        if preservingInput {
            execution.draft = draft
            execution.attachments = attachments
        } else if wasWaitingForInitialSession {
            execution.draft = pendingDraft
            execution.attachments = pendingAttachments
            pendingDraft = ""
            pendingAttachments = []
        } else {
            execution.draft = ""
            execution.attachments = []
        }
        sessionExecutions[snapshot.activeSessionId] = execution
        activeSessionID = snapshot.activeSessionId
    }

    // Accepts session state only when every path belongs to the configured working directory.
    private func validateSessionSnapshot(_ snapshot: SessionSnapshot) throws {
        let expectedCwd = (settings.workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard snapshot.cwd == expectedCwd else {
            throw QuickPiError.message("Pi 会话目录与当前范围不一致")
        }
        guard snapshot.sessions.allSatisfy({ $0.cwd == expectedCwd }) else {
            throw QuickPiError.message("会话列表包含其他目录的会话")
        }
        guard Set(snapshot.sessions.map(\.id)).count == snapshot.sessions.count,
              Set(snapshot.sessions.map(\.path)).count == snapshot.sessions.count else {
            throw QuickPiError.message("Pi 会话列表包含重复项")
        }
        guard snapshot.sessions.contains(where: {
            $0.id == snapshot.activeSessionId && $0.path == snapshot.activeSessionPath
        }) else {
            throw QuickPiError.message("活动会话不在当前目录的会话列表中")
        }
    }

    // Replaces disk-backed session metadata and creates empty UI state for newly discovered sessions.
    private func applySessionList(_ values: [ConversationSession]) {
        sessions = values
        for session in values where sessionExecutions[session.id] == nil {
            sessionExecutions[session.id] = SessionExecution()
        }
    }

    // Reconstructs visible turns from Pi's active branch without changing the saved context.
    private func restoredAnswers(from messages: [SavedSessionMessage]) throws -> [AnswerSession] {
        var answers: [AnswerSession] = []
        var current: AnswerSession?

        for message in messages {
            switch message.role {
            case .user:
                guard let text = message.text else {
                    throw QuickPiError.message("Pi 用户消息缺少文本")
                }
                if var answer = current {
                    finishInterruptedAnswer(&answer)
                    answers.append(answer)
                }
                current = AnswerSession(
                    question: SubmittedQuestion(
                        text: text,
                        attachmentNames: [],
                        workspacePath: settings.workspacePath
                    ),
                    startedAt: Date(timeIntervalSince1970: message.timestamp / 1_000),
                    sections: [],
                    status: .waiting,
                    forkEntryId: message.entryId
                )
            case .assistant:
                guard var answer = current,
                      let content = message.content,
                      let provider = message.provider,
                      let model = message.model,
                      let usage = message.usage,
                      let stopReason = message.stopReason else {
                    throw QuickPiError.message("Pi 助手历史消息不完整")
                }
                for block in content {
                    switch block.type {
                    case .text:
                        guard let text = block.text else {
                            throw QuickPiError.message("Pi 助手历史文本缺少内容")
                        }
                        appendRestoredSection(.markdown(text), to: &answer)
                    case .thinking:
                        guard let thinking = block.thinking else {
                            throw QuickPiError.message("Pi 助手历史思考缺少内容")
                        }
                        appendRestoredSection(.thinking(thinking), to: &answer)
                    case .toolCall:
                        guard let callId = block.toolCallId,
                              let name = block.toolName,
                              let arguments = block.arguments else {
                            throw QuickPiError.message("Pi 历史工具调用不完整")
                        }
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                        answer.sections.append(AnswerSection(
                            id: UUID(),
                            content: .tool(ToolActivity(
                                callId: callId,
                                name: name,
                                input: String(decoding: try encoder.encode(arguments), as: UTF8.self),
                                output: "",
                                status: .running
                            ))
                        ))
                    }
                }
                answer.provider = provider
                answer.model = model
                answer.usage.add(usage)
                answer.stopReason = stopReason
                switch stopReason {
                case "stop", "length":
                    answer.status = .completed
                    answer.error = nil
                case "toolUse":
                    answer.status = .running
                    answer.error = nil
                case "aborted":
                    answer.status = .stopped
                    answer.error = nil
                case "error":
                    guard let error = message.errorMessage, !error.isEmpty else {
                        throw QuickPiError.message("Pi 助手历史错误缺少说明")
                    }
                    answer.status = .failed
                    answer.error = error
                default:
                    throw QuickPiError.message("未知的 Pi 助手停止原因：\(stopReason)")
                }
                current = answer
            case .toolResult:
                guard var answer = current,
                      let callId = message.toolCallId,
                      let name = message.toolName,
                      let output = message.text,
                      let isError = message.isError,
                      let index = answer.sections.firstIndex(where: { section in
                          if case .tool(let tool) = section.content {
                              return tool.callId == callId && tool.name == name
                          }
                          return false
                      }), case .tool(var tool) = answer.sections[index].content else {
                    throw QuickPiError.message("Pi 历史工具结果没有对应调用")
                }
                tool.output = output
                tool.status = isError ? .failed : .completed
                answer.sections[index].content = .tool(tool)
                current = answer
            case .custom:
                guard let customMessage = message.customMessage else {
                    throw QuickPiError.message("Pi 扩展历史消息不完整")
                }
                guard customMessage.display else {
                    continue
                }
                if var answer = current,
                   answer.status == .waiting || answer.status == .running {
                    answer.sections.append(AnswerSection(
                        id: UUID(),
                        content: .customMessage(customMessage)
                    ))
                    current = answer
                } else {
                    if let answer = current {
                        answers.append(answer)
                    }
                    current = AnswerSession(
                        question: nil,
                        startedAt: Date(timeIntervalSince1970: message.timestamp / 1_000),
                        sections: [AnswerSection(id: UUID(), content: .customMessage(customMessage))],
                        status: .completed
                    )
                }
            }
        }

        if var answer = current {
            finishInterruptedAnswer(&answer)
            answers.append(answer)
        }
        return answers
    }

    // Merges adjacent restored text blocks to match the live streaming representation.
    private func appendRestoredSection(_ content: AnswerSectionContent, to answer: inout AnswerSession) {
        if let index = answer.sections.indices.last {
            switch (answer.sections[index].content, content) {
            case let (.markdown(existing), .markdown(text)):
                answer.sections[index].content = .markdown(existing + text)
                return
            case let (.thinking(existing), .thinking(text)):
                answer.sections[index].content = .thinking(existing + text)
                return
            default:
                break
            }
        }
        answer.sections.append(AnswerSection(id: UUID(), content: content))
    }

    // A persisted turn without a terminal assistant message was interrupted before restart.
    private func finishInterruptedAnswer(_ answer: inout AnswerSession) {
        if answer.status == .waiting || answer.status == .running {
            answer.status = .stopped
        }
    }

    // Mutates one session atomically so published dictionary changes reach SwiftUI.
    private func updateSession(_ sessionID: String, _ update: (inout SessionExecution) -> Void) {
        guard var execution = sessionExecutions[sessionID] else {
            preconditionFailure("会话状态不存在：\(sessionID)")
        }
        update(&execution)
        sessionExecutions[sessionID] = execution
    }

    // Stores an error in the owning session, or in startup state before a session exists.
    private func setRuntimeError(_ message: String?, sessionID: String?) {
        guard let sessionID else {
            startupRuntimeError = message
            if message != nil {
                startupResultPresented = true
            }
            return
        }
        updateSession(sessionID) { execution in
            execution.runtimeError = message
            if message != nil {
                execution.resultPresented = true
            }
        }
    }

    // Creates the visible user turn before its bound process accepts any work.
    private func beginAnswer(
        sessionID: String,
        question: String,
        attachmentNames: [String],
        status: AnswerStatus
    ) -> Int {
        updateSession(sessionID) { execution in
            if let answer = execution.answer {
                execution.previousAnswers.append(answer)
            }
            execution.answerGeneration += 1
            execution.answer = AnswerSession(
                question: SubmittedQuestion(
                    text: question,
                    attachmentNames: attachmentNames,
                    workspacePath: settings.workspacePath
                ),
                startedAt: Date(),
                sections: [],
                status: status
            )
            execution.draft = ""
            execution.attachments = []
            execution.runtimeError = nil
            execution.resultPresented = true
            execution.unreadCompletion = false
            execution.conversationLoaded = true
        }
        guard let generation = sessionExecutions[sessionID]?.answerGeneration else {
            preconditionFailure("提交后会话状态不存在：\(sessionID)")
        }
        return generation
    }

    // Marks a background terminal result unread while its process remains available for immediate switching.
    private func finishSessionExecution(_ sessionID: String) {
        guard let execution = sessionExecutions[sessionID], !execution.isBusy else {
            return
        }
        if sessionID != activeSessionID, execution.answer != nil {
            updateSession(sessionID) { $0.unreadCompletion = true }
        }
    }

    // Creates a process whose events remain unbound until its exact session is known.
    private func makeRuntime() -> PiRuntime {
        let runtime = PiRuntime(applicationSupportDirectory: applicationSupportDirectory)
        runtime.onEvent = { [weak self, weak runtime] event in
            guard let runtime else {
                return
            }
            self?.consume(event, from: runtime)
        }
        unboundRuntimes[ObjectIdentifier(runtime)] = runtime
        return runtime
    }

    // Starts a process, reloads the public plugin catalog, and applies the selected model when available.
    private func startRuntime(_ runtime: PiRuntime, session: PiSessionLaunch) async throws -> String? {
        try await runtime.start(settings: settings, session: session)
        applyRuntimeSnapshot(try await runtime.snapshot())
        guard let selection = settings.selectedModel else {
            return nil
        }
        guard modelOptions.contains(where: {
            $0.providerId == selection.providerId && $0.id == selection.modelId
        }) else {
            return "已保存的模型不可用，请重新选择模型"
        }
        try await runtime.selectModel(selection)
        return nil
    }

    // Applies the provider, model, and command contracts reported by Pi.
    private func applyRuntimeSnapshot(_ snapshot: RuntimeSnapshot) {
        let customIds = Set(settings.providers.map(\.id))
        builtInProviders = snapshot.providers.filter { !customIds.contains($0.id) }
        builtInModels = snapshot.models.filter { !customIds.contains($0.providerId) }
        let nativeNames = Set(Self.nativeSlashCommands.map(\.name))
        slashCommands = Self.nativeSlashCommands + snapshot.commands.filter {
            !nativeNames.contains($0.name)
        }
    }

    // Associates every later event from one process with exactly one session.
    private func bindRuntime(_ runtime: PiRuntime, to sessionID: String) {
        let identifier = ObjectIdentifier(runtime)
        precondition(runtimeSessionIDs[identifier] == nil)
        precondition(runtimes[sessionID] == nil)
        let unboundRuntime = unboundRuntimes.removeValue(forKey: identifier)
        precondition(unboundRuntime === runtime)
        runtimes[sessionID] = runtime
        runtimeSessionIDs[identifier] = sessionID
        let pendingEvents = pendingRuntimeEvents.removeValue(forKey: identifier) ?? []
        for event in pendingEvents {
            if case .runtimeExited = event {
                removeRuntime(runtime, stopping: false)
            }
            consume(event, sessionID: sessionID)
        }
    }

    // Moves a process only after Pi confirms that it changed to a newly created session.
    private func rebindRuntime(_ runtime: PiRuntime, from oldSessionID: String, to newSessionID: String) {
        let identifier = ObjectIdentifier(runtime)
        precondition(runtimeSessionIDs[identifier] == oldSessionID)
        precondition(runtimes[oldSessionID] === runtime)
        precondition(runtimes[newSessionID] == nil)
        let wasReady = readySessionIDs.remove(oldSessionID) != nil
        let wasStarting = startingSessionIDs.remove(oldSessionID) != nil
        runtimes.removeValue(forKey: oldSessionID)
        runtimes[newSessionID] = runtime
        runtimeSessionIDs[identifier] = newSessionID
        if sessionExecutions[newSessionID] == nil {
            sessionExecutions[newSessionID] = SessionExecution()
        }
        if wasReady {
            readySessionIDs.insert(newSessionID)
        }
        if wasStarting {
            startingSessionIDs.insert(newSessionID)
        }
    }

    // Removes one known process and all readiness bookkeeping for its session.
    private func removeRuntime(sessionID: String, stopping: Bool) {
        guard let runtime = runtimes.removeValue(forKey: sessionID) else {
            readySessionIDs.remove(sessionID)
            startingSessionIDs.remove(sessionID)
            return
        }
        runtimeSessionIDs.removeValue(forKey: ObjectIdentifier(runtime))
        pendingRuntimeEvents.removeValue(forKey: ObjectIdentifier(runtime))
        readySessionIDs.remove(sessionID)
        startingSessionIDs.remove(sessionID)
        if stopping {
            runtime.stop()
        }
    }

    // Removes a process by identity after a session-changing command may have rebound it.
    private func removeRuntime(_ runtime: PiRuntime, stopping: Bool) {
        let identifier = ObjectIdentifier(runtime)
        guard let sessionID = runtimeSessionIDs[identifier] else {
            unboundRuntimes.removeValue(forKey: identifier)
            pendingRuntimeEvents.removeValue(forKey: identifier)
            if stopping {
                runtime.stop()
            }
            return
        }
        removeRuntime(sessionID: sessionID, stopping: stopping)
    }

    // Keeps only the selected idle process plus processes that are still doing work.
    private func pruneRuntimeIfIdle(sessionID: String) {
        guard sessionID != activeSessionID,
              startingSessionIDs.contains(sessionID) == false,
              sessionExecutions[sessionID]?.isBusy == false else {
            return
        }
        removeRuntime(sessionID: sessionID, stopping: true)
    }

    // Queues startup events until the process is bound, then routes all live events by process identity.
    private func consume(_ event: PiRuntimeEvent, from runtime: PiRuntime) {
        let identifier = ObjectIdentifier(runtime)
        guard let sessionID = runtimeSessionIDs[identifier] else {
            pendingRuntimeEvents[identifier, default: []].append(event)
            return
        }
        guard runtimes[sessionID] === runtime else {
            return
        }
        if case .runtimeExited = event {
            removeRuntime(runtime, stopping: false)
        }
        consume(event, sessionID: sessionID)
        if runtimes.isEmpty {
            slashCommands = Self.nativeSlashCommands
        }
    }

    // Applies a test or active-session event through the same session-aware event reducer.
    func consume(_ event: PiRuntimeEvent) {
        guard let sessionID = activeSessionID else {
            setRuntimeError("Pi 事件到达时没有活动会话", sessionID: nil)
            notifyPanel()
            return
        }
        consume(event, sessionID: sessionID)
    }

    // Applies every Pi event only to the session that owns its source process.
    func consume(_ event: PiRuntimeEvent, sessionID: String) {
        guard sessionExecutions[sessionID] != nil else {
            setRuntimeError("Pi 事件对应的会话不存在：\(sessionID)", sessionID: activeSessionID)
            notifyPanel()
            return
        }
        switch event {
        case .agentStarted:
            updateSession(sessionID) { execution in
                execution.agentRunning = true
                if execution.answer?.status == .waiting
                    || execution.answer?.status == .running
                    || execution.answer?.status == .completed {
                    execution.answer?.status = .running
                    execution.answer?.retryMessage = nil
                    execution.answer?.error = nil
                }
            }
        case .userMessage(let message):
            if sessionExecutions[sessionID]?.isAnswering == false {
                _ = beginAnswer(
                    sessionID: sessionID,
                    question: message,
                    attachmentNames: [],
                    status: .waiting
                )
            }
        case .userMessagePersisted:
            guard let runtime = runtimes[sessionID],
                  let generation = sessionExecutions[sessionID]?.answerGeneration else {
                break
            }
            Task {
                do {
                    let messages = try await runtime.forkMessages()
                    guard runtimes[sessionID] === runtime,
                          generation == sessionExecutions[sessionID]?.answerGeneration else {
                        return
                    }
                    guard let entry = messages.last else {
                        throw QuickPiError.message("Pi 没有返回当前消息的分叉点")
                    }
                    guard sessionExecutions[sessionID]?.answer != nil else {
                        throw QuickPiError.message("当前回复不存在")
                    }
                    updateSession(sessionID) { execution in
                        execution.answer?.forkEntryId = entry.entryId
                    }
                } catch {
                    guard generation == sessionExecutions[sessionID]?.answerGeneration else {
                        return
                    }
                    setRuntimeError(error.localizedDescription, sessionID: sessionID)
                    notifyPanel()
                }
            }
        case .textDelta(let delta):
            appendText(delta, sessionID: sessionID)
        case .thinkingDelta(let delta):
            appendThinking(delta, sessionID: sessionID)
        case let .toolStarted(id, name, input):
            updateSession(sessionID) { execution in
                execution.answer?.sections.append(AnswerSection(
                    id: UUID(),
                    content: .tool(ToolActivity(
                        callId: id,
                        name: name,
                        input: input,
                        output: "",
                        status: .running
                    ))
                ))
            }
        case let .toolUpdated(id, output):
            updateTool(id: id, output: output, status: .running, sessionID: sessionID)
        case let .toolFinished(id, output, isError):
            updateTool(
                id: id,
                output: output,
                status: isError ? .failed : .completed,
                sessionID: sessionID
            )
        case let .assistantMetadata(provider, model, usage, stopReason):
            updateSession(sessionID) { execution in
                execution.answer?.provider = provider
                execution.answer?.model = model
                execution.answer?.usage.add(usage)
                execution.answer?.stopReason = stopReason
            }
        case .retrying(let message):
            updateSession(sessionID) { execution in
                execution.answer?.status = .running
                execution.answer?.error = nil
                execution.answer?.retryMessage = message
            }
        case .settled:
            updateSession(sessionID) { execution in
                execution.agentRunning = false
                let failed = execution.answer?.error != nil
                if execution.answer?.status == .waiting || execution.answer?.status == .running {
                    execution.answer?.status = failed ? .failed : .completed
                }
                execution.answer?.retryMessage = nil
            }
            finishSessionExecution(sessionID)
        case let .turnFailed(message, aborted):
            updateSession(sessionID) { execution in
                execution.answer?.status = aborted ? .stopped : .running
                execution.answer?.error = aborted ? nil : message
                execution.answer?.retryMessage = nil
                if aborted {
                    execution.agentRunning = false
                }
            }
            if aborted {
                finishSessionExecution(sessionID)
            }
        case .authPrompt(let prompt):
            authSession?.prompt = prompt
        case .authEvent(let event):
            authSession?.event = event
        case .authCompleted:
            authSession = nil
            scheduleRuntimeRestart()
        case .logoutCompleted:
            break
        case .customMessage(let message):
            guard message.display else {
                break
            }
            updateSession(sessionID) { execution in
                execution.conversationLoaded = true
                if execution.isAnswering {
                    execution.answer?.sections.append(AnswerSection(
                        id: UUID(),
                        content: .customMessage(message)
                    ))
                } else {
                    if let answer = execution.answer {
                        execution.previousAnswers.append(answer)
                    }
                    execution.answerGeneration += 1
                    execution.answer = AnswerSession(
                        question: nil,
                        startedAt: Date(timeIntervalSince1970: message.timestamp / 1_000),
                        sections: [AnswerSection(id: UUID(), content: .customMessage(message))],
                        status: .completed
                    )
                    execution.resultPresented = true
                }
            }
            finishSessionExecution(sessionID)
        case .extensionNotification(let notification):
            updateSession(sessionID) { execution in
                execution.conversationLoaded = true
                if execution.isAnswering {
                    execution.answer?.sections.append(AnswerSection(
                        id: UUID(),
                        content: .extensionNotification(notification)
                    ))
                } else {
                    if let answer = execution.answer {
                        execution.previousAnswers.append(answer)
                    }
                    execution.answerGeneration += 1
                    execution.answer = AnswerSession(
                        question: nil,
                        startedAt: Date(),
                        sections: [AnswerSection(id: UUID(), content: .extensionNotification(notification))],
                        status: .completed
                    )
                    execution.resultPresented = true
                }
            }
            finishSessionExecution(sessionID)
        case let .extensionStatus(key, text):
            updateSession(sessionID) { execution in
                if let text {
                    if let index = execution.extensionStatuses.firstIndex(where: { $0.key == key }) {
                        execution.extensionStatuses[index].text = text
                    } else {
                        execution.extensionStatuses.append(ExtensionStatus(key: key, text: text))
                    }
                } else {
                    execution.extensionStatuses.removeAll { $0.key == key }
                }
            }
        case let .extensionWidget(key, lines, placement):
            updateSession(sessionID) { execution in
                if let lines {
                    if let index = execution.extensionWidgets.firstIndex(where: { $0.key == key }) {
                        execution.extensionWidgets[index].lines = lines
                        execution.extensionWidgets[index].placement = placement
                    } else {
                        execution.extensionWidgets.append(ExtensionWidget(
                            key: key,
                            lines: lines,
                            placement: placement
                        ))
                    }
                } else {
                    execution.extensionWidgets.removeAll { $0.key == key }
                }
            }
        case .extensionTitle(let title):
            updateSession(sessionID) { $0.extensionTitle = title }
        case .extensionEditorText(let text):
            updateSession(sessionID) { $0.draft = text }
        case .extensionPrompt(let prompt):
            updateSession(sessionID) { $0.extensionPrompt = prompt }
        case .operationFailed(let message):
            if authSession != nil {
                authSession?.error = message
            } else if sessionExecutions[sessionID]?.isAnswering == true {
                updateSession(sessionID) { execution in
                    execution.answer?.status = .failed
                    execution.answer?.error = message
                }
                finishSessionExecution(sessionID)
            } else {
                setRuntimeError(message, sessionID: sessionID)
            }
        case .runtimeExited(let message):
            updateSession(sessionID) { execution in
                execution.runtimeError = message
                execution.resultPresented = true
                execution.extensionCommandRunning = false
                execution.agentRunning = false
                execution.extensionStatuses = []
                execution.extensionWidgets = []
                execution.extensionTitle = nil
                execution.extensionPrompt = nil
                if execution.isAnswering {
                    execution.answer?.status = .failed
                    execution.answer?.error = message
                }
            }
            finishSessionExecution(sessionID)
        }
        notifyPanel()
    }

    // Shows a native command result without adding the command to Pi's saved model conversation.
    private func presentCommandResult(question: String, markdown: String, sessionID: String) {
        updateSession(sessionID) { execution in
            if let answer = execution.answer {
                execution.previousAnswers.append(answer)
            }
            execution.answerGeneration += 1
            execution.answer = AnswerSession(
                question: SubmittedQuestion(
                    text: question,
                    attachmentNames: [],
                    workspacePath: settings.workspacePath
                ),
                startedAt: Date(),
                sections: [AnswerSection(id: UUID(), content: .extensionMessage(markdown))],
                status: .completed
            )
            execution.draft = ""
            execution.attachments = []
            execution.runtimeError = nil
            execution.resultPresented = true
            execution.conversationLoaded = true
        }
        finishSessionExecution(sessionID)
        notifyPanel()
    }

    // Appends streamed Markdown to the answer owned by one runtime.
    private func appendText(_ delta: String, sessionID: String) {
        updateSession(sessionID) { execution in
            guard execution.answer != nil else {
                execution.runtimeError = "收到回答时没有活动问题"
                execution.resultPresented = true
                return
            }
            if let index = execution.answer?.sections.indices.last,
               case .markdown(let text) = execution.answer?.sections[index].content {
                execution.answer?.sections[index].content = .markdown(text + delta)
            } else {
                execution.answer?.sections.append(AnswerSection(id: UUID(), content: .markdown(delta)))
            }
        }
    }

    // Appends private reasoning to the answer owned by one runtime.
    private func appendThinking(_ delta: String, sessionID: String) {
        updateSession(sessionID) { execution in
            guard execution.answer != nil else {
                execution.runtimeError = "收到思考内容时没有活动问题"
                execution.resultPresented = true
                return
            }
            if let index = execution.answer?.sections.indices.last,
               case .thinking(let text) = execution.answer?.sections[index].content {
                execution.answer?.sections[index].content = .thinking(text + delta)
            } else {
                execution.answer?.sections.append(AnswerSection(id: UUID(), content: .thinking(delta)))
            }
        }
    }

    // Replaces the tool block matching Pi's call id inside its owning session.
    private func updateTool(id: String, output: String, status: ToolStatus, sessionID: String) {
        updateSession(sessionID) { execution in
            guard let index = execution.answer?.sections.firstIndex(where: { section in
                if case .tool(let tool) = section.content {
                    return tool.callId == id
                }
                return false
            }), case .tool(var tool) = execution.answer?.sections[index].content else {
                execution.answer?.status = .failed
                execution.answer?.error = "收到未知工具调用的执行结果"
                return
            }
            tool.output = output
            tool.status = status
            execution.answer?.sections[index].content = .tool(tool)
        }
    }

    // Notifies AppKit when answer visibility or dynamic result content changes.
    private func notifyPanel() {
        panelContentChanged?()
    }
}
