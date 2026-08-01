import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAI = "openai"
    case claudeCode = "claude-code"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .claudeCode:
            "Claude Code"
        }
    }

    var piAPI: String {
        switch self {
        case .openAI:
            "openai-responses"
        case .claudeCode:
            "anthropic-messages"
        }
    }
}

struct ModelSelection: Codable, Equatable {
    let providerId: String
    let modelId: String
}

enum ThinkingLevel: String, Codable, CaseIterable, Equatable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var title: String {
        switch self {
        case .off:
            "关闭"
        case .minimal:
            "最低"
        case .low:
            "低"
        case .medium:
            "中"
        case .high:
            "高"
        case .xhigh:
            "极高"
        case .max:
            "最高"
        }
    }
}

struct ProviderConfiguration: Codable, Equatable, Identifiable {
    let id: String
    var kind: ProviderKind
    var name: String
    var baseURL: String
    var models: [String]
    var modelThinkingLevels: [String: [ThinkingLevel]]? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case kind = "type"
        case name
        case baseURL = "baseUrl"
        case models
        case modelThinkingLevels
    }
}

struct AppSettings: Codable, Equatable {
    var shortcut: String
    var launchAtLogin: Bool
    var workspacePath: String?
    var selectedModel: ModelSelection?
    var providers: [ProviderConfiguration]
    var fillInputFromClipboardOnShortcut: Bool

    enum CodingKeys: String, CodingKey {
        case shortcut
        case launchAtLogin
        case workspacePath
        case selectedModel
        case providers
        case fillInputFromClipboardOnShortcut
    }

    init(
        shortcut: String,
        launchAtLogin: Bool,
        workspacePath: String?,
        selectedModel: ModelSelection?,
        providers: [ProviderConfiguration],
        fillInputFromClipboardOnShortcut: Bool = false
    ) {
        self.shortcut = shortcut
        self.launchAtLogin = launchAtLogin
        self.workspacePath = workspacePath
        self.selectedModel = selectedModel
        self.providers = providers
        self.fillInputFromClipboardOnShortcut = fillInputFromClipboardOnShortcut
    }

    // Keeps settings written before this option existed readable with the new behavior disabled.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try container.decode(String.self, forKey: .shortcut)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath)
        selectedModel = try container.decodeIfPresent(ModelSelection.self, forKey: .selectedModel)
        providers = try container.decode([ProviderConfiguration].self, forKey: .providers)
        fillInputFromClipboardOnShortcut = try container.decodeIfPresent(
            Bool.self,
            forKey: .fillInputFromClipboardOnShortcut
        ) ?? false
    }

    // Converts the persisted project root into the directory URL used by the native picker and Pi.
    var workspaceURL: URL? {
        guard let workspacePath else {
            return nil
        }
        return URL(fileURLWithPath: workspacePath, isDirectory: true)
    }

    static let defaults = AppSettings(
        shortcut: "commandShiftSpace",
        launchAtLogin: false,
        workspacePath: nil,
        selectedModel: nil,
        providers: [],
        fillInputFromClipboardOnShortcut: false
    )
}

struct ManagedWorktree: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let repositoryPath: String
    let localWorkspacePath: String
    let worktreePath: String
    let workspacePath: String
    let baseCommit: String
    let createdAt: Double
    var branch: String?
}

struct ProviderStatus: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let configured: Bool
    let supportsAPIKeyLogin: Bool
    let supportsOAuthLogin: Bool
}

struct ModelOption: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let providerId: String
    let providerName: String
    let supportsImages: Bool
    let supportsReasoning: Bool

    var selection: ModelSelection {
        ModelSelection(providerId: providerId, modelId: id)
    }

    var selectionKey: String {
        "\(providerId)/\(id)"
    }
}

struct RuntimeSnapshot: Codable, Equatable {
    let providers: [ProviderStatus]
    let models: [ModelOption]
    let commands: [SlashCommand]
}

struct PiThinkingState: Equatable {
    let level: ThinkingLevel
    let availableLevels: [ThinkingLevel]
}

struct SlashCommand: Codable, Equatable {
    enum Source: String, Codable {
        case app
        case `extension`
        case prompt
        case skill

        var title: String {
            switch self {
            case .app:
                "应用"
            case .extension:
                "插件"
            case .prompt:
                "提示"
            case .skill:
                "Skill"
            }
        }
    }

    let name: String
    let description: String?
    let source: Source
}

struct PiSessionStats: Decodable, Equatable {
    struct Tokens: Decodable, Equatable {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let total: Int
    }

    struct ContextUsage: Decodable, Equatable {
        let tokens: Int?
        let contextWindow: Int
        let percent: Double?
    }

    let sessionFile: String
    let sessionId: String
    let userMessages: Int
    let assistantMessages: Int
    let toolCalls: Int
    let toolResults: Int
    let totalMessages: Int
    let tokens: Tokens
    let cost: Double
    let contextUsage: ContextUsage?
}

struct PiCompactionResult: Decodable, Equatable {
    let summary: String
    let tokensBefore: Int
    let estimatedTokensAfter: Int
}

struct PiCloneResult: Decodable, Equatable {
    let cancelled: Bool
}

struct PiForkMessages: Decodable, Equatable {
    let messages: [PiForkMessage]
}

struct PiForkMessage: Decodable, Equatable {
    let entryId: String
    let text: String
}

struct PiExportResult: Decodable, Equatable {
    let path: String
}

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case null

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

    // Formats an already valid JSON value without changing its structure or field names.
    var formattedJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}

enum CustomMessageQRCode: Equatable {
    case absent
    case invalid
    case url(URL)
}

struct PiCustomMessage: Codable, Equatable {
    let customType: String
    let content: JSONValue
    let display: Bool
    let details: JSONValue?
    let timestamp: Double

    private enum CodingKeys: String, CodingKey {
        case customType
        case content
        case display
        case details
        case timestamp
    }

    // Creates the same custom-message shape used by Pi's public extension contract.
    init(customType: String, content: JSONValue, display: Bool, details: JSONValue?, timestamp: Double) {
        self.customType = customType
        self.content = content
        self.display = display
        self.details = details
        self.timestamp = timestamp
    }

    // Validates the portable details.qrUrl hint without coupling it to one plugin type.
    var qrCode: CustomMessageQRCode {
        guard case .object(let values) = details,
              let qrValue = values["qrUrl"] else {
            return .absent
        }
        guard case .string(let value) = qrValue,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return .invalid
        }
        return .url(url)
    }

    // Preserves an explicit JSON null in details instead of merging it with an omitted field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customType = try container.decode(String.self, forKey: .customType)
        content = try container.decode(JSONValue.self, forKey: .content)
        display = try container.decode(Bool.self, forKey: .display)
        details = container.contains(.details)
            ? try container.decode(JSONValue.self, forKey: .details)
            : nil
        timestamp = try container.decode(Double.self, forKey: .timestamp)
    }

    // Writes details only when Pi supplied it, while retaining an explicit JSON null value.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(customType, forKey: .customType)
        try container.encode(content, forKey: .content)
        try container.encode(display, forKey: .display)
        if let details {
            try container.encode(details, forKey: .details)
        }
        try container.encode(timestamp, forKey: .timestamp)
    }
}

struct ConversationSession: Codable, Equatable, Identifiable {
    let path: String
    let id: String
    let cwd: String
    let name: String?
    let created: Double
    let modified: Double
    let messageCount: Int
    let firstMessage: String

    var title: String {
        let explicitName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicitName.isEmpty {
            return explicitName
        }
        let firstLine = firstMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? ""
        return firstLine.isEmpty ? "新会话" : firstLine
    }

    var modifiedAt: Date {
        Date(timeIntervalSince1970: modified / 1_000)
    }
}

struct SessionSnapshot: Codable, Equatable {
    let cwd: String
    let activeSessionPath: String
    let activeSessionId: String
    let sessions: [ConversationSession]
    let messages: [SavedSessionMessage]
}

struct SavedSessionMessage: Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        case toolResult
        case custom
    }

    let entryId: String
    let role: Role
    let timestamp: Double
    let text: String?
    let attachments: [MessageAttachment]?
    let content: [SavedAssistantContent]?
    let provider: String?
    let model: String?
    let usage: PiUsage?
    let stopReason: String?
    let errorMessage: String?
    let toolCallId: String?
    let toolName: String?
    let isError: Bool?
    let customMessage: PiCustomMessage?
}

struct SavedAssistantContent: Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case thinking
        case toolCall
    }

    let type: Kind
    let text: String?
    let thinking: String?
    let toolCallId: String?
    let toolName: String?
    let arguments: JSONValue?
}

struct ImagePayload: Encodable, Equatable {
    let type = "image"
    let data: String
    let mimeType: String
}

struct MessageAttachment: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case image
        case document
    }

    let id: String
    let name: String
    let kind: Kind
    let data: Data?
    let mimeType: String?

    init(
        id: String,
        name: String,
        kind: Kind,
        data: Data? = nil,
        mimeType: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.data = data
        self.mimeType = mimeType
    }
}

struct QueuedUserMessage: Codable, Equatable, Identifiable {
    enum Delivery: String, Codable {
        case steer
        case followUp
    }

    let id: String
    var text: String
    let delivery: Delivery
    let attachmentNames: [String]
    let editable: Bool
    var attachments: [MessageAttachment]

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case delivery
        case attachmentNames
        case editable
        case attachments
    }

    init(
        id: String,
        text: String,
        delivery: Delivery,
        attachmentNames: [String] = [],
        editable: Bool = true,
        attachments: [MessageAttachment] = []
    ) {
        self.id = id
        self.text = text
        self.delivery = delivery
        self.attachmentNames = attachmentNames
        self.editable = editable
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        delivery = try container.decode(Delivery.self, forKey: .delivery)
        attachmentNames = try container.decodeIfPresent([String].self, forKey: .attachmentNames) ?? []
        editable = try container.decodeIfPresent(Bool.self, forKey: .editable) ?? true
        attachments = try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
    }

    var isSteering: Bool {
        delivery == .steer
    }
}

struct PendingAttachment: Identifiable, Equatable {
    enum Content: Equatable {
        case text(String)
        case image(data: Data, mimeType: String)
    }

    let id: UUID
    let name: String
    let content: Content

    var messageAttachment: MessageAttachment {
        switch content {
        case .text:
            MessageAttachment(
                id: id.uuidString,
                name: name,
                kind: .document
            )
        case let .image(data, mimeType):
            MessageAttachment(
                id: id.uuidString,
                name: name,
                kind: .image,
                data: data,
                mimeType: mimeType
            )
        }
    }
}

struct SubmittedQuestion: Equatable {
    let text: String
    let attachments: [MessageAttachment]
    let workspacePath: String?

    init(text: String, attachments: [MessageAttachment], workspacePath: String?) {
        self.text = text
        self.attachments = attachments
        self.workspacePath = workspacePath
    }

    init(text: String, attachmentNames: [String], workspacePath: String?) {
        self.init(
            text: text,
            attachments: attachmentNames.enumerated().map { index, name in
                MessageAttachment(
                    id: "legacy-\(index)-\(name)",
                    name: name,
                    kind: .document
                )
            },
            workspacePath: workspacePath
        )
    }

    var attachmentNames: [String] {
        attachments.map(\.name)
    }
}

enum AnswerStatus: Equatable {
    case waiting
    case running
    case completed
    case stopped
    case failed
}

enum ToolStatus: Equatable {
    case running
    case completed
    case failed
}

struct ToolActivity: Equatable {
    let callId: String
    let name: String
    let input: String
    var output: String
    var status: ToolStatus
}

enum AnswerSectionContent: Equatable {
    case markdown(String)
    case extensionMessage(String)
    case fileLink(URL)
    case customMessage(PiCustomMessage)
    case extensionNotification(ExtensionNotification)
    case thinking(String)
    case tool(ToolActivity)
}

struct AnswerSection: Identifiable, Equatable {
    let id: UUID
    var content: AnswerSectionContent
}

struct AnswerUsage: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cost = 0.0

    var totalTokens: Int {
        input + output + cacheRead + cacheWrite
    }

    // Adds usage from every assistant turn, including turns that invoke tools.
    mutating func add(_ value: PiUsage) {
        input += value.input
        output += value.output
        cacheRead += value.cacheRead
        cacheWrite += value.cacheWrite
        cost += value.cost
    }
}

struct AnswerSession: Identifiable, Equatable {
    let id: UUID = UUID()
    let question: SubmittedQuestion?
    let startedAt: Date
    var sections: [AnswerSection]
    var status: AnswerStatus
    var cloneEntryId: String? = nil
    var provider: String? = nil
    var model: String? = nil
    var usage = AnswerUsage()
    var retryMessage: String? = nil
    var stopReason: String? = nil
    var error: String? = nil

    var answerText: String {
        sections.compactMap { section in
            switch section.content {
            case .markdown(let text), .extensionMessage(let text):
                return text
            case .fileLink(let url):
                return url.path
            case .customMessage(let message):
                var text = "[\(message.customType)]\n"
                switch message.content {
                case .string(let content):
                    text += content
                default:
                    text += message.content.formattedJSON
                }
                if let details = message.details {
                    text += "\n\ndetails:\n\(details.formattedJSON)"
                }
                return text
            case .extensionNotification(let notification):
                return notification.message
            case .thinking, .tool:
                return nil
            }
        }.joined(separator: "\n\n")
    }
}

struct PiUsage: Codable, Equatable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let cost: Double
}

struct AuthPrompt: Equatable {
    struct Option: Equatable {
        let id: String
        let label: String
        let description: String?
    }

    let requestId: String
    let type: String
    let message: String
    let placeholder: String?
    let options: [Option]
}

enum AuthEvent: Equatable {
    case info(message: String, links: [(url: String, label: String?)])
    case authURL(url: String, instructions: String?)
    case deviceCode(userCode: String, verificationURI: String)
    case progress(String)

    // Compares tuple-backed authentication events field by field.
    static func == (lhs: AuthEvent, rhs: AuthEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.info(leftMessage, leftLinks), .info(rightMessage, rightLinks)):
            return leftMessage == rightMessage
                && leftLinks.map { [$0.url, $0.label ?? ""] } == rightLinks.map { [$0.url, $0.label ?? ""] }
        case let (.authURL(leftURL, leftInstructions), .authURL(rightURL, rightInstructions)):
            return leftURL == rightURL && leftInstructions == rightInstructions
        case let (.deviceCode(leftCode, leftURI), .deviceCode(rightCode, rightURI)):
            return leftCode == rightCode && leftURI == rightURI
        case let (.progress(left), .progress(right)):
            return left == right
        default:
            return false
        }
    }
}

struct AuthSession: Equatable {
    let providerId: String
    let providerName: String
    var event: AuthEvent?
    var prompt: AuthPrompt?
    var error: String?
}

enum ExtensionNotificationKind: String, Equatable {
    case info
    case warning
    case error
}

struct ExtensionNotification: Equatable {
    let message: String
    let kind: ExtensionNotificationKind
}

struct ExtensionStatus: Identifiable, Equatable {
    // Matches the status key emitted by Pi's bundled plan-mode extension.
    static let planModeKey = "plan-mode"

    let key: String
    var text: String
    var richText: ExtensionRichText? = nil

    var id: String { key }
}

struct ExtensionRichText: Equatable {
    enum Color: Equatable {
        case indexed(Int)
        case rgb(red: Int, green: Int, blue: Int)
    }

    struct Style: Equatable {
        var foreground: Color?
        var bold = false
        var dimmed = false
        var italic = false
        var underlined = false
        var strikethrough = false
    }

    struct Run: Equatable {
        let text: String
        let style: Style
    }

    let runs: [Run]

    var plainText: String {
        runs.map(\.text).joined()
    }

    var hasFormatting: Bool {
        runs.contains { $0.style != Style() }
    }

    // Converts terminal SGR runs emitted by Pi extensions into platform-neutral styles.
    init(ansi source: String) {
        guard let expression = try? NSRegularExpression(pattern: "\u{001B}\\[([0-9;]*)m") else {
            runs = source.isEmpty ? [] : [Run(text: source, style: Style())]
            return
        }
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        var parsedRuns: [Run] = []
        var style = Style()
        var cursor = source.startIndex

        func append(_ text: Substring) {
            guard !text.isEmpty else {
                return
            }
            let value = String(text)
            if let last = parsedRuns.last, last.style == style {
                parsedRuns[parsedRuns.count - 1] = Run(text: last.text + value, style: style)
            } else {
                parsedRuns.append(Run(text: value, style: style))
            }
        }

        for match in expression.matches(in: source, range: sourceRange) {
            guard let matchRange = Range(match.range, in: source) else {
                continue
            }
            append(source[cursor..<matchRange.lowerBound])

            let parameterText = Range(match.range(at: 1), in: source).map { String(source[$0]) } ?? ""
            let parameters = parameterText.isEmpty
                ? [0]
                : parameterText.split(separator: ";", omittingEmptySubsequences: false).map {
                    Int($0) ?? 0
                }
            var index = 0
            while index < parameters.count {
                let parameter = parameters[index]
                switch parameter {
                case 0:
                    style = Style()
                case 1:
                    style.bold = true
                case 2:
                    style.dimmed = true
                case 3:
                    style.italic = true
                case 4:
                    style.underlined = true
                case 9:
                    style.strikethrough = true
                case 22:
                    style.bold = false
                    style.dimmed = false
                case 23:
                    style.italic = false
                case 24:
                    style.underlined = false
                case 29:
                    style.strikethrough = false
                case 30...37:
                    style.foreground = .indexed(parameter - 30)
                case 38:
                    if index + 2 < parameters.count, parameters[index + 1] == 5 {
                        style.foreground = .indexed(parameters[index + 2])
                        index += 2
                    } else if index + 4 < parameters.count, parameters[index + 1] == 2 {
                        style.foreground = .rgb(
                            red: parameters[index + 2],
                            green: parameters[index + 3],
                            blue: parameters[index + 4]
                        )
                        index += 4
                    }
                case 39:
                    style.foreground = nil
                case 90...97:
                    style.foreground = .indexed(parameter - 90 + 8)
                default:
                    break
                }
                index += 1
            }
            cursor = matchRange.upperBound
        }
        append(source[cursor...])
        runs = parsedRuns
    }
}

struct ExtensionWidget: Identifiable, Equatable {
    // Matches the checklist key emitted by Pi's bundled plan-mode extension.
    static let planModeKey = "plan-todos"

    enum Placement: String, Equatable {
        case aboveEditor
        case belowEditor
    }

    let key: String
    var lines: [String]
    var placement: Placement
    var richLines: [ExtensionRichText]? = nil

    var id: String { key }
}

struct ExtensionPrompt: Equatable {
    let requestId: String
    let method: String
    let title: String
    let message: String?
    let placeholder: String?
    let options: [String]
    let prefill: String?
}

struct QuestionnaireDefinition: Codable, Equatable {
    struct Question: Codable, Equatable, Identifiable {
        struct Option: Codable, Equatable {
            let value: String
            let label: String
            let description: String?
            let recommended: Bool?
        }

        let id: String
        let label: String
        let prompt: String
        let options: [Option]
        let allowOther: Bool
    }

    let questions: [Question]
}

struct QuestionnairePrompt: Equatable, Identifiable {
    let requestId: String
    let definition: QuestionnaireDefinition

    var id: String { requestId }
}

struct QuestionnaireAnswer: Codable, Equatable {
    let id: String
    let value: String
    let label: String
    let wasCustom: Bool
    let index: Int?
}

struct QuestionnaireResponse: Encodable {
    let cancelled: Bool
    let answers: [QuestionnaireAnswer]
}

struct ModelCatalogResponse: Decodable {
    struct RemoteModel: Decodable {
        let id: String
    }

    let data: [RemoteModel]
}

enum QuickPiError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            message
        }
    }
}
