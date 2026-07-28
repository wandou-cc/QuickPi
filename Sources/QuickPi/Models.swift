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
            "openai-completions"
        case .claudeCode:
            "anthropic-messages"
        }
    }
}

struct ModelSelection: Codable, Equatable {
    let providerId: String
    let modelId: String
}

struct ProviderConfiguration: Codable, Equatable, Identifiable {
    let id: String
    var kind: ProviderKind
    var name: String
    var baseURL: String
    var models: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case kind = "type"
        case name
        case baseURL = "baseUrl"
        case models
    }
}

struct AppSettings: Codable, Equatable {
    var shortcut: String
    var launchAtLogin: Bool
    var terminalAccess: Bool
    var fileSystemAccess: Bool
    var selectedModel: ModelSelection?
    var providers: [ProviderConfiguration]

    static let defaults = AppSettings(
        shortcut: "commandShiftSpace",
        launchAtLogin: false,
        terminalAccess: false,
        fileSystemAccess: false,
        selectedModel: nil,
        providers: []
    )
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
}

struct ImagePayload: Encodable, Equatable {
    let type = "image"
    let data: String
    let mimeType: String
}

struct PendingAttachment: Identifiable, Equatable {
    enum Content: Equatable {
        case text(String)
        case image(data: Data, mimeType: String)
    }

    let id: UUID
    let name: String
    let content: Content
}

struct SubmittedQuestion: Equatable {
    let text: String
    let attachmentNames: [String]
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

struct AnswerSession: Equatable {
    let question: SubmittedQuestion
    let startedAt: Date
    var sections: [AnswerSection]
    var status: AnswerStatus
    var provider: String? = nil
    var model: String? = nil
    var usage = AnswerUsage()
    var retryMessage: String? = nil
    var stopReason: String? = nil
    var error: String? = nil

    var answerText: String {
        sections.compactMap { section in
            if case .markdown(let text) = section.content {
                return text
            }
            return nil
        }.joined(separator: "\n\n")
    }
}

struct PiUsage: Equatable {
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
