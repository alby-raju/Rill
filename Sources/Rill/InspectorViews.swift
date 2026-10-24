import SwiftUI
import RillCore
import UniformTypeIdentifiers

struct ResponseView: View {
    var exchange: Exchange?
    var running: Bool
    @ViewState<String> private var section = "Body"
    @ViewState<Bool> private var pretty = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Text("RESPONSE").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if let exchange {
                    Label("\(exchange.status) \(HTTPURLResponse.localizedString(forStatusCode: exchange.status).capitalized)", systemImage: "circle.fill").foregroundStyle(exchange.status < 400 ? Color.green : Color.orange)
                    Text(String(format: "%.0f ms", exchange.duration * 1000))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(exchange.body.count), countStyle: .file))
                }
            }.font(.system(size: 11, weight: .medium, design: .monospaced)).padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            if running {
                VStack(spacing: 12) { ProgressView().controlSize(.small); Text("Following the request…").font(.callout).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let exchange {
                HStack {
                    Picker("Response section", selection: $section) { Text("Body").tag("Body"); Text("Headers (\(exchange.headers.count))").tag("Headers"); Text("Checks (\(exchange.checks.count))").tag("Checks") }.pickerStyle(.segmented).frame(width: 310)
                    Spacer()
                    if section == "Body" { Toggle("Pretty JSON", isOn: $pretty).toggleStyle(.checkbox); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(exchange.previewIsTruncated ? exchange.text : pretty ? exchange.prettyText : exchange.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Copy response body"); Button { export(exchange) } label: { Image(systemName: "square.and.arrow.up") }.help("Export response") }
                }.font(.caption).padding(.horizontal, 20).padding(.vertical, 10)
                if section == "Body" {
                    if exchange.previewIsTruncated {
                        Text("Preview limited to 512 KiB. Export or copy the raw body for the complete response.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                    }
                    ScrollView([.vertical, .horizontal]) { Text(exchange.previewText(pretty: pretty)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(20) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if section == "Headers" {
                    List(exchange.headers) { field in HStack(alignment: .top) { Text(field.name).fontWeight(.medium).frame(width: 190, alignment: .leading); Text(field.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(field.value, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy header value") }.font(.system(size: 11, design: .monospaced)) }
                } else if exchange.checks.isEmpty {
                    ContentUnavailableView("No checks configured", systemImage: "checkmark.seal", description: Text("Add an expected status or body match in Checks."))
                } else {
                    List(exchange.checks) { check in Label(check.title, systemImage: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(check.passed ? Color.green : Color.red) }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.up.right.circle").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Text("See what comes back.").font(.system(size: 18, weight: .medium))
                    Text("Send a request to inspect its response, headers and checks.").font(.callout).foregroundStyle(.secondary)
                    Text("⌘ ↵").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 3)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func export(_ exchange: Exchange) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "response.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exchange.body.write(to: url, options: .atomic) }
        catch { let alert = NSAlert(error: error); alert.runModal() }
    }
}
struct EnvironmentEditor: View {
    @EnvironmentObject var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) var dismiss
    @ViewState<UUID?> private var selected: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Environments").font(.title2.weight(.semibold)); Text("One request. Every stage of your API.").foregroundStyle(.secondary) }; Spacer(); Button("Done") { store.persist(); dismiss() }.keyboardShortcut(.defaultAction) }
            HSplitView {
                VStack {
                    List(selection: $selected) { ForEach(store.workspace.environments) { Text($0.name).tag($0.id) } }
                    Button("New environment", systemImage: "plus") { let environment = RillCore.Environment(name: "New environment"); store.workspace.environments.append(environment); selected = environment.id; store.persist() }
                }.frame(minWidth: 180, maxWidth: 220)
                if let index = store.workspace.environments.firstIndex(where: { $0.id == selected }) {
                    VStack(alignment: .leading) {
                        TextField("Environment name", text: $store.workspace.environments[index].name).font(.title3).textFieldStyle(.roundedBorder).padding(16)
                        FieldEditor(fields: $store.workspace.environments[index].variables, noun: "variable")
                        Text("Use {{name}} in URLs, headers, body or auth. Environment values are stored in plain text; keep tokens in the request’s Auth tab.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                        Button("Delete environment", role: .destructive) { if store.workspace.selectedEnvironmentID == selected { store.workspace.selectedEnvironmentID = nil }; store.workspace.environments.remove(at: index); selected = nil; store.persist() }.padding(16)
                    }
                } else { ContentUnavailableView("Choose an environment", systemImage: "square.stack.3d.up", description: Text("Create Local, Staging or Production variable sets.")) }
            }
        }.padding(24).frame(width: 800, height: 500)
            .onAppear { selected = store.workspace.selectedEnvironmentID ?? store.workspace.environments.first?.id }
            .onDisappear { store.persist() }
    }
}
struct HistoryView: View {
    @EnvironmentObject var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Session history").font(.title2.weight(.semibold)); Spacer(); Button("Clear") { store.workspace.history.removeAll() }.disabled(store.workspace.history.isEmpty); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            Text("Response payloads are kept in memory for this session. Up to 50 exchanges, with a shared 32 MiB limit.").font(.caption).foregroundStyle(.secondary)
            if store.workspace.history.isEmpty { ContentUnavailableView("A fresh start", systemImage: "clock", description: Text("Your requests will appear here as you send them.")) }
            else {
                List(store.workspace.history) { exchange in
                    Button {
                        if store.workspace.requests.contains(where: { $0.id == exchange.requestID }) { store.selection = exchange.requestID }
                        // Defer until request navigation has cleared its previous response.
                        Task { @MainActor in await Task.yield(); store.response = exchange }
                        dismiss()
                    } label: {
                        HStack { Text("\(exchange.status)").foregroundStyle(exchange.status < 400 ? Color.green : Color.orange).frame(width: 40); VStack(alignment: .leading) { Text(exchange.requestName).fontWeight(.medium); Text("\(exchange.method.rawValue) \(exchange.url)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); Text(exchange.date, style: .time).font(.caption).foregroundStyle(.secondary) }
                    }.buttonStyle(.plain).padding(.vertical, 5)
                }
            }
        }.padding(24).frame(width: 800, height: 500)
    }
}
struct RequestSearch: View {
    @EnvironmentObject var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) var dismiss
    @ViewState<String> private var query = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Image(systemName: "magnifyingglass"); TextField("Find a request by name or URL", text: $query).textFieldStyle(.plain).focused($focused); Button("Done") { dismiss() } }
            Divider()
            List(store.workspace.requests.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }) { request in
                Button { store.selection = request.id; store.response = nil; dismiss() } label: { HStack { Text(request.method.rawValue).foregroundStyle(methodColor(request.method)).font(.system(size: 10, weight: .bold, design: .monospaced)).frame(width: 50); VStack(alignment: .leading) { Text(request.name); Text(request.url.isEmpty ? "No URL yet" : request.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); Image(systemName: "return").foregroundStyle(.tertiary) } }.buttonStyle(.plain).padding(.vertical, 6)
            }
        }.padding(24).frame(width: 640, height: 380).onAppear { focused = true }
    }
}
