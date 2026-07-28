import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var builtInProviders: [ProviderStatus] = []
    @Published private(set) var builtInModels: [ModelOption] = []
    @Published private(set) var slashCommands: [SlashCommand] = []
    @Published private(set) var runtimeReady = false
    @Published private(set) var runtimeStarting = false
    @Published private(set) var sessions: [ConversationSession] = []
    @Published private(set) var activeSessionID: String?
    @Published private(set) var sessionChanging = false
    @Published private(set) var previousAnswers: [AnswerSession] = []
    @Published private(set) var answer: AnswerSession?
    @Published private(set) var resultPresented = false
    @Published var draft = ""
    @Published var attachments: [PendingAttachment] = []
    @Published var runtimeError: String?
    @Published var shortcutError: String?
    @Published var authSession: AuthSession?
    @Published private(set) var extensionPrompt: ExtensionPrompt?

    private let store: ConfigurationStore
    private let runtime: PiRuntime
    let checkForUpdates: () -> Void
    let presentSettings: () -> Void
    private var runtimeGeneration = 0
    private var answerGeneration = 0

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
        return custom + builtInModels.filter { !customIds.contains($0.providerId) }
    }

    var selectedModel: ModelOption? {
        guard let selection = settings.selectedModel else {
            return nil
        }
        return modelOptions.first {
            $0.providerId == selection.providerId && $0.id == selection.modelId
        }
    }

    var isAnswering: Bool {
        answer?.status == .waiting || answer?.status == .running
    }

    var conversationAnswers: [AnswerSession] {
        previousAnswers + (answer.map { [$0] } ?? [])
    }

    var activeSession: ConversationSession? {
        guard let activeSessionID else {
            return nil
        }
        return sessions.first { $0.id == activeSessionID }
    }

    var scopeTitle: String {
        settings.workspaceURL?.lastPathComponent ?? "主目录"
    }

    func title(for session: ConversationSession) -> String {
        if session.id == activeSessionID,
           session.firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let question = conversationAnswers.first?.question.text {
            return question
        }
        return session.title
    }

    var showsResultPanel: Bool {
        runtimeError != nil || (resultPresented && !conversationAnswers.isEmpty)
    }

    // Loads the settings document and binds desktop actions plus managed Pi process events.
    init(
        applicationSupportDirectory: URL,
        checkForUpdates: @escaping () -> Void,
        presentSettings: @escaping () -> Void
    ) throws {
        store = ConfigurationStore(applicationSupportDirectory: applicationSupportDirectory)
        settings = try store.load()
        runtime = PiRuntime(applicationSupportDirectory: applicationSupportDirectory)
        self.checkForUpdates = checkForUpdates
        self.presentSettings = presentSettings
        runtime.onEvent = { [weak self] event in
            self?.consume(event)
        }
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
        guard !isAnswering else {
            runtimeError = "回答期间不能切换模型"
            notifyPanel()
            return
        }
        do {
            var next = settings
            next.selectedModel = model.selection
            settings = try store.save(next)
            runtimeReady = false
            notifyPanel()
            do {
                try await runtime.selectModel(model.selection)
                runtimeReady = true
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
            for url in urls {
                attachments.append(try AttachmentLoader.load(url: url))
            }
            runtimeError = nil
        } catch {
            runtimeError = error.localizedDescription
        }
        notifyPanel()
    }

    // Removes one attachment before the question is submitted.
    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
        notifyPanel()
    }

    // Persists the explicitly selected project root and restarts Pi in that directory.
    func setWorkspace(_ url: URL?) {
        guard !isAnswering else {
            runtimeError = "回答期间不能切换工作区"
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

    // Creates one visible answer session and submits its text, documents, and images to Pi.
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
        let commandName = question.hasPrefix("/")
            ? question.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init)
            : nil
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
        guard !isAnswering else {
            return
        }

        let images = attachments.compactMap { attachment -> ImagePayload? in
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
        let documentSections = attachments.compactMap { attachment -> String? in
            if case let .text(text) = attachment.content {
                return "附件：\(attachment.name)\n\n\(text)"
            }
            return nil
        }
        let prompt = documentSections.isEmpty
            ? question
            : "\(question)\n\n---\n\n\(documentSections.joined(separator: "\n\n---\n\n"))"
        let attachmentNames = attachments.map(\.name)

        answerGeneration += 1
        let generation = answerGeneration
        if let answer {
            previousAnswers.append(answer)
        }
        draft = ""
        attachments = []
        runtimeError = nil
        resultPresented = true
        answer = AnswerSession(
            question: SubmittedQuestion(
                text: question,
                attachmentNames: attachmentNames,
                workspacePath: settings.workspacePath
            ),
            startedAt: Date(),
            sections: [],
            status: .waiting
        )
        notifyPanel()

        do {
            try await runtime.prompt(message: prompt, images: images)
            guard generation == answerGeneration else {
                return
            }
            if isExtensionCommand {
                let snapshot = try await runtime.snapshot()
                guard generation == answerGeneration else {
                    return
                }
                let customIds = Set(settings.providers.map(\.id))
                builtInProviders = snapshot.providers.filter { !customIds.contains($0.id) }
                builtInModels = snapshot.models.filter { !customIds.contains($0.providerId) }
                slashCommands = snapshot.commands
                if answer?.status == .waiting {
                    if answer?.sections.isEmpty == true {
                        appendText("命令已执行")
                    }
                    if answer?.error == nil {
                        answer?.status = .completed
                    }
                }
                notifyPanel()
            }
        } catch {
            guard generation == answerGeneration else {
                return
            }
            answer?.status = .failed
            answer?.error = error.localizedDescription
            notifyPanel()
        }
    }

    // Stops the current answer and leaves completed content available for copying.
    func abort() async {
        answerGeneration += 1
        let generation = answerGeneration
        do {
            if let prompt = extensionPrompt {
                try runtime.respondToExtensionPrompt(requestId: prompt.requestId, cancelled: true)
                extensionPrompt = nil
            }
            try await runtime.abort()
            guard generation == answerGeneration else {
                return
            }
            answer?.status = .stopped
            answer?.retryMessage = nil
        } catch {
            guard generation == answerGeneration else {
                return
            }
            answer?.status = .failed
            answer?.error = error.localizedDescription
        }
        notifyPanel()
    }

    // Hides the result while retaining the active session and its complete conversation.
    func clearAnswer() async {
        answerGeneration += 1
        let generation = answerGeneration
        do {
            if let prompt = extensionPrompt {
                try runtime.respondToExtensionPrompt(requestId: prompt.requestId, cancelled: true)
                extensionPrompt = nil
            }
            if isAnswering {
                try await runtime.abort()
            }
            guard generation == answerGeneration else {
                return
            }
            resultPresented = false
            runtimeError = nil
        } catch {
            guard generation == answerGeneration else {
                return
            }
            runtimeError = error.localizedDescription
        }
        notifyPanel()
    }

    // Creates a persistent empty session in the current main-directory or workspace scope.
    func createSession() async {
        guard runtimeReady, !isAnswering, !sessionChanging else {
            return
        }
        sessionChanging = true
        runtimeError = nil
        let previousSessionID = activeSessionID
        notifyPanel()
        do {
            try await runtime.newSession()
            let snapshot = try await runtime.sessionSnapshot()
            guard snapshot.activeSessionId != previousSessionID else {
                throw QuickPiError.message("Pi 没有创建新会话")
            }
            try applySessionSnapshot(snapshot)
            resultPresented = false
        } catch {
            sessionChanging = false
            scheduleRuntimeRestart(reporting: error.localizedDescription)
            return
        }
        sessionChanging = false
        notifyPanel()
    }

    // Switches only to a session returned for the active working-directory scope.
    func switchSession(id: String) async {
        guard runtimeReady, !isAnswering, !sessionChanging else {
            return
        }
        guard id != activeSessionID else {
            return
        }
        guard let target = sessions.first(where: { $0.id == id }) else {
            runtimeError = "所选会话不属于当前目录"
            notifyPanel()
            return
        }
        sessionChanging = true
        runtimeError = nil
        notifyPanel()
        do {
            try await runtime.switchSession(path: target.path)
            let snapshot = try await runtime.sessionSnapshot()
            guard snapshot.activeSessionId == target.id,
                  snapshot.activeSessionPath == target.path else {
                throw QuickPiError.message("Pi 切换后的会话与所选会话不一致")
            }
            try applySessionSnapshot(snapshot)
        } catch {
            sessionChanging = false
            scheduleRuntimeRestart(reporting: error.localizedDescription)
            return
        }
        sessionChanging = false
        notifyPanel()
    }

    // Deletes normal and workspace sessions, leaving one new empty session in the current scope.
    func deleteAllSessions() async {
        guard runtimeReady, !isAnswering, !sessionChanging else {
            return
        }
        sessionChanging = true
        runtimeError = nil
        notifyPanel()
        do {
            let snapshot = try await runtime.deleteAllSessions()
            guard snapshot.sessions.count == 1 else {
                throw QuickPiError.message("删除后当前目录仍存在旧会话")
            }
            try applySessionSnapshot(snapshot)
            resultPresented = false
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
        guard let prompt = authSession?.prompt else {
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
        guard let prompt = extensionPrompt else {
            return
        }
        do {
            try runtime.respondToExtensionPrompt(
                requestId: prompt.requestId,
                value: value,
                confirmed: confirmed
            )
            extensionPrompt = nil
        } catch {
            answer?.status = .failed
            answer?.error = error.localizedDescription
        }
        notifyPanel()
    }

    // Cancels the current extension interaction so its command handler can finish.
    func cancelExtensionPrompt() {
        guard let prompt = extensionPrompt else {
            return
        }
        do {
            try runtime.respondToExtensionPrompt(requestId: prompt.requestId, cancelled: true)
            extensionPrompt = nil
        } catch {
            answer?.status = .failed
            answer?.error = error.localizedDescription
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
        runtime.stop()
    }

    // Runs the deterministic lifecycle only for the latest persisted configuration generation.
    private func launchRuntime(generation: Int) async {
        guard generation == runtimeGeneration else {
            return
        }
        runtimeStarting = true
        runtimeReady = false
        runtimeError = nil
        builtInProviders = []
        builtInModels = []
        slashCommands = []
        extensionPrompt = nil
        sessions = []
        activeSessionID = nil
        previousAnswers = []
        answer = nil
        resultPresented = false
        notifyPanel()

        do {
            try store.writeModels(for: settings)
            try await runtime.start(settings: settings)
            guard generation == runtimeGeneration else {
                return
            }

            var selectedCustomModel = false
            if let selection = settings.selectedModel,
               settings.providers.contains(where: {
                   $0.id == selection.providerId && $0.models.contains(selection.modelId)
                }) {
                try await runtime.selectModel(selection)
                guard generation == runtimeGeneration else {
                    return
                }
                selectedCustomModel = true
            }

            do {
                let snapshot = try await runtime.snapshot()
                guard generation == runtimeGeneration else {
                    return
                }
                let customIds = Set(settings.providers.map(\.id))
                builtInProviders = snapshot.providers.filter { !customIds.contains($0.id) }
                builtInModels = snapshot.models.filter { !customIds.contains($0.providerId) }
                slashCommands = snapshot.commands
            } catch {
                guard generation == runtimeGeneration else {
                    return
                }
                runtimeError = "读取 Pi Provider 状态失败：\(error.localizedDescription)"
                runtimeStarting = false
                notifyPanel()
                return
            }

            if let selection = settings.selectedModel {
                if modelOptions.contains(where: {
                    $0.providerId == selection.providerId && $0.id == selection.modelId
                }) {
                    if !selectedCustomModel {
                        try await runtime.selectModel(selection)
                        guard generation == runtimeGeneration else {
                            return
                        }
                    }
                } else {
                    runtimeError = "已保存的模型不可用，请重新选择模型"
                }
            }
            let sessionSnapshot = try await runtime.sessionSnapshot()
            guard generation == runtimeGeneration else {
                return
            }
            try applySessionSnapshot(sessionSnapshot)
            runtimeReady = true
        } catch {
            guard generation == runtimeGeneration else {
                return
            }
            runtime.stop()
            runtimeReady = false
            runtimeError = error.localizedDescription
        }
        runtimeStarting = false
        notifyPanel()
    }

    // Invalidates earlier launches, stops their process, and starts Pi from the newest disk settings.
    private func scheduleRuntimeRestart(reporting message: String? = nil) {
        runtimeGeneration += 1
        runtimeReady = false
        runtimeStarting = true
        extensionPrompt = nil
        if isAnswering {
            answerGeneration += 1
            answer?.status = .stopped
            answer?.retryMessage = nil
        }
        sessions = []
        activeSessionID = nil
        previousAnswers = []
        answer = nil
        resultPresented = false
        runtime.stop()
        notifyPanel()
        let generation = runtimeGeneration
        Task {
            await launchRuntime(generation: generation)
            guard generation == runtimeGeneration, runtimeReady, let message else {
                return
            }
            runtimeError = message
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

    // Accepts session state only when every path belongs to the process working directory.
    func applySessionSnapshot(_ snapshot: SessionSnapshot) throws {
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

        let answers = try restoredAnswers(from: snapshot.messages)
        sessions = snapshot.sessions
        activeSessionID = snapshot.activeSessionId
        previousAnswers = answers
        answer = nil
        resultPresented = !previousAnswers.isEmpty
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
                    status: .waiting
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

    // Applies every Pi event to the current answer, authentication sheet, or runtime status.
    private func consume(_ event: PiRuntimeEvent) {
        switch event {
        case .agentStarted:
            if answer?.status == .waiting
                || answer?.status == .running
                || answer?.status == .completed {
                answer?.status = .running
                answer?.retryMessage = nil
                answer?.error = nil
            }
        case .textDelta(let delta):
            appendText(delta)
        case .thinkingDelta(let delta):
            appendThinking(delta)
        case let .toolStarted(id, name, input):
            answer?.sections.append(AnswerSection(
                id: UUID(),
                content: .tool(ToolActivity(
                    callId: id,
                    name: name,
                    input: input,
                    output: "",
                    status: .running
                ))
            ))
        case let .toolUpdated(id, output):
            updateTool(id: id, output: output, status: .running)
        case let .toolFinished(id, output, isError):
            updateTool(id: id, output: output, status: isError ? .failed : .completed)
        case let .assistantMetadata(provider, model, usage, stopReason):
            answer?.provider = provider
            answer?.model = model
            answer?.usage.add(usage)
            answer?.stopReason = stopReason
        case .retrying(let message):
            answer?.status = .running
            answer?.error = nil
            answer?.retryMessage = message
        case .settled:
            if answer?.status == .waiting || answer?.status == .running {
                answer?.status = answer?.error == nil ? .completed : .failed
            }
            answer?.retryMessage = nil
        case let .turnFailed(message, aborted):
            answer?.status = aborted ? .stopped : .running
            answer?.error = aborted ? nil : message
            answer?.retryMessage = nil
        case .authPrompt(let prompt):
            authSession?.prompt = prompt
        case .authEvent(let event):
            authSession?.event = event
        case .authCompleted:
            authSession = nil
            scheduleRuntimeRestart()
        case .logoutCompleted:
            break
        case .extensionNotice(let message):
            if answer?.status == .waiting || answer?.status == .running {
                appendText(message)
            }
        case .extensionPrompt(let prompt):
            extensionPrompt = prompt
        case .operationFailed(let message):
            if authSession != nil {
                authSession?.error = message
            } else if isAnswering {
                answer?.status = .failed
                answer?.error = message
            } else {
                runtimeError = message
            }
        case .runtimeExited(let message):
            runtimeReady = false
            runtimeStarting = false
            extensionPrompt = nil
            runtimeError = message
            if isAnswering {
                answer?.status = .failed
                answer?.error = message
            }
        }
        notifyPanel()
    }

    // Appends streamed Markdown to the current text block or starts a new one after another block type.
    private func appendText(_ delta: String) {
        guard answer != nil else {
            runtimeError = "收到回答时没有活动问题"
            return
        }
        if let index = answer?.sections.indices.last,
           case .markdown(let text) = answer?.sections[index].content {
            answer?.sections[index].content = .markdown(text + delta)
        } else {
            answer?.sections.append(AnswerSection(id: UUID(), content: .markdown(delta)))
        }
    }

    // Appends private reasoning to its own collapsible block without mixing it into the answer text.
    private func appendThinking(_ delta: String) {
        guard answer != nil else {
            runtimeError = "收到思考内容时没有活动问题"
            return
        }
        if let index = answer?.sections.indices.last,
           case .thinking(let text) = answer?.sections[index].content {
            answer?.sections[index].content = .thinking(text + delta)
        } else {
            answer?.sections.append(AnswerSection(id: UUID(), content: .thinking(delta)))
        }
    }

    // Replaces the tool block matching Pi's call id with its current output and status.
    private func updateTool(id: String, output: String, status: ToolStatus) {
        guard let index = answer?.sections.firstIndex(where: { section in
            if case .tool(let tool) = section.content {
                return tool.callId == id
            }
            return false
        }), case .tool(var tool) = answer?.sections[index].content else {
            answer?.status = .failed
            answer?.error = "收到未知工具调用的执行结果"
            return
        }
        tool.output = output
        tool.status = status
        answer?.sections[index].content = .tool(tool)
    }

    // Notifies AppKit when answer visibility or dynamic result content changes.
    private func notifyPanel() {
        panelContentChanged?()
    }
}
