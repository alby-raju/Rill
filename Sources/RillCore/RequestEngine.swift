import Foundation

public enum RillError: LocalizedError {
    case unsupportedBodyMethod, invalidAPIKey, invalidURL, missingVariable(String), invalidHeader(String), responseTooLarge, invalidWorkspace, invalidLimits, invalidTimeout, duplicateHeader
    public var errorDescription: String? {
        switch self {
        case .unsupportedBodyMethod: "GET and HEAD bodies are not supported by this transport. Choose None or another method."
        case .invalidAPIKey: "Enter a nonempty API-key name."
        case .invalidLimits: "Response download limits must be between 1 byte and 256 MiB."
        case .invalidTimeout: "Request timeout must be a finite positive number."
        case .duplicateHeader: "Repeated request headers are not yet supported. Combine them explicitly only when permitted by the API."
        case .invalidURL: "Enter a valid http:// or https:// URL."
        case .missingVariable(let name): "No value found for {{\(name)}} in the selected environment."
        case .invalidHeader(let name): "Invalid header: \(name). Header names must be HTTP tokens and values cannot contain line breaks."
        case .responseTooLarge: "Response exceeded the configured download limit."
        case .invalidWorkspace: "This file is not a supported Rill workspace."
        }
    }
}
public struct ResponseBudget: Sendable {
    public let downloadBytes: Int
    public static let standard = ResponseBudget(uncheckedBytes: ResourceLimits.responseBytes)
    private init(uncheckedBytes: Int) { downloadBytes = uncheckedBytes }
    public init(downloadBytes: Int) throws {
        guard (1...(256 * 1024 * 1024)).contains(downloadBytes) else { throw RillError.invalidLimits }
        self.downloadBytes = downloadBytes
    }
}

public enum RequestEngine {
    public static func resolve(_ text: String, variables: [String: String]) throws -> String {
        try VariableExpansion.resolve(text, values: variables)
    }

    public static func prepare(_ draft: RequestDraft, environment: Environment?) throws -> URLRequest {
        let variables = environment?.variables.filter { $0.enabled && !$0.name.isEmpty }.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
        var expandedBytes = 0
        func expand(_ value: String) throws -> String {
            let result = try resolve(value, variables: variables)
            expandedBytes += result.utf8.count
            guard expandedBytes <= ResourceLimits.workspaceBytes else { throw EditingError.expansionLimit }
            return result
        }
        let address = try expand(draft.url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: address), ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host?.isEmpty == false, components.user == nil, components.password == nil else { throw RillError.invalidURL }
        // Preserve the caller's existing percent-encoded query byte-for-byte.
        // New fields encode literal plus, spaces, Unicode and delimiters independently.
        var query = components.percentEncodedQuery
        func appendQuery(_ name: String, _ value: String) {
            let pair = HTTPEncoding.component(name) + "=" + HTTPEncoding.component(value)
            query = query.map { $0.isEmpty ? pair : $0 + "&" + pair } ?? pair
        }
        let keyName = draft.auth == .apiKey ? try expand(draft.apiKeyName ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if draft.auth == .apiKey && keyName.isEmpty { throw RillError.invalidAPIKey }
        let keyInQuery = draft.auth == .apiKey && draft.apiKeyLocation == .query
        if keyInQuery {
            query = HTTPEncoding.removingQuery(keyName, from: query)
        }
        for field in draft.parameters where field.enabled && !field.name.isEmpty {
            let name = try expand(field.name), value = try expand(field.value)
            if !keyInQuery || name != keyName { appendQuery(name, value) }
        }
        if keyInQuery { appendQuery(keyName, try expand(draft.credential)) }
        components.percentEncodedQuery = query
        components.fragment = nil
        guard let url = components.url else { throw RillError.invalidURL }
        guard draft.timeout.isFinite, draft.timeout > 0 else { throw RillError.invalidTimeout }
        var request = URLRequest(url: url)
        request.httpMethod = draft.method.rawValue
        request.timeoutInterval = min(max(draft.timeout, 1), 300)
        request.setValue("application/json, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("Rill/0.1", forHTTPHeaderField: "User-Agent")
        var headerNames = Set<String>()
        for field in draft.headers where field.enabled && !field.name.isEmpty {
            let name = try expand(field.name), value = try expand(field.value)
            guard headerNames.insert(name.lowercased()).inserted else { throw RillError.duplicateHeader }
            let tokens = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokens.contains($0) }), !hasInvalidHeaderValue(value) else { throw RillError.invalidHeader(name) }
            request.setValue(value, forHTTPHeaderField: name)
        }
        let body: Data?
        switch draft.bodyMode {
        case .none?: body = nil
        case .form?:
            let fields = try (draft.formFields ?? []).filter { $0.enabled && !$0.name.isEmpty }.map {
                HTTPEncoding.formComponent(try expand($0.name)) + "=" + HTTPEncoding.formComponent(try expand($0.value))
            }
            body = Data(fields.joined(separator: "&").utf8)
        case .text?: body = Data(try expand(draft.body).utf8)
        case nil: body = draft.body.isEmpty ? nil : Data(try expand(draft.body).utf8)
        }
        if let body {
            guard draft.method != .GET && draft.method != .HEAD else { throw RillError.unsupportedBodyMethod }
            request.httpBody = body
            let type = draft.bodyMode == .form ? "application/x-www-form-urlencoded" : try expand(draft.contentType)
            guard !hasInvalidHeaderValue(type) else { throw RillError.invalidHeader("Content-Type") }
            if draft.bodyMode == .form {
                // A structured encoder owns its wire content type.
                request.setValue(type, forHTTPHeaderField: "Content-Type")
            } else if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        }
        switch draft.auth {
        case .none: break
        case .bearer:
            let token = try expand(draft.credential)
            guard !hasInvalidHeaderValue(token) else { throw RillError.invalidHeader("Authorization") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            if !keyInQuery {
                guard HTTPEncoding.isHeaderName(keyName), !hasInvalidHeaderValue(try expand(draft.credential)) else { throw RillError.invalidHeader(keyName) }
                request.setValue(try expand(draft.credential), forHTTPHeaderField: keyName)
            }
        case .basic:
            let token = try "\(expand(draft.username)):\(expand(draft.credential))".data(using: .utf8)!.base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
    private static func hasInvalidHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.contains { ($0.value < 32 && $0.value != 9) || $0.value == 127 }
    }
    public static func execute(_ draft: RequestDraft, environment: Environment?, budget: ResponseBudget = .standard) async throws -> Exchange {
        try Task.checkCancellation()
        let request = try prepare(draft, environment: environment)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let start = ProcessInfo.processInfo.systemUptime
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RillError.invalidURL }
        let maximum = budget.downloadBytes
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
        return Exchange(requestID: draft.id, requestName: draft.name, method: draft.method, url: http.url?.absoluteString ?? request.url!.absoluteString, status: http.statusCode, duration: ProcessInfo.processInfo.systemUptime - start, headers: headers, body: data, checks: checks, preparedRequest: PreparedRequestSummary(request))
    }
}
