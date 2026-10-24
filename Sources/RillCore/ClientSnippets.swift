import Foundation

public enum ClientTarget: String, CaseIterable, Sendable {
    case requests = "Python requests", httpx = "Python httpx"
    case fetch = "Node fetch", axios = "Node axios"
    case java = "Java HttpClient", okhttp = "Java OkHttp", go = "Go net/http", rust = "Rust reqwest", csharp = "C# HttpClient"
}

/// One owned snapshot, shared by every target. No SDK re-encodes forms or multipart.
public struct FrozenClientRequest: Sendable {
    public let method: String
    public let url: String
    public let headers: [String: String]
    public let body: Data?
    public let timeout: Double
    public static let bodyLimit = 1024 * 1024

    public static func capture(_ draft: RequestDraft, environment: Environment?, includeCredentials: Bool = false,
                               profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil) throws -> Self {
        guard draft.tlsProfileID == nil else { throw CommandError.unsupported("client TLS profiles") }
        let files = (draft.bodyMode == .binary ? [draft.binaryFile].compactMap { $0 } : []) + (draft.bodyMode == .multipart ? (draft.multipartParts ?? []).filter { $0.enabled && $0.kind == .file }.compactMap(\.file) : [])
        var size: UInt64 = 0
        for file in files {
            guard file.byteCount <= UInt64(bodyLimit), size <= UInt64(bodyLimit) - file.byteCount else { throw CommandError.tooLarge }
            size += file.byteCount
        }
        let frozen = try RequestEngine.freeze(draft, environment: environment, profiles: profiles, secrets: secrets)
        defer { frozen.removeTemporaryBody() }
        try Task.checkCancellation()
        let request = frozen.request
        var body = request.httpBody
        if let file = frozen.temporaryBody {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var data = Data()
            while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
                try Task.checkCancellation()
                guard data.count <= bodyLimit - chunk.count else { throw CommandError.tooLarge }
                data.append(chunk)
            }
            body = data
        }
        guard (body?.count ?? 0) <= bodyLimit, let url = request.url?.absoluteString, url.utf8.count <= 256 * 1024 else { throw CommandError.tooLarge }
        var headers = request.allHTTPHeaderFields ?? [:]
        guard headers.count <= 1000, headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 256 * 1024 else { throw CommandError.tooLarge }
        let effective = try AuthenticationProfiles.applying(to: draft, profiles: profiles)
        let values = environment?.variables.filter { $0.enabled && !$0.name.isEmpty }.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
        let customKey = effective.auth == .apiKey && effective.apiKeyLocation != .query
            ? try VariableExpansion.resolve(effective.apiKeyName ?? "", values: values, secretLookup: { name in
                guard let secrets else { throw AuthenticationError.missingSecret }; return try secrets.resolve(name)
            }).lowercased() : ""
        let sensitive: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key", "x-auth-token", customKey]
        for (key, value) in headers {
            let lower = key.lowercased()
            guard !["host", "connection", "transfer-encoding", "expect", "upgrade", "trailer"].contains(lower), value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }), value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { throw CommandError.unsupported("transport-owned or non-ASCII client header") }
            if lower == "content-length" {
                guard Int(value) == (body?.count ?? 0) else { throw CommandError.unsupported("mismatched Content-Length") }
                headers.removeValue(forKey: key)
            } else if !includeCredentials && sensitive.contains(lower) { headers[key] = "[REDACTED]" }
        }
        return Self(method: request.httpMethod ?? "GET", url: url, headers: headers, body: body, timeout: request.timeoutInterval)
    }
}

public enum ClientSnippetGenerator {
    static func literal(_ value: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
    public static func generate(_ request: FrozenClientRequest, target: ClientTarget) throws -> String {
        try Task.checkCancellation()
        if target == .fetch || target == .axios {
            guard !request.headers.keys.contains(where: { ["__proto__", "constructor", "prototype"].contains($0.lowercased()) }) else {
                throw CommandError.unsupported("reserved JavaScript header property")
            }
        }
        let method = try literal(request.method), url = try literal(request.url)
        let headers = "{" + (try request.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { try literal($0.key) + ": " + literal($0.value) }).joined(separator: ", ") + "}"
        let javascriptHeaders = "JSON.parse(" + (try literal(headers)) + ")"
        let encoded = try literal(request.body?.base64EncodedString() ?? "")
        let seconds = String(request.timeout), milliseconds = String(Int(request.timeout * 1000))
        let pythonBody = request.body == nil ? "None" : "base64.b64decode(\(encoded))"
        let nodeBody = request.body == nil ? "undefined" : "Buffer.from(\(encoded), 'base64')"
        let note = "Frozen request; redirects disabled. Review secrets in URL/body/headers. SDK URL, default headers and timeout semantics may differ from Rill. Response limit: 16 MiB."
        let result: String
        switch target {
        case .requests, .httpx:
            let setup = target == .requests ? "# python -m pip install requests\nimport requests" : "# python -m pip install httpx\nimport httpx"
            let client = target == .requests ? "requests.Session()" : "httpx.Client(trust_env=False, follow_redirects=False, timeout=\(seconds))"
            let call = target == .requests
                ? "client.request(\(method), \(url), headers=headers, data=body, timeout=\(seconds), allow_redirects=False, stream=True)"
                : "client.stream(\(method), \(url), headers=headers, content=body)"
            let chunks = target == .requests ? "response.iter_content(chunk_size=65536)" : "response.iter_bytes(chunk_size=65536)"
            result = """
            # \(note)
            \(setup)
            import base64
            import sys
            headers = \(headers)
            body = \(pythonBody)
            with \(client) as client:
                \(target == .requests ? "client.trust_env = False" : "# trust_env is configured in the constructor")
                with \(call) as response:
                    payload = bytearray()
                    for chunk in \(chunks):
                        if len(payload) + len(chunk) > 16777216:
                            raise RuntimeError("Response exceeds 16 MiB")
                        payload.extend(chunk)
                    sys.stdout.buffer.write(payload)
            """
        case .fetch:
            result = """
            // Node 22+; save as request.mjs. \(note)
            const response = await fetch(\(url), {
              method: \(method), headers: \(javascriptHeaders), body: \(nodeBody),
              redirect: 'manual', signal: AbortSignal.timeout(\(milliseconds))
            });
            const chunks = []; let size = 0;
            for await (const chunk of response.body ?? []) {
              size += chunk.length;
              if (size > 16777216) throw new Error('Response exceeds 16 MiB');
              chunks.push(chunk);
            }
            process.stdout.write(Buffer.concat(chunks));
            """
        case .java, .okhttp, .go, .rust, .csharp:
            result = try compiledClient(request, target: target)
        case .axios:
            result = """
            // Node 22+; npm install axios; save as request.mjs. \(note)
            import axios from 'axios';
            const headers = \(javascriptHeaders);
            if (!Object.keys(headers).some(key => key.toLowerCase() === 'content-type')) headers['Content-Type'] = false;
            const response = await axios({
              url: \(url), method: \(method), headers, data: \(nodeBody),
              proxy: false, maxRedirects: 0, timeout: \(milliseconds),
              signal: AbortSignal.timeout(\(milliseconds)), responseType: 'arraybuffer',
              transformRequest: [value => value], transformResponse: [value => value],
              validateStatus: () => true, maxContentLength: 16777216, maxBodyLength: 1048576
            });
            process.stdout.write(Buffer.from(response.data));
            """
        }
        guard result.utf8.count <= 2 * 1024 * 1024 else { throw CommandError.tooLarge }
        return result + "\n"
    }
}
