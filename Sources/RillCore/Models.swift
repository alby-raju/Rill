import Foundation

public struct Field: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var name: String
    public var value: String
    public init(name: String = "", value: String = "") { self.name = name; self.value = value }
}
public enum HTTPMethod: String, Codable, CaseIterable, Sendable { case GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS }
public enum AuthKind: String, Codable, CaseIterable, Sendable { case none = "None", bearer = "Bearer token", basic = "Basic" }
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
    public var text: String { String(data: body, encoding: .utf8) ?? "Binary response (\(body.count) bytes). Export to inspect." }
    public var previewIsTruncated: Bool { body.count > ResourceLimits.previewBytes }
    public func previewText(pretty: Bool) -> String {
        guard !previewIsTruncated else { return String(decoding: body.prefix(ResourceLimits.previewBytes), as: UTF8.self) }
        return pretty ? prettyText : text
    }
    public var prettyText: String {
        guard body.count <= ResourceLimits.previewBytes else { return previewText(pretty: false) }
        guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return text }
        return text
    }
}
public struct Workspace: Codable, Equatable, Sendable {
    public var version = 1
    public var storageRevision: UUID?
    public var collections: [RequestCollection] = []
    public var requests: [RequestDraft] = []
    public var environments: [Environment] = []
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
