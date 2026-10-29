import AppKit
import RillCore
import SwiftUI

struct SelectionRow: View {
    let title: String
    var detail = ""
    var icon = "folder"
    var selected = false
    var action: () -> Void
    @FocusState private var focused: Bool
    @ViewState private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(RillPalette.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 10)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RillPalette.accent)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    selected
                        ? RillPalette.accent.opacity(0.12)
                        : hovered ? Color.primary.opacity(0.05) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focused)
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                    focused ? RillPalette.accent : .clear, lineWidth: 1.5)
            )
            .onHover { hovered = $0 }.help(title).accessibilityAddTraits(
                selected ? [.isSelected] : [])
    }
}

enum WorkbenchSelector: String {
    case environment, layout
}

struct EnvironmentSwitcher: View {
    @EnvironmentObject var store: WorkbenchStore
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                Text(store.environment?.name ?? "No environment").lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.caption2)
            }.frame(width: 180)
        }.buttonStyle(RillButtonStyle()).accessibilityLabel("Choose environment")
    }
}

struct EnvironmentSelectionPanel: View {
    @EnvironmentObject var store: WorkbenchStore
    var dismiss: () -> Void
    @ViewState private var search = ""
    private var matches: [RillCore.Environment] {
        store.workspace.environments.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Request environment").font(.headline)
            Text("Choose the variable set used by your requests.").font(.caption)
                .foregroundStyle(.secondary)
            if store.workspace.environments.count > 5 {
                TextField("Find environment", text: $search).textFieldStyle(RillTextFieldStyle())
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    SelectionRow(
                        title: "No environment",
                        detail: "Use request values without environment variables",
                        icon: "circle.slash", selected: store.workspace.selectedEnvironmentID == nil
                    ) { choose(nil) }
                    ForEach(matches) { environment in
                        SelectionRow(
                            title: environment.name,
                            detail: "\(environment.variables.count) local variables",
                            icon: "square.stack.3d.up",
                            selected: store.workspace.selectedEnvironmentID == environment.id
                        ) { choose(environment.id) }
                    }
                    if matches.isEmpty && !search.isEmpty {
                        Text("No matching environments").font(.caption).foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
            }.frame(height: min(CGFloat(matches.count + 1) * 76, 270))
            Divider()
            Button("Manage environments…", systemImage: "slider.horizontal.3") {
                dismiss()
                store.showEnvironments = true
            }.buttonStyle(RillButtonStyle()).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16)
    }
    private func choose(_ id: UUID?) {
        store.workspace.selectedEnvironmentID = id
        store.persist()
        dismiss()
    }
}

struct RequestLayoutSelector: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "rectangle.split.2x1")
        }
        .buttonStyle(RillButtonStyle(emphasis: .quiet)).help("Request and response layout")
        .accessibilityLabel("Request and response layout")
    }
}

struct RequestLayoutSelectionPanel: View {
    @Binding var selection: String
    var dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Workbench layout").font(.headline).padding(10)
            choice("automatic", "Automatic", "Adapts to your window width", "rectangle.3.group")
            choice(
                "horizontal", "Side by side", "Request on the left, response on the right",
                "rectangle.split.2x1")
            choice("vertical", "Stacked", "Request above the response", "rectangle.split.1x2")
        }.padding(8)
    }
    private func choice(_ value: String, _ title: String, _ detail: String, _ icon: String)
        -> some View
    {
        SelectionRow(title: title, detail: detail, icon: icon, selected: selection == value) {
            selection = value
            dismiss()
        }
        #if DEBUG
            .background(SelectorBoundsProbe(identifier: "rill.selector.choice." + value))
        #endif
    }
}

/// Unlike a floating NSPopover, this surface is always bounded by the workbench window.
struct ContainedWorkbenchSelector<Content: View>: View {
    var dismiss: () -> Void
    @ViewBuilder var content: () -> Content
    @FocusState private var focused: Bool
    @ViewState private var contentHeight: CGFloat = 300
    var body: some View {
        GeometryReader { viewport in
            ZStack(alignment: .topTrailing) {
                SelectorDismissBackdrop(
                    panel: CGRect(
                        x: viewport.size.width - min(360, max(0, viewport.size.width - 32)) - 16,
                        y: 72,
                        width: min(360, max(0, viewport.size.width - 32)),
                        height: min(contentHeight, max(0, viewport.size.height - 88))
                    ), dismiss: dismiss
                ).accessibilityHidden(true)
                ScrollView {
                    content()
                        .background {
                            GeometryReader { contentBounds in
                                Color.clear.preference(
                                    key: SelectorHeightKey.self, value: contentBounds.size.height)
                            }
                        }
                }
                .frame(width: min(360, max(0, viewport.size.width - 32)))
                .frame(height: min(contentHeight, max(0, viewport.size.height - 88)))
                .onPreferenceChange(SelectorHeightKey.self) { contentHeight = $0 }
                .background(RillPalette.canvas, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RillPalette.line))
                .overlay(alignment: .topTrailing) {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(RillButtonStyle(emphasis: .quiet))
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Close selector")
                        .padding(6)
                }
                .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
                #if DEBUG
                    .background(SelectorBoundsProbe())
                #endif
                .focusable().focused($focused)
                .onExitCommand(perform: dismiss)
                .onAppear { focused = true }
                .padding(.top, 72).padding(.trailing, 16)
            }
        }
    }
}

#if DEBUG
    private struct SelectorBoundsProbe: NSViewRepresentable {
        var identifier = "rill.selector.bounds"
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.identifier = NSUserInterfaceItemIdentifier(identifier)
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }
#endif

private struct SelectorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Own click-away events above native request/response hosts without intercepting panel controls.
private struct SelectorDismissBackdrop: NSViewRepresentable {
    var panel: CGRect
    var dismiss: () -> Void
    func makeNSView(context: Context) -> Backdrop { Backdrop() }
    func updateNSView(_ view: Backdrop, context: Context) {
        view.panel = panel
        view.dismiss = dismiss
    }
    final class Backdrop: NSView {
        var panel = CGRect.zero
        var dismiss: () -> Void = {}
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            if panel.contains(convert(point, from: superview)) { return nil }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) { dismiss() }
    }
}
