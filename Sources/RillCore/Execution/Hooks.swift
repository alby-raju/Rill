import Foundation
import CryptoKit

public struct RequestHook: Codable, Equatable, Sendable {
    public var enabled = false
    public var language = "json-operations-v1"
    public var source = "[]"
    public init() {}
}
public struct HookOutcome: Sendable {
    public var request: RequestDraft
    public var variables: [String: String]
    public var checks: [CheckResult] = []
    public var logs: [String] = []
    public var next: String?
    public var stop = false
}
public enum HookRuntime {
    public static func validateStorage(_ hook: RequestHook) throws {
        guard hook.language == "json-operations-v1", hook.source.utf8.count <= 256 * 1024 else { throw WorkflowError.invalidConfiguration }
    }
    public static func validate(_ hook: RequestHook) throws {
        try validateStorage(hook)
        guard hook.enabled else { return }
        let data = Data(hook.source.utf8)
        try WorkspaceFile.checkJSONBounds(data)
        _ = try JSONValueParser(data).parse()
        guard let operations = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw WorkflowError.invalidConfiguration }
        var count = 0
        try validate(operations, depth: 0, count: &count)
    }
    private static let fields: [String: Set<String>] = [
        "set": ["op", "name", "value"], "unset": ["op", "name"],
        "url": ["op", "value"], "body": ["op", "value"], "header": ["op", "name", "value"],
        "assert": ["op", "value", "equals"], "extract": ["op", "name", "kind", "selector"],
        "sha256": ["op", "name", "value"], "hmac": ["op", "name", "key", "value"],
        "time": ["op", "name"], "uuid": ["op", "name"], "next": ["op", "value"], "stop": ["op"],
        "log": ["op", "value"], "if": ["op", "value", "equals", "then", "else"]
    ]
    private static func validate(_ operations: [[String: Any]], depth: Int, count: inout Int) throws {
        guard depth <= 16 else { throw WorkflowError.limit }
        for operation in operations {
            count += 1
            guard count <= 1024, let op = operation["op"] as? String, let allowed = fields[op], Set(operation.keys).isSubset(of: allowed),
                  Set(operation.keys).isSuperset(of: allowed.subtracting(op == "if" ? ["else"] : [])) else { throw WorkflowError.invalidConfiguration }
            for (key, value) in operation where key != "then" && key != "else" {
                guard let text = value as? String, text.utf8.count <= 128 * 1024 else { throw WorkflowError.invalidConfiguration }
            }
            if op == "if" {
                guard let yes = operation["then"] as? [[String: Any]] else { throw WorkflowError.invalidConfiguration }
                try validate(yes, depth: depth + 1, count: &count)
                if let other = operation["else"] {
                    guard let no = other as? [[String: Any]] else { throw WorkflowError.invalidConfiguration }
                    try validate(no, depth: depth + 1, count: &count)
                }
            }
        }
    }
    public static func execute(_ hook: RequestHook?, request: RequestDraft, variables: [String: String], response: Exchange? = nil) throws -> HookOutcome {
        var result = HookOutcome(request: request, variables: variables)
        guard let hook, hook.enabled else { return result }
        try validate(hook)
        let start = ProcessInfo.processInfo.systemUptime
        let operations = try JSONSerialization.jsonObject(with: Data(hook.source.utf8)) as! [[String: Any]]
        var count = 0, logBytes = 0
        func checkBudget() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - start <= 0.25, result.variables.count <= 1024,
                  result.variables.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 4 * 1024 * 1024,
                  result.request.url.utf8.count <= 256 * 1024, result.request.body.utf8.count <= 1024 * 1024,
                  result.request.headers.count <= 1000,
                  result.request.headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 256 * 1024 else { throw WorkflowError.limit }
        }
        func resolve(_ text: String) throws -> String {
            var values = result.variables
            values["request.url"] = result.request.url; values["request.body"] = result.request.body
            if let response {
                values["response.status"] = String(response.status)
                values["response.body"] = String(decoding: response.body.prefix(1024 * 1024), as: UTF8.self)
                values["response.bodyTruncated"] = response.body.count > 1024 * 1024 || response.bodyWasTruncated == true ? "true" : "false"
                for header in response.headers.prefix(1000) { values["response.header." + header.name.lowercased()] = header.value }
            }
            let value = try VariableExpansion.resolve(text, values: values)
            guard value.utf8.count <= 1024 * 1024 else { throw WorkflowError.limit }
            return value
        }
        func name(_ operation: [String: Any]) throws -> String {
            guard let value = operation["name"] as? String, ResponseRules.validVariable(value), !value.hasPrefix("request."), !value.hasPrefix("response.") else { throw WorkflowError.invalidConfiguration }
            return value
        }
        func run(_ operations: [[String: Any]]) throws {
            for operation in operations {
                try checkBudget(); count += 1; guard count <= 1024 else { throw WorkflowError.limit }
                let op = operation["op"] as! String
                func value(_ key: String = "value") throws -> String { try resolve(operation[key] as? String ?? "") }
                switch op {
                case "set": result.variables[try name(operation)] = try value()
                case "unset": result.variables.removeValue(forKey: try name(operation))
                case "url": result.request.url = try value()
                case "body": result.request.body = try value(); result.request.bodyMode = .text
                case "header":
                    let key = try value("name"), text = try value()
                    guard HTTPEncoding.isHeaderName(key), !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw WorkflowError.invalidConfiguration }
                    result.request.headers.removeAll { $0.name.caseInsensitiveCompare(key) == .orderedSame }
                    result.request.headers.append(Field(name: key, value: text))
                case "assert": result.checks.append(CheckResult(title: "Hook assertion", passed: try value() == value("equals")))
                case "extract":
                    guard let response, let kind = ExtractionKind(rawValue: operation["kind"] as? String ?? "") else { throw WorkflowError.invalidConfiguration }
                    var rule = ResponseExtraction(); rule.variable = try name(operation); rule.kind = kind; rule.selector = try value("selector")
                    for (key, text) in try ResponseRules.extract([rule], response: response) { result.variables[key] = text }
                case "sha256": result.variables[try name(operation)] = SHA256.hash(data: Data(try value().utf8)).map { String(format: "%02x", $0) }.joined()
                case "hmac":
                    let key = SymmetricKey(data: Data(try value("key").utf8))
                    result.variables[try name(operation)] = HMAC<SHA256>.authenticationCode(for: Data(try value().utf8), using: key).map { String(format: "%02x", $0) }.joined()
                case "time": result.variables[try name(operation)] = String(Int64(Date().timeIntervalSince1970 * 1000))
                case "uuid": result.variables[try name(operation)] = UUID().uuidString.lowercased()
                case "next": result.next = try value()
                case "stop": result.stop = true
                case "log":
                    let text = try value(); logBytes += text.utf8.count
                    guard result.logs.count < 32, logBytes <= 16 * 1024 else { throw WorkflowError.limit }
                    result.logs.append(text)
                case "if":
                    let branch = try value() == value("equals") ? "then" : "else"
                    if let children = operation[branch] as? [[String: Any]] { try run(children) }
                default: throw WorkflowError.invalidConfiguration
                }
                try checkBudget()
                if result.stop { return }
            }
        }
        do { try checkBudget(); try run(operations); try checkBudget() }
        catch is CancellationError { throw CancellationError() }
        catch let error as WorkflowError { throw error }
        catch { throw WorkflowError.hookFailure }
        guard !result.stop || result.next == nil else { throw WorkflowError.invalidBranch }
        return result
    }
}
