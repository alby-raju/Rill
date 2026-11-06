import RillCore
import SwiftUI
import UniformTypeIdentifiers

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
    @ViewState<ActiveProbeKind> private var probe = .reflection
    @ViewState<String> private var probeURL = ""
    @ViewState<String> private var queryName = ""
    @ViewState<HTTPMethod> private var probeMethod = .GET
    @ViewState<Int> private var sampleCount = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                RillToolHeading(
                    title: "API definitions and tools",
                    subtitle: "Import contracts, validate data and test locally.",
                    icon: "doc.text.magnifyingglass")
                Spacer()
                if busy {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                    Button("Cancel") { task?.cancel() }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            RillTabs(titles: ["Definitions", "Schema", "Mocks", "Inspection"], selection: $section)
                .disabled(busy)
            Group {
                switch section {
                case "Definitions": definitions
                case "Schema": schemas
                case "Mocks": mocks
                default: inspection
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(RillSpacing.sheet).frame(width: 1000, height: 740).rillToolControls()
            .onAppear { probeURL = store.selected?.url ?? "" }
            .onDisappear {
                generation = UUID()
                task?.cancel()

            }
            .onChange(of: section) { _, _ in
                result = ""
                error = nil
            }
            .onChange(of: schema) { _, _ in result = "" }
            .onChange(of: instance) { _, _ in result = "" }
            .onChange(of: refreshID) { _, _ in preview = nil }
            .onChange(of: remoteURL) { _, _ in preview = nil }
    }
    private var definitions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Local JSON/YAML or an explicit URL. No references, external examples or endpoints are fetched automatically. Review generated samples and setup gaps before Apply; source snapshots may contain secrets."
            ).font(.caption).foregroundStyle(.secondary)
            RillSection(
                title: "Definition source",
                subtitle: "Load a local OpenAPI file or fetch a specific URL.",
                icon: "doc.badge.plus"
            ) {
                Picker("Import or refresh", selection: $refreshID) {
                    Text("Import as a new source").tag(nil as UUID?)
                    ForEach(store.workspace.apiDefinitions ?? []) {
                        Text($0.title + " · " + String($0.id.uuidString.prefix(8))).tag(
                            Optional($0.id))
                    }
                }.disabled(busy)
                HStack {
                    Button("Load local definition…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.json, .yaml]
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        loadFile(url)
                    }
                    TextField("https://example.test/openapi.json", text: $remoteURL)
                    Button("Fetch this URL") { fetch() }.disabled(remoteURL.isEmpty)
                }.disabled(busy)
            }
            if let preview {
                Text(
                    preview.source.title + " · " + preview.source.version
                        + " · \(preview.operations.count) operations"
                ).font(.headline)
                HStack {
                    Button("Review changes and Apply…") {
                        let definition = preview
                        let id = refreshID
                        perform { _ = await store.applyAPIDefinition(definition, refreshing: id) }
                    }
                    Button("Generate editable mock routes") {
                        perform {
                            let routes = try await detached { try DefinitionMocks.routes(preview) }
                            let project = MockProject(name: preview.source.title, routes: routes)
                            var projects = store.workspace.mockProjects ?? []
                            projects.append(project)
                            try MockProject.validateStorage(projects)
                            store.workspace.mockProjects = projects
                            section = "Mocks"
                        }
                    }
                }.disabled(busy)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(preview.warnings, id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(preview.operations, id: \.key) { operation in
                            Text(operation.key).font(.system(.body, design: .monospaced))
                            ForEach(Array(operation.gaps.enumerated()), id: \.offset) {
                                Text($0.element).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                RillToolEmpty(
                    title: "No definition loaded",
                    detail:
                        "Load a file or fetch a URL to review operations and setup gaps before importing.",
                    icon: "doc.text.magnifyingglass"
                ).rillToolPanel()
            }
            if let refreshID,
                let source = store.workspace.apiDefinitions?.first(where: { $0.id == refreshID })
            {
                Button("Reload saved snapshot offline") {
                    perform {
                        preview = try await detached {
                            try APIDefinitionLoader.parse(
                                source.snapshot, location: source.location, sourceID: source.id)
                        }
                    }
                }.disabled(busy)
            }
        }
    }
    private var schemas: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Explicit JSON Schema subset. Unsupported rules and external references cannot pass; instance values are omitted from findings. JSON input limit: 8 MiB; validation depth: 64."
            ).font(.caption).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading) {
                    Label("Schema JSON", systemImage: "curlybraces").font(.headline)
                    CodeEditor(text: $schema, contentType: "application/json", completions: [])
                        .disabled(busy)
                }
                VStack(alignment: .leading) {
                    Label("Instance JSON", systemImage: "doc.text").font(.headline)
                    CodeEditor(text: $instance, contentType: "application/json", completions: [])
                        .disabled(busy)
                }
            }
            Button("Validate instance", systemImage: "checkmark.seal") {
                let schema = Data(schema.utf8)
                let instance = Data(instance.utf8)
                perform {
                    let validation = try await detached {
                        try JSONSchema.validate(instance: instance, schema: schema)
                    }
                    if validation.valid {
                        result = "Valid for the supported subset"
                    } else {
                        let findings: [String] = validation.findings.map { finding in
                            let path = finding.path.isEmpty ? "/" : finding.path
                            return "\(finding.keyword) at \(path): \(finding.message)"
                        }
                        let unsupported = validation.unsupported.map { "Unsupported: " + $0 }
                        result = (findings + unsupported).joined(separator: "\n")
                    }
                }
            }.disabled(busy)
            ScrollView {
                Text(result.isEmpty ? "Results will appear here." : result)
                    .textSelection(.enabled).padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 130).rillToolPanel()
        }
    }
    private var mocks: some View {
        MockWorkbenchContent().environmentObject(store)
    }
    private var inspection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RillSection(
                title: "Passive header review",
                subtitle: "Inspect a response already in the Workbench.", icon: "shield"
            ) {
                Button("Inspect current response headers (no traffic)") {
                    guard let response = store.response else {
                        error = "Send or select a response first."
                        return
                    }
                    let findings = SecurityInspection.passive(response)
                    result =
                        findings.isEmpty
                        ? "No indicators in this limited header check; this is not security certification."
                        : findings.map { $0.rule + ": " + $0.evidence + "\n" + $0.guidance }.joined(
                            separator: "\n\n")
                }.disabled(busy)
            }
            RillSection(
                title: "Active probes",
                subtitle: "Send a bounded set of requests to an explicit target.",
                icon: "scope"
            ) {
                Text(
                    "Active probes send additional unauthenticated requests to the exact URL below. They do not use selected request auth, headers or hooks. Query probes modify one existing query value and may re-encode the query; rate samples send at most ten sequential requests. Use targets you are authorized to test."
                ).font(.caption).foregroundStyle(.secondary)
                TextField("Explicit target URL", text: $probeURL).disabled(busy)
                HStack {
                    Picker("Method", selection: $probeMethod) {
                        Text("GET").tag(HTTPMethod.GET)
                        Text("HEAD").tag(HTTPMethod.HEAD)
                    }
                    Picker("Probe", selection: $probe) {
                        ForEach(ActiveProbeKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if probe == .rate {
                        Stepper("Samples: \(sampleCount)", value: $sampleCount, in: 1...10)
                    } else {
                        TextField("One existing query name", text: $queryName)
                    }
                }.disabled(busy)
                Button("Send explicit probe requests") {
                    let url = probeURL
                    let method = probeMethod
                    let kind = probe
                    let name = queryName
                    let count = probe == .rate ? sampleCount : 1
                    perform {
                        let report = try await ActiveProbes.run(
                            url: url, method: method, kind: kind, queryName: name, count: count)
                        result =
                            "Statuses: " + report.statuses.map(String.init).joined(separator: ", ")
                            + " · Cancelled: \(report.cancelled)\n\n"
                            + report.findings.map { $0.evidence + "\n" + $0.guidance }.joined(
                                separator: "\n\n")
                    }
                }.disabled(busy || probeURL.isEmpty)
            }
            Label("Inspection results", systemImage: "list.bullet.rectangle").font(.headline)
            ScrollView {
                Text(result.isEmpty ? "Results will appear here." : result)
                    .textSelection(.enabled).padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.rillToolPanel()
        }
    }
    private func loadFile(_ url: URL) {
        perform { preview = try await detached { try APIDefinitionLoader.load(url) } }
    }
    private func fetch() {
        let url = remoteURL
        perform { preview = try await APIDefinitionLoader.fetch(url) }
    }
    private func detached<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws
        -> T
    {
        let worker = Task.detached {
            try Task.checkCancellation()
            return try operation()
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return result
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        task?.cancel()
        generation = UUID()
        let id = generation
        busy = true
        error = nil
        task = Task {
            defer {
                if generation == id {
                    busy = false
                    task = nil
                }
            }
            do { try await operation() } catch is CancellationError {} catch {
                if generation == id { self.error = error.localizedDescription }
            }
        }
    }
}
