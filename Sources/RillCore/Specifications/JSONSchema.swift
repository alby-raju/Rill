import Foundation

public struct SchemaFinding: Codable, Equatable, Sendable {
    public let path: String
    public let keyword: String
    public let message: String
}
public struct SchemaValidation: Codable, Sendable {
    public let findings: [SchemaFinding]
    public let unsupported: [String]
    public var valid: Bool { findings.isEmpty && unsupported.isEmpty }
}
public enum SchemaError: LocalizedError {
    case invalid, unsupported, limit
    public var errorDescription: String? {
        switch self {
        case .invalid: "Invalid JSON/schema input or local reference. Runtime values are omitted."
        case .unsupported:
            "This schema contains unsupported validation rules or external references."
        case .limit:
            "Schema validation exceeds its input, depth, node, reference or finding budget."
        }
    }
}
extension JSONValue {
    var object: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        var result: [String: JSONValue] = [:]
        for (key, value) in object {
            guard result[key.text] == nil else { return nil }
            result[key.text] = value
        }
        return result
    }
    var string: String? {
        if case .string(let value) = self { return String(decoding: value, as: UTF8.self) }
        return nil
    }
    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
    subscript(_ name: String) -> JSONValue? {
        if case .object(let object) = self { return object[JSONKey(name)] }
        return nil
    }
    func pointer(_ reference: String) throws -> JSONValue {
        guard reference == "#" || reference.hasPrefix("#/"),
            let decoded = String(reference.dropFirst()).removingPercentEncoding
        else { throw SchemaError.unsupported }
        var value = self
        for token in try ResponseJSON.pathTokens(decoded) {
            if case .object(let object) = value, let child = object[JSONKey(token)] {
                value = child
            } else if case .array(let array) = value, let index = Int(token),
                String(index) == token, array.indices.contains(index)
            {
                value = array[index]
            } else {
                throw SchemaError.invalid
            }
        }
        return value
    }
}
/// Decimal comparison on normalized digit/exponent strings; no Double rounding.
struct ExactSchemaNumber: Comparable {
    let negative: Bool
    let digits: String
    let exponent: Int
    init(_ value: JSONValue) throws {
        guard case .number(let normalized) = value else { throw SchemaError.invalid }
        var text = normalized
        negative = text.hasPrefix("-")
        if negative { text.removeFirst() }
        let pieces = text.split(separator: "e", omittingEmptySubsequences: false)
        guard pieces[0].count <= 4096 else { throw SchemaError.limit }
        digits = String(pieces[0])
        exponent = pieces.count == 2 ? Int(pieces[1])! : 0
    }
    var integer: Bool { digits == "0" || exponent >= 0 }
    var nonnegativeInt: Int? {
        guard !negative, integer, digits.count + exponent <= 9 else { return nil }
        return Int(digits + String(repeating: "0", count: exponent))
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.negative != rhs.negative { return lhs.negative }
        func magnitude(_ a: Self, _ b: Self) -> Bool {
            if a.digits == "0" { return b.digits != "0" }
            if b.digits == "0" { return false }
            let left = a.digits.count + a.exponent
            let right = b.digits.count + b.exponent
            if left != right { return left < right }
            let length = max(a.digits.count, b.digits.count)
            return a.digits.padding(toLength: length, withPad: "0", startingAt: 0)
                .lexicographicallyPrecedes(
                    b.digits.padding(toLength: length, withPad: "0", startingAt: 0))
        }
        return lhs.negative ? magnitude(rhs, lhs) : magnitude(lhs, rhs)
    }
}
public enum JSONSchema {
    static let supported: Set<String> = [
        "$schema", "$id", "$defs", "definitions", "$ref", "type", "required", "properties", "enum",
        "const", "items", "additionalProperties", "minimum", "maximum", "exclusiveMinimum",
        "exclusiveMaximum", "minLength", "maxLength", "minItems", "maxItems", "minProperties",
        "maxProperties", "nullable", "allOf", "anyOf", "oneOf", "title", "description", "default",
        "example", "examples", "format", "deprecated", "readOnly", "writeOnly", "discriminator",
        "xml", "externalDocs",
    ]
    public static func validate(instance: Data, schema: Data) throws -> SchemaValidation {
        let value = try JSONValueParser(instance).parse()
        let root = try JSONValueParser(schema).parse()
        return try validate(value, schema: root, root: root)
    }
    static func validate(_ instance: JSONValue, schema: JSONValue, root: JSONValue) throws
        -> SchemaValidation
    {
        var unsupported = Set<String>()
        var inspected = 0
        func inspect(_ schema: JSONValue, depth: Int, references: Set<String>) throws {
            try Task.checkCancellation()
            inspected += 1
            guard depth <= 64, inspected <= 10_000 else { throw SchemaError.limit }
            if schema.bool != nil { return }
            guard let object = schema.object else { throw SchemaError.invalid }
            if depth > 0 && object["$id"] != nil { unsupported.insert("nested $id") }
            for key in object.keys where !supported.contains(key) && !key.hasPrefix("x-") {
                unsupported.insert(String(decoding: key.utf8.prefix(128), as: UTF8.self))
            }
            guard unsupported.count <= 128 else { throw SchemaError.limit }
            if let ref = object["$ref"] {
                guard let text = ref.string else { throw SchemaError.invalid }
                if !text.hasPrefix("#") {
                    unsupported.insert("external $ref")
                } else if !references.contains(text) {
                    try inspect(
                        root.pointer(text), depth: depth + 1, references: references.union([text]))
                }
            }
            for key in ["properties", "$defs", "definitions"] {
                if let children = object[key] {
                    guard let children = children.object else { throw SchemaError.invalid }
                    for child in children.values {
                        try inspect(child, depth: depth + 1, references: references)
                    }
                }
            }
            for key in ["items", "additionalProperties"] {
                if let child = object[key] {
                    try inspect(child, depth: depth + 1, references: references)
                }
            }
            for key in ["allOf", "anyOf", "oneOf"] {
                if let children = object[key] {
                    guard let children = children.array, !children.isEmpty, children.count <= 128
                    else { throw SchemaError.invalid }
                    for child in children {
                        try inspect(child, depth: depth + 1, references: references)
                    }
                }
            }
            if let type = object["type"] {
                let types = type.string.map { [$0] } ?? type.array?.compactMap(\.string) ?? []
                guard !types.isEmpty, types.count == (type.array?.count ?? 1),
                    types.allSatisfy({
                        ["object", "array", "string", "number", "integer", "boolean", "null"]
                            .contains($0)
                    })
                else { throw SchemaError.invalid }
            }
            if let required = object["required"] {
                guard let rows = required.array, rows.allSatisfy({ $0.string != nil }),
                    Set(rows.compactMap(\.string)).count == rows.count
                else { throw SchemaError.invalid }
            }
            for key in [
                "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties",
            ] {
                if let number = object[key] {
                    guard try ExactSchemaNumber(number).nonnegativeInt != nil else {
                        throw SchemaError.invalid
                    }
                }
            }
            for key in ["minimum", "maximum"] {
                if let number = object[key] { _ = try ExactSchemaNumber(number) }
            }
            for key in ["exclusiveMinimum", "exclusiveMaximum"] {
                if let number = object[key], number.bool == nil {
                    _ = try ExactSchemaNumber(number)
                }
            }
            if let flag = object["nullable"] {
                guard flag.bool != nil else { throw SchemaError.invalid }
            }
            if let values = object["enum"] {
                guard let rows = values.array, !rows.isEmpty else { throw SchemaError.invalid }
            }
        }
        try inspect(schema, depth: 0, references: [])
        if !unsupported.isEmpty {
            return SchemaValidation(findings: [], unsupported: unsupported.sorted())
        }
        var visited = 0
        func evaluate(
            _ value: JSONValue, _ schema: JSONValue, path: String, depth: Int,
            references: Set<String>
        ) throws -> [SchemaFinding] {
            try Task.checkCancellation()
            visited += 1
            guard depth <= 64, visited <= 10_000, path.utf8.count <= 8192 else {
                throw SchemaError.limit
            }
            if let bool = schema.bool {
                return bool
                    ? []
                    : [SchemaFinding(path: path, keyword: "false", message: "Value is forbidden")]
            }
            let object = schema.object!
            var findings: [SchemaFinding] = []
            func fail(_ keyword: String) {
                if findings.count < 1000 {
                    findings.append(
                        SchemaFinding(
                            path: path, keyword: keyword,
                            message: "Value does not satisfy the documented rule"))
                }
            }
            if let ref = object["$ref"]?.string {
                let key = ref + "|" + path
                guard !references.contains(key) else { throw SchemaError.invalid }
                findings += try evaluate(
                    value, root.pointer(ref), path: path, depth: depth + 1,
                    references: references.union([key]))
            }
            let nullableNull = object["nullable"]?.bool == true && value == .null
            if let type = object["type"], !nullableNull {
                let types = type.string.map { [$0] } ?? type.array!.compactMap(\.string)
                func matches(_ type: String) throws -> Bool {
                    switch (type, value) {
                    case ("object", .object), ("array", .array), ("string", .string),
                        ("number", .number), ("boolean", .bool), ("null", .null):
                        return true
                    case ("integer", .number): return try ExactSchemaNumber(value).integer
                    default: return false
                    }
                }
                var matching = false
                for type in types { if try matches(type) { matching = true } }
                if !matching { fail("type") }
            }
            if let values = object["enum"]?.array, !values.contains(value) { fail("enum") }
            if let expected = object["const"], expected != value { fail("const") }
            for key in ["allOf", "anyOf", "oneOf"] {
                if let schemas = object[key]?.array {
                    var passes = 0
                    for child in schemas {
                        if try evaluate(
                            value, child, path: path, depth: depth + 1, references: references
                        ).isEmpty {
                            passes += 1
                        }
                    }
                    if key == "allOf" && passes != schemas.count || key == "anyOf" && passes == 0
                        || key == "oneOf" && passes != 1
                    {
                        fail(key)
                    }
                }
            }
            func bounds(_ count: Int, _ minimum: String, _ maximum: String) throws {
                if let lower = object[minimum],
                    count < (try ExactSchemaNumber(lower).nonnegativeInt!)
                {
                    fail(minimum)
                }
                if let upper = object[maximum],
                    count > (try ExactSchemaNumber(upper).nonnegativeInt!)
                {
                    fail(maximum)
                }
            }
            switch value {
            case .object(let values):
                try bounds(values.count, "minProperties", "maxProperties")
                for key in object["required"]?.array?.compactMap(\.string) ?? []
                where values[JSONKey(key)] == nil { fail("required") }
                var properties: [JSONKey: JSONValue] = [:]
                if case .object(let rules)? = object["properties"] { properties = rules }
                for (key, child) in values {
                    if let rule = properties[key] ?? object["additionalProperties"] {
                        let next =
                            path + "/"
                            + key.text.replacingOccurrences(of: "~", with: "~0")
                            .replacingOccurrences(of: "/", with: "~1")
                        findings += try evaluate(
                            child, rule, path: next, depth: depth + 1, references: references)
                    }
                    guard findings.count <= 1000 else { throw SchemaError.limit }
                }
            case .array(let values):
                try bounds(values.count, "minItems", "maxItems")
                if let rule = object["items"] {
                    for (index, child) in values.enumerated() {
                        findings += try evaluate(
                            child, rule, path: path + "/\(index)", depth: depth + 1,
                            references: references)
                        guard findings.count <= 1000 else { throw SchemaError.limit }
                    }
                }
            case .string(let bytes):
                try bounds(
                    String(decoding: bytes, as: UTF8.self).unicodeScalars.count, "minLength",
                    "maxLength")
            case .number:
                let number = try ExactSchemaNumber(value)
                if let lower = object["minimum"] {
                    let limit = try ExactSchemaNumber(lower)
                    if number < limit || object["exclusiveMinimum"]?.bool == true && number == limit
                    {
                        fail("minimum")
                    }
                }
                if let upper = object["maximum"] {
                    let limit = try ExactSchemaNumber(upper)
                    if number > limit || object["exclusiveMaximum"]?.bool == true && number == limit
                    {
                        fail("maximum")
                    }
                }
                if let lower = object["exclusiveMinimum"], lower.bool == nil,
                    number <= (try ExactSchemaNumber(lower))
                {
                    fail("exclusiveMinimum")
                }
                if let upper = object["exclusiveMaximum"], upper.bool == nil,
                    number >= (try ExactSchemaNumber(upper))
                {
                    fail("exclusiveMaximum")
                }
            default: break
            }
            guard findings.count <= 1000 else { throw SchemaError.limit }
            return findings
        }
        return SchemaValidation(
            findings: try evaluate(instance, schema, path: "", depth: 0, references: []),
            unsupported: [])
    }
}
