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

struct EnvironmentSwitcher: View {
    @EnvironmentObject var store: WorkbenchStore
    @ViewState private var presented = false
    @ViewState private var search = ""
    var body: some View {
        Button {
            presented.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                Text(store.environment?.name ?? "No environment").lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.caption2)
            }.frame(width: 180)
        }.buttonStyle(RillButtonStyle()).accessibilityLabel("Choose environment")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Request environment").font(.headline)
                    Text("Choose the variable set used by your requests.").font(.caption)
                        .foregroundStyle(.secondary)
                    if store.workspace.environments.count > 5 {
                        TextField("Find environment", text: $search).textFieldStyle(
                            RillTextFieldStyle())
                    }
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            SelectionRow(
                                title: "No environment",
                                detail: "Use request values without environment variables",
                                icon: "circle.slash",
                                selected: store.workspace.selectedEnvironmentID == nil
                            ) { choose(nil) }
                            ForEach(
                                store.workspace.environments.filter {
                                    search.isEmpty
                                        || $0.name.localizedCaseInsensitiveContains(search)
                                }
                            ) { environment in
                                SelectionRow(
                                    title: environment.name,
                                    detail: "\(environment.variables.count) local variables",
                                    icon: "square.stack.3d.up",
                                    selected: store.workspace.selectedEnvironmentID
                                        == environment.id
                                ) { choose(environment.id) }
                            }
                        }
                    }.frame(
                        height: min(
                            CGFloat(
                                store.workspace.environments.filter {
                                    search.isEmpty
                                        || $0.name.localizedCaseInsensitiveContains(search)
                                }.count + 1) * 68, 270))
                    Divider()
                    Button("Manage environments…", systemImage: "slider.horizontal.3") {
                        presented = false
                        store.showEnvironments = true
                    }.buttonStyle(RillButtonStyle()).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(16).frame(width: 330)
            }
    }
    private func choose(_ id: UUID?) {
        store.workspace.selectedEnvironmentID = id
        store.persist()
        presented = false
    }
}

struct RequestLayoutSelector: View {
    @Binding var selection: String
    @ViewState private var presented = false
    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Image(systemName: "rectangle.split.2x1")
        }
        .buttonStyle(RillButtonStyle(emphasis: .quiet)).help("Request and response layout")
        .accessibilityLabel("Request and response layout")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Workbench layout").font(.headline).padding(10)
                choice("automatic", "Automatic", "Adapts to your window width", "rectangle.3.group")
                choice(
                    "horizontal", "Side by side", "Request on the left, response on the right",
                    "rectangle.split.2x1")
                choice("vertical", "Stacked", "Request above the response", "rectangle.split.1x2")
            }.padding(8).frame(width: 320)
        }
    }
    private func choice(_ value: String, _ title: String, _ detail: String, _ icon: String)
        -> some View
    {
        SelectionRow(title: title, detail: detail, icon: icon, selected: selection == value) {
            selection = value
            presented = false
        }
    }
}
