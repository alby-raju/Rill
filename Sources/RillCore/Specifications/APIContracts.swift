import Foundation

public enum ContractError: LocalizedError {
    case missingSource, requestRejected
    public var errorDescription: String? {
        switch self {
        case .missingSource: "The linked API definition or operation is missing. Refresh or unlink the request."
        case .requestRejected: "The request does not satisfy its supported API contract. Review required parameters, body, credentials and unsupported rules before sending."
        }
    }
}
struct APIContractContext {
    let root: JSONValue
    let path: String
    let method: String
    let pathItem: JSONValue
    let operation: JSONValue
    init?(_ link: APIRequestLink?, definitions: [APIDefinitionSource]) throws {
        guard let link, link.checkContract else { return nil }
        guard let source = definitions.first(where: { $0.id == link.sourceID }), let space = link.operationKey.firstIndex(of: " ") else { throw ContractError.missingSource }
        root = try JSONValueParser(source.snapshot).parse()
        method = String(link.operationKey[..<space]); path = String(link.operationKey[link.operationKey.index(after: space)...])
        guard let raw = root["paths"]?[path] else { throw ContractError.missingSource }
        func resolved(_ input: JSONValue, root: JSONValue, depth: Int = 0) throws -> JSONValue {
            guard depth <= 32 else { throw SchemaError.limit }
            if let ref = input["$ref"]?.string { return try resolved(root.pointer(ref), root: root, depth: depth + 1) }; return input
        }
        pathItem = try resolved(raw, root: root)
        guard let operation = pathItem[method.lowercased()] else { throw ContractError.missingSource }
        self.operation = operation
    }
    func resolve(_ value: JSONValue, depth: Int = 0) throws -> JSONValue {
        guard depth <= 32 else { throw SchemaError.limit }
        if let ref = value["$ref"]?.string { return try resolve(root.pointer(ref), depth: depth + 1) }; return value
    }
    func schema(_ value: JSONValue, against schema: JSONValue) throws -> Bool {
        try JSONSchema.validate(value, schema: schema, root: root).valid
    }
    func scalar(_ text: String, schema: JSONValue) throws -> JSONValue {
        let type = try resolve(schema)["type"]?.string
        if ["integer", "number", "boolean", "null"].contains(type ?? "") { return try JSONValueParser(Data(text.utf8)).parse() }
        if type == "array" || type == "object" { throw SchemaError.unsupported }
        return .string(Data(text.utf8))
    }
    func requestChecks(_ request: URLRequest) throws -> [CheckResult] {
        var checks: [CheckResult] = []
        func check(_ name: String, _ passed: Bool) { checks.append(CheckResult(title: "Contract " + name, passed: passed)) }
        check("method", request.httpMethod == method)
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ContractError.requestRejected }
        let expected = path.split(separator: "/", omittingEmptySubsequences: false)
        let actual = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        let suffix = actual.suffix(max(0, expected.count - 1))
        let pathFields = expected.dropFirst()
        check("path", suffix.count == pathFields.count && zip(pathFields, suffix).allSatisfy { field, value in
            if field.hasPrefix("{") && field.hasSuffix("}") { return !value.isEmpty }
            return String(value).removingPercentEncoding == String(field).removingPercentEncoding
        })
        var parameters: [JSONValue] = []
        for raw in (pathItem["parameters"]?.array ?? []) + (operation["parameters"]?.array ?? []) {
            let parameter = try resolve(raw)
            guard let name = parameter["name"]?.string, let place = parameter["in"]?.string else { throw SchemaError.invalid }
            parameters.removeAll { $0["name"]?.string == name && $0["in"]?.string == place }; parameters.append(parameter)
        }
        for parameter in parameters {
            guard let name = parameter["name"]?.string, let place = parameter["in"]?.string else { throw SchemaError.invalid }
            let required = parameter["required"]?.bool == true || place == "path"
            if ["body", "formData"].contains(place) {
                if place == "formData" { check("form representation unsupported", false); continue }
                if let body = request.httpBody {
                    check("request body", try schema(JSONValueParser(body).parse(), against: parameter["schema"] ?? .object([:])))
                } else if required { check("required request body", false) }
                continue
            }
            let values: [String]
            switch place {
            case "query": values = (components.queryItems ?? []).filter { $0.name == name }.map { $0.value ?? "" }
            case "header": values = request.value(forHTTPHeaderField: name).map { [$0] } ?? []
            case "cookie":
                values = (request.value(forHTTPHeaderField: "Cookie") ?? "").split(separator: ";").compactMap { field in
                    let pair = field.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    return pair.count == 2 && pair[0] == name ? String(pair[1]) : nil
                }
            case "path":
                if let index = pathFields.firstIndex(of: Substring("{" + name + "}")), suffix.count == pathFields.count {
                    values = [String(Array(suffix)[pathFields.distance(from: pathFields.startIndex, to: index)]).removingPercentEncoding ?? ""]
                } else { values = [] }
            default: throw SchemaError.unsupported
            }
            if values.isEmpty { if required { check("required " + place, false) }; continue }
            let rule = parameter["schema"] ?? .object(Dictionary(uniqueKeysWithValues: (parameter.object ?? [:]).filter { JSONSchema.supported.contains($0.key) && !["required", "example"].contains($0.key) }.map { (JSONKey($0.key), $0.value) }))
            if parameter["content"] != nil || parameter["style"]?.string.map({ !["simple", "form"].contains($0) }) == true { check("parameter representation unsupported", false); continue }
            for value in values { check(place + " schema", try schema(scalar(value, schema: rule), against: rule)) }
        }
        if let raw = operation["requestBody"] {
            let body = try resolve(raw)
            let bytes = request.httpBody?.count ?? Int(request.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
            if body["required"]?.bool == true { check("required request body", bytes > 0) }
            if bytes > 0 {
                let type = Self.mediaType(request.value(forHTTPHeaderField: "Content-Type"))
                guard let description = body["content"]?[type] else { check("request media type", false); return checks }
                if let rule = description["schema"] {
                    if let data = request.httpBody {
                        let value = type.contains("json") ? try JSONValueParser(data).parse() : .string(data)
                        check("request schema", try schema(value, against: rule))
                    } else { check("streaming body schema unsupported", false) }
                }
            }
        }
        let security = operation["security"]?.array ?? root["security"]?.array ?? []
        if !security.isEmpty {
            let schemes = root["components"]?["securitySchemes"] ?? root["securityDefinitions"]
            let query = components.queryItems ?? []
            var acceptable = false
            for alternative in security {
                guard let entries = alternative.object else { throw SchemaError.invalid }
                var complete = true
                for key in entries.keys {
                    guard let raw = schemes?[key] else { throw SchemaError.invalid }; let scheme = try resolve(raw)
                    switch scheme["type"]?.string {
                    case "basic", "http", "oauth2", "openIdConnect": complete = complete && !(request.value(forHTTPHeaderField: "Authorization") ?? "").trimmingCharacters(in: .whitespaces).isEmpty && !(request.value(forHTTPHeaderField: "Authorization") ?? "").hasSuffix(" ")
                    case "apiKey":
                        guard let name = scheme["name"]?.string else { throw SchemaError.invalid }
                        if scheme["in"]?.string == "query" { complete = complete && query.contains { $0.name == name && !($0.value ?? "").isEmpty } }
                        else if scheme["in"]?.string == "header" { complete = complete && !(request.value(forHTTPHeaderField: name) ?? "").isEmpty }
                        else { complete = false }
                    default: complete = false
                    }
                }
                acceptable = acceptable || complete
            }
            check("security presence (not credential validity)", acceptable)
        }
        return checks
    }
    static func mediaType(_ value: String?) -> String { value?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "" }
    func responseChecks(_ response: Exchange) -> [CheckResult] {
        do {
            guard let responses = operation["responses"]?.object else { throw SchemaError.invalid }
            let status = String(response.status)
            guard let raw = responses[status] ?? responses[String(status.prefix(1)) + "XX"] ?? responses["default"] else { return [CheckResult(title: "Contract documented response status", passed: false)] }
            let description = try resolve(raw)
            var checks = [CheckResult(title: "Contract documented response status", passed: true)]
            for (name, raw) in description["headers"]?.object ?? [:] {
                let header = try resolve(raw), value = response.headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
                if value == nil && header["required"]?.bool == true { checks.append(CheckResult(title: "Contract required response header", passed: false)) }
                if let value, let rule = header["schema"] { checks.append(CheckResult(title: "Contract response header schema", passed: try schema(scalar(value, schema: rule), against: rule))) }
            }
            let type = Self.mediaType(response.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value)
            let rule: JSONValue?
            if let content = description["content"]?.object, !content.isEmpty {
                guard !type.isEmpty, let media = content[type] ?? content[type.split(separator: "/").first.map { String($0) + "/*" } ?? ""] ?? content["*/*"] else { checks.append(CheckResult(title: "Contract response media type", passed: false)); return checks }
                rule = media["schema"]
            } else { rule = description["schema"] }
            if let rule {
                guard response.bodyWasTruncated != true else { throw SchemaError.invalid }
                let value = type.contains("json") ? try JSONValueParser(response.body).parse() : .string(response.body)
                checks.append(CheckResult(title: "Contract response schema", passed: try schema(value, against: rule)))
            }
            return checks
        } catch { return [CheckResult(title: "Contract response invalid or unsupported", passed: false)] }
    }
}
