import Foundation

public struct ResponseDifference: Sendable {
    public let path: String
    public let before: String
    public let after: String
}
public struct ResponseComparison: Sendable {
    public let differences: [ResponseDifference]
    public let limited: Bool
    public var text: String {
        if differences.isEmpty { return "JSON values are equal (object order and number spelling ignored)." }
        return differences.map { "\($0.path.isEmpty ? "/" : $0.path)\n− \($0.before)\n+ \($0.after)" }.joined(separator: "\n\n") + (limited ? "\n\nComparison limited to 1,000 differences." : "")
    }
}
public enum ComparisonError: LocalizedError {
    case incomplete, unsupported, limit
    public var errorDescription: String? {
        switch self {
        case .incomplete: "A body was omitted or truncated during retention. Complete payloads are required for semantic comparison."
        case .unsupported: "Semantic comparison requires valid JSON with unique object keys. Non-JSON bodies can be inspected as raw text/bytes."
        case .limit: "JSON comparison exceeds 8 MiB, 128 levels, 100,000 values or the supported numeric exponent range."
        }
    }
}
public enum ResponseComparator {
    public static func compare(_ first: Exchange, _ second: Exchange) throws -> ResponseComparison {
        guard first.bodyWasTruncated != true, second.bodyWasTruncated != true else { throw ComparisonError.incomplete }
        let left = try JSONValueParser(first.body).parse(), right = try JSONValueParser(second.body).parse()
        var differences: [ResponseDifference] = [], limited = false
        func record(_ path: String, _ before: JSONValue?, _ after: JSONValue?) throws {
            guard path.utf8.count <= 8192 else { throw ComparisonError.limit }
            if differences.count >= 1000 { limited = true; return }
            differences.append(ResponseDifference(path: path, before: before?.summary ?? "(missing)", after: after?.summary ?? "(missing)"))
        }
        func descend(_ before: JSONValue, _ after: JSONValue, path: String) throws {
            guard path.utf8.count <= 8192 else { throw ComparisonError.limit }
            if before == after || limited { return }
            switch (before, after) {
            case (.object(let lhs), .object(let rhs)):
                for key in Set(lhs.keys).union(rhs.keys).sorted() {
                    let child = path + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                    if let a = lhs[key], let b = rhs[key] { try descend(a, b, path: child) } else { try record(child, lhs[key], rhs[key]) }
                    if limited { return }
                }
            case (.array(let lhs), .array(let rhs)):
                for index in 0..<max(lhs.count, rhs.count) {
                    let a = lhs.indices.contains(index) ? lhs[index] : nil, b = rhs.indices.contains(index) ? rhs[index] : nil
                    if let a, let b { try descend(a, b, path: path + "/\(index)") } else { try record(path + "/\(index)", a, b) }
                    if limited { return }
                }
            default: try record(path, before, after)
            }
        }
        try descend(left, right, path: "")
        return ResponseComparison(differences: differences, limited: limited)
    }
}
private indirect enum JSONValue: Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(String), bool(Bool), null
    var summary: String {
        switch self {
        case .object(let value): "Object (\(value.count) keys)"
        case .array(let value): "Array (\(value.count) values)"
        case .string(let value): String(reflecting: String(value.prefix(500))) + (value.count > 500 ? "…" : "")
        case .number(let value): String(value.prefix(500))
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        }
    }
}
private struct JSONValueParser {
    let bytes: [UInt8]
    var index = 0
    var nodes = 0
    init(_ data: Data) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw ComparisonError.limit }
        bytes = Array(data)
    }
    mutating func whitespace() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ byte: UInt8) -> Bool { whitespace(); if index < bytes.count && bytes[index] == byte { index += 1; return true }; return false }
    func parse() throws -> JSONValue {
        var parser = self
        let result = try parser.value(depth: 0); parser.whitespace()
        guard parser.index == bytes.count else { throw ComparisonError.unsupported }
        return result
    }
    mutating func value(depth: Int) throws -> JSONValue {
        try Task.checkCancellation()
        nodes += 1; guard nodes <= 100_000, depth <= 128 else { throw ComparisonError.limit }
        whitespace(); guard index < bytes.count else { throw ComparisonError.unsupported }
        switch bytes[index] {
        case 123:
            index += 1; var object: [String: JSONValue] = [:]
            if take(125) { return .object(object) }
            repeat {
                whitespace(); let key = try string()
                guard object[key] == nil, take(58) else { throw ComparisonError.unsupported }
                object[key] = try value(depth: depth + 1)
                if take(125) { return .object(object) }
            } while take(44)
            throw ComparisonError.unsupported
        case 91:
            index += 1; var array: [JSONValue] = []
            if take(93) { return .array(array) }
            repeat {
                array.append(try value(depth: depth + 1))
                if take(93) { return .array(array) }
            } while take(44)
            throw ComparisonError.unsupported
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        default: return .number(try number())
        }
    }
    mutating func literal(_ text: String) throws {
        let value = Array(text.utf8)
        guard index + value.count <= bytes.count, bytes[index..<index + value.count].elementsEqual(value) else { throw ComparisonError.unsupported }
        index += value.count
    }
    mutating func string() throws -> String {
        guard index < bytes.count && bytes[index] == 34 else { throw ComparisonError.unsupported }
        let start = index; index += 1; var escaped = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if escaped { escaped = false }
            else if byte == 92 { escaped = true }
            else if byte == 34 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) } catch { throw ComparisonError.unsupported }
            }
        }
        throw ComparisonError.unsupported
    }
    mutating func number() throws -> String {
        let start = index
        if index < bytes.count && bytes[index] == 45 { index += 1 }
        guard index < bytes.count else { throw ComparisonError.unsupported }
        if bytes[index] == 48 { index += 1 }
        else {
            guard (49...57).contains(bytes[index]) else { throw ComparisonError.unsupported }
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count && bytes[index] == 46 {
            index += 1; let fractionStart = index
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            guard index > fractionStart else { throw ComparisonError.unsupported }
        }
        if index < bytes.count && [69,101].contains(bytes[index]) {
            index += 1
            if index < bytes.count && [43,45].contains(bytes[index]) { index += 1 }
            let exponentStart = index
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            guard index > exponentStart else { throw ComparisonError.unsupported }
        }
        let raw = String(decoding: bytes[start..<index], as: UTF8.self).lowercased()
        let parts = raw.split(separator: "e", omittingEmptySubsequences: false)
        let exponent: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), (-1_000_000...1_000_000).contains(parsed) else { throw ComparisonError.limit }
            exponent = parsed
        } else { exponent = 0 }
        var mantissa = String(parts[0]), negative = false
        if mantissa.hasPrefix("-") { negative = true; mantissa.removeFirst() }
        let fractionCount = mantissa.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        var digits = mantissa.filter { $0 != "." }
        // Normalize exact decimal digits; never round through Double/NSNumber.
        let leading = digits.prefix { $0 == "0" }.count
        digits.removeFirst(leading)
        if digits.isEmpty { return "0" }
        let trailing = digits.reversed().prefix { $0 == "0" }.count
        digits.removeLast(trailing)
        return (negative ? "-" : "") + digits + "e" + String(exponent - fractionCount + trailing)
    }
}
