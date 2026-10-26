import SwiftUI

/// Shared native control surfaces; system appearance and keyboard behavior are retained.
enum RillPalette {
    static let accent = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.34, green: 0.82, blue: 0.70, alpha: 1)
                : NSColor(red: 0.04, green: 0.40, blue: 0.33, alpha: 1)
        })
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let line = Color.primary.opacity(0.10)
}

struct RillButtonStyle: ButtonStyle {
    enum Emphasis { case primary, secondary, quiet }
    var emphasis: Emphasis = .secondary
    @SwiftUI.Environment(\.isEnabled) private var enabled
    @SwiftUI.Environment(\.colorScheme) private var scheme
    @ViewState private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, emphasis == .quiet ? 9 : 14).padding(.vertical, 9)
            .foregroundStyle(
                emphasis == .primary ? (scheme == .dark ? Color.black : .white) : Color.primary
            )
            .background(
                background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                    emphasis == .primary
                        ? Color.clear
                        : RillPalette.line.opacity(emphasis == .quiet && !hovered ? 0 : 1))
            )
            .opacity(enabled ? 1 : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
    }
    private func background(pressed: Bool) -> Color {
        if emphasis == .primary {
            return RillPalette.accent.opacity(pressed ? 0.75 : hovered ? 0.88 : 1)
        }
        return Color.primary.opacity(
            pressed ? 0.12 : hovered ? 0.07 : emphasis == .quiet ? 0 : 0.035)
    }
}

struct RillTextFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).padding(.horizontal, 11).padding(.vertical, 9)
            .background(RillPalette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7).strokeBorder(
                    focused ? RillPalette.accent : RillPalette.line, lineWidth: focused ? 1.5 : 1)
            )
            .focused($focused)
    }
}

struct RillSelect<Value: Hashable, Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: Value
    @ViewBuilder var options: () -> Options
    var body: some View {
        Menu {
            Section(title) {
                Picker(title, selection: $selection, content: options).pickerStyle(.inline)
                    .labelsHidden()
            }
        } label: {
            HStack(spacing: 9) {
                Text(value).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(
                    .system(size: 9, weight: .semibold)
                ).foregroundStyle(.secondary)
            }.font(.system(size: 12, weight: .medium))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RillPalette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(RillPalette.line))
            .accessibilityLabel(title).accessibilityValue(value)
    }
}

struct RillSection<Content: View>: View {
    let title: String
    let subtitle: String
    var icon: String = "slider.horizontal.3"
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon).foregroundStyle(RillPalette.accent).frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content()
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(RillPalette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RillPalette.line))
    }
}

struct RillNotice: View {
    let text: String
    var icon = "info.circle"
    var body: some View {
        Label(text, systemImage: icon).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).frame(
                maxWidth: .infinity, alignment: .leading
            )
            .padding(12).background(
                RillPalette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct RillTabs: View {
    let titles: [String]
    @Binding var selection: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(titles, id: \.self) { title in
                    Button {
                        selection = title
                    } label: {
                        Text(title).font(
                            .system(size: 12, weight: selection == title ? .semibold : .medium)
                        )
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .foregroundStyle(selection == title ? RillPalette.accent : .secondary)
                        .background(
                            selection == title ? RillPalette.accent.opacity(0.11) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityAddTraits(
                        selection == title ? .isSelected : [])
                }
            }.padding(5)
        }.frame(height: 42)
    }
}
