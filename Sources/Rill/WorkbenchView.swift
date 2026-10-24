import SwiftUI
import RillCore

private let accent = Color(red: 0.16, green: 0.62, blue: 0.53)
struct WorkbenchView: View {
    @EnvironmentObject private var store: WorkbenchStore
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
        } detail: {
            VStack(spacing: 0) {
                topbar
                Divider()
                if let request = store.selected {
                    RequestEditor(request: Binding(get: { store.workspace.requests.first { $0.id == request.id } ?? request }, set: { store.update($0) }))
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
                            .contextMenu { Button("New request") { store.newRequest(in: collection.id) } }
                    }
                }
                if !filtered(nil).isEmpty { Section("Unfiled") { ForEach(filtered(nil)) { request in requestRow(request) } } }
            }.listStyle(.sidebar)
            Button { store.newRequest() } label: { Label("New request", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 12)
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
        }.padding(.vertical, 5).tag(request.id)
            .contextMenu { Button("Duplicate") { store.duplicate(request) }; Button("Delete request", role: .destructive) { store.delete(request) } }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("REQUEST").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    TextField("Request name", text: $request.name).textFieldStyle(.plain).font(.system(size: 23, weight: .semibold))
                }
                Spacer()
                Picker("Collection", selection: $request.collectionID) { Text("Unfiled").tag(nil as UUID?); ForEach(store.workspace.collections) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden().frame(maxWidth: 180)
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)
            HStack(spacing: 10) {
                Picker("Method", selection: $request.method) { ForEach(HTTPMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 100).tint(methodColor(request.method))
                TextField("https://api.example.com/v1/resources", text: $request.url).textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).onSubmit { store.send() }
                if store.running { Button { store.cancel() } label: { Label("Cancel", systemImage: "stop.fill") }.buttonStyle(.bordered) }
                else { Button { store.send() } label: { Label("Send", systemImage: "arrow.up.right").fontWeight(.semibold).padding(.horizontal, 10).padding(.vertical, 3) }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command) }
            }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary)).padding(.horizontal, 24).padding(.bottom, 22)
            VSplitView {
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
                        case "Body":
                            VStack(spacing: 8) {
                                HStack {
                                    Picker("Content type", selection: $request.contentType) { Text("JSON").tag("application/json"); Text("Text").tag("text/plain"); Text("XML").tag("application/xml"); Text("Form encoded").tag("application/x-www-form-urlencoded") }.frame(width: 220)
                                    Spacer()
                                    Button("Format JSON") { formatBody() }.disabled(request.contentType != "application/json")
                                }
                                TextEditor(text: $request.body).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                            }.padding(16)
                        case "Auth":
                            Form {
                                Picker("Authentication", selection: $request.auth) { ForEach(AuthKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                                if request.auth == .basic { TextField("Username", text: $request.username) }
                                if request.auth != .none { SecureField(request.auth == .bearer ? "Token or {{variable}}" : "Password", text: $request.credential); Text("Saved in macOS Keychain.").font(.caption).foregroundStyle(.secondary) }
                            }.padding(20)
                        default:
                            Form {
                                TextField("Expected HTTP status", text: $request.expectedStatus, prompt: Text("e.g. 200"))
                                TextField("Response body contains", text: $request.bodyContains)
                                HStack { Text("Timeout (seconds)"); TextField("Timeout", value: $request.timeout, format: .number).frame(width: 70); Text("1–300").foregroundStyle(.secondary) }
                                Text("Checks run after each response. Leave a field empty to skip it.").font(.caption).foregroundStyle(.secondary)
                            }.padding(20)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.frame(minHeight: 180, idealHeight: 250)
                ResponseView(exchange: store.response, running: store.running).frame(minHeight: 220)
            }
        }
        .onChange(of: store.selection) { _, _ in store.response = nil }
    }
    private func formatBody() {
        do { let object = try JSONSerialization.jsonObject(with: Data(request.body.utf8), options: .fragmentsAllowed); let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]); request.body = String(decoding: data, as: UTF8.self) }
        catch { store.error = "The body is not valid JSON: \(error.localizedDescription)" }
    }
}
struct FieldEditor: View {
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
                        TextField("Value or {{variable}}", text: $field.value)
                        Button { fields.removeAll { $0.id == field.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Remove \(noun)")
                    }.textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                }
                Button { fields.append(Field()) } label: { Label("Add \(noun)", systemImage: "plus") }.buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                if fields.isEmpty { Text("Add only what this request needs.").foregroundStyle(.tertiary).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5) }
            }.padding(20)
        }
    }
}
