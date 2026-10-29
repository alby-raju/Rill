import RillCore
import SwiftUI

private let accent = RillPalette.accent
struct WorkbenchView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var launchIntroductionFinished = false
    private var showingLaunch: Bool { store.loading || !launchIntroductionFinished }
    @ViewState private var requestTransfer: RequestTransfer?
    @AppStorage("collapsedCollectionIDs") private var collapsedCollectionIDs = ""
    @ViewState private var collapsedSearchCollections: Set<UUID> = []
    @AppStorage("requestLayout") private var requestLayout = "automatic"
    var body: some View {
        NavigationSplitView {
            sidebar.onChange(of: store.search) { _, _ in collapsedSearchCollections.removeAll() }
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
                .background(SplitAutosave(name: "rill.sidebar", vertical: true))
        } detail: {
            VStack(spacing: 0) {
                topbar
                if !store.editor.openTabs.isEmpty { tabbar }
                Divider()
                if let request = store.selected {
                    RequestEditor(
                        request: Binding(
                            get: {
                                store.editor.request(request.id, in: store.workspace) ?? request
                            }, set: { store.update($0) })
                    )
                    .id(request.id)
                } else {
                    WelcomeView()
                }
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text("LOCAL WORKSPACE").font(
                        .system(size: 10, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text(store.saveStatus)
                    if store.persistenceHealth == .failed && store.persistenceAvailable {
                        Button("Retry saving") { store.persist() }
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text("⌘ K  Find request")
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(
                    .vertical, 9)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RillPalette.canvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .buttonStyle(RillButtonStyle())
        .textFieldStyle(RillTextFieldStyle())
        .disabled(store.loading || store.importing || store.closing)
        .overlay {
            if showingLaunch {
                LaunchView(
                    status: store.loading ? store.startupStatus : "Ready to explore.",
                    loading: store.loading
                ).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showingLaunch)
        .task {
            guard !launchIntroductionFinished else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                launchIntroductionFinished = true
            } catch { /* A closed window does not need to finish its introduction. */  }
        }
        .tint(accent)
        .sheet(item: $requestTransfer) {
            RequestTransferSheet(transfer: $0).environmentObject(store)
        }
        .sheet(isPresented: $store.showForeignScripts) {
            ForeignScriptReviewView().environmentObject(store)
        }
        .sheet(isPresented: $store.showCommandImport) {
            CommandImportView().environmentObject(store)
        }
        .sheet(isPresented: $store.showHelp) { OfflineHelpView() }
        .sheet(isPresented: $store.showWorkspaceTools) {
            WorkspaceToolsView().environmentObject(store)
        }
        .sheet(isPresented: $store.showGRPC) { GRPCWorkbenchView().environmentObject(store) }
        .sheet(isPresented: $store.showBrokers) { BrokerWorkbenchView().environmentObject(store) }
        .sheet(isPresented: $store.showLiveStreams) { LiveStreamsView().environmentObject(store) }
        .sheet(isPresented: $store.showAPITools) { APIToolsView().environmentObject(store) }
        .sheet(isPresented: $store.showRunner) { RunnerView().environmentObject(store) }
        .sheet(isPresented: $store.showCommandExport) {
            CommandExportView().environmentObject(store)
        }
        .sheet(isPresented: $store.showTLS) { TLSManagerView().environmentObject(store) }
        .sheet(isPresented: $store.showAuthentication) {
            AuthenticationManager().environmentObject(store)
        }
        .sheet(isPresented: $store.showEnvironments) {
            EnvironmentEditor().environmentObject(store)
        }
        .sheet(isPresented: $store.showHistory) { HistoryView().environmentObject(store) }
        .sheet(isPresented: $store.showPalette) { RequestSearch().environmentObject(store) }
        .alert(
            "Rill needs your attention",
            isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
        ) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "water.waves").font(.system(size: 25, weight: .bold))
                    .foregroundStyle(accent)
                Text("rill").font(.system(size: 30, weight: .bold, design: .rounded))
                Spacer()
                Text("API STUDIO").font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 22)
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Find a request", text: $store.search).textFieldStyle(.plain)
            }
            .font(.callout).padding(9).background(
                .quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8)
            ).padding(.horizontal, 14)
            HStack {
                Text("COLLECTIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(
                    .secondary)
                Spacer()
                Button {
                    store.newCollection()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }.buttonStyle(RillButtonStyle(emphasis: .quiet)).help("New collection")
                    .accessibilityLabel("New collection").buttonStyle(
                        RillButtonStyle(emphasis: .quiet))
            }
            .padding(.horizontal, 20).padding(.top, 25).padding(.bottom, 8)
            List(selection: $store.selection) {
                ForEach(store.workspace.collections) { collection in
                    Group {
                        Button {
                            let expanded = collectionExpansion(collection.id)
                            expanded.wrappedValue.toggle()
                        } label: {
                            HStack {
                                Image(
                                    systemName: collectionExpansion(collection.id).wrappedValue
                                        ? "chevron.down" : "chevron.right"
                                )
                                .font(.system(size: 9, weight: .semibold)).frame(width: 12)
                                Image(systemName: "folder")
                                Text(collection.name)
                                Spacer()
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            (collectionExpansion(collection.id).wrappedValue
                                ? "Collapse " : "Expand ") + collection.name
                        )
                        .accessibilityValue(
                            collectionExpansion(collection.id).wrappedValue
                                ? "Expanded" : "Collapsed"
                        )
                        .contextMenu {
                            Button("New request") { store.newRequest(in: collection.id) }
                            Button("Rename…") { store.renameCollection(collection) }
                            Button("Delete collection…", role: .destructive) {
                                store.deleteCollection(collection)
                            }
                        }
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .dropDestination(for: String.self) { values, _ in
                            guard let raw = values.first, let id = UUID(uuidString: raw) else {
                                return false
                            }
                            do {
                                try store.transferRequest(id, to: collection.id, copy: false)
                                return true
                            } catch {
                                store.error = error.localizedDescription
                                return false
                            }
                        }
                        if collectionExpansion(collection.id).wrappedValue {
                            ForEach(filtered(collection.id)) { request in requestRow(request) }
                        }
                    }
                }
                if !filtered(nil).isEmpty {
                    Section("Unfiled") { ForEach(filtered(nil)) { request in requestRow(request) } }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .overlay {
                    if store.workspace.requests.isEmpty && store.workspace.collections.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "folder").font(.title2)
                            Text("Your collections live here").font(
                                .system(size: 12, weight: .medium))
                            Text("Create a collection to organize requests.").font(
                                .system(size: 11)
                            ).multilineTextAlignment(.center)
                        }.foregroundStyle(.secondary).padding(24).frame(
                            maxHeight: .infinity, alignment: .top
                        ).padding(.top, 22).allowsHitTesting(false)
                    }
                }
            Menu {
                Button("Blank request") { store.newRequest() }
                ForEach(RequestTemplate.allCases, id: \.self) { template in
                    Button(template.rawValue) { store.newRequest(template: template) }
                }
            } label: {
                Label("New request", systemImage: "plus").frame(
                    maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton).padding(.horizontal, 20).padding(.vertical, 12)
            Divider().padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    store.showEnvironments = true
                } label: {
                    Label("Environments", systemImage: "square.stack.3d.up")
                }
                Button {
                    store.showHistory = true
                } label: {
                    Label("Session history", systemImage: "clock.arrow.circlepath")
                }
                Menu {
                    Button("Import Rill workspace…") { store.importWorkspace() }
                    Button("Export Rill workspace…") { store.exportWorkspace() }
                } label: {
                    Label("Workspace files", systemImage: "tray.2")
                }
                .menuStyle(.borderlessButton)
            }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary).padding(20)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func collectionExpansion(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                if !store.search.isEmpty { return !collapsedSearchCollections.contains(id) }
                return !collapsedCollectionIDs.split(separator: ",").contains(
                    Substring(id.uuidString))
            },
            set: { expanded in
                store.focusedCollectionID = id
                if !store.search.isEmpty {
                    if expanded {
                        collapsedSearchCollections.remove(id)
                    } else {
                        collapsedSearchCollections.insert(id)
                    }
                } else {
                    let current = Set(store.workspace.collections.map { $0.id.uuidString })
                    var collapsed = Set(
                        collapsedCollectionIDs.split(separator: ",").map(String.init)
                    ).intersection(current)
                    if expanded {
                        collapsed.remove(id.uuidString)
                    } else {
                        collapsed.insert(id.uuidString)
                    }
                    collapsedCollectionIDs = collapsed.sorted().joined(separator: ",")
                }
            })
    }
    private func filtered(_ collection: UUID?) -> [RequestDraft] {
        store.workspace.requests.filter {
            $0.collectionID == collection
                && (store.search.isEmpty || $0.name.localizedCaseInsensitiveContains(store.search)
                    || $0.url.localizedCaseInsensitiveContains(store.search))
        }
    }
    private func requestRow(_ request: RequestDraft) -> some View {
        HStack(spacing: 10) {
            Text(request.method.rawValue).font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(methodColor(request.method)).frame(width: 42, alignment: .leading)
            Text(request.name).font(.system(size: 12)).lineLimit(1)
            if store.editor.isDirty(request.id, in: store.workspace) {
                Circle().frame(width: 5, height: 5).accessibilityLabel("Unsaved draft")
            }
        }.frame(height: 28).padding(.vertical, 5).tag(request.id)
            .draggable(request.id.uuidString)
            .dropDestination(for: String.self) { values, point in
                guard let raw = values.first, let id = UUID(uuidString: raw) else { return false }
                store.reorder(id, target: request.id, after: point.y > 19)
                return true
            }
            .contextMenu {
                Button("Duplicate") {
                    store.duplicate(
                        store.editor.request(request.id, in: store.workspace) ?? request)
                }
                Button("Copy to collection…") {
                    requestTransfer = RequestTransfer(requestID: request.id, copy: true)
                }
                Button("Move to collection…") {
                    requestTransfer = RequestTransfer(requestID: request.id, copy: false)
                }
                Divider()
                Button("Move earlier") {
                    store.attempt {
                        try WorkspaceOperations.move(request.id, offset: -1, in: &store.workspace)
                    }
                }
                Button("Move later") {
                    store.attempt {
                        try WorkspaceOperations.move(request.id, offset: 1, in: &store.workspace)
                    }
                }
                Button("Delete request…", role: .destructive) { store.delete(request) }
            }
    }
    private var tabbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.editor.openTabs, id: \.self) { id in
                    if let request = store.editor.request(id, in: store.workspace) {
                        HStack(spacing: 8) {
                            Button {
                                store.selection = id
                            } label: {
                                HStack(spacing: 6) {
                                    if store.editor.pinnedTabs.contains(id) {
                                        Image(systemName: "pin.fill")
                                    }
                                    Text(request.name).lineLimit(1)
                                    if store.editor.isDirty(id, in: store.workspace) {
                                        Circle().frame(width: 5, height: 5).accessibilityLabel(
                                            "Unsaved draft")
                                    }
                                }
                            }.buttonStyle(.plain)
                            if !store.editor.pinnedTabs.contains(id) {
                                Button {
                                    store.closeTab(id)
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 9))
                                }.buttonStyle(RillButtonStyle(emphasis: .quiet)).help("Close tab")
                                    .accessibilityLabel("Close request tab")
                            }
                        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 10)
                            .background(
                                store.selection == id ? accent.opacity(0.13) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .overlay(
                                RequestTabMenu(
                                    pinned: store.editor.pinnedTabs.contains(id),
                                    canEdit: store.canEdit,
                                    hasLeft: store.editor.openTabs.first != id,
                                    hasRight: store.editor.openTabs.last != id
                                ) { action in
                                    guard store.editor.openTabs.contains(id) else { return }
                                    switch action {
                                    case .pin: store.togglePin(id)
                                    case .close: store.closeTab(id, force: true)
                                    case .left: store.closeTabs(.left, relativeTo: id)
                                    case .right: store.closeTabs(.right, relativeTo: id)
                                    case .all: store.closeTabs(.all)
                                    }
                                })
                    }
                }
            }.padding(.horizontal, 16).padding(.bottom, 6)
        }
    }
    private var topbar: some View {
        HStack {
            Image(systemName: "square.split.2x2").foregroundStyle(.secondary)
            Text("Workbench").font(.callout.weight(.medium))
            Spacer()
            EnvironmentSwitcher()
            RequestLayoutSelector(selection: $requestLayout)
            Button {
                store.showPalette = true
            } label: {
                Image(systemName: "command")
            }.buttonStyle(RillButtonStyle(emphasis: .quiet)).help("Find request (⌘K)")
                .accessibilityLabel("Find request")
        }.padding(.horizontal, 24).padding(.vertical, 15)
    }
}
func methodColor(_ method: HTTPMethod) -> Color {
    switch method {
    case .GET: accent
    case .POST: .orange
    case .DELETE: .red
    case .PUT, .PATCH: .blue
    default: .secondary
    }
}

struct RequestEditor: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var request: RequestDraft
    @FocusState private var urlFocused: Bool
    @ViewState<String> private var section = RillPreview.section
    @AppStorage("requestLayout") private var requestLayout = "automatic"
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("REQUEST").font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    TextField("Request name", text: $request.name).textFieldStyle(.plain).font(
                        .system(size: 23, weight: .semibold))
                }
                Spacer()
                Button {
                    store.saveSelected()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }.buttonStyle(RillButtonStyle()).disabled(
                    !store.editor.isDirty(request.id, in: store.workspace))
                RillSelect(
                    title: "Collection",
                    value: store.workspace.collections.first(where: {
                        $0.id == request.collectionID
                    })?.name ?? "Unfiled", selection: $request.collectionID
                ) {
                    Text("Unfiled").tag(nil as UUID?)
                    ForEach(store.workspace.collections) { Text($0.name).tag(Optional($0.id)) }
                }.frame(width: 180)
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)
            HStack(spacing: 10) {
                RillSelect(
                    title: "HTTP method", value: request.method.rawValue, selection: $request.method
                ) { ForEach(HTTPMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(
                    width: 100
                ).foregroundStyle(methodColor(request.method))
                TextField("https://api.example.com/v1/resources", text: $request.url)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).onSubmit {
                        store.send()
                    }.focused($urlFocused).accessibilityLabel("Request URL")
                if store.running {
                    Button {
                        store.cancel()
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }.buttonStyle(RillButtonStyle())
                } else {
                    Button {
                        store.send()
                    } label: {
                        Label("Send", systemImage: "arrow.up.right").fontWeight(.semibold).padding(
                            .horizontal, 10
                        ).padding(.vertical, 3)
                    }.buttonStyle(RillButtonStyle(emphasis: .primary)).keyboardShortcut(
                        .return, modifiers: .command
                    ).disabled(
                        request.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !store.canEdit
                    ).help(
                        request.url.isEmpty
                            ? "Enter a URL to send this request" : "Send request (⌘↵)")
                }
            }.padding(10).background(
                Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)
            ).overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(
                    urlFocused ? accent : RillPalette.line, lineWidth: urlFocused ? 1.5 : 1)
            ).padding(.horizontal, 24).padding(.bottom, 16)
            GeometryReader { geometry in
                let horizontal =
                    requestLayout == "horizontal"
                    || (requestLayout == "automatic" && geometry.size.width >= 1050)
                RequestSplitView(
                    vertical: horizontal,
                    leadingMinimum: horizontal ? 350 : min(140, geometry.size.height * 0.35),
                    trailingMinimum: horizontal ? 350 : min(180, geometry.size.height * 0.4),
                    leading: paneStyle(boundedPane { composition }),
                    trailing: paneStyle(
                        boundedPane {
                            ResponseView(exchange: store.response, running: store.running)
                        })
                ).id(horizontal)

            }
        }
        .onChange(of: store.selection) { _, _ in store.response = nil }
        #if DEBUG
            .onReceive(RillPreview.requestSections) { section = $0 }
        #endif
    }
    private func paneStyle<Content: View>(_ content: Content) -> some View {
        content.environmentObject(store)
            .disabled(store.loading || store.importing || store.closing)
            .defaultAppStorage(RillPreview.preferences)
            .buttonStyle(RillButtonStyle())
            .textFieldStyle(RillTextFieldStyle())
    }

    /// Keep the native split item's sizing identity independent of selected tab content.
    /// macOS 15 can otherwise redistribute space even when nested content is clipped.
    private func boundedPane<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let pane = content()
        return GeometryReader { viewport in
            pane.frame(
                width: max(0, viewport.size.width), height: max(0, viewport.size.height),
                alignment: .topLeading
            ).clipped()
        }
    }
    private var composition: some View {
        VStack(alignment: .leading, spacing: 0) {
            RillTabs(
                titles: ["Parameters", "Headers", "Body", "GraphQL", "Auth", "Checks", "Workflow"],
                selection: $section
            ).padding(.horizontal, 14).padding(.bottom, 4)
            Divider()
            GeometryReader { _ in
                Group {
                    switch section {
                    case "Parameters": FieldEditor(fields: $request.parameters, noun: "parameter")
                    case "Headers": FieldEditor(fields: $request.headers, noun: "header")
                    case "Body": BodyComposer(request: $request)
                    case "Auth":
                        AuthenticationComposer(request: $request)
                    case "GraphQL": GraphQLComposer(request: $request)
                    case "Workflow": WorkflowEditor(request: $request)
                    default:
                        ScrollView {
                            RillSection(
                                title: "Response checks",
                                subtitle: "Validate the result each time you send this request.",
                                icon: "checkmark.seal"
                            ) {
                                TextField(
                                    "Expected status · e.g. 200", text: $request.expectedStatus)
                                TextField("Response body contains", text: $request.bodyContains)
                                HStack {
                                    Text("Timeout")
                                    Spacer()
                                    TextField("Seconds", value: $request.timeout, format: .number)
                                        .frame(width: 90)
                                    Text("seconds · 1–300").font(.caption).foregroundStyle(
                                        .secondary)
                                }
                                RillNotice(
                                    text:
                                        "Leave a check empty to skip it. For JSON and header rules, open Workflow."
                                )
                            }.padding(20).frame(maxWidth: 740, alignment: .leading)
                        }
                    }

                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.clipped()

        }
    }
    private func formatBody() {
        do { request.body = try JSONTextFormatter.pretty(request.body) } catch {
            store.error = "The body is not valid JSON: \(error.localizedDescription)"
        }
    }
}
struct FieldEditor: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var fields: [Field]
    var noun: String
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack {
                    Text("KEY").frame(maxWidth: .infinity, alignment: .leading)
                    Text("VALUE").frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(
                    .secondary
                ).padding(.leading, 28).padding(.trailing, 28)
                ForEach($fields) { $field in
                    HStack {
                        Toggle("Enabled", isOn: $field.enabled).labelsHidden().toggleStyle(
                            .checkbox)
                        TextField("Key", text: $field.name)
                        Menu {
                            ForEach(
                                InputSuggestions.keys(
                                    prefix: field.name, headers: noun == "header",
                                    workspace: store.workspace), id: \.self
                            ) { value in Button(value) { field.name = value } }
                        } label: {
                            Image(systemName: "chevron.down")
                        }.menuStyle(.borderlessButton).frame(width: 18).help("Key suggestions")
                        TextField("Value or {{variable}}", text: $field.value)
                        Menu {
                            ForEach(InputSuggestions.variables(in: store.environment), id: \.self) {
                                value in Button(value) { field.value = value }
                            }
                        } label: {
                            Image(systemName: "curlybraces")
                        }.menuStyle(.borderlessButton).frame(width: 18).help(
                            "Environment variables")
                        Button {
                            fields.removeAll { $0.id == field.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(RillButtonStyle(emphasis: .quiet)).foregroundStyle(.secondary)
                            .help("Remove \(noun)").accessibilityLabel("Remove \(noun)")
                    }.textFieldStyle(RillTextFieldStyle()).font(
                        .system(size: 12, design: .monospaced))
                }
                Button {
                    fields.append(Field())
                } label: {
                    Label("Add \(noun)", systemImage: "plus")
                }.buttonStyle(RillButtonStyle()).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                if fields.isEmpty {
                    RillNotice(
                        text:
                            "No \(noun)s yet. Add a key and value, or use {{variables}} from your environment.",
                        icon: "list.bullet.rectangle"
                    ).padding(.top, 12)
                }
            }.padding(20)
        }
    }
}
