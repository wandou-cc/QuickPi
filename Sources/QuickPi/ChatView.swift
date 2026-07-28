import AppKit
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let quickPiFocusInput = Notification.Name("quickPiFocusInput")
}

struct ChatView: View {
    @ObservedObject var state: AppState
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            inputBar
            if state.showsResultPanel {
                Divider()
                    .padding(.horizontal, 14)
                resultPanel
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.primary.opacity(0.12))
        }
        .sheet(isPresented: $state.settingsPresented) {
            SettingsView(state: state)
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickPiFocusInput)) { _ in
            promptFocused = true
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("问点什么", text: $state.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($promptFocused)
                .onSubmit {
                    Task { await state.send() }
                }

            if !state.attachments.isEmpty {
                Menu {
                    ForEach(state.attachments) { attachment in
                        Button("移除 \(attachment.name)") {
                            state.removeAttachment(id: attachment.id)
                        }
                    }
                } label: {
                    Label("\(state.attachments.count)", systemImage: "paperclip")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button {
                chooseAttachments()
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .help("添加附件")

            Menu {
                if state.modelOptions.isEmpty {
                    Text("未配置模型")
                } else {
                    ForEach(state.modelOptions, id: \.selectionKey) { model in
                        Button {
                            Task { await state.selectModel(selectionKey: model.selectionKey) }
                        } label: {
                            if state.settings.selectedModel == model.selection {
                                Label("\(model.providerName) · \(model.name)", systemImage: "checkmark")
                            } else {
                                Text("\(model.providerName) · \(model.name)")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if state.runtimeStarting {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(state.selectedModel?.name ?? "选择模型")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 150)
            .disabled(!state.runtimeReady || state.isAnswering)

            Button {
                Task { await state.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .disabled(
                state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !state.runtimeReady
                    || state.isAnswering
            )
            .help("发送")

            Button {
                state.settingsPresented = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .help("设置")
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let answer = state.answer {
                            questionView(answer.question)

                            ForEach(answer.sections) { section in
                                AnswerSectionView(section: section)
                            }

                            if answer.sections.isEmpty && state.isAnswering {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(answer.status == .waiting ? "正在连接模型" : "正在思考")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let retry = answer.retryMessage {
                                Label(retry, systemImage: "arrow.clockwise")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }
                            if let error = answer.error {
                                Label(error, systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            } else if answer.status == .stopped {
                                Label("已停止", systemImage: "stop.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            answerMetadata(answer)
                        }

                        if let runtimeError = state.runtimeError {
                            Label(runtimeError, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("answer-bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.answer) { _, _ in
                    proxy.scrollTo("answer-bottom", anchor: .bottom)
                }
            }

            Divider()

            HStack(spacing: 14) {
                if state.isAnswering {
                    Button {
                        Task { await state.abort() }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.plain)
                    .help("停止回答")
                }

                Spacer()

                if let text = state.answer?.answerText, !text.isEmpty {
                    Button {
                        copy(text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("复制回答")
                }

                Button {
                    Task { await state.clearAnswer() }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("收起结果")
            }
            .font(.caption)
            .padding(.horizontal, 18)
            .frame(height: 40)
        }
        .frame(height: 440)
    }

    // Renders the submitted question and its attachment names without repeating extracted content.
    private func questionView(_ question: SubmittedQuestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(question.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !question.attachmentNames.isEmpty {
                Label(question.attachmentNames.joined(separator: " · "), systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // Shows model, token, cost, and non-normal stop metadata after assistant turns arrive.
    @ViewBuilder
    private func answerMetadata(_ answer: AnswerSession) -> some View {
        if answer.model != nil || answer.usage.totalTokens > 0 || answer.stopReason == "length" {
            HStack(spacing: 10) {
                if let provider = answer.provider, let model = answer.model {
                    Text("\(provider) / \(model)")
                }
                if answer.usage.totalTokens > 0 {
                    Text("\(answer.usage.totalTokens.formatted()) tokens")
                }
                if answer.usage.cost > 0 {
                    Text(answer.usage.cost, format: .currency(code: "USD"))
                }
                if answer.stopReason == "length" {
                    Label("达到输出上限", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
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
        guard panel.runModal() == .OK else {
            return
        }
        Task { await state.addAttachments(urls: panel.urls) }
    }

    // Replaces the general pasteboard with the selected answer or code content.
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct AnswerSectionView: View {
    let section: AnswerSection

    var body: some View {
        switch section.content {
        case .markdown(let text):
            AnswerMarkdownView(source: text)
        case .thinking(let text):
            DisclosureGroup {
                AnswerMarkdownView(source: text)
                    .padding(.top, 6)
            } label: {
                Label("思考过程", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .tool(let tool):
            ToolActivityView(tool: tool)
        }
    }
}

private struct ToolActivityView: View {
    let tool: ToolActivity

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("输入")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                monospaced(tool.input)
                if !tool.output.isEmpty {
                    Text("输出")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    monospaced(tool.output)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                switch tool.status {
                case .running:
                    ProgressView()
                        .controlSize(.mini)
                case .completed:
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.red)
                }
                Text(tool.name)
                    .font(.caption.weight(.medium))
            }
        }
    }

    // Displays tool JSON and output in a stable horizontally scrollable monospace region.
    private func monospaced(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(9)
        }
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct AnswerMarkdownView: View {
    let source: String

    var body: some View {
        // Asset-only providers prevent untrusted model output from issuing remote image requests.
        Markdown(source)
            .markdownTheme(.gitHub)
            .markdownImageProvider(AssetImageProvider())
            .markdownInlineImageProvider(AssetInlineImageProvider())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
