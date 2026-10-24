import Foundation
import Network

public struct MockRoute: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var method: HTTPMethod = .GET
    public var path = "/"
    public var status = 200
    public var headers: [Field] = [Field(name: "Content-Type", value: "application/json")]
    public var body = "{}"
    public init() {}
}
public actor MockServer {
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var routes: [MockRoute] = []
    private var generation = UUID()
    private let queue = DispatchQueue(label: "app.rill.mock")
    public init() {}
    public static func validate(_ routes: [MockRoute]) throws {
        guard routes.count <= 1000, Set(routes.map { $0.method.rawValue + " " + $0.path }).count == routes.count,
              routes.reduce(0, { $0 + $1.body.utf8.count }) <= 16 * 1024 * 1024,
              routes.reduce(0, { $0 + $1.headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) }) <= 4 * 1024 * 1024 else { throw WorkflowError.limit }
        for route in routes {
            guard route.path.hasPrefix("/"), !route.path.contains("?"), !route.path.contains("#"), route.path.utf8.count <= 4096,
                  !route.path.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }),
                  (200...599).contains(route.status), route.body.utf8.count <= 1024 * 1024, route.headers.count <= 100, route.headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 16384,
                  Set(route.headers.map { $0.name.lowercased() }).count == route.headers.count,
                  route.headers.allSatisfy({ HTTPEncoding.isHeaderName($0.name) && !["content-length", "transfer-encoding", "connection", "trailer", "content-encoding"].contains($0.name.lowercased()) && $0.value.utf8.count <= 8192 && !$0.value.unicodeScalars.contains(where: { $0.value < 32 || $0.value >= 127 }) }) else { throw WorkflowError.invalidConfiguration }
        }
    }
    public func start(routes: [MockRoute], port: UInt16 = 0) async throws -> URL {
        guard listener == nil else { throw WorkflowError.invalidConfiguration }
        try Self.validate(routes); try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters); self.listener = listener; self.routes = routes
        generation = UUID(); let id = generation
        listener.stateUpdateHandler = { [weak self] state in Task { await self?.state(state, generation: id) } }
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection, generation: id) } }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in Task { await self?.startupTimeout(id) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in ready = continuation; listener.start(queue: queue) }
        } onCancel: { Task { await self.stop() } }
    }
    public func stop() {
        generation = UUID(); listener?.cancel(); listener = nil
        ready?.resume(throwing: CancellationError()); ready = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll(); routes = []
    }
    private func startupTimeout(_ id: UUID) { if generation == id && ready != nil { stop() } }
    private func state(_ state: NWListener.State, generation id: UUID) {
        guard id == generation else { return }
        switch state {
        case .ready:
            if let port = listener?.port, let continuation = ready {
                ready = nil; continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)")!)
            }
        case .failed(let error): ready?.resume(throwing: error); ready = nil; stop()
        default: break
        }
    }
    private func accept(_ connection: NWConnection, generation id: UUID) {
        guard generation == id, connections.count < 32 else { connection.cancel(); return }
        let key = UUID(); connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { await self?.close(key) } }
            if case .cancelled = state { Task { await self?.close(key) } }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in Task { await self?.close(key) } }
        receive(connection, key: key, data: Data())
    }
    private func close(_ key: UUID) { connections.removeValue(forKey: key)?.cancel() }
    private func receive(_ connection: NWConnection, key: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(65536, 1024 * 1024 + 16384 - data.count)) { [weak self] bytes, _, complete, error in
            Task { await self?.received(connection, key: key, prior: data, bytes: bytes, complete: complete, failed: error != nil) }
        }
    }
    private func received(_ connection: NWConnection, key: UUID, prior: Data, bytes: Data?, complete: Bool, failed: Bool) {
        guard connections[key] != nil, !failed else { close(key); return }
        var data = prior; data.append(bytes ?? Data())
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count >= 16384 || complete { close(key) } else { receive(connection, key: key, data: data) }; return
        }
        guard end.lowerBound < 16384, let text = String(data: data[..<end.lowerBound], encoding: .utf8) else { close(key); return }
        let lines = text.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, let method = HTTPMethod(rawValue: String(first[0])), ["HTTP/1.0", "HTTP/1.1"].contains(String(first[2])), first[1].hasPrefix("/") else { close(key); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), HTTPEncoding.isHeaderName(String(line[..<colon])) else { close(key); return }
            let name = String(line[..<colon]).lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { close(key); return }; headers[name] = value
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil, let length = Int(headers["content-length"] ?? "0"), (0...(1024 * 1024)).contains(length) else { close(key); return }
        if data.count < end.upperBound + length { if complete { close(key) } else { receive(connection, key: key, data: data) }; return }
        let path = String(first[1]).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        let route = routes.first { $0.method == method && Self.matches($0.path, path) }
        let status = route?.status ?? 404
        let payload = [204, 304].contains(status) ? Data() : Data((route?.body ?? "No mock route").utf8)
        let fields = (route?.headers ?? [Field(name: "Content-Type", value: "text/plain")]).filter { $0.enabled }
        var response = "HTTP/1.1 \(status) Mock\r\nConnection: close\r\nContent-Length: \(payload.count)\r\n"
        for field in fields { response += field.name + ": " + field.value + "\r\n" }
        response += "\r\n"
        var output = Data(response.utf8); if method != .HEAD { output.append(payload) }
        connection.send(content: output, completion: .contentProcessed { [weak self] _ in Task { await self?.close(key) } })
    }
    private static func matches(_ pattern: String, _ path: String) -> Bool {
        let a = pattern.split(separator: "/", omittingEmptySubsequences: false), b = path.split(separator: "/", omittingEmptySubsequences: false)
        return a.count == b.count && zip(a, b).allSatisfy { String($0).removingPercentEncoding == String($1).removingPercentEncoding || ($0.hasPrefix("{") && $0.hasSuffix("}") && !$1.isEmpty) }
    }
    deinit { listener?.cancel(); for connection in connections.values { connection.cancel() } }
}
public enum DefinitionMocks {
    public static func routes(_ definition: APIDefinition) throws -> [MockRoute] {
        let root = try JSONValueParser(definition.source.snapshot).parse()
        var routes: [MockRoute] = []
        for operation in definition.operations {
            guard let separator = operation.key.firstIndex(of: " ") else { throw SchemaError.invalid }
            let path = String(operation.key[operation.key.index(after: separator)...])
            let context = try APIContractContext(APIRequestLink(sourceID: definition.source.id, operationKey: operation.key, baseline: Data()), definitions: [definition.source])!
            guard let responses = context.operation["responses"]?.object, let status = responses.keys.sorted().first(where: { Int($0).map { (200...299).contains($0) } == true }) else { continue }
            let response = try context.resolve(responses[status]!)
            var route = MockRoute(); route.path = path; route.method = operation.request.method; route.status = Int(status)!
            if let content = response["content"]?.object, let type = content.keys.sorted().first, let media = content[type] {
                let schema = media["schema"] ?? .object([:])
                let example = try media["example"] ?? media["examples"]?.object?.sorted(by: { $0.key < $1.key }).first?.value["value"] ?? APISamples.value(schema, root: root)
                route.headers = [Field(name: "Content-Type", value: type)]; route.body = type.contains("json") ? try ResponseJSON.encoded(example) : try ResponseJSON.text(example)
            } else if let schema = response["schema"] {
                let sample = try APISamples.value(schema, root: root); route.body = try ResponseJSON.encoded(sample)
            } else { route.body = ""; route.headers = [] }
            routes.append(route)
        }
        try MockServer.validate(routes); return routes
    }
}

public enum MockRouteFile {
    public static func decode(_ data: Data) throws -> [MockRoute] {
        guard data.count <= 2 * 1024 * 1024 else { throw WorkflowError.limit }
        let parsed = try JSONValueParser(data).parse()
        guard let parsedRows = parsed.array, let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 1000 else { throw WorkflowError.invalidConfiguration }
        let routes = try rows.enumerated().map { index, row in
            guard Set(row.keys).isSubset(of: ["method", "path", "status", "headers", "body"]),
                  let method = (row["method"] as? String).flatMap(HTTPMethod.init(rawValue:)), let path = row["path"] as? String,
                  let statusValue = parsedRows[index]["status"], let status = try ExactSchemaNumber(statusValue).nonnegativeInt, let body = row["body"] as? String else { throw WorkflowError.invalidConfiguration }
            var route = MockRoute(); route.method = method; route.path = path; route.status = status; route.body = body
            if let headers = row["headers"] { guard let headers = headers as? [String: String] else { throw WorkflowError.invalidConfiguration }; route.headers = headers.sorted { $0.key < $1.key }.map { Field(name: $0.key, value: $0.value) } }
            else { route.headers = [] }
            return route
        }
        try MockServer.validate(routes); return routes
    }
    public static func encode(_ routes: [MockRoute]) throws -> Data {
        try MockServer.validate(routes)
        let rows: [[String: Any]] = routes.map { ["method": $0.method.rawValue, "path": $0.path, "status": $0.status, "headers": Dictionary(uniqueKeysWithValues: $0.headers.filter(\.enabled).map { ($0.name, $0.value) }), "body": $0.body] }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 2 * 1024 * 1024 else { throw WorkflowError.limit }; return data
    }
}
