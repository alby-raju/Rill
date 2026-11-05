import Foundation

/// A redacted inventory, not a JavaScript parser, translator or execution plan.
/// Every nonempty foreign block remains unsupported, independently of its lexical hints.
public struct ScriptCompatibilityInventory: Encodable, Sendable {
    public enum Scope: String, Encodable, Sendable { case collection, folder, request }
    public enum Phase: String, Encodable, Sendable { case prerequest, test, other }
    public enum Disposition: String, Encodable, Sendable { case empty, unsupported, invalid }
    public enum Coverage: String, Encodable, Sendable { case lexical, partial, limited }
    public struct Feature: Encodable, Sendable {
        public let code: String
        public let line: Int
        public let byteColumn: Int
    }
    public struct Source: Encodable, Sendable {
        public let location: String
        public let scope: Scope
        public let phase: Phase
        public let declaredDisabled: Bool
        public let disposition: Disposition
        public var affectedRequests: Int
        public let coverage: Coverage
        public let features: [Feature]
    }
    public let schemaVersion = 1
    public let strategy = "foreign-source-blocked"
    public let analysis = "lexical-hints-only"
    public let supportedForeignConstructs = 0
    public let translatedForeignConstructs = 0
    public private(set) var sourceCount = 0
    public private(set) var requests = 0
    public private(set) var sources: [Source] = []
    public var omittedSources: Int { sourceCount - sources.count }
    public var complete: Bool {
        omittedSources == 0 && !sources.contains { $0.coverage != .lexical }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, strategy, analysis, supportedForeignConstructs,
            translatedForeignConstructs
        case sourceCount, requests, sources, omittedSources, complete
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(strategy, forKey: .strategy)
        try values.encode(analysis, forKey: .analysis)
        try values.encode(supportedForeignConstructs, forKey: .supportedForeignConstructs)
        try values.encode(translatedForeignConstructs, forKey: .translatedForeignConstructs)
        try values.encode(sourceCount, forKey: .sourceCount)
        try values.encode(requests, forKey: .requests)
        try values.encode(sources, forKey: .sources)
        try values.encode(omittedSources, forKey: .omittedSources)
        try values.encode(complete, forKey: .complete)
    }

    public static func inspect(collection: Data, folder: String? = nil) throws -> Self {
        try inspect(PostmanFolderSelection.prepare(collection, folder: folder))
    }

    static func inspect(_ selection: PostmanFolderSelection) throws -> Self {
        guard selection.root["info"] is [String: Any],
            selection.root["item"] is [[String: Any]]
        else { throw PostmanImportError.invalid }
        var result = Self()
        var budget = ScriptFeatureScanner.Budget()
        var remainingNodes = 100_000
        func source(_ event: Any, location: String, scope: Scope) throws -> Source {
            guard let event = event as? [String: Any],
                let script = event["script"] as? [String: Any]
            else {
                return Source(
                    location: location, scope: scope, phase: .other, declaredDisabled: false,
                    disposition: .invalid, affectedRequests: 0, coverage: .lexical,
                    features: [.init(code: "source.invalid", line: 1, byteColumn: 1)])
            }
            let phase = (event["listen"] as? String).flatMap(Phase.init(rawValue:)) ?? .other
            let disabled = event["disabled"] as? Bool == true || script["disabled"] as? Bool == true
            var features: [Feature] = []
            let remote = script["src"] != nil
            if remote { features.append(.init(code: "source.external", line: 1, byteColumn: 1)) }
            let otherLanguage =
                (script["type"] as? String).map {
                    !["text/javascript", "application/javascript", "javascript"].contains($0)
                } ?? false
            if otherLanguage {
                features.append(.init(code: "source.otherLanguage", line: 1, byteColumn: 1))
            }
            let lines = script["exec"] as? [String]
            let empty =
                lines?.allSatisfy {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } == true && !remote
            var coverage = Coverage.lexical
            let disposition: Disposition
            if empty {
                disposition = .empty
            } else if let lines {
                disposition = .unsupported
                let bytes = lines.reduce(0) { $0 + $1.utf8.count } + max(0, lines.count - 1)
                if bytes > 1024 * 1024 || lines.count > 10_000 || bytes > budget.bytes {
                    coverage = .limited
                    features.append(.init(code: "analysis.limit", line: 1, byteColumn: 1))
                } else {
                    budget.bytes -= bytes
                    let scanned = try ScriptFeatureScanner.scan(
                        lines.joined(separator: "\n"), budget: &budget)
                    coverage = scanned.coverage
                    features += scanned.features
                }
            } else {
                disposition = remote ? .unsupported : .invalid
                if !remote {
                    features.append(
                        .init(code: "source.invalidOrMissingExec", line: 1, byteColumn: 1))
                }
            }
            return Source(
                location: location, scope: scope, phase: phase, declaredDisabled: disabled,
                disposition: disposition, affectedRequests: 0, coverage: coverage,
                features: features)
        }
        @discardableResult
        func walk(_ row: [String: Any], location: String, depth: Int) throws -> Int {
            try Task.checkCancellation()
            remainingNodes -= 1
            guard depth <= 33, remainingNodes >= 0 else { throw PostmanImportError.invalid }
            let scope: Scope = depth == 0 ? .collection : row["request"] != nil ? .request : .folder
            let start = result.sources.count
            if let value = row["event"] {
                let events = value as? [Any] ?? [value]
                result.sourceCount += events.count
                for (index, event) in events.prefix(max(0, 1000 - result.sources.count))
                    .enumerated()
                {
                    try Task.checkCancellation()
                    let path = location + "/event" + (value is [Any] ? "/\(index)" : "")
                    result.sources.append(try source(event, location: path, scope: scope))
                }
            }
            let end = result.sources.count
            var count = row["request"] == nil ? 0 : 1
            if let children = row["item"] as? [[String: Any]] {
                for (index, child) in children.enumerated() {
                    let original =
                        selection.originalIndices.indices.contains(depth)
                        ? selection.originalIndices[depth] : index
                    count += try walk(
                        child, location: location + "/item/\(original)", depth: depth + 1)
                }
            }
            for index in start..<end { result.sources[index].affectedRequests = count }
            return count
        }
        result.requests = try walk(selection.root, location: "", depth: 0)
        return result
    }
}
