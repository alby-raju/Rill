import RillCore
import SwiftUI

struct LiveStreamsView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<String> private var mode = "WebSocket"
    @ViewState<String> private var endpoint = ""
    @ViewState<String> private var outgoing = ""
    @ViewState<String> private var encoding = "Text"
    @ViewState<String> private var initPayload = "{}"
    @ViewState<[StreamRecord]> private var records = []
    @ViewState<Int> private var retainedBytes = 0
    @ViewState<Bool> private var running = false
    @ViewState<Bool> private var busy = false
    @ViewState<Bool> private var sending = false
    @ViewState<Bool> private var terminal = false
    @ViewState<String> private var status = "Disconnected"
    @ViewState<String?> private var error: String?
    @ViewState<UUID> private var generation = UUID()
    @ViewState<Task<Void, Never>?> private var task: Task<Void, Never>?
    @ViewState<WebSocketClient> private var socket = WebSocketClient()
    @ViewState<GraphQLSubscriptionClient> private var subscription = GraphQLSubscriptionClient()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Live protocols").font(.title2)
                Spacer()
                Text(status).font(.caption)
                Button("Done") {
                    stop()
                    dismiss()
                }.keyboardShortcut(.cancelAction)
            }
            Text(
                "Connections use the selected request's auth, headers, environment and TLS settings with the explicit endpoint below. Messages may contain secrets; this timeline is transient and never enters saved history/reports. No automatic reconnect or replay. Limits: 1 MiB/message, 1,000 records/8 MiB timeline, five-minute sessions."
            ).font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Protocol", selection: $mode) {
                    Text("WebSocket").tag("WebSocket")
                    Text("Server-sent events").tag("SSE")
                    Text("GraphQL subscription").tag("Subscription")
                }.frame(width: 250).disabled(busy)
                TextField("Explicit ws(s):// or http(s):// endpoint", text: $endpoint).font(
                    .system(.body, design: .monospaced)
                ).disabled(running || busy)
                Button("Connect") { connect() }.disabled(
                    running || busy || endpoint.isEmpty || store.selected == nil)
                Button("Disconnect") { stop() }.disabled(!running && !busy)
            }
            if mode == "Subscription" {
                Text(
                    "Uses the selected request's GraphQL query/variables with graphql-transport-ws. connection_init JSON is optional and may contain credentials; use named-secret templates where practical. Its expanded payload is omitted from the timeline."
                ).font(.caption).foregroundStyle(.secondary)
                TextField("connection_init payload (JSON object)", text: $initPayload).disabled(
                    running || busy)
            }
            if mode == "WebSocket" {
                HStack {
                    Picker("Send as", selection: $encoding) {
                        Text("Text").tag("Text")
                        Text("Base64 binary").tag("Binary")
                    }.frame(width: 160)
                    TextField("Message", text: $outgoing).font(.system(.body, design: .monospaced))
                    Button("Send") { send() }.disabled(!running || sending || busy)
                    Button("Ping") { ping() }.disabled(!running || sending || busy)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.direction.rawValue + " · " + record.kind.rawValue).font(
                                .caption
                            ).foregroundStyle(record.kind == .error ? .red : .secondary)
                            Text(preview(record)).font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("\(records.count) records · \(retainedBytes) retained bytes").font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear timeline") {
                    records = []
                    retainedBytes = 0
                }.disabled(running || busy)
            }
        }.padding(24).frame(width: 1050, height: 720)
            .onAppear {
                if let request = store.selected {
                    endpoint = request.url
                    if request.graphql != nil {
                        mode = "Subscription"
                        endpoint = websocketURL(endpoint)
                    }
                }
            }
            .onChange(of: mode) { _, value in
                stop()
                if value != "SSE" {
                    endpoint = websocketURL(endpoint)
                } else {
                    endpoint = endpoint.replacingOccurrences(of: "wss://", with: "https://")
                        .replacingOccurrences(of: "ws://", with: "http://")
                }
            }
            .onChange(of: store.selection) { _, _ in stop() }
            .onDisappear { stop() }
    }
    private func websocketURL(_ value: String) -> String {
        value.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(
            of: "http://", with: "ws://")
    }
    private func preview(_ record: StreamRecord) -> String {
        if record.kind == .binary {
            return record.data.prefix(8192).base64EncodedString()
                + (record.data.count > 8192 ? "\n(binary preview limited to 8 KiB)" : "")
        }
        let text = String(decoding: record.data.prefix(65536), as: UTF8.self)
        return text + (record.data.count > 65536 ? "\n(text preview limited to 64 KiB)" : "")
    }
    private func add(_ record: StreamRecord, id: UUID) {
        guard generation == id else { return }
        guard records.count < 1000, retainedBytes <= 8 * 1024 * 1024 - record.data.count else {
            error = "Timeline limit reached; connection stopped."
            stop()
            return
        }
        records.append(record)
        retainedBytes += record.data.count
        if record.kind == .open {
            status = mode == "Subscription" ? "Socket open; GraphQL handshake" : "Connected"
        }
        if record.kind == .close || record.kind == .error {
            terminal = true
            running = false
            status = "Closed"
        }
    }
    private func connect() {
        guard var request = store.selected else { return }
        request.url = endpoint
        let tls = store.workspace.tlsProfiles ?? []
        guard confirmStreamTLS(request, profiles: tls) else { return }
        task?.cancel()
        generation = UUID()
        let id = generation
        let selectedMode = mode
        let environment = store.environment
        let profiles = store.workspace.authProfiles ?? []
        let secrets = NamedSecretResolver(catalog: store.workspace.namedSecrets ?? [])
        let initValue = initPayload
        let snapshot = request
        records = []
        retainedBytes = 0
        running = true
        busy = true
        terminal = false
        error = nil
        status = "Connecting…"
        task = Task {
            defer {
                if generation == id {
                    busy = false
                    task = nil
                }
            }
            do {
                if selectedMode == "SSE" {
                    try await ServerSentEvents.run(
                        snapshot, environment: environment, profiles: profiles, secrets: secrets,
                        tlsProfiles: tls,
                        onEvent: { event in
                            let text =
                                "event: " + event.event + "\nid: " + event.identifier + "\ndata:\n"
                                + event.data
                            await MainActor.run {
                                add(
                                    StreamRecord(
                                        direction: .inbound, kind: .text, data: Data(text.utf8)),
                                    id: id)
                            }
                        })
                    if generation == id {
                        running = false
                        status = "SSE ended (no reconnect)"
                    }
                } else if selectedMode == "Subscription" {
                    guard snapshot.graphql != nil else { throw GraphQLError.invalidInput }
                    try await subscription.start(
                        snapshot, environment: environment, initPayload: initValue,
                        profiles: profiles, secrets: secrets, tlsProfiles: tls,
                        onRecord: { record in await MainActor.run { add(record, id: id) } })
                    if generation == id && !terminal { status = "Subscribed" }
                } else {
                    try await socket.connect(
                        snapshot, environment: environment, profiles: profiles, secrets: secrets,
                        tlsProfiles: tls,
                        onRecord: { record in await MainActor.run { add(record, id: id) } })
                    if generation == id && !terminal { status = "Connected" }
                }
            } catch {
                if generation == id {
                    running = false
                    status = "Disconnected"
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
        }
    }
    private func stop() {
        generation = UUID()
        let id = generation
        task?.cancel()
        task = nil
        running = false
        busy = true
        sending = false
        status = "Disconnecting…"
        Task {
            await subscription.stop()
            await socket.stop()
            if generation == id {
                busy = false
                status = "Disconnected"
            }
        }
    }
    private func send() {
        let text = outgoing
        let binary = encoding == "Binary"
        let id = generation
        guard text.utf8.count <= 1400000 else {
            error = "Message exceeds its embedding limit."
            return
        }
        sending = true
        Task {
            defer { if generation == id { sending = false } }
            do {
                if binary {
                    guard let data = Data(base64Encoded: text) else {
                        throw WorkflowError.invalidConfiguration
                    }
                    try await socket.send(data: data)
                } else {
                    try await socket.send(text: text)
                }
            } catch { if generation == id { self.error = error.localizedDescription } }
        }
    }
    private func ping() {
        let id = generation
        sending = true
        Task {
            defer { if generation == id { sending = false } }
            do { try await socket.ping() } catch {
                if generation == id { self.error = error.localizedDescription }
            }
        }
    }
}
