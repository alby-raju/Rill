import RillCore
import SwiftUI
import UniformTypeIdentifiers

struct GRPCWorkbenchView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<GRPCConfiguration> private var configuration = GRPCConfiguration()
    @ViewState<ProtobufSchema?> private var schema: ProtobufSchema?
    @ViewState<String> private var selection = ""
    @ViewState<String> private var mode = "All"
    @ViewState<String> private var search = ""
    @ViewState<String> private var message = "{}"
    @ViewState<[URL]> private var roots = []
    @ViewState<GRPCSession> private var session = GRPCSession()
    @ViewState<[StreamRecord]> private var records = []
    @ViewState<Int> private var bytes = 0
    @ViewState<Bool> private var busy = false
    @ViewState<Bool> private var running = false
    @ViewState<Bool> private var halfClosed = false
    @ViewState<String> private var status = "No descriptors loaded"
    @ViewState<String?> private var error: String?
    @ViewState<UUID> private var generation = UUID()
    @ViewState<Task<Void, Never>?> private var operation: Task<Void, Never>?
    private var selected: ProtobufMethod? { schema?.methods.first { $0.id == selection } }
    private var streamingInput: Bool {
        selected?.mode == .clientStreaming || selected?.mode == .bidirectional
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("gRPC workbench").font(.title2)
                Spacer()
                Text(status).font(.caption)
                Button("Done") {
                    stop()
                    dismiss()
                }.keyboardShortcut(.cancelAction)
            }
            Text(
                "Native HTTP/2; grpc/http explicitly selects plaintext, grpcs/https verifies system TLS and hostname. No external grpcurl or generated application stubs. Metadata and decoded messages may contain secrets; this transient timeline is never written to history/reports. One call per session, 1 MiB wire messages, 1,000 records/8 MiB timeline."
            ).font(.caption).foregroundStyle(.secondary)
            connectionControls
            HSplitView {
                VStack(alignment: .leading) {
                    definitionControls
                    TextField("Find service/method", text: $search)
                    Picker("Call mode", selection: $mode) {
                        Text("All").tag("All")
                        ForEach(GRPCCallMode.allCases, id: \.self) {
                            Text($0.rawValue).tag($0.rawValue)
                        }
                    }
                    List(selection: $selection) {
                        ForEach(
                            (schema?.methods ?? []).filter {
                                (mode == "All" || $0.mode.rawValue == mode)
                                    && (search.isEmpty
                                        || $0.id.localizedCaseInsensitiveContains(search))
                            }
                        ) { method in
                            VStack(alignment: .leading) {
                                Text(method.id).font(.system(.caption, design: .monospaced))
                                Text(method.mode.rawValue).font(.caption2).foregroundStyle(
                                    .secondary)
                            }.tag(method.id)
                        }
                    }
                    Text(
                        "Metadata: lowercase keys; -bin values are base64. Selected environment/named-secret templates resolve only for explicit network actions."
                    ).font(.caption).foregroundStyle(.secondary)
                    FieldEditor(fields: $configuration.metadata, noun: "metadata").frame(
                        height: 150
                    ).disabled(running || busy)
                }.frame(minWidth: 340, idealWidth: 390)
                VStack(alignment: .leading) {
                    if let selected {
                        Text(selected.inputType + " → " + selected.outputType).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    CodeEditor(
                        text: $message, contentType: "application/json", completions: [],
                        label: "Protobuf JSON message"
                    ).frame(minHeight: 170, idealHeight: 210, maxHeight: 250)
                    HStack {
                        Button("Start call") { start() }.disabled(
                            running || busy || selected == nil)
                        Button("Send message") { send() }.disabled(
                            !running || !streamingInput || halfClosed || busy)
                        Button("Finish sending") { finishSending() }.disabled(
                            !running || !streamingInput || halfClosed || busy)
                        Button("Cancel call") { stop() }.disabled(!running && !busy)
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(records) { record in
                                Text(record.direction.rawValue + " · " + record.kind.rawValue).font(
                                    .caption
                                ).foregroundStyle(.secondary)
                                Text(preview(record)).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Divider()
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("\(records.count) records · \(bytes) bytes retained").font(.caption)
                        .foregroundStyle(.secondary)
                }.padding(.leading, 12).frame(minWidth: 570)
            }
        }.padding(24).frame(width: 1150, height: 800)
            .onDisappear { stop() }
            .onChange(of: selection) { _, _ in
                stop()
                message = "{}"
            }
            .onChange(of: mode) { _, _ in stop() }
    }
    private var connectionControls: some View {
        HStack {
            TextField("Explicit grpc(s):// host:port", text: $configuration.endpoint).font(
                .system(.body, design: .monospaced)
            ).disabled(running || busy)
            Text("Deadline (seconds)")
            TextField("Deadline", value: $configuration.timeout, format: .number).frame(width: 70)
                .disabled(running || busy)
            Button("Discover by reflection") { reflect() }.disabled(running || busy)
        }
    }
    private var definitionControls: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Load .proto / descriptor set…") { load() }.disabled(running || busy)
                Button("Add import folder…") { addRoot() }.disabled(running || busy)
            }
            Text("\(roots.count) additional import folders · \(schema?.methods.count ?? 0) methods")
                .font(.caption).foregroundStyle(.secondary)
            Text(
                "Loads use the bundled compiler with bounded imports/deadline. Reflection tries v1 then v1alpha only when unimplemented. Source/descriptor loading works when reflection is disabled. Extensions, groups and Editions require separate support."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func preview(_ record: StreamRecord) -> String {
        if record.kind == .binary {
            return record.data.prefix(8192).base64EncodedString()
                + "\n(raw Protobuf binary preview)"
        }
        return String(decoding: record.data.prefix(65536), as: UTF8.self)
            + (record.data.count > 65536 ? "\n(preview limited to 64 KiB)" : "")
    }
    private func add(_ record: StreamRecord, id: UUID) {
        guard generation == id else { return }
        guard records.count < 1000, bytes <= 8 * 1024 * 1024 - record.data.count else {
            error = "Decoded timeline limit reached; call cancelled."
            stop()
            return
        }
        records.append(record)
        bytes += record.data.count
        if record.kind == .close {
            running = false
            status = "Completed"
        }
        if record.kind == .error {
            running = false
            status = "Failed/cancelled"
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        operation?.cancel()
        busy = true
        error = nil
        let id = generation
        operation = Task {
            defer {
                if generation == id {
                    busy = false
                    operation = nil
                }
            }
            do { try await action() } catch {
                if generation == id && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    private func resolvedConfiguration() async throws -> GRPCConfiguration {
        let snapshot = configuration
        let values = WorkflowEngine.variables(in: store.environment)
        let secrets = NamedSecretResolver(catalog: store.workspace.namedSecrets ?? [])
        let worker = Task.detached {
            var config = snapshot
            func resolve(_ text: String) throws -> String {
                try VariableExpansion.resolve(
                    text, values: values, secretLookup: { try secrets.resolve($0) })
            }
            config.endpoint = try resolve(config.endpoint)
            for index in config.metadata.indices {
                config.metadata[index].name = try resolve(config.metadata[index].name)
                config.metadata[index].value = try resolve(config.metadata[index].value)
            }
            return config
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
    private func encode(_ text: String, schema: ProtobufSchema, method: ProtobufMethod) async throws
        -> Data
    {
        let values = WorkflowEngine.variables(in: store.environment)
        let secrets = NamedSecretResolver(catalog: store.workspace.namedSecrets ?? [])
        let worker = Task.detached {
            let resolved = try VariableExpansion.resolve(
                text, values: values, secretLookup: { try secrets.resolve($0) })
            return try schema.encode(json: resolved, message: method.inputType)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
    private func load() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data, .sourceCode]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let roots = roots
        let id = generation
        perform {
            let loaded: ProtobufSchema
            if url.pathExtension == "proto" {
                loaded = try await ProtobufCompiler.compile(url, importRoots: roots)
            } else {
                let worker = Task.detached {
                    try ProtobufSchema(
                        descriptorSet: BoundedFileInput.read(url, limit: 8 * 1024 * 1024))
                }
                loaded = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
            }
            try Task.checkCancellation()
            guard generation == id else { return }
            schema = loaded
            selection = loaded.methods.first?.id ?? ""
            status = "Descriptors loaded offline"
        }
    }
    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url, roots.count < 8, !roots.contains(url) {
            roots.append(url)
        }
    }
    private func reflect() {
        let id = generation
        perform {
            let config = try await resolvedConfiguration()
            let loaded = try await GRPCReflection.discover(config)
            try Task.checkCancellation()
            if generation == id {
                schema = loaded
                selection = loaded.methods.first?.id ?? ""
                status = "Reflection descriptors loaded"
            }
        }
    }
    private func start() {
        guard let schema, let method = selected else { return }
        let text = message
        generation = UUID()
        let id = generation
        records = []
        bytes = 0
        halfClosed = !streamingInput
        perform {
            let config = try await resolvedConfiguration()
            let initial = try await encode(text, schema: schema, method: method)
            try Task.checkCancellation()
            guard generation == id else { return }
            running = true
            status = "Calling \(method.mode.rawValue)…"
            do {
                try await session.start(
                    config, method: method, initialMessage: initial,
                    onRecord: { record in
                        var display = record
                        if record.kind == .binary {
                            let type =
                                record.direction == .inbound ? method.outputType : method.inputType
                            if let json = try? schema.decode(data: record.data, message: type) {
                                display = StreamRecord(
                                    direction: record.direction, kind: .text, data: Data(json.utf8))
                            }
                        }
                        let value = display
                        await MainActor.run { add(value, id: id) }
                    })
            } catch {
                running = false
                throw error
            }
        }
    }
    private func send() {
        guard let schema, let method = selected else { return }
        let text = message
        perform {
            let data = try await encode(text, schema: schema, method: method)
            try Task.checkCancellation()
            try await session.send(data)
        }
    }
    private func finishSending() {
        perform {
            try await session.finishSending()
            halfClosed = true
        }
    }
    private func stop() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        busy = true
        running = false
        halfClosed = true
        let id = generation
        Task {
            await session.stop()
            if generation == id {
                busy = false
                status = schema == nil ? "No descriptors loaded" : "Ready"
            }
        }
    }
}
