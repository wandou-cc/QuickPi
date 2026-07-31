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

    // Persists the exact worktree paths used to recover project scope across app launches.
    func testManagedWorktreePersistenceRejectsDuplicateWorkspacePaths() throws {
        let directory = try temporaryDirectory()
        let store = ConfigurationStore(applicationSupportDirectory: directory)
        let worktree = ManagedWorktree(
            id: "worktree-1",
            repositoryPath: "/tmp/repository",
            localWorkspacePath: "/tmp/repository/project",
            worktreePath: "/tmp/Quick Pi/worktrees/worktree-1",
            workspacePath: "/tmp/Quick Pi/worktrees/worktree-1/project",
            baseCommit: "0123456789abcdef",
            createdAt: 1_000,
            branch: "feature/session"
        )

        try store.saveManagedWorktrees([worktree])

        XCTAssertEqual(try store.loadManagedWorktrees(), [worktree])
        let url = directory.appendingPathComponent("worktrees.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
        )
        XCTAssertNil(object[0]["sessionIDs"])

        let duplicate = ManagedWorktree(
            id: "worktree-2",
            repositoryPath: worktree.repositoryPath,
            localWorkspacePath: worktree.localWorkspacePath,
            worktreePath: "/tmp/Quick Pi/worktrees/worktree-2",
            workspacePath: worktree.workspacePath,
            baseCommit: worktree.baseCommit,
            createdAt: 2_000,
            branch: nil
        )
        XCTAssertThrowsError(try store.saveManagedWorktrees([worktree, duplicate]))
    }

    // Creates a detached checkout with the source checkout's tracked and non-ignored untracked changes.
    func testManagedWorktreeCreationTransfersLocalChangesAndRefusesDirtyRemoval() async throws {
        let directory = try temporaryDirectory()
        let repository = try makeRepository(in: directory)
        try Data("source modification\n".utf8).write(
            to: repository.appendingPathComponent("tracked.txt")
        )
        let notes = repository.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("untracked\n".utf8).write(to: notes.appendingPathComponent("new.txt"))
        let ignored = repository.appendingPathComponent("ignored", isDirectory: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try Data("local cache\n".utf8).write(to: ignored.appendingPathComponent("cache.txt"))
        let manager = GitWorktreeManager(
            applicationSupportDirectory: directory.appendingPathComponent("support", isDirectory: true)
        )

        let repositoryIsGit = try await manager.isGitRepository(at: repository)
        let directoryIsGit = try await manager.isGitRepository(at: directory)
        XCTAssertTrue(repositoryIsGit)
        XCTAssertFalse(directoryIsGit)
        let worktree = try await manager.create(sessionID: "session-dirty", workspaceURL: repository)

        let initialBranch = try await manager.currentBranch(in: worktree)
        XCTAssertNil(initialBranch)
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: worktree.worktreePath).appendingPathComponent("tracked.txt")),
            "source modification\n"
        )
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: worktree.worktreePath).appendingPathComponent("notes/new.txt")),
            "untracked\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: worktree.worktreePath).appendingPathComponent("ignored/cache.txt").path
        ))
        do {
            try await manager.validateRemoval(of: worktree)
            XCTFail("Dirty worktree validation should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未提交改动"))
        }
        do {
            try await manager.remove(worktree)
            XCTFail("Git should refuse to remove a dirty worktree")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.worktreePath))
    }

    // Keeps a user-created branch after its clean managed checkout is removed.
    func testManagedWorktreeCreatesBranchAndCleansCheckout() async throws {
        let directory = try temporaryDirectory()
        let repository = try makeRepository(in: directory)
        let manager = GitWorktreeManager(
            applicationSupportDirectory: directory.appendingPathComponent("support", isDirectory: true)
        )
        let worktree = try await manager.create(sessionID: "session-branch", workspaceURL: repository)

        _ = try await manager.createBranch(
            named: "feature/quick-pi",
            at: URL(fileURLWithPath: worktree.workspacePath, isDirectory: true)
        )
        let branch = try await manager.currentBranch(in: worktree)
        XCTAssertEqual(branch, "feature/quick-pi")
        try await manager.validateRemoval(of: worktree)
        let protectedBranch = try await manager.preserveDetachedHead(of: worktree)
        XCTAssertNil(protectedBranch)
        try await manager.remove(worktree)

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.worktreePath))
        XCTAssertEqual(
            try runGit(["-C", repository.path, "branch", "--show-current"]),
            "main\n"
        )
        _ = try runGit([
            "-C", repository.path,
            "show-ref", "--verify", "--quiet", "refs/heads/feature/quick-pi",
        ])
    }

    // Protects a clean detached commit with a stable branch before removing its worktree reference.
    func testManagedWorktreePreservesDetachedCommitBeforeCleanup() async throws {
        let directory = try temporaryDirectory()
        let repository = try makeRepository(in: directory)
        let manager = GitWorktreeManager(
            applicationSupportDirectory: directory.appendingPathComponent("support", isDirectory: true)
        )
        let worktree = try await manager.create(sessionID: "SESSION-COMMIT", workspaceURL: repository)
        let worktreeURL = URL(fileURLWithPath: worktree.worktreePath, isDirectory: true)
        try Data("detached commit\n".utf8).write(to: worktreeURL.appendingPathComponent("detached.txt"))
        _ = try runGit(["-C", worktree.worktreePath, "add", "detached.txt"])
        _ = try runGit(["-C", worktree.worktreePath, "commit", "-m", "Detached work"])
        let detachedHead = try runGit(["-C", worktree.worktreePath, "rev-parse", "HEAD"])

        try await manager.validateRemoval(of: worktree)
        let preservedBranch = try await manager.preserveDetachedHead(of: worktree)
        let branch = try XCTUnwrap(preservedBranch)
        XCTAssertEqual(branch, "quick-pi/session-commit")
        XCTAssertEqual(
            try runGit(["-C", repository.path, "rev-parse", branch]),
            detachedHead
        )
        try await manager.remove(worktree)

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.worktreePath))
        XCTAssertEqual(
            try runGit(["-C", repository.path, "rev-parse", branch]),
            detachedHead
        )
    }

    // Verifies the status, Diff, commit, branch-switching, and Log contracts used by the Git menu.
    func testGitMenuLocalRepositoryWorkflow() async throws {
        let directory = try temporaryDirectory()
        let repository = try makeRepository(in: directory)
        let manager = GitWorktreeManager(
            applicationSupportDirectory: directory.appendingPathComponent("support", isDirectory: true)
        )
        let commitMessageHook = repository.appendingPathComponent(".git/hooks/commit-msg")
        try Data("#!/bin/sh\n# commitlint --edit \"$1\"\nexit 0\n".utf8).write(to: commitMessageHook)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: commitMessageHook.path
        )

        let initialBranches = try await manager.localBranches(at: repository)
        XCTAssertEqual(initialBranches, [GitLocalBranch(name: "main", isCurrent: true)])

        try Data("updated\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try Data("notes\n".utf8).write(to: repository.appendingPathComponent("notes.txt"))
        _ = try runGit(["-C", repository.path, "add", "tracked.txt"])

        let dirtyStatus = try await manager.repositoryStatus(at: repository)
        XCTAssertEqual(dirtyStatus.branch, "main")
        XCTAssertEqual(dirtyStatus.additions, 1)
        XCTAssertEqual(dirtyStatus.deletions, 1)
        XCTAssertEqual(dirtyStatus.changedFileCount, 2)
        XCTAssertTrue(dirtyStatus.hasStagedChanges)
        XCTAssertTrue(dirtyStatus.hasUnstagedChanges)
        XCTAssertFalse(dirtyStatus.canPush)

        let diff = try await manager.diff(at: repository)
        XCTAssertTrue(diff.text.contains("-original"))
        XCTAssertTrue(diff.text.contains("+updated"))
        XCTAssertFalse(diff.isTruncated)
        XCTAssertEqual(diff.untrackedFiles, ["notes.txt"])
        XCTAssertEqual(diff.untrackedFileCount, 1)

        let stagedContext = try await manager.commitMessageContext(
            includingUnstaged: false,
            at: repository
        )
        XCTAssertTrue(stagedContext.contains("Initial commit"))
        XCTAssertTrue(stagedContext.contains("Git hook: commit-msg"))
        XCTAssertTrue(stagedContext.contains("commitlint --edit"))
        XCTAssertTrue(stagedContext.contains("+updated"))
        XCTAssertFalse(stagedContext.contains("notes.txt"))

        let completeContext = try await manager.commitMessageContext(
            includingUnstaged: true,
            at: repository
        )
        XCTAssertTrue(completeContext.contains("notes.txt"))

        do {
            _ = try await manager.commit(message: "", includingUnstaged: false, at: repository)
            XCTFail("The Git layer must reject an empty final commit message")
        } catch {
            XCTAssertEqual(error.localizedDescription, "请输入提交信息")
        }

        let stagedCommit = try await manager.commit(
            message: "Update tracked file",
            includingUnstaged: false,
            at: repository
        )
        XCTAssertEqual(stagedCommit.count, 12)
        let afterStagedCommit = try await manager.repositoryStatus(at: repository)
        XCTAssertFalse(afterStagedCommit.hasStagedChanges)
        XCTAssertTrue(afterStagedCommit.hasUnstagedChanges)
        do {
            _ = try await manager.commitMessageContext(includingUnstaged: false, at: repository)
            XCTFail("Commit message generation must reject an empty staged scope")
        } catch {
            XCTAssertEqual(error.localizedDescription, "没有可提交的暂存更改")
        }

        let completeCommit = try await manager.commit(
            message: "Add notes",
            includingUnstaged: true,
            at: repository
        )
        XCTAssertEqual(completeCommit.count, 12)
        let cleanStatus = try await manager.repositoryStatus(at: repository)
        XCTAssertFalse(cleanStatus.hasChanges)

        let log = try await manager.recentCommits(at: repository)
        XCTAssertEqual(log.map(\.subject), ["Add notes", "Update tracked file", "Initial commit"])
        XCTAssertTrue(log.allSatisfy { !$0.commitID.isEmpty && !$0.shortCommitID.isEmpty })

        let branch = try await manager.createBranch(named: "feature/git-menu", at: repository)
        XCTAssertEqual(branch, "feature/git-menu")
        XCTAssertEqual(try runGit(["-C", repository.path, "branch", "--show-current"]), "feature/git-menu\n")
        let branches = try await manager.localBranches(at: repository)
        XCTAssertEqual(
            Set(branches.map(\.name)),
            Set(["main", "feature/git-menu"])
        )

        try await manager.switchBranch(named: "main", at: repository)
        XCTAssertEqual(try runGit(["-C", repository.path, "branch", "--show-current"]), "main\n")
    }

    // Establishes origin as the upstream only when the current branch has no existing upstream.
    func testGitMenuPushEstablishesOriginUpstream() async throws {
        let directory = try temporaryDirectory()
        let repository = try makeRepository(in: directory)
        let remote = directory.appendingPathComponent("remote.git", isDirectory: true)
        let manager = GitWorktreeManager(
            applicationSupportDirectory: directory.appendingPathComponent("support", isDirectory: true)
        )
        _ = try runGit(["init", "--bare", "-b", "main", remote.path])
        _ = try runGit(["-C", repository.path, "remote", "add", "origin", remote.path])

        _ = try runGit(["-C", repository.path, "config", "branch.main.remote", "missing"])
        _ = try runGit(["-C", repository.path, "config", "branch.main.merge", "refs/heads/main"])
        let invalidUpstreamStatus = try await manager.repositoryStatus(at: repository)
        XCTAssertFalse(invalidUpstreamStatus.canPush)
        do {
            try await manager.push(at: repository)
            XCTFail("An invalid configured upstream must not fall back to origin")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        _ = try runGit(["-C", repository.path, "config", "--unset", "branch.main.remote"])
        _ = try runGit(["-C", repository.path, "config", "--unset", "branch.main.merge"])

        let initialStatus = try await manager.repositoryStatus(at: repository)
        XCTAssertTrue(initialStatus.canPush)
        try await manager.push(at: repository)

        let pushedStatus = try await manager.repositoryStatus(at: repository)
        XCTAssertEqual(pushedStatus.upstream, "origin/main")
        XCTAssertEqual(
            try runGit(["-C", remote.path, "rev-parse", "refs/heads/main"]),
            try runGit(["-C", repository.path, "rev-parse", "HEAD"])
        )
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
                    models: ["model-a", "model-b"],
                    modelThinkingLevels: [
                        "model-b": [.off, .low, .high, .max],
                    ]
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
        XCTAssertEqual(models[0]["reasoning"] as? Bool, false)
        XCTAssertNil(models[0]["thinkingLevelMap"])
        XCTAssertEqual(models[1]["reasoning"] as? Bool, true)
        let thinkingLevelMap = try XCTUnwrap(models[1]["thinkingLevelMap"] as? [String: Any])
        XCTAssertNil(thinkingLevelMap["off"])
        XCTAssertTrue(thinkingLevelMap["minimal"] is NSNull)
        XCTAssertNil(thinkingLevelMap["low"])
        XCTAssertTrue(thinkingLevelMap["medium"] is NSNull)
        XCTAssertNil(thinkingLevelMap["high"])
        XCTAssertTrue(thinkingLevelMap["xhigh"] is NSNull)
        XCTAssertEqual(thinkingLevelMap["max"] as? String, "max")
    }

    // Rejects reasoning declarations that do not describe one real model and usable levels.
    func testModelsGenerationRejectsInvalidThinkingLevelDeclarations() throws {
        let directory = try temporaryDirectory()
        let store = ConfigurationStore(applicationSupportDirectory: directory)
        let invalidConfigurations: [[String: [ThinkingLevel]]] = [
            ["unknown-model": [.off, .high]],
            ["model-a": [.high, .high]],
            ["model-a": [.off]],
        ]

        for modelThinkingLevels in invalidConfigurations {
            let settings = AppSettings(
                shortcut: "commandShiftSpace",
                launchAtLogin: false,
                workspacePath: nil,
                selectedModel: nil,
                providers: [
                    ProviderConfiguration(
                        id: "provider-1",
                        kind: .openAI,
                        name: "Gateway",
                        baseURL: "https://gateway.example/v1",
                        models: ["model-a"],
                        modelThinkingLevels: modelThinkingLevels
                    ),
                ]
            )

            XCTAssertThrowsError(try store.writeModels(for: settings)) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "Provider 的模型推理能力配置无效：Gateway"
                )
            }
        }
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

    // Keeps existing Provider settings readable while leaving undeclared reasoning disabled.
    func testProviderWithoutThinkingLevelsLoadsAsUndeclared() throws {
        let directory = try temporaryDirectory()
        let data = Data(
            """
            {
              "shortcut": "commandShiftSpace",
              "launchAtLogin": false,
              "workspacePath": null,
              "selectedModel": {"providerId": "provider-1", "modelId": "model-a"},
              "providers": [{
                "id": "provider-1",
                "type": "openai",
                "name": "Gateway",
                "baseUrl": "https://gateway.example/v1",
                "models": ["model-a"]
              }]
            }
            """.utf8
        )
        try data.write(to: directory.appendingPathComponent("settings.json"))

        let provider = try XCTUnwrap(ConfigurationStore(
            applicationSupportDirectory: directory
        ).load().providers.first)

        XCTAssertNil(provider.modelThinkingLevels)
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

    // Creates one committed Git repository used as the source checkout in worktree tests.
    private func makeRepository(in directory: URL) throws -> URL {
        let repository = directory.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try runGit(["-C", repository.path, "init", "-b", "main"])
        _ = try runGit(["-C", repository.path, "config", "user.name", "Quick Pi Tests"])
        _ = try runGit(["-C", repository.path, "config", "user.email", "quick-pi-tests@example.invalid"])
        try Data("original\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try Data("ignored/\n".utf8).write(to: repository.appendingPathComponent(".gitignore"))
        _ = try runGit(["-C", repository.path, "add", "tracked.txt", ".gitignore"])
        _ = try runGit(["-C", repository.path, "commit", "-m", "Initial commit"])
        return repository
    }

    // Runs a small deterministic Git command without allowing shell interpolation.
    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let outputText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorText = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw QuickPiError.message(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return outputText
    }
}
