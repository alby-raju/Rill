import Foundation

/// Explicit raw artifact: response bodies and headers can contain credentials. Ordinary exports
/// always strip these fields. This format never contains variable maps or credential providers.
public enum RunSnapshotFile {
    private struct Envelope: Codable {
        var kind = "rill.run-snapshot"
        var schemaVersion = 1
        let report: RunReport
    }
    public static func encode(_ report: RunReport) throws -> Data {
        try RunReportExporter.validate(report)  // shared metric/resource validation
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(report: report))
        guard data.count <= ResourceLimits.workspaceBytes else { throw WorkflowError.limit }
        return data
    }
    public static func decode(_ data: Data) throws -> RunReport {
        try WorkspaceFile.checkJSONBounds(data)
        struct Header: Decodable {
            let kind: String
            let schemaVersion: Int
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(Header.self, from: data)
        guard header.schemaVersion == 1 else { throw WorkflowError.invalidConfiguration }
        let report: RunReport
        switch header.kind {
        case "rill.run-snapshot": report = try decoder.decode(Envelope.self, from: data).report
        case "rill.run-report": report = try decoder.decode(RunReport.self, from: data)
        default: throw WorkflowError.invalidConfiguration
        }
        guard
            report.outcomes.allSatisfy({
                (1...10000).contains($0.iteration) && (0...6).contains($0.attempt)
                    && ($0.status.map { (100...599).contains($0) } ?? true)
                    && (0...(256 * 1024 * 1024)).contains($0.bodyBytes)
                    && ($0.retainedBody?.count ?? 0) <= ResourceLimits.workspaceBytes
                    && ($0.responseHeaders?.count ?? 0) <= 100
                    && (0...100000).contains($0.checkCount ?? $0.checks.count)
                    && (0...($0.checkCount ?? $0.checks.count)).contains(
                        $0.failedCheckCount ?? $0.checks.filter { !$0.passed }.count)
                    && ($0.checksOmitted == true
                        || ($0.checkCount ?? $0.checks.count) == $0.checks.count)
                    && ($0.bodyOmitted || $0.retainedBody != nil)
                    && ($0.retainedBody?.count ?? 0) <= $0.bodyBytes
                    && ($0.headersOmitted != false || $0.responseHeaders != nil)
            }), (0...10000).contains(report.requestedSteps), (report.sources?.count ?? 0) <= 10000,
            (report.sources ?? [:]).allSatisfy({
                UUID(uuidString: $0.key) != nil && RunSources.valid($0.value)
            }),
            report.sourceFormat == nil
                || ["postman-position-v1", "native-id-v1"].contains(report.sourceFormat!),
            Set(report.outcomes.map(\.id)).count == report.outcomes.count
        else { throw WorkflowError.invalidConfiguration }
        try RunReportExporter.validate(report)
        return report
    }
}

public struct RunComparisonOptions: Sendable {
    public var metadataOnly = false
    public var ignoreJSONPointers: [String] = []
    public var ignoreHeaders: [String] = ["date", "server", "content-length"]
    public var latencyIncreasePercent: Double = 20
    public var latencyFloorMilliseconds: Double = 10
    public init() {}
    public func validate() throws {
        guard ignoreJSONPointers.count <= 100,
            ignoreJSONPointers.allSatisfy(ResponseComparator.validPointer),
            ignoreHeaders.count <= 100, ignoreHeaders.allSatisfy(HTTPEncoding.isHeaderName),
            latencyIncreasePercent.isFinite, (0...100000).contains(latencyIncreasePercent),
            latencyFloorMilliseconds.isFinite, (0...86400000).contains(latencyFloorMilliseconds)
        else { throw WorkflowError.invalidConfiguration }
    }
}
public struct RunChange: Encodable, Sendable {
    public let requestID: UUID
    public let iteration: Int
    public let visit: Int
    public let missingBefore: Bool
    public let missingAfter: Bool
    public let stateChanged: Bool
    public let statusChanged: Bool
    public let assertionsChanged: Bool?
    public let retriesChanged: Bool
    public let latencyRegression: Bool
    public let bodyChanged: Bool?
    public let schemaChanged: Bool?
    public let headersChanged: Bool?
    public let sourceLocation: String?
    public let beforeStatus: Int?
    public let afterStatus: Int?
    public let beforeState: RunState?
    public let afterState: RunState?
    public let beforeSeconds: Double?
    public let afterSeconds: Double?
    public let beforeChecks: Int?
    public let afterChecks: Int?
    public let beforeFailedChecks: Int?
    public let afterFailedChecks: Int?
    public let bodyDifferenceCount: Int?
    public var changed: Bool {
        missingBefore || missingAfter || stateChanged || statusChanged || assertionsChanged == true
            || retriesChanged || latencyRegression || bodyChanged == true || schemaChanged == true
            || headersChanged == true
    }
}
public struct RunComparisonReport: Encodable, Sendable {
    public let schemaVersion = 1
    public let kind = "rill.run-comparison"
    public let changes: [RunChange]
    public let beforePassed: Bool
    public let afterPassed: Bool
    public let metadataOnly: Bool
    public let ignoredJSONPointerCount: Int
    public let ignoredHeaderCount: Int
    public let latencyIncreasePercent: Double
    public let latencyFloorMilliseconds: Double
    public let missingPayloadComparisons: Int
    public let limitedBodyComparisons: Int
    public let missingHeaderComparisons: Int
    public let missingAssertionComparisons: Int
    public var complete: Bool {
        missingPayloadComparisons == 0 && limitedBodyComparisons == 0
            && missingHeaderComparisons == 0 && missingAssertionComparisons == 0
    }
    public var changed: Bool { beforePassed != afterPassed || changes.contains(where: \.changed) }
    public func encode(to encoder: Encoder) throws {
        enum Key: String, CodingKey {
            case schemaVersion, kind, changes, beforePassed, afterPassed, changed, complete
            case metadataOnly, ignoredJSONPointerCount, ignoredHeaderCount, latencyIncreasePercent,
                latencyFloorMilliseconds,
                missingPayloadComparisons, limitedBodyComparisons, missingHeaderComparisons,
                missingAssertionComparisons
        }
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(kind, forKey: .kind)
        try container.encode(changes, forKey: .changes)
        try container.encode(beforePassed, forKey: .beforePassed)
        try container.encode(afterPassed, forKey: .afterPassed)
        try container.encode(metadataOnly, forKey: .metadataOnly)
        try container.encode(ignoredJSONPointerCount, forKey: .ignoredJSONPointerCount)
        try container.encode(ignoredHeaderCount, forKey: .ignoredHeaderCount)
        try container.encode(latencyIncreasePercent, forKey: .latencyIncreasePercent)
        try container.encode(latencyFloorMilliseconds, forKey: .latencyFloorMilliseconds)
        try container.encode(changed, forKey: .changed)
        try container.encode(complete, forKey: .complete)
        try container.encode(missingPayloadComparisons, forKey: .missingPayloadComparisons)
        try container.encode(limitedBodyComparisons, forKey: .limitedBodyComparisons)
        try container.encode(missingHeaderComparisons, forKey: .missingHeaderComparisons)
        try container.encode(missingAssertionComparisons, forKey: .missingAssertionComparisons)
    }

}
public enum RunComparator {
    private struct Key: Hashable {
        let id: UUID
        let iteration: Int
        let visit: Int
    }
    private static func terminal(_ report: RunReport) -> [(Key, RunAttempt)] {
        let attempts = report.outcomes
        var visits: [String: Int] = [:]
        var result: [(Key, RunAttempt)] = []
        for (index, attempt) in attempts.enumerated() {
            if index + 1 < attempts.count {
                let next = attempts[index + 1]
                if next.requestID == attempt.requestID && next.iteration == attempt.iteration
                    && next.attempt == attempt.attempt + 1
                {
                    continue
                }
            }
            let key = "\(attempt.requestID)/\(attempt.iteration)"
            visits[key, default: 0] += 1
            result.append(
                (
                    Key(id: attempt.requestID, iteration: attempt.iteration, visit: visits[key]!),
                    attempt
                ))
        }
        return result
    }
    public static func compare(
        _ before: RunReport, _ after: RunReport, options: RunComparisonOptions = .init()
    ) throws -> RunComparisonReport {
        try options.validate()
        guard before.sourceFormat == after.sourceFormat else {
            throw WorkflowError.invalidConfiguration
        }
        try RunReportExporter.validate(before)
        try RunReportExporter.validate(after)
        let lhs = Dictionary(uniqueKeysWithValues: terminal(before))
        let rhs = Dictionary(uniqueKeysWithValues: terminal(after))
        let keys = Set(lhs.keys).union(rhs.keys).sorted {
            if $0.id != $1.id { return $0.id.uuidString < $1.id.uuidString }
            return $0.iteration != $1.iteration ? $0.iteration < $1.iteration : $0.visit < $1.visit
        }
        guard keys.count <= 20000 else { throw WorkflowError.limit }
        var missingPayloads = 0
        var limited = 0
        var missingHeaders = 0
        var missingAssertions = 0
        let ignoredHeaders = Set(options.ignoreHeaders.map { $0.lowercased() })
        var changes: [RunChange] = []
        for key in keys {
            try Task.checkCancellation()
            let a = lhs[key]
            let b = rhs[key]
            var bodyChanged: Bool?
            var bodyDifferenceCount: Int?
            var schemaChanged: Bool?
            var headersChanged: Bool?
            if !options.metadataOnly, let a, let b, a.bodyOmitted == false, b.bodyOmitted == false,
                let x = a.retainedBody, let y = b.retainedBody
            {
                if x == y {
                    bodyChanged = false
                    bodyDifferenceCount = 0
                    schemaChanged = (try? JSONValueParser(x).parse()) == nil ? nil : false
                    if x.count > 8 * 1024 * 1024 { limited += 1 }
                } else {
                    do {
                        let xExchange = exchange(x)
                        let yExchange = exchange(y)
                        let comparison = try ResponseComparator.compare(
                            xExchange, yExchange, ignoring: options.ignoreJSONPointers)
                        bodyChanged = !comparison.differences.isEmpty
                        bodyDifferenceCount = comparison.differences.count
                        if comparison.limited { limited += 1 }
                        var budget = 200000
                        let ignored = Set(options.ignoreJSONPointers.map { Data($0.utf8) })
                        schemaChanged =
                            try schema(
                                JSONValueParser(x).parse(), ignored: ignored, budget: &budget)
                            != schema(JSONValueParser(y).parse(), ignored: ignored, budget: &budget)
                    } catch ComparisonError.unsupported {
                        // Complete non-JSON: byte comparison; schema is unavailable.
                        bodyChanged = true
                    } catch ComparisonError.limit { limited += 1 }
                }
            } else if !options.metadataOnly {
                missingPayloads += 1
            }
            if !options.metadataOnly, let a, let b, a.headersOmitted == false,
                b.headersOmitted == false,
                let x = a.responseHeaders, let y = b.responseHeaders
            {
                func headers(_ fields: [Field]) -> [Data] {
                    fields.filter { $0.enabled && !ignoredHeaders.contains($0.name.lowercased()) }
                        .map {
                            Data(($0.name.lowercased() + "\u{0}" + $0.value).utf8)
                        }.sorted { $0.lexicographicallyPrecedes($1) }
                }
                headersChanged = headers(x) != headers(y)
            } else if !options.metadataOnly {
                missingHeaders += 1
            }
            let assertionsChanged: Bool?
            if let a, let b {
                if (a.checkCount ?? a.checks.count) != (b.checkCount ?? b.checks.count)
                    || (a.failedCheckCount ?? a.checks.filter { !$0.passed }.count)
                        != (b.failedCheckCount ?? b.checks.filter { !$0.passed }.count)
                {
                    assertionsChanged = true
                } else if a.checksOmitted != true && b.checksOmitted != true {
                    assertionsChanged = a.checks.map(\.passed) != b.checks.map(\.passed)
                } else {
                    assertionsChanged = nil
                }
            } else {
                assertionsChanged = nil
            }
            if assertionsChanged == nil { missingAssertions += 1 }
            let oldDuration = a?.duration ?? 0
            let newDuration = b?.duration ?? 0
            let regression =
                a != nil && b != nil
                && newDuration - oldDuration > options.latencyFloorMilliseconds / 1000
                && newDuration > oldDuration * (1 + options.latencyIncreasePercent / 100)
            changes.append(
                RunChange(
                    requestID: key.id, iteration: key.iteration, visit: key.visit,
                    missingBefore: a == nil, missingAfter: b == nil,
                    stateChanged: a != nil && b != nil && a?.state != b?.state,
                    statusChanged: a != nil && b != nil && a?.status != b?.status,
                    assertionsChanged: assertionsChanged,
                    retriesChanged: a != nil && b != nil && a?.attempt != b?.attempt,
                    latencyRegression: regression, bodyChanged: bodyChanged,
                    schemaChanged: schemaChanged, headersChanged: headersChanged,
                    sourceLocation: (after.sources?[key.id.uuidString]
                        ?? before.sources?[key.id.uuidString]).flatMap {
                            RunSources.valid($0) ? $0 : nil
                        },
                    beforeStatus: a?.status, afterStatus: b?.status,
                    beforeState: a?.state, afterState: b?.state,
                    beforeSeconds: a?.duration, afterSeconds: b?.duration,
                    beforeChecks: a.map { $0.checkCount ?? $0.checks.count },
                    afterChecks: b.map { $0.checkCount ?? $0.checks.count },
                    beforeFailedChecks: a.map {
                        $0.failedCheckCount ?? $0.checks.filter { !$0.passed }.count
                    },
                    afterFailedChecks: b.map {
                        $0.failedCheckCount ?? $0.checks.filter { !$0.passed }.count
                    }, bodyDifferenceCount: bodyDifferenceCount))
        }
        return RunComparisonReport(
            changes: changes, beforePassed: before.passed, afterPassed: after.passed,
            metadataOnly: options.metadataOnly,
            ignoredJSONPointerCount: options.ignoreJSONPointers.count,
            ignoredHeaderCount: ignoredHeaders.count,
            latencyIncreasePercent: options.latencyIncreasePercent,
            latencyFloorMilliseconds: options.latencyFloorMilliseconds,
            missingPayloadComparisons: missingPayloads, limitedBodyComparisons: limited,
            missingHeaderComparisons: missingHeaders, missingAssertionComparisons: missingAssertions
        )
    }
    private static func exchange(_ body: Data) -> Exchange {
        Exchange(
            requestID: UUID(), requestName: "", method: .GET, url: "", status: 200,
            duration: 0, headers: [], body: body, checks: [])
    }
    private static func schema(
        _ value: JSONValue, path: String = "", ignored: Set<Data>, budget: inout Int
    ) throws -> Data {
        budget -= 1
        guard budget >= 0, path.utf8.count <= 8192 else { throw ComparisonError.limit }
        if ignored.contains(Data(path.utf8)) { return Data("ignored".utf8) }
        func child(_ key: String) -> String {
            path + "/"
                + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(
                    of: "/", with: "~1")
        }
        func joined(_ parts: [Data], kind: UInt8) throws -> Data {
            var result = Data([kind])
            for part in parts {
                guard result.count + part.count + 20 <= 8 * 1024 * 1024 else {
                    throw ComparisonError.limit
                }
                result.append(Data((String(part.count) + ":").utf8))
                result.append(part)
            }
            return result
        }
        switch value {
        case .object(let fields):
            var parts: [Data] = []
            for key in fields.keys.sorted(by: { $0.bytes.lexicographicallyPrecedes($1.bytes) }) {
                let next = child(key.text)
                if ignored.contains(Data(next.utf8)) { continue }
                parts.append(key.bytes)
                parts.append(
                    try schema(fields[key]!, path: next, ignored: ignored, budget: &budget))
            }
            return try joined(parts, kind: 111)
        case .array(let values):
            var variants: Set<Data> = []
            for (index, value) in values.enumerated() {
                let next = child(String(index))
                if ignored.contains(Data(next.utf8)) { continue }
                variants.insert(try schema(value, path: next, ignored: ignored, budget: &budget))
                guard variants.count <= 100 else { throw ComparisonError.limit }
            }
            return try joined(variants.sorted { $0.lexicographicallyPrecedes($1) }, kind: 97)
        case .string: return Data([115])
        case .number: return Data([110])
        case .bool: return Data([98])
        case .null: return Data([48])
        }
    }
}
