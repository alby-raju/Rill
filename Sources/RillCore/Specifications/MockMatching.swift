import Foundation

enum MockMatching {
    static func validate(_ route: MockRoute) throws {
        guard (route.query?.count ?? 0) <= 100, (route.requestHeaders?.count ?? 0) <= 100,
            (route.expectedBody?.utf8.count ?? 0) <= 1024 * 1024,
            (0...10_000).contains(route.delayMilliseconds ?? 0),
            (route.origin?.operation.utf8.count ?? 0) <= 8192
        else { throw WorkflowError.limit }
        let fields = (route.query ?? []) + (route.requestHeaders ?? [])
        guard fields.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 16384,
            fields.allSatisfy({
                !$0.name.isEmpty && $0.name.utf8.count <= 1024 && $0.value.utf8.count <= 8192
            }),
            (route.requestHeaders ?? []).allSatisfy({
                HTTPEncoding.isHeaderName($0.name)
                    && !$0.value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
            }),
            Set((route.requestHeaders ?? []).map { $0.name.lowercased() }).count
                == (route.requestHeaders?.count ?? 0)
        else { throw WorkflowError.invalidConfiguration }
        if let scenario = route.scenario {
            guard ResponseRules.validVariable(scenario.name),
                ResponseRules.validVariable(scenario.requiredState),
                scenario.nextState.map(ResponseRules.validVariable) ?? true
            else { throw WorkflowError.invalidConfiguration }
        }
    }
    static func signature(_ route: MockRoute) throws -> Data {
        func fields(_ rows: [Field]?, headers: Bool = false) -> [[String]] {
            (rows ?? []).filter(\.enabled).map {
                [headers ? $0.name.lowercased() : $0.name, $0.value]
            }.sorted {
                let a = Data($0[0].utf8)
                let b = Data($1[0].utf8)
                return a == b
                    ? Data($0[1].utf8).lexicographicallyPrecedes(Data($1[1].utf8))
                    : a.lexicographicallyPrecedes(b)
            }
        }
        var key: [String: Any] = [
            "method": route.method.rawValue, "path": route.path, "query": fields(route.query),
            "headers": fields(route.requestHeaders, headers: true),
        ]
        if let body = route.expectedBody { key["body"] = body }
        if let scenario = route.scenario {
            key["scenario"] = [scenario.name, scenario.requiredState]
        }
        return try JSONSerialization.data(withJSONObject: key, options: [.sortedKeys])
    }
    static func matches(
        _ route: MockRoute, method: HTTPMethod, path: String, query: [URLQueryItem],
        headers: [String: String], body: Data, states: [String: String]
    ) -> Bool {
        guard route.method == method, pathMatches(route.path, path) else { return false }
        if let scenario = route.scenario,
            (states[scenario.name] ?? "start") != scenario.requiredState
        {
            return false
        }
        for field in route.query ?? [] where field.enabled {
            guard
                query.contains(where: {
                    $0.name.utf8.elementsEqual(field.name.utf8)
                        && ($0.value ?? "").utf8.elementsEqual(field.value.utf8)
                })
            else { return false }
        }
        for field in route.requestHeaders ?? [] where field.enabled {
            guard let value = headers[field.name.lowercased()],
                value.utf8.elementsEqual(field.value.utf8)
            else { return false }
        }
        if let expected = route.expectedBody, body != Data(expected.utf8) { return false }
        return true
    }
    static func pathMatches(_ pattern: String, _ path: String) -> Bool {
        let a = pattern.split(separator: "/", omittingEmptySubsequences: false)
        let b = path.split(separator: "/", omittingEmptySubsequences: false)
        return a.count == b.count
            && zip(a, b).allSatisfy { left, right in
                guard let x = String(left).removingPercentEncoding,
                    let y = String(right).removingPercentEncoding
                else { return false }
                return x.utf8.elementsEqual(y.utf8)
                    || (left.hasPrefix("{") && left.hasSuffix("}") && !right.isEmpty)
            }
    }
}

public enum MockExamples {
    public static func url(base: URL, route: MockRoute) throws -> URL {
        try MockServer.validate([route])
        guard base.scheme == "http", base.host == "127.0.0.1",
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw WorkflowError.invalidConfiguration }
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:@")
        components.percentEncodedPath = try route.path.split(
            separator: "/", omittingEmptySubsequences: false
        ).map {
            if $0.hasPrefix("{") && $0.hasSuffix("}") { return "sample" }
            guard let decoded = String($0).removingPercentEncoding,
                let encoded = decoded.addingPercentEncoding(withAllowedCharacters: allowed)
            else { throw WorkflowError.invalidConfiguration }
            return encoded
        }.joined(separator: "/")
        let query = (route.query ?? []).filter(\.enabled).map {
            URLQueryItem(name: $0.name, value: $0.value)
        }
        components.queryItems = query.isEmpty ? nil : query
        components.fragment = nil
        guard let result = components.url else { throw WorkflowError.invalidConfiguration }
        return result
    }
    public static func curl(base: URL, route: MockRoute) throws -> String {
        func quote(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var command =
            "curl --request " + quote(route.method.rawValue) + " "
            + quote(try url(base: base, route: route).absoluteString)
        for field in route.requestHeaders ?? [] where field.enabled {
            command += " --header " + quote(field.name + ": " + field.value)
        }
        if let body = route.expectedBody { command += " --data-raw " + quote(body) }
        return command
    }
}
