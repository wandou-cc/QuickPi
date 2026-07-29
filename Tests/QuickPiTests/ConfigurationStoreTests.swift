import Foundation
import XCTest
@testable import QuickPi

final class ConfigurationStoreTests: XCTestCase {
    // Verifies that a missing settings file represents only a clean first launch.
    func testMissingSettingsLoadsDefaults() throws {
        let directory = try temporaryDirectory()
        let store = ConfigurationStore(applicationSupportDirectory: directory)

        XCTAssertEqual(try store.load(), .defaults)
    }

    // Verifies that settings.json is the source used to generate Pi's models.json.
    func testSettingsRoundTripAndModelsGeneration() throws {
        let directory = try temporaryDirectory()
        let store = ConfigurationStore(applicationSupportDirectory: directory)
        let settings = AppSettings(
            shortcut: "controlSpace",
            launchAtLogin: true,
            workspacePath: directory.appendingPathComponent("project", isDirectory: true).path,
            selectedModel: ModelSelection(providerId: "provider-1", modelId: "model-b"),
            providers: [
                ProviderConfiguration(
                    id: "provider-1",
                    kind: .openAI,
                    name: "Gateway",
                    baseURL: "https://gateway.example/v1",
                    models: ["model-a", "model-b"]
                ),
            ]
        )

        XCTAssertEqual(try store.save(settings), settings)
        XCTAssertEqual(try store.load().workspacePath, settings.workspacePath)
        let storedSettings = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("settings.json"))
            ) as? [String: Any]
        )
        XCTAssertNil(storedSettings["terminalAccess"])
        XCTAssertNil(storedSettings["fileSystemAccess"])
        try store.writeModels(for: try store.load())

        let modelsURL = directory.appendingPathComponent("pi/models.json")
        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: modelsURL)) as? [String: Any]
        )
        let providers = try XCTUnwrap(document["providers"] as? [String: Any])
        let provider = try XCTUnwrap(providers["provider-1"] as? [String: Any])
        XCTAssertEqual(provider["name"] as? String, "Gateway")
        XCTAssertEqual(provider["baseUrl"] as? String, "https://gateway.example/v1")
        XCTAssertEqual(provider["api"] as? String, "openai-responses")
        XCTAssertEqual(
            (provider["headers"] as? [String: String])?["User-Agent"],
            "codex_cli_rs/0.145.0"
        )
        let models = try XCTUnwrap(provider["models"] as? [[String: Any]])
        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["model-a", "model-b"])
    }

    // Verifies that the current settings schema persists an explicit no-workspace selection.
    func testSettingsWithNoWorkspaceLoadsWithNoWorkspace() throws {
        let directory = try temporaryDirectory()
        let data = Data(
            """
            {
              "shortcut": "commandShiftSpace",
              "launchAtLogin": false,
              "workspacePath": null,
              "selectedModel": null,
              "providers": []
            }
            """.utf8
        )
        try data.write(to: directory.appendingPathComponent("settings.json"))

        let store = ConfigurationStore(applicationSupportDirectory: directory)

        XCTAssertNil(try store.load().workspacePath)
    }

    // Verifies that an explicit no-workspace selection is presented as the main space.
    @MainActor
    func testScopeTitleUsesMainSpaceWithoutWorkspace() throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )

        XCTAssertEqual(state.scopeTitle, "主空间")
    }

    // Verifies that a selected project is presented by its directory name.
    @MainActor
    func testScopeTitleUsesSelectedDirectoryName() throws {
        let directory = try temporaryDirectory()
        let workspace = directory.appendingPathComponent("client-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = ConfigurationStore(applicationSupportDirectory: directory)
        var settings = AppSettings.defaults
        settings.workspacePath = workspace.path
        _ = try store.save(settings)
        let state = try AppState(
            applicationSupportDirectory: directory,
            checkForUpdates: {},
            presentSettings: {}
        )

        XCTAssertEqual(state.scopeTitle, "client-project")
    }

    // Verifies that a missing project directory never becomes the active persisted workspace.
    @MainActor
    func testInvalidWorkspaceSelectionIsRejected() throws {
        let directory = try temporaryDirectory()
        let state = try AppState(
            applicationSupportDirectory: directory,
            checkForUpdates: {},
            presentSettings: {}
        )

        state.setWorkspace(directory.appendingPathComponent("missing", isDirectory: true))

        XCTAssertNil(state.settings.workspacePath)
        XCTAssertEqual(state.runtimeError, "所选工作区不是有效目录")
    }

    // Verifies that saving one custom API key preserves another custom Provider credential.
    func testAPIKeyWritePreservesOtherCustomCredential() throws {
        let directory = try temporaryDirectory()
        let piDirectory = directory.appendingPathComponent("pi", isDirectory: true)
        try FileManager.default.createDirectory(at: piDirectory, withIntermediateDirectories: true)
        let authURL = piDirectory.appendingPathComponent("auth.json")
        let original: [String: Any] = [
            "provider-2": ["type": "api_key", "key": "other-key"],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: authURL)

        let store = ConfigurationStore(applicationSupportDirectory: directory)
        try store.saveAPIKey("test-key", providerId: "provider-1")
        XCTAssertEqual(try store.loadAPIKey(providerId: "provider-1"), "test-key")

        let credentials = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any]
        )
        let other = try XCTUnwrap(credentials["provider-2"] as? [String: String])
        let custom = try XCTUnwrap(credentials["provider-1"] as? [String: String])
        XCTAssertEqual(other, ["type": "api_key", "key": "other-key"])
        XCTAssertEqual(custom, ["type": "api_key", "key": "test-key"])
        let attributes = try FileManager.default.attributesOfItem(atPath: authURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    // Verifies that the removed customProviders schema is rejected instead of migrated.
    func testLegacySettingsSchemaIsRejected() throws {
        let directory = try temporaryDirectory()
        let legacy = Data(
            """
            {
              "shortcut": "commandShiftSpace",
              "launchAtLogin": false,
              "workspacePath": null,
              "selectedModel": null,
              "customProviders": []
            }
            """.utf8
        )
        try legacy.write(to: directory.appendingPathComponent("settings.json"))
        let store = ConfigurationStore(applicationSupportDirectory: directory)

        XCTAssertThrowsError(try store.load())
    }

    // Creates an isolated directory and registers strict cleanup with XCTest.
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickPiTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }
}
