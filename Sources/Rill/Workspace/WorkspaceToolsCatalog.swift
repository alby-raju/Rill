import SwiftUI

/// Ordered workspace destinations shared by the tools browser and the macOS Workspace menu.
struct WorkspaceTool: Identifiable {
    let title: String
    let detail: String
    let icon: String
    var requiresRequest = false
    var shortcut: KeyboardShortcut?
    let open: @MainActor (WorkbenchStore) -> Void

    var id: String { title }

    @MainActor func isAvailable(in store: WorkbenchStore) -> Bool {
        store.canEdit && (!requiresRequest || store.selected != nil)
    }

    struct Group: Identifiable {
        let title: String
        let tools: [WorkspaceTool]
        var id: String { title }
    }

    @MainActor static let groups: [Group] = [
        Group(
            title: "Request setup",
            tools: [
                WorkspaceTool(
                    title: "Environments", detail: "Manage shared variables and inheritance.",
                    icon: "square.stack.3d.up",
                    shortcut: KeyboardShortcut("e", modifiers: [.command, .shift])
                ) { $0.showEnvironments = true },
                WorkspaceTool(
                    title: "Authentication and Secrets",
                    detail: "Manage reusable credentials and Keychain values.",
                    icon: "key.horizontal"
                ) { $0.showAuthentication = true },
                WorkspaceTool(
                    title: "TLS Profiles",
                    detail: "Configure certificate trust and client identities.",
                    icon: "lock.shield"
                ) { $0.showTLS = true },
            ]),
        Group(
            title: "Sessions and testing",
            tools: [
                WorkspaceTool(
                    title: "Response History",
                    detail: "Inspect captured responses and compare JSON snapshots.",
                    icon: "clock.arrow.circlepath"
                ) { $0.showHistory = true },
                WorkspaceTool(
                    title: "Cookie Manager",
                    detail: "Inspect and remove cookies collected in this session.",
                    icon: "tray.full"
                ) { $0.showCookies = true },
                WorkspaceTool(
                    title: "Local Mocks",
                    detail: "Save mock projects, match requests and inspect calls.",
                    icon: "server.rack"
                ) { $0.showMocks = true },
                WorkspaceTool(
                    title: "Collection Runner",
                    detail: "Run collections, environment matrices and load tests.",
                    icon: "play.rectangle"
                ) { $0.showRunner = true },
                WorkspaceTool(
                    title: "API Definitions and Tools",
                    detail:
                        "Import definitions, validate schemas, create mocks and inspect responses.",
                    icon: "doc.text.magnifyingglass"
                ) { $0.showAPITools = true },
            ]),
        Group(
            title: "Protocols",
            tools: [
                WorkspaceTool(
                    title: "Live Protocols",
                    detail:
                        "Use the selected request with WebSocket, SSE or GraphQL subscriptions.",
                    icon: "waveform.path", requiresRequest: true
                ) { $0.showLiveStreams = true },
                WorkspaceTool(
                    title: "gRPC", detail: "Discover services and call Protobuf methods.",
                    icon: "point.3.connected.trianglepath.dotted"
                ) { $0.showGRPC = true },
                WorkspaceTool(
                    title: "Message Brokers", detail: "Connect to MQTT, AMQP and Kafka.",
                    icon: "antenna.radiowaves.left.and.right"
                ) { $0.showBrokers = true },
            ]),
        Group(
            title: "Files and integrations",
            tools: [
                WorkspaceTool(
                    title: "Import Rill Workspace", detail: "Preview and import a workspace file.",
                    icon: "square.and.arrow.down"
                ) { $0.importWorkspace() },
                WorkspaceTool(
                    title: "Export Rill Workspace", detail: "Save a portable workspace file.",
                    icon: "square.and.arrow.up"
                ) { $0.exportWorkspace() },
                WorkspaceTool(
                    title: "Workspace Integrations",
                    detail: "Use Git, read-only sharing and local extensions.",
                    icon: "point.3.connected.trianglepath.dotted"
                ) { $0.showWorkspaceTools = true },
                WorkspaceTool(
                    title: "Create Backup", detail: "Save a local backup of workspace data.",
                    icon: "archivebox"
                ) { $0.createBackup() },
                WorkspaceTool(
                    title: "Restore Backup",
                    detail: "Review a backup before replacing workspace data.",
                    icon: "arrow.counterclockwise"
                ) { $0.restoreBackup() },
            ]),
    ]

    func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query)
            || detail.localizedCaseInsensitiveContains(query)
    }
}

struct WorkspaceToolsBrowser: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<String> private var filter = ""
    @ViewState<String> private var category = "All"
    @FocusState private var searchFocused: Bool
    let select: (WorkspaceTool) -> Void

    private var groups: [WorkspaceTool.Group] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspaceTool.groups.compactMap { group in
            guard category == "All" || category == group.title else { return nil }
            let matches =
                group.title.localizedCaseInsensitiveContains(query)
                ? group.tools : group.tools.filter { $0.matches(query) }
            return matches.isEmpty ? nil : WorkspaceTool.Group(title: group.title, tools: matches)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                RillToolHeading(
                    title: "Workspace tools",
                    subtitle: "Find settings, sessions, protocol workbenches and workspace files.",
                    icon: "square.grid.2x2")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Find a workspace tool", text: $filter)
                .accessibilityLabel("Find a workspace tool")
                .focused($searchFocused)
            RillTabs(
                titles: ["All"] + WorkspaceTool.groups.map(\.title), selection: $category)
            if groups.isEmpty {
                RillToolEmpty(
                    title: "No matching tools",
                    detail: "Try another search or choose All to search every category.",
                    icon: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.title).font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                    .padding(.horizontal, 12).padding(.top, 8)
                                ForEach(group.tools) { tool in
                                    Button {
                                        select(tool)
                                    } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: tool.icon).frame(width: 20)
                                                .foregroundStyle(RillPalette.accent)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(tool.title).font(.callout.weight(.semibold))
                                                Text(tool.detail).font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(RillButtonStyle(emphasis: .quiet, size: .row))
                                        .disabled(!tool.isAvailable(in: store))
                                }
                            }.padding(6).rillToolPanel()
                        }
                    }.padding(.trailing, 4)
                }
            }
        }.padding(RillSpacing.sheet).frame(width: 650, height: 575).rillToolControls()
            .onAppear { searchFocused = true }
    }
}
