import Foundation

public struct ServerEvent: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public let event: String
    public let identifier: String
    public let data: String
    public let retryMilliseconds: Int?
}
public struct ServerEventParser: Sendable {
    private var line = Data()
    private var data: [String] = []
    private var bytes = 0
    private var event = ""
    private var identifier = ""
    private var retry: Int?
    private var firstLine = true
    private var ignoreLF = false
    public init() {}
    public mutating func append(_ byte: UInt8) throws -> ServerEvent? {
        if ignoreLF { ignoreLF = false; if byte == 10 { return nil } }
        if byte == 13 || byte == 10 {
            if byte == 13 { ignoreLF = true }
            var text = String(decoding: line, as: UTF8.self); line.removeAll(keepingCapacity: true)
            if firstLine { firstLine = false; if text.hasPrefix("\u{FEFF}") { text.removeFirst() } }
            if text.isEmpty {
                defer { data.removeAll(keepingCapacity: true); event = ""; bytes = 0 }
                guard !data.isEmpty else { return nil }
                return ServerEvent(event: event.isEmpty ? "message" : event, identifier: identifier, data: data.joined(separator: "\n"), retryMilliseconds: retry)
            }
            if text.hasPrefix(":") { return nil }
            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]); var value = parts.count == 2 ? String(parts[1]) : ""
            if value.hasPrefix(" ") { value.removeFirst() }
            switch name {
            case "data": bytes += value.utf8.count + 1; guard bytes <= 1024 * 1024 else { throw WorkflowError.limit }; data.append(value)
            case "event": event = value
            case "id": if !value.contains("\0") { identifier = value }
            case "retry": if !value.isEmpty && value.allSatisfy({ $0.isASCII && $0.isNumber }), let parsed = Int(value), (0...300_000).contains(parsed) { retry = parsed }
            default: break
            }
            return nil
        }
        guard line.count < 65536 else { throw WorkflowError.limit }
        line.append(byte); return nil
    }
}
public enum ServerSentEvents {
    public static func run(_ input: RequestDraft, environment: Environment?, profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil,
                           tlsProfiles: [TLSProfile] = [], onEvent: @escaping @Sendable (ServerEvent) async -> Void) async throws {
        var draft = input; draft.method = .GET; draft.graphql = nil; draft.bodyMode = RequestBodyMode.none
        let frozen = try RequestEngine.freeze(draft, environment: environment, profiles: profiles, secrets: secrets)
        defer { frozen.removeTemporaryBody() }
        var request = frozen.request; request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let profile = try TLSProfiles.selected(draft.tlsProfileID, from: tlsProfiles)
        let identity = try profile?.identityReference.map { try SystemTLSIdentities().identity(for: $0) }
        let configuration = HTTPClientConfiguration.make(); configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: HTTPTransportDelegate(prepared: frozen, profile: profile, identity: identity, followRedirects: false), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              APIContractContext.mediaType(http.value(forHTTPHeaderField: "Content-Type")) == "text/event-stream" else { throw StreamError.invalidResponse }
        var parser = ServerEventParser(), bytes = 0, events = 0
        for try await byte in stream {
            bytes += 1; guard bytes <= 8 * 1024 * 1024 else { throw WorkflowError.limit }
            if bytes % 4096 == 0 { try Task.checkCancellation() }
            if let event = try parser.append(byte) {
                events += 1; guard events <= 1000 else { throw WorkflowError.limit }
                await onEvent(event)
            }
        }
        // EOF does not dispatch an unterminated event. No implicit reconnect/replay.
    }
}
