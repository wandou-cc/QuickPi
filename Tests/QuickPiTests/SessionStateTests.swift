import AppKit
import Foundation
import XCTest
@testable import QuickPi

final class SessionStateTests: XCTestCase {
    @MainActor
    func testNativeCommandsAreAvailableBeforeRuntimeStarts() throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )

        state.draft = "/"

        XCTAssertEqual(
            state.slashCommandSuggestions.map(\.name),
            ["new", "worktree", "settings", "copy", "name", "session", "compact", "clone", "branch", "export"]
        )
        XCTAssertTrue(state.slashCommandSuggestions.allSatisfy { $0.source == .app })
        XCTAssertEqual(state.inputBarHeight, 154)
        XCTAssertEqual(state.slashCommandMenuHeight, 185)

        state.draft = "/settings"
        XCTAssertTrue(state.draftMatchesSlashCommand)
    }

    @MainActor
    func testInputEditorHeightGrowsWithinEightLineBounds() throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )

        XCTAssertEqual(state.inputBarHeight, 154)
        XCTAssertEqual(state.inputEditorBarHeight, 116)

        let editor = PromptTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 96))
        editor.string = "第一行\n第二行\n第三行\n第四行\n第五行"
        let measuredHeight = editor.contentHeight
        XCTAssertGreaterThan(measuredHeight, 96)

        state.setInputEditorHeight(measuredHeight)
        XCTAssertEqual(state.inputEditorHeight, measuredHeight)
        XCTAssertEqual(state.inputBarHeight, 58 + measuredHeight)
        XCTAssertEqual(state.inputEditorBarHeight, 20 + measuredHeight)

        state.setInputEditorHeight(1_000)
        XCTAssertEqual(state.inputBarHeight, 228)
        XCTAssertEqual(state.inputEditorBarHeight, 190)

        state.setInputEditorHeight(1)
        XCTAssertEqual(state.inputBarHeight, 154)
        XCTAssertEqual(state.inputEditorBarHeight, 116)
    }

    // Verifies that an image paste enters the existing attachment pipeline and becomes normalized JPEG data.
    @MainActor
    func testPastedImageBecomesPendingAttachment() async throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let image = NSImage(size: NSSize(width: 4, height: 2))
        image.addRepresentation(bitmap)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("QuickPiTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.writeObjects([image]))

        let providers = PromptTextView.imageProviders(from: pasteboard)
        XCTAssertEqual(providers.count, 1)

        await state.addPastedImages(providers: providers)

        let attachment = try XCTUnwrap(state.attachments.first)
        XCTAssertEqual(state.attachments.count, 1)
        XCTAssertEqual(attachment.name, "粘贴图片")
        guard case let .image(data, mimeType) = attachment.content else {
            return XCTFail("粘贴图片未生成图片附件")
        }
        XCTAssertEqual(mimeType, "image/jpeg")
        XCTAssertNotNil(NSImage(data: data))
        XCTAssertEqual(state.inputBarHeight, 192)
        XCTAssertNil(state.runtimeError)
    }

    // Confirms command search is case-insensitive and matches beyond the beginning of the name.
    @MainActor
    func testSlashCommandsSupportFuzzyNameMatching() throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )

        state.draft = "/TTI"

        XCTAssertEqual(state.slashCommandSuggestions.map(\.name), ["settings"])
    }

    func testRuntimeSnapshotDecodesCommandDescriptions() throws {
        let data = Data(
            #"{"providers":[],"models":[{"id":"gpt-5.6","name":"GPT-5.6","providerId":"openai","providerName":"OpenAI","supportsImages":true,"supportsReasoning":true}],"commands":[{"name":"review","description":"Review changes","source":"extension"},{"name":"skill:search","source":"skill"}]}"#.utf8
        )

        let snapshot = try JSONDecoder().decode(RuntimeSnapshot.self, from: data)

        XCTAssertEqual(snapshot.models.count, 1)
        XCTAssertTrue(snapshot.models[0].supportsReasoning)
        XCTAssertEqual(snapshot.commands.count, 2)
        XCTAssertEqual(snapshot.commands[0].description, "Review changes")
        XCTAssertNil(snapshot.commands[1].description)
    }

    func testCloneTurnAnchorsDecodePersistedEntryIDs() throws {
        let messages = try JSONDecoder().decode(
            PiForkMessages.self,
            from: Data(#"{"messages":[{"entryId":"entry-1","text":"原始问题"}]}"#.utf8)
        )

        XCTAssertEqual(messages.messages, [PiForkMessage(entryId: "entry-1", text: "原始问题")])
    }

    func testAnswerTextIncludesExtensionMessages() {
        let answer = AnswerSession(
            question: SubmittedQuestion(text: "/status", attachmentNames: [], workspacePath: nil),
            startedAt: Date(timeIntervalSince1970: 0),
            sections: [
                AnswerSection(id: UUID(), content: .extensionMessage("插件反馈")),
                AnswerSection(
                    id: UUID(),
                    content: .fileLink(URL(fileURLWithPath: "/tmp/pi-session.html"))
                ),
                AnswerSection(id: UUID(), content: .markdown("模型回答")),
            ],
            status: .completed
        )

        XCTAssertEqual(answer.answerText, "插件反馈\n\n/tmp/pi-session.html\n\n模型回答")
    }

    func testPiCustomMessagePreservesRawProtocolFields() throws {
        let data = Data(
            #"{"role":"custom","customType":"plugin-data","content":{"items":[1,true,null],"label":"raw"},"display":true,"details":{"nested":{"value":42}},"timestamp":1234}"#.utf8
        )

        let message = try JSONDecoder().decode(PiCustomMessage.self, from: data)

        XCTAssertEqual(message.customType, "plugin-data")
        XCTAssertEqual(message.content, .object([
            "items": .array([.integer(1), .boolean(true), .null]),
            "label": .string("raw"),
        ]))
        XCTAssertEqual(message.details, .object([
            "nested": .object(["value": .integer(42)]),
        ]))
        XCTAssertTrue(message.display)
        XCTAssertEqual(message.timestamp, 1_234)

        let nullDetailsMessage = try JSONDecoder().decode(
            PiCustomMessage.self,
            from: Data(
                #"{"customType":"plugin-null","content":"raw","display":true,"details":null,"timestamp":5678}"#.utf8
            )
        )
        XCTAssertEqual(nullDetailsMessage.details, .null)
        XCTAssertEqual(
            try JSONDecoder().decode(PiCustomMessage.self, from: JSONEncoder().encode(nullDetailsMessage)),
            nullDetailsMessage
        )
    }

    // Applies the portable qrUrl hint to every plugin type while rejecting non-web URL schemes.
    func testCustomMessageQRCodeHintIsPluginIndependent() throws {
        let url = "https://example.com/login?token=abc&source=plugin"
        let message = PiCustomMessage(
            customType: "another-login-plugin",
            content: .string("Scan to log in"),
            display: true,
            details: .object(["qrUrl": .string(url)]),
            timestamp: 1_000
        )
        let invalidMessage = PiCustomMessage(
            customType: "another-login-plugin",
            content: .string("Invalid QR payload"),
            display: true,
            details: .object(["qrUrl": .string("file:///tmp/login")]),
            timestamp: 2_000
        )

        XCTAssertEqual(message.qrCode, .url(try XCTUnwrap(URL(string: url))))
        XCTAssertEqual(invalidMessage.qrCode, .invalid)
        XCTAssertEqual(
            PiCustomMessage(
                customType: "plain-plugin",
                content: .string("No QR"),
                display: true,
                details: .object(["value": .integer(1)]),
                timestamp: 3_000
            ).qrCode,
            .absent
        )
    }

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
                message(entryId: "user-1", role: .user, timestamp: 1_000, text: "检查项目"),
                message(
                    entryId: "assistant-1",
                    role: .assistant,
                    timestamp: 2_000,
                    content: [
                        content(type: .text, text: "开始检查。"),
                        content(type: .thinking, thinking: " \n"),
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
                    entryId: "tool-1",
                    role: .toolResult,
                    timestamp: 3_000,
                    text: "file contents",
                    toolCallId: "call-1",
                    toolName: "read",
                    isError: false
                ),
                message(
                    entryId: "assistant-2",
                    role: .assistant,
                    timestamp: 4_000,
                    content: [content(type: .text, text: "检查完成。")],
                    provider: "provider",
                    model: "model",
                    usage: PiUsage(input: 20, output: 8, cacheRead: 0, cacheWrite: 0, cost: 0.02),
                    stopReason: "stop"
                ),
                message(entryId: "user-2", role: .user, timestamp: 5_000, text: "继续处理"),
                message(
                    entryId: "assistant-3",
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
        XCTAssertEqual(answer.question?.text, "检查项目")
        XCTAssertEqual(answer.cloneEntryId, "user-1")
        XCTAssertEqual(answer.status, .completed)
        XCTAssertEqual(answer.answerText, "开始检查。\n\n检查完成。")
        XCTAssertFalse(answer.sections.contains { section in
            if case .thinking = section.content {
                return true
            }
            return false
        })
        XCTAssertEqual(answer.usage.totalTokens, 45)
        guard case .tool(let tool) = answer.sections[1].content else {
            return XCTFail("第二个回答区块应为工具调用")
        }
        XCTAssertEqual(tool.output, "file contents")
        XCTAssertEqual(tool.status, .completed)
        XCTAssertEqual(state.conversationAnswers[1].question?.text, "继续处理")
        XCTAssertEqual(state.conversationAnswers[1].cloneEntryId, "user-2")
        XCTAssertEqual(state.conversationAnswers[1].answerText, "第二轮完成。")

        state.toggleResultPanel()
        XCTAssertFalse(state.showsResultPanel)
        state.toggleResultPanel()
        XCTAssertTrue(state.showsResultPanel)
    }

    // Switches the current window to the cloned session while keeping the source session record.
    @MainActor
    func testClonedTurnBecomesActiveSessionWithEmptyDraft() throws {
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
        let sourceSession = conversationSession(id: "source-session", cwd: cwd, firstMessage: "第一轮")
        let clonedSession = conversationSession(id: "cloned-session", cwd: cwd, firstMessage: "第一轮")
        let firstTurn = [
            message(entryId: "user-1", role: .user, timestamp: 1_000, text: "第一轮"),
            message(
                entryId: "assistant-1",
                role: .assistant,
                timestamp: 2_000,
                content: [content(type: .text, text: "第一轮回答")],
                provider: "provider",
                model: "model",
                usage: PiUsage(input: 10, output: 5, cacheRead: 0, cacheWrite: 0, cost: 0.01),
                stopReason: "stop"
            ),
        ]
        try state.applySessionSnapshot(SessionSnapshot(
            cwd: cwd,
            activeSessionPath: sourceSession.path,
            activeSessionId: sourceSession.id,
            sessions: [sourceSession],
            messages: firstTurn + [
                message(entryId: "user-2", role: .user, timestamp: 3_000, text: "第二轮"),
                message(
                    entryId: "assistant-2",
                    role: .assistant,
                    timestamp: 4_000,
                    content: [content(type: .text, text: "第二轮回答")],
                    provider: "provider",
                    model: "model",
                    usage: PiUsage(input: 12, output: 6, cacheRead: 0, cacheWrite: 0, cost: 0.02),
                    stopReason: "stop"
                ),
            ]
        ))
        state.draft = "原会话草稿"

        try state.applySessionSnapshot(SessionSnapshot(
            cwd: cwd,
            activeSessionPath: clonedSession.path,
            activeSessionId: clonedSession.id,
            sessions: [clonedSession, sourceSession],
            messages: firstTurn
        ))

        XCTAssertEqual(state.activeSessionID, clonedSession.id)
        XCTAssertEqual(Set(state.sessions.map(\.id)), Set([sourceSession.id, clonedSession.id]))
        XCTAssertEqual(state.conversationAnswers.map { $0.question?.text }, ["第一轮"])
        XCTAssertEqual(state.conversationAnswers.first?.answerText, "第一轮回答")
        XCTAssertTrue(state.draft.isEmpty)
    }

    @MainActor
    func testRuntimeErrorCanBeCollapsedAndReopened() throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )

        state.runtimeError = "运行失败"
        XCTAssertTrue(state.showsResultPanel)

        state.toggleResultPanel()
        XCTAssertFalse(state.showsResultPanel)
        state.toggleResultPanel()
        XCTAssertTrue(state.showsResultPanel)
    }

    // Keeps active native-editor input intact while model events continuously refresh the answer view.
    @MainActor
    func testStreamingOutputPreservesEditedDraft() throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )
        _ = try applyEmptySession(to: state, id: "session-streaming-draft")

        state.consume(.userMessage("正在回答的问题"))
        state.consume(.agentStarted)
        state.draft = "输出期间输入的新问题"
        state.consume(.thinkingDelta("继续思考"))
        state.consume(.textDelta("第一段输出"))
        state.consume(.textDelta("第二段输出"))

        XCTAssertEqual(state.draft, "输出期间输入的新问题")
        XCTAssertEqual(state.answer?.answerText, "第一段输出第二段输出")
    }

    // Splits queued steering and follow-up deliveries into the exact user turns emitted by Pi.
    @MainActor
    func testQueuedMessagesBecomeSeparateConversationTurns() throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )
        _ = try applyEmptySession(to: state, id: "session-queue")

        state.consume(.userMessage("正在处理"))
        state.consume(.agentStarted)
        state.consume(.textDelta("第一轮回答"))
        state.consume(.queueChanged(steering: ["优先处理"], followUp: ["稍后处理"]))

        XCTAssertEqual(state.queuedSteeringMessages, ["优先处理"])
        XCTAssertEqual(state.queuedFollowUpMessages, ["稍后处理"])
        XCTAssertTrue(state.showsResultPanel)

        state.consume(.queueChanged(steering: [], followUp: ["稍后处理"]))
        state.consume(.userMessage("优先处理"))
        state.consume(.textDelta("插队回答"))

        XCTAssertEqual(
            state.conversationAnswers.map { $0.question?.text },
            ["正在处理", "优先处理"]
        )
        XCTAssertEqual(state.conversationAnswers[0].status, .completed)
        XCTAssertEqual(state.answer?.status, .running)

        state.consume(.queueChanged(steering: [], followUp: []))
        state.consume(.userMessage("稍后处理"))
        state.consume(.textDelta("排队回答"))
        state.consume(.settled)

        XCTAssertEqual(
            state.conversationAnswers.map { $0.question?.text },
            ["正在处理", "优先处理", "稍后处理"]
        )
        XCTAssertEqual(state.conversationAnswers[1].status, .completed)
        XCTAssertEqual(state.answer?.status, .completed)
        XCTAssertEqual(state.answer?.answerText, "排队回答")
        XCTAssertTrue(state.queuedSteeringMessages.isEmpty)
        XCTAssertTrue(state.queuedFollowUpMessages.isEmpty)
    }

    // Keeps a plugin command and its fire-and-forget notification in the same visible conversation turn.
    @MainActor
    func testExtensionNotificationAppearsUnderVisiblePluginCommand() throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )
        _ = try applyEmptySession(to: state, id: "session-notify")

        state.consume(.userMessage("/weixin-login"))
        state.consume(.extensionNotification(ExtensionNotification(
            message: "✅ WeChat session restored from cache",
            kind: .info
        )))
        state.consume(.settled)

        let answer = try XCTUnwrap(state.answer)
        XCTAssertEqual(answer.question?.text, "/weixin-login")
        XCTAssertEqual(answer.answerText, "✅ WeChat session restored from cache")
        XCTAssertEqual(answer.status, .completed)
        guard case .extensionNotification(let notification) = answer.sections.first?.content else {
            return XCTFail("插件通知应作为正文区块显示")
        }
        XCTAssertEqual(notification.kind, .info)
        XCTAssertTrue(state.showsResultPanel)
        XCTAssertEqual(state.inputBarHeight, 154)
    }

    // Keeps fire-and-forget plugin output when an idle session later receives a fresh Pi process.
    @MainActor
    func testRebindingLoadedSessionPreservesTransientPluginConversation() throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )
        let session = try applyEmptySession(to: state, id: "session-rebind")
        state.consume(.userMessage("/weixin-login"))
        state.consume(.extensionNotification(ExtensionNotification(
            message: "Session restored",
            kind: .info
        )))
        state.consume(.settled)

        try state.applySessionSnapshot(SessionSnapshot(
            cwd: session.cwd,
            activeSessionPath: session.path,
            activeSessionId: session.id,
            sessions: [session],
            messages: []
        ), preservingInput: true)

        XCTAssertEqual(state.answer?.question?.text, "/weixin-login")
        XCTAssertEqual(state.answer?.answerText, "Session restored")
        XCTAssertEqual(state.answer?.status, .completed)
    }

    // Shows persistent custom messages as standalone entries when no user turn owns them.
    @MainActor
    func testDisplayableExtensionMessageHasNoSyntheticQuestion() throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )
        _ = try applyEmptySession(to: state, id: "session-message")

        let message = PiCustomMessage(
            customType: "plugin-data",
            content: .object([
                "items": .array([.integer(1), .boolean(true), .null]),
                "label": .string("raw"),
            ]),
            display: true,
            details: .object(["nested": .object(["value": .integer(42)])]),
            timestamp: 1_000
        )
        state.consume(.customMessage(message))

        let answer = try XCTUnwrap(state.answer)
        XCTAssertNil(answer.question)
        guard case .customMessage(let restoredMessage) = answer.sections.first?.content else {
            return XCTFail("插件消息应按原始自定义消息显示")
        }
        XCTAssertEqual(restoredMessage, message)
        XCTAssertTrue(answer.answerText.contains("[plugin-data]"))
        XCTAssertTrue(answer.answerText.contains("\"items\""))
        XCTAssertTrue(answer.answerText.contains("\"nested\""))
        XCTAssertTrue(state.showsResultPanel)
    }

    // Exercises every fire-and-forget field that Pi documents for RPC extension clients.
    @MainActor
    func testRuntimeExtensionUIProtocolUpdatesNativeStateByKey() throws {
        let directory = try temporaryDirectory()
        let state = try AppState(
            applicationSupportDirectory: directory,
            checkForUpdates: {},
            presentSettings: {}
        )
        _ = try applyEmptySession(to: state, id: "session-ui")
        let runtime = PiRuntime(applicationSupportDirectory: directory)
        runtime.onEvent = { state.consume($0) }

        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"1","method":"notify","message":"Saved","notifyType":"warning"}"#.utf8
        ))
        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"2","method":"setStatus","statusKey":"sync","statusText":"\u001b[33mSyncing\u001b[0m"}"#.utf8
        ))
        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"3","method":"setWidget","widgetKey":"tasks","widgetLines":["\u001b[2m☐ \u001b[0mTask 1","Task 2"],"widgetPlacement":"belowEditor"}"#.utf8
        ))
        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"4","method":"setTitle","title":"Plugin workspace"}"#.utf8
        ))
        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"5","method":"set_editor_text","text":"prefilled"}"#.utf8
        ))

        XCTAssertEqual(state.answer?.answerText, "Saved")
        guard case .extensionNotification(let notification) = state.answer?.sections.first?.content else {
            return XCTFail("notify 应进入正文")
        }
        XCTAssertEqual(notification.kind, .warning)
        XCTAssertEqual(state.extensionStatuses, [ExtensionStatus(key: "sync", text: "Syncing")])
        XCTAssertEqual(
            state.extensionWidgets,
            [ExtensionWidget(key: "tasks", lines: ["☐ Task 1", "Task 2"], placement: .belowEditor)]
        )
        XCTAssertEqual(state.extensionTitle, "Plugin workspace")
        XCTAssertEqual(state.draft, "prefilled")
        XCTAssertEqual(state.inputBarHeight, 198)

        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"6","method":"setStatus","statusKey":"sync","statusText":"Done"}"#.utf8
        ))
        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"7","method":"setWidget","widgetKey":"tasks","widgetLines":["Done"]}"#.utf8
        ))

        XCTAssertEqual(state.extensionStatuses, [ExtensionStatus(key: "sync", text: "Done")])
        XCTAssertEqual(
            state.extensionWidgets,
            [ExtensionWidget(key: "tasks", lines: ["Done"], placement: .aboveEditor)]
        )

        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"8","method":"setStatus","statusKey":"sync"}"#.utf8
        ))
        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"9","method":"setWidget","widgetKey":"tasks"}"#.utf8
        ))

        XCTAssertTrue(state.extensionStatuses.isEmpty)
        XCTAssertTrue(state.extensionWidgets.isEmpty)

        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"plan-status","method":"setStatus","statusKey":"plan-mode","statusText":"📋 1/2"}"#.utf8
        ))
        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"plan-widget","method":"setWidget","widgetKey":"plan-todos","widgetLines":["☑ Inspect the chain","☐ Move the progress UI"]}"#.utf8
        ))

        XCTAssertEqual(
            state.extensionStatuses,
            [ExtensionStatus(key: ExtensionStatus.planModeKey, text: "📋 1/2")]
        )
        XCTAssertEqual(
            state.extensionWidgets,
            [ExtensionWidget(
                key: ExtensionWidget.planModeKey,
                lines: ["☑ Inspect the chain", "☐ Move the progress UI"],
                placement: .aboveEditor
            )]
        )
        XCTAssertEqual(state.inputBarHeight, 154)

        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"clear-plan-status","method":"setStatus","statusKey":"plan-mode"}"#.utf8
        ))
        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"clear-plan-widget","method":"setWidget","widgetKey":"plan-todos"}"#.utf8
        ))

        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"10","method":"select","title":"Plan mode - what next?","options":["Execute the plan (track progress)","Stay in plan mode","Refine the plan"]}"#.utf8
        ))
        XCTAssertEqual(state.extensionPrompt, ExtensionPrompt(
            requestId: "10",
            method: "select",
            title: "Plan mode - what next?",
            message: nil,
            placeholder: nil,
            options: ["Execute the plan (track progress)", "Stay in plan mode", "Refine the plan"],
            prefill: nil
        ))

        try runtime.consumeExtensionRequest(Data(
            #"{"type":"extension_ui_request","id":"11","method":"editor","title":"Refine the plan:","prefill":"Keep the tests focused"}"#.utf8
        ))
        XCTAssertEqual(state.extensionPrompt, ExtensionPrompt(
            requestId: "11",
            method: "editor",
            title: "Refine the plan:",
            message: nil,
            placeholder: nil,
            options: [],
            prefill: "Keep the tests focused"
        ))
    }

    // Keeps concurrent event streams isolated and marks only unseen background completion.
    @MainActor
    func testParallelSessionsExposeRunningAndUnreadCompletionStates() throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )
        let cwd = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let foreground = conversationSession(id: "foreground", cwd: cwd, firstMessage: "前台会话")
        let background = conversationSession(id: "background", cwd: cwd, firstMessage: "")
        try state.applySessionSnapshot(SessionSnapshot(
            cwd: cwd,
            activeSessionPath: foreground.path,
            activeSessionId: foreground.id,
            sessions: [foreground, background],
            messages: []
        ))

        state.consume(.userMessage("后台任务"), sessionID: background.id)
        state.consume(.agentStarted, sessionID: background.id)
        state.consume(.textDelta("后台回答"), sessionID: background.id)

        XCTAssertEqual(state.activeSessionID, foreground.id)
        XCTAssertTrue(state.isSessionRunning(id: background.id))
        XCTAssertFalse(state.hasUnreadCompletion(id: background.id))
        XCTAssertTrue(state.conversationAnswers.isEmpty)

        state.consume(.settled, sessionID: background.id)

        XCTAssertFalse(state.isSessionRunning(id: background.id))
        XCTAssertTrue(state.hasUnreadCompletion(id: background.id))
        XCTAssertEqual(state.title(for: background), "后台任务")

        try state.applySessionSnapshot(SessionSnapshot(
            cwd: cwd,
            activeSessionPath: background.path,
            activeSessionId: background.id,
            sessions: [foreground, background],
            messages: [
                message(entryId: "user-bg", role: .user, timestamp: 1_000, text: "后台任务"),
                message(
                    entryId: "assistant-bg",
                    role: .assistant,
                    timestamp: 2_000,
                    content: [content(type: .text, text: "后台回答")],
                    provider: "provider",
                    model: "model",
                    usage: PiUsage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, cost: 0),
                    stopReason: "stop"
                ),
            ]
        ))

        XCTAssertEqual(state.activeSessionID, background.id)
        XCTAssertFalse(state.hasUnreadCompletion(id: background.id))
        XCTAssertEqual(state.conversationAnswers.first?.answerText, "后台回答")
    }

    // Keeps a running session visible when a newly created process scans disk before that session is listed.
    @MainActor
    func testNewSessionSnapshotRetainsConcurrentRunningSession() throws {
        let state = try AppState(
            applicationSupportDirectory: try temporaryDirectory(),
            checkForUpdates: {},
            presentSettings: {}
        )
        let cwd = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let first = conversationSession(id: "first", cwd: cwd, firstMessage: "第一个会话")
        let running = conversationSession(id: "running", cwd: cwd, firstMessage: "")
        let created = conversationSession(id: "created", cwd: cwd, firstMessage: "")
        try state.applySessionSnapshot(SessionSnapshot(
            cwd: cwd,
            activeSessionPath: first.path,
            activeSessionId: first.id,
            sessions: [first, running],
            messages: []
        ))

        state.consume(.userMessage("后台任务"), sessionID: running.id)
        state.consume(.agentStarted, sessionID: running.id)
        try state.applySessionSnapshot(SessionSnapshot(
            cwd: cwd,
            activeSessionPath: created.path,
            activeSessionId: created.id,
            sessions: [created, first],
            messages: []
        ))

        XCTAssertEqual(state.activeSessionID, created.id)
        XCTAssertEqual(Set(state.sessions.map(\.id)), Set([first.id, running.id, created.id]))
        XCTAssertTrue(state.isSessionRunning(id: running.id))

        state.consume(.settled, sessionID: running.id)
        try state.applySessionSnapshot(SessionSnapshot(
            cwd: cwd,
            activeSessionPath: created.path,
            activeSessionId: created.id,
            sessions: [created, first],
            messages: []
        ), preservingInput: true)

        XCTAssertEqual(state.sessions.map(\.id), [created.id, first.id])
    }

    // Restores displayable custom messages from the active Pi branch after a runtime restart.
    @MainActor
    func testSessionSnapshotRestoresDisplayableExtensionMessage() throws {
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
        let session = conversationSession(id: "session-custom", cwd: cwd, firstMessage: "")
        let snapshot = SessionSnapshot(
            cwd: cwd,
            activeSessionPath: session.path,
            activeSessionId: session.id,
            sessions: [session],
            messages: [
                message(
                    entryId: "custom-hidden",
                    role: .custom,
                    timestamp: 500,
                    customMessage: PiCustomMessage(
                        customType: "plugin-hidden",
                        content: .string("Hidden plugin output"),
                        display: false,
                        details: .null,
                        timestamp: 500
                    )
                ),
                message(
                    entryId: "custom-1",
                    role: .custom,
                    timestamp: 1_000,
                    customMessage: PiCustomMessage(
                        customType: "plugin-output",
                        content: .string("Persistent plugin output"),
                        display: true,
                        details: .object(["nested": .object(["enabled": .boolean(true)])]),
                        timestamp: 1_000
                    )
                ),
            ]
        )

        try state.applySessionSnapshot(snapshot)

        let answer = try XCTUnwrap(state.conversationAnswers.first)
        XCTAssertNil(answer.question)
        XCTAssertEqual(answer.sections.count, 1)
        guard case .customMessage(let message) = answer.sections[0].content else {
            return XCTFail("历史插件消息应保留原始结构")
        }
        XCTAssertEqual(message, PiCustomMessage(
            customType: "plugin-output",
            content: .string("Persistent plugin output"),
            display: true,
            details: .object(["nested": .object(["enabled": .boolean(true)])]),
            timestamp: 1_000
        ))
        XCTAssertEqual(
            answer.answerText,
            """
            [plugin-output]
            Persistent plugin output

            details:
            {
              "nested" : {
                "enabled" : true
              }
            }
            """
        )
        XCTAssertEqual(answer.status, .completed)
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
            XCTAssertEqual(error.localizedDescription, "Pi 会话目录不属于当前项目")
        }
        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertNil(state.activeSessionID)
    }

    // Keeps one selected checkout and all of its managed worktree sessions in the same project scope.
    @MainActor
    func testManagedWorktreeSessionsUsePersistedWorkingDirectoryOwnership() throws {
        let directory = try temporaryDirectory()
        let localWorkspace = directory.appendingPathComponent("project", isDirectory: true)
        let worktreeWorkspace = directory.appendingPathComponent("worktree", isDirectory: true)
        let foreignWorkspace = directory.appendingPathComponent("foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: localWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreignWorkspace, withIntermediateDirectories: true)

        let localPath = localWorkspace.standardizedFileURL.resolvingSymlinksInPath().path
        let worktreePath = worktreeWorkspace.standardizedFileURL.resolvingSymlinksInPath().path
        let foreignPath = foreignWorkspace.standardizedFileURL.resolvingSymlinksInPath().path
        let store = ConfigurationStore(applicationSupportDirectory: directory)
        var settings = AppSettings.defaults
        settings.workspacePath = localPath
        _ = try store.save(settings)
        try store.saveManagedWorktrees([ManagedWorktree(
            id: "worktree-1",
            repositoryPath: localPath,
            localWorkspacePath: localPath,
            worktreePath: worktreePath,
            workspacePath: worktreePath,
            baseCommit: "0123456789abcdef",
            createdAt: 1_000,
            branch: nil
        )])
        let state = try AppState(
            applicationSupportDirectory: directory,
            checkForUpdates: {},
            presentSettings: {}
        )
        let localSession = conversationSession(id: "local", cwd: localPath, firstMessage: "本地")
        let worktreeSession = conversationSession(id: "worktree", cwd: worktreePath, firstMessage: "Worktree")
        let foreignSession = conversationSession(id: "foreign", cwd: foreignPath, firstMessage: "其他项目")

        try state.applySessionSnapshot(SessionSnapshot(
            cwd: localPath,
            activeSessionPath: localSession.path,
            activeSessionId: localSession.id,
            sessions: [localSession, worktreeSession, foreignSession],
            messages: []
        ))

        XCTAssertEqual(state.sessions.map(\.id), [localSession.id, worktreeSession.id])
        XCTAssertEqual(state.worktreeLabel(for: worktreeSession), "detached HEAD")
        XCTAssertFalse(state.isManagedWorktreeSession(id: localSession.id))
        XCTAssertTrue(state.isManagedWorktreeSession(id: worktreeSession.id))

        try state.applySessionSnapshot(SessionSnapshot(
            cwd: worktreePath,
            activeSessionPath: worktreeSession.path,
            activeSessionId: worktreeSession.id,
            sessions: [localSession, worktreeSession, foreignSession],
            messages: []
        ))

        XCTAssertEqual(state.activeWorkingDirectoryURL.path, worktreePath)
        XCTAssertEqual(state.activeManagedWorktree?.id, "worktree-1")
        XCTAssertEqual(state.scopeTitle, "project")
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

    @MainActor
    private func applyEmptySession(to state: AppState, id: String) throws -> ConversationSession {
        let cwd = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let session = conversationSession(id: id, cwd: cwd, firstMessage: "")
        try state.applySessionSnapshot(SessionSnapshot(
            cwd: cwd,
            activeSessionPath: session.path,
            activeSessionId: session.id,
            sessions: [session],
            messages: []
        ))
        return session
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
        entryId: String,
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
        isError: Bool? = nil,
        customMessage: PiCustomMessage? = nil
    ) -> SavedSessionMessage {
        SavedSessionMessage(
            entryId: entryId,
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
            isError: isError,
            customMessage: customMessage
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
