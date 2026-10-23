import Foundation

public enum RillError: LocalizedError {
    case invalidURL, missingVariable(String), invalidHeader(String), responseTooLarge, invalidWorkspace
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid http:// or https:// URL."
        case .missingVariable(let name): "No value found for {{\(name)}} in the selected environment."
        case .invalidHeader(let name): "Invalid header: \(name). Header names must be HTTP tokens and values cannot contain line breaks."
        case .responseTooLarge: "Response exceeded the 16 MiB limit."
        case .invalidWorkspace: "This file is not a supported Rill workspace."
        }
    }
}
public enum RequestEngine {
    public static func resolve(_ text: String, variables: [String: String]) throws -> String {
        let pattern = try NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)
        var output = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: text), let fullRange = Range(match.range, in: output) else { continue }
            let name = String(text[keyRange]).trimmingCharacters(in: .whitespaces)
            guard let value = variables[name] else { throw RillError.missingVariable(name) }
            output.replaceSubrange(fullRange, with: value)
        }
        return output
    }
    public static func prepare(_ draft: RequestDraft, environment: Environment?) throws -> URLRequest {
        let variables = environment?.variables.filter { $0.enabled && !$0.name.isEmpty }.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
        func expand(_ value: String) throws -> String { try resolve(value, variables: variables) }
        let address = try expand(draft.url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: address), ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host?.isEmpty == false, components.user == nil, components.password == nil else { throw RillError.invalidURL }
        let query = try draft.parameters.filter { $0.enabled && !$0.name.isEmpty }.map { URLQueryItem(name: try expand($0.name), value: try expand($0.value)) }
        if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query }
        guard let url = components.url else { throw RillError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = draft.method.rawValue
        request.timeoutInterval = min(max(draft.timeout, 1), 300)
        request.setValue("application/json, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("Rill/0.1", forHTTPHeaderField: "User-Agent")
        for field in draft.headers where field.enabled && !field.name.isEmpty {
            let name = try expand(field.name), value = try expand(field.value)
            let tokens = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokens.contains($0) }), !value.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) else { throw RillError.invalidHeader(name) }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !draft.body.isEmpty {
            request.httpBody = try expand(draft.body).data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue(draft.contentType, forHTTPHeaderField: "Content-Type") }
        }
        switch draft.auth {
        case .none: break
        case .bearer:
            let token = try expand(draft.credential)
            guard !token.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) else { throw RillError.invalidHeader("Authorization") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .basic:
            let token = try "\(expand(draft.username)):\(expand(draft.credential))".data(using: .utf8)!.base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
    public static func execute(_ draft: RequestDraft, environment: Environment?) async throws -> Exchange {
        let request = try prepare(draft, environment: environment)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let start = Date()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RillError.invalidURL }
        let maximum = 16 * 1024 * 1024
        if response.expectedContentLength > Int64(maximum) { throw RillError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count >= maximum { throw RillError.responseTooLarge }
            if data.count % 4096 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        let headers = http.allHeaderFields.map { Field(name: String(describing: $0.key), value: String(describing: $0.value)) }.sorted { $0.name < $1.name }
        var checks: [CheckResult] = []
        if !draft.expectedStatus.isEmpty { checks.append(CheckResult(title: "Status equals \(draft.expectedStatus)", passed: Int(draft.expectedStatus) == http.statusCode)) }
        if !draft.bodyContains.isEmpty { checks.append(CheckResult(title: "Body contains \(draft.bodyContains)", passed: String(data: data, encoding: .utf8)?.contains(draft.bodyContains) == true)) }
        return Exchange(requestID: draft.id, requestName: draft.name, method: draft.method, url: request.url!.absoluteString, status: http.statusCode, duration: Date().timeIntervalSince(start), headers: headers, body: data, checks: checks)
    }
}
public enum WorkspaceFile {
    public static func load(from url: URL) throws -> Workspace {
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
        guard workspace.version == 1, Set(workspace.requests.map(\.id)).count == workspace.requests.count, Set(workspace.collections.map(\.id)).count == workspace.collections.count, Set(workspace.environments.map(\.id)).count == workspace.environments.count else { throw RillError.invalidWorkspace }
        return workspace
    }
    public static func save(_ workspace: Workspace, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(workspace).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
