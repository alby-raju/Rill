import SwiftUI
import UniformTypeIdentifiers
import RillCore

struct APIToolsView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<String> private var section = "Definitions"
    @ViewState<String> private var remoteURL = ""
    @ViewState<UUID?> private var refreshID: UUID?
    @ViewState<APIDefinition?> private var preview: APIDefinition?
    @ViewState<String> private var schema = #"{"type":"object"}"#
    @ViewState<String> private var instance = "{}"
    @ViewState<String> private var result = ""
    @ViewState<String?> private var error: String?
    @ViewState<Bool> private var busy = false
    @ViewState<Task<Void, Never>?> private var task: Task<Void, Never>?
    @ViewState<UUID> private var generation = UUID()
    @ViewState<MockServer> private var server = MockServer()
    @ViewState<String> private var mockAddress = ""
    @ViewState<Int> private var port = 0
    @ViewState<String> private var mockJSON = #"[{"method":"GET","path":"/hello","status":200,"headers":{"Content-Type":"application/json"},"body":"{\"message\":\"hello\"}"}]"#
    @ViewState<ActiveProbeKind> private var probe = .reflection
    @ViewState<String> private var probeURL = ""
    @ViewState<String> private var queryName = ""
    @ViewState<HTTPMethod> private var probeMethod = .GET
    @ViewState<Int> private var sampleCount = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("API definitions and tools").font(.title2); Spacer(); if busy { Button("Cancel") { task?.cancel() } }; Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Picker("Tool", selection: $section) { ForEach(["Definitions", "Schema", "Mocks", "Inspection"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).disabled(busy)
            Group {
                switch section {
                case "Definitions": definitions
                case "Schema": schemas
                case "Mocks": mocks
                default: inspection
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(24).frame(width: 1000, height: 740)
        .onAppear { probeURL = store.selected?.url ?? "" }
        .onDisappear { generation = UUID(); task?.cancel(); let server = server; Task { await server.stop() } }
        .onChange(of: section) { _, _ in result = ""; error = nil }
        .onChange(of: schema) { _, _ in result = "" }
        .onChange(of: instance) { _, _ in result = "" }
        .onChange(of: refreshID) { _, _ in preview = nil }
        .onChange(of: remoteURL) { _, _ in preview = nil }
    }
    private var definitions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local JSON/YAML or an explicit URL. No references, external examples or endpoints are fetched automatically. Review generated samples and setup gaps before Apply; source snapshots may contain secrets.").font(.caption).foregroundStyle(.secondary)
            Picker("Import or refresh", selection: $refreshID) {
                Text("Import as a new source").tag(nil as UUID?)
                ForEach(store.workspace.apiDefinitions ?? []) { Text($0.title + " · " + String($0.id.uuidString.prefix(8))).tag(Optional($0.id)) }
            }.disabled(busy)
            HStack {
                Button("Load local definition…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .yaml]
                    guard panel.runModal() == .OK, let url = panel.url else { return }; loadFile(url)
                }
                TextField("https://example.test/openapi.json", text: $remoteURL)
                Button("Fetch this URL") { fetch() }.disabled(remoteURL.isEmpty)
            }.disabled(busy)
            if let preview {
                Text(preview.source.title + " · " + preview.source.version + " · \(preview.operations.count) operations").font(.headline)
                HStack {
                    Button("Review changes and Apply…") { let definition = preview, id = refreshID; perform { _ = await store.applyAPIDefinition(definition, refreshing: id) } }
                    Button("Generate editable mock routes") {
                        perform {
                            let routes = try await detached { try DefinitionMocks.routes(preview) }
                            mockJSON = String(decoding: try MockRouteFile.encode(routes), as: UTF8.self); section = "Mocks"
                        }
                    }
                }.disabled(busy)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(preview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        ForEach(preview.operations, id: \.key) { operation in
                            Text(operation.key).font(.system(.body, design: .monospaced))
                            ForEach(Array(operation.gaps.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { Text("Load a definition to preview operations and positive test expectations.").foregroundStyle(.secondary) }
            if let refreshID, let source = store.workspace.apiDefinitions?.first(where: { $0.id == refreshID }) {
                Button("Reload saved snapshot offline") { perform { preview = try await detached { try APIDefinitionLoader.parse(source.snapshot, location: source.location, sourceID: source.id) } } }.disabled(busy)
            }
        }
    }
    private var schemas: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Explicit JSON Schema subset. Unsupported rules and external references cannot pass; instance values are omitted from findings. JSON input limit: 8 MiB; validation depth: 64.").font(.caption).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading) { Text("Schema JSON"); CodeEditor(text: $schema, contentType: "application/json", completions: []).disabled(busy) }
                VStack(alignment: .leading) { Text("Instance JSON"); CodeEditor(text: $instance, contentType: "application/json", completions: []).disabled(busy) }
            }
            Button("Validate instance") {
                let schema = Data(schema.utf8), instance = Data(instance.utf8)
                perform {
                    let validation = try await detached { try JSONSchema.validate(instance: instance, schema: schema) }
                    if validation.valid { result = "Valid for the supported subset" }
                    else {
                        let findings: [String] = validation.findings.map { finding in
                            let path = finding.path.isEmpty ? "/" : finding.path
                            return "\(finding.keyword) at \(path): \(finding.message)"
                        }
                        let unsupported = validation.unsupported.map { "Unsupported: " + $0 }
                        result = (findings + unsupported).joined(separator: "\n")
                    }
                }
            }.disabled(busy)
            ScrollView { Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 130)
        }
    }
    private var mocks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loopback-only HTTP mock server. Edit method/path/status/headers/body JSON. Paths can use {parameter} segments. No scripts run. Mock responses are examples, not proof of schema conformance. Closing this window stops the server.").font(.caption).foregroundStyle(.secondary)
            CodeEditor(text: $mockJSON, contentType: "application/json", completions: []).disabled(!mockAddress.isEmpty || busy)
            HStack {
                Text("Port (0 chooses a free port)"); TextField("Port", value: $port, format: .number).frame(width: 90).disabled(!mockAddress.isEmpty || busy)
                Button("Start mock server") {
                    guard (0...65535).contains(port) else { error = "Choose a port between 0 and 65535."; return }
                    let data = Data(mockJSON.utf8), port = UInt16(port)
                    perform { let routes = try await detached { try MockRouteFile.decode(data) }; mockAddress = try await server.start(routes: routes, port: port).absoluteString }
                }.disabled(busy || !mockAddress.isEmpty)
                Button("Stop") { perform { await server.stop(); mockAddress = "" } }.disabled(busy || mockAddress.isEmpty)
                Text(mockAddress).textSelection(.enabled)
            }
        }
    }
    private var inspection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Inspect current response headers (no traffic)") {
                guard let response = store.response else { error = "Send or select a response first."; return }
                let findings = SecurityInspection.passive(response)
                result = findings.isEmpty ? "No indicators in this limited header check; this is not security certification." : findings.map { $0.rule + ": " + $0.evidence + "\n" + $0.guidance }.joined(separator: "\n\n")
            }.disabled(busy)
            Divider()
            Text("Active probes send additional unauthenticated requests to the exact URL below. They do not use selected request auth, headers or hooks. Query probes modify one existing query value and may re-encode the query; rate samples send at most ten sequential requests. Use targets you are authorized to test.").font(.caption).foregroundStyle(.secondary)
            TextField("Explicit target URL", text: $probeURL).disabled(busy)
            HStack {
                Picker("Method", selection: $probeMethod) { Text("GET").tag(HTTPMethod.GET); Text("HEAD").tag(HTTPMethod.HEAD) }
                Picker("Probe", selection: $probe) { ForEach(ActiveProbeKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                if probe == .rate { Stepper("Samples: \(sampleCount)", value: $sampleCount, in: 1...10) }
                else { TextField("One existing query name", text: $queryName) }
            }.disabled(busy)
            Button("Send explicit probe requests") {
                let url = probeURL, method = probeMethod, kind = probe, name = queryName, count = probe == .rate ? sampleCount : 1
                perform {
                    let report = try await ActiveProbes.run(url: url, method: method, kind: kind, queryName: name, count: count)
                    result = "Statuses: " + report.statuses.map(String.init).joined(separator: ", ") + " · Cancelled: \(report.cancelled)\n\n" + report.findings.map { $0.evidence + "\n" + $0.guidance }.joined(separator: "\n\n")
                }
            }.disabled(busy || probeURL.isEmpty)
            ScrollView { Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
    private func loadFile(_ url: URL) { perform { preview = try await detached { try APIDefinitionLoader.load(url) } } }
    private func fetch() { let url = remoteURL; perform { preview = try await APIDefinitionLoader.fetch(url) } }
    private func detached<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached { try Task.checkCancellation(); return try operation() }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); return result
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; task?.cancel(); generation = UUID(); let id = generation; busy = true; error = nil
        task = Task {
            defer { if generation == id { busy = false; task = nil } }
            do { try await operation() }
            catch is CancellationError { }
            catch { if generation == id { self.error = error.localizedDescription } }
        }
    }
}
