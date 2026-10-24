import Foundation

public struct Field: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var name: String
    public var value: String
    public init(name: String = "", value: String = "") { self.name = name; self.value = value }
}
public enum HTTPMethod: String, Codable, CaseIterable, Sendable { case GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS }
public enum AuthKind: String, Codable, CaseIterable, Sendable { case none = "None", bearer = "Bearer token", basic = "Basic", apiKey = "API key" }
public enum APIKeyLocation: String, Codable, CaseIterable, Sendable { case header = "Header", query = "Query" }
public enum RequestBodyMode: String, Codable, CaseIterable, Sendable { case none = "None", text = "Raw text", form = "Form fields", multipart = "Multipart", binary = "Binary file" }
public struct PreparedRequestSummary: Codable, Equatable, Sendable {
    public var method: String
    public var url: String
    public var headers: [Field]
    public var bodyBytes: Int?
    public var tlsPolicy: String?
    public func write(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try WorkspaceFile.atomicWrite(encoder.encode(self), to: url)
    }
    public init(_ request: URLRequest) {
        method = request.httpMethod ?? "GET"
        var components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        if let items = components?.queryItems { components?.queryItems = items.map { URLQueryItem(name: $0.name, value: "[redacted]") } }
        components?.fragment = nil
        url = components?.url?.absoluteString ?? "Unavailable"
        let visible: Set<String> = ["accept", "content-type", "user-agent", "content-length"]
        headers = (request.allHTTPHeaderFields ?? [:]).map { Field(name: $0.key, value: visible.contains($0.key.lowercased()) ? $0.value : "[redacted]") }.sorted { $0.name < $1.name }
        bodyBytes = request.httpBody?.count ?? request.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init)
    }
}
public struct RequestDraft: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var collectionID: UUID?
    public var name = "Untitled request"
    public var method: HTTPMethod = .GET
    public var url = ""
    public var headers: [Field] = []
    public var parameters: [Field] = []
    public var body = ""
    public var contentType = "application/json"
    public var bodyMode: RequestBodyMode?
    public var formFields: [Field]?
    public var multipartParts: [MultipartPart]?
    public var binaryFile: UploadFileReference?
    public var apiKeyName: String?
    public var apiKeyLocation: APIKeyLocation?
    public var tlsProfileID: UUID?
    public var authProfileID: UUID?
    public var auth: AuthKind = .none
    public var username = ""
    public var credential = ""
    public var timeout: Double = 30
    public var expectedStatus = ""
    public var bodyContains = ""
    public init(collectionID: UUID? = nil) { self.collectionID = collectionID }
}
public struct RequestCollection: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public init(name: String) { self.name = name }
}
public struct Environment: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var parentID: UUID?
    public var name: String
    public var variables: [Field] = []
    public init(name: String) { self.name = name }
}
public struct CheckResult: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var passed: Bool
    public init(title: String, passed: Bool) { self.title = title; self.passed = passed }
}
public struct ExecutionEvent: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var elapsed: Double
    public var title: String
    public init(elapsed: Double, title: String) { self.elapsed = elapsed; self.title = title }
}
public struct Exchange: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var requestID: UUID
    public var requestName: String
    public var method: HTTPMethod
    public var url: String
    public var status: Int
    public var duration: Double
    public var headers: [Field]
    public var body: Data
    public var checks: [CheckResult]
    public var preparedRequest: PreparedRequestSummary?
    public var previewLimit: Int?
    public var downloadLimit: Int?
    public var originalBodyBytes: Int?
    public var bodyWasTruncated: Bool?
    public var events: [ExecutionEvent]?
    public var previewByteLimit: Int { min(max(previewLimit ?? ResourceLimits.previewBytes, 128), 8 * 1024 * 1024) }
    public var text: String { String(data: body, encoding: .utf8) ?? "Binary response (\(body.count) bytes). Export to inspect." }
    public var previewIsTruncated: Bool { body.count > previewByteLimit }
    public func previewText(pretty: Bool) -> String {
        guard !previewIsTruncated else { return String(decoding: body.prefix(previewByteLimit), as: UTF8.self) }
        return pretty ? prettyText : text
    }
    public var prettyText: String {
        guard body.count <= previewByteLimit, bodyWasTruncated != true else { return previewText(pretty: false) }
        guard let raw = String(data: body, encoding: .utf8), let formatted = try? JSONTextFormatter.pretty(raw) else { return text }
        return formatted
    }
}
public struct Workspace: Codable, Equatable, Sendable {
    public var version = 1
    public var storageRevision: UUID?
    public var collections: [RequestCollection] = []
    public var requests: [RequestDraft] = []
    public var environments: [Environment] = []
    public var authProfiles: [AuthenticationProfile]?
    public var namedSecrets: [NamedSecret]?
    public var tlsProfiles: [TLSProfile]?
    public var selectedEnvironmentID: UUID?
    public var history: [Exchange] = []
    public init() {}
    /// Session history and the internal storage token are not user edits.
    /// Credentials still count because they must be saved in the companion store.
    public func needsSave(comparedTo previous: Workspace) -> Bool {
        var current = self, earlier = previous
        current.history = []; earlier.history = []
        current.storageRevision = nil; earlier.storageRevision = nil
        return current != earlier
    }
    public static var starter: Workspace {
        var workspace = Workspace()
        let collection = RequestCollection(name: "My first collection")
        workspace.collections = [collection]
        var request = RequestDraft(collectionID: collection.id)
        request.name = "New request"
        workspace.requests = [request]
        return workspace
    }
}
