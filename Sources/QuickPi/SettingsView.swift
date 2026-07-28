import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var shortcut: String
    @State private var launchAtLogin: Bool
    @State private var terminalAccess: Bool
    @State private var fileSystemAccess: Bool
    @State private var generalMessage: String?
    @State private var showingProviderForm = false
    @State private var provider = ProviderConfiguration(
        id: "custom-\(UUID().uuidString.lowercased())",
        kind: .openAI,
        name: "",
        baseURL: "",
        models: []
    )
    @State private var apiKey = ""
    @State private var selectedModelId = ""
    @State private var syncingModels = false
    @State private var savingProvider = false
    @State private var providerMessage: String?

    // Seeds editable controls from the settings document loaded from disk.
    init(state: AppState) {
        self.state = state
        _shortcut = State(initialValue: state.settings.shortcut)
        _launchAtLogin = State(initialValue: state.settings.launchAtLogin)
        _terminalAccess = State(initialValue: state.settings.terminalAccess)
        _fileSystemAccess = State(initialValue: state.settings.fileSystemAccess)
    }

    private var isEditingProvider: Bool {
        state.settings.providers.contains { $0.id == provider.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(syncingModels || savingProvider)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)

            Divider()

            TabView {
                generalTab
                    .tabItem { Label("通用", systemImage: "gearshape") }
                providersTab
                    .tabItem { Label("Provider", systemImage: "server.rack") }
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
        .interactiveDismissDisabled(syncingModels || savingProvider)
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
                Picker("全局快捷键", selection: $shortcut) {
                    Text("⌘ ⇧ Space").tag("commandShiftSpace")
                    Text("⌥ Space").tag("optionSpace")
                    Text("⌃ Space").tag("controlSpace")
                    Text("⌘ ⌥ Space").tag("commandOptionSpace")
                }
                Toggle("登录后自动启动", isOn: $launchAtLogin)
            }

            Section("Pi 权限") {
                Toggle(isOn: $terminalAccess) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("终端")
                        Text("允许 Pi 执行 shell 命令，终端本身包含文件系统访问")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: terminalAccess) { _, enabled in
                    if enabled {
                        fileSystemAccess = true
                    }
                }
                Toggle(isOn: $fileSystemAccess) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("文件系统")
                        Text("允许 Pi 使用专用工具读取、搜索和修改文件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(terminalAccess)
            }

            Section("软件更新") {
                Button {
                    state.checkForUpdates()
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Section {
                HStack {
                    Button("保存") {
                        Task { await saveGeneralSettings() }
                    }
                    .buttonStyle(.borderedProminent)
                    if let generalMessage {
                        Text(generalMessage)
                            .font(.caption)
                            .foregroundStyle(generalMessage == "已保存" ? Color.secondary : Color.red)
                    }
                }
                if let shortcutError = state.shortcutError {
                    Text(shortcutError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var providersTab: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Provider")
                    .font(.headline)
                Spacer()
                Button {
                    if showingProviderForm {
                        showingProviderForm = false
                    } else {
                        provider = ProviderConfiguration(
                            id: "custom-\(UUID().uuidString.lowercased())",
                            kind: .openAI,
                            name: "",
                            baseURL: "",
                            models: []
                        )
                        apiKey = ""
                        selectedModelId = ""
                        providerMessage = nil
                        showingProviderForm = true
                    }
                } label: {
                    Image(systemName: showingProviderForm ? "xmark" : "plus")
                }
                .buttonStyle(.plain)
                .disabled(syncingModels || savingProvider)
                .help(showingProviderForm ? "关闭" : "添加自定义 Provider")
            }

            if showingProviderForm {
                providerForm
            } else {
                providerList
            }
        }
    }

    private var providerList: some View {
        VStack(spacing: 8) {
            List(state.providerOptions) { item in
                if let stored = state.settings.providers.first(where: { $0.id == item.id }) {
                    customProviderRow(stored)
                } else {
                    builtInProviderRow(item)
                }
            }
            .listStyle(.inset)
            .overlay {
                if state.providerOptions.isEmpty {
                    ContentUnavailableView("没有可用 Provider", systemImage: "server.rack")
                }
            }

            if let providerMessage {
                Text(providerMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var providerForm: some View {
        Form {
            Group {
                Picker("类型", selection: $provider.kind) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                TextField("名称", text: $provider.name)
                TextField(
                    provider.kind == .openAI
                        ? "Base URL，例如 https://api.openai.com/v1"
                        : "Base URL，例如 https://api.anthropic.com",
                    text: $provider.baseURL
                )
                SecureField(
                    isEditingProvider ? "API Key（留空则保留已保存的 Key）" : "API Key",
                    text: $apiKey
                )
            }
            .disabled(syncingModels || savingProvider)

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

            if !provider.models.isEmpty {
                Picker("使用模型", selection: $selectedModelId) {
                    ForEach(provider.models, id: \.self) { modelId in
                        Text(modelId).tag(modelId)
                    }
                }
            }

            if let providerMessage {
                Text(providerMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

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
        .formStyle(.grouped)
        .onChange(of: provider.kind) { _, _ in resetSyncedModels() }
        .onChange(of: provider.baseURL) { _, _ in resetSyncedModels() }
        .onChange(of: apiKey) { _, _ in resetSyncedModels() }
    }

    // Saves general settings and reports disk or macOS service errors in the same form.
    private func saveGeneralSettings() async {
        generalMessage = nil
        do {
            try await state.saveDesktopSettings(
                shortcut: shortcut,
                launchAtLogin: launchAtLogin,
                terminalAccess: terminalAccess,
                fileSystemAccess: fileSystemAccess
            )
            generalMessage = "已保存"
        } catch {
            generalMessage = error.localizedDescription
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
            selectedModelId = models[0]
        } catch {
            provider.models = []
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
                models: []
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
        selectedModelId = ""
        providerMessage = nil
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
