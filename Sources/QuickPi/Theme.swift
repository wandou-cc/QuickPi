import AppKit
import SwiftUI

enum QuickPiTheme: String, CaseIterable, Identifiable {
    static let storageKey = "quickPiTheme"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

private extension NSColor {
    static let quickPiWindowBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .windowBackgroundColor
            : .white
    }

    static let quickPiControlBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .controlBackgroundColor
            : .white
    }
}

extension Color {
    static let quickPiWindowBackground = Color(nsColor: .quickPiWindowBackground)
    static let quickPiControlBackground = Color(nsColor: .quickPiControlBackground)
}
