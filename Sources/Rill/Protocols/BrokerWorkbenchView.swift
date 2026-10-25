import SwiftUI
import RillCore

struct BrokerWorkbenchView: View {
    var body: some View {
        TabView {
            MQTTAMQPWorkbenchView().tabItem { Label("MQTT / AMQP", systemImage: "antenna.radiowaves.left.and.right") }
            KafkaWorkbenchView().tabItem { Label("Kafka", systemImage: "arrow.triangle.branch") }
        }.frame(width: 1100, height: 810)
    }
}
struct MQTTAMQPWorkbenchView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<MQTTConfiguration> private var configuration = MQTTConfiguration()
    @ViewState<MQTTClient> private var mqtt = MQTTClient()
    @ViewState<AMQPClient> private var amqp = AMQPClient()
    @ViewState<String> private var protocolName = "MQTT"
    @ViewState<String> private var virtualHost = "/"
    @ViewState<String> private var filter = "events/#"
    @ViewState<String> private var topic = "events/example"
    @ViewState<MQTTQoS> private var qos = .atMostOnce
    @ViewState<Bool> private var retain = false
    @ViewState<String> private var payload = "{\"hello\":\"Rill\"}"
    @ViewState<String> private var contentType = "application/json"
    @ViewState<Bool> private var cloudEvent = false
    @ViewState<String> private var eventSource = "/rill"
    @ViewState<String> private var eventType = "app.rill.message"
    @ViewState<[StreamRecord]> private var timeline = []
    @ViewState<Int> private var retainedBytes = 0
    @ViewState<Bool> private var running = false
    @ViewState<Bool> private var busy = false
    @ViewState<Bool> private var sending = false
    @ViewState<String> private var status = "Disconnected"
    @ViewState<String?> private var error: String?
    @ViewState<UUID> private var generation = UUID()
    @ViewState<Task<Void, Never>?> private var connectionTask: Task<Void, Never>?
    @ViewState<Task<Void, Never>?> private var sendTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Broker workbench").font(.title2); Spacer(); Text(status).font(.caption); Button("Done") { stop(); dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Explicit broker connections. mqtt/tcp use plaintext; mqtts/ssl and wss verify system TLS trust and hostname. ws/wss negotiate mqtt and preserve path/query. No automatic reconnect or redirects. AMQP uses existing queues only: consumption acknowledges received messages and can remove them from the queue. Default-exchange publishing requires broker confirms. Settings and message timelines are transient; passwords can use selected-environment or named-secret templates.").font(.caption).foregroundStyle(.secondary)
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Protocol", selection: $protocolName) { Text("MQTT").tag("MQTT"); Text("AMQP 0-9-1").tag("AMQP") }.disabled(running || busy)
                        connectionSettings.disabled(running || busy)
                        HStack { Button("Connect") { connect() }.disabled(running || busy); Button("Disconnect") { stop() }.disabled(!running && !busy) }
                        Divider()
                        TextField(protocolName == "MQTT" ? "Subscription filter (wildcards allowed)" : "Existing queue to consume", text: $filter)
                        Button("Subscribe and wait for broker acknowledgement") { subscribe() }.disabled(!running || busy || sending)
                        Divider()
                        TextField(protocolName == "MQTT" ? "Concrete publish topic" : "Existing destination queue", text: $topic)
                        if protocolName == "MQTT" {
                        Picker("QoS", selection: $qos) { ForEach(MQTTQoS.allCases, id: \.self) { Text(String($0.rawValue)).tag($0) } }.pickerStyle(.segmented)
                        Toggle("Retain published message", isOn: $retain)
                        }
                        Toggle("Structured CloudEvent 1.0", isOn: $cloudEvent)
                        if cloudEvent { TextField("CloudEvent source URI-reference", text: $eventSource); TextField("CloudEvent type", text: $eventType) }
                        else { TextField("Content type (MQTT 5 / AMQP)", text: $contentType) }
                        Text("Payload (UTF-8; parsed JSON when CloudEvents is enabled)").font(.caption)
                        CodeEditor(text: $payload, contentType: "application/json", completions: [], label: "Broker publish payload").frame(minHeight: 180)
                        Button("Publish") { publish() }.disabled(!running || busy || sending)
                        Text("QoS 0 confirms a local write; QoS 1/2 wait for broker acknowledgements. Separate subscription/publish destinations prevent accidentally publishing to a wildcard. Payloads cap at 1 MiB; sessions at five minutes, 1,000 events and 8 MiB retained data. MQTT 5 metadata is unavailable in 3.1.1.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.trailing, 12)
                }.frame(minWidth: 390, idealWidth: 440, maxWidth: 500)
                VStack(alignment: .leading) {
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(timeline) { record in
                                Text(record.direction.rawValue + " · " + record.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                                Text(String(decoding: record.data.prefix(65536), as: UTF8.self) + (record.data.count > 65536 ? "\n(preview limited to 64 KiB)" : "")).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Divider()
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("\(timeline.count) events · \(retainedBytes) bytes retained").font(.caption).foregroundStyle(.secondary)
                }.padding(.leading, 12).frame(minWidth: 400)
            }
        }.padding(24).frame(width: 1080, height: 760)
        .onDisappear { stop() }
        .onChange(of: protocolName) { _, value in
            stop(); configuration.endpoint = value == "AMQP" ? "amqp://localhost:5672" : "mqtt://localhost:1883"
            filter = value == "AMQP" ? "existing" : "events/#"; topic = value == "AMQP" ? "existing" : "events/example"
        }
    }
    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Broker endpoint", text: $configuration.endpoint)
            if protocolName == "MQTT" {
                Picker("MQTT version", selection: $configuration.version) { ForEach(MQTTVersion.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField("Client identifier", text: $configuration.clientID)
            } else { TextField("Virtual host", text: $virtualHost) }
            TextField("Username", text: $configuration.username)
            SecureField("Password or {{secret:name}}", text: $configuration.password)
            HStack { Text("Operation timeout (seconds)"); TextField("Timeout", value: $configuration.timeout, format: .number).frame(width: 70) }
        }
    }
    private func connect() {
        let resolver = NamedSecretResolver(catalog: store.workspace.namedSecrets ?? [])
        let values = WorkflowEngine.variables(in: store.environment)
        let snapshot = configuration, selectedProtocol = protocolName, vhost = virtualHost
        generation = UUID(); let id = generation
        timeline = []; retainedBytes = 0; error = nil; busy = true; status = "Connecting…"
        connectionTask = Task {
            defer { if generation == id { busy = false; connectionTask = nil } }
            let worker = Task.detached {
                var settings = snapshot
                func resolve(_ text: String) throws -> String { try VariableExpansion.resolve(text, values: values, secretLookup: { try resolver.resolve($0) }) }
                settings.endpoint = try resolve(settings.endpoint); settings.username = try resolve(settings.username); settings.password = try resolve(settings.password); settings.clientID = try resolve(settings.clientID)
                return settings
            }
            do {
                let settings = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); guard generation == id else { return }
                if selectedProtocol == "AMQP" {
                    var config = AMQPConfiguration(); config.endpoint = settings.endpoint; config.username = settings.username; config.password = settings.password; config.virtualHost = vhost; config.timeout = settings.timeout
                    try await amqp.connect(config, onEvent: { event in await MainActor.run { receiveAMQP(event, id: id) } })
                } else { try await mqtt.connect(settings, onEvent: { event in await MainActor.run { receive(event, id: id) } }) }
            } catch { if generation == id { status = "Disconnected"; running = false; self.error = "Broker connection did not complete. " + error.localizedDescription } }
        }
    }
    private func receiveAMQP(_ event: AMQPEvent, id: UUID) {
        guard generation == id else { return }
        switch event {
        case .connected: running = true; status = "Connected"; add(.system, .open, Data("AMQP connected".utf8))
        case .delivery(let message):
            let metadata = "Routing key: \(message.routingKey) · redelivered \(message.redelivered)\nContent-Type: \(message.contentType ?? "(absent)")\n"
            add(.inbound, .text, Data(metadata.utf8) + message.payload)
        case .acknowledged: add(.system, .text, Data("Publish confirmed by broker".utf8))
        case .error(let message): error = message; add(.system, .error, Data(message.utf8))
        case .closed: running = false; status = "Disconnected"; add(.system, .close, Data("AMQP closed".utf8))
        }
    }

    private func receive(_ event: BrokerSessionEvent, id: UUID) {
        guard generation == id else { return }
        switch event {
        case .connected: running = true; status = "Connected"; add(.system, .open, Data("MQTT connected".utf8))
        case .message(let message):
            let metadata = "Topic: \(message.destination) · QoS \(message.qos.rawValue) · retained \(message.retained)\nContent-Type: \(message.contentType ?? "(absent)")\n"
            add(.inbound, .text, Data(metadata.utf8) + message.payload)
        case .acknowledged(let message): add(.system, .text, Data(message.utf8))
        case .error(let message): error = message; add(.system, .error, Data(message.utf8))
        case .closed: running = false; status = "Disconnected"; add(.system, .close, Data("MQTT closed".utf8))
        }
    }
    private func add(_ direction: StreamDirection, _ kind: StreamKind, _ data: Data) {
        guard timeline.count < 1000, retainedBytes <= 8 * 1024 * 1024 - data.count else { error = "Timeline limit reached; disconnected."; stop(); return }
        timeline.append(StreamRecord(direction: direction, kind: kind, data: data)); retainedBytes += data.count
    }
    private func subscribe() {
        let filter = filter, qos = qos, id = generation, isAMQP = protocolName == "AMQP"; sending = true
        sendTask = Task { defer { if generation == id { sending = false; sendTask = nil } }; do { if isAMQP { try await amqp.consume(queue: filter) } else { try await mqtt.subscribe(filter, qos: qos) } } catch { if generation == id { self.error = error.localizedDescription } } }
    }
    private func publish() {
        let topic = topic, qos = qos, retain = retain, id = generation, isAMQP = protocolName == "AMQP"
        let data: Data, type: String?
        do {
            data = cloudEvent ? try CloudEvents.structured(source: eventSource, type: eventType, data: payload) : Data(payload.utf8)
            type = cloudEvent ? CloudEvents.contentType : (contentType.isEmpty ? nil : contentType)
            guard isAMQP || configuration.version == .v5 || type == nil else { throw BrokerError.configuration }
        } catch { self.error = error.localizedDescription; return }
        sending = true
        sendTask = Task { defer { if generation == id { sending = false; sendTask = nil } }; do { if isAMQP { try await amqp.publish(queue: topic, payload: data, contentType: type) } else { try await mqtt.publish(topic: topic, payload: data, qos: qos, retain: retain, contentType: type, payloadIsUTF8: true) } } catch { if generation == id { self.error = error.localizedDescription } } }
    }
    private func stop() {
        generation = UUID(); let id = generation; connectionTask?.cancel(); connectionTask = nil; sendTask?.cancel(); sendTask = nil
        busy = true; running = false; sending = false; status = "Disconnecting…"
        Task { await mqtt.stop(); await amqp.stop(); if generation == id { busy = false; status = "Disconnected" } }
    }
}
