import Foundation
import CryptoKit

public struct APIDefinitionSource: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var location: String
    public var title: String
    public var version: String
    public var snapshot: Data
    public init(id: UUID = UUID(), location: String, title: String, version: String, snapshot: Data) {
        self.id = id; self.location = location; self.title = title; self.version = version; self.snapshot = snapshot
    }
}
public struct APIRequestLink: Codable, Equatable, Sendable {
    public var sourceID: UUID
    public var operationKey: String
    public var baseline: Data
    public var checkContract = true
    public init(sourceID: UUID, operationKey: String, baseline: Data) { self.sourceID = sourceID; self.operationKey = operationKey; self.baseline = baseline }
}
public struct APIOperation: Sendable {
    public let key: String
    public let group: String
    public let request: RequestDraft
    public let gaps: [String]
    public let fingerprint: String
}
public struct APIDefinition: Sendable {
    public let source: APIDefinitionSource
    public let operations: [APIOperation]
    public let warnings: [String]
}
public enum APIDefinitionLoader {
    public static func fetch(_ url: String) async throws -> APIDefinition {
        var request = RequestDraft(); request.url = url
        let exchange = try await RequestEngine.execute(request, environment: nil, budget: ResponseBudget(downloadBytes: 8 * 1024 * 1024))
        guard (200...299).contains(exchange.status) else { throw SchemaError.invalid }
        return try parse(exchange.body, location: url)
    }
    public static func load(_ url: URL) throws -> APIDefinition { try parse(BoundedFileInput.read(url, limit: 8 * 1024 * 1024), location: url.lastPathComponent) }
    public static func parse(_ input: Data, location: String, sourceID: UUID = UUID()) throws -> APIDefinition {
        guard input.count <= 8 * 1024 * 1024, location.utf8.count <= 4096 else { throw SchemaError.limit }
        var data = input
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        let root: JSONValue
        if String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            root = try JSONValueParser(data).parse()
        } else {
            let object = try BoundedYAML.object(data, allowAliases: true, exactNumbers: true)
            func rejectMerge(_ value: Any, depth: Int = 0) throws {
                guard depth <= 64 else { throw SchemaError.limit }
                if let object = value as? [String: Any] { guard object["<<"] == nil else { throw SchemaError.unsupported }; for child in object.values { try rejectMerge(child, depth: depth + 1) } }
                else if let rows = value as? [Any] { for child in rows { try rejectMerge(child, depth: depth + 1) } }
            }
            try rejectMerge(object)
            root = try JSONValueParser(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).parse()
        }
        guard let object = root.object, let paths = root["paths"]?.object else { throw SchemaError.invalid }
        let version = root["openapi"]?.string ?? root["swagger"]?.string ?? ""
        guard version == "2.0" || ["3.0.", "3.1.", "3.2."].contains(where: { version.hasPrefix($0) }) else { throw SchemaError.unsupported }
        let canonical = Data(try ResponseJSON.encoded(root).utf8)
        guard canonical.count <= 8 * 1024 * 1024 else { throw SchemaError.limit }
        let source = APIDefinitionSource(id: sourceID, location: location, title: root["info"]?["title"]?.string ?? "API definition", version: version, snapshot: canonical)
        var generatedBytes = 0
        var operations: [APIOperation] = [], warnings = ["Generated samples are bounded examples, not proof of conformance. Configure credentials and unresolved path/server variables before running. Source snapshots/examples may contain secrets and remain plain text. External references and remote examples are never loaded."]
        func resolve(_ value: JSONValue, depth: Int = 0) throws -> JSONValue {
            guard depth <= 32 else { throw SchemaError.limit }
            if let ref = value["$ref"]?.string { return try resolve(root.pointer(ref), depth: depth + 1) }; return value
        }
        func server(_ value: JSONValue?) throws -> String {
            if let server = value?.array?.first {
                guard var address = server["url"]?.string else { throw SchemaError.invalid }
                for (name, variable) in server["variables"]?.object ?? [:] {
                    guard let replacement = variable["default"]?.string else { throw SchemaError.invalid }
                    address = address.replacingOccurrences(of: "{" + name + "}", with: replacement)
                }
                return address
            }
            if version == "2.0", let host = root["host"]?.string {
                return (root["schemes"]?.array?.first?.string ?? "https") + "://" + host + (root["basePath"]?.string ?? "")
            }
            if let url = URL(string: location), ["http", "https"].contains(url.scheme ?? ""), let host = url.host {
                return (url.scheme ?? "https") + "://" + host + (url.port.map { ":\($0)" } ?? "")
            }
            return "{{base_url}}"
        }
        for path in paths.keys.sorted() {
            try Task.checkCancellation()
            guard path.hasPrefix("/"), path.utf8.count <= 4096 else { throw SchemaError.invalid }
            let pathItem = try resolve(paths[path]!)
            guard let item = pathItem.object else { throw SchemaError.invalid }
            if item["query"] != nil || item["additionalOperations"] != nil { throw SchemaError.unsupported }
            if item["trace"] != nil && warnings.count < 100 { warnings.append("TRACE is unsupported by the native HTTP transport and was omitted: " + path) }
            for method in HTTPMethod.allCases {
                guard let operation = item[method.rawValue.lowercased()] else { continue }
                guard operation.object != nil else { throw SchemaError.invalid }
                var request = RequestDraft(), gaps: [String] = []
                request.method = method
                request.name = operation["summary"]?.string ?? operation["operationId"]?.string ?? method.rawValue + " " + path
                let group = operation["tags"]?.array?.first?.string ?? source.title
                var address = try server(operation["servers"] ?? pathItem["servers"] ?? root["servers"])
                if address.hasPrefix("/") {
                    if let base = URL(string: location), let absolute = URL(string: address, relativeTo: base)?.absoluteURL, ["http", "https"].contains(absolute.scheme ?? "") { address = absolute.absoluteString }
                    else { address = "{{base_url}}" + address }
                }
                address = address.hasSuffix("/") ? String(address.dropLast()) : address
                var requestPath = path
                var parameters: [JSONValue] = []
                for raw in (pathItem["parameters"]?.array ?? []) + (operation["parameters"]?.array ?? []) {
                    let parameter = try resolve(raw)
                    guard let name = parameter["name"]?.string, let place = parameter["in"]?.string else { throw SchemaError.invalid }
                    parameters.removeAll { $0["name"]?.string == name && $0["in"]?.string == place }; parameters.append(parameter)
                }
                for parameter in parameters {
                    let name = parameter["name"]!.string!, place = parameter["in"]!.string!
                    let schema = try resolve(parameter["schema"] ?? parameter)
                    let example = parameter["example"] ?? schema["example"] ?? schema["default"]
                    let sample = try example ?? APISamples.value(schema, root: root)
                    let text = try APISamples.parameterText(sample)
                    let required = parameter["required"]?.bool == true || place == "path"
                    if required && example == nil { gaps.append("Review generated required \(place) parameter: \(name)") }
                    if parameter["style"]?.string.map({ !["simple", "form"].contains($0) }) == true || parameter["content"] != nil { throw SchemaError.unsupported }
                    switch place {
                    case "path": requestPath = requestPath.replacingOccurrences(of: "{" + name + "}", with: HTTPEncoding.component(text))
                    case "query": request.parameters.append(Field(name: name, value: text))
                    case "header": request.headers.append(Field(name: name, value: text))
                    case "cookie": gaps.append("Configure required cookie parameter manually: " + name)
                    case "body": request.bodyMode = .text; request.body = try ResponseJSON.encoded(sample); request.contentType = root["consumes"]?.array?.first?.string ?? "application/json"
                    case "formData":
                        guard schema["type"]?.string != "file" else { throw SchemaError.unsupported }
                        request.bodyMode = .form; if request.formFields == nil { request.formFields = [] }; request.formFields?.append(Field(name: name, value: text))
                    default: throw SchemaError.unsupported
                    }
                }
                guard !requestPath.contains("{") else { throw SchemaError.invalid }
                request.url = address + requestPath
                if let body = operation["requestBody"] {
                    let body = try resolve(body)
                    guard let content = body["content"]?.object, let media = content.keys.sorted().first(where: { $0 == "application/json" || $0.hasSuffix("+json") || $0.hasPrefix("text/") }), let description = content[media] else { throw SchemaError.unsupported }
                    let schema = try resolve(description["schema"] ?? .object([:]))
                    let sample = try description["example"] ?? description["examples"]?.object?.sorted(by: { $0.key < $1.key }).first?.value["value"] ?? APISamples.value(schema, root: root)
                    request.bodyMode = .text; request.contentType = media; request.body = media.hasPrefix("text/") ? try ResponseJSON.text(sample) : try ResponseJSON.encoded(sample)
                }
                let security = operation["security"]?.array ?? root["security"]?.array ?? []
                if let alternative = security.first?.object, !alternative.isEmpty {
                    let schemes = root["components"]?["securitySchemes"]?.object ?? root["securityDefinitions"]?.object ?? [:]
                    for (index, key) in alternative.keys.sorted().enumerated() {
                        guard let raw = schemes[key] else { throw SchemaError.invalid }; let scheme = try resolve(raw)
                        if index > 0 { gaps.append("Additional security scheme needs manual setup: " + key); continue }
                        switch scheme["type"]?.string {
                        case "basic": request.auth = .basic; request.username = "{{username}}"
                        case "http" where scheme["scheme"]?.string?.lowercased() == "basic": request.auth = .basic; request.username = "{{username}}"
                        case "http" where scheme["scheme"]?.string?.lowercased() == "bearer": request.auth = .bearer
                        case "apiKey":
                            if ["query", "header"].contains(scheme["in"]?.string ?? "") {
                                request.auth = .apiKey; request.apiKeyName = scheme["name"]?.string; request.apiKeyLocation = scheme["in"]?.string == "query" ? .query : .header
                            } else { gaps.append("Cookie API-key auth requires manual configuration") }
                        case "oauth2", "openIdConnect": request.auth = .bearer; gaps.append("OAuth/OpenID metadata retained in source; configure native auth/token explicitly")
                        default: gaps.append("Unsupported security scheme needs manual setup: " + key)
                        }
                        gaps.append("Configure credentials for security scheme: " + key)
                    }
                }
                if let success = operation["responses"]?.object?.keys.sorted().first(where: { Int($0).map { (200...299).contains($0) } == true }) { request.expectedStatus = success }
                else { gaps.append("No concrete documented success status; review positive test") }
                let key = method.rawValue + " " + path
                let fingerprint = SHA256.hash(data: Data(try ResponseJSON.encoded(.array([operation, root["components"]?["schemas"] ?? .null, root["definitions"] ?? .null])).utf8)).map { String(format: "%02x", $0) }.joined()
                generatedBytes += try JSONEncoder().encode(request).count + group.utf8.count + gaps.reduce(0, { $0 + $1.utf8.count })
                guard generatedBytes <= 16 * 1024 * 1024, request.name.utf8.count <= 4096, group.utf8.count <= 4096, request.url.utf8.count <= 256 * 1024, request.headers.count <= 1000, request.parameters.count <= 1000 else { throw SchemaError.limit }
                operations.append(APIOperation(key: key, group: group, request: request, gaps: gaps, fingerprint: fingerprint))
                guard operations.count <= 2000, request.body.utf8.count <= 1024 * 1024 else { throw SchemaError.limit }
            }
        }
        if object["webhooks"] != nil || object["callbacks"] != nil { warnings.append("Callbacks/webhooks do not generate outgoing requests.") }
        return APIDefinition(source: source, operations: operations, warnings: warnings)
    }
}
enum APISamples {
    static func parameterText(_ value: JSONValue) throws -> String {
        guard case .number = value else { return try ResponseJSON.text(value) }
        let number = try ExactSchemaNumber(value)
        guard abs(number.exponent) + number.digits.count <= 4096 else { throw SchemaError.limit }
        let sign = number.negative ? "-" : ""
        if number.exponent >= 0 { return sign + number.digits + String(repeating: "0", count: number.exponent) }
        let point = number.digits.count + number.exponent
        if point > 0 { let index = number.digits.index(number.digits.startIndex, offsetBy: point); return sign + number.digits[..<index] + "." + number.digits[index...] }
        return sign + "0." + String(repeating: "0", count: -point) + number.digits
    }
    private struct Budget { var nodes = 0; var bytes = 0 }
    static func value(_ schema: JSONValue, root: JSONValue) throws -> JSONValue {
        var budget = Budget()
        return try walk(schema, root: root, depth: 0, references: [], budget: &budget)
    }
    private static func literal(_ value: JSONValue, budget: inout Budget) throws -> JSONValue {
        budget.bytes += try ResponseJSON.encoded(value).utf8.count
        guard budget.bytes <= 1024 * 1024 else { throw SchemaError.limit }
        return value
    }
    private static func walk(_ schema: JSONValue, root: JSONValue, depth: Int, references: Set<String>, budget: inout Budget) throws -> JSONValue {
        try Task.checkCancellation(); budget.nodes += 1
        guard budget.nodes <= 10_000, budget.bytes <= 1024 * 1024 else { throw SchemaError.limit }
        guard depth <= 16 else { throw SchemaError.limit }
        if let ref = schema["$ref"]?.string {
            guard !references.contains(ref) else { throw SchemaError.unsupported }
            return try walk(root.pointer(ref), root: root, depth: depth + 1, references: references.union([ref]), budget: &budget)
        }
        if let sample = schema["example"] ?? schema["default"] ?? schema["const"] ?? schema["enum"]?.array?.first { budget.bytes += try ResponseJSON.encoded(sample).utf8.count; guard budget.bytes <= 1024 * 1024 else { throw SchemaError.limit }; return sample }
        if let alternatives = schema["oneOf"]?.array ?? schema["anyOf"]?.array { guard let first = alternatives.first else { throw SchemaError.invalid }; return try walk(first, root: root, depth: depth + 1, references: references, budget: &budget) }
        switch schema["type"]?.string {
        case "object", nil where schema["properties"] != nil:
            var object: [JSONKey: JSONValue] = [:]
            let properties = schema["properties"]?.object ?? [:]
            guard properties.count <= 128 else { throw SchemaError.limit }
            for (name, child) in properties { budget.bytes += name.utf8.count + 6; object[JSONKey(name)] = try walk(child, root: root, depth: depth + 1, references: references, budget: &budget) }
            return .object(object)
        case "array": return .array([try walk(schema["items"] ?? .object([:]), root: root, depth: depth + 1, references: references, budget: &budget)])
        case "integer", "number": return try literal(schema["minimum"] ?? .number("0"), budget: &budget)
        case "boolean": return try literal(.bool(false), budget: &budget)
        case "null": return try literal(.null, budget: &budget)
        default: return try literal(.string(Data("example".utf8)), budget: &budget)
        }
    }
}
