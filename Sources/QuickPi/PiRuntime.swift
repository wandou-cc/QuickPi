import Foundation

enum PiRuntimeEvent {
    case agentStarted
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

        // Builds one command from the fields defined by Pi's RPC protocol.
        init(
            id: String? = nil,
            type: String,
            message: String? = nil,
            images: [ImagePayload]? = nil,
            provider: String? = nil,
            modelId: String? = nil
        ) {
            self.id = id
            self.type = type
            self.message = message
            self.images = images
            self.provider = provider
            self.modelId = modelId
        }
    }

    private struct ExtensionUIResponse: Encodable {
        let type = "extension_ui_response"
        let id: String
        let value: String?
        let cancelled: Bool?
    }

    private struct EnvelopeType: Decodable {
        let type: String
    }

    private struct ResponseEnvelope: Decodable {
        let id: String?
        let success: Bool
        let error: String?
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

            let role: String
            let provider: String?
            let model: String?
            let usage: Usage?
            let stopReason: String?
        }

        let message: Message
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
        let event: WireAuthEvent?
        let prompt: WirePrompt?
        let providerId: String?
    }

    private enum JSONValue: Codable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case integer(Int)
        case number(Double)
        case boolean(Bool)
        case null

        // Decodes the arbitrary JSON value used for tool arguments.
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Int.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "未知 JSON 值")
            }
        }

        // Encodes tool arguments for stable, readable display in the result panel.
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .object(let value):
                try container.encode(value)
            case .array(let value):
                try container.encode(value)
            case .string(let value):
                try container.encode(value)
            case .integer(let value):
                try container.encode(value)
            case .number(let value):
                try container.encode(value)
            case .boolean(let value):
                try container.encode(value)
            case .null:
                try container.encodeNil()
            }
        }
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
    private var commandContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var snapshotContinuation: CheckedContinuation<RuntimeSnapshot, Error>?
    private var logoutContinuation: CheckedContinuation<String, Error>?

    var onEvent: ((PiRuntimeEvent) -> Void)?

    // Keeps Pi state isolated in this application's support directory.
    init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    // Starts the bundled official Pi process and verifies that its RPC loop answers.
    func start(settings: AppSettings) async throws {
        guard process == nil else {
            throw QuickPiError.message("Pi 已经在运行")
        }
        guard let piURL = Bundle.main.url(forResource: "pi", withExtension: nil, subdirectory: "pi-runtime"),
              let extensionURL = Bundle.main.url(forResource: "quick-pi-extension", withExtension: "js") else {
            throw QuickPiError.message("应用内的 Pi 运行文件不完整")
        }

        let runId = UUID()
        let nextProcess = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        nextProcess.executableURL = piURL
        nextProcess.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        nextProcess.arguments = arguments(settings: settings, extensionURL: extensionURL)
        nextProcess.standardInput = inputPipe
        nextProcess.standardOutput = outputPipe
        nextProcess.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        environment["PI_CODING_AGENT_DIR"] = applicationSupportDirectory
            .appendingPathComponent("pi", isDirectory: true).path
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

    // Selects the exact Provider and model persisted by the native app.
    func selectModel(_ selection: ModelSelection) async throws {
        try await sendCommand(
            type: "set_model",
            provider: selection.providerId,
            modelId: selection.modelId
        )
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
            cancelled: value == nil ? true : nil
        )
        try write(response)
    }

    // Prefixes user content so a leading slash cannot enter Pi's extension-command namespace.
    func prompt(message: String, images: [ImagePayload]) async throws {
        try await sendCommand(
            type: "prompt",
            message: "User request:\n\(message)",
            images: images
        )
    }

    // Aborts the current model turn through the documented RPC command.
    func abort() async throws {
        try await sendCommand(type: "abort")
    }

    // Clears Pi's in-memory conversation while preserving the running process.
    func newSession() async throws {
        try await sendCommand(type: "new_session")
    }

    // Builds Pi's command line from the two permissions explicitly stored by the user.
    private func arguments(settings: AppSettings, extensionURL: URL) -> [String] {
        var values = [
            "--mode", "rpc",
            "--no-session",
            "--no-extensions",
            "--extension", extensionURL.path,
            "--no-skills",
            "--no-prompt-templates",
            "--no-themes",
            "--no-context-files",
            "--offline",
            "--system-prompt",
            "You are a concise, accurate general-purpose assistant. Answer in the user's language and use Markdown when it improves clarity.",
        ]
        var tools: [String] = []
        if settings.terminalAccess {
            tools.append("bash")
        }
        if settings.fileSystemAccess {
            tools.append(contentsOf: ["read", "edit", "write", "grep", "find", "ls"])
        }
        if tools.isEmpty {
            values.append("--no-tools")
        } else {
            values.append(contentsOf: ["--tools", tools.joined(separator: ",")])
        }
        return values
    }

    // Sends a correlated command and resumes only from its matching Pi response id.
    private func sendCommand(
        type: String,
        message: String? = nil,
        images: [ImagePayload]? = nil,
        provider: String? = nil,
        modelId: String? = nil
    ) async throws {
        let id = UUID().uuidString
        try await withCheckedThrowingContinuation { continuation in
            commandContinuations[id] = continuation
            do {
                try write(RPCCommand(
                    id: id,
                    type: type,
                    message: message,
                    images: images,
                    provider: provider,
                    modelId: modelId
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
            continuation.resume()
        } else {
            guard let error = envelope.error else {
                continuation.resume(throwing: QuickPiError.message("Pi RPC 错误响应缺少说明"))
                return
            }
            continuation.resume(throwing: QuickPiError.message(error))
        }
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

    // Publishes model identity, usage, and stop reason for each completed assistant turn.
    private func consumeMessageEnd(_ record: Data) throws {
        let message = try JSONDecoder().decode(MessageEndEnvelope.self, from: record).message
        guard message.role == "assistant" else {
            return
        }
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

    // Decodes extension notifications and authentication prompts owned by Quick Pi.
    private func consumeExtensionRequest(_ record: Data) throws {
        let envelope = try JSONDecoder().decode(ExtensionRequestEnvelope.self, from: record)
        if envelope.method == "notify",
           let message = envelope.message,
           message.hasPrefix("quickpi:") {
            let payload = try decodeExtensionPayload(String(message.dropFirst("quickpi:".count)))
            try consumeExtensionPayload(payload)
            return
        }
        if envelope.method == "input" || envelope.method == "select" {
            guard let requestId = envelope.id,
                  let title = envelope.title,
                  title.hasPrefix("quickpi:") else {
                return
            }
            let payload = try decodeExtensionPayload(String(title.dropFirst("quickpi:".count)))
            guard payload.kind == "authPrompt", let prompt = payload.prompt else {
                throw QuickPiError.message("Pi 登录提示无效")
            }
            onEvent?(.authPrompt(AuthPrompt(
                requestId: requestId,
                type: prompt.type,
                message: prompt.message,
                placeholder: prompt.placeholder,
                options: (prompt.options ?? []).map {
                    AuthPrompt.Option(id: $0.id, label: $0.label, description: $0.description)
                }
            )))
        }
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
        if let continuation = snapshotContinuation {
            snapshotContinuation = nil
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
            continuation.resume(throwing: error)
        }
        commandContinuations.removeAll()
        if let continuation = snapshotContinuation {
            snapshotContinuation = nil
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
