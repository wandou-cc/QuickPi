import Foundation
import XCTest
@testable import QuickPi

final class SessionStateTests: XCTestCase {
    @MainActor
    func testSessionSnapshotRestoresConversationAndToolActivity() throws {
        let directory = try temporaryDirectory()
        let state = try AppState(
            applicationSupportDirectory: directory,
            checkForUpdates: {},
            presentSettings: {}
        )
        let cwd = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let session = conversationSession(id: "session-1", cwd: cwd, firstMessage: "检查项目")
        let snapshot = SessionSnapshot(
            cwd: cwd,
            activeSessionPath: session.path,
            activeSessionId: session.id,
            sessions: [session],
            messages: [
                message(role: .user, timestamp: 1_000, text: "检查项目"),
                message(
                    role: .assistant,
                    timestamp: 2_000,
                    content: [
                        content(type: .text, text: "开始检查。"),
                        content(
                            type: .toolCall,
                            toolCallId: "call-1",
                            toolName: "read",
                            arguments: .object(["path": .string("README.md")])
                        ),
                    ],
                    provider: "provider",
                    model: "model",
                    usage: PiUsage(input: 10, output: 5, cacheRead: 2, cacheWrite: 0, cost: 0.01),
                    stopReason: "toolUse"
                ),
                message(
                    role: .toolResult,
                    timestamp: 3_000,
                    text: "file contents",
                    toolCallId: "call-1",
                    toolName: "read",
                    isError: false
                ),
                message(
                    role: .assistant,
                    timestamp: 4_000,
                    content: [content(type: .text, text: "检查完成。")],
                    provider: "provider",
                    model: "model",
                    usage: PiUsage(input: 20, output: 8, cacheRead: 0, cacheWrite: 0, cost: 0.02),
                    stopReason: "stop"
                ),
                message(role: .user, timestamp: 5_000, text: "继续处理"),
                message(
                    role: .assistant,
                    timestamp: 6_000,
                    content: [content(type: .text, text: "第二轮完成。")],
                    provider: "provider",
                    model: "model",
                    usage: PiUsage(input: 30, output: 6, cacheRead: 0, cacheWrite: 0, cost: 0.03),
                    stopReason: "stop"
                ),
            ]
        )

        try state.applySessionSnapshot(snapshot)

        XCTAssertEqual(state.activeSessionID, session.id)
        XCTAssertEqual(state.conversationAnswers.count, 2)
        let answer = try XCTUnwrap(state.conversationAnswers.first)
        XCTAssertEqual(answer.question.text, "检查项目")
        XCTAssertEqual(answer.status, .completed)
        XCTAssertEqual(answer.answerText, "开始检查。\n\n检查完成。")
        XCTAssertEqual(answer.usage.totalTokens, 45)
        guard case .tool(let tool) = answer.sections[1].content else {
            return XCTFail("第二个回答区块应为工具调用")
        }
        XCTAssertEqual(tool.output, "file contents")
        XCTAssertEqual(tool.status, .completed)
        XCTAssertEqual(state.conversationAnswers[1].question.text, "继续处理")
        XCTAssertEqual(state.conversationAnswers[1].answerText, "第二轮完成。")
    }

    @MainActor
    func testWorkspaceRejectsMainDirectorySessions() throws {
        let directory = try temporaryDirectory()
        let workspace = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let resolvedWorkspace = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let store = ConfigurationStore(applicationSupportDirectory: directory)
        var settings = AppSettings.defaults
        settings.workspacePath = resolvedWorkspace
        _ = try store.save(settings)
        let state = try AppState(
            applicationSupportDirectory: directory,
            checkForUpdates: {},
            presentSettings: {}
        )
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let mainSession = conversationSession(id: "main-session", cwd: home, firstMessage: "普通问题")
        let snapshot = SessionSnapshot(
            cwd: home,
            activeSessionPath: mainSession.path,
            activeSessionId: mainSession.id,
            sessions: [mainSession],
            messages: []
        )

        XCTAssertThrowsError(try state.applySessionSnapshot(snapshot)) { error in
            XCTAssertEqual(error.localizedDescription, "Pi 会话目录与当前范围不一致")
        }
        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertNil(state.activeSessionID)
    }

    private func conversationSession(id: String, cwd: String, firstMessage: String) -> ConversationSession {
        ConversationSession(
            path: "/sessions/\(id).jsonl",
            id: id,
            cwd: cwd,
            name: nil,
            created: 1_000,
            modified: 2_000,
            messageCount: firstMessage.isEmpty ? 0 : 1,
            firstMessage: firstMessage
        )
    }

    private func content(
        type: SavedAssistantContent.Kind,
        text: String? = nil,
        thinking: String? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        arguments: JSONValue? = nil
    ) -> SavedAssistantContent {
        SavedAssistantContent(
            type: type,
            text: text,
            thinking: thinking,
            toolCallId: toolCallId,
            toolName: toolName,
            arguments: arguments
        )
    }

    private func message(
        role: SavedSessionMessage.Role,
        timestamp: Double,
        text: String? = nil,
        content: [SavedAssistantContent]? = nil,
        provider: String? = nil,
        model: String? = nil,
        usage: PiUsage? = nil,
        stopReason: String? = nil,
        errorMessage: String? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        isError: Bool? = nil
    ) -> SavedSessionMessage {
        SavedSessionMessage(
            role: role,
            timestamp: timestamp,
            text: text,
            content: content,
            provider: provider,
            model: model,
            usage: usage,
            stopReason: stopReason,
            errorMessage: errorMessage,
            toolCallId: toolCallId,
            toolName: toolName,
            isError: isError
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickPiSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }
}
