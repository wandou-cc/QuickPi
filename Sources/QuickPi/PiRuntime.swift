import Foundation

enum PiSessionLaunch {
    case mostRecent
    case existing(path: String)
    case new(id: String)
}

enum PiRuntimeEvent {
    case agentStarted
    case userMessage(String)
    case userMessagePersisted
    case textDelta(String)
    case thinkingDelta(String)
    case toolStarted(id: String, name: String, input: String)
    case toolUpdated(id: String, output: String)
    case toolFinished(id: String, output: String, isError: Bool)
    case assistantMetadata(provider: String, model: String, usage: PiUsage, stopReason: String)
    case retrying(String)
    case settled
    case turnFailed(message: String, aborted: Bool)
    case authPrompt(AuthPrompt)
    case authEvent(AuthEvent)
    case authCompleted(String)
    case logoutCompleted(String)
    case customMessage(PiCustomMessage)
    case extensionNotification(ExtensionNotification)
    case extensionStatus(key: String, text: String?)
    case extensionWidget(key: String, lines: [String]?, placement: ExtensionWidget.Placement)
    case extensionTitle(String)
    case extensionEditorText(String)
    case extensionPrompt(ExtensionPrompt)
    case operationFailed(String)
    case runtimeExited(String)
}

@MainActor
final class PiRuntime {
    private enum Stream {
        case standardOutput
        case standardError
    }

    private struct RPCCommand: Encodable {
        let id: String?
        let type: String
        let message: String?
        let images: [ImagePayload]?
        let provider: String?
        let modelId: String?
        let level: ThinkingLevel?
        let sessionPath: String?
        let name: String?
        let customInstructions: String?

        // Builds one command from the fields defined by Pi's RPC protocol.
        init(
            id: String? = nil,
            type: String,
            message: String? = nil,
            images: [ImagePayload]? = nil,
            provider: String? = nil,
            modelId: String? = nil,
            level: ThinkingLevel? = nil,
            sessionPath: String? = nil,
            name: String? = nil,
            customInstructions: String? = nil
        ) {
            self.id = id
            self.type = type
            self.message = message
            self.images = images
            self.provider = provider
            self.modelId = modelId
            self.level = level
            self.sessionPath = sessionPath
            self.name = name
            self.customInstructions = customInstructions
        }
    }

    private struct ExtensionUIResponse: Encodable {
        let type = "extension_ui_response"
        let id: String
        let value: String?
        let confirmed: Bool?
        let cancelled: Bool?
    }

    private struct CommitMessageRequest: Encodable {
        let requestId: String
        let context: String
    }

    private struct EnvelopeType: Decodable {
        let type: String
    }

    private struct ResponseEnvelope: Decodable {
        let id: String?
        let success: Bool
        let error: String?
        let data: JSONValue?
    }

    private struct RuntimeStateResponse: Decodable {
        let thinkingLevel: ThinkingLevel
    }

    private struct ThinkingLevelsResponse: Decodable {
        let levels: [ThinkingLevel]
    }

    private struct MessageUpdateEnvelope: Decodable {
        struct AssistantEvent: Decodable {
            struct AssistantError: Decodable {
                let errorMessage: String
            }

            let type: String
            let delta: String?
            let reason: String?
            let error: AssistantError?
        }

        let assistantMessageEvent: AssistantEvent
    }

    private struct MessageEndEnvelope: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                struct Cost: Decodable {
                    let total: Double
                }

                let input: Int
                let output: Int
                let cacheRead: Int
                let cacheWrite: Int
                let cost: Cost
            }

            let provider: String?
            let model: String?
            let usage: Usage?
            let stopReason: String?
            let errorMessage: String?
        }

        let message: Message
    }

    private struct MessageRoleEnvelope: Decodable {
        struct Message: Decodable {
            let role: String
        }

        let message: Message
    }

    private struct MessageStartEnvelope: Decodable {
        struct Message: Decodable {
            let role: String
            let content: CustomMessageContent
        }

        let message: Message
    }

    private enum CustomMessageContent: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
            let mimeType: String?
        }

        case text(String)
        case blocks([Block])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .blocks(try container.decode([Block].self))
            }
        }
    }

    private struct CustomMessageEndEnvelope: Decodable {
        let message: PiCustomMessage
    }

    private struct ToolExecutionStartEnvelope: Decodable {
        let toolCallId: String
        let toolName: String
        let args: JSONValue
    }

    private struct ToolExecutionUpdateEnvelope: Decodable {
        let toolCallId: String
        let partialResult: ToolResult
    }

    private struct ToolExecutionEndEnvelope: Decodable {
        let toolCallId: String
        let result: ToolResult
        let isError: Bool
    }

    private struct ToolResult: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
            let mimeType: String?
        }

        let content: [Content]
    }

    private struct RetryEnvelope: Decodable {
        let attempt: Int
        let maxAttempts: Int
        let delayMs: Int
        let errorMessage: String
    }

    private struct ExtensionErrorEnvelope: Decodable {
        let error: String
    }

    private struct ExtensionRequestEnvelope: Decodable {
        let id: String?
        let method: String
        let message: String?
        let title: String?
        let placeholder: String?
        let options: [String]?
        let prefill: String?
        let text: String?
        let notifyType: String?
        let statusKey: String?
        let statusText: String?
        let widgetKey: String?
        let widgetLines: [String]?
        let widgetPlacement: String?
    }

    private struct ExtensionPayload: Decodable {
        struct WireAuthEvent: Decodable {
            struct Link: Decodable {
                let url: String
                let label: String?
            }

            let type: String
            let message: String?
            let links: [Link]?
            let url: String?
            let instructions: String?
            let userCode: String?
            let verificationUri: String?
        }

        struct WirePrompt: Decodable {
            struct Option: Decodable {
                let id: String
                let label: String
                let description: String?
            }

            let type: String
            let message: String
            let placeholder: String?
            let options: [Option]?
        }

        let kind: String
        let snapshot: RuntimeSnapshot?
        let sessionSnapshot: SessionSnapshot?
        let event: WireAuthEvent?
        let prompt: WirePrompt?
        let providerId: String?
        let requestId: String?
        let message: String?
        let error: String?
    }

    private let applicationSupportDirectory: URL
    private var process: Process?
    private var input: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var standardOutputBuffer = Data()
    private var standardErrorBuffer = Data()
    private var activeRunId: UUID?
    private var errorOutput: [String] = []
    private var commandContinuations: [String: (Result<JSONValue?, Error>) -> Void] = [:]
    private var commitMessageContinuations: [String: (Result<String, Error>) -> Void] = [:]
    private var snapshotContinuation: CheckedContinuation<RuntimeSnapshot, Error>?
    private var sessionSnapshotContinuation: CheckedContinuation<SessionSnapshot, Error>?
    private var cloneTurnContinuation: CheckedContinuation<SessionSnapshot, Error>?
    private var deleteSessionContinuation: CheckedContinuation<SessionSnapshot, Error>?
    private var deleteSessionsContinuation: CheckedContinuation<SessionSnapshot, Error>?
    private var logoutContinuation: CheckedContinuation<String, Error>?

    var onEvent: ((PiRuntimeEvent) -> Void)?

    // Keeps Quick Pi's providers and sessions isolated while Pi loads its normal global resources.
    init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    // Starts the bundled official Pi process and verifies that its RPC loop answers.
    func start(
        settings: AppSettings,
        workingDirectoryURL: URL,
        session: PiSessionLaunch = .mostRecent
    ) async throws {
        guard process == nil else {
            throw QuickPiError.message("Pi 已经在运行")
        }
        guard let piURL = Bundle.main.url(forResource: "pi", withExtension: nil, subdirectory: "pi-runtime"),
              let extensionURL = Bundle.main.url(forResource: "quick-pi-extension", withExtension: "js"),
              let planModeURL = Bundle.main.url(
                forResource: "index",
                withExtension: "ts",
                subdirectory: "plan-mode"
              ) else {
            throw QuickPiError.message("应用内的 Pi 运行文件不完整")
        }

        let currentDirectoryURL = workingDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: currentDirectoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw QuickPiError.message("会话运行目录不存在：\(currentDirectoryURL.path)")
        }

        let runId = UUID()
        let nextProcess = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        nextProcess.executableURL = piURL
        nextProcess.currentDirectoryURL = currentDirectoryURL
        nextProcess.arguments = arguments(
            settings: settings,
            extensionURL: extensionURL,
            planModeURL: planModeURL,
            session: session
        )
        nextProcess.standardInput = inputPipe
        nextProcess.standardOutput = outputPipe
        nextProcess.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        let quickPiDirectory = applicationSupportDirectory.appendingPathComponent("pi", isDirectory: true)
        environment["PI_CODING_AGENT_DIR"] = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent", isDirectory: true).path
        environment["PI_CODING_AGENT_SESSION_DIR"] = quickPiDirectory
            .appendingPathComponent("sessions", isDirectory: true).path
        environment["QUICK_PI_DATA_DIR"] = quickPiDirectory.path
        environment["PI_OFFLINE"] = "1"
        nextProcess.environment = environment
        nextProcess.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                self?.processDidTerminate(terminatedProcess, runId: runId)
            }
        }

        try nextProcess.run()
        process = nextProcess
        activeRunId = runId
        errorOutput = []
        standardOutputBuffer.removeAll(keepingCapacity: true)
        standardErrorBuffer.removeAll(keepingCapacity: true)
        input = inputPipe.fileHandleForWriting
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        standardOutput = outputHandle
        standardError = errorHandle
        readRecords(
            from: outputHandle,
            stream: .standardOutput,
            runId: runId
        )
        readRecords(
            from: errorHandle,
            stream: .standardError,
            runId: runId
        )
        do {
            try await sendCommand(type: "get_state")
        } catch {
            if activeRunId == runId {
                stop()
            }
            throw error
        }
    }

    // Stops the active process as an expected lifecycle action without publishing an error.
    func stop() {
        guard let process else {
            return
        }
        activeRunId = nil
        self.process = nil
        let currentInput = input
        input = nil
        currentInput?.closeFile()
        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        standardOutput?.closeFile()
        standardError?.closeFile()
        standardOutput = nil
        standardError = nil
        standardOutputBuffer.removeAll(keepingCapacity: true)
        standardErrorBuffer.removeAll(keepingCapacity: true)
        process.terminate()
        failPendingCommands(with: CancellationError())
    }

    // Requests built-in Provider login state and available models from the extension.
    func snapshot() async throws -> RuntimeSnapshot {
        guard snapshotContinuation == nil else {
            throw QuickPiError.message("Provider 状态正在读取")
        }
        return try await withCheckedThrowingContinuation { continuation in
            snapshotContinuation = continuation
            do {
                try sendWithoutResponse(type: "prompt", message: "/quick-snapshot")
            } catch {
                snapshotContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // Reads the saved sessions and active branch for the process working directory.
    func sessionSnapshot() async throws -> SessionSnapshot {
        guard sessionSnapshotContinuation == nil else {
            throw QuickPiError.message("会话状态正在读取")
        }
        return try await withCheckedThrowingContinuation { continuation in
            sessionSnapshotContinuation = continuation
            do {
                try sendWithoutResponse(type: "prompt", message: "/quick-session-snapshot")
            } catch {
                sessionSnapshotContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // Selects the exact Provider and model, then reads Pi's effective reasoning capability.
    func selectModel(_ selection: ModelSelection) async throws -> PiThinkingState {
        try await sendCommand(
            type: "set_model",
            provider: selection.providerId,
            modelId: selection.modelId
        )
        return try await thinkingState()
    }

    // Applies one level accepted by the current model and returns Pi's effective state.
    func selectThinkingLevel(_ level: ThinkingLevel) async throws -> PiThinkingState {
        try await sendCommand(type: "set_thinking_level", level: level)
        return try await thinkingState()
    }

    // Reads the current level and the model-specific list from Pi's documented RPC commands.
    private func thinkingState() async throws -> PiThinkingState {
        let state = try await sendCommand(type: "get_state", response: RuntimeStateResponse.self)
        let available = try await sendCommand(
            type: "get_available_thinking_levels",
            response: ThinkingLevelsResponse.self
        )
        guard available.levels.contains(state.thinkingLevel) else {
            throw QuickPiError.message("Pi 返回的当前推理强度不在可用列表中")
        }
        return PiThinkingState(level: state.thinkingLevel, availableLevels: available.levels)
    }

    // Starts one built-in Provider authentication flow through Pi's extension UI protocol.
    func login(providerId: String, authType: String) throws {
        try sendWithoutResponse(
            type: "prompt",
            message: "/quick-login \(providerId) \(authType)"
        )
    }

    // Removes a built-in Provider credential and waits for the extension's confirmation.
    func logout(providerId: String) async throws {
        guard logoutContinuation == nil else {
            throw QuickPiError.message("另一个退出操作尚未完成")
        }
        _ = try await withCheckedThrowingContinuation { continuation in
            logoutContinuation = continuation
            do {
                try sendWithoutResponse(type: "prompt", message: "/quick-logout \(providerId)")
            } catch {
                logoutContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // Returns a native authentication input or cancellation to its matching Pi request.
    func respondToAuth(requestId: String, value: String?) throws {
        let response = ExtensionUIResponse(
            id: requestId,
            value: value,
            confirmed: nil,
            cancelled: value == nil ? true : nil
        )
        try write(response)
    }

    // Returns one native response to an interactive prompt opened by a loaded extension.
    func respondToExtensionPrompt(
        requestId: String,
        value: String? = nil,
        confirmed: Bool? = nil,
        cancelled: Bool? = nil
    ) throws {
        try write(ExtensionUIResponse(
            id: requestId,
            value: value,
            confirmed: confirmed,
            cancelled: cancelled
        ))
    }

    // Sends registered slash commands unchanged while keeping normal questions outside that namespace.
    func prompt(message: String, images: [ImagePayload]) async throws {
        try await sendCommand(
            type: "prompt",
            message: message,
            images: images
        )
    }

    // Uses the active Pi model for one isolated completion that does not enter the conversation history.
    func generateCommitMessage(context: String) async throws -> String {
        let requestId = UUID().uuidString
        let requestData = try JSONEncoder().encode(CommitMessageRequest(
            requestId: requestId,
            context: context
        ))
        let encodedRequest = requestData.base64EncodedString()
        return try await withCheckedThrowingContinuation { continuation in
            commitMessageContinuations[requestId] = { result in
                continuation.resume(with: result)
            }
            do {
                try sendWithoutResponse(
                    type: "prompt",
                    message: "/quick-generate-commit-message \(encodedRequest)"
                )
            } catch {
                commitMessageContinuations[requestId] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // Aborts the current model turn through the documented RPC command.
    func abort() async throws {
        try await sendCommand(type: "abort")
    }

    // Sets the display name stored on the active Pi session.
    func setSessionName(_ name: String) async throws {
        try await sendCommand(type: "set_session_name", name: name)
    }

    // Reads Pi's exact token, message, tool, cost, and context statistics.
    func sessionStats() async throws -> PiSessionStats {
        try await sendCommand(type: "get_session_stats", response: PiSessionStats.self)
    }

    // Runs Pi's manual context compaction with optional user instructions.
    func compact(instructions: String?) async throws -> PiCompactionResult {
        try await sendCommand(
            type: "compact",
            customInstructions: instructions,
            response: PiCompactionResult.self
        )
    }

    // Clones the current branch into a new Pi session.
    func cloneSession() async throws -> PiCloneResult {
        try await sendCommand(type: "clone", response: PiCloneResult.self)
    }

    // Clones one completed user turn at its final branch entry and returns the new session.
    func cloneTurn(entryId: String) async throws -> SessionSnapshot {
        guard cloneTurnContinuation == nil else {
            throw QuickPiError.message("另一个会话克隆尚未完成")
        }
        return try await withCheckedThrowingContinuation { continuation in
            cloneTurnContinuation = continuation
            do {
                try sendWithoutResponse(type: "prompt", message: "/quick-clone-turn \(entryId)")
            } catch {
                cloneTurnContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // Returns persisted user-message ids used as stable turn anchors by Quick Pi.
    func forkMessages() async throws -> [PiForkMessage] {
        let result = try await sendCommand(
            type: "get_fork_messages",
            response: PiForkMessages.self
        )
        return result.messages
    }

    // Exports the active Pi session through the bundled HTML exporter.
    func exportHTML() async throws -> PiExportResult {
        try await sendCommand(type: "export_html", response: PiExportResult.self)
    }

    // Replaces the active session, removes every older Pi session, and returns the new state.
    func deleteAllSessions() async throws -> SessionSnapshot {
        guard deleteSessionsContinuation == nil else {
            throw QuickPiError.message("会话正在删除")
        }
        return try await withCheckedThrowingContinuation { continuation in
            deleteSessionsContinuation = continuation
            do {
                try sendWithoutResponse(type: "prompt", message: "/quick-delete-all-sessions")
            } catch {
                deleteSessionsContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // Deletes one inactive Pi session and returns the refreshed project session list.
    func deleteSession(id: String) async throws -> SessionSnapshot {
        guard deleteSessionContinuation == nil else {
            throw QuickPiError.message("另一个会话正在删除")
        }
        return try await withCheckedThrowingContinuation { continuation in
            deleteSessionContinuation = continuation
            do {
                try sendWithoutResponse(type: "prompt", message: "/quick-delete-session \(id)")
            } catch {
                deleteSessionContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // Enables Pi's native tools and resource discovery in the selected working directory.
    private func arguments(
        settings: AppSettings,
        extensionURL: URL,
        planModeURL: URL,
        session: PiSessionLaunch
    ) -> [String] {
        var values = [
            "--mode", "rpc",
            "--extension", extensionURL.path,
            "--extension", planModeURL.path,
            "--offline",
        ]
        switch session {
        case .mostRecent:
            values.append("--continue")
        case .existing(let path):
            values.append(contentsOf: ["--session", path])
        case .new(let id):
            values.append(contentsOf: ["--session-id", id])
        }
        if settings.workspacePath != nil {
            values.append(contentsOf: [
                "--approve",
                "--append-system-prompt",
                "The user selected the current working directory as the project workspace. Inspect the project before editing, keep file operations inside this workspace unless the user explicitly asks otherwise, and answer in the user's language.",
            ])
        } else {
            values.append(contentsOf: [
                "--no-context-files",
                "--system-prompt",
                "You are a concise, accurate general-purpose assistant. Answer in the user's language and use Markdown when it improves clarity.",
            ])
        }
        return values
    }

    // Sends a correlated command and resumes only from its matching Pi response id.
    private func sendCommand(
        type: String,
        message: String? = nil,
        images: [ImagePayload]? = nil,
        provider: String? = nil,
        modelId: String? = nil,
        level: ThinkingLevel? = nil,
        sessionPath: String? = nil,
        name: String? = nil,
        customInstructions: String? = nil
    ) async throws {
        let id = UUID().uuidString
        try await withCheckedThrowingContinuation { continuation in
            commandContinuations[id] = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            do {
                try write(RPCCommand(
                    id: id,
                    type: type,
                    message: message,
                    images: images,
                    provider: provider,
                    modelId: modelId,
                    level: level,
                    sessionPath: sessionPath,
                    name: name,
                    customInstructions: customInstructions
                ))
            } catch {
                commandContinuations[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // Sends a correlated command and decodes the documented response data object.
    private func sendCommand<Response: Decodable>(
        type: String,
        customInstructions: String? = nil,
        response: Response.Type
    ) async throws -> Response {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            commandContinuations[id] = { result in
                switch result {
                case .success(let value):
                    guard let value else {
                        continuation.resume(throwing: QuickPiError.message("Pi RPC 响应缺少数据"))
                        return
                    }
                    do {
                        let data = try JSONEncoder().encode(value)
                        continuation.resume(returning: try JSONDecoder().decode(Response.self, from: data))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            do {
                try write(RPCCommand(
                    id: id,
                    type: type,
                    customInstructions: customInstructions
                ))
            } catch {
                commandContinuations[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // Sends an extension command whose completion arrives as a structured notification.
    private func sendWithoutResponse(type: String, message: String) throws {
        try write(RPCCommand(type: type, message: message))
    }

    // Writes one Codable value as a single LF-delimited RPC record.
    private func write<T: Encodable>(_ value: T) throws {
        guard let input else {
            throw QuickPiError.message("Pi 尚未启动")
        }
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    // Reads each pipe only when Foundation reports available bytes, avoiding blocking Swift's executor.
    private func readRecords(
        from handle: FileHandle,
        stream: Stream,
        runId: UUID
    ) {
        handle.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            if data.isEmpty {
                readableHandle.readabilityHandler = nil
            }
            Task { @MainActor [weak self] in
                self?.consume(data: data, stream: stream, runId: runId)
            }
        }
    }

    // Frames arbitrary pipe chunks strictly on LF as required by Pi's JSONL protocol.
    private func consume(data: Data, stream: Stream, runId: UUID) {
        guard activeRunId == runId else {
            return
        }
        var buffer: Data
        switch stream {
        case .standardOutput:
            standardOutputBuffer.append(data)
            buffer = standardOutputBuffer
        case .standardError:
            standardErrorBuffer.append(data)
            buffer = standardErrorBuffer
        }

        while let newline = buffer.firstIndex(of: 0x0A) {
            var record = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if record.last == 0x0D {
                record.removeLast()
            }
            if !record.isEmpty {
                consume(record: record, stream: stream, runId: runId)
            }
        }

        switch stream {
        case .standardOutput:
            standardOutputBuffer = buffer
        case .standardError:
            standardErrorBuffer = buffer
        }
        if data.isEmpty && !buffer.isEmpty {
            streamEndedWithPartialRecord(stream: stream, runId: runId)
        }
    }

    // Routes one complete stdout record or retains stderr for an unexpected exit report.
    private func consume(record: Data, stream: Stream, runId: UUID) {
        guard activeRunId == runId else {
            return
        }
        if stream == .standardError {
            errorOutput.append(String(decoding: record, as: UTF8.self))
            if errorOutput.count > 20 {
                errorOutput.removeFirst(errorOutput.count - 20)
            }
            return
        }

        do {
            let type = try JSONDecoder().decode(EnvelopeType.self, from: record).type
            switch type {
            case "response":
                try consumeResponse(record)
            case "agent_start":
                onEvent?(.agentStarted)
            case "message_start":
                try consumeMessageStart(record)
            case "agent_settled":
                onEvent?(.settled)
            case "message_update":
                try consumeMessageUpdate(record)
            case "message_end":
                try consumeMessageEnd(record)
            case "tool_execution_start":
                try consumeToolStart(record)
            case "tool_execution_update":
                try consumeToolUpdate(record)
            case "tool_execution_end":
                try consumeToolEnd(record)
            case "auto_retry_start":
                let retry = try JSONDecoder().decode(RetryEnvelope.self, from: record)
                let delay = Double(retry.delayMs) / 1_000
                onEvent?(.retrying(
                    "第 \(retry.attempt)/\(retry.maxAttempts) 次重试，\(delay.formatted()) 秒后继续：\(retry.errorMessage)"
                ))
            case "extension_ui_request":
                try consumeExtensionRequest(record)
            case "extension_error":
                let envelope = try JSONDecoder().decode(ExtensionErrorEnvelope.self, from: record)
                failExtensionOperation(with: QuickPiError.message(envelope.error))
            default:
                break
            }
        } catch {
            onEvent?(.operationFailed("Pi RPC 数据无效：\(error.localizedDescription)"))
        }
    }

    // Completes the command continuation identified by a response id.
    private func consumeResponse(_ record: Data) throws {
        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: record)
        guard let id = envelope.id,
              let continuation = commandContinuations.removeValue(forKey: id) else {
            return
        }
        if envelope.success {
            continuation(.success(envelope.data))
        } else {
            guard let error = envelope.error else {
                continuation(.failure(QuickPiError.message("Pi RPC 错误响应缺少说明")))
                return
            }
            continuation(.failure(QuickPiError.message(error)))
        }
    }

    // Publishes user messages injected by extensions so background plugin turns have visible context.
    private func consumeMessageStart(_ record: Data) throws {
        let message = try JSONDecoder().decode(MessageStartEnvelope.self, from: record).message
        guard message.role == "user" else {
            return
        }
        let text: String
        switch message.content {
        case .text(let value):
            text = value
        case .blocks(let blocks):
            text = try blocks.map { block in
                switch block.type {
                case "text":
                    guard let value = block.text else {
                        throw QuickPiError.message("Pi 用户文本消息缺少内容")
                    }
                    return value
                case "image":
                    guard let mimeType = block.mimeType else {
                        throw QuickPiError.message("Pi 用户图片消息缺少类型")
                    }
                    return "[图片：\(mimeType)]"
                default:
                    throw QuickPiError.message("未知的 Pi 用户消息类型：\(block.type)")
                }
            }.joined(separator: "\n")
        }
        onEvent?(.userMessage(text))
    }

    // Publishes text, thinking, and terminal model errors from a streaming assistant event.
    private func consumeMessageUpdate(_ record: Data) throws {
        let event = try JSONDecoder().decode(MessageUpdateEnvelope.self, from: record)
            .assistantMessageEvent
        switch event.type {
        case "text_delta":
            guard let delta = event.delta else {
                throw QuickPiError.message("Pi 文本增量缺少内容")
            }
            onEvent?(.textDelta(delta))
        case "thinking_delta":
            guard let delta = event.delta else {
                throw QuickPiError.message("Pi 思考增量缺少内容")
            }
            onEvent?(.thinkingDelta(delta))
        case "error":
            let aborted = event.reason == "aborted"
            if aborted {
                onEvent?(.turnFailed(message: "已停止回答", aborted: true))
            } else {
                guard let error = event.error else {
                    throw QuickPiError.message("Pi 模型错误缺少说明")
                }
                onEvent?(.turnFailed(message: error.errorMessage, aborted: false))
            }
        default:
            break
        }
    }

    // Publishes the complete Pi custom-message contract or metadata from a completed assistant turn.
    private func consumeMessageEnd(_ record: Data) throws {
        let role = try JSONDecoder().decode(MessageRoleEnvelope.self, from: record).message.role
        if role == "user" {
            onEvent?(.userMessagePersisted)
            return
        }
        if role == "custom" {
            let message = try JSONDecoder().decode(CustomMessageEndEnvelope.self, from: record).message
            onEvent?(.customMessage(message))
            return
        }
        guard role == "assistant" else {
            return
        }
        let message = try JSONDecoder().decode(MessageEndEnvelope.self, from: record).message
        guard let provider = message.provider,
              let model = message.model,
              let usage = message.usage,
              let stopReason = message.stopReason else {
            throw QuickPiError.message("Pi 助手消息元数据不完整")
        }
        onEvent?(.assistantMetadata(
            provider: provider,
            model: model,
            usage: PiUsage(
                input: usage.input,
                output: usage.output,
                cacheRead: usage.cacheRead,
                cacheWrite: usage.cacheWrite,
                cost: usage.cost.total
            ),
            stopReason: stopReason
        ))
        if stopReason == "error" {
            guard let errorMessage = message.errorMessage, !errorMessage.isEmpty else {
                throw QuickPiError.message("Pi 助手错误消息缺少说明")
            }
            onEvent?(.turnFailed(message: errorMessage, aborted: false))
        }
    }

    // Publishes a readable, stable representation of a tool call and its arguments.
    private func consumeToolStart(_ record: Data) throws {
        let envelope = try JSONDecoder().decode(ToolExecutionStartEnvelope.self, from: record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let input = String(decoding: try encoder.encode(envelope.args), as: UTF8.self)
        onEvent?(.toolStarted(id: envelope.toolCallId, name: envelope.toolName, input: input))
    }

    // Replaces one tool's accumulated output with Pi's latest partial result.
    private func consumeToolUpdate(_ record: Data) throws {
        let envelope = try JSONDecoder().decode(ToolExecutionUpdateEnvelope.self, from: record)
        onEvent?(.toolUpdated(id: envelope.toolCallId, output: try toolText(envelope.partialResult)))
    }

    // Completes one tool entry with its final output and explicit error state.
    private func consumeToolEnd(_ record: Data) throws {
        let envelope = try JSONDecoder().decode(ToolExecutionEndEnvelope.self, from: record)
        onEvent?(.toolFinished(
            id: envelope.toolCallId,
            output: try toolText(envelope.result),
            isError: envelope.isError
        ))
    }

    // Converts documented text and image tool-result blocks into a compact native display.
    private func toolText(_ result: ToolResult) throws -> String {
        try result.content.map { content in
            switch content.type {
            case "text":
                guard let text = content.text else {
                    throw QuickPiError.message("Pi 工具文本结果缺少内容")
                }
                return text
            case "image":
                guard let mimeType = content.mimeType else {
                    throw QuickPiError.message("Pi 工具图片结果缺少类型")
                }
                return "[图片：\(mimeType)]"
            default:
                throw QuickPiError.message("未知的 Pi 工具结果类型：\(content.type)")
            }
        }.joined(separator: "\n")
    }

    // Removes terminal SGR styling because native SwiftUI renders extension status text itself.
    private func plainExtensionText(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
    }

    // Decodes Quick Pi control messages and public interaction requests from loaded extensions.
    func consumeExtensionRequest(_ record: Data) throws {
        let envelope = try JSONDecoder().decode(ExtensionRequestEnvelope.self, from: record)
        if envelope.method == "notify" {
            guard let message = envelope.message else {
                throw QuickPiError.message("Pi 扩展通知缺少内容")
            }
            if message.hasPrefix("quickpi:") {
                let payload = try decodeExtensionPayload(String(message.dropFirst("quickpi:".count)))
                try consumeExtensionPayload(payload)
            } else {
                let rawKind = envelope.notifyType ?? ExtensionNotificationKind.info.rawValue
                guard let kind = ExtensionNotificationKind(rawValue: rawKind) else {
                    throw QuickPiError.message("未知的 Pi 扩展通知类型：\(rawKind)")
                }
                onEvent?(.extensionNotification(ExtensionNotification(message: message, kind: kind)))
            }
            return
        }
        if envelope.method == "setStatus" {
            guard let key = envelope.statusKey else {
                throw QuickPiError.message("Pi 扩展状态缺少标识")
            }
            onEvent?(.extensionStatus(key: key, text: envelope.statusText.map(plainExtensionText)))
            return
        }
        if envelope.method == "setWidget" {
            guard let key = envelope.widgetKey else {
                throw QuickPiError.message("Pi 扩展 Widget 缺少标识")
            }
            let rawPlacement = envelope.widgetPlacement ?? ExtensionWidget.Placement.aboveEditor.rawValue
            guard let placement = ExtensionWidget.Placement(rawValue: rawPlacement) else {
                throw QuickPiError.message("未知的 Pi 扩展 Widget 位置：\(rawPlacement)")
            }
            onEvent?(.extensionWidget(
                key: key,
                lines: envelope.widgetLines?.map(plainExtensionText),
                placement: placement
            ))
            return
        }
        if envelope.method == "setTitle" {
            guard let title = envelope.title else {
                throw QuickPiError.message("Pi 扩展窗口标题缺少内容")
            }
            onEvent?(.extensionTitle(title))
            return
        }
        if envelope.method == "set_editor_text" {
            guard let text = envelope.text else {
                throw QuickPiError.message("Pi 扩展输入框消息缺少内容")
            }
            onEvent?(.extensionEditorText(text))
            return
        }
        if envelope.method == "input" || envelope.method == "select" {
            if let requestId = envelope.id,
               let title = envelope.title,
               title.hasPrefix("quickpi:") {
                let payload = try decodeExtensionPayload(String(title.dropFirst("quickpi:".count)))
                guard payload.kind == "authPrompt", let prompt = payload.prompt else {
                    throw QuickPiError.message("Pi 登录提示无效")
                }
                let options: [AuthPrompt.Option]
                if prompt.type == "select" {
                    guard let promptOptions = prompt.options else {
                        throw QuickPiError.message("Pi 登录选择提示缺少选项")
                    }
                    options = promptOptions.map {
                        AuthPrompt.Option(id: $0.id, label: $0.label, description: $0.description)
                    }
                } else {
                    options = []
                }
                onEvent?(.authPrompt(AuthPrompt(
                    requestId: requestId,
                    type: prompt.type,
                    message: prompt.message,
                    placeholder: prompt.placeholder,
                    options: options
                )))
                return
            }
        }

        guard ["input", "select", "confirm", "editor"].contains(envelope.method) else {
            throw QuickPiError.message("未知的 Pi 扩展 UI 请求：\(envelope.method)")
        }
        guard let requestId = envelope.id, let title = envelope.title else {
            throw QuickPiError.message("Pi 扩展交互请求不完整")
        }
        let options: [String]
        switch envelope.method {
        case "input", "editor":
            options = []
        case "select":
            guard let requestOptions = envelope.options else {
                throw QuickPiError.message("Pi 扩展选择提示缺少选项")
            }
            options = requestOptions
        case "confirm":
            guard envelope.message != nil else {
                throw QuickPiError.message("Pi 扩展确认提示缺少说明")
            }
            options = []
        default:
            return
        }
        onEvent?(.extensionPrompt(ExtensionPrompt(
            requestId: requestId,
            method: envelope.method,
            title: title,
            message: envelope.message,
            placeholder: envelope.placeholder,
            options: options,
            prefill: envelope.prefill
        )))
    }

    // Decodes one JSON payload sent through the extension notification prefix.
    private func decodeExtensionPayload(_ text: String) throws -> ExtensionPayload {
        try JSONDecoder().decode(ExtensionPayload.self, from: Data(text.utf8))
    }

    // Applies one structured snapshot, authentication event, or logout confirmation.
    private func consumeExtensionPayload(_ payload: ExtensionPayload) throws {
        switch payload.kind {
        case "snapshot":
            guard let snapshot = payload.snapshot, let continuation = snapshotContinuation else {
                throw QuickPiError.message("Pi Provider 状态响应无效")
            }
            snapshotContinuation = nil
            continuation.resume(returning: snapshot)
        case "sessionSnapshot":
            guard let snapshot = payload.sessionSnapshot, let continuation = sessionSnapshotContinuation else {
                throw QuickPiError.message("Pi 会话状态响应无效")
            }
            sessionSnapshotContinuation = nil
            continuation.resume(returning: snapshot)
        case "sessionCloned":
            guard let snapshot = payload.sessionSnapshot, let continuation = cloneTurnContinuation else {
                throw QuickPiError.message("Pi 会话克隆响应无效")
            }
            cloneTurnContinuation = nil
            continuation.resume(returning: snapshot)
        case "sessionDeleted":
            guard let snapshot = payload.sessionSnapshot, let continuation = deleteSessionContinuation else {
                throw QuickPiError.message("Pi 单会话删除响应无效")
            }
            deleteSessionContinuation = nil
            continuation.resume(returning: snapshot)
        case "sessionsDeleted":
            guard let snapshot = payload.sessionSnapshot, let continuation = deleteSessionsContinuation else {
                throw QuickPiError.message("Pi 会话删除响应无效")
            }
            deleteSessionsContinuation = nil
            continuation.resume(returning: snapshot)
        case "authEvent":
            guard let event = payload.event else {
                throw QuickPiError.message("Pi 登录事件无效")
            }
            onEvent?(.authEvent(try authEvent(from: event)))
        case "authComplete":
            guard let providerId = payload.providerId else {
                throw QuickPiError.message("Pi 登录完成事件无效")
            }
            onEvent?(.authCompleted(providerId))
        case "logoutComplete":
            guard let providerId = payload.providerId, let continuation = logoutContinuation else {
                throw QuickPiError.message("Pi 退出事件无效")
            }
            logoutContinuation = nil
            continuation.resume(returning: providerId)
            onEvent?(.logoutCompleted(providerId))
        case "commitMessage":
            guard let requestId = payload.requestId,
                  let message = payload.message,
                  let continuation = commitMessageContinuations.removeValue(forKey: requestId) else {
                throw QuickPiError.message("Pi 提交信息响应无效")
            }
            let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                continuation(.failure(QuickPiError.message("当前模型生成了空提交信息")))
                return
            }
            continuation(.success(value))
        case "commitMessageError":
            guard let requestId = payload.requestId,
                  let message = payload.error,
                  let continuation = commitMessageContinuations.removeValue(forKey: requestId) else {
                throw QuickPiError.message("Pi 提交信息错误响应无效")
            }
            continuation(.failure(QuickPiError.message(message)))
        default:
            throw QuickPiError.message("未知的 Pi 扩展事件：\(payload.kind)")
        }
    }

    // Converts one provider-owned authentication event into native app state.
    private func authEvent(from event: ExtensionPayload.WireAuthEvent) throws -> AuthEvent {
        switch event.type {
        case "info":
            guard let message = event.message else {
                throw QuickPiError.message("Pi 登录信息缺少内容")
            }
            return .info(
                message: message,
                links: (event.links ?? []).map { (url: $0.url, label: $0.label) }
            )
        case "auth_url":
            guard let url = event.url else {
                throw QuickPiError.message("Pi 授权事件缺少地址")
            }
            return .authURL(url: url, instructions: event.instructions)
        case "device_code":
            guard let userCode = event.userCode, let verificationURI = event.verificationUri else {
                throw QuickPiError.message("Pi 设备授权事件不完整")
            }
            return .deviceCode(userCode: userCode, verificationURI: verificationURI)
        case "progress":
            guard let message = event.message else {
                throw QuickPiError.message("Pi 登录进度缺少内容")
            }
            return .progress(message)
        default:
            throw QuickPiError.message("未知的 Pi 登录事件：\(event.type)")
        }
    }

    // Resolves extension waiters and publishes the same explicit failure to the UI.
    private func failExtensionOperation(with error: Error) {
        for continuation in commitMessageContinuations.values {
            continuation(.failure(error))
        }
        commitMessageContinuations.removeAll()
        if let continuation = snapshotContinuation {
            snapshotContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = sessionSnapshotContinuation {
            sessionSnapshotContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = cloneTurnContinuation {
            cloneTurnContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = deleteSessionContinuation {
            deleteSessionContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = deleteSessionsContinuation {
            deleteSessionsContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = logoutContinuation {
            logoutContinuation = nil
            continuation.resume(throwing: error)
        }
        onEvent?(.operationFailed(error.localizedDescription))
    }

    // Resolves every outstanding continuation when its process can no longer answer.
    private func failPendingCommands(with error: Error) {
        for continuation in commandContinuations.values {
            continuation(.failure(error))
        }
        commandContinuations.removeAll()
        for continuation in commitMessageContinuations.values {
            continuation(.failure(error))
        }
        commitMessageContinuations.removeAll()
        if let continuation = snapshotContinuation {
            snapshotContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = sessionSnapshotContinuation {
            sessionSnapshotContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = cloneTurnContinuation {
            cloneTurnContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = deleteSessionContinuation {
            deleteSessionContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = deleteSessionsContinuation {
            deleteSessionsContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = logoutContinuation {
            logoutContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    // Reports a truncated JSONL record only for the currently active Pi process.
    private func streamEndedWithPartialRecord(stream: Stream, runId: UUID) {
        guard activeRunId == runId, stream == .standardOutput else {
            return
        }
        onEvent?(.operationFailed("Pi RPC 输出未以换行符结束"))
    }

    // Publishes one unexpected exit with the process status and retained stderr context.
    private func processDidTerminate(_ terminatedProcess: Process, runId: UUID) {
        guard activeRunId == runId, process === terminatedProcess else {
            return
        }
        activeRunId = nil
        process = nil
        input?.closeFile()
        input = nil
        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        standardOutput?.closeFile()
        standardError?.closeFile()
        standardOutput = nil
        standardError = nil
        standardOutputBuffer.removeAll(keepingCapacity: true)
        standardErrorBuffer.removeAll(keepingCapacity: true)
        let error = QuickPiError.message("Pi 运行进程异常退出（\(terminatedProcess.terminationStatus)）")
        failPendingCommands(with: error)
        let detail = errorOutput.joined(separator: "\n")
        onEvent?(.runtimeExited(detail.isEmpty ? error.localizedDescription : "\(error.localizedDescription)\n\(detail)"))
    }
}
