import SwiftUI
import RillCore

private let accent = Color(red: 0.16, green: 0.62, blue: 0.53)
struct WorkbenchView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @AppStorage("requestLayout") private var requestLayout = "automatic"
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
                .background(SplitAutosave(name: "rill.sidebar", vertical: true))
        } detail: {
            VStack(spacing: 0) {
                topbar
                tabbar
                Divider()
                if let request = store.selected {
                    RequestEditor(request: Binding(get: { store.editor.request(request.id, in: store.workspace) ?? request }, set: { store.update($0) }))
                        .id(request.id)
                } else {
                    ContentUnavailableView("A clear path to your API", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Create a request to start exploring."))
                    Button("New request") { store.newRequest() }.buttonStyle(.borderedProminent).padding(.bottom, 80)
                }
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text("LOCAL WORKSPACE").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text(store.saveStatus)
                    if store.persistenceHealth == .failed && store.persistenceAvailable { Button("Retry saving") { store.persist() } }
                    Text("·").foregroundStyle(.tertiary)
                    Text("⌘ K  Find request")
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 9)
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .disabled(store.loading || store.importing || store.closing)
        .overlay { if store.loading { ProgressView("Opening workspace…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .tint(accent)
        .sheet(isPresented: $store.showCommandImport) { CommandImportView().environmentObject(store) }
        .sheet(isPresented: $store.showCommandExport) { CommandExportView().environmentObject(store) }
        .sheet(isPresented: $store.showTLS) { TLSManagerView().environmentObject(store) }
        .sheet(isPresented: $store.showAuthentication) { AuthenticationManager().environmentObject(store) }
        .sheet(isPresented: $store.showEnvironments) { EnvironmentEditor().environmentObject(store) }
        .sheet(isPresented: $store.showHistory) { HistoryView().environmentObject(store) }
        .sheet(isPresented: $store.showPalette) { RequestSearch().environmentObject(store) }
        .alert("Rill needs your attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "water.waves").font(.system(size: 25, weight: .bold)).foregroundStyle(accent)
                Text("rill").font(.system(size: 30, weight: .bold, design: .rounded))
                Spacer()
                Text("API STUDIO").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.top, 30).padding(.bottom, 24)
            HStack { Image(systemName: "magnifyingglass"); TextField("Find a request", text: $store.search).textFieldStyle(.plain) }
                .font(.callout).padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 14)
            HStack { Text("COLLECTIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary); Spacer(); Button { store.newCollection() } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(.plain).help("New collection") }
                .padding(.horizontal, 20).padding(.top, 25).padding(.bottom, 8)
            List(selection: $store.selection) {
                ForEach(store.workspace.collections) { collection in
                    Section {
                        ForEach(filtered(collection.id)) { request in requestRow(request) }
                    } header: {
                        HStack { Image(systemName: "folder"); Text(collection.name); Spacer() }
                            .contextMenu {
                                Button("New request") { store.newRequest(in: collection.id) }
                                Button("Rename…") { store.renameCollection(collection) }
                                Button("Delete collection…", role: .destructive) { store.deleteCollection(collection) }
                            }.onTapGesture { store.focusedCollectionID = collection.id }
                    }
                }
                if !filtered(nil).isEmpty { Section("Unfiled") { ForEach(filtered(nil)) { request in requestRow(request) } } }
            }.listStyle(.sidebar)
            Menu {
                Button("Blank request") { store.newRequest() }
                ForEach(RequestTemplate.allCases, id: \.self) { template in Button(template.rawValue) { store.newRequest(template: template) } }
            } label: { Label("New request", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading) }
                .menuStyle(.borderlessButton).padding(.horizontal, 20).padding(.vertical, 12)
            Divider().padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 16) {
                Button { store.showEnvironments = true } label: { Label("Environments", systemImage: "square.stack.3d.up") }
                Button { store.showHistory = true } label: { Label("Session history", systemImage: "clock.arrow.circlepath") }
                Menu { Button("Import Rill workspace…") { store.importWorkspace() }; Button("Export Rill workspace…") { store.exportWorkspace() } } label: { Label("Workspace files", systemImage: "tray.2") }
                    .menuStyle(.borderlessButton)
            }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary).padding(20)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func filtered(_ collection: UUID?) -> [RequestDraft] {
        store.workspace.requests.filter { $0.collectionID == collection && (store.search.isEmpty || $0.name.localizedCaseInsensitiveContains(store.search) || $0.url.localizedCaseInsensitiveContains(store.search)) }
    }
    private func requestRow(_ request: RequestDraft) -> some View {
        HStack(spacing: 10) {
            Text(request.method.rawValue).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(methodColor(request.method)).frame(width: 42, alignment: .leading)
            Text(request.name).font(.system(size: 12)).lineLimit(1)
            if store.editor.isDirty(request.id, in: store.workspace) { Circle().frame(width: 5, height: 5).accessibilityLabel("Unsaved draft") }
        }.frame(height: 28).padding(.vertical, 5).tag(request.id)
            .draggable(request.id.uuidString)
            .dropDestination(for: String.self) { values, point in
                guard let raw = values.first, let id = UUID(uuidString: raw) else { return false }
                store.reorder(id, target: request.id, after: point.y > 19); return true
            }
            .contextMenu {
                Button("Duplicate") { store.duplicate(store.editor.request(request.id, in: store.workspace) ?? request) }
                Button("Move earlier") { store.attempt { try WorkspaceOperations.move(request.id, offset: -1, in: &store.workspace) } }
                Button("Move later") { store.attempt { try WorkspaceOperations.move(request.id, offset: 1, in: &store.workspace) } }
                Button("Delete request…", role: .destructive) { store.delete(request) }
            }
    }
    private var tabbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.editor.openTabs, id: \.self) { id in
                    if let request = store.editor.request(id, in: store.workspace) {
                        HStack(spacing: 8) {
                            Button { store.selection = id } label: {
                                HStack(spacing: 6) {
                                    if store.editor.pinnedTabs.contains(id) { Image(systemName: "pin.fill") }
                                    Text(request.name).lineLimit(1)
                                    if store.editor.isDirty(id, in: store.workspace) { Circle().frame(width: 5, height: 5).accessibilityLabel("Unsaved draft") }
                                }
                            }.buttonStyle(.plain)
                            if !store.editor.pinnedTabs.contains(id) {
                                Button { store.closeTab(id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).help("Close tab")
                            }
                        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 10)
                            .background(store.selection == id ? accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .contextMenu {
                                Button(store.editor.pinnedTabs.contains(id) ? "Unpin" : "Pin") { store.togglePin(id) }
                                Button("Close") { store.closeTab(id, force: true) }
                            }
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
            Picker("Environment", selection: Binding(get: { store.workspace.selectedEnvironmentID }, set: { store.workspace.selectedEnvironmentID = $0; store.persist() })) {
                Text("No environment").tag(nil as UUID?)
                ForEach(store.workspace.environments) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().frame(width: 180)
            Menu {
                Picker("Request layout", selection: $requestLayout) { Text("Automatic").tag("automatic"); Text("Side by side").tag("horizontal"); Text("Stacked").tag("vertical") }
            } label: { Image(systemName: "rectangle.split.2x1") }.menuStyle(.borderlessButton).frame(width: 28)
            Button { store.showPalette = true } label: { Image(systemName: "command") }.buttonStyle(.plain).help("Find request (⌘K)")
        }.padding(.horizontal, 24).padding(.vertical, 15)
    }
}
func methodColor(_ method: HTTPMethod) -> Color {
    switch method { case .GET: accent; case .POST: .orange; case .DELETE: .red; case .PUT, .PATCH: .blue; default: .secondary }
}

struct RequestEditor: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var request: RequestDraft
    @ViewState<String> private var section = "Parameters"
    @AppStorage("requestLayout") private var requestLayout = "automatic"
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("REQUEST").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    TextField("Request name", text: $request.name).textFieldStyle(.plain).font(.system(size: 23, weight: .semibold))
                }
                Spacer()
                Button("Save") { store.saveSelected() }.disabled(!store.editor.isDirty(request.id, in: store.workspace))
                Picker("Collection", selection: $request.collectionID) { Text("Unfiled").tag(nil as UUID?); ForEach(store.workspace.collections) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden().frame(maxWidth: 180)
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)
            HStack(spacing: 10) {
                Picker("Method", selection: $request.method) { ForEach(HTTPMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 100).tint(methodColor(request.method))
                TextField("https://api.example.com/v1/resources", text: $request.url).textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).onSubmit { store.send() }
                if store.running { Button { store.cancel() } label: { Label("Cancel", systemImage: "stop.fill") }.buttonStyle(.bordered) }
                else { Button { store.send() } label: { Label("Send", systemImage: "arrow.up.right").fontWeight(.semibold).padding(.horizontal, 10).padding(.vertical, 3) }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command) }
            }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary)).padding(.horizontal, 24).padding(.bottom, 22)
            GeometryReader { geometry in
                if requestLayout == "horizontal" || (requestLayout == "automatic" && geometry.size.width >= 1050) {
                    HSplitView {
                        composition.frame(minWidth: 350).background(SplitAutosave(name: "rill.request.horizontal", vertical: true))
                        ResponseView(exchange: store.response, running: store.running).frame(minWidth: 350)
                    }
                } else {
                    VSplitView {
                        composition.frame(minHeight: 180, idealHeight: 250).background(SplitAutosave(name: "rill.request.vertical", vertical: false))
                        ResponseView(exchange: store.response, running: store.running).frame(minHeight: 220)
                    }
                }
            }
        }
        .onChange(of: store.selection) { _, _ in store.response = nil }
    }
    private var composition: some View {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 22) {
                        ForEach(["Parameters", "Headers", "Body", "Auth", "Checks"], id: \.self) { title in
                            Button { section = title } label: { VStack(spacing: 10) { Text(title).font(.system(size: 12, weight: section == title ? .semibold : .regular)).foregroundStyle(section == title ? .primary : .secondary); Rectangle().fill(section == title ? accent : .clear).frame(height: 2) }.fixedSize(horizontal: true, vertical: false) }.buttonStyle(.plain)
                        }
                        Spacer()
                    }.padding(.horizontal, 24)
                    Divider()
                    Group {
                        switch section {
                        case "Parameters": FieldEditor(fields: $request.parameters, noun: "parameter")
                        case "Headers": FieldEditor(fields: $request.headers, noun: "header")
                        case "Body": BodyComposer(request: $request)
                        case "Auth":
                            AuthenticationComposer(request: $request)
                        default:
                            Form {
                                TextField("Expected HTTP status", text: $request.expectedStatus, prompt: Text("e.g. 200"))
                                TextField("Response body contains", text: $request.bodyContains)
                                HStack { Text("Timeout (seconds)"); TextField("Timeout", value: $request.timeout, format: .number).frame(width: 70); Text("1–300").foregroundStyle(.secondary) }
                                Text("Checks run after each response. Leave a field empty to skip it.").font(.caption).foregroundStyle(.secondary)
                            }.padding(20)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
    }
    private func formatBody() {
        do { request.body = try JSONTextFormatter.pretty(request.body) }
        catch { store.error = "The body is not valid JSON: \(error.localizedDescription)" }
    }
}
struct FieldEditor: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var fields: [Field]
    var noun: String
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack { Text("KEY").frame(maxWidth: .infinity, alignment: .leading); Text("VALUE").frame(maxWidth: .infinity, alignment: .leading) }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).padding(.leading, 28).padding(.trailing, 28)
                ForEach($fields) { $field in
                    HStack {
                        Toggle("Enabled", isOn: $field.enabled).labelsHidden().toggleStyle(.checkbox)
                        TextField("Key", text: $field.name)
                        Menu {
                            ForEach(InputSuggestions.keys(prefix: field.name, headers: noun == "header", workspace: store.workspace), id: \.self) { value in Button(value) { field.name = value } }
                        } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).frame(width: 18).help("Key suggestions")
                        TextField("Value or {{variable}}", text: $field.value)
                        Menu {
                            ForEach(InputSuggestions.variables(in: store.environment), id: \.self) { value in Button(value) { field.value = value } }
                        } label: { Image(systemName: "curlybraces") }.menuStyle(.borderlessButton).frame(width: 18).help("Environment variables")
                        Button { fields.removeAll { $0.id == field.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Remove \(noun)")
                    }.textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                }
                Button { fields.append(Field()) } label: { Label("Add \(noun)", systemImage: "plus") }.buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                if fields.isEmpty { Text("Add only what this request needs.").foregroundStyle(.tertiary).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5) }
            }.padding(20)
        }
    }
}
