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

/// Glass belongs to navigation/chrome; editors and response content retain solid reading surfaces.
struct RillGlassSurface: ViewModifier {
    enum Role { case navigation, toolbar, floating, control }
    var role: Role = .floating
    var cornerRadius: CGFloat = 12
    @SwiftUI.Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @SwiftUI.Environment(\.colorSchemeContrast) private var contrast
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.Environment(\.isEnabled) private var enabled
    private var needsOpaqueSurface: Bool {
        #if DEBUG
            if RillPreview.accessibleSelector { return true }
        #endif
        return reduceTransparency || contrast == .increased
    }
    private var backing: Color {
        role == .navigation ? Color(nsColor: .windowBackgroundColor) : RillPalette.canvas
    }
    private var opacity: Double {
        switch role {
        case .navigation: 0.78
        case .toolbar: 0.82
        case .floating: 0.86
        case .control: 0.72
        }
    }
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background {
                if needsOpaqueSurface {
                    shape.fill(backing)
                } else if #available(macOS 26.0, *), role == .floating || role == .control {
                    ZStack {
                        shape.fill(.clear)
                            .glassEffect(
                                .regular.tint(RillPalette.accent.opacity(0.025))
                                    .interactive(
                                        role == .control && enabled
                                            && RillMotion.enabled(reduceMotion)), in: shape)
                        shape.fill(backing.opacity(opacity))
                    }
                } else {
                    ZStack {
                        shape.fill(.regularMaterial)
                        shape.fill(backing.opacity(opacity))
                    }
                }
            }
            .overlay {
                if cornerRadius > 0 {
                    shape.strokeBorder(
                        needsOpaqueSurface ? Color.primary.opacity(0.25) : RillPalette.line
                    )
                    .allowsHitTesting(false)
                }
            }
    }
}

@MainActor enum RillMotion {
    static func enabled(_ reduceMotion: Bool) -> Bool {
        #if DEBUG
            if RillPreview.accessibleSelector { return false }
        #endif
        return !reduceMotion
    }
    static func transition(_ reduceMotion: Bool) -> Animation? {
        enabled(reduceMotion) ? .smooth(duration: 0.18) : nil
    }
}

struct RillButtonStyle: ButtonStyle {
    enum Emphasis { case primary, secondary, quiet }
    var emphasis: Emphasis = .secondary
    @SwiftUI.Environment(\.isEnabled) private var enabled
    @SwiftUI.Environment(\.colorScheme) private var scheme
    @ViewState private var hovered = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, emphasis == .quiet ? 9 : 14).padding(.vertical, 9)
            .foregroundStyle(
                emphasis == .primary ? (scheme == .dark ? Color.black : .white) : Color.primary
            )
            .background {
                if emphasis == .secondary {
                    Color.clear.modifier(RillGlassSurface(role: .control, cornerRadius: 10))
                }
                RoundedRectangle(cornerRadius: 10).fill(
                    background(pressed: configuration.isPressed))
            }
            .overlay {
                if emphasis == .primary {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12))
                } else if emphasis == .quiet && hovered {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(RillPalette.line)
                }
            }
            .opacity(enabled ? 1 : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
            .animation(
                RillMotion.enabled(reduceMotion) ? .easeOut(duration: 0.12) : nil, value: hovered)
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
            .modifier(RillGlassSurface(role: .control, cornerRadius: 10))
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
    @Namespace private var indicator
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        .background {
                            if selection == title {
                                RoundedRectangle(cornerRadius: 9).fill(
                                    RillPalette.accent.opacity(0.14)
                                )
                                .matchedGeometryEffect(id: "selection", in: indicator)
                            }
                        }
                    }.buttonStyle(.plain).accessibilityAddTraits(
                        selection == title ? .isSelected : [])
                }
            }.padding(5)
                .animation(RillMotion.transition(reduceMotion), value: selection)
        }.frame(height: 42)
            .modifier(RillGlassSurface(role: .toolbar, cornerRadius: 11))
    }
}
