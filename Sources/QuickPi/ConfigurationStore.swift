import Foundation

final class ConfigurationStore {
    private struct ModelsDocument: Encodable {
        let providers: [String: PiProvider]
    }

    private struct PiProvider: Encodable {
        let name: String
        let baseUrl: String
        let api: String
        let headers: [String: String]?
        let models: [PiModel]
    }

    private struct PiModel: Encodable {
        struct Cost: Encodable {
            let input = 0
            let output = 0
            let cacheRead = 0
            let cacheWrite = 0
        }

        let id: String
        let name: String
        let reasoning = false
        let input = ["text", "image"]
        let contextWindow = 128_000
        let maxTokens = 16_384
        let cost = Cost()
    }

    private let settingsURL: URL
    private let piDirectory: URL

    // Defines the app-owned settings, custom Provider catalog, and custom credentials.
    init(applicationSupportDirectory: URL) {
        settingsURL = applicationSupportDirectory.appendingPathComponent("settings.json")
        piDirectory = applicationSupportDirectory.appendingPathComponent("pi", isDirectory: true)
    }

    // Reads the exact current settings schema; only a genuinely missing file means first launch.
    func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return .defaults
        }
        return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
    }

    // Atomically replaces settings.json and then verifies it by decoding the stored bytes.
    func save(_ settings: AppSettings) throws -> AppSettings {
        try createDirectories()
        let data = try Self.encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        return try load()
    }

    // Generates Pi's models.json solely from the settings document used by the UI.
    func writeModels(for settings: AppSettings) throws {
        try createDirectories()
        var providers: [String: PiProvider] = [:]
        for provider in settings.providers {
            guard providers[provider.id] == nil else {
                throw QuickPiError.message("Provider ID 重复：\(provider.id)")
            }
            providers[provider.id] = PiProvider(
                name: provider.name,
                baseUrl: provider.baseURL,
                api: provider.kind.piAPI,
                headers: provider.kind == .openAI
                    ? ["User-Agent": "codex_cli_rs/0.145.0"]
                    : nil,
                models: provider.models.map { PiModel(id: $0, name: $0) }
            )
        }
        let data = try Self.encoder.encode(ModelsDocument(providers: providers))
        let url = piDirectory.appendingPathComponent("models.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // Reads the exact API-key credential owned by one persisted custom Provider.
    func loadAPIKey(providerId: String) throws -> String {
        let url = piDirectory.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuickPiError.message("该 Provider 没有已保存的 API Key")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let credentials = object as? [String: Any],
              let credential = credentials[providerId] as? [String: String],
              credential["type"] == "api_key",
              let key = credential["key"],
              !key.isEmpty else {
            throw QuickPiError.message("该 Provider 的 API Key 凭证无效")
        }
        return key
    }

    // Writes one custom Provider key while preserving the other app-owned custom credentials.
    func saveAPIKey(_ key: String, providerId: String) throws {
        try createDirectories()
        let url = piDirectory.appendingPathComponent("auth.json")
        var credentials: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let storedCredentials = object as? [String: Any] else {
                throw QuickPiError.message("Pi 凭证文件格式无效")
            }
            credentials = storedCredentials
        } else {
            credentials = [:]
        }
        credentials[providerId] = ["type": "api_key", "key": key]
        let data = try JSONSerialization.data(
            withJSONObject: credentials,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // Removes only the credential owned by a deleted custom Provider.
    func deleteCredential(providerId: String) throws {
        let url = piDirectory.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard var credentials = object as? [String: Any] else {
            throw QuickPiError.message("Pi 凭证文件格式无效")
        }
        credentials.removeValue(forKey: providerId)
        let data = try JSONSerialization.data(
            withJSONObject: credentials,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // Creates private parent directories before any settings or credential write.
    private func createDirectories() throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: piDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: piDirectory.path
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
