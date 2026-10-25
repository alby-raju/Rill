import SwiftUI
import UniformTypeIdentifiers
import RillCore

struct GraphQLComposer: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Binding var request: RequestDraft
    @ViewState<[String]> private var names = []
    @ViewState<Int> private var typeCount = 0
    @ViewState<String> private var status = "No schema loaded"
    @ViewState<String> private var schemaSearch = ""
    @ViewState<Bool> private var loading = false
    @ViewState<UUID> private var generation = UUID()
    @ViewState<Task<Void, Never>?> private var schemaTask: Task<Void, Never>?
    @ViewState<Task<Void, Never>?> private var task: Task<Void, Never>?
    private var configuration: GraphQLConfiguration { request.graphql ?? GraphQLConfiguration() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Use GraphQL JSON POST", isOn: Binding(get: { request.graphql != nil }, set: { value in
                if value { request.graphql = GraphQLConfiguration(); request.method = .POST; request.bodyMode = .text }
                else { cancel(); request.graphql = nil; names = []; typeCount = 0 }
            }))
            Text("Uses the endpoint and auth/header/TLS settings above. GraphQL owns the outgoing JSON body and Content-Type while enabled. Server GraphQL errors appear separately from HTTP status. Raw body settings remain available when disabled.").font(.caption).foregroundStyle(.secondary)
            if request.graphql != nil {
                TextField("Operation name (optional)", text: binding(\.operationName))
                HSplitView {
                    VStack(alignment: .leading) { Text("Query"); CodeEditor(text: binding(\.query), contentType: "application/graphql", completions: names, label: "GraphQL query editor") }
                    VStack(alignment: .leading) { Text("Variables (JSON object)"); CodeEditor(text: binding(\.variables), contentType: "application/json", completions: [], label: "GraphQL variables editor") }
                }
                HStack {
                    Button(loading ? "Loading…" : "Introspect endpoint") { introspect(automatic: false) }.disabled(loading)
                    Button("Load schema JSON offline…") { loadOffline() }.disabled(loading)
                    if loading { Button("Cancel") { cancel() } }
                    Toggle("Introspect on endpoint changes", isOn: binding(\.introspectOnEndpointChange))
                }.font(.caption)
                Text("Opt-in automatic introspection may send the selected auth to each edited endpoint. It runs only while this editor is visible; imports disable it. Failed/disabled introspection never retries automatically. Completion is a schema-name prefix list, not a type-aware language server (Ctrl+Space/Escape).").font(.caption).foregroundStyle(.secondary)
                HStack { Text(status).font(.caption); Spacer(); TextField("Find schema name", text: $schemaSearch).frame(width: 200) }
                ScrollView(.horizontal) { Text(names.filter { schemaSearch.isEmpty || $0.localizedCaseInsensitiveContains(schemaSearch) }.prefix(100).joined(separator: " · ")).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(height: 35)
                if configuration.schemaEndpoint != nil && configuration.schemaEndpoint != request.url { Text("The saved schema is from another endpoint; reload explicitly or enable endpoint-change introspection.").font(.caption).foregroundStyle(.orange) }
            }
        }.padding(18)
        .onAppear { readSaved() }
        .onDisappear { cancel(); schemaTask?.cancel(); schemaTask = nil }
        .onChange(of: request.url) { _, _ in
            guard configuration.introspectOnEndpointChange else { return }
            cancel(); let id = generation
            task = Task { do { try await Task.sleep(for: .milliseconds(600)); if generation == id { introspect(automatic: true) } } catch { } }
        }
        .onChange(of: request.graphql?.schemaSnapshot) { _, _ in readSaved() }
    }
    private func binding<T>(_ key: WritableKeyPath<GraphQLConfiguration, T>) -> Binding<T> {
        Binding(get: { configuration[keyPath: key] }, set: { value in var copy = configuration; copy[keyPath: key] = value; request.graphql = copy })
    }
    private func cancel() { generation = UUID(); task?.cancel(); task = nil; loading = false }
    private func readSaved() {
        guard let snapshot = configuration.schemaSnapshot else { names = []; typeCount = 0; return }
        schemaTask?.cancel()
        let worker = Task.detached { try GraphQLSchema(snapshot) }
        schemaTask = Task {
            do {
                let schema = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                if request.graphql?.schemaSnapshot == snapshot { names = schema.names; typeCount = schema.typeCount; status = "\(typeCount) types · \(names.count) completion names (saved schema)" }
            } catch { if !Task.isCancelled { status = "Saved schema is invalid; reload explicitly" } }
        }
    }
    private func introspect(automatic: Bool) {
        guard request.graphql != nil else { return }
        let snapshot = request, environment = store.environment, profiles = store.workspace.authProfiles ?? [], tls = store.workspace.tlsProfiles ?? [], secrets = NamedSecretResolver(catalog: store.workspace.namedSecrets ?? [])
        if let profile = tls.first(where: { $0.id == snapshot.tlsProfileID }), profile.mode == .insecure {
            if automatic { status = "Automatic introspection skipped for insecure TLS; run manually"; return }
            guard confirmStreamTLS(snapshot, profiles: tls) else { return }
        }
        cancel(); let id = generation; loading = true
        task = Task {
            defer { if generation == id { loading = false; task = nil } }
            do {
                let data = try await GraphQL.introspect(snapshot, environment: environment, profiles: profiles, secrets: secrets, tlsProfiles: tls)
                try Task.checkCancellation()
                guard generation == id, request == snapshot, store.environment == environment, (store.workspace.authProfiles ?? []) == profiles, (store.workspace.tlsProfiles ?? []) == tls, (store.workspace.namedSecrets ?? []) == secrets.catalog else { return }
                request.graphql?.schemaEndpoint = snapshot.url; request.graphql?.schemaSnapshot = data
                status = "Schema loaded; save this request to retain it offline"
            } catch { if generation == id && !Task.isCancelled { status = error.localizedDescription } }
        }
    }
    private func loadOffline() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        cancel(); let id = generation; loading = true
        task = Task {
            defer { if generation == id { loading = false; task = nil } }
            let worker = Task.detached { let data = try BoundedFileInput.read(url, limit: 8 * 1024 * 1024); _ = try GraphQLSchema(data); return data }
            do {
                let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                if generation == id && request.graphql != nil { request.graphql?.schemaSnapshot = data; request.graphql?.schemaEndpoint = request.url }
            } catch { if generation == id && !Task.isCancelled { status = error.localizedDescription } }
        }
    }
}
@MainActor func confirmStreamTLS(_ request: RequestDraft, profiles: [TLSProfile]) -> Bool {
    guard let profile = profiles.first(where: { $0.id == request.tlsProfileID }), profile.mode == .insecure else { return true }
    let alert = NSAlert(); alert.messageText = "Connect with insecure TLS?"; alert.informativeText = "The selected profile disables certificate and hostname verification for this connection."
    alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Connect with Insecure TLS")
    return alert.runModal() == .alertSecondButtonReturn
}
