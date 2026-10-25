import CryptoKit
import Foundation
import Security

public enum ShareError: LocalizedError {
    case invalid, unauthorized, insecure
    public var errorDescription: String? {
        switch self {
        case .invalid:
            "Invalid share configuration, response or destination. Sharing is limited to 8 MiB."
        case .unauthorized: "The read-only share rejected the access token."
        case .insecure: "Use HTTPS or explicitly allow plaintext HTTP outside loopback."
        }
    }
}
public struct WorkspaceShare: Codable, Sendable {
    public let version: Int
    public let readOnly: Bool
    public let workspace: Workspace
}
public enum WorkspaceSharing {
    public static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ShareError.invalid
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    public static func validToken(_ token: String) -> Bool {
        (32...256).contains(token.utf8.count)
            && token.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || [45, 95].contains($0)
            }
    }
    public static func sanitized(_ source: Workspace) throws -> Workspace {
        try WorkspaceFile.validate(source)
        var workspace = source
        workspace.history = []
        workspace.storageRevision = nil
        workspace.authProfiles = nil
        workspace.tlsProfiles = nil
        workspace.namedSecrets = nil
        workspace.apiDefinitions = nil
        for index in workspace.environments.indices {
            for field in workspace.environments[index].variables.indices {
                workspace.environments[index].variables[field].value = ""
                workspace.environments[index].variables[field].enabled = false
            }
        }
        for index in workspace.requests.indices {
            var request = workspace.requests[index]
            var url = URLComponents(string: request.url)
            url?.user = nil
            url?.password = nil
            url?.fragment = nil
            if let fields = url?.queryItems {
                url?.queryItems = fields.map { URLQueryItem(name: $0.name, value: "") }
            }
            request.url = url?.string ?? ""
            request.auth = .none
            request.username = ""
            request.credential = ""
            request.authProfileID = nil
            request.tlsProfileID = nil
            request.headers = request.headers.map {
                var field = $0
                field.value = ""
                field.enabled = false
                return field
            }
            request.parameters = request.parameters.map {
                var field = $0
                field.value = ""
                field.enabled = false
                return field
            }
            request.body = ""
            request.bodyMode = RequestBodyMode.none
            request.formFields = nil
            request.multipartParts = nil
            request.binaryFile = nil
            request.apiKeyName = nil
            request.apiKeyLocation = nil
            request.graphql = nil
            request.apiLink = nil
            request.preHook = nil
            request.postHook = nil
            request.foreignScripts = nil
            request.assertions = nil
            request.extractions = nil
            request.expectedStatus = ""
            request.bodyContains = ""
            workspace.requests[index] = request
        }
        try WorkspaceFile.validate(workspace)
        return workspace
    }
    public static func encode(_ workspace: Workspace) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(
            WorkspaceShare(version: 1, readOnly: true, workspace: sanitized(workspace)))
        guard data.count <= 8 * 1024 * 1024 else { throw ShareError.invalid }
        return data
    }
    public static func decode(_ data: Data) throws -> Workspace {
        guard data.count <= 8 * 1024 * 1024 else { throw ShareError.invalid }
        _ = try JSONValueParser(data).parse()
        let envelope = try JSONDecoder().decode(WorkspaceShare.self, from: data)
        guard envelope.version == 1, envelope.readOnly else { throw ShareError.invalid }
        return try sanitized(envelope.workspace)
    }
    public static func pull(
        _ url: URL, token: String, destination: URL, allowPlaintextLAN: Bool = false
    ) async throws {
        guard validToken(token), destination.isFileURL,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.user == nil, components.password == nil
        else { throw ShareError.invalid }
        let loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(
            components.host?.lowercased() ?? "")
        guard
            components.scheme == "https"
                || (components.scheme == "http" && (loopback || allowPlaintextLAN))
        else { throw ShareError.insecure }
        var request = RequestDraft()
        request.url = url.absoluteString
        request.auth = .bearer
        request.credential = token
        let response = try await RequestEngine.execute(
            request, environment: nil, followRedirects: false)
        guard response.status == 200 else { throw ShareError.unauthorized }
        let workspace = try WorkspaceImport.merging(decode(response.body), into: Workspace())
        try Task.checkCancellation()
        try WorkspaceFile.createNew(WorkspaceFile.encode(workspace), at: destination)
    }
    static func equalToken(_ provided: String, digest: Data) -> Bool {
        let value = Data(SHA256.hash(data: Data(provided.utf8)))
        return zip(value, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
