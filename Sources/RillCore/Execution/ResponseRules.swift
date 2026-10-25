import Foundation

public enum AssertionKind: String, Codable, CaseIterable, Sendable {
    case status, headerExists, headerContains, bodyContains, jsonEquals
}
public struct ResponseAssertion: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var kind: AssertionKind = .status
    public var selector = ""
    public var expected = "200"
    public init() {}
}
public enum ExtractionKind: String, Codable, CaseIterable, Sendable { case header, json }
public struct ResponseExtraction: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var kind: ExtractionKind = .json
    public var selector = "$.token"
    public var variable = "token"
    public init() {}
}
public enum WorkflowError: String, LocalizedError, Sendable {
    case invalidConfiguration, missingValue, invalidJSON, invalidSelector, limit, hookFailure,
        invalidBranch
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Invalid workflow configuration. Check rule, hook and runner settings."
        case .missingValue: "A required response value is missing."
        case .invalidJSON: "The complete response must be valid bounded JSON with unique keys."
        case .invalidSelector:
            "Use a JSON Pointer or a simple $.field[0] path; wildcards and filters are unsupported."
        case .limit: "The workflow exceeded its execution, input, output or retention budget."
        case .hookFailure: "The hook failed. Runtime values are omitted from this diagnostic."
        case .invalidBranch:
            "The selected next request must be an ID or a unique name in this collection."
        }
    }
}

/// Exact JSON decimal/string semantics shared with response comparison.
enum ResponseJSON {
    static func value(_ data: Data, path: String) throws -> JSONValue {
        guard path.utf8.count <= 4096 else { throw WorkflowError.invalidSelector }
        let tokens = try pathTokens(path)
        var value: JSONValue
        do { value = try JSONValueParser(data).parse() } catch is CancellationError {
            throw CancellationError()
        } catch { throw WorkflowError.invalidJSON }
        for token in tokens {
            switch value {
            case .object(let object):
                guard let child = object[JSONKey(token)] else { throw WorkflowError.missingValue }
                value = child
            case .array(let array):
                guard
                    token == "0"
                        || (!token.hasPrefix("0")
                            && token.allSatisfy({ $0.isASCII && $0.isNumber })),
                    let index = Int(token), array.indices.contains(index)
                else { throw WorkflowError.missingValue }
                value = array[index]
            default: throw WorkflowError.missingValue
            }
        }
        return value
    }
    static func pathTokens(_ path: String) throws -> [String] {
        if path.isEmpty || path == "$" { return [] }
        if path.hasPrefix("/") {
            return try path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map
            { part in
                let bytes = Array(part.utf8)
                for index in bytes.indices where bytes[index] == 126 {
                    guard index + 1 < bytes.count, [48, 49].contains(bytes[index + 1]) else {
                        throw WorkflowError.invalidSelector
                    }
                }
                return String(part).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(
                    of: "~0", with: "~")
            }
        }
        guard path.hasPrefix("$.") || path.hasPrefix("$[") else {
            throw WorkflowError.invalidSelector
        }
        let chars = Array(path)
        var index = 1
        var tokens: [String] = []
        while index < chars.count {
            if chars[index] == "." {
                index += 1
                let start = index
                while index < chars.count && chars[index] != "." && chars[index] != "[" {
                    index += 1
                }
                let key = String(chars[start..<index])
                guard !key.isEmpty,
                    key.allSatisfy({
                        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
                    })
                else { throw WorkflowError.invalidSelector }
                tokens.append(key)
            } else if chars[index] == "[" {
                index += 1
                let start = index
                while index < chars.count && chars[index].isASCII && chars[index].isNumber {
                    index += 1
                }
                guard index > start, index < chars.count, chars[index] == "]" else {
                    throw WorkflowError.invalidSelector
                }
                let token = String(chars[start..<index])
                guard token == "0" || !token.hasPrefix("0") else {
                    throw WorkflowError.invalidSelector
                }
                tokens.append(token)
                index += 1
            } else {
                throw WorkflowError.invalidSelector
            }
            guard tokens.count <= 128 else { throw WorkflowError.invalidSelector }
        }
        return tokens
    }
    static func encoded(_ value: JSONValue) throws -> String {
        if case .string(let data) = value {
            return String(
                decoding: try JSONEncoder().encode(String(decoding: data, as: UTF8.self)),
                as: UTF8.self)
        }
        return try text(value)
    }
    static func text(_ value: JSONValue) throws -> String {
        switch value {
        case .string(let data): return String(decoding: data, as: UTF8.self)
        case .number(let number): return number
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .object(let object):
            return "{"
                + (try object.keys.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }.map {
                    key in
                    String(decoding: try JSONEncoder().encode(key.text), as: UTF8.self) + ":"
                        + (try encoded(object[key]!))
                }).joined(separator: ",") + "}"
        case .array(let array): return "[" + (try array.map(encoded)).joined(separator: ",") + "]"
        }
    }
}
public enum ResponseRules {
    public static func validate(
        _ assertions: [ResponseAssertion], _ extractions: [ResponseExtraction]
    ) throws {
        guard assertions.count <= 128, extractions.count <= 128,
            Set(assertions.map(\.id)).count == assertions.count,
            Set(extractions.map(\.id)).count == extractions.count,
            assertions.allSatisfy({
                $0.selector.utf8.count <= 4096 && $0.expected.utf8.count <= 1024 * 1024
            }),
            assertions.reduce(0, { $0 + $1.expected.utf8.count }) <= 2 * 1024 * 1024,
            extractions.allSatisfy({ $0.selector.utf8.count <= 4096 && validVariable($0.variable) })
        else { throw WorkflowError.invalidConfiguration }
    }
    public static func validVariable(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }
    public static func evaluate(_ assertions: [ResponseAssertion], response: Exchange)
        -> [CheckResult]
    {
        guard (try? validate(assertions, [])) != nil else {
            return [CheckResult(title: "Invalid assertion configuration", passed: false)]
        }
        return assertions.filter(\.enabled).map { rule in
            let passed: Bool
            do {
                switch rule.kind {
                case .status:
                    passed =
                        Int(rule.expected).map { (100...599).contains($0) && $0 == response.status }
                        ?? false
                case .headerExists:
                    passed =
                        HTTPEncoding.isHeaderName(rule.selector)
                        && response.headers.contains {
                            $0.name.caseInsensitiveCompare(rule.selector) == .orderedSame
                        }
                case .headerContains:
                    passed =
                        HTTPEncoding.isHeaderName(rule.selector)
                        && response.headers.contains {
                            $0.name.caseInsensitiveCompare(rule.selector) == .orderedSame
                                && $0.value.contains(rule.expected)
                        }
                case .bodyContains:
                    passed =
                        response.bodyWasTruncated != true
                        && String(data: response.body, encoding: .utf8)?.contains(rule.expected)
                            == true
                case .jsonEquals:
                    guard response.bodyWasTruncated != true else { throw WorkflowError.invalidJSON }
                    passed =
                        try ResponseJSON.value(response.body, path: rule.selector)
                        == JSONValueParser(Data(rule.expected.utf8)).parse()
                }
            } catch { passed = false }
            return CheckResult(
                title: rule.kind.rawValue
                    + (passed ? " passed" : " failed (missing, invalid or unequal)"), passed: passed
            )
        }
    }
    public static func extract(_ rules: [ResponseExtraction], response: Exchange) throws -> [String:
        String]
    {
        try validate([], rules)
        var updates: [String: String] = [:]
        var bytes = 0
        for rule in rules where rule.enabled {
            try Task.checkCancellation()
            guard updates[rule.variable] == nil else { throw WorkflowError.invalidConfiguration }
            let value: String
            switch rule.kind {
            case .header:
                let matching = response.headers.filter {
                    $0.name.caseInsensitiveCompare(rule.selector) == .orderedSame
                }
                guard HTTPEncoding.isHeaderName(rule.selector), matching.count == 1 else {
                    throw WorkflowError.missingValue
                }
                value = matching[0].value
            case .json:
                guard response.bodyWasTruncated != true else { throw WorkflowError.invalidJSON }
                value = try ResponseJSON.text(
                    ResponseJSON.value(response.body, path: rule.selector))
            }
            bytes += value.utf8.count
            guard value.utf8.count <= 1024 * 1024, bytes <= 4 * 1024 * 1024 else {
                throw WorkflowError.limit
            }
            updates[rule.variable] = value
        }
        return updates
    }
}
