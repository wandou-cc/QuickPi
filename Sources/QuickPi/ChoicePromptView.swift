import SwiftUI

struct PromptChoiceItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let description: String?
    let recommended: Bool
}

// Keeps every extension-owned choice value at its original index while sharing one native presentation.
func extensionPromptChoiceItems(_ prompt: ExtensionPrompt) -> [PromptChoiceItem] {
    switch prompt.method {
    case "select":
        prompt.options.enumerated().map { index, option in
            PromptChoiceItem(
                id: index,
                title: option,
                description: nil,
                recommended: false
            )
        }
    case "confirm":
        [
            PromptChoiceItem(id: 0, title: "确认", description: nil, recommended: false),
            PromptChoiceItem(id: 1, title: "否", description: nil, recommended: false),
        ]
    default:
        []
    }
}

struct PromptChoicePanel: View {
    let title: String
    let subtitle: String?
    let choices: [PromptChoiceItem]
    let onSelect: (Int) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(choices) { choice in
                        PromptChoiceRow(
                            number: choice.id + 1,
                            title: choice.title,
                            description: choice.description,
                            recommended: choice.recommended,
                            selected: false
                        ) {
                            onSelect(choice.id)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
        .frame(width: 720, height: 460)
        .background(Color.quickPiWindowBackground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("取消")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

struct PromptChoiceRow: View {
    let number: Int
    let title: String
    let description: String?
    let recommended: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text("\(number)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected || hovered ? Color.accentColor : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        selected || hovered ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.05),
                        in: Circle()
                    )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if recommended {
                            Text("推荐")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .fixedSize()
                        }
                    }
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected || hovered ? Color.accentColor : Color.secondary.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected || hovered ? Color.accentColor.opacity(0.045) : Color.primary.opacity(0.018))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    selected || hovered ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.1),
                    lineWidth: 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }
    }
}
