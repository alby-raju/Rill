import Foundation
import CryptoKit

public struct PluginContext: Sendable {
    public let apiVersion = 1
    public let requestCount: Int
    public let collectionCount: Int
    public init(workspace: Workspace) { requestCount = workspace.requests.count; collectionCount = workspace.collections.count }
}
public enum PluginServiceKind: String, Codable, Sendable { case requestTemplate, mockRoutes }
public struct PluginService: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: PluginServiceKind
    public var file: String
}
public struct PluginDescriptor: Codable, Identifiable, Sendable {
    public var apiVersion: Int
    public var id: String
    public var name: String
    public var version: String
    public var services: [PluginService]
}
public struct DiscoveredPlugin: Identifiable, Sendable {
    public let descriptor: PluginDescriptor
    public let directory: URL
    public let fingerprint: String
    let content: [String: Data]
    public var id: String { descriptor.id }
}
public struct PluginTrust: Codable, Sendable {
    public var approved: [String: String] = [:]
    public init() {}
    public mutating func enable(_ plugin: DiscoveredPlugin) { approved[plugin.id] = plugin.fingerprint }
    public mutating func disable(_ id: String) { approved[id] = nil }
    public func allows(_ plugin: DiscoveredPlugin) -> Bool { approved[plugin.id] == plugin.fingerprint }
    public static func load(_ url: URL) throws -> Self { if !FileManager.default.fileExists(atPath: url.path) { return Self() }; let result = try JSONDecoder().decode(Self.self, from: BoundedFileInput.read(url, limit: 65536)); guard result.approved.count <= 128, result.approved.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value.utf8.count == 64 && $0.value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) }) else { throw WorkspaceError.invalidStructure }; return result }
    public func save(_ url: URL) throws { guard approved.count <= 128 else { throw WorkflowError.limit }; try WorkspaceFile.atomicWrite(JSONEncoder().encode(self), to: url) }
}
/// Versioned data-only native extension contract. No dylib/JAR/script/process loading.
public struct PluginRegistry: Sendable {
    public let context: PluginContext
    public let enabled: [DiscoveredPlugin]
    public init(plugins: [DiscoveredPlugin], trust: PluginTrust, context: PluginContext) { self.context = context; enabled = plugins.filter { trust.allows($0) } }
    public static func discover(_ root: URL) throws -> [DiscoveredPlugin] {
        guard root.isFileURL else { throw WorkspaceError.invalidStructure }
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard entries.count <= 128 else { throw WorkflowError.limit }
        var result: [DiscoveredPlugin] = [], ids: Set<String> = [], aggregate = 0
        for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw WorkspaceError.invalidStructure }; if values.isDirectory != true { continue }
            let manifest = directory.appendingPathComponent("rill-plugin.json")
            if !FileManager.default.fileExists(atPath: manifest.path) { continue }
            let data = try BoundedFileInput.read(manifest, limit: 65536); _ = try JSONValueParser(data).parse()
            let descriptor = try JSONDecoder().decode(PluginDescriptor.self, from: data)
            func identifier(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) } }
            guard descriptor.apiVersion == 1, identifier(descriptor.id), ids.insert(descriptor.id).inserted, !descriptor.name.isEmpty, descriptor.name.utf8.count <= 256,
                  !descriptor.version.isEmpty, descriptor.version.utf8.count <= 128, descriptor.services.count <= 32, Set(descriptor.services.map(\.id)).count == descriptor.services.count else { throw WorkspaceError.invalidStructure }
            var hash = SHA256(); hash.update(data: data); var snapshot: [String: Data] = [:]
            for service in descriptor.services {
                guard identifier(service.id), !service.file.isEmpty, service.file.utf8.count <= 256, !service.file.contains("/"), !service.file.contains("\\"), service.file != ".", service.file != "..", service.file.hasSuffix(".json") else { throw WorkspaceError.invalidStructure }
                let content = try BoundedFileInput.read(directory.appendingPathComponent(service.file), limit: 1024 * 1024)
                aggregate += content.count; guard aggregate <= 16 * 1024 * 1024 else { throw WorkflowError.limit }; snapshot[service.id] = content
                hash.update(data: Data(service.file.utf8)); hash.update(data: content)
                if service.kind == .mockRoutes { _ = try MockRouteFile.decode(content) }
                else { var request = try JSONDecoder().decode(RequestDraft.self, from: content); request.credential = ""; request.collectionID = nil; request.authProfileID = nil; request.tlsProfileID = nil; request.apiLink = nil; var workspace = Workspace(); workspace.requests = [request]; try WorkspaceFile.validate(workspace) }
            }
            result.append(DiscoveredPlugin(descriptor: descriptor, directory: directory, fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(), content: snapshot))
        }
        return result
    }
    public func request(plugin id: String, service serviceID: String) throws -> RequestDraft {
        guard let plugin = enabled.first(where: { $0.id == id }), let service = plugin.descriptor.services.first(where: { $0.id == serviceID && $0.kind == .requestTemplate }) else { throw WorkspaceError.unavailable }
        // Re-discover immediately before registration/use: changed content invalidates trust.
        let current = try Self.discover(plugin.directory.deletingLastPathComponent()).first { $0.id == id }
        guard current?.fingerprint == plugin.fingerprint else { throw WorkspaceError.conflict }
        var request = try JSONDecoder().decode(RequestDraft.self, from: current!.content[service.id]!)
        request.id = UUID(); request.collectionID = nil; request.credential = ""; request.authProfileID = nil; request.tlsProfileID = nil; request.apiLink = nil
        request.preHook?.enabled = false; request.postHook?.enabled = false; request.graphql?.introspectOnEndpointChange = false
        return request
    }
    public func mockRoutes(plugin id: String, service serviceID: String) throws -> [MockRoute] {
        guard let plugin = enabled.first(where: { $0.id == id }), let service = plugin.descriptor.services.first(where: { $0.id == serviceID && $0.kind == .mockRoutes }) else { throw WorkspaceError.unavailable }
        guard let current = try Self.discover(plugin.directory.deletingLastPathComponent()).first(where: { $0.id == id }), current.fingerprint == plugin.fingerprint, let data = current.content[service.id] else { throw WorkspaceError.conflict }
        return try MockRouteFile.decode(data)
    }

}
