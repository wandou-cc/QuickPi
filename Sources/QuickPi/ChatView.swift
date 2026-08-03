import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import MarkdownUI
import SystemConfiguration
import SwiftUI
import UniformTypeIdentifiers

private let chatMessageFontSize = QuickPiTypography.bodySize
private let qrCodeContext = CIContext()

private struct SlashCommandScrollRequest: Equatable {
    let id = UUID()
    let commandName: String
}

private struct ResultBottomPreferenceKey: PreferenceKey {
    static let defaultValue = CGFloat.infinity

    // Keeps the single bottom position emitted by the result content.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// Retains scroll position without invalidating the view for every scroll-wheel event.
private final class ResultScrollTracker {
    var isAtBottom = true
    var followsPendingAnswerChange = false
}

final class PromptTextView: NSTextView {
    private static let preferredImageTypeIdentifiers = [
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.heic.identifier,
        UTType.tiff.identifier,
    ]

    var onPasteImages: (([NSItemProvider]) -> Void)?
    var onSubmit: (() -> Void)?
    var onMoveSuggestion: ((Int) -> Bool)?
    var onWidthChange: (() -> Void)?

    // Creates the standard AppKit text system required by the designated text-view initializer.
    override convenience init(frame frameRect: NSRect) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(
            width: frameRect.width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        layoutManager.addTextContainer(textContainer)
        self.init(frame: frameRect, textContainer: textContainer)
    }

    // Configures the plain multiline editor used inside the SwiftUI input bar.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        drawsBackground = false
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        font = .systemFont(ofSize: chatMessageFontSize)
        textColor = .labelColor
        textContainerInset = NSSize(width: 6, height: 10)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 96)
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    // This editor is created in code and is never restored from an AppKit archive.
    required init?(coder: NSCoder) {
        fatalError("PromptTextView does not support NSCoder")
    }

    // Returns the laid-out text height, including the editor's vertical insets.
    var contentHeight: CGFloat {
        guard let layoutManager, let textContainer else {
            preconditionFailure("PromptTextView requires its AppKit text system")
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let textBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let textBottom = max(textBounds.maxY, layoutManager.extraLineFragmentRect.maxY)
        return ceil(textBottom + textContainerInset.height * 2)
    }

    // Lets AppKit route Command-V for image-only clipboards to the custom paste handler.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for identifier in Self.preferredImageTypeIdentifiers {
            let type = NSPasteboard.PasteboardType(identifier)
            if !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    // Converts every clipboard image representation into the existing attachment input contract.
    static func imageProviders(from pasteboard: NSPasteboard) -> [NSItemProvider] {
        var providers: [NSItemProvider] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let imageTypes = item.types.filter { pasteboardType in
                UTType(pasteboardType.rawValue)?.conforms(to: .image) == true
            }
            let preferredType = preferredImageTypeIdentifiers.lazy.compactMap { identifier in
                imageTypes.first(where: { $0.rawValue == identifier })
            }.first ?? imageTypes.first
            if let preferredType, let data = item.data(forType: preferredType) {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(
                    forTypeIdentifier: preferredType.rawValue,
                    visibility: .all
                ) { completion in
                    completion(data, nil)
                    return nil
                }
                providers.append(provider)
                continue
            }

            if let value = item.string(forType: .fileURL),
               let url = URL(string: value),
               url.isFileURL,
               isImageFile(url),
               let provider = NSItemProvider(contentsOf: url) {
                provider.suggestedName = url.lastPathComponent
                providers.append(provider)
            }
        }
        if !providers.isEmpty {
            return providers
        }

        let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
        return images.map { NSItemProvider(object: $0) }
    }

    // Recognizes extension-based and extensionless image files copied from Finder.
    private static func isImageFile(_ url: URL) -> Bool {
        if let contentType = UTType(filenameExtension: url.pathExtension) {
            return contentType.conforms(to: .image)
        }
        return (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?
            .conforms(to: .image) == true
    }

    // Adds image attachments and inserts an accompanying plain-text representation at the selection.
    @discardableResult
    func handleImagePaste(from pasteboard: NSPasteboard) -> Bool {
        let providers = Self.imageProviders(from: pasteboard)
        guard !providers.isEmpty else {
            return false
        }
        guard let onPasteImages else {
            preconditionFailure("PromptTextView image paste handler is not configured")
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            insertText(text, replacementRange: selectedRange())
        }
        onPasteImages(providers)
        return true
    }

    // Sends image paste commands to the attachment pipeline while preserving native text paste.
    override func paste(_ sender: Any?) {
        if !handleImagePaste(from: .general) {
            super.paste(sender)
        }
    }

    // Preserves submit and slash-command navigation before passing ordinary editing keys to AppKit.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.isEmpty && !hasMarkedText() {
            if event.keyCode == 36 || event.keyCode == 76 {
                guard let onSubmit else {
                    preconditionFailure("PromptTextView submit handler is not configured")
                }
                onSubmit()
                return
            }
            if event.keyCode == 126 || event.keyCode == 125 {
                guard let onMoveSuggestion else {
                    preconditionFailure("PromptTextView suggestion handler is not configured")
                }
                let offset = event.keyCode == 126 ? -1 : 1
                if onMoveSuggestion(offset) {
                    return
                }
            }
        }
        super.keyDown(with: event)
    }

    // Recalculates wrapped text when the available editor width changes.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) >= 1
        super.setFrameSize(newSize)
        if widthChanged {
            onWidthChange?()
        }
    }
}

private struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onHeightChange: (CGFloat) -> Void
    let onPasteImages: ([NSItemProvider]) -> Void
    let onSubmit: () -> Void
    let onMoveSuggestion: (Int) -> Bool

    // Creates the coordinator that keeps AppKit editing state synchronized with SwiftUI.
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // Builds one vertically resizable native text view inside a transparent scroll container.
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false

        let textView = PromptTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.delegate = context.coordinator
        textView.onPasteImages = { context.coordinator.parent.onPasteImages($0) }
        textView.onSubmit = { context.coordinator.parent.onSubmit() }
        textView.onMoveSuggestion = { context.coordinator.parent.onMoveSuggestion($0) }
        textView.onWidthChange = { context.coordinator.scheduleHeightUpdate() }
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scheduleHeightUpdate()
        return scrollView
    }

    // Applies external draft and focus changes without replacing user-driven selections.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else {
            preconditionFailure("PromptEditor requires its native text view")
        }
        let bindingTextChanged = text != context.coordinator.representedText
        context.coordinator.representedText = text
        if bindingTextChanged && textView.string != text {
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            context.coordinator.scheduleHeightUpdate()
        }
        if isFocused && textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                guard context.coordinator.parent.isFocused,
                      let window = textView.window else {
                    return
                }
                window.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        var representedText: String
        weak var textView: PromptTextView?
        private var heightUpdateScheduled = false

        // Stores the current SwiftUI bindings and action closures for native callbacks.
        init(parent: PromptEditor) {
            self.parent = parent
            representedText = parent.text
        }

        // Propagates native text edits and their new intrinsic height.
        func textDidChange(_ notification: Notification) {
            guard let textView else {
                preconditionFailure("PromptEditor text callback requires its native text view")
            }
            parent.text = textView.string
            representedText = textView.string
            parent.onHeightChange(textView.contentHeight)
        }

        // Keeps the SwiftUI focus border in sync when editing begins.
        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        // Keeps the SwiftUI focus border in sync when editing ends.
        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        // Defers layout-driven measurements until AppKit has updated line wrapping.
        func scheduleHeightUpdate() {
            guard !heightUpdateScheduled else {
                return
            }
            heightUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView else {
                    return
                }
                heightUpdateScheduled = false
                parent.onHeightChange(textView.contentHeight)
            }
        }
    }
}

extension Notification.Name {
    static let quickPiFocusInput = Notification.Name("quickPiFocusInput")
    static let quickPiPresentSettings = Notification.Name("quickPiPresentSettings")
    static let quickPiPresentGitActions = Notification.Name("quickPiPresentGitActions")
}

private enum AppModal: String, Identifiable {
    case settings
    case git

    var id: String { rawValue }
}

struct ChatView: View {
    @ObservedObject var state: AppState
    let togglePanelZoom: () -> Void
    let presentGitActions: () -> Void
    let setPanelHidesOnDeactivate: (Bool) -> Void
    @AppStorage(QuickPiTheme.storageKey) private var theme = QuickPiTheme.system
    @AppStorage("showSystemStatus") private var showSystemStatus = true
    @State private var promptFocused = false
    @State private var confirmsDeletingSessions = false
    @State private var sessionPendingDeletion: ConversationSession?
    @State private var sessionsPresented = false
    @State private var planPresented = false
    @State private var selectedSlashCommandIndex = 0
    @State private var slashCommandScrollRequest: SlashCommandScrollRequest?
    @State private var modelMenuPresented = false
    @State private var resultScrollTracker = ResultScrollTracker()
    @State private var activeModal: AppModal?
    @State private var editingAnswerID: UUID?
    @State private var editedQuestion = ""
    @State private var editingQueuedMessageID: String?
    @State private var editedQueuedMessage = ""
    @FocusState private var editedQuestionFocused: Bool
    @FocusState private var editedQueuedMessageFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            contextBar
            if !state.slashCommandSuggestions.isEmpty {
                slashCommandMenu
            } else if state.showsResultPanel {
                resultPanel
            }
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.quickPiWindowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.primary.opacity(0.12))
        }
        .sheet(item: $activeModal) { modal in
            switch modal {
            case .settings:
                SettingsView(
                    state: state,
                    setPanelHidesOnDeactivate: setPanelHidesOnDeactivate
                )
                .dynamicTypeSize(.medium)
            case .git:
                GitActionsView(state: state)
                    .dynamicTypeSize(.medium)
            }
        }
        .sheet(isPresented: Binding(
            get: { state.questionnairePrompt != nil },
            set: { presented in
                if !presented && state.questionnairePrompt != nil {
                    state.cancelQuestionnaire()
                }
            }
        )) {
            if let prompt = state.questionnairePrompt {
                QuestionnairePromptView(state: state, prompt: prompt)
            }
        }
        .sheet(isPresented: Binding(
            get: { state.extensionPrompt != nil },
            set: { presented in
                if !presented && state.extensionPrompt != nil {
                    state.cancelExtensionPrompt()
                }
            }
        )) {
            if let prompt = state.extensionPrompt {
                ExtensionPromptView(state: state, prompt: prompt)
            }
        }
        .alert("删除全部会话？", isPresented: $confirmsDeletingSessions) {
            Button("取消", role: .cancel) {}
            Button("删除全部", role: .destructive) {
                Task { await state.deleteAllSessions() }
            }
        } message: {
            Text("仅当所有托管 Worktree 都没有未提交改动时，才会清理 Worktree 并删除全部会话。操作无法撤销。")
        }
        .alert("删除会话？", isPresented: Binding(
            get: { sessionPendingDeletion != nil },
            set: { presented in
                if !presented {
                    sessionPendingDeletion = nil
                }
            }
        )) {
            Button("取消", role: .cancel) {
                sessionPendingDeletion = nil
            }
            Button("删除", role: .destructive) {
                guard let session = sessionPendingDeletion else {
                    return
                }
                sessionPendingDeletion = nil
                Task { await state.deleteSession(id: session.id) }
            }
        } message: {
            if let session = sessionPendingDeletion,
               state.isManagedWorktreeSession(id: session.id) {
                Text("会删除此会话。如果它是所属 Worktree 的最后一个会话，也会清理该 Worktree；存在未提交改动时删除会被取消。")
            } else {
                Text("会话记录删除后无法恢复。")
            }
        }
        .preferredColorScheme(theme.colorScheme)
        .task(id: "\(state.activeSessionID ?? "")\0\(state.scopePath)") {
            await state.refreshGitStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickPiFocusInput)) { _ in
            promptFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickPiPresentSettings)) { _ in
            activeModal = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickPiPresentGitActions)) { _ in
            activeModal = .git
        }
        .onChange(of: state.draft) { _, _ in
            selectedSlashCommandIndex = 0
            if !state.slashCommandSuggestions.isEmpty {
                modelMenuPresented = false
            }
        }
        .onChange(of: state.slashCommands) { _, _ in
            if !state.slashCommandSuggestions.isEmpty {
                modelMenuPresented = false
            }
        }
        .onChange(of: state.activeSessionID) { _, _ in
            editingAnswerID = nil
            editedQuestion = ""
            editedQuestionFocused = false
            editingQueuedMessageID = nil
            editedQueuedMessage = ""
            editedQueuedMessageFocused = false
        }
        .onChange(of: state.queuedMessages.map(\.id)) { _, ids in
            guard let editingQueuedMessageID, !ids.contains(editingQueuedMessageID) else {
                return
            }
            self.editingQueuedMessageID = nil
            editedQueuedMessage = ""
            editedQueuedMessageFocused = false
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            ForEach(state.extensionWidgets.filter {
                $0.key != ExtensionWidget.planModeKey && $0.placement == .aboveEditor
            }) { widget in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(widget.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
                            .help(line)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .frame(height: CGFloat(widget.lines.count * 16 + 12))
                .background(.primary.opacity(0.025))
            }

            VStack(spacing: 0) {
                if !state.attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(state.attachments) { attachment in
                                inputAttachmentView(attachment)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 52)
                }

                promptEditorArea
                    .padding(.horizontal, 8)

                composerToolbar
                    .padding(.horizontal, 8)
                    .frame(height: 38)
            }
            .background(
                Color.quickPiControlBackground,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .padding(.vertical, 10)
            .containerRelativeFrame(.horizontal) { availableWidth, _ in
                availableWidth * (state.showsResultPanel ? 0.85 : 0.98)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            ForEach(state.extensionWidgets.filter {
                $0.key != ExtensionWidget.planModeKey && $0.placement == .belowEditor
            }) { widget in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(widget.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
                            .help(line)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .frame(height: CGFloat(widget.lines.count * 16 + 12))
                .background(.primary.opacity(0.025))
            }
        }
        .frame(height: state.inputEditorBarHeight)
    }

    private var promptEditorArea: some View {
        ZStack(alignment: .topLeading) {
            PromptEditor(
                text: Binding(
                    get: { state.draft },
                    set: { state.draft = $0 }
                ),
                isFocused: $promptFocused,
                onHeightChange: state.setInputEditorHeight,
                onPasteImages: { providers in
                    Task { await state.addPastedImages(providers: providers) }
                },
                onSubmit: {
                    let suggestions = state.slashCommandSuggestions
                    if suggestions.isEmpty || state.draftMatchesSlashCommand {
                        Task { await state.send() }
                    } else {
                        selectSlashCommand(
                            suggestions[min(selectedSlashCommandIndex, suggestions.count - 1)]
                        )
                    }
                },
                onMoveSuggestion: { offset in
                    let suggestions = state.slashCommandSuggestions
                    guard !suggestions.isEmpty else {
                        return false
                    }
                    let nextIndex = (
                        selectedSlashCommandIndex + suggestions.count + offset
                    ) % suggestions.count
                    selectedSlashCommandIndex = nextIndex
                    slashCommandScrollRequest = SlashCommandScrollRequest(
                        commandName: suggestions[nextIndex].name
                    )
                    return true
                }
            )

            if state.draft.isEmpty {
                Text(state.conversationAnswers.isEmpty ? "问点什么" : "继续提出修改")
                    .font(.system(size: chatMessageFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 120)
        .frame(height: state.inputEditorHeight)
        .layoutPriority(1)
    }

    private var composerToolbar: some View {
        HStack(spacing: 8) {
            Button {
                chooseAttachments()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .frame(width: 30, height: 30)
            .foregroundStyle(.secondary)
            .help("添加附件")

            Menu {
                Button {
                    setOperationApprovalEnabled(true)
                } label: {
                    Label(
                        "需要审批",
                        systemImage: state.settings.operationApproval.enabled
                            ? "checkmark"
                            : "checkmark.shield"
                    )
                }
                Button {
                    setOperationApprovalEnabled(false)
                } label: {
                    Label(
                        "完全访问",
                        systemImage: state.settings.operationApproval.enabled
                            ? "exclamationmark.shield"
                            : "checkmark"
                    )
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: state.settings.operationApproval.enabled
                        ? "checkmark.shield"
                        : "exclamationmark.shield")
                    Text(state.settings.operationApproval.enabled ? "需要审批" : "完全访问")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: QuickPiTypography.controlSize, weight: .semibold))
                .padding(.horizontal, 4)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(state.settings.operationApproval.enabled ? Color.orange : Color.red)
            .disabled(
                state.hasRunningSessions
                    || state.runtimeStarting
                    || state.sessionChanging
                    || state.gitOperationRunning
            )
            .help(
                state.settings.operationApproval.enabled
                    ? "当前需要审批，点击切换访问权限"
                    : "当前为完全访问，点击切换访问权限"
            )

            Spacer(minLength: 8)

            modelPickerButton
            submitControls
        }
    }

    private func setOperationApprovalEnabled(_ enabled: Bool) {
        var configuration = state.settings.operationApproval
        guard configuration.enabled != enabled else {
            return
        }
        configuration.enabled = enabled
        do {
            try state.saveOperationApprovalSettings(configuration)
        } catch {
            state.runtimeError = error.localizedDescription
        }
    }

    private var modelPickerButton: some View {
        Button {
            modelMenuPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                if state.runtimeStarting {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(state.selectedModel.map { model in
                    state.supportsThinking
                        ? "\(model.name) · \(state.thinkingLevel.title)"
                        : model.name
                } ?? "选择模型")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .layoutPriority(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .fixedSize()
            }
            .font(.system(size: QuickPiTypography.controlSize, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(width: 160, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 160)
        .disabled(
            !state.runtimeReady
                || state.hasRunningSessions
                || state.sessionChanging
                || state.gitOperationRunning
        )
        .help(
            state.selectedModel.map {
                state.supportsThinking
                    ? "\($0.providerName) · \($0.name) · 推理强度：\(state.thinkingLevel.title)"
                    : "\($0.providerName) · \($0.name)"
            }
                ?? "选择模型"
        )
        .popover(
            isPresented: $modelMenuPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            modelMenu
        }
    }

    @ViewBuilder
    private var submitControls: some View {
        if state.isAnswering
            && !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 6) {
                Button {
                    Task { await state.send(steering: true) }
                } label: {
                    Label("插队", systemImage: "arrowshape.turn.up.right.fill")
                        .font(.system(size: QuickPiTypography.controlSize, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .frame(width: 60, height: 30)
                .foregroundStyle(.orange)
                .disabled(state.promptSubmissionRunning)
                .help("在当前工具调用结束后优先发送")

                Button {
                    Task { await state.send() }
                } label: {
                    Label("排队", systemImage: "clock")
                        .font(.system(size: QuickPiTypography.controlSize, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .frame(width: 60, height: 30)
                .foregroundStyle(Color.accentColor)
                .disabled(state.promptSubmissionRunning)
                .help("当前回答完成后发送")
            }
            .fixedSize(horizontal: true, vertical: false)
        } else {
            Button {
                if state.isAnswering {
                    Task { await state.abort() }
                } else {
                    Task { await state.send() }
                }
            } label: {
                if state.promptSubmissionRunning || state.extensionCommandRunning {
                    ProgressView()
                        .controlSize(.small)
                } else if state.isAnswering {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                }
            }
            .buttonStyle(.plain)
            .frame(width: 30, height: 30)
            .foregroundStyle(state.isAnswering ? Color.red : Color.accentColor)
            .disabled(
                !state.runtimeReady
                    || state.promptSubmissionRunning
                    || state.sessionChanging
                    || state.gitOperationRunning
                    || (!state.isAnswering
                        && (state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || state.isBusy))
            )
            .help(state.isAnswering ? "停止回答" : "发送")
        }
    }

    private func inputAttachmentView(_ attachment: PendingAttachment) -> some View {
        HStack(spacing: 7) {
            switch attachment.content {
            case let .image(data, _):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .frame(width: 34, height: 34)
                }
            case .text:
                Image(systemName: "doc.text")
                    .font(.system(size: 17))
                    .frame(width: 28, height: 34)
            }

            Text(attachment.name)
                .font(.system(size: QuickPiTypography.metadataSize))
                .lineLimit(2)
                .frame(maxWidth: 116, alignment: .leading)

            Button {
                state.removeAttachment(id: attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help("移除附件")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 5)
        .padding(.trailing, 6)
        .frame(height: 42)
        .background(
            .primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var slashCommandMenu: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.slashCommandSuggestions.enumerated()), id: \.element.name) { index, command in
                        Button {
                            selectSlashCommand(command)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("/\(command.name)")
                                        .font(.system(
                                            size: QuickPiTypography.controlSize,
                                            weight: .semibold,
                                            design: .monospaced
                                        ))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let description = command.description, !description.isEmpty {
                                        Text(description)
                                            .font(.system(size: QuickPiTypography.metadataSize))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 12)
                                Text(command.source.title)
                                    .font(.system(size: QuickPiTypography.metadataSize, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(
                                index == selectedSlashCommandIndex
                                    ? Color.accentColor.opacity(0.08)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(command.name)
                        .onHover { hovering in
                            if hovering {
                                selectedSlashCommandIndex = index
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.visible)
            .onChange(of: slashCommandScrollRequest) { _, request in
                guard let request else {
                    return
                }
                proxy.scrollTo(request.commandName, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: state.slashCommandMenuHeight)
        .overlay(alignment: .top) {
            Divider()
                .padding(.horizontal, 14)
        }
    }

    private var modelMenuHeight: CGFloat {
        guard !state.modelOptions.isEmpty else {
            return 56
        }
        return min(CGFloat(state.modelOptions.count) * 38 + 8, 240)
    }

    private var modelMenu: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                if state.modelOptions.isEmpty {
                    Text("未配置模型")
                        .font(.system(size: QuickPiTypography.metadataSize))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(state.modelOptions, id: \.selectionKey) { model in
                            Button {
                                modelMenuPresented = false
                                Task { await state.selectModel(selectionKey: model.selectionKey) }
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(model.name)
                                            .font(.system(size: QuickPiTypography.controlSize, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(model.providerName)
                                            .font(.system(size: QuickPiTypography.metadataSize))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    if model.supportsReasoning {
                                        Image(systemName: "brain")
                                            .font(.system(size: QuickPiTypography.metadataSize))
                                            .foregroundStyle(.secondary)
                                            .help("支持推理强度")
                                    }
                                    if state.settings.selectedModel == model.selection {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: QuickPiTypography.metadataSize, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
            .scrollIndicators(.visible)
            .frame(height: modelMenuHeight)

            if state.supportsThinking {
                Divider()
                HStack(spacing: 10) {
                    Label("推理强度", systemImage: "brain")
                        .font(.system(size: QuickPiTypography.metadataSize))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("推理强度", selection: Binding(
                        get: { state.thinkingLevel },
                        set: { level in
                            Task { await state.selectThinkingLevel(level) }
                        }
                    )) {
                        ForEach(state.availableThinkingLevels, id: \.self) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 104)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
            }
        }
        .frame(width: 280)
    }

    // Inserts a Pi command and leaves the cursor ready for any command arguments.
    private func selectSlashCommand(_ command: SlashCommand) {
        state.draft = "/\(command.name) "
        selectedSlashCommandIndex = 0
        promptFocused = true
    }

    private var contextBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    chooseWorkspace()
                } label: {
                    Label(
                        state.settings.workspacePath == nil ? "选择工作区…" : "更换工作区…",
                        systemImage: "folder"
                    )
                }
                if state.settings.workspacePath != nil {
                    Divider()
                    Button {
                        state.setWorkspace(nil)
                    } label: {
                        Label("返回主空间", systemImage: "house")
                    }
                }
                if let worktree = state.activeManagedWorktree {
                    Divider()
                    Label(
                        worktree.branch ?? "detached HEAD",
                        systemImage: "arrow.triangle.branch"
                    )
                    if worktree.branch == nil {
                        Button {
                            state.draft = "/branch "
                            promptFocused = true
                        } label: {
                            Label("创建分支…", systemImage: "plus")
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: state.activeManagedWorktree == nil ? "folder" : "arrow.triangle.branch")
                    Text(state.scopeTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: QuickPiTypography.topBarSize, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(width: 116, height: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 116)
            .disabled(state.hasRunningSessions || state.sessionChanging || state.gitOperationRunning)
            .help(state.scopePath)

            Button {
                sessionsPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    if state.sessionChanging {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    Text("会话记录")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: QuickPiTypography.topBarSize, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(width: 116, height: 28, alignment: .leading)
                .background(
                    .primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 116)
            .disabled(state.sessions.isEmpty || state.sessionChanging || state.gitOperationRunning)
            .help("查看会话记录")
            .popover(isPresented: $sessionsPresented, arrowEdge: .top) {
                VStack(spacing: 0) {
                    if state.sessions.isEmpty {
                        Text("暂无会话")
                            .font(.system(size: QuickPiTypography.metadataSize))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(state.sessions) { session in
                                    HStack(spacing: 4) {
                                        Button {
                                            sessionsPresented = false
                                            Task { await state.switchSession(id: session.id) }
                                        } label: {
                                            HStack(spacing: 8) {
                                                Group {
                                                    if state.isSessionRunning(id: session.id) {
                                                        ProgressView()
                                                            .controlSize(.mini)
                                                    } else if state.hasUnreadCompletion(id: session.id) {
                                                        Circle()
                                                            .fill(Color.blue)
                                                            .frame(width: 8, height: 8)
                                                    } else {
                                                        Image(systemName: "checkmark")
                                                            .opacity(session.id == state.activeSessionID ? 1 : 0)
                                                    }
                                                }
                                                .frame(width: 12, height: 12)

                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(state.title(for: session))
                                                        .lineLimit(1)
                                                    if let worktree = state.worktreeLabel(for: session) {
                                                        Label(worktree, systemImage: "arrow.triangle.branch")
                                                            .font(.system(size: QuickPiTypography.metadataSize))
                                                            .foregroundStyle(.secondary)
                                                            .lineLimit(1)
                                                    }
                                                }
                                                Spacer(minLength: 8)
                                            }
                                            .contentShape(Rectangle())
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            sessionsPresented = false
                                            sessionPendingDeletion = session
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.plain)
                                        .frame(width: 26, height: 26)
                                        .foregroundStyle(.secondary)
                                        .disabled(
                                            session.id == state.activeSessionID
                                                || state.hasRunningSessions
                                                || state.sessionChanging
                                                || state.gitOperationRunning
                                        )
                                        .help(session.id == state.activeSessionID ? "请先切换到其他会话" : "删除会话")
                                    }
                                    .padding(.leading, 10)
                                    .padding(.trailing, 6)
                                    .frame(height: 44)
                                    .help(session.cwd)
                                }
                            }
                        }
                        .scrollIndicators(.visible)
                        .frame(height: min(CGFloat(state.sessions.count) * 44, 308))
                    }

                    Divider()

                    Button(role: .destructive) {
                        sessionsPresented = false
                        confirmsDeletingSessions = true
                    } label: {
                        Label("删除全部会话…", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .disabled(state.hasRunningSessions || state.gitOperationRunning)
                }
                .frame(width: 260)
            }

            if let planStatus = state.extensionStatuses.first(where: {
                $0.key == ExtensionStatus.planModeKey
            }) {
                Button {
                    planPresented.toggle()
                } label: {
                    HStack(spacing: 5) {
                        PlanStatusTextView(status: planStatus)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: QuickPiTypography.topBarSize, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(width: 104, height: 28, alignment: .leading)
                    .background(
                        .primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 104)
                .help("查看 Plan 进度")
                .popover(isPresented: $planPresented, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Label("Plan 进度", systemImage: "list.bullet.clipboard")
                            Spacer()
                            PlanStatusTextView(status: planStatus)
                        }
                        .font(.system(size: QuickPiTypography.metadataSize, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 40)

                        Divider()

                        if let planWidget = state.extensionWidgets.first(where: {
                            $0.key == ExtensionWidget.planModeKey
                        }) {
                            ScrollView(.vertical) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(planWidget.lines.enumerated()), id: \.offset) { index, line in
                                        PlanProgressLineView(
                                            source: line,
                                            richText: planWidget.richLines.flatMap {
                                                $0.indices.contains(index) ? $0[index] : nil
                                            },
                                            baseURL: state.activeWorkingDirectoryURL
                                        )
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                    }
                                }
                                .padding(12)
                            }
                            .scrollIndicators(.visible)
                            .frame(height: min(CGFloat(planWidget.lines.count) * 36 + 24, 360))
                        } else {
                            Text("尚无执行进度")
                                .font(.system(size: QuickPiTypography.metadataSize))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                    }
                    .frame(width: 360)
                }
            }

            let extensionStatuses = state.extensionStatuses.filter {
                $0.key != ExtensionStatus.planModeKey
            }
            if !extensionStatuses.isEmpty {
                let statusText = extensionStatuses.map(\.text).joined(separator: " · ")
                Label(statusText, systemImage: "puzzlepiece.extension")
                    .font(.system(size: QuickPiTypography.topBarSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                    .help(statusText)
            }

            if showSystemStatus {
                SystemStatusView()
            }

            Button {
                presentGitActions()
            } label: {
                HStack(spacing: 5) {
                    if state.gitOperationRunning || state.activeGitStatusLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    Text(
                        state.activeGitStatus.map { $0.branch ?? "detached HEAD" }
                            ?? (state.activeGitStatusError == nil ? "Git" : "非 Git")
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: QuickPiTypography.topBarSize, weight: .medium))
                .padding(.horizontal, 8)
                .frame(width: 104, height: 28, alignment: .leading)
                .background(
                    .primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 104)
            .foregroundStyle(.secondary)
            .disabled(state.activeSessionID == nil || state.runtimeStarting || state.sessionChanging)
            .help(state.activeGitStatusError ?? "Git 操作")

            Spacer(minLength: 0)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard state.showsResultPanel, state.slashCommandMenuHeight == 0 else {
                        return
                    }
                    togglePanelZoom()
                }

            if state.hasResultPanelContent {
                Button {
                    state.toggleResultPanel()
                } label: {
                    Image(systemName: state.showsResultPanel ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 28)
                .foregroundStyle(.secondary)
                .help(state.showsResultPanel ? "收起结果" : "展开结果")
            }

            Button {
                Task { await state.createSession(usesIndependentWorktree: false) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("新建会话")
                }
                .font(.system(size: QuickPiTypography.topBarSize, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(width: 96, height: 30)
                .background(
                    .primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 96, height: 30)
            .disabled(
                state.activeSessionID == nil
                    || state.runtimeStarting
                    || state.sessionChanging
                    || state.gitOperationRunning
            )
            .help("在当前目录新建会话")

            Button {
                state.presentSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .frame(width: 30, height: 28)
            .foregroundStyle(.secondary)
            .help("设置")
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
    }

    private var resultPanel: some View {
        let conversationAnswers = state.conversationAnswers
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView {
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(
                                    Array(conversationAnswers.enumerated()),
                                    id: \.element.id
                                ) { index, answer in
                                    let toolGroups = toolActivityGroupsByCallID(in: answer.sections)
                                    let hasRunningTool = answer.sections.contains { section in
                                        if case .tool(let tool) = section.content {
                                            return tool.status == .running
                                        }
                                        return false
                                    }

                                    let answerText = answer.answerText

                                    VStack(alignment: .leading, spacing: 16) {
                                        if let question = answer.question {
                                            questionView(
                                                question,
                                                answerID: answer.id,
                                                entryID: answer.cloneEntryId
                                            )
                                        }

                                        VStack(alignment: .leading, spacing: 12) {
                                            ForEach(answer.sections) { section in
                                                AnswerSectionView(
                                                    section: section,
                                                    toolsByCallID: toolGroups,
                                                    baseURL: state.activeWorkingDirectoryURL,
                                                    openFile: state.openLocalFile,
                                                    respondToApproval: state.respondToOperationApproval
                                                )
                                            }

                                            if answer.id == state.answer?.id && state.isAnswering {
                                                HStack(spacing: 8) {
                                                    ProgressView()
                                                        .controlSize(.small)
                                                    Text(
                                                        answer.status == .waiting
                                                            ? "正在连接模型"
                                                            : hasRunningTool
                                                                ? "正在调用工具"
                                                                : "正在思考"
                                                    )
                                                    .font(.system(size: QuickPiTypography.supportingSize))
                                                    .foregroundStyle(.secondary)
                                                }
                                            }

                                            if let retry = answer.retryMessage {
                                                Label(retry, systemImage: "arrow.clockwise")
                                                    .font(.system(size: QuickPiTypography.metadataSize))
                                                    .foregroundStyle(.orange)
                                                    .textSelection(.enabled)
                                            }
                                            if let error = answer.error {
                                                Label(error, systemImage: "exclamationmark.circle")
                                                    .font(.system(size: QuickPiTypography.metadataSize))
                                                    .foregroundStyle(.red)
                                                    .textSelection(.enabled)
                                            } else if answer.status == .stopped {
                                                Label("已停止", systemImage: "stop.circle")
                                                    .font(.system(size: QuickPiTypography.supportingSize))
                                                    .foregroundStyle(.secondary)
                                            }

                                            if answer.model != nil
                                                || answer.usage.totalTokens > 0
                                                || answer.stopReason == "length"
                                                || answer.cloneEntryId != nil
                                                || !answerText.isEmpty {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    answerMetadata(answer)

                                                    if answer.cloneEntryId != nil || !answerText.isEmpty {
                                                        HStack(spacing: 10) {
                                                            if let entryId = answer.cloneEntryId {
                                                                Button {
                                                                    Task {
                                                                        await state.cloneSession(from: entryId)
                                                                        promptFocused = true
                                                                    }
                                                                } label: {
                                                                    Image(systemName: "arrow.triangle.branch")
                                                                        .font(.system(size: 12, weight: .medium))
                                                                }
                                                                .buttonStyle(.plain)
                                                                .frame(width: 24, height: 24)
                                                                .disabled(
                                                                    !state.runtimeReady
                                                                        || state.isBusy
                                                                        || state.sessionChanging
                                                                )
                                                                .help("从此回复克隆为新会话")
                                                            }

                                                            if !answerText.isEmpty {
                                                                Button {
                                                                    copy(answerText)
                                                                } label: {
                                                                    Image(systemName: "doc.on.doc")
                                                                        .font(.system(size: 12, weight: .medium))
                                                                }
                                                                .buttonStyle(.plain)
                                                                .frame(width: 24, height: 24)
                                                                .help("复制此回复")
                                                            }

                                                            Spacer(minLength: 8)
                                                        }
                                                        .foregroundStyle(.secondary)
                                                    }
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.top, 2)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        if index < conversationAnswers.count - 1 {
                                            Divider()
                                                .opacity(0.7)
                                                .padding(.top, 2)
                                        }
                                    }
                                    .padding(.top, 18)
                                    .padding(
                                        .bottom,
                                        index == conversationAnswers.count - 1 ? 18 : 0
                                    )
                                    .id(answer.id)
                                    .onAppear {
                                        guard answer.id == conversationAnswers.last?.id else {
                                            return
                                        }
                                        resultScrollTracker.isAtBottom = true
                                        resultScrollTracker.followsPendingAnswerChange = false
                                        proxy.scrollTo("result-bottom", anchor: .bottom)
                                    }
                                }

                                ForEach(state.queuedMessages) { message in
                                    queuedMessageView(message)
                                        .padding(.top, 14)
                                }

                                if let runtimeError = state.runtimeError {
                                    Label(runtimeError, systemImage: "exclamationmark.triangle")
                                        .font(.system(size: QuickPiTypography.metadataSize))
                                        .foregroundStyle(.red)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.horizontal, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Color.clear
                                .frame(height: 1)
                                .id("result-bottom")
                                .background {
                                    GeometryReader { bottom in
                                        Color.clear.preference(
                                            key: ResultBottomPreferenceKey.self,
                                            value: bottom.frame(in: .named("result-scroll")).maxY
                                        )
                                    }
                                }
                        }
                    }
                    .coordinateSpace(name: "result-scroll")
                    .onPreferenceChange(ResultBottomPreferenceKey.self) { bottom in
                        resultScrollTracker.isAtBottom = bottom <= viewport.size.height + 1
                    }
                    .onReceive(state.objectWillChange) { _ in
                        // Capture the position before published content moves the bottom marker.
                        resultScrollTracker.followsPendingAnswerChange = resultScrollTracker.isAtBottom
                    }
                    .onChange(of: state.answer) { _, _ in
                        let shouldFollow = resultScrollTracker.followsPendingAnswerChange
                        resultScrollTracker.followsPendingAnswerChange = false
                        guard shouldFollow else {
                            return
                        }
                        Task { @MainActor in
                            // Scroll after Markdown has adopted the newly published content size.
                            await Task.yield()
                            proxy.scrollTo("result-bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: state.queuedMessages) { _, _ in
                        let shouldFollow = resultScrollTracker.followsPendingAnswerChange
                        resultScrollTracker.followsPendingAnswerChange = false
                        guard shouldFollow else {
                            return
                        }
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo("result-bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.quickPiWindowBackground)
    }

    // Keeps one pending message editable until the extension hands it to Pi for delivery.
    private func queuedMessageView(_ message: QueuedUserMessage) -> some View {
        let isEditing = editingQueuedMessageID == message.id
        let editLineCount = max(
            editedQueuedMessage.split(separator: "\n", omittingEmptySubsequences: false).count,
            2
        )
        let editHeight = min(max(CGFloat(editLineCount) * 22 + 18, 68), 170)

        return HStack(alignment: .top) {
            Spacer(minLength: 120)

            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    if isEditing {
                        TextEditor(text: $editedQueuedMessage)
                            .font(.system(size: chatMessageFontSize))
                            .lineSpacing(3)
                            .scrollContentBackground(.hidden)
                            .focused($editedQueuedMessageFocused)
                            .frame(height: editHeight)
                    } else {
                        Text(message.text)
                            .font(.system(size: chatMessageFontSize))
                            .lineSpacing(3)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                            .help(message.text)
                    }
                    if !message.attachments.isEmpty {
                        messageAttachmentsView(message.attachments)
                    } else if !message.attachmentNames.isEmpty {
                        Label(message.attachmentNames.joined(separator: " · "), systemImage: "paperclip")
                            .font(.system(size: QuickPiTypography.metadataSize))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isEditing ? Color.accentColor.opacity(0.45) : Color.clear,
                            lineWidth: isEditing ? 1.5 : 0
                        )
                }

                HStack(spacing: 10) {
                    Label(
                        message.isSteering ? "将插队" : "已排队",
                        systemImage: message.isSteering
                            ? "arrowshape.turn.up.right.fill"
                            : "clock"
                    )
                    .font(.system(size: QuickPiTypography.metadataSize))
                    .foregroundStyle(message.isSteering ? Color.orange : Color.secondary)

                    if isEditing {
                        Button {
                            editingQueuedMessageID = nil
                            editedQueuedMessage = ""
                            editedQueuedMessageFocused = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .help("取消编辑")

                        Button {
                            let replacement = editedQueuedMessage
                            Task {
                                if await state.editQueuedMessage(
                                    id: message.id,
                                    replacement: replacement
                                ) {
                                    editingQueuedMessageID = nil
                                    editedQueuedMessage = ""
                                    editedQueuedMessageFocused = false
                                }
                            }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .disabled(
                            editedQueuedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || state.promptSubmissionRunning
                        )
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("保存队列消息")
                    } else if message.editable {
                        Button {
                            editingAnswerID = nil
                            editedQuestion = ""
                            editedQuestionFocused = false
                            editingQueuedMessageID = message.id
                            editedQueuedMessage = message.text
                            Task { @MainActor in
                                editedQueuedMessageFocused = true
                            }
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .disabled(state.promptSubmissionRunning || editingQueuedMessageID != nil)
                        .help("编辑队列消息")

                        Button {
                            Task { await state.cancelQueuedMessage(id: message.id) }
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .disabled(state.promptSubmissionRunning)
                        .help("取消发送")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func messageAttachmentsView(_ attachments: [MessageAttachment]) -> some View {
        HStack(alignment: .top, spacing: 9) {
            ForEach(attachments) { attachment in
                VStack(alignment: .leading, spacing: 4) {
                    if attachment.kind == .image,
                       let data = attachment.data,
                       let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.medium)
                            .scaledToFill()
                            .frame(width: 72, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: attachment.kind == .image ? "photo" : "doc.text")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .frame(width: 72, height: 64)
                            .background(.primary.opacity(0.045))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Text(attachment.name)
                        .font(.system(size: QuickPiTypography.metadataSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(width: 72, alignment: .leading)
                }
                .help(attachment.name)
            }
        }
    }

    // Edits a persisted question in place before Pi replaces the active branch from that turn.
    private func questionView(
        _ question: SubmittedQuestion,
        answerID: UUID,
        entryID: String?
    ) -> some View {
        let isEditing = editingAnswerID == answerID
        let editLineCount = max(editedQuestion.split(separator: "\n", omittingEmptySubsequences: false).count, 2)
        let editHeight = min(max(CGFloat(editLineCount) * 22 + 18, 68), 170)

        return HStack(alignment: .top) {
            Spacer(minLength: 120)

            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    if isEditing {
                        TextEditor(text: $editedQuestion)
                            .font(.system(size: chatMessageFontSize))
                            .lineSpacing(3)
                            .scrollContentBackground(.hidden)
                            .focused($editedQuestionFocused)
                            .frame(height: editHeight)
                    } else {
                        Text(question.text)
                            .font(.system(size: chatMessageFontSize))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    if !question.attachments.isEmpty {
                        messageAttachmentsView(question.attachments)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    Color.accentColor.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isEditing
                                ? Color.accentColor.opacity(0.45)
                                : Color.accentColor.opacity(0.12),
                            lineWidth: isEditing ? 1.5 : 1
                        )
                }

                HStack(spacing: 10) {
                    if isEditing, let entryID {
                        Button {
                            editingAnswerID = nil
                            editedQuestion = ""
                            editedQuestionFocused = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .frame(width: 24, height: 24)
                        .help("取消编辑")

                        Button {
                            let replacement = editedQuestion
                            Task {
                                if await state.editMessage(entryId: entryID, replacement: replacement) {
                                    editingAnswerID = nil
                                    editedQuestion = ""
                                    editedQuestionFocused = false
                                }
                            }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .frame(width: 24, height: 24)
                        .disabled(
                            editedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || state.sessionChanging
                        )
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("提交编辑并重新回答")
                    } else {
                        Button {
                            copy(question.text)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .frame(width: 24, height: 24)
                        .help("复制问题")

                        if entryID != nil {
                            Button {
                                editingAnswerID = answerID
                                editedQuestion = question.text
                                Task { @MainActor in
                                    editedQuestionFocused = true
                                }
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .frame(width: 24, height: 24)
                            .disabled(
                                !state.runtimeReady
                                    || state.isBusy
                                    || state.sessionChanging
                                    || editingAnswerID != nil
                                    || editingQueuedMessageID != nil
                            )
                            .help("编辑此问题并重新回答")
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // Keeps model and total tokens together, followed by detailed usage and exceptional metadata.
    @ViewBuilder
    private func answerMetadata(_ answer: AnswerSession) -> some View {
        if answer.model != nil || answer.usage.totalTokens > 0 || answer.stopReason == "length" {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if let model = answer.model {
                        Text(model)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                    }
                    if answer.usage.totalTokens > 0 {
                        Text("总 Token \(answer.usage.totalTokens.formatted())")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(2)
                    }
                    if answer.usage.cost > 0 {
                        Text(answer.usage.cost, format: .currency(code: "USD"))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if answer.stopReason == "length" {
                        Label("达到输出上限", systemImage: "exclamationmark.triangle")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(.orange)
                    }
                }

                if answer.usage.totalTokens > 0 {
                    Text(
                        "输入 \(answer.usage.input.formatted())"
                            + " · 输出 \(answer.usage.output.formatted())"
                            + " · 缓存读取 \(answer.usage.cacheRead.formatted())"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: QuickPiTypography.metadataSize))
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
    }

    // Opens the native picker and passes only the user's explicit selections to the loader.
    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .pdf, .plainText, .data]
        panel.directoryURL = state.activeWorkingDirectoryURL
        guard panel.runModal() == .OK else {
            return
        }
        Task { await state.addAttachments(urls: panel.urls) }
    }

    // Opens the native directory picker at the current project root and persists one selection.
    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = state.settings.workspaceURL
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        state.setWorkspace(url)
    }

    // Replaces the general pasteboard with the selected answer or code content.
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private enum GitAction: String, CaseIterable, Identifiable {
    case commit
    case push
    case createBranch
    case switchBranch
    case diff
    case log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commit: "提交"
        case .push: "推送"
        case .createBranch: "新建分支"
        case .switchBranch: "切换分支"
        case .diff: "Diff"
        case .log: "Log"
        }
    }

    var systemImage: String {
        switch self {
        case .commit: "checkmark.circle"
        case .push: "icloud.and.arrow.up"
        case .createBranch: "plus"
        case .switchBranch: "arrow.left.arrow.right"
        case .diff: "doc.text.magnifyingglass"
        case .log: "clock.arrow.circlepath"
        }
    }
}

private enum GitButtonProminence: Equatable {
    case standard
    case primary
}

private struct GitButtonStyle: ButtonStyle {
    var prominence = GitButtonProminence.standard
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPrimary = prominence == .primary
        configuration.label
            .font(.system(size: QuickPiTypography.settingsSize, weight: .medium))
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(
                isPrimary
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isPrimary ? Color.clear : Color.primary.opacity(0.14),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct GitIconButtonStyle: ButtonStyle {
    var tint = Color.secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
    }
}

struct GitActionsView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAction = GitAction.commit
    @State private var commitMessage = ""
    @State private var includesUnstaged = true
    @State private var newBranchName = ""
    @State private var localBranches: [GitLocalBranch] = []
    @State private var diffSnapshot: GitDiffSnapshot?
    @State private var logEntries: [GitLogEntry] = []
    @State private var contentLoading = false
    @State private var contentGeneration = 0
    @State private var feedback: String?
    @State private var feedbackIsError = false

    private var operationDisabled: Bool {
        state.activeGitStatus == nil
            || state.gitOperationRunning
            || state.hasRunningSessions
            || state.sessionChanging
    }

    private var canCommit: Bool {
        guard let status = state.activeGitStatus else {
            return false
        }
        let hasCommittableChanges = includesUnstaged
            ? status.hasChanges
            : status.hasStagedChanges
        return hasCommittableChanges && !operationDisabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            gitHeader
            Divider()
            gitActionTabs
            Divider()

            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            gitFooter
        }
        .buttonStyle(GitButtonStyle())
        .font(.system(size: QuickPiTypography.settingsSize))
        .frame(width: 760, height: 540)
        .background(Color.quickPiWindowBackground)
        .interactiveDismissDisabled(state.gitOperationRunning)
        .task(id: "\(state.activeSessionID ?? "")\0\(state.scopePath)") {
            feedback = nil
            selectedAction = .commit
            await refreshStatus()
        }
        .task(id: "\(state.activeSessionID ?? "")\0\(state.scopePath)\0\(selectedAction.rawValue)") {
            await loadContent(for: selectedAction)
        }
    }

    private var gitHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.activeWorkingDirectoryURL.lastPathComponent)
                    .font(.system(size: QuickPiTypography.titleSize, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(state.activeGitStatus.map { $0.branch ?? "detached HEAD" } ?? "Git")
                    if let upstream = state.activeGitStatus?.upstream {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text(upstream)
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            if let status = state.activeGitStatus, status.hasChanges {
                HStack(spacing: 10) {
                    Text("+\(status.additions)")
                        .foregroundStyle(.green)
                    Text("-\(status.deletions)")
                        .foregroundStyle(.red)
                }
                .monospacedDigit()
            }

            Button {
                feedback = nil
                Task {
                    await refreshStatus()
                    await loadContent(for: selectedAction)
                }
            } label: {
                if state.activeGitStatusLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(GitIconButtonStyle())
            .disabled(state.activeGitStatusLoading || state.gitOperationRunning)
            .help("刷新 Git 状态")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(GitIconButtonStyle())
            .disabled(state.gitOperationRunning)
            .help("关闭 Git")
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }

    private var gitActionTabs: some View {
        HStack(spacing: 0) {
            ForEach(GitAction.allCases) { action in
                Button {
                    selectedAction = action
                    feedback = nil
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .font(.system(size: QuickPiTypography.settingsSize, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(action == selectedAction ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(action == selectedAction ? Color.accentColor : Color.secondary)
                .background(action == selectedAction ? Color.accentColor.opacity(0.06) : Color.clear)
                .disabled(state.activeGitStatus == nil)
            }
        }
        .frame(height: 44)
    }

    private var gitFooter: some View {
        HStack(spacing: 8) {
            if let feedback {
                Image(systemName: feedbackIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(feedbackIsError ? Color.red : Color.green)
                Text(feedback)
                    .foregroundStyle(feedbackIsError ? Color.red : Color.secondary)
                    .help(feedback)
            } else if let status = state.activeGitStatus {
                Image(systemName: status.hasChanges ? "circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: status.hasChanges ? 7 : 14))
                    .foregroundStyle(status.hasChanges ? Color.orange : Color.green)
                Text(status.hasChanges ? "\(status.changedFileCount) 个改动文件" : "工作树已同步")
                    .foregroundStyle(.secondary)
            } else if state.activeGitStatusLoading {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取 Git 状态")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(state.activeGitStatusError ?? "Git 状态不可用")
                    .foregroundStyle(.red)
                    .help(state.activeGitStatusError ?? "Git 状态不可用")
            }
            Spacer(minLength: 0)
        }
        .lineLimit(2)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedAction {
        case .commit:
            commitContent
        case .push:
            pushContent
        case .createBranch:
            createBranchContent
        case .switchBranch:
            switchBranchContent
        case .diff:
            diffContent
        case .log:
            logContent
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: QuickPiTypography.settingsSize, weight: .semibold))
    }

    private func gitDetailRow(_ title: String, value: String) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }

    private var commitContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("提交更改", systemImage: "checkmark.circle")

            TextField("提交信息（留空时由当前模型生成）", text: $commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(10)
                .background(
                    Color.quickPiControlBackground,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                }
                .disabled(state.gitOperationRunning)

            Toggle("包含未暂存的更改", isOn: $includesUnstaged)
                .toggleStyle(.checkbox)
                .disabled(state.gitOperationRunning)

            HStack(spacing: 8) {
                Button {
                    Task { await commit(pushAfterCommit: false) }
                } label: {
                    Label("提交", systemImage: "checkmark.circle")
                }
                .buttonStyle(GitButtonStyle(prominence: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCommit)

                Button {
                    Task { await commit(pushAfterCommit: true) }
                } label: {
                    Label("提交并推送", systemImage: "arrow.up.circle")
                }
                .disabled(!canCommit || state.activeGitStatus?.canPush != true)
            }

            if let status = state.activeGitStatus {
                Label(
                    status.hasStagedChanges ? "暂存区有待提交更改" : "暂存区没有待提交更改",
                    systemImage: status.hasStagedChanges ? "tray.full" : "tray"
                )
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var pushContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("推送分支", systemImage: "icloud.and.arrow.up")

            if let status = state.activeGitStatus {
                VStack(spacing: 0) {
                    gitDetailRow("当前分支", value: status.branch ?? "detached HEAD")
                    Divider()
                    gitDetailRow("上游分支", value: status.upstream ?? "未设置")
                }
            }

            Button {
                Task { await push() }
            } label: {
                Label("推送", systemImage: "icloud.and.arrow.up")
            }
            .buttonStyle(GitButtonStyle(prominence: .primary))
            .disabled(operationDisabled || state.activeGitStatus?.canPush != true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var createBranchContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("新建分支", systemImage: "plus")

            TextField("分支名称", text: $newBranchName)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(
                    Color.quickPiControlBackground,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                }
                .disabled(state.gitOperationRunning)

            Button {
                Task { await createBranch() }
            } label: {
                Label("创建并切换", systemImage: "arrow.triangle.branch")
            }
            .buttonStyle(GitButtonStyle(prominence: .primary))
            .disabled(
                operationDisabled
                    || newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var switchBranchContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("切换本地分支", systemImage: "arrow.left.arrow.right")

            if contentLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if localBranches.isEmpty {
                Text("没有本地分支")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(localBranches) { branch in
                            Button {
                                Task { await switchBranch(to: branch) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(
                                        systemName: branch.isCurrent
                                            ? "checkmark.circle.fill"
                                            : "arrow.triangle.branch"
                                    )
                                    .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
                                    .frame(width: 18)

                                    Text(branch.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Spacer(minLength: 8)

                                    if branch.isCurrent {
                                        Text("当前")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                                .contentShape(Rectangle())
                                .background(branch.isCurrent ? Color.accentColor.opacity(0.06) : Color.clear)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.08))
                                        .frame(height: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(branch.isCurrent || operationDisabled)
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var diffContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("工作树 Diff", systemImage: "doc.text.magnifyingglass")
                Spacer()
                Button {
                    copyDiff()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(GitIconButtonStyle())
                .disabled(diffSnapshot?.text.isEmpty != false)
                .help("复制 Diff")
            }

            if contentLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diffSnapshot {
                if diffSnapshot.text.isEmpty {
                    Text("没有已跟踪文件差异")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(diffSnapshot.text)
                            .font(.system(size: QuickPiTypography.settingsSize, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(10)
                    }
                    .scrollIndicators(.visible)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: diffSnapshot.untrackedFiles.isEmpty ? .infinity : 180
                    )
                    .background(
                        Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    }
                }

                if diffSnapshot.isTruncated {
                    Text("Diff 输出过大，仅显示前 200,000 个字符")
                        .foregroundStyle(.secondary)
                }

                if !diffSnapshot.untrackedFiles.isEmpty {
                    Text("未跟踪文件（\(diffSnapshot.untrackedFileCount)）")
                        .font(.system(size: QuickPiTypography.settingsSize, weight: .semibold))

                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(diffSnapshot.untrackedFiles, id: \.self) { path in
                                Text(path)
                                    .font(.system(size: QuickPiTypography.settingsSize, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 70)

                    if diffSnapshot.untrackedFileCount > diffSnapshot.untrackedFiles.count {
                        Text("仅显示前 \(diffSnapshot.untrackedFiles.count) 个未跟踪文件")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var logContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("最近提交", systemImage: "clock.arrow.circlepath")

            if contentLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if logEntries.isEmpty {
                Text("还没有提交记录")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(logEntries) { entry in
                            HStack(alignment: .top, spacing: 12) {
                                Text(entry.shortCommitID)
                                    .font(.system(size: QuickPiTypography.settingsSize, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                                    .textSelection(.enabled)
                                    .frame(width: 84, alignment: .leading)

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.subject)
                                        .lineLimit(2)
                                        .textSelection(.enabled)

                                    HStack(spacing: 12) {
                                        Text(entry.author)
                                        Spacer(minLength: 8)
                                        Text(entry.date)
                                            .monospacedDigit()
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.08))
                                    .frame(height: 1)
                            }
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    // Reloads repository status and exposes the exact Git error in the fixed footer.
    private func refreshStatus() async {
        await state.refreshGitStatus()
        if let error = state.activeGitStatusError {
            feedback = error
            feedbackIsError = true
        }
    }

    // Loads only the selected read-only Git view and ignores results from an obsolete selection.
    private func loadContent(for action: GitAction) async {
        guard action == .switchBranch || action == .diff || action == .log,
              state.activeGitStatus != nil else {
            contentLoading = false
            return
        }
        contentGeneration &+= 1
        let generation = contentGeneration
        let workspacePath = state.activeWorkingDirectoryURL.path
        contentLoading = true
        do {
            switch action {
            case .switchBranch:
                let branches = try await state.gitLocalBranches()
                guard generation == contentGeneration,
                      selectedAction == action,
                      workspacePath == state.activeWorkingDirectoryURL.path else {
                    return
                }
                localBranches = branches
            case .diff:
                let snapshot = try await state.gitDiff()
                guard generation == contentGeneration,
                      selectedAction == action,
                      workspacePath == state.activeWorkingDirectoryURL.path else {
                    return
                }
                diffSnapshot = snapshot
            case .log:
                let entries = try await state.gitLog()
                guard generation == contentGeneration,
                      selectedAction == action,
                      workspacePath == state.activeWorkingDirectoryURL.path else {
                    return
                }
                logEntries = entries
            case .commit, .push, .createBranch:
                return
            }
        } catch {
            guard generation == contentGeneration,
                  selectedAction == action,
                  workspacePath == state.activeWorkingDirectoryURL.path else {
                return
            }
            feedback = error.localizedDescription
            feedbackIsError = true
        }
        guard generation == contentGeneration else {
            return
        }
        contentLoading = false
    }

    // Executes commit or commit-and-push and preserves partial-success errors from AppState.
    private func commit(pushAfterCommit: Bool) async {
        do {
            let message = try await state.commitGitChanges(
                message: commitMessage,
                includingUnstaged: includesUnstaged,
                pushAfterCommit: pushAfterCommit
            )
            commitMessage = ""
            feedback = message
            feedbackIsError = false
        } catch {
            await state.refreshGitStatus()
            feedback = error.localizedDescription
            feedbackIsError = true
        }
    }

    // Pushes the current branch and reports the exact remote or upstream failure.
    private func push() async {
        do {
            feedback = try await state.pushGitBranch()
            feedbackIsError = false
        } catch {
            await state.refreshGitStatus()
            feedback = error.localizedDescription
            feedbackIsError = true
        }
    }

    // Creates a validated branch through AppState's Git write-operation lock.
    private func createBranch() async {
        do {
            feedback = try await state.createGitBranch(named: newBranchName)
            feedbackIsError = false
            newBranchName = ""
        } catch {
            await state.refreshGitStatus()
            feedback = error.localizedDescription
            feedbackIsError = true
        }
    }

    // Switches to one branch returned by Git and reloads the local branch list.
    private func switchBranch(to branch: GitLocalBranch) async {
        do {
            feedback = try await state.switchGitBranch(named: branch.name)
            feedbackIsError = false
            await loadContent(for: .switchBranch)
        } catch {
            await state.refreshGitStatus()
            feedback = error.localizedDescription
            feedbackIsError = true
        }
    }

    // Copies the currently displayed bounded Diff text to the macOS pasteboard.
    private func copyDiff() {
        guard let text = diffSnapshot?.text, !text.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct SystemStatusSnapshot {
    let cpuUsage: Double?
    let memoryUsage: Double
    let usedMemory: UInt64
    let totalMemory: UInt64
    let appMemory: UInt64
    let wiredMemory: UInt64
    let compressedMemory: UInt64
    let availableMemory: UInt64
    let swapMemory: UInt64
    let storageUsage: Double
    let usedStorage: UInt64
    let totalStorage: UInt64
    let networkInterface: String?
    let networkAddress: String?
    let downloadBytesPerSecond: Double?
    let uploadBytesPerSecond: Double?
    let uptime: TimeInterval
}

private struct HostCPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

private struct NetworkSample {
    let interfaceName: String
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let uptime: TimeInterval
}

@MainActor
private final class SystemStatusMonitor: ObservableObject {
    @Published private(set) var snapshot: SystemStatusSnapshot?
    @Published private(set) var errorMessage: String?
    private var previousCPUTicks: HostCPUTicks?
    private var previousNetworkSample: NetworkSample?

    // Samples host-wide CPU, memory, startup-volume, and primary-interface usage.
    func refresh() {
        var cpuInfo = host_cpu_load_info_data_t()
        var cpuInfoCount = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let cpuResult = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuInfoCount)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuInfoCount)
            }
        }
        guard cpuResult == KERN_SUCCESS else {
            snapshot = nil
            errorMessage = "无法读取 CPU 状态（\(cpuResult)）"
            return
        }

        let currentCPUTicks = HostCPUTicks(
            user: cpuInfo.cpu_ticks.0,
            system: cpuInfo.cpu_ticks.1,
            idle: cpuInfo.cpu_ticks.2,
            nice: cpuInfo.cpu_ticks.3
        )
        let cpuUsage: Double?
        if let previousCPUTicks {
            let userDelta = UInt64(currentCPUTicks.user &- previousCPUTicks.user)
            let systemDelta = UInt64(currentCPUTicks.system &- previousCPUTicks.system)
            let idleDelta = UInt64(currentCPUTicks.idle &- previousCPUTicks.idle)
            let niceDelta = UInt64(currentCPUTicks.nice &- previousCPUTicks.nice)
            let totalDelta = userDelta + systemDelta + idleDelta + niceDelta
            guard totalDelta > 0 else {
                snapshot = nil
                errorMessage = "CPU 计数器未产生新数据"
                return
            }
            cpuUsage = Double(userDelta + systemDelta + niceDelta) / Double(totalDelta)
        } else {
            cpuUsage = nil
        }

        var memoryInfo = vm_statistics64_data_t()
        var memoryInfoCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let memoryResult = withUnsafeMutablePointer(to: &memoryInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(memoryInfoCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &memoryInfoCount)
            }
        }
        guard memoryResult == KERN_SUCCESS else {
            snapshot = nil
            errorMessage = "无法读取内存状态（\(memoryResult)）"
            return
        }
        guard memoryInfo.purgeable_count <= memoryInfo.internal_page_count else {
            snapshot = nil
            errorMessage = "内存统计数据不一致"
            return
        }

        // Used memory is anonymous non-purgeable memory plus wired and compressed pages.
        let usedPages = UInt64(memoryInfo.internal_page_count - memoryInfo.purgeable_count)
            + UInt64(memoryInfo.wire_count)
            + UInt64(memoryInfo.compressor_page_count)
        let memoryProduct = usedPages.multipliedReportingOverflow(by: UInt64(vm_kernel_page_size))
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        guard !memoryProduct.overflow, memoryProduct.partialValue <= totalMemory else {
            snapshot = nil
            errorMessage = "内存统计数据超出物理内存"
            return
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let appMemory = UInt64(memoryInfo.internal_page_count - memoryInfo.purgeable_count) * pageSize
        let wiredMemory = UInt64(memoryInfo.wire_count) * pageSize
        let compressedMemory = UInt64(memoryInfo.compressor_page_count) * pageSize
        let availableMemory = totalMemory - memoryProduct.partialValue

        var swapUsage = xsw_usage()
        var swapUsageSize = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &swapUsage, &swapUsageSize, nil, 0) == 0 else {
            snapshot = nil
            errorMessage = "无法读取交换空间：\(String(cString: strerror(errno)))"
            return
        }

        let ipv4Key = SCDynamicStoreKeyCreateNetworkGlobalEntity(
            nil,
            kSCDynamicStoreDomainState,
            kSCEntNetIPv4
        )
        let ipv6Key = SCDynamicStoreKeyCreateNetworkGlobalEntity(
            nil,
            kSCDynamicStoreDomainState,
            kSCEntNetIPv6
        )
        let primaryInterfaceKey = kSCDynamicStorePropNetPrimaryInterface as String
        var networkInterface: String?
        var networkAddressFamily: Int32?

        let ipv4State = SCDynamicStoreCopyValue(nil, ipv4Key)
        if let ipv4State {
            guard let state = ipv4State as? [String: Any],
                  let primaryInterface = state[primaryInterfaceKey] as? String else {
                snapshot = nil
                errorMessage = "IPv4 网络状态数据不一致"
                return
            }
            networkInterface = primaryInterface
            networkAddressFamily = AF_INET
        } else {
            let ipv4Error = SCError()
            guard ipv4Error == kSCStatusNoKey else {
                snapshot = nil
                errorMessage = "无法读取 IPv4 网络状态：\(String(cString: SCErrorString(ipv4Error)))"
                return
            }

            let ipv6State = SCDynamicStoreCopyValue(nil, ipv6Key)
            if let ipv6State {
                guard let state = ipv6State as? [String: Any],
                      let primaryInterface = state[primaryInterfaceKey] as? String else {
                    snapshot = nil
                    errorMessage = "IPv6 网络状态数据不一致"
                    return
                }
                networkInterface = primaryInterface
                networkAddressFamily = AF_INET6
            } else {
                let ipv6Error = SCError()
                guard ipv6Error == kSCStatusNoKey else {
                    snapshot = nil
                    errorMessage = "无法读取 IPv6 网络状态：\(String(cString: SCErrorString(ipv6Error)))"
                    return
                }
            }
        }

        var networkAddress: String?
        var downloadBytesPerSecond: Double?
        var uploadBytesPerSecond: Double?
        let currentUptime = ProcessInfo.processInfo.systemUptime

        if let networkInterface, let networkAddressFamily {
            var interfaceAddresses: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&interfaceAddresses) == 0, let firstAddress = interfaceAddresses else {
                snapshot = nil
                errorMessage = "无法读取网络地址：\(String(cString: strerror(errno)))"
                return
            }
            defer { freeifaddrs(firstAddress) }

            var currentAddress: UnsafeMutablePointer<ifaddrs>? = firstAddress
            while let addressEntry = currentAddress {
                let address = addressEntry.pointee
                currentAddress = address.ifa_next
                guard String(cString: address.ifa_name) == networkInterface,
                      let socketAddress = address.ifa_addr,
                      socketAddress.pointee.sa_family == UInt8(networkAddressFamily) else {
                    continue
                }

                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameResult = getnameinfo(
                    socketAddress,
                    socklen_t(socketAddress.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                guard nameResult == 0 else {
                    snapshot = nil
                    errorMessage = "无法解析网络地址：\(String(cString: gai_strerror(nameResult)))"
                    return
                }
                networkAddress = String(cString: host)
                break
            }
            guard networkAddress != nil else {
                snapshot = nil
                errorMessage = "主网络接口缺少本机地址"
                return
            }

            let interfaceIndex = if_nametoindex(networkInterface)
            guard interfaceIndex > 0 else {
                snapshot = nil
                errorMessage = "主网络接口不存在"
                return
            }

            var routeMIB: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
            var routeBufferSize = 0
            guard sysctl(
                &routeMIB,
                u_int(routeMIB.count),
                nil,
                &routeBufferSize,
                nil,
                0
            ) == 0 else {
                snapshot = nil
                errorMessage = "无法读取网络统计长度：\(String(cString: strerror(errno)))"
                return
            }

            var routeBuffer = [UInt8](repeating: 0, count: routeBufferSize)
            let routeResult = routeBuffer.withUnsafeMutableBytes { buffer in
                sysctl(
                    &routeMIB,
                    u_int(routeMIB.count),
                    buffer.baseAddress,
                    &routeBufferSize,
                    nil,
                    0
                )
            }
            guard routeResult == 0 else {
                snapshot = nil
                errorMessage = "无法读取网络统计：\(String(cString: strerror(errno)))"
                return
            }

            var receivedBytes: UInt64?
            var sentBytes: UInt64?
            routeBuffer.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return
                }
                var offset = 0
                while offset < routeBufferSize {
                    let header = baseAddress.advanced(by: offset).loadUnaligned(as: if_msghdr.self)
                    guard header.ifm_msglen > 0 else {
                        return
                    }
                    if header.ifm_type == UInt8(RTM_IFINFO2) {
                        let details = baseAddress.advanced(by: offset).loadUnaligned(as: if_msghdr2.self)
                        if UInt32(details.ifm_index) == interfaceIndex {
                            receivedBytes = details.ifm_data.ifi_ibytes
                            sentBytes = details.ifm_data.ifi_obytes
                            return
                        }
                    }
                    offset += Int(header.ifm_msglen)
                }
            }
            guard let receivedBytes, let sentBytes else {
                snapshot = nil
                errorMessage = "主网络接口缺少流量统计"
                return
            }

            let currentNetworkSample = NetworkSample(
                interfaceName: networkInterface,
                receivedBytes: receivedBytes,
                sentBytes: sentBytes,
                uptime: currentUptime
            )
            if let previousNetworkSample,
               previousNetworkSample.interfaceName == networkInterface,
               receivedBytes >= previousNetworkSample.receivedBytes,
               sentBytes >= previousNetworkSample.sentBytes {
                let interval = currentUptime - previousNetworkSample.uptime
                guard interval > 0 else {
                    snapshot = nil
                    errorMessage = "网络采样间隔无效"
                    return
                }
                downloadBytesPerSecond = Double(receivedBytes - previousNetworkSample.receivedBytes) / interval
                uploadBytesPerSecond = Double(sentBytes - previousNetworkSample.sentBytes) / interval
            }
            self.previousNetworkSample = currentNetworkSample
        } else {
            previousNetworkSample = nil
        }

        let storageAttributes: [FileAttributeKey: Any]
        do {
            storageAttributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
        } catch {
            snapshot = nil
            errorMessage = "无法读取磁盘状态：\(error.localizedDescription)"
            return
        }
        guard let totalStorage = (storageAttributes[.systemSize] as? NSNumber)?.uint64Value,
              let freeStorage = (storageAttributes[.systemFreeSize] as? NSNumber)?.uint64Value,
              totalStorage > 0,
              freeStorage <= totalStorage else {
            snapshot = nil
            errorMessage = "磁盘统计数据不一致"
            return
        }
        let usedStorage = totalStorage - freeStorage

        previousCPUTicks = currentCPUTicks
        snapshot = SystemStatusSnapshot(
            cpuUsage: cpuUsage,
            memoryUsage: Double(memoryProduct.partialValue) / Double(totalMemory),
            usedMemory: memoryProduct.partialValue,
            totalMemory: totalMemory,
            appMemory: appMemory,
            wiredMemory: wiredMemory,
            compressedMemory: compressedMemory,
            availableMemory: availableMemory,
            swapMemory: swapUsage.xsu_used,
            storageUsage: Double(usedStorage) / Double(totalStorage),
            usedStorage: usedStorage,
            totalStorage: totalStorage,
            networkInterface: networkInterface,
            networkAddress: networkAddress,
            downloadBytesPerSecond: downloadBytesPerSecond,
            uploadBytesPerSecond: uploadBytesPerSecond,
            uptime: currentUptime
        )
        errorMessage = nil
    }
}

private struct SystemStatusView: View {
    @StateObject private var monitor = SystemStatusMonitor()
    @State private var detailsPresented = false
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Button {
            detailsPresented.toggle()
        } label: {
            Group {
                if let snapshot = monitor.snapshot {
                    let memoryText = snapshot.memoryUsage.formatted(
                        .percent.precision(.fractionLength(0))
                    )
                    let storageText = snapshot.storageUsage.formatted(
                        .percent.precision(.fractionLength(0))
                    )
                    Group {
                        if let cpuUsage = snapshot.cpuUsage {
                            let cpuText = cpuUsage.formatted(
                                .percent.precision(.fractionLength(0))
                            )
                            Text("CPU \(cpuText) · 内存 \(memoryText) · 磁盘 \(storageText)")
                        } else {
                            Text("CPU 采集中 · 内存 \(memoryText) · 磁盘 \(storageText)")
                        }
                    }
                    .foregroundStyle(.secondary)
                } else if let errorMessage = monitor.errorMessage {
                    Text("系统状态读取失败")
                        .foregroundStyle(.red)
                        .help(errorMessage)
                } else {
                    Text("系统状态采集中")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: QuickPiTypography.topBarSize, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(
                minWidth: 150,
                idealWidth: 190,
                maxWidth: 190,
                minHeight: 28,
                maxHeight: 28,
                alignment: .leading
            )
            .background(
                .primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 150, idealWidth: 190, maxWidth: 190)
        .help("查看系统状态详情")
        .popover(isPresented: $detailsPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Label("系统状态", systemImage: "gauge")
                    .font(.system(size: QuickPiTypography.titleSize, weight: .semibold))

                if let snapshot = monitor.snapshot {
                    let uptimeMinutes = Int(snapshot.uptime / 60)
                    let systemVersion = ProcessInfo.processInfo.operatingSystemVersion
                    let memoryText = snapshot.memoryUsage.formatted(
                        .percent.precision(.fractionLength(0))
                    )
                    let storageText = snapshot.storageUsage.formatted(
                        .percent.precision(.fractionLength(0))
                    )
                    let appMemoryText = snapshot.appMemory.formatted(.byteCount(style: .memory))
                    let wiredMemoryText = snapshot.wiredMemory.formatted(.byteCount(style: .memory))
                    let compressedMemoryText = snapshot.compressedMemory.formatted(.byteCount(style: .memory))
                    let availableMemoryText = snapshot.availableMemory.formatted(.byteCount(style: .memory))
                    let swapMemoryText = snapshot.swapMemory.formatted(.byteCount(style: .memory))

                    LabeledContent("CPU") {
                        if let cpuUsage = snapshot.cpuUsage {
                            Text(cpuUsage, format: .percent.precision(.fractionLength(0)))
                        } else {
                            Text("采集中")
                        }
                    }
                    LabeledContent("内存") {
                        Text(
                            "\(memoryText) · "
                                + "\(snapshot.usedMemory.formatted(.byteCount(style: .memory))) / "
                                + snapshot.totalMemory.formatted(.byteCount(style: .memory))
                        )
                    }
                    LabeledContent("App 内存", value: appMemoryText)
                    LabeledContent("联动内存", value: wiredMemoryText)
                    LabeledContent("压缩内存", value: compressedMemoryText)
                    LabeledContent("可用内存", value: availableMemoryText)
                    LabeledContent("交换空间", value: swapMemoryText)
                    LabeledContent("磁盘") {
                        Text(
                            "\(storageText) · "
                                + "\(snapshot.usedStorage.formatted(.byteCount(style: .file))) / "
                                + snapshot.totalStorage.formatted(.byteCount(style: .file))
                        )
                    }

                    Divider()

                    if let networkInterface = snapshot.networkInterface,
                       let networkAddress = snapshot.networkAddress {
                        LabeledContent("网络接口", value: networkInterface)
                        LabeledContent("本机地址", value: networkAddress)
                        LabeledContent("下行") {
                            if let downloadBytesPerSecond = snapshot.downloadBytesPerSecond {
                                Text(
                                    "\(UInt64(downloadBytesPerSecond.rounded()).formatted(.byteCount(style: .file)))/秒"
                                )
                            } else {
                                Text("采集中")
                            }
                        }
                        LabeledContent("上行") {
                            if let uploadBytesPerSecond = snapshot.uploadBytesPerSecond {
                                Text(
                                    "\(UInt64(uploadBytesPerSecond.rounded()).formatted(.byteCount(style: .file)))/秒"
                                )
                            } else {
                                Text("采集中")
                            }
                        }
                    } else {
                        LabeledContent("网络", value: "未连接")
                    }

                    Divider()

                    LabeledContent("处理器核心", value: "\(ProcessInfo.processInfo.activeProcessorCount) 个")
                    LabeledContent("系统运行") {
                        Text(
                            uptimeMinutes >= 1_440
                                ? "\(uptimeMinutes / 1_440) 天 \((uptimeMinutes % 1_440) / 60) 小时"
                                : "\(uptimeMinutes / 60) 小时 \(uptimeMinutes % 60) 分钟"
                        )
                    }
                    LabeledContent("操作系统") {
                        Text(
                            "macOS \(systemVersion.majorVersion)."
                                + "\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
                        )
                    }
                } else if let errorMessage = monitor.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else {
                    Text("采集中")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: QuickPiTypography.metadataSize))
            .monospacedDigit()
            .padding(16)
            .frame(width: 360)
        }
        .onAppear {
            monitor.refresh()
        }
        .onReceive(refreshTimer) { _ in
            monitor.refresh()
        }
    }
}

private struct QuestionnairePromptView: View {
    @ObservedObject var state: AppState
    let prompt: QuestionnairePrompt
    @State private var questionIndex = 0
    @State private var answers: [String: QuestionnaireAnswer] = [:]
    @State private var customInput = ""
    @State private var customQuestionID: String?
    @FocusState private var customInputFocused: Bool

    private var questions: [QuestionnaireDefinition.Question] {
        prompt.definition.questions
    }

    private var question: QuestionnaireDefinition.Question {
        questions[questionIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        PromptChoiceRow(
                            number: index + 1,
                            title: option.label,
                            description: option.description,
                            recommended: option.recommended == true,
                            selected: answers[question.id]?.index == index + 1
                        ) {
                            select(option: option, index: index)
                        }
                    }
                    if question.allowOther {
                        customAnswerRow
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            Divider()
            HStack {
                Spacer()
                Button("跳过") {
                    skipQuestion()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
        .frame(width: 720, height: 460)
        .background(Color.quickPiWindowBackground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(question.prompt)
                .font(.system(size: QuickPiTypography.titleSize, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                questionnaireNavigationButton(
                    systemName: "chevron.left",
                    help: "上一题",
                    disabled: questionIndex == 0
                ) {
                    move(to: questionIndex - 1)
                }
                Text("\(questionIndex + 1) of \(questions.count)")
                    .font(.system(size: QuickPiTypography.controlSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 44)
                questionnaireNavigationButton(
                    systemName: "chevron.right",
                    help: "下一题",
                    disabled: questionIndex == questions.count - 1
                ) {
                    move(to: questionIndex + 1)
                }
                questionnaireNavigationButton(
                    systemName: "xmark",
                    help: "取消问答",
                    disabled: false
                ) {
                    state.cancelQuestionnaire()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var customAnswerRow: some View {
        Group {
            if customQuestionID == question.id {
                HStack(spacing: 12) {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
                    TextField("输入其他回答", text: $customInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($customInputFocused)
                        .onSubmit { submitCustomAnswer() }
                    Button {
                        submitCustomAnswer()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(customInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("提交回答")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                }
            } else {
                Button {
                    beginCustomAnswer()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(Color.primary.opacity(0.05), in: Circle())
                        Text(customAnswerLabel)
                            .font(.system(size: QuickPiTypography.controlSize, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.025))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var customAnswerLabel: String {
        guard let answer = answers[question.id], answer.wasCustom else {
            return "输入其他回答"
        }
        return answer.label
    }

    @ViewBuilder
    private func questionnaireNavigationButton(
        systemName: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.35) : Color.secondary)
        .disabled(disabled)
        .help(help)
    }

    private func select(option: QuestionnaireDefinition.Question.Option, index: Int) {
        answers[question.id] = QuestionnaireAnswer(
            id: question.id,
            value: option.value,
            label: option.label,
            wasCustom: false,
            index: index + 1
        )
        advanceOrSubmit()
    }

    private func beginCustomAnswer() {
        if let answer = answers[question.id], answer.wasCustom {
            customInput = answer.label
        } else {
            customInput = ""
        }
        customQuestionID = question.id
        customInputFocused = true
    }

    private func submitCustomAnswer() {
        let value = customInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return
        }
        answers[question.id] = QuestionnaireAnswer(
            id: question.id,
            value: value,
            label: value,
            wasCustom: true,
            index: nil
        )
        customQuestionID = nil
        customInputFocused = false
        advanceOrSubmit()
    }

    private func skipQuestion() {
        answers[question.id] = nil
        advanceOrSubmit()
    }

    private func advanceOrSubmit() {
        if questionIndex < questions.count - 1 {
            move(to: questionIndex + 1)
        } else {
            let orderedAnswers = questions.compactMap { answers[$0.id] }
            state.respondToQuestionnaire(answers: orderedAnswers)
        }
    }

    private func move(to index: Int) {
        guard questions.indices.contains(index) else {
            return
        }
        questionIndex = index
        customQuestionID = nil
        customInput = ""
        customInputFocused = false
    }
}

private struct ExtensionPromptView: View {
    @ObservedObject var state: AppState
    let prompt: ExtensionPrompt
    @State private var value: String

    init(state: AppState, prompt: ExtensionPrompt) {
        self.state = state
        self.prompt = prompt
        _value = State(initialValue: prompt.prefill ?? "")
    }

    var body: some View {
        Group {
            if prompt.method == "select" || prompt.method == "confirm" {
                PromptChoicePanel(
                    title: prompt.title,
                    subtitle: prompt.message,
                    choices: extensionPromptChoiceItems(prompt),
                    onSelect: selectChoice(at:),
                    onCancel: state.cancelExtensionPrompt
                )
            } else {
                inputPrompt
            }
        }
    }

    private var inputPrompt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.title)
                .font(.system(size: QuickPiTypography.titleSize, weight: .semibold))

            if let message = prompt.message {
                Text(message)
                    .foregroundStyle(.secondary)
            }

            if prompt.method == "editor" {
                TextEditor(text: $value)
                    .font(.system(size: QuickPiTypography.codeSize, design: .monospaced))
                    .padding(6)
                    .background(
                        .primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                submitRow
            } else {
                TextField(prompt.placeholder ?? "", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Spacer(minLength: 0)
                submitRow
            }
        }
        .padding(20)
        .frame(width: 420, height: prompt.method == "editor" ? 360 : 280)
        .background(Color.quickPiWindowBackground)
    }

    private var submitRow: some View {
        HStack {
            Spacer()
            Button("取消") {
                state.cancelExtensionPrompt()
            }
            Button("继续") {
                submit()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func selectChoice(at index: Int) {
        if prompt.method == "select" {
            guard prompt.options.indices.contains(index) else {
                return
            }
            state.respondToExtensionPrompt(value: prompt.options[index])
        } else if prompt.method == "confirm" {
            state.respondToExtensionPrompt(confirmed: index == 0)
        }
    }

    // Returns the exact input or edited text requested by the extension.
    private func submit() {
        state.respondToExtensionPrompt(value: value)
    }
}

// Groups adjacent tool activity until visible model text starts the next response segment.
func toolActivityGroupsByCallID(in sections: [AnswerSection]) -> [String: [ToolActivity]] {
    var groups: [[ToolActivity]] = []
    var current: [ToolActivity] = []

    for section in sections {
        switch section.content {
        case .markdown(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !current.isEmpty {
                groups.append(current)
                current.removeAll(keepingCapacity: true)
            }
        case .tool(let tool):
            current.append(tool)
        default:
            break
        }
    }
    if !current.isEmpty {
        groups.append(current)
    }

    return groups.reduce(into: [:]) { result, group in
        for tool in group {
            result[tool.callId] = group
        }
    }
}

private struct AnswerSectionView: View {
    let section: AnswerSection
    let toolsByCallID: [String: [ToolActivity]]
    let baseURL: URL
    let openFile: (URL) -> Void
    let respondToApproval: (String, Bool) -> Void

    var body: some View {
        switch section.content {
        case .markdown(let text):
            AnswerMarkdownView(source: text, baseURL: baseURL)
        case .extensionMessage(let text):
            AnswerMarkdownView(source: text, baseURL: baseURL)
        case .fileLink(let url):
            Button {
                openFile(url)
            } label: {
                Label(url.lastPathComponent, systemImage: "doc")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .help(url.path)
        case .customMessage(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("[\(message.customType)]")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                switch message.content {
                case .string(let content):
                    AnswerMarkdownView(source: content, baseURL: baseURL)
                default:
                    Text(message.content.formattedJSON)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                switch message.qrCode {
                case .absent:
                    EmptyView()
                case .invalid:
                    Label("插件提供的 details.qrUrl 无效", systemImage: "exclamationmark.triangle")
                        .font(.system(size: QuickPiTypography.metadataSize))
                        .foregroundStyle(.red)
                case .url(let qrURL):
                    let qrImage: CGImage? = {
                        let filter = CIFilter.qrCodeGenerator()
                        filter.message = Data(qrURL.absoluteString.utf8)
                        filter.correctionLevel = "M"
                        guard let output = filter.outputImage else {
                            return nil
                        }
                        let scale = max(CGFloat(1), floor(220 / output.extent.width))
                        let scaled = output.transformed(
                            by: CGAffineTransform(scaleX: scale, y: scale)
                        )
                        return qrCodeContext.createCGImage(scaled, from: scaled.extent)
                    }()

                    if let qrImage {
                        Image(decorative: qrImage, scale: 1)
                            .interpolation(.none)
                            .padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.primary.opacity(0.12))
                            }
                            .accessibilityLabel("登录二维码")
                    } else {
                        Label("无法生成二维码", systemImage: "exclamationmark.triangle")
                            .font(.system(size: QuickPiTypography.metadataSize))
                            .foregroundStyle(.red)
                    }

                    Link(destination: qrURL) {
                        Label("打开备用地址", systemImage: "arrow.up.right.square")
                    }
                    .font(.system(size: QuickPiTypography.metadataSize))
                }
                if let details = message.details {
                    DisclosureGroup {
                        Text(details.formattedJSON)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                            .textSelection(.enabled)
                    } label: {
                        Text("插件详情")
                            .font(.system(size: QuickPiTypography.metadataSize, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .extensionNotification(let notification):
            let presentation: (color: Color, symbol: String) = switch notification.kind {
            case .info:
                (Color.accentColor, "info.circle.fill")
            case .warning:
                (.orange, "exclamationmark.triangle.fill")
            case .error:
                (.red, "xmark.circle.fill")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(presentation.color)
                AnswerMarkdownView(source: notification.message, baseURL: baseURL)
            }
        case .operationApproval(let approval):
            OperationApprovalView(approval: approval) { approved in
                respondToApproval(approval.requestId, approved)
            }
        case .thinking(let text):
            ThinkingActivityView(text: text, baseURL: baseURL)
        case .tool(let tool):
            if let tools = toolsByCallID[tool.callId], tool.callId == tools.first?.callId {
                ToolActivityGroupView(tools: tools)
            }
        }
    }
}

private struct OperationApprovalButtonStyle: ButtonStyle {
    let approved: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: QuickPiTypography.settingsSize, weight: .medium))
            .foregroundStyle(approved ? Color.white : Color.red)
            .padding(.horizontal, 14)
            .frame(minWidth: 104, minHeight: 32, maxHeight: 32)
            .background(
                approved
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.72 : 1)
                    : Color.red.opacity(configuration.isPressed ? 0.10 : 0.04),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        approved ? Color.accentColor : Color.red.opacity(0.45),
                        lineWidth: 1
                    )
            }
    }
}

private struct OperationApprovalView: View {
    let approval: OperationApproval
    let onDecision: (Bool) -> Void

    private var presentation: (title: String, symbol: String) {
        switch approval.kind {
        case .shell:
            ("Shell 命令需要审批", "terminal")
        case .write:
            ("文件写入需要审批", "doc.badge.plus")
        case .edit:
            ("文件编辑需要审批", "square.and.pencil")
        case .tool:
            ("工具调用需要审批", "wrench.and.screwdriver")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                Text(presentation.title)
                    .font(.system(size: QuickPiTypography.bodySize, weight: .semibold))
                Text(approval.toolName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                decisionLabel
            }

            Label(approval.workingDirectory, systemImage: "folder")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(approval.workingDirectory)

            ScrollView([.horizontal, .vertical]) {
                Text(approval.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(9)
            }
            .frame(maxWidth: .infinity, maxHeight: 180, alignment: .leading)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))

            if approval.decision == .pending {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button {
                        onDecision(false)
                    } label: {
                        Label("不通过", systemImage: "xmark")
                    }
                    .buttonStyle(OperationApprovalButtonStyle(approved: false))

                    Button {
                        onDecision(true)
                    } label: {
                        Label("通过", systemImage: "checkmark")
                    }
                    .buttonStyle(OperationApprovalButtonStyle(approved: true))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var decisionLabel: some View {
        switch approval.decision {
        case .pending:
            Label("等待决定", systemImage: "clock")
                .foregroundStyle(.orange)
        case .approved:
            Label("已通过", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .rejected:
            Label("未通过", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

private func toolActivityInlineSummary(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private struct ThinkingActivityView: View {
    let text: String
    let baseURL: URL
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: "brain")
                    Text("思考过程")
                        .font(.system(
                            size: QuickPiTypography.supportingSize,
                            weight: .medium,
                            design: .monospaced
                        ))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "收起思考过程" : "展开思考过程")

            if isExpanded {
                AnswerMarkdownView(source: text, baseURL: baseURL)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
    }
}

private struct ToolActivityGroupView: View {
    let tools: [ToolActivity]
    @State private var isExpanded = false

    private var isFinished: Bool {
        !tools.contains { $0.status == .running }
    }

    var body: some View {
        if tools.count > 1, isFinished {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        Image(systemName: tools.contains { $0.status == .failed }
                            ? "xmark.circle"
                            : "checkmark.circle")
                        Text("已调用 \(tools.count) 个工具")
                            .font(.system(size: QuickPiTypography.supportingSize, weight: .medium))
                            .fixedSize(horizontal: true, vertical: false)
                        Text(tools.map {
                            "\($0.name) \(toolActivityInlineSummary($0.input))"
                        }.joined(separator: " · "))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起工具调用" : "展开工具调用")

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(tools, id: \.callId) { tool in
                            ToolActivityView(tool: tool)
                        }
                    }
                    .padding(.top, 8)
                    .transition(.opacity)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tools, id: \.callId) { tool in
                    ToolActivityView(tool: tool)
                }
            }
        }
    }
}

private struct ToolActivityView: View {
    let tool: ToolActivity
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    switch tool.status {
                    case .running:
                        ProgressView()
                            .controlSize(.mini)
                    case .completed:
                        Image(systemName: "checkmark.circle")
                    case .failed:
                        Image(systemName: "xmark.circle")
                    }
                    Text(tool.name)
                        .font(.system(
                            size: QuickPiTypography.supportingSize,
                            weight: .medium,
                            design: .monospaced
                        ))
                        .fixedSize(horizontal: true, vertical: false)
                    Text(toolActivityInlineSummary(tool.input))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "收起 \(tool.name)" : "展开 \(tool.name)")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("输入")
                        .font(.system(size: QuickPiTypography.metadataSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                    monospaced(tool.input)
                    if !tool.output.isEmpty {
                        Text("输出")
                            .font(.system(size: QuickPiTypography.metadataSize, weight: .semibold))
                            .foregroundStyle(.secondary)
                        monospaced(tool.output)
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
    }

    // Displays tool JSON and output in a stable horizontally scrollable monospace region.
    private func monospaced(_ text: String) -> some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(9)
                    .padding(.trailing, 30)
                    .textSelection(.enabled)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .foregroundStyle(.secondary)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .padding(5)
            .help("复制内容")
        }
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

private let planMarkdownTheme = Theme()
    .text {
        ForegroundColor(Color.primary.opacity(0.92))
        FontSize(QuickPiTypography.supportingSize)
    }
    .code {
        FontFamilyVariant(.monospaced)
        FontSize(QuickPiTypography.codeSize)
        BackgroundColor(Color.primary.opacity(0.055))
    }
    .strong {
        FontWeight(.semibold)
    }
    .link {
        ForegroundColor(.accentColor)
    }
    .paragraph { configuration in
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .relativeLineSpacing(.em(0.12))
            .markdownMargin(top: 0, bottom: 0)
    }
    .list { configuration in
        configuration.label
            .markdownMargin(top: 0, bottom: 0)
    }
    .listItem { configuration in
        configuration.label
            .markdownMargin(top: 0, bottom: 0)
    }

private struct PlanStatusTextView: View {
    let status: ExtensionStatus

    var body: some View {
        if let richText = status.richText {
            Text(richText.attributedString(fontSize: 12, baseWeight: .medium))
        } else {
            Text(status.text)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PlanProgressLineView: View {
    let source: String
    let richText: ExtensionRichText?
    let baseURL: URL

    var body: some View {
        if let richText {
            Text(richText.attributedString(fontSize: QuickPiTypography.supportingSize))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            Markdown(source, baseURL: baseURL)
                .markdownTheme(planMarkdownTheme)
                .markdownImageProvider(AssetImageProvider())
                .markdownInlineImageProvider(AssetInlineImageProvider())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.isFileURL else {
                        return .systemAction
                    }
                    return NSWorkspace.shared.open(url) ? .handled : .discarded
                })
        }
    }
}

private extension ExtensionRichText {
    func attributedString(
        fontSize: CGFloat,
        baseWeight: NSFont.Weight = .regular
    ) -> AttributedString {
        let value = NSMutableAttributedString(string: "")
        for run in runs {
            var font = NSFont.systemFont(
                ofSize: fontSize,
                weight: run.style.bold ? .semibold : baseWeight
            )
            if run.style.italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: run.style.foreground.map {
                    nativeColor($0, dimmed: run.style.dimmed)
                } ?? (run.style.dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor),
            ]
            if run.style.underlined {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.style.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            value.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return AttributedString(value)
    }

    func nativeColor(_ color: Color, dimmed: Bool) -> NSColor {
        let resolved: NSColor
        switch color {
        case .indexed(let index):
            resolved = indexedColor(index)
        case let .rgb(red, green, blue):
            resolved = NSColor(
                srgbRed: CGFloat(min(max(red, 0), 255)) / 255,
                green: CGFloat(min(max(green, 0), 255)) / 255,
                blue: CGFloat(min(max(blue, 0), 255)) / 255,
                alpha: 1
            )
        }
        return dimmed ? resolved.withAlphaComponent(0.62) : resolved
    }

    func indexedColor(_ index: Int) -> NSColor {
        let basic: [NSColor] = [
            .black, .systemRed, .systemGreen, .systemYellow,
            .systemBlue, .systemPurple, .systemCyan, .white,
            .darkGray, .systemRed, .systemGreen, .systemYellow,
            .systemBlue, .systemPurple, .systemCyan, .white,
        ]
        if basic.indices.contains(index) {
            return basic[index]
        }
        if (16...231).contains(index) {
            let cube = [0, 95, 135, 175, 215, 255]
            let offset = index - 16
            return NSColor(
                srgbRed: CGFloat(cube[offset / 36]) / 255,
                green: CGFloat(cube[(offset / 6) % 6]) / 255,
                blue: CGFloat(cube[offset % 6]) / 255,
                alpha: 1
            )
        }
        let component = CGFloat(min(max(8 + (index - 232) * 10, 0), 255)) / 255
        return NSColor(srgbRed: component, green: component, blue: component, alpha: 1)
    }
}

private let answerMarkdownTheme = Theme()
    .text {
        ForegroundColor(Color.primary.opacity(0.92))
        FontSize(QuickPiTypography.bodySize)
    }
    .code {
        FontFamilyVariant(.monospaced)
        FontSize(QuickPiTypography.codeSize)
        ForegroundColor(Color.primary.opacity(0.88))
        BackgroundColor(Color.primary.opacity(0.055))
    }
    .strong {
        FontWeight(.semibold)
    }
    .link {
        ForegroundColor(.accentColor)
    }
    .heading1 { configuration in
        configuration.label
            .relativeLineSpacing(.em(0.14))
            .markdownMargin(top: 18, bottom: 8)
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(QuickPiTypography.titleSize)
            }
    }
    .heading2 { configuration in
        configuration.label
            .relativeLineSpacing(.em(0.14))
            .markdownMargin(top: 16, bottom: 8)
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(QuickPiTypography.titleSize)
            }
    }
    .heading3 { configuration in
        configuration.label
            .relativeLineSpacing(.em(0.14))
            .markdownMargin(top: 14, bottom: 6)
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(QuickPiTypography.titleSize)
            }
    }
    .heading4 { configuration in
        configuration.label
            .markdownMargin(top: 12, bottom: 6)
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(QuickPiTypography.titleSize)
            }
    }
    .heading5 { configuration in
        configuration.label
            .markdownMargin(top: 12, bottom: 6)
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(QuickPiTypography.titleSize)
                ForegroundColor(.secondary)
            }
    }
    .heading6 { configuration in
        configuration.label
            .markdownMargin(top: 12, bottom: 6)
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(QuickPiTypography.titleSize)
                ForegroundColor(.secondary)
            }
    }
    .paragraph { configuration in
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .relativeLineSpacing(.em(0.22))
            .markdownMargin(top: 0, bottom: 10)
    }
    .list { configuration in
        configuration.label
            .markdownMargin(top: 0, bottom: 10)
    }
    .listItem { configuration in
        configuration.label
            .relativeLineSpacing(.em(0.18))
            .markdownMargin(top: .em(0.3))
    }
    .taskListMarker { configuration in
        Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(configuration.isCompleted ? Color.accentColor : Color.secondary)
            .imageScale(.small)
            .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
    }
    .blockquote { configuration in
        configuration.label
            .markdownTextStyle {
                ForegroundColor(.secondary)
                BackgroundColor(nil)
            }
            .relativePadding(.vertical, length: .em(0.55))
            .relativePadding(.horizontal, length: .em(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .markdownMargin(top: 0, bottom: 10)
    }
    .codeBlock { configuration in
        VStack(alignment: .leading, spacing: 0) {
            if let language = configuration.language {
                Text(language)
                    .font(.system(
                        size: QuickPiTypography.metadataSize,
                        weight: .medium,
                        design: .monospaced
                    ))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.24))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(QuickPiTypography.codeSize)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08))
        }
        .markdownMargin(top: 0, bottom: 10)
    }
    .table { configuration in
        ScrollView(.horizontal) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: Color.primary.opacity(0.1)))
                .markdownTableBackgroundStyle(
                    .alternatingRows(
                        Color.primary.opacity(0.025),
                        Color.clear,
                        header: Color.primary.opacity(0.055)
                    )
                )
        }
        .markdownMargin(top: 0, bottom: 10)
    }
    .tableCell { configuration in
        configuration.label
            .markdownTextStyle {
                if configuration.row == 0 {
                    FontWeight(.semibold)
                }
                BackgroundColor(nil)
            }
            .fixedSize(horizontal: false, vertical: true)
            .relativeLineSpacing(.em(0.18))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
    }
    .thematicBreak {
        Divider()
            .overlay(Color.primary.opacity(0.12))
            .markdownMargin(top: 14, bottom: 14)
    }

private struct AnswerMarkdownView: View {
    let source: String
    let baseURL: URL

    var body: some View {
        // Asset-only providers prevent untrusted model output from issuing remote image requests.
        Markdown(source, baseURL: baseURL)
            .markdownTheme(answerMarkdownTheme)
            .markdownImageProvider(AssetImageProvider())
            .markdownInlineImageProvider(AssetInlineImageProvider())
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.isFileURL else {
                    return .systemAction
                }
                return NSWorkspace.shared.open(url) ? .handled : .discarded
            })
    }
}
