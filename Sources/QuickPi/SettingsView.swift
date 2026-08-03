import SwiftUI

private enum SettingsPane {
    case general
    case personalization
    case security
    case providers
}

private let providerGridColumns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12),
]

struct SettingsView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(QuickPiTheme.storageKey) private var theme = QuickPiTheme.system
    @AppStorage("showSystemStatus") private var showSystemStatus = true
    @AppStorage("hidePanelWhenInactive") private var hidePanelWhenInactive = false
    @State private var selectedPane: SettingsPane = .general
    @State private var shortcut: String
    @State private var launchAtLogin: Bool
    @State private var fillInputFromClipboardOnShortcut: Bool
    @State private var savingGeneral = false
    @State private var generalMessage: String?
    @State private var approvalEnabled: Bool
    @State private var approvalToolNames: String
    @State private var approveAllShellCommands: Bool
    @State private var shellCommandKeywords: String
    @State private var savingSecurity = false
    @State private var securityMessage: String?
    @State private var securityMessageIsError = false
    @State private var agentInstructions = ""
    @State private var savedAgentInstructions = ""
    @State private var loadingAgentInstructions = true
    @State private var savingAgentInstructions = false
    @State private var personalizationMessage: String?
    @State private var personalizationMessageIsError = false
    @State private var showingProviderForm = false
    @State private var provider = ProviderConfiguration(
        id: "custom-\(UUID().uuidString.lowercased())",
        kind: .openAI,
        name: "",
        baseURL: "",
        models: [],
        modelThinkingLevels: [:]
    )
    @State private var apiKey = ""
    @State private var selectedModelId = ""
    @State private var syncingModels = false
    @State private var savingProvider = false
    @State private var providerMessage: String?
    private let setPanelHidesOnDeactivate: (Bool) -> Void

    // Seeds editable controls and binds the live AppKit panel behavior.
    init(state: AppState, setPanelHidesOnDeactivate: @escaping (Bool) -> Void) {
        self.state = state
        self.setPanelHidesOnDeactivate = setPanelHidesOnDeactivate
        _shortcut = State(initialValue: state.settings.shortcut)
        _launchAtLogin = State(initialValue: state.settings.launchAtLogin)
        _fillInputFromClipboardOnShortcut = State(
            initialValue: state.settings.fillInputFromClipboardOnShortcut
        )
        let approval = state.settings.operationApproval
        _approvalEnabled = State(initialValue: approval.enabled)
        _approvalToolNames = State(initialValue: approval.toolNames.joined(separator: "\n"))
        _approveAllShellCommands = State(initialValue: approval.approveAllShellCommands)
        _shellCommandKeywords = State(initialValue: approval.shellCommandKeywords.joined(separator: "\n"))
    }

    private var isEditingProvider: Bool {
        state.settings.providers.contains { $0.id == provider.id }
    }

    private var currentAppVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (.some(version), .some(build)):
            return "\(version) (\(build))"
        case let (.some(version), .none):
            return version
        case let (.none, .some(build)):
            return build
        case (.none, .none):
            return "未知"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                Button {
                    selectedPane = .general
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "gearshape")
                            .frame(width: 18)
                        Text("通用")
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                    .background(
                        selectedPane == .general ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedPane == .general ? Color.accentColor : Color.primary)

                Button {
                    selectedPane = .personalization
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "person.crop.circle")
                            .frame(width: 18)
                        Text("个性化")
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                    .background(
                        selectedPane == .personalization ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedPane == .personalization ? Color.accentColor : Color.primary)

                Button {
                    selectedPane = .security
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.shield")
                            .frame(width: 18)
                        Text("安全")
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                    .background(
                        selectedPane == .security ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedPane == .security ? Color.accentColor : Color.primary)

                Button {
                    selectedPane = .providers
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "server.rack")
                            .frame(width: 18)
                        Text("Provider")
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                    .background(
                        selectedPane == .providers ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedPane == .providers ? Color.accentColor : Color.primary)

                Spacer()
            }
            .padding(12)
            .frame(width: 164)
            .frame(maxHeight: .infinity)
            .background(Color.quickPiWindowBackground)

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Group {
                        if selectedPane == .general {
                            Text("通用")
                        } else if selectedPane == .personalization {
                            Text("个性化")
                        } else if selectedPane == .security {
                            Text("安全")
                        } else if showingProviderForm {
                            Text(isEditingProvider ? "编辑 Provider" : "添加 Provider")
                        } else {
                            Text("Provider")
                        }
                    }
                    .font(.system(size: QuickPiTypography.titleSize, weight: .semibold))

                    if (selectedPane == .general && savingGeneral)
                        || (selectedPane == .personalization && savingAgentInstructions)
                        || (selectedPane == .security && savingSecurity) {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    if selectedPane == .security {
                        Button {
                            applyOperationApprovalDraft(.defaults)
                            securityMessage = nil
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(SettingsIconButtonStyle())
                        .disabled(savingSecurity)
                        .help("恢复默认")

                        Button {
                            saveSecuritySettings()
                        } label: {
                            Label("保存", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(SettingsActionButtonStyle(prominence: .primary))
                        .disabled(savingSecurity || !state.canSaveAgentInstructions)
                    }

                    if selectedPane == .providers {
                        Button {
                            if showingProviderForm {
                                showingProviderForm = false
                            } else {
                                provider = ProviderConfiguration(
                                    id: "custom-\(UUID().uuidString.lowercased())",
                                    kind: .openAI,
                                    name: "",
                                    baseURL: "",
                                    models: [],
                                    modelThinkingLevels: [:]
                                )
                                apiKey = ""
                                selectedModelId = ""
                                providerMessage = nil
                                showingProviderForm = true
                            }
                        } label: {
                            Label(
                                showingProviderForm ? "返回列表" : "添加 Provider",
                                systemImage: showingProviderForm ? "chevron.left" : "plus"
                            )
                        }
                        .disabled(syncingModels || savingProvider)
                    }

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(SettingsIconButtonStyle())
                    .disabled(
                        savingGeneral
                            || savingSecurity
                            || savingAgentInstructions
                            || syncingModels
                            || savingProvider
                    )
                    .help("关闭设置")
                }
                .padding(.horizontal, 24)
                .frame(height: 64)

                Divider()

                if selectedPane == .general {
                    generalTab
                } else if selectedPane == .personalization {
                    personalizationTab
                } else if selectedPane == .security {
                    securityTab
                } else {
                    providersTab
                }
            }
        }
        .buttonStyle(SettingsActionButtonStyle())
        .font(.system(size: QuickPiTypography.settingsSize))
        .frame(width: 780, height: 660)
        .background(Color.quickPiWindowBackground)
        .preferredColorScheme(theme.colorScheme)
        .interactiveDismissDisabled(
            savingGeneral || savingSecurity || savingAgentInstructions || syncingModels || savingProvider
        )
        .task {
            loadAgentInstructions()
        }
        .sheet(isPresented: Binding(
            get: { state.authSession != nil },
            set: { presented in
                if !presented && state.authSession != nil {
                    state.cancelAuth()
                }
            }
        )) {
            AuthView(state: state)
        }
    }

    private var generalTab: some View {
        Form {
            Section("快速启动") {
                Picker("全局快捷键", selection: Binding(
                    get: { shortcut },
                    set: { value in
                        persistGeneralSettings(
                            shortcut: value,
                            launchAtLogin: launchAtLogin,
                            fillInputFromClipboardOnShortcut: fillInputFromClipboardOnShortcut
                        )
                    }
                )) {
                    Text("⌘ ⇧ Space").tag("commandShiftSpace")
                    Text("⌥ Space").tag("optionSpace")
                    Text("⌃ Space").tag("controlSpace")
                    Text("⌘ ⌥ Space").tag("commandOptionSpace")
                }
                Toggle("登录后自动启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        persistGeneralSettings(
                            shortcut: shortcut,
                            launchAtLogin: enabled,
                            fillInputFromClipboardOnShortcut: fillInputFromClipboardOnShortcut
                        )
                    }
                ))
                Toggle("快捷键打开时填入新复制的文本", isOn: Binding(
                    get: { fillInputFromClipboardOnShortcut },
                    set: { enabled in
                        persistGeneralSettings(
                            shortcut: shortcut,
                            launchAtLogin: launchAtLogin,
                            fillInputFromClipboardOnShortcut: enabled
                        )
                    }
                ))
                Toggle("失焦时隐藏主弹窗", isOn: $hidePanelWhenInactive)
                    .onChange(of: hidePanelWhenInactive) { _, hidesOnDeactivate in
                        setPanelHidesOnDeactivate(hidesOnDeactivate)
                    }
            }

            Section("首页") {
                Toggle("显示系统状态", isOn: $showSystemStatus)
            }

            Section("软件更新") {
                LabeledContent("当前版本") {
                    Text(currentAppVersion)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button {
                    state.checkForUpdates()
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            if generalMessage != nil || state.shortcutError != nil {
                Section {
                    if let generalMessage {
                        Text(generalMessage)
                            .font(.system(size: QuickPiTypography.settingsSize))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let shortcutError = state.shortcutError {
                        Text(shortcutError)
                            .font(.system(size: QuickPiTypography.settingsSize))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.quickPiWindowBackground)
        .disabled(savingGeneral)
    }

    private var securityTab: some View {
        Form {
            Section("操作审批") {
                Toggle("启用操作审批", isOn: $approvalEnabled)
            }

            Section("工具") {
                LabeledContent("逐次审批的工具名") {
                    TextEditor(text: $approvalToolNames)
                        .font(.system(size: QuickPiTypography.settingsSize, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(width: 390)
                        .frame(minHeight: 82, maxHeight: 110)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                        }
                        .accessibilityLabel("逐次审批的工具名，每行一个")
                }
            }

            Section("Shell") {
                Toggle("审批所有 Shell 命令", isOn: $approveAllShellCommands)
                LabeledContent("危险命令关键字") {
                    TextEditor(text: $shellCommandKeywords)
                        .font(.system(size: QuickPiTypography.settingsSize, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(width: 390)
                        .frame(minHeight: 132, maxHeight: 180)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                        }
                        .accessibilityLabel("危险 Shell 命令关键字，每行一个")
                        .disabled(approveAllShellCommands)
                }
            }

            if let securityMessage {
                Section {
                    Text(securityMessage)
                        .foregroundStyle(securityMessageIsError ? Color.red : Color.green)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.quickPiWindowBackground)
        .disabled(savingSecurity)
    }

    private var personalizationTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Text("主题")
                    .font(.system(size: QuickPiTypography.settingsSize, weight: .semibold))

                Spacer()

                Picker("主题", selection: $theme) {
                    ForEach(QuickPiTheme.allCases) { option in
                        Label(option.title, systemImage: option.systemImage)
                            .tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 390)
            }

            Divider()

            HStack(spacing: 8) {
                Text("全局 AGENTS.md")
                    .font(.system(size: QuickPiTypography.settingsSize, weight: .semibold))

                Spacer()

                Button {
                    agentInstructions = state.defaultAgentInstructions
                    personalizationMessage = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(SettingsIconButtonStyle())
                .disabled(loadingAgentInstructions || savingAgentInstructions)
                .help("恢复默认")

                Button {
                    savePersonalizationSettings()
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(SettingsActionButtonStyle(prominence: .primary))
                .disabled(
                    loadingAgentInstructions
                        || savingAgentInstructions
                        || agentInstructions == savedAgentInstructions
                        || !state.canSaveAgentInstructions
                )
            }

            Group {
                if loadingAgentInstructions {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在读取 AGENTS.md")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $agentInstructions)
                        .font(.system(size: QuickPiTypography.settingsSize, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                        }
                        .accessibilityLabel("全局 AGENTS.md")
                        .disabled(savingAgentInstructions)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 180,
                idealHeight: 220,
                maxHeight: 240
            )

            if let personalizationMessage {
                Text(personalizationMessage)
                    .font(.system(size: QuickPiTypography.settingsSize))
                    .foregroundStyle(personalizationMessageIsError ? Color.red : Color.green)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .background(Color.quickPiWindowBackground)
    }

    private var providersTab: some View {
        Group {
            if showingProviderForm {
                providerForm
            } else {
                providerList
            }
        }
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("自定义 Provider")
                            .font(.system(size: QuickPiTypography.settingsSize, weight: .semibold))

                        if state.settings.providers.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.dashed")
                                Text("尚未添加自定义 Provider")
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .background(
                                Color.quickPiControlBackground,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                            }
                        } else {
                            LazyVGrid(columns: providerGridColumns, alignment: .leading, spacing: 12) {
                                ForEach(state.settings.providers) { item in
                                    customProviderCard(item)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("内置 Provider")
                            .font(.system(size: QuickPiTypography.settingsSize, weight: .semibold))

                        LazyVGrid(columns: providerGridColumns, alignment: .leading, spacing: 12) {
                            ForEach(state.providerOptions.filter { item in
                                !state.settings.providers.contains { $0.id == item.id }
                            }) { item in
                                builtInProviderCard(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .scrollIndicators(.visible)
            .background(Color.quickPiWindowBackground)

            if let providerMessage {
                Divider()
                Text(providerMessage)
                    .font(.system(size: QuickPiTypography.settingsSize))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
        }
    }

    private var providerForm: some View {
        Form {
            Section("推荐服务") {
                Link(destination: URL(string: "https://codeingforce.com")!) {
                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .font(.system(size: 17))
                            .foregroundStyle(.orange)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Coding Force 中转站")
                                .font(.system(size: QuickPiTypography.settingsSize, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text("codeingforce.com")
                                .font(.system(size: QuickPiTypography.settingsSize))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("访问 Coding Force 中转站")
            }

            Section {
                LabeledContent("接口类型") {
                    Picker("", selection: $provider.kind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    .accessibilityLabel("接口类型")
                }

                LabeledContent("名称") {
                    TextField("", text: $provider.name)
                        .accessibilityLabel("名称")
                        .frame(width: 280)
                }

                LabeledContent("Base URL") {
                    TextField("", text: $provider.baseURL)
                        .accessibilityLabel("Base URL")
                        .frame(width: 280)
                }

                LabeledContent("API Key") {
                    SecureField("", text: $apiKey)
                        .accessibilityLabel("API Key")
                        .frame(width: 280)
                }
            }
            .disabled(syncingModels || savingProvider)

            Section("模型") {
                HStack {
                    Text(provider.models.isEmpty ? "尚未同步模型" : "\(provider.models.count) 个可用模型")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        Task { await syncProviderModels() }
                    } label: {
                        if syncingModels {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("同步模型", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(
                        syncingModels
                            || savingProvider
                            || (!isEditingProvider
                                && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                }

                if !provider.models.isEmpty {
                    Picker("使用模型", selection: $selectedModelId) {
                        ForEach(provider.models, id: \.self) { modelId in
                            Text(modelId).tag(modelId)
                        }
                    }

                    Toggle("支持推理", isOn: Binding(
                        get: { provider.modelThinkingLevels?[selectedModelId] != nil },
                        set: { supportsReasoning in
                            guard !selectedModelId.isEmpty else {
                                return
                            }
                            var configurations = provider.modelThinkingLevels ?? [:]
                            if supportsReasoning {
                                configurations[selectedModelId] = [
                                    .off, .minimal, .low, .medium, .high,
                                ]
                            } else {
                                configurations.removeValue(forKey: selectedModelId)
                            }
                            provider.modelThinkingLevels = configurations
                        }
                    ))
                    .disabled(syncingModels || savingProvider)

                    if let levels = provider.modelThinkingLevels?[selectedModelId] {
                        LabeledContent("可用强度") {
                            Menu {
                                ForEach(ThinkingLevel.allCases, id: \.self) { level in
                                    Toggle(level.title, isOn: thinkingLevelBinding(level))
                                }
                            } label: {
                                Text(levels.map(\.title).joined(separator: "、"))
                                    .lineLimit(1)
                            }
                            .frame(width: 280, alignment: .trailing)
                        }
                        .disabled(syncingModels || savingProvider)
                    }
                }
            }

            if let providerMessage {
                Text(providerMessage)
                    .font(.system(size: QuickPiTypography.settingsSize))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        Task { await saveProvider() }
                    } label: {
                        if savingProvider {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("保存 Provider")
                        }
                    }
                    .buttonStyle(SettingsActionButtonStyle(prominence: .primary))
                    .disabled(
                        provider.models.isEmpty
                            || selectedModelId.isEmpty
                            || (!isEditingProvider
                                && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            || syncingModels
                            || savingProvider
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.quickPiWindowBackground)
        .onChange(of: provider.kind) { _, _ in resetSyncedModels() }
        .onChange(of: provider.baseURL) { _, _ in resetSyncedModels() }
        .onChange(of: apiKey) { _, _ in resetSyncedModels() }
    }

    private func editableLines(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func operationApprovalDraft() -> OperationApprovalConfiguration {
        OperationApprovalConfiguration(
            enabled: approvalEnabled,
            toolNames: editableLines(in: approvalToolNames),
            approveAllShellCommands: approveAllShellCommands,
            shellCommandKeywords: editableLines(in: shellCommandKeywords)
        )
    }

    private func applyOperationApprovalDraft(_ configuration: OperationApprovalConfiguration) {
        approvalEnabled = configuration.enabled
        approvalToolNames = configuration.toolNames.joined(separator: "\n")
        approveAllShellCommands = configuration.approveAllShellCommands
        shellCommandKeywords = configuration.shellCommandKeywords.joined(separator: "\n")
    }

    private func saveSecuritySettings() {
        guard !savingSecurity else {
            return
        }
        savingSecurity = true
        securityMessage = nil
        do {
            try state.saveOperationApprovalSettings(operationApprovalDraft())
            applyOperationApprovalDraft(state.settings.operationApproval)
            securityMessage = "已保存"
            securityMessageIsError = false
        } catch {
            securityMessage = error.localizedDescription
            securityMessageIsError = true
        }
        savingSecurity = false
    }

    // Reads the native Pi context file once when the settings window opens.
    private func loadAgentInstructions() {
        guard loadingAgentInstructions else {
            return
        }
        do {
            let instructions = try state.loadAgentInstructions()
            agentInstructions = instructions
            savedAgentInstructions = instructions
            personalizationMessage = nil
        } catch {
            personalizationMessage = error.localizedDescription
            personalizationMessageIsError = true
        }
        loadingAgentInstructions = false
    }

    // Saves the Markdown exactly as entered; AppState owns runtime restart coordination.
    private func savePersonalizationSettings() {
        guard !loadingAgentInstructions && !savingAgentInstructions else {
            return
        }
        savingAgentInstructions = true
        personalizationMessage = nil
        do {
            let saved = try state.saveAgentInstructions(agentInstructions)
            agentInstructions = saved
            savedAgentInstructions = saved
            personalizationMessage = "已保存"
            personalizationMessageIsError = false
        } catch {
            personalizationMessage = error.localizedDescription
            personalizationMessageIsError = true
        }
        savingAgentInstructions = false
    }

    // Persists one control change immediately and restores the disk values if macOS rejects it.
    private func persistGeneralSettings(
        shortcut nextShortcut: String,
        launchAtLogin nextLaunchAtLogin: Bool,
        fillInputFromClipboardOnShortcut nextFillInputFromClipboardOnShortcut: Bool
    ) {
        guard !savingGeneral else {
            return
        }
        shortcut = nextShortcut
        launchAtLogin = nextLaunchAtLogin
        fillInputFromClipboardOnShortcut = nextFillInputFromClipboardOnShortcut
        savingGeneral = true
        generalMessage = nil
        Task {
            do {
                try await state.saveDesktopSettings(
                    shortcut: nextShortcut,
                    launchAtLogin: nextLaunchAtLogin,
                    fillInputFromClipboardOnShortcut: nextFillInputFromClipboardOnShortcut
                )
            } catch {
                shortcut = state.settings.shortcut
                launchAtLogin = state.settings.launchAtLogin
                fillInputFromClipboardOnShortcut = state.settings.fillInputFromClipboardOnShortcut
                generalMessage = error.localizedDescription
            }
            savingGeneral = false
        }
    }

    // Fetches the exact model list before the Provider can be persisted.
    private func syncProviderModels() async {
        guard !syncingModels && !savingProvider else {
            return
        }
        syncingModels = true
        defer { syncingModels = false }
        providerMessage = nil
        do {
            let models = try await state.syncModels(
                kind: provider.kind,
                baseURL: provider.baseURL,
                apiKey: apiKey,
                providerId: provider.id
            )
            provider.models = models
            if let modelThinkingLevels = provider.modelThinkingLevels {
                provider.modelThinkingLevels = modelThinkingLevels.filter {
                    models.contains($0.key)
                }
            }
            selectedModelId = models[0]
        } catch {
            provider.models = []
            provider.modelThinkingLevels = [:]
            selectedModelId = ""
            providerMessage = error.localizedDescription
        }
    }

    // Persists the synchronized Provider and closes the form once the disk write succeeds.
    private func saveProvider() async {
        guard !syncingModels && !savingProvider else {
            return
        }
        savingProvider = true
        defer { savingProvider = false }
        providerMessage = nil
        do {
            try state.saveProvider(
                provider,
                apiKey: apiKey,
                selectedModelId: selectedModelId
            )
            showingProviderForm = false
            provider = ProviderConfiguration(
                id: "custom-\(UUID().uuidString.lowercased())",
                kind: .openAI,
                name: "",
                baseURL: "",
                models: [],
                modelThinkingLevels: [:]
            )
            apiKey = ""
            selectedModelId = ""
        } catch {
            providerMessage = error.localizedDescription
        }
    }

    // Invalidates a model catalog as soon as any connection field changes.
    private func resetSyncedModels() {
        provider.models = []
        provider.modelThinkingLevels = [:]
        selectedModelId = ""
        providerMessage = nil
    }

    // Updates one exact Pi level while keeping the Provider capability list ordered and valid.
    private func thinkingLevelBinding(_ level: ThinkingLevel) -> Binding<Bool> {
        Binding(
            get: {
                provider.modelThinkingLevels?[selectedModelId]?.contains(level) == true
            },
            set: { enabled in
                guard !selectedModelId.isEmpty,
                      var configurations = provider.modelThinkingLevels,
                      let configuredLevels = configurations[selectedModelId] else {
                    return
                }
                var selectedLevels = Set(configuredLevels)
                if enabled {
                    selectedLevels.insert(level)
                } else {
                    selectedLevels.remove(level)
                }
                let orderedLevels = ThinkingLevel.allCases.filter(selectedLevels.contains)
                if orderedLevels.contains(where: { $0 != .off }) {
                    configurations[selectedModelId] = orderedLevels
                } else {
                    configurations.removeValue(forKey: selectedModelId)
                }
                provider.modelThinkingLevels = configurations
            }
        )
    }

    // Shows one disk-backed custom Provider and its local management actions.
    private func customProviderCard(_ item: ProviderConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ProviderBrandIcon(id: item.id, name: item.name)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text("\(item.kind.title) · \(item.models.count) 个模型")
                        .font(.system(size: QuickPiTypography.settingsSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if state.settings.selectedModel?.providerId == item.id {
                    Label("当前", systemImage: "checkmark.circle.fill")
                        .font(.system(size: QuickPiTypography.settingsSize))
                        .foregroundStyle(.green)
                }

                Spacer(minLength: 0)

                Button {
                    provider = item
                    apiKey = ""
                    if let selection = state.settings.selectedModel,
                       selection.providerId == item.id,
                       item.models.contains(selection.modelId) {
                        selectedModelId = selection.modelId
                    } else {
                        selectedModelId = item.models.first ?? ""
                    }
                    providerMessage = nil
                    showingProviderForm = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(SettingsIconButtonStyle())
                .help("编辑 Provider")

                Button {
                    Task {
                        do {
                            try state.deleteProvider(id: item.id)
                            providerMessage = nil
                        } catch {
                            providerMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(SettingsIconButtonStyle(tint: .red))
                .help("删除 Provider")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(
            Color.quickPiControlBackground,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    // Shows one built-in Provider and the authentication methods it supports.
    private func builtInProviderCard(_ item: ProviderStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ProviderBrandIcon(id: item.id, name: item.name)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(item.configured ? "已连接" : item.id)
                        .font(.system(size: QuickPiTypography.settingsSize))
                        .foregroundStyle(item.configured ? Color.green : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            if item.configured {
                HStack {
                    Spacer()
                    Button {
                        Task { await state.logout(providerId: item.id) }
                    } label: {
                        Label("退出", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(SettingsActionButtonStyle(compact: true))
                }
            } else if item.supportsAPIKeyLogin || item.supportsOAuthLogin {
                HStack(spacing: 8) {
                    if item.supportsAPIKeyLogin {
                        ProviderAuthButton(title: "API Key", systemImage: "key.fill") {
                            state.startAuth(provider: item, type: "api_key")
                        }
                    }
                    if item.supportsOAuthLogin {
                        ProviderAuthButton(title: "登录", systemImage: "person.crop.circle.badge.checkmark") {
                            state.startAuth(provider: item, type: "oauth")
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(
            Color.quickPiControlBackground,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }
}

private enum SettingsButtonProminence: Equatable {
    case standard
    case primary
}

private struct SettingsActionButtonStyle: ButtonStyle {
    var prominence = SettingsButtonProminence.standard
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPrimary = prominence == .primary
        configuration.label
            .font(.system(size: QuickPiTypography.settingsSize, weight: .medium))
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(minHeight: compact ? 30 : 32)
            .background(
                isPrimary
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1)
                    : Color.quickPiControlBackground,
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

private struct SettingsIconButtonStyle: ButtonStyle {
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

private struct ProviderAuthButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 15)
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: QuickPiTypography.settingsSize, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .foregroundStyle(Color.primary.opacity(0.9))
        .background(
            isHovering ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isHovering ? Color.accentColor.opacity(0.42) : Color.primary.opacity(0.16),
                    lineWidth: 1
                )
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(title)
    }
}

private struct ProviderBrandIcon: View {
    let id: String
    let name: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let imageResourceName, let image = brandImage(named: imageResourceName) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    private var imageResourceName: String? {
        guard let resourceName else {
            return nil
        }
        guard Self.themedResourceNames.contains(resourceName) else {
            return resourceName
        }
        let appearance = colorScheme == .dark ? "dark" : "light"
        return "\(resourceName)-\(appearance)"
    }

    private static let themedResourceNames: Set<String> = [
        "anthropic",
        "github-copilot",
        "groq",
        "openai",
        "opencode",
        "vercel",
        "xai",
        "xiaomi-mimo",
        "zai",
    ]

    private var resourceName: String? {
        let value = "\(id) \(name)".lowercased()
        if value.contains("github") || value.contains("copilot") {
            return "github-copilot"
        }
        if value.contains("anthropic") || value.contains("claude") {
            return "anthropic"
        }
        if value.contains("azure") {
            return "azure-openai"
        }
        if value.contains("codex") {
            return "openai-codex"
        }
        if value.contains("openai") || value.contains("chatgpt") {
            return "openai"
        }
        if value.contains("deepseek") {
            return "deepseek"
        }
        if value.contains("nvidia") {
            return "nvidia"
        }
        if value.contains("vertex") {
            return "google-vertex"
        }
        if value.contains("google cloud") || value.contains("google-cloud") {
            return "google-cloud"
        }
        if value.contains("google") || value.contains("gemini") {
            return "google-gemini"
        }
        if value.contains("amazon") || value.contains("bedrock") {
            return "amazon-bedrock"
        }
        if value.contains("mistral") {
            return "mistral"
        }
        if value.contains("groq") {
            return "groq"
        }
        if value.contains("cerebras") {
            return "cerebras"
        }
        if value.contains("cloudflare") && value.contains("worker") {
            return "cloudflare-workers"
        }
        if value.contains("cloudflare") {
            return "cloudflare"
        }
        if value.contains("openrouter") {
            return "openrouter"
        }
        if value.contains("vercel") {
            return "vercel"
        }
        if value.contains("opencode") {
            return "opencode"
        }
        if value.contains("huggingface") || value.contains("hugging face") {
            return "huggingface"
        }
        if value.contains("fireworks") {
            return "fireworks"
        }
        if value.contains("together") {
            return "together"
        }
        if value.contains("kimi") || value.contains("moonshot") {
            return "kimi"
        }
        if value.contains("minimax") {
            return "minimax"
        }
        if value.contains("qwen") {
            return "qwen"
        }
        if value.contains("xiaomi") || value.contains("mimo") {
            return "xiaomi-mimo"
        }
        if value.contains("xai") || value.contains("grok") {
            return "xai"
        }
        if value.contains("zai") {
            return "zai"
        }
        if value.contains("ant-ling") || value.contains("ant ling") {
            return "ant-ling"
        }
        return nil
    }

    private func brandImage(named resourceName: String) -> NSImage? {
        if let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "png",
            subdirectory: "ProviderIcons"
        ), let image = NSImage(contentsOf: url) {
            return image
        }
#if SWIFT_PACKAGE
        if let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: "png",
            subdirectory: "ProviderIcons"
        ) {
            return NSImage(contentsOf: url)
        }
#endif
        return nil
    }
}

private struct AuthView: View {
    @ObservedObject var state: AppState
    @State private var value = ""

    var body: some View {
        Group {
            if let session = state.authSession,
               let prompt = session.prompt,
               prompt.type == "select" {
                PromptChoicePanel(
                    title: prompt.message,
                    subtitle: "连接 \(session.providerName)",
                    choices: prompt.options.enumerated().map { index, option in
                        PromptChoiceItem(
                            id: index,
                            title: option.label,
                            description: option.description,
                            recommended: false
                        )
                    },
                    onSelect: { index in
                        guard prompt.options.indices.contains(index) else {
                            return
                        }
                        state.respondToAuth(value: prompt.options[index].id)
                    },
                    onCancel: state.cancelAuth
                )
            } else if let session = state.authSession {
                standardAuthView(session)
            }
        }
        .background(Color.quickPiWindowBackground)
        .buttonStyle(SettingsActionButtonStyle())
        .onChange(of: state.authSession?.prompt) { _, _ in
            value = ""
        }
    }

    private func standardAuthView(_ session: AuthSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接 \(session.providerName)")
                .font(.system(size: QuickPiTypography.settingsSize, weight: .semibold))

            if let event = session.event {
                authEvent(event)
            }
            if let prompt = session.prompt {
                promptView(prompt)
            } else if session.event == nil && session.error == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在准备登录")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = session.error {
                Text(error)
                    .font(.system(size: QuickPiTypography.settingsSize))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Spacer()
            HStack {
                Spacer()
                Button("取消") {
                    state.cancelAuth()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 330)
    }

    // Renders the provider-owned OAuth status and verified external links.
    @ViewBuilder
    private func authEvent(_ event: AuthEvent) -> some View {
        switch event {
        case .info(let message, let links):
            Text(message)
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                Button(link.label ?? "打开链接") {
                    state.openExternal(link.url)
                }
            }
        case .authURL(let url, let instructions):
            if let instructions {
                Text(instructions)
                    .foregroundStyle(.secondary)
            }
            Button("打开授权页面", systemImage: "arrow.up.right.square") {
                state.openExternal(url)
            }
            .buttonStyle(SettingsActionButtonStyle(prominence: .primary))
        case .deviceCode(let userCode, let verificationURI):
            Text(userCode)
                .font(.system(size: QuickPiTypography.settingsSize, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            Button("打开验证页面", systemImage: "arrow.up.right.square") {
                state.openExternal(verificationURI)
            }
            .buttonStyle(SettingsActionButtonStyle(prominence: .primary))
        case .progress(let message):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
            }
        }
    }

    // Presents the exact secret, text, or option selection requested by Pi.
    @ViewBuilder
    private func promptView(_ prompt: AuthPrompt) -> some View {
        if prompt.type == "select" {
            Text(prompt.message)
                .font(.system(size: QuickPiTypography.settingsSize, weight: .medium))
            ForEach(prompt.options, id: \.id) { option in
                Button {
                    state.respondToAuth(value: option.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                        if let description = option.description {
                            Text(description)
                                .font(.system(size: QuickPiTypography.settingsSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text(prompt.message)
                .font(.system(size: QuickPiTypography.settingsSize, weight: .medium))
            if prompt.type == "secret" {
                SecureField(prompt.placeholder ?? "", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit(prompt) }
            } else {
                TextField(prompt.placeholder ?? "", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit(prompt) }
            }
            Button("继续") {
                submit(prompt)
            }
            .buttonStyle(SettingsActionButtonStyle(prominence: .primary))
            .disabled(value.isEmpty)
        }
    }

    // Returns a non-empty authentication value to its matching request id.
    private func submit(_ prompt: AuthPrompt) {
        guard !value.isEmpty else {
            return
        }
        state.respondToAuth(value: value)
    }
}
