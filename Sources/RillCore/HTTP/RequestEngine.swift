import Foundation

public enum RillError: LocalizedError {
    case unsupportedBodyMethod, invalidAPIKey, invalidURL, missingVariable(String), invalidHeader(
        String), responseTooLarge, invalidWorkspace, invalidLimits, invalidTimeout, duplicateHeader
    public var errorDescription: String? {
        switch self {
        case .unsupportedBodyMethod:
            "GET and HEAD bodies are not supported by this transport. Choose None or another method."
        case .invalidAPIKey: "Enter a nonempty API-key name."
        case .invalidLimits: "Response download limits must be between 1 byte and 256 MiB."
        case .invalidTimeout: "Request timeout must be between 1 and 300 seconds."
        case .duplicateHeader:
            "Repeated request headers are not yet supported. Combine them explicitly only when permitted by the API."
        case .invalidURL: "Enter a valid http:// or https:// URL."
        case .missingVariable(let name):
            "No value found for {{\(name)}} in the selected environment."
        case .invalidHeader(let name):
            "Invalid header: \(name). Header names must be HTTP tokens and values cannot contain line breaks."
        case .responseTooLarge: "Response exceeded the configured download limit."
        case .invalidWorkspace: "This file is not a supported Rill workspace."
        }
    }
}
public struct ResponseBudget: Sendable {
    public let downloadBytes: Int
    public let previewBytes: Int
    public static let standard = ResponseBudget(uncheckedBytes: ResourceLimits.responseBytes)
    private init(uncheckedBytes: Int) {
        downloadBytes = uncheckedBytes
        previewBytes = ResourceLimits.previewBytes
    }
    public init(downloadBytes: Int, previewBytes: Int = ResourceLimits.previewBytes) throws {
        guard (1...(256 * 1024 * 1024)).contains(downloadBytes),
            (128...(8 * 1024 * 1024)).contains(previewBytes)
        else { throw RillError.invalidLimits }
        self.downloadBytes = downloadBytes
        self.previewBytes = previewBytes
    }
}

enum HTTPClientConfiguration {
    static func make() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }
}

public enum RequestEngine {
    public static func resolve(_ text: String, variables: [String: String]) throws -> String {
        try VariableExpansion.resolve(text, values: variables)
    }

    public static func prepare(
        _ input: RequestDraft, environment: Environment?, profiles: [AuthenticationProfile] = [],
        secrets: NamedSecretResolver? = nil
    ) throws -> URLRequest {
        let draft = try AuthenticationProfiles.applying(to: input, profiles: profiles)
        let variables =
            environment?.variables.filter { $0.enabled && !$0.name.isEmpty }.reduce(
                into: [String: String]()
            ) { $0[$1.name] = $1.value } ?? [:]
        var expandedBytes = 0
        func expand(_ value: String) throws -> String {
            let result = try VariableExpansion.resolve(
                value, values: variables,
                secretLookup: { name in
                    guard let secrets else { throw AuthenticationError.missingSecret }
                    return try secrets.resolve(name)
                })
            expandedBytes += result.utf8.count
            guard expandedBytes <= ResourceLimits.workspaceBytes else {
                throw EditingError.expansionLimit
            }
            return result
        }
        let address = try expand(draft.url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: address),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.host?.isEmpty == false, components.user == nil, components.password == nil
        else { throw RillError.invalidURL }
        // Preserve the caller's existing percent-encoded query byte-for-byte.
        // New fields encode literal plus, spaces, Unicode and delimiters independently.
        var query = components.percentEncodedQuery
        func appendQuery(_ name: String, _ value: String) {
            let pair = HTTPEncoding.component(name) + "=" + HTTPEncoding.component(value)
            query = query.map { $0.isEmpty ? pair : $0 + "&" + pair } ?? pair
        }
        let keyName =
            draft.auth == .apiKey
            ? try expand(draft.apiKeyName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if draft.auth == .apiKey && keyName.isEmpty { throw RillError.invalidAPIKey }
        let keyInQuery = draft.auth == .apiKey && draft.apiKeyLocation == .query
        if keyInQuery {
            query = HTTPEncoding.removingQuery(keyName, from: query)
        }
        for field in draft.parameters where field.enabled && !field.name.isEmpty {
            let name = try expand(field.name)
            let value = try expand(field.value)
            if !keyInQuery || name != keyName { appendQuery(name, value) }
        }
        if keyInQuery { appendQuery(keyName, try expand(draft.credential)) }
        components.percentEncodedQuery = query
        components.fragment = nil
        guard let url = components.url else { throw RillError.invalidURL }
        guard draft.timeout.isFinite, (1...300).contains(draft.timeout) else {
            throw RillError.invalidTimeout
        }
        var request = URLRequest(url: url)
        request.httpMethod = draft.method.rawValue
        request.timeoutInterval = draft.timeout
        request.setValue("application/json, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("Rill/" + RillVersion.number, forHTTPHeaderField: "User-Agent")
        var headerNames = Set<String>()
        for field in draft.headers where field.enabled && !field.name.isEmpty {
            let name = try expand(field.name)
            let value = try expand(field.value)
            guard headerNames.insert(name.lowercased()).inserted else {
                throw RillError.duplicateHeader
            }
            let tokens = CharacterSet(
                charactersIn:
                    "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokens.contains($0) }),
                !hasInvalidHeaderValue(value)
            else { throw RillError.invalidHeader(name) }
            request.setValue(value, forHTTPHeaderField: name)
        }
        let body: Data?
        if let graphql = draft.graphql {
            guard draft.method == .POST else { throw GraphQLError.invalidInput }
            let encoded = try Data(
                ResponseJSON.encoded(GraphQL.payload(graphql, resolve: expand)).utf8)
            guard encoded.count <= 4 * 1024 * 1024 else { throw WorkflowError.limit }
            body = encoded
        } else {
            switch draft.bodyMode {
            case .none?: body = nil
            case .form?:
                let fields = try (draft.formFields ?? []).filter { $0.enabled && !$0.name.isEmpty }
                    .map {
                        HTTPEncoding.formComponent(try expand($0.name)) + "="
                            + HTTPEncoding.formComponent(try expand($0.value))
                    }
                body = Data(fields.joined(separator: "&").utf8)
            case .multipart?, .binary?: throw UploadError.requiresFreeze
            case .text?: body = Data(try expand(draft.body).utf8)
            case nil: body = draft.body.isEmpty ? nil : Data(try expand(draft.body).utf8)
            }
        }
        if let body {
            guard draft.method != .GET && draft.method != .HEAD else {
                throw RillError.unsupportedBodyMethod
            }
            request.httpBody = body
            let type =
                draft.graphql != nil
                ? "application/json"
                : draft.bodyMode == .form
                    ? "application/x-www-form-urlencoded" : try expand(draft.contentType)
            guard !hasInvalidHeaderValue(type) else {
                throw RillError.invalidHeader("Content-Type")
            }
            if draft.bodyMode == .form || draft.graphql != nil {
                // A structured encoder owns its wire content type.
                request.setValue(type, forHTTPHeaderField: "Content-Type")
            } else if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(type, forHTTPHeaderField: "Content-Type")
            }
        }
        switch draft.auth {
        case .none: break
        case .bearer:
            let token = try expand(draft.credential)
            guard !hasInvalidHeaderValue(token) else {
                throw RillError.invalidHeader("Authorization")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            if !keyInQuery {
                guard HTTPEncoding.isHeaderName(keyName),
                    !hasInvalidHeaderValue(try expand(draft.credential))
                else { throw RillError.invalidHeader(keyName) }
                request.setValue(try expand(draft.credential), forHTTPHeaderField: keyName)
            }
        case .basic:
            let token = try "\(expand(draft.username)):\(expand(draft.credential))".data(
                using: .utf8)!.base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
    public static func freeze(
        _ input: RequestDraft, environment: Environment?, profiles: [AuthenticationProfile] = [],
        secrets: NamedSecretResolver? = nil
    ) throws -> PreparedHTTPRequest {
        let draft = try AuthenticationProfiles.applying(to: input, profiles: profiles)
        guard draft.graphql == nil && (draft.bodyMode == .multipart || draft.bodyMode == .binary)
        else {
            return PreparedHTTPRequest(
                request: try prepare(draft, environment: environment, secrets: secrets))
        }
        guard draft.method != .GET && draft.method != .HEAD else {
            throw RillError.unsupportedBodyMethod
        }
        var headersOnly = draft
        headersOnly.bodyMode = RequestBodyMode.none
        var request = try prepare(headersOnly, environment: environment, secrets: secrets)
        let upload = try UploadBody.create(draft, environment: environment, secrets: secrets)
        request.httpBodyStream = InputStream(url: upload.url)
        request.setValue(String(upload.count), forHTTPHeaderField: "Content-Length")
        if draft.bodyMode == .multipart || request.value(forHTTPHeaderField: "Content-Type") == nil
        {
            request.setValue(upload.contentType, forHTTPHeaderField: "Content-Type")
        }
        return PreparedHTTPRequest(request: request, temporaryBody: upload.url)
    }
    private static func hasInvalidHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.contains { ($0.value < 32 && $0.value != 9) || $0.value == 127 }
    }
    public static func execute(
        _ draft: RequestDraft, environment: Environment?, budget: ResponseBudget = .standard,
        profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil,
        tlsProfiles: [TLSProfile] = [], identities: any TLSIdentityProvider = SystemTLSIdentities(),
        definitions: [APIDefinitionSource] = [], followRedirects: Bool = true,
        fileTLS: FileTLSConfiguration? = nil
    ) async throws -> Exchange {
        try Task.checkCancellation()
        let selectedProfile = try TLSProfiles.selected(
            draft.tlsProfileID, from: tlsProfiles,
            fileIdentityAvailable: fileTLS?.hasClientIdentity == true)
        let tlsProfile =
            fileTLS?.overridesTrust == true ? fileTLS?.profile : selectedProfile ?? fileTLS?.profile
        let savedIdentity =
            fileTLS == nil
            ? try selectedProfile?.identityReference.map { try identities.identity(for: $0) } : nil
        let frozen = try freeze(
            draft, environment: environment, profiles: profiles, secrets: secrets)
        defer { frozen.removeTemporaryBody() }
        let request = frozen.request
        let fileCredential = fileTLS?.credential(for: request.url)
        if fileTLS != nil, let selectedProfile,
            selectedProfile.requiresClientIdentity || selectedProfile.identityReference != nil,
            fileCredential == nil
        {
            throw FileTLSError.invalidOrigin
        }
        let identity = fileTLS == nil ? savedIdentity : fileCredential?.0
        let contract = try APIContractContext(draft.apiLink, definitions: definitions)
        if let contract {
            guard try contract.requestChecks(request).allSatisfy(\.passed) else {
                throw ContractError.requestRejected
            }
        }
        let configuration = HTTPClientConfiguration.make()
        let delegate = HTTPTransportDelegate(
            prepared: frozen, profile: tlsProfile, identity: identity,
            certificates: fileCredential?.1,
            identityPersistence: fileTLS == nil ? .forSession : .none,
            followRedirects: followRedirects)
        let session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func transportFailure(_ error: Error) throws -> Never {
            if Task.isCancelled { throw CancellationError() }
            if let code = delegate.tlsRejection { throw URLError(code) }
            throw error
        }
        let start = ProcessInfo.processInfo.systemUptime
        let received: (URLSession.AsyncBytes, URLResponse)
        do { received = try await session.bytes(for: request) } catch {
            try transportFailure(error)
        }
        let (bytes, response) = received
        guard let http = response as? HTTPURLResponse else { throw RillError.invalidURL }
        let headersElapsed = ProcessInfo.processInfo.systemUptime - start
        let maximum = budget.downloadBytes
        if response.expectedContentLength > Int64(maximum) { throw RillError.responseTooLarge }
        var data = Data()
        do {
            for try await byte in bytes {
                if data.count >= maximum { throw RillError.responseTooLarge }
                if data.count % 4096 == 0 { try Task.checkCancellation() }
                data.append(byte)
            }
        } catch { try transportFailure(error) }
        let headers = http.allHeaderFields.map {
            Field(name: String(describing: $0.key), value: String(describing: $0.value))
        }.sorted { $0.name < $1.name }
        var checks: [CheckResult] = []
        if !draft.expectedStatus.isEmpty {
            checks.append(
                CheckResult(
                    title: "Status equals \(draft.expectedStatus)",
                    passed: Int(draft.expectedStatus) == http.statusCode))
        }
        if !draft.bodyContains.isEmpty {
            checks.append(
                CheckResult(
                    title: "Body contains \(draft.bodyContains)",
                    passed: String(data: data, encoding: .utf8)?.contains(draft.bodyContains)
                        == true))
        }
        checks += ResponseRules.evaluate(
            draft.assertions ?? [],
            response: Exchange(
                requestID: draft.id, requestName: draft.name, method: draft.method,
                url: http.url?.absoluteString ?? "", status: http.statusCode, duration: 0,
                headers: headers, body: data, checks: []))
        if draft.graphql != nil {
            if let result = try? GraphQL.result(data) {
                checks.append(CheckResult(title: "GraphQL response envelope", passed: result.valid))
                checks.append(
                    CheckResult(title: "GraphQL server errors", passed: result.errors.isEmpty))
            } else {
                checks.append(
                    CheckResult(title: "GraphQL response envelope invalid", passed: false))
            }
        }
        if let contract {
            checks += contract.responseChecks(
                Exchange(
                    requestID: draft.id, requestName: draft.name, method: draft.method,
                    url: http.url?.absoluteString ?? "", status: http.statusCode, duration: 0,
                    headers: headers, body: data, checks: []))
        }
        var summary = PreparedRequestSummary(request)
        summary.tlsPolicy = tlsProfile?.mode.rawValue ?? TLSMode.system.rawValue
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        return Exchange(
            requestID: draft.id, requestName: draft.name, method: draft.method,
            url: http.url?.absoluteString ?? request.url!.absoluteString, status: http.statusCode,
            duration: elapsed, headers: headers, body: data, checks: checks,
            preparedRequest: summary, previewLimit: budget.previewBytes,
            downloadLimit: budget.downloadBytes,
            events: [
                ExecutionEvent(elapsed: 0, title: "Prepared request; transport started"),
                ExecutionEvent(elapsed: headersElapsed, title: "Response headers received"),
                ExecutionEvent(elapsed: elapsed, title: "Response body complete"),
            ])
    }
}

final class HTTPTransportDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let rejectionLock = NSLock()
    private var rejection: URLError.Code?
    var tlsRejection: URLError.Code? { rejectionLock.withLock { rejection } }
    private func rejectTLS(_ code: URLError.Code) {
        rejectionLock.withLock { rejection = code }
    }
    let prepared: PreparedHTTPRequest
    let profile: TLSProfile?
    let identity: SecIdentity?
    let certificates: [SecCertificate]?
    let identityPersistence: URLCredential.Persistence
    let followRedirects: Bool
    init(
        prepared: PreparedHTTPRequest, profile: TLSProfile?, identity: SecIdentity?,
        certificates: [SecCertificate]? = nil,
        identityPersistence: URLCredential.Persistence = .forSession,
        followRedirects: Bool = true
    ) {
        self.prepared = prepared
        self.profile = profile
        self.identity = identity
        self.certificates = certificates
        self.identityPersistence = identityPersistence
        self.followRedirects = followRedirects
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let profile, profile.mode != .system else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            guard let trust = challenge.protectionSpace.serverTrust else {
                rejectTLS(.serverCertificateUntrusted)
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            if profile.mode == .insecure
                || TLSProfiles.evaluate(
                    trust, host: challenge.protectionSpace.host, profile: profile)
            {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                rejectTLS(.serverCertificateUntrusted)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity, challenge.previousFailureCount == 0,
                FileTLSConfiguration.matches(challenge.protectionSpace, url: prepared.request.url)
            else {
                rejectTLS(
                    challenge.previousFailureCount > 0
                        ? .clientCertificateRejected : .clientCertificateRequired)
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(
                    identity: identity,
                    certificates: certificates?.isEmpty == false ? certificates : nil,
                    persistence: identityPersistence))
        default: completionHandler(.performDefaultHandling, nil)
        }
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        completionHandler(prepared.newBodyStream())
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        func origin(_ url: URL?) -> String? {
            guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
            else { return nil }
            return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
        }
        // Do not forward custom credential headers or replay bodies to another origin.
        completionHandler(
            followRedirects && origin(request.url) == origin(prepared.request.url) ? request : nil)
    }
}
