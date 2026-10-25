import RillCore
import SwiftUI

struct KafkaWorkbenchView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<KafkaConfiguration> private var configuration = KafkaConfiguration()
    @ViewState<KafkaSession> private var session = KafkaSession()
    @ViewState<String> private var partition = ""
    @ViewState<String> private var payload = "{\"hello\":\"Rill\"}"
    @ViewState<String> private var key = ""
    @ViewState<String> private var contentType = "application/json"
    @ViewState<Bool> private var cloudEvent = false
    @ViewState<String> private var eventSource = "/rill"
    @ViewState<String> private var eventType = "app.rill.message"
    @ViewState<Bool> private var busy = false
    @ViewState<Bool> private var running = false
    @ViewState<Bool> private var sending = false
    @ViewState<[StreamRecord]> private var records = []
    @ViewState<Int> private var bytes = 0
    @ViewState<String> private var status = "Disconnected"
    @ViewState<String?> private var error: String?
    @ViewState<UUID> private var generation = UUID()
    @ViewState<Task<Void, Never>?> private var connectionTask: Task<Void, Never>?
    @ViewState<Task<Void, Never>?> private var sendTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Kafka workbench").font(.title2)
                Spacer()
                Text(status).font(.caption)
                Button("Done") {
                    stop()
                    dismiss()
                }.keyboardShortcut(.cancelAction)
            }
            Text(
                "Native librdkafka, no JVM. Connecting discovers advertised brokers and inspects existing partitions from their current end without committing offsets. Manual assignment does not balance a consumer group or give an atomic start across partitions. Native connectivity retries may occur until the five-minute session deadline; publishing has no application retries and waits for broker acknowledgement."
            ).font(.caption).foregroundStyle(.secondary)
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        settings.disabled(running || busy)
                        HStack {
                            Button("Connect and inspect latest") { connect() }.disabled(
                                running || busy)
                            Button("Disconnect") { stop() }.disabled(!running && !busy)
                        }
                        Divider()
                        TextField("Optional UTF-8 message key", text: $key)
                        Toggle("Structured CloudEvent 1.0", isOn: $cloudEvent)
                        if cloudEvent {
                            TextField("Source URI-reference", text: $eventSource)
                            TextField("Event type", text: $eventType)
                        } else {
                            TextField("Content-type header", text: $contentType)
                        }
                        CodeEditor(
                            text: $payload, contentType: "application/json", completions: [],
                            label: "Kafka publish payload"
                        ).frame(minHeight: 190)
                        Button("Publish and wait for acknowledgement") { publish() }.disabled(
                            !running || busy || sending)
                        Text(
                            "Settings/messages stay transient. Selected-environment/named-secret templates resolve for connection credentials. TLS verifies system anchor certificates and broker hostnames. Message bodies cap at 1 MiB; all-partition mode caps at 16 existing partitions (select one for larger topics). Timeline: 1,000 records/8 MiB. No schema registry, administration or topic creation."
                        ).font(.caption).foregroundStyle(.secondary)
                    }.padding(.trailing, 12)
                }.frame(minWidth: 400, idealWidth: 460, maxWidth: 500)
                VStack(alignment: .leading) {
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(records) { record in
                                Text(record.direction.rawValue + " · " + record.kind.rawValue).font(
                                    .caption
                                ).foregroundStyle(.secondary)
                                Text(
                                    String(decoding: record.data.prefix(65536), as: UTF8.self)
                                        + (record.data.count > 65536
                                            ? "\n(preview limited to 64 KiB)" : "")
                                ).font(.system(.caption, design: .monospaced)).textSelection(
                                    .enabled)
                                Divider()
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("\(records.count) records · \(bytes) bytes retained").font(.caption)
                        .foregroundStyle(.secondary)
                }.padding(.leading, 12).frame(minWidth: 420)
            }
        }.padding(24).frame(width: 1080, height: 760)
            .onDisappear { stop() }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                "Bootstrap host:port pairs, comma-separated", text: $configuration.bootstrapServers)
            TextField("Existing topic", text: $configuration.topic)
            TextField("Group ID (offsets never committed)", text: $configuration.groupID)
            TextField("Partition (blank: all, at most 16)", text: $partition)
            Picker("Security", selection: $configuration.security) {
                ForEach(KafkaSecurity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if configuration.security == .saslPlaintext || configuration.security == .saslTLS {
                TextField("SASL/PLAIN username", text: $configuration.username)
                SecureField("Password or {{secret:name}}", text: $configuration.password)
            }
            HStack {
                Text("Operation timeout (seconds)")
                TextField("Timeout", value: $configuration.timeout, format: .number).frame(
                    width: 70)
            }
        }
    }
    private func connect() {
        var snapshot = configuration
        if !partition.isEmpty {
            guard let value = Int(partition), value >= 0, value <= Int(Int32.max) else {
                error = "Choose a nonnegative partition number or leave it blank."
                return
            }
            snapshot.partition = value
        } else {
            snapshot.partition = nil
        }
        let settings = snapshot
        let variables = WorkflowEngine.variables(in: store.environment)
        let secrets = NamedSecretResolver(catalog: store.workspace.namedSecrets ?? [])
        generation = UUID()
        let id = generation
        busy = true
        error = nil
        records = []
        bytes = 0
        status = "Connecting…"
        connectionTask = Task {
            defer {
                if generation == id {
                    busy = false
                    connectionTask = nil
                }
            }
            let worker = Task.detached {
                var resolved = settings
                func resolve(_ text: String) throws -> String {
                    try VariableExpansion.resolve(
                        text, values: variables, secretLookup: { try secrets.resolve($0) })
                }
                resolved.bootstrapServers = try resolve(resolved.bootstrapServers)
                resolved.topic = try resolve(resolved.topic)
                resolved.groupID = try resolve(resolved.groupID)
                resolved.username = try resolve(resolved.username)
                resolved.password = try resolve(resolved.password)
                return resolved
            }
            do {
                let resolved = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard generation == id else { return }
                try await session.start(
                    resolved, onRecord: { record in await MainActor.run { add(record, id: id) } })
            } catch {
                if generation == id {
                    running = false
                    status = "Disconnected"
                    self.error =
                        "Kafka connection did not complete. Check endpoint, topic, authentication and TLS settings."
                }
            }
        }
    }
    private func add(_ record: StreamRecord, id: UUID) {
        guard generation == id else { return }
        guard records.count < 1000, bytes <= 8 * 1024 * 1024 - record.data.count else {
            error = "Timeline limit reached; disconnected."
            stop()
            return
        }
        records.append(record)
        bytes += record.data.count
        if record.kind == .open {
            running = true
            status = "Inspecting latest"
        }
        if record.kind == .error || record.kind == .close {
            running = false
            status = "Session ended"
        }
    }
    private func publish() {
        let data: Data
        let type: String?
        let messageKey = key.isEmpty ? nil : Data(key.utf8)
        let id = generation
        do {
            data =
                cloudEvent
                ? try CloudEvents.structured(source: eventSource, type: eventType, data: payload)
                : Data(payload.utf8)
            type = cloudEvent ? CloudEvents.contentType : (contentType.isEmpty ? nil : contentType)
        } catch {
            self.error = error.localizedDescription
            return
        }
        sending = true
        error = nil
        sendTask = Task {
            defer {
                if generation == id {
                    sending = false
                    sendTask = nil
                }
            }
            do { try await session.publish(data, key: messageKey, contentType: type) } catch {
                if generation == id {
                    self.error =
                        "Kafka publish was not acknowledged. Check the session and message settings."
                }
            }
        }
    }
    private func stop() {
        generation = UUID()
        let id = generation
        connectionTask?.cancel()
        connectionTask = nil
        sendTask?.cancel()
        sendTask = nil
        running = false
        busy = true
        sending = false
        status = "Disconnecting…"
        Task {
            await session.stop()
            if generation == id {
                busy = false
                status = "Disconnected"
            }
        }
    }
}
