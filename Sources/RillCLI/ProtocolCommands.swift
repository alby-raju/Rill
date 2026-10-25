import Foundation
import RillCore

actor ProtocolLedger {
    var inbound = 0, outbound = 0, failures = 0, ended = false, bytes = 0
    var lastJSON: Data?
    func add(
        _ record: StreamRecord, show: Bool, schema: ProtobufSchema? = nil,
        method: ProtobufMethod? = nil
    ) {
        if record.direction == .inbound { inbound += 1 }
        if record.direction == .outbound { outbound += 1 }
        if record.kind == .error {
            failures += 1
            ended = true
        }
        if record.kind == .close { ended = true }
        var data = record.data
        if record.kind == .binary, let schema, let method {
            do {
                data = Data(
                    try schema.decode(
                        data: record.data,
                        message: record.direction == .inbound ? method.outputType : method.inputType
                    ).utf8)
                if record.direction == .inbound { lastJSON = data }
            } catch {
                failures += 1
                ended = true
                return
            }
        }
        bytes += data.count
        guard bytes <= 8 * 1024 * 1024 else {
            failures += 1
            ended = true
            return
        }
        if show {
            try? FileHandle.standardOutput.write(contentsOf: data.prefix(65536) + Data([10]))
        }
    }
    func event(_ event: ServerEvent, show: Bool) {
        inbound += 1
        if show {
            try? FileHandle.standardOutput.write(
                contentsOf: Data(
                    (event.event + "\n" + event.identifier + "\n" + event.data + "\n").utf8))
        }
    }
    func summary() -> [String: Int] {
        ["received": inbound, "sent": outbound, "failures": failures]
    }
    func complete() -> Bool { ended }
    func failed() -> Bool { failures > 0 }
    func json() -> Data? { lastJSON }
}
extension RillCLI {
    static func protocolCommand(_ args: Arguments) async throws {
        if args.command == "share-pull" {
            guard let url = URL(string: try args.operand()) else {
                throw CLIError.usage("Invalid share URL.")
            }
            try await WorkspaceSharing.pull(
                url, token: tokenFromFile(args.required("token-file")),
                destination: URL(fileURLWithPath: args.required("destination")),
                allowPlaintextLAN: args.flags.contains("allow-lan"))
            try args.text("Sanitized share saved to a new destination")
            return
        }
        if args.command == "mock-serve" {
            let routes = try MockRouteFile.decode(
                BoundedFileInput.read(
                    URL(fileURLWithPath: args.required("routes")), limit: 2 * 1024 * 1024))
            let port = try args.integer("port", default: 0)
            guard (0...65535).contains(port) else { throw CLIError.usage("Invalid port.") }
            let server = MockServer()
            let url = try await server.start(routes: routes, port: UInt16(port))
            try args.text(url.absoluteString)
            do { try await waitForCancellation() } catch {
                await server.stop()
                throw error
            }
        }
        let workspace =
            FileManager.default.fileExists(atPath: args.workspaceURL.path)
            ? try WorkspaceFile.load(from: args.workspaceURL) : Workspace()
        let environment = try args.environment(workspace)
        let secrets = NamedSecretResolver(catalog: workspace.namedSecrets ?? [])
        func resolve(_ value: String) throws -> String {
            try VariableExpansion.resolve(
                value, values: WorkflowEngine.variables(in: environment),
                secretLookup: { try secrets.resolve($0) })
        }
        var request = RequestDraft()
        request.url = try args.required("endpoint")
        request.headers = try args.fields("header")
        request.timeout = try args.seconds()
        request = try args.transport(request, workspace: workspace)
        let show = args.flags.contains("show-messages") && !args.quiet
        switch args.command {
        case "graphql":
            request.method = .POST
            var config = GraphQLConfiguration()
            if let path = args.value("query-file") {
                guard
                    let query = String(
                        data: try BoundedFileInput.read(
                            URL(fileURLWithPath: path), limit: 1024 * 1024), encoding: .utf8)
                else { throw CLIError.usage("Query file must be UTF-8.") }
                config.query = query
            } else {
                config.query = try args.required("query")
            }
            config.variables = args.value("variables") ?? "{}"
            request.graphql = config
            let response = try await RequestEngine.execute(
                request, environment: environment, profiles: workspace.authProfiles ?? [],
                secrets: secrets, tlsProfiles: workspace.tlsProfiles ?? [])
            if let output = args.value("output") { try args.write(response.body, to: output) }
            try args.json([
                "status": response.status, "checks": response.checks.count,
                "failedChecks": response.checks.filter { !$0.passed }.count,
            ])
            guard (200...299).contains(response.status), response.checks.allSatisfy(\.passed) else {
                throw CLIError.assertion
            }
        case "sse":
            let ledger = ProtocolLedger()
            try await ServerSentEvents.run(
                request, environment: environment, profiles: workspace.authProfiles ?? [],
                secrets: secrets, tlsProfiles: workspace.tlsProfiles ?? [],
                onEvent: { await ledger.event($0, show: show) })
            try args.json(await ledger.summary())
        case "ws":
            let socket = WebSocketClient()
            let ledger = ProtocolLedger()
            do {
                try await socket.connect(
                    request, environment: environment, profiles: workspace.authProfiles ?? [],
                    secrets: secrets, tlsProfiles: workspace.tlsProfiles ?? [],
                    onRecord: { await ledger.add($0, show: show) })
                if let message = args.value("send") {
                    try await socket.send(text: resolve(message))
                }
                try await Task.sleep(for: .seconds(args.seconds("wait", default: 1)))
                await socket.stop()
                try args.json(await ledger.summary())
                if await ledger.failed() { throw CLIError.runtime }
            } catch {
                await socket.stop()
                throw error
            }
        case "grpc":
            guard args.value("tls") == nil else {
                throw CLIError.usage(
                    "This gRPC baseline uses system trust; custom TLS profiles are not supported.")
            }
            var config = GRPCConfiguration()
            config.endpoint = try resolve(request.url)
            config.timeout = request.timeout
            config.metadata = try args.fields("metadata").map {
                var field = $0
                field.name = try resolve(field.name)
                field.value = try resolve(field.value)
                return field
            }
            let schema: ProtobufSchema
            if let path = args.value("descriptor") {
                schema = try ProtobufSchema(
                    descriptorSet: BoundedFileInput.read(
                        URL(fileURLWithPath: path), limit: 8 * 1024 * 1024))
            } else if let path = args.value("proto") {
                schema = try await ProtobufCompiler.compile(
                    URL(fileURLWithPath: path),
                    importRoots: (args.values["proto-include"] ?? []).map {
                        URL(fileURLWithPath: $0)
                    })
            } else {
                schema = try await GRPCReflection.discover(config)
            }
            let name = try args.required("method").trimmingCharacters(
                in: CharacterSet(charactersIn: "/"))
            guard let method = schema.methods.first(where: { $0.id == name }) else {
                throw CLIError.usage("Method is missing from loaded/reflected descriptors.")
            }
            let body = try schema.encode(json: resolve(args.body()), message: method.inputType)
            let session = GRPCSession()
            let ledger = ProtocolLedger()
            do {
                try await session.start(
                    config, method: method, initialMessage: body,
                    onRecord: { await ledger.add($0, show: show, schema: schema, method: method) })
                if method.mode == .clientStreaming || method.mode == .bidirectional {
                    try await session.finishSending()
                }
                while !(await ledger.complete()) { try await Task.sleep(for: .milliseconds(10)) }
                await session.stop()
                try args.json(await ledger.summary())
                if let path = args.value("output"), let data = await ledger.json() {
                    try args.write(data, to: path)
                }
                if await ledger.failed() { throw CLIError.runtime }
            } catch {
                await session.stop()
                throw error
            }
        default: throw CLIError.usage("Unknown protocol command.")
        }
    }
}
