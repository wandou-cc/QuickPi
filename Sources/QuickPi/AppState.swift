import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var builtInProviders: [ProviderStatus] = []
    @Published private(set) var builtInModels: [ModelOption] = []
    @Published private(set) var runtimeReady = false
    @Published private(set) var runtimeStarting = false
    @Published private(set) var answer: AnswerSession?
    @Published var draft = ""
    @Published var attachments: [PendingAttachment] = []
    @Published var runtimeError: String?
    @Published var shortcutError: String?
    @Published var settingsPresented = false
    @Published var authSession: AuthSession?

    private let store: ConfigurationStore
    private let runtime: PiRuntime
    let checkForUpdates: () -> Void
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

    var showsResultPanel: Bool {
        answer != nil || runtimeError != nil
    }

    // Loads the only business settings document and binds the managed Pi process events.
    init(applicationSupportDirectory: URL, checkForUpdates: @escaping () -> Void) throws {
        store = ConfigurationStore(applicationSupportDirectory: applicationSupportDirectory)
        settings = try store.load()
        runtime = PiRuntime(applicationSupportDirectory: applicationSupportDirectory)
        self.checkForUpdates = checkForUpdates
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
        guard let model = selectedModel else {
            settingsPresented = true
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
        guard images.isEmpty || model.supportsImages else {
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
        draft = ""
        attachments = []
        runtimeError = nil
        answer = AnswerSession(
            question: SubmittedQuestion(text: question, attachmentNames: attachmentNames),
            startedAt: Date(),
            sections: [],
            status: .waiting
        )
        notifyPanel()

        do {
            try await runtime.newSession()
            guard generation == answerGeneration else {
                return
            }
            try await runtime.prompt(message: prompt, images: images)
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

    // Clears the visible result after stopping an active turn; every new question creates its own session.
    func clearAnswer() async {
        answerGeneration += 1
        let generation = answerGeneration
        do {
            if isAnswering {
                try await runtime.abort()
            }
            guard generation == answerGeneration else {
                return
            }
            answer = nil
            runtimeError = nil
        } catch {
            guard generation == answerGeneration else {
                return
            }
            runtimeError = error.localizedDescription
        }
        notifyPanel()
    }

    // Saves general settings and restarts Pi only when tool permissions changed.
    func saveDesktopSettings(
        shortcut: String,
        launchAtLogin: Bool,
        terminalAccess: Bool,
        fileSystemAccess: Bool
    ) async throws {
        guard !terminalAccess || fileSystemAccess else {
            throw QuickPiError.message("终端权限必须同时开启文件系统权限")
        }
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

        let permissionsChanged = terminalAccess != settings.terminalAccess
            || fileSystemAccess != settings.fileSystemAccess
        var next = settings
        next.shortcut = shortcut
        next.launchAtLogin = launchAtLogin
        next.terminalAccess = terminalAccess
        next.fileSystemAccess = fileSystemAccess
        settings = try store.save(next)

        if permissionsChanged {
            scheduleRuntimeRestart()
        }
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
    private func scheduleRuntimeRestart() {
        runtimeGeneration += 1
        runtimeReady = false
        runtimeStarting = true
        if isAnswering {
            answerGeneration += 1
            answer?.status = .stopped
            answer?.retryMessage = nil
        }
        runtime.stop()
        notifyPanel()
        let generation = runtimeGeneration
        Task { await launchRuntime(generation: generation) }
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

    // Applies every Pi event to the current answer, authentication sheet, or runtime status.
    private func consume(_ event: PiRuntimeEvent) {
        switch event {
        case .agentStarted:
            if answer?.status == .waiting || answer?.status == .running {
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
