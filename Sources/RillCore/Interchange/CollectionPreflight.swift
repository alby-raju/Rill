import Foundation

public enum CollectionPreflightInputError: Error {
    case insomnia, nativeWorkspace
}

/// Offline input inspection. Passing this check is not a claim of Newman equivalence.
public struct CollectionPreflight: Encodable, Sendable {
    public struct Issue: Codable, Sendable {
        public let code: String
        public let location: String
        public init(_ code: String, _ location: String) {
            self.code = code
            self.location = location
        }
    }
    public let schemaVersion = 1
    public let scope = "static-postman-input"
    public var requests = 0
    public var scripts = 0
    public var issueCount = 0
    public var issues: [Issue] = []
    public var passed: Bool { requests > 0 && issues.isEmpty }

    public static func inspect(
        collection: Data, environment: Data? = nil, overrides: [String: String] = [:]
    ) throws -> Self {
        try WorkspaceFile.checkJSONBounds(collection)
        func object(_ data: Data) throws -> [String: Any] {
            try WorkspaceFile.checkJSONBounds(data)
            let bytes = data.starts(with: [0xef, 0xbb, 0xbf]) ? Data(data.dropFirst(3)) : data
            guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { throw PostmanImportError.invalid }
            return value
        }
        let root = try object(collection)
        if root["resources"] is [[String: Any]] || root["__export_format"] != nil {
            throw CollectionPreflightInputError.insomnia
        }
        if root["requests"] is [[String: Any]], root["collections"] is [[String: Any]] {
            throw CollectionPreflightInputError.nativeWorkspace
        }
        guard root["info"] is [String: Any], root["item"] is [[String: Any]] else {
            throw PostmanImportError.invalid
        }
        var result = Self()
        func issue(_ code: String, _ path: String) {
            result.issueCount += 1
            if result.issues.count < 1000 { result.issues.append(Issue(code, path)) }
        }
        // Never hydrate imported credentials or apply this workspace.
        do { _ = try PostmanImporter.parse(collection) } catch {
            issue("collection.unsupported_representation", "/")
        }
        var variables: [String: String] = [:]
        func values(_ rows: Any?, path: String) {
            guard let rows else { return }
            guard let rows = rows as? [[String: Any]] else {
                issue("variables.invalid", path)
                return
            }
            var names = Set<String>()
            for (index, row) in rows.enumerated() {
                guard let key = row["key"] as? String, !key.isEmpty, names.insert(key).inserted,
                    let value = row["value"] as? String
                else {
                    issue("variables.invalid_or_duplicate", path + "/\(index)")
                    continue
                }
                if row["enabled"] as? Bool == false || row["disabled"] as? Bool == true { continue }
                variables[key] = value
            }
        }
        values(root["variable"], path: "/variable")
        if let environment {
            let env = try object(environment)
            guard env["_postman_variable_scope"] as? String == "environment",
                env["values"] is [[String: Any]]
            else { throw PostmanImportError.invalid }
            values(env["values"], path: "/environment/values")
        }
        for (key, value) in overrides { variables[key] = value }
        let pattern = try NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
        var remainingReferences = 100_000
        func references(_ text: String, seen: Set<String> = [], depth: Int = 0) -> Bool {
            guard depth <= 32, remainingReferences >= 0, !Task.isCancelled else { return false }
            var valid = true
            pattern.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) {
                match, _, stop in
                remainingReferences -= 1
                guard remainingReferences >= 0, let match,
                    let range = Range(match.range(at: 1), in: text)
                else {
                    valid = false
                    stop.pointee = true
                    return
                }
                let key = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if key.hasPrefix("$") {
                    if !DynamicTemplates.supports(key) {
                        valid = false
                        stop.pointee = true
                    }
                    return
                }
                guard !seen.contains(key), let value = variables[key],
                    references(value, seen: seen.union([key]), depth: depth + 1)
                else {
                    valid = false
                    stop.pointee = true
                    return
                }
            }
            return valid
        }

        func fields(_ value: Any, path: String) {
            if let text = value as? String {
                if !references(text) { issue("variables.unresolved_cyclic_or_limit", path) }
            } else if let rows = value as? [Any] {
                for (i, row) in rows.enumerated() { fields(row, path: path + "/\(i)") }
            } else if let row = value as? [String: Any] {
                if row["disabled"] as? Bool == true { return }
                for key in row.keys.sorted() where key != "description" {
                    // Only fixed field names are emitted: never echo arbitrary JSON keys.
                    if let child = row[key] { fields(child, path: path) }
                }
            }
        }
        func walk(_ row: [String: Any], path: String, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 32 else { throw PostmanImportError.invalid }
            if let events = row["event"] as? [[String: Any]] {
                for (i, event) in events.enumerated() {
                    let script = event["script"] as? [String: Any]
                    let lines = script?["exec"] as? [String]
                    let empty =
                        lines?.allSatisfy {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        } == true && script?["src"] == nil
                    if !empty {
                        result.scripts += 1
                        issue("scripts.unsupported", path + "/event/\(i)")
                    }
                }
            }
            if row["event"] != nil && !(row["event"] is [[String: Any]]) {
                issue("scripts.invalid", path + "/event")
            }
            for key in ["auth", "protocolProfileBehavior", "proxy", "certificate"] {
                if key == "auth", let value = row[key] { fields(value, path: path + "/auth") }
                if key != "auth", row[key] != nil {
                    issue("transport.settings_not_applied", path + "/" + key)
                }
            }
            if let request = row["request"] {
                result.requests += 1
                fields(request, path: path + "/request")
            }
            if let children = row["item"] as? [[String: Any]] {
                for (i, child) in children.enumerated() {
                    try walk(child, path: path + "/item/\(i)", depth: depth + 1)
                }
            }
        }
        try walk(root, path: "", depth: 0)
        try Task.checkCancellation()
        if result.requests == 0 { issue("collection.empty", "/item") }
        return result
    }
}
