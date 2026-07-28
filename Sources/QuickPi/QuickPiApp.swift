import AppKit
import Carbon
import Sparkle
import SwiftUI

private let panelMinimumWidth: CGFloat = 520

private let hotKeyHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else {
        return OSStatus(eventNotHandledErr)
    }
    Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue().invoke()
    return noErr
}

final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var identifier: UInt32 = 0
    private let action: () -> Void

    // Installs one process-wide Carbon handler for the app's global shortcut.
    init(action: @escaping () -> Void) throws {
        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else {
            throw QuickPiError.message("全局快捷键监听器注册失败（\(status)）")
        }
    }

    deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    // Registers one supported shortcut only after macOS accepts it.
    func register(_ shortcut: String) throws {
        let modifiers: UInt32
        switch shortcut {
        case "commandShiftSpace":
            modifiers = UInt32(cmdKey | shiftKey)
        case "optionSpace":
            modifiers = UInt32(optionKey)
        case "controlSpace":
            modifiers = UInt32(controlKey)
        case "commandOptionSpace":
            modifiers = UInt32(cmdKey | optionKey)
        default:
            throw QuickPiError.message("不支持的全局快捷键")
        }

        let nextIdentifier = identifier + 1
        let hotKeyId = EventHotKeyID(signature: OSType(0x51504920), id: nextIdentifier)
        var nextHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            modifiers,
            hotKeyId,
            GetApplicationEventTarget(),
            0,
            &nextHotKey
        )
        guard status == noErr else {
            throw QuickPiError.message("该快捷键已被其他应用占用")
        }
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        hotKey = nextHotKey
        identifier = nextIdentifier
    }

    // Invokes the Swift closure from the Carbon callback.
    fileprivate func invoke() {
        action()
    }
}

private final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Hides the launcher when the standard cancel action is sent.
    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var panel: QuickPanel?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var shortcut: GlobalShortcut?
    private var state: AppState?
    private var resultContentHeight: CGFloat = 441

    // Creates the menu-bar app, native panel, global shortcut, and managed Pi runtime.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()

        guard let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            presentFatalError("无法读取 Application Support 目录")
            return
        }

        do {
            let appState = try AppState(
                applicationSupportDirectory: baseDirectory.appendingPathComponent("Quick Pi", isDirectory: true),
                checkForUpdates: { [unowned self] in
                    self.updaterController.checkForUpdates(nil)
                },
                presentSettings: { [unowned self] in
                    self.showSettings()
                }
            )
            state = appState
            createPanel(state: appState)
            createSettingsWindow(state: appState)
            createStatusItem()
            shortcut = try GlobalShortcut { [weak self] in
                self?.togglePanel()
            }
            appState.applyShortcut = { [weak self] value in
                guard let shortcut = self?.shortcut else {
                    throw QuickPiError.message("全局快捷键尚未初始化")
                }
                try shortcut.register(value)
            }
            appState.panelContentChanged = { [weak self] in
                self?.updatePanelSize()
            }
            do {
                try shortcut?.register(appState.settings.shortcut)
            } catch {
                appState.shortcutError = error.localizedDescription
            }
            showPanel()
            if appState.shortcutError != nil {
                showSettings()
            }
            Task { await appState.start() }
        } catch {
            presentFatalError(error.localizedDescription)
        }
    }

    // Stops the subprocess before macOS tears down the menu-bar application.
    func applicationWillTerminate(_ notification: Notification) {
        state?.stop()
    }

    // Hides the panel instead of terminating its accessory application.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // Preserves only user-driven result height changes while streamed events continue updating the panel.
    func windowDidResize(_ notification: Notification) {
        guard let panel,
              let state,
              let resizedWindow = notification.object as? NSWindow,
              resizedWindow === panel,
              panel.inLiveResize,
              state.showsResultPanel else {
            return
        }
        let inputHeight: CGFloat = state.attachments.isEmpty ? 102 : 140
        resultContentHeight = panel.contentLayoutRect.height - inputHeight
    }

    // Installs standard text actions so every native text field supports normal shortcuts.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    // Hosts the compact SwiftUI launcher in a borderless floating AppKit panel.
    private func createPanel(state: AppState) {
        let panel = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 102),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quick Pi"
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: panelMinimumWidth, height: 102)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ChatView(state: state))
        self.panel = panel
    }

    // Hosts settings in a titled standalone window so it remains draggable and non-modal.
    private func createSettingsWindow(state: AppState) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(
            rootView: SettingsView(state: state) { [unowned window] in
                window.close()
            }
        )
        window.center()
        settingsWindow = window
    }

    // Creates a left-click launcher and a right-click application menu.
    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else {
            presentFatalError("无法创建菜单栏入口")
            return
        }
        button.image = NSImage(
            systemSymbolName: "bubble.left.and.bubble.right.fill",
            accessibilityDescription: "Quick Pi"
        )
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menu = NSMenu()
        menu.addItem(withTitle: "打开 Quick Pi", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(withTitle: "设置", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items {
            menuItem.target = self
        }
        statusMenu = menu
        statusItem = item
    }

    // Toggles the launcher on a normal click and opens commands on a secondary click.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp, let statusMenu {
            statusItem?.menu = statusMenu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePanel()
        }
    }

    // Opens and focuses the quick question panel.
    @objc private func openPanel() {
        showPanel()
    }

    // Opens settings from the menu-bar command.
    @objc private func openSettings() {
        showSettings()
    }

    // Opens Sparkle's standard user-initiated update flow.
    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    // Terminates through the normal NSApplication lifecycle.
    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // Switches between the hidden and focused launcher states.
    private func togglePanel() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
        } else {
            showPanel()
        }
    }

    // Activates the accessory app and moves keyboard focus into the prompt.
    private func showPanel() {
        positionPanelAtTopCenter()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .quickPiFocusInput, object: nil)
    }

    // Activates and focuses the independent settings window without changing the launcher.
    private func showSettings() {
        guard let settingsWindow else {
            preconditionFailure("设置窗口必须在打开前创建")
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    // Expands results downward while keeping the input bar's top edge stationary.
    private func updatePanelSize() {
        guard let panel, let state else {
            return
        }
        let inputHeight: CGFloat = state.attachments.isEmpty ? 102 : 140
        let targetHeight: CGFloat
        if state.showsResultPanel {
            panel.contentMinSize = NSSize(width: panelMinimumWidth, height: inputHeight + 241)
            targetHeight = inputHeight + resultContentHeight
        } else {
            panel.contentMinSize = NSSize(width: panelMinimumWidth, height: inputHeight)
            targetHeight = inputHeight
        }
        guard panel.frame.height != targetHeight else {
            return
        }
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = targetHeight
        frame.origin.y = top - targetHeight
        panel.setFrame(frame, display: true, animate: true)
    }

    // Places the panel near the top center of the screen containing the pointer.
    private func positionPanelAtTopCenter() {
        guard let panel else {
            return
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(pointer, $0.frame, false)
        }) else {
            return
        }
        let visibleFrame = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = visibleFrame.midX - frame.width / 2
        frame.origin.y = visibleFrame.maxY - 96 - frame.height
        panel.setFrame(frame, display: false)
    }

    // Presents startup failures that make the menu-bar app unusable.
    private func presentFatalError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Quick Pi 无法启动"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}

@main
enum QuickPiApplication {
    // Starts the AppKit lifecycle without creating an unused SwiftUI window scene.
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
