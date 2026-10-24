import SwiftUI
import RillCore
import UniformTypeIdentifiers

struct ResponseView: View {
    var exchange: Exchange?
    var running: Bool
    @ViewState<String> private var section = "Body"
    @ViewState<Bool> private var pretty = true
    @AppStorage("editorFontSize") private var fontSize = 12.0
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
                    Picker("Response section", selection: $section) { Text("Body").tag("Body"); Text("Headers (\(exchange.headers.count))").tag("Headers"); Text("Checks (\(exchange.checks.count))").tag("Checks"); Text("Request").tag("Request"); Text("Timeline").tag("Timeline") }.pickerStyle(.segmented).frame(maxWidth: 550)
                    Spacer()
                    if section == "Body" { Toggle("Pretty JSON", isOn: $pretty).toggleStyle(.checkbox); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(exchange.previewIsTruncated ? exchange.text : pretty ? exchange.prettyText : exchange.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Copy response body"); Button { export(exchange) } label: { Image(systemName: "square.and.arrow.up") }.help("Export response") }
                }.font(.caption).padding(.horizontal, 20).padding(.vertical, 10)
                if section == "Body" {
                    if exchange.previewIsTruncated {
                        Text("Preview limited to \(ByteCountFormatter.string(fromByteCount: Int64(exchange.previewByteLimit), countStyle: .file)). Export or copy retained bytes to inspect more.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                    }
                    ResponseBodyPreview(exchange: exchange, pretty: pretty, fontSize: fontSize).id(exchange.id)
                } else if section == "Headers" {
                    List(exchange.headers) { field in HStack(alignment: .top) { Text(field.name).fontWeight(.medium).frame(width: 190, alignment: .leading); Text(field.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(field.value, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy header value") }.font(.system(size: 11, design: .monospaced)) }
                } else if section == "Timeline" {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(exchange.events ?? []) { event in HStack { Text(String(format: "%.1f ms", event.elapsed * 1000)).frame(width: 100, alignment: .leading); Text(event.title) } }
                        Text("Monotonic elapsed transport milestones. Local preparation precedes this timeline; DNS, connection and TLS phases are not separately measured.").font(.caption).foregroundStyle(.secondary)
                    }.font(.system(size: fontSize, design: .monospaced)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20)
                } else if section == "Request" {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Effective response URL: " + exchange.url).textSelection(.enabled)
                            if let summary = exchange.preparedRequest {
                                Text(summary.method + " " + summary.url).textSelection(.enabled)
                                Text("TLS: " + (summary.tlsPolicy ?? "System trust"))
                                if let limit = exchange.downloadLimit { Text("Download budget: " + ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) }
                                Button("Export redacted prepared request…") { exportPrepared(summary) }
                                Text("Prepared body: \(summary.bodyBytes.map { String($0) + " bytes" } ?? "none")")
                                ForEach(summary.headers) { field in Text(field.name + ": " + field.value).textSelection(.enabled) }
                            }
                            Text("Initial prepared request before redirects and transport-added headers. Query values and custom header values are masked; URL paths and response URLs may still contain sensitive data. Timing is total elapsed time; DNS/connect/TLS phases are not measured.").foregroundStyle(.secondary)
                        }.font(.system(size: fontSize, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
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
    private func exportPrepared(_ summary: PreparedRequestSummary) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "prepared-request.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await Task.detached { try summary.write(to: url) }.value }
            catch { NSAlert(error: error).runModal() }
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
                        Picker("Inherits from", selection: $store.workspace.environments[index].parentID) {
                            Text("None").tag(nil as UUID?)
                            ForEach(store.workspace.environments.filter { EnvironmentResolver.canSetParent($0.id, for: store.workspace.environments[index].id, in: store.workspace.environments) }) { parent in Text(parent.name).tag(Optional(parent.id)) }
                        }.padding(.horizontal, 16)
                        FieldEditor(fields: $store.workspace.environments[index].variables, noun: "variable")
                        Text("Use {{name}} in URLs, headers, body or auth. Environment values are stored in plain text; keep tokens in the request’s Auth tab.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                        Button("Delete environment", role: .destructive) { if let selected { WorkspaceOperations.deleteEnvironment(selected, in: &store.workspace) }; selected = nil; store.persist() }.padding(16)
                    }
                } else { ContentUnavailableView("Choose an environment", systemImage: "square.stack.3d.up", description: Text("Create Local, Staging or Production variable sets.")) }
            }
        }.padding(24).frame(width: 800, height: 500)
            .onAppear { selected = store.workspace.selectedEnvironmentID ?? store.workspace.environments.first?.id }
            .onDisappear { store.persist() }
    }
}
struct HistoryView: View {
    @ViewState<String?> private var comparison: String?
    @ViewState<Bool> private var comparing = false
    @ViewState<Task<Void, Never>?> private var comparisonTask: Task<Void, Never>? = nil
    @EnvironmentObject var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 16) {
            HStack { Text("Response history").font(.title2.weight(.semibold)); Spacer(); Button("Clear") { store.clearHistory() }; Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            HStack {
                Text(store.historyStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let selected = store.workspace.history.first(where: { $0.id == store.inspectedHistoryID }) {
                    Menu(comparing ? "Comparing…" : "Compare JSON with…") {
                        ForEach(store.workspace.history.filter { $0.id != selected.id }) { other in
                            Button(other.requestName + " · " + other.date.formatted(date: .omitted, time: .standard)) {
                                comparing = true
                                comparisonTask?.cancel()
                                comparisonTask = Task {
                                    let worker = Task.detached { try ResponseComparator.compare(selected, other).text }
                                    do {
                                        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                                        if !Task.isCancelled { comparison = result }
                                    } catch { if !Task.isCancelled { comparison = error.localizedDescription } }
                                    comparing = false
                                }
                            }
                        }
                    }.disabled(comparing)
                }
            }
            HSplitView {
                List(selection: $store.inspectedHistoryID) {
                    ForEach(store.workspace.history) { exchange in
                        VStack(alignment: .leading) {
                            Text("\(exchange.status) · \(exchange.requestName)")
                            Text(exchange.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        }.tag(exchange.id).padding(.vertical, 5)
                    }
                }.frame(minWidth: 200, idealWidth: 250)
                ResponseView(exchange: store.workspace.history.first { $0.id == store.inspectedHistoryID }, running: false).frame(minWidth: 500)
            }
        }.padding(24).frame(width: 1000, height: 600)
        .onDisappear { comparisonTask?.cancel() }
        .sheet(isPresented: Binding(get: { comparison != nil }, set: { if !$0 { comparison = nil } })) {
            VStack {
                HStack { Text("Semantic JSON comparison").font(.title2); Spacer(); Button("Done") { comparison = nil }.keyboardShortcut(.defaultAction) }
                ScrollView([.vertical, .horizontal]) { Text(comparison ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(24).frame(width: 750, height: 550)
        }
    }
}
struct RequestSearch: View {
    @EnvironmentObject var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) var dismiss
    @ViewState<String> private var query = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Image(systemName: "magnifyingglass"); TextField("Find requests, collections, environments or history", text: $query).textFieldStyle(.plain).focused($focused); Button("Done") { dismiss() } }
            Divider()
            List(store.searchResults(query)) { result in
                Button { dismiss(); Task { @MainActor in await Task.yield(); store.activateSearch(result) } } label: {
                    HStack { Text(result.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary).frame(width: 90); VStack(alignment: .leading) { Text(result.title); Text(result.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer() }
                }.buttonStyle(.plain).padding(.vertical, 6)
            }
        }.padding(24).frame(width: 720, height: 400).onAppear { focused = true }
    }
}
