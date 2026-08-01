import SwiftUI

private enum SettingsPane {
    case general
    case providers
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showSystemStatus") private var showSystemStatus = true
    @AppStorage("hidePanelWhenInactive") private var hidePanelWhenInactive = false
    @State private var selectedPane: SettingsPane = .general
    @State private var shortcut: String
    @State private var launchAtLogin: Bool
    @State private var savingGeneral = false
    @State private var generalMessage: String?
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
            .background(Color.white)

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Group {
                        if selectedPane == .general {
                            Text("通用")
                        } else if showingProviderForm {
                            Text(isEditingProvider ? "编辑 Provider" : "添加 Provider")
                        } else {
                            Text("Provider")
                        }
                    }
                    .font(.title3.weight(.semibold))

                    if selectedPane == .general && savingGeneral {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

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
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
                    .disabled(savingGeneral || syncingModels || savingProvider)
                    .help("关闭设置")
                }
                .padding(.horizontal, 24)
                .frame(height: 64)

                Divider()

                if selectedPane == .general {
                    generalTab
                } else {
                    providersTab
                }
            }
        }
        .frame(width: 780, height: 660)
        .background(Color.white)
        .preferredColorScheme(.light)
        .interactiveDismissDisabled(savingGeneral || syncingModels || savingProvider)
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
                            launchAtLogin: launchAtLogin
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
                            launchAtLogin: enabled
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
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let shortcutError = state.shortcutError {
                        Text(shortcutError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .disabled(savingGeneral)
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
            List {
                Section("自定义 Provider") {
                    if state.settings.providers.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.dashed")
                            Text("尚未添加自定义 Provider")
                        }
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                    } else {
                        ForEach(state.settings.providers) { item in
                            customProviderRow(item)
                        }
                    }
                }

                Section("内置 Provider") {
                    ForEach(state.providerOptions.filter { item in
                        !state.settings.providers.contains { $0.id == item.id }
                    }) { item in
                        builtInProviderRow(item)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Color.white)

            if let providerMessage {
                Divider()
                Text(providerMessage)
                    .font(.caption)
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
                            .font(.title2)
                            .foregroundStyle(.orange)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Coding Force 中转站")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("codeingforce.com")
                                .font(.caption)
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
                    .font(.caption)
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
                    .buttonStyle(.borderedProminent)
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
        .background(Color.white)
        .onChange(of: provider.kind) { _, _ in resetSyncedModels() }
        .onChange(of: provider.baseURL) { _, _ in resetSyncedModels() }
        .onChange(of: apiKey) { _, _ in resetSyncedModels() }
    }

    // Persists one control change immediately and restores the disk values if macOS rejects it.
    private func persistGeneralSettings(
        shortcut nextShortcut: String,
        launchAtLogin nextLaunchAtLogin: Bool
    ) {
        guard !savingGeneral else {
            return
        }
        shortcut = nextShortcut
        launchAtLogin = nextLaunchAtLogin
        savingGeneral = true
        generalMessage = nil
        Task {
            do {
                try await state.saveDesktopSettings(
                    shortcut: nextShortcut,
                    launchAtLogin: nextLaunchAtLogin
                )
            } catch {
                shortcut = state.settings.shortcut
                launchAtLogin = state.settings.launchAtLogin
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

    // Shows one disk-backed custom Provider and deletes it from all app-owned files.
    private func customProviderRow(_ item: ProviderConfiguration) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .lineLimit(1)
                Text("\(item.kind.title) · \(item.models.count) 个模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.settings.selectedModel?.providerId == item.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("当前 Provider")
            }
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
            .buttonStyle(.plain)
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
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("删除 Provider")
        }
        .padding(.vertical, 3)
    }

    // Shows authentication actions reported by a built-in Pi Provider.
    private func builtInProviderRow(_ item: ProviderStatus) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .lineLimit(1)
                Text(item.configured ? "已连接" : item.id)
                    .font(.caption)
                    .foregroundStyle(item.configured ? Color.green : Color.secondary)
            }
            Spacer()
            if item.configured {
                Button("退出") {
                    Task { await state.logout(providerId: item.id) }
                }
                .controlSize(.small)
            } else {
                if item.supportsAPIKeyLogin {
                    Button("API Key") {
                        state.startAuth(provider: item, type: "api_key")
                    }
                    .controlSize(.small)
                }
                if item.supportsOAuthLogin {
                    Button("登录") {
                        state.startAuth(provider: item, type: "oauth")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct AuthView: View {
    @ObservedObject var state: AppState
    @State private var value = ""

    var body: some View {
        Group {
            if let session = state.authSession {
                VStack(alignment: .leading, spacing: 16) {
                    Text("连接 \(session.providerName)")
                        .font(.headline)

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
                            .font(.caption)
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
            }
        }
        .frame(width: 400, height: 330)
        .background(Color.white)
        .preferredColorScheme(.light)
        .onChange(of: state.authSession?.prompt) { _, _ in
            value = ""
        }
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
            .buttonStyle(.borderedProminent)
        case .deviceCode(let userCode, let verificationURI):
            Text(userCode)
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .textSelection(.enabled)
            Button("打开验证页面", systemImage: "arrow.up.right.square") {
                state.openExternal(verificationURI)
            }
            .buttonStyle(.borderedProminent)
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
                .font(.subheadline.weight(.medium))
            ForEach(prompt.options, id: \.id) { option in
                Button {
                    state.respondToAuth(value: option.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                        if let description = option.description {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text(prompt.message)
                .font(.subheadline.weight(.medium))
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
            .buttonStyle(.borderedProminent)
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
