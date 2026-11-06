import Foundation
import RillCore

extension RillCLI {
    static func reportDiff(_ args: Arguments) throws {
        guard args.operands.count == 2,
            Set(args.values.keys).isSubset(of: [
                "ignore-json", "ignore-header", "latency-percent", "latency-floor",
            ]),
            args.flags.isSubset(of: ["json", "quiet", "metadata-only", "strict-headers"])
        else {
            throw CLIError.usage(
                "Use report-diff BEFORE AFTER [--metadata-only] [--ignore-json POINTER] [--ignore-header NAME] [--strict-headers] [--latency-percent N] [--latency-floor MS] [--json|--quiet]."
            )
        }
        var options = RunComparisonOptions()
        options.metadataOnly = args.flags.contains("metadata-only")
        options.ignoreJSONPointers = args.values["ignore-json"] ?? []
        if args.flags.contains("strict-headers") { options.ignoreHeaders = [] }
        options.ignoreHeaders += args.values["ignore-header"] ?? []
        if let text = args.value("latency-percent") {
            guard let value = Double(text) else {
                throw CLIError.usage("Invalid latency percentage.")
            }
            options.latencyIncreasePercent = value
        }
        if let text = args.value("latency-floor") {
            guard let value = Double(text) else { throw CLIError.usage("Invalid latency floor.") }
            options.latencyFloorMilliseconds = value
        }
        let comparison: RunComparisonReport
        do {
            try options.validate()
            let before = try RunSnapshotFile.decode(
                BoundedFileInput.read(
                    URL(fileURLWithPath: args.operands[0]), limit: ResourceLimits.workspaceBytes))
            let after = try RunSnapshotFile.decode(
                BoundedFileInput.read(
                    URL(fileURLWithPath: args.operands[1]), limit: ResourceLimits.workspaceBytes))
            comparison = try RunComparator.compare(before, after, options: options)
        } catch is CancellationError { throw CancellationError() } catch {
            throw CLIError.usage(
                "Invalid, oversized or incompatible versioned reports/snapshots or comparison rules. Runtime content and paths omitted."
            )
        }
        if args.flags.contains("json") {
            try args.json(comparison)
        } else {
            try args.text(
                "Rill comparison · \(comparison.changed ? "changes detected" : "no observed changes") · \(comparison.complete ? "complete" : "incomplete")"
            )
            try args.text(
                "\(comparison.changes.filter(\.changed).count) changed request visits · \(comparison.missingPayloadComparisons) unavailable payloads · \(comparison.missingHeaderComparisons) unavailable headers · \(comparison.missingAssertionComparisons) unavailable check sets · \(comparison.limitedBodyComparisons) bounded comparisons"
            )
            for change in comparison.changes.filter(\.changed).prefix(100) {
                try args.text(
                    "\(change.requestID) iteration=\(change.iteration) visit=\(change.visit) status=\(change.statusChanged) checks=\(change.assertionsChanged.map(String.init) ?? "unknown") body=\(change.bodyChanged.map(String.init) ?? "unknown") schema=\(change.schemaChanged.map(String.init) ?? "unknown") latency=\(change.latencyRegression)"
                )
            }
        }
        if comparison.changed { throw CLIError.assertion }
        if !comparison.complete {
            throw CLIError.usage(
                "Comparison is incomplete. Supply raw snapshots or explicitly select --metadata-only; missing data is not evidence of equality."
            )
        }
    }
    static func annotations(_ report: RunReport) throws {
        let attempts = report.outcomes.filter { $0.state != .notRun }
        var lines: [String] = []
        for (index, attempt) in attempts.enumerated()
        where attempt.state == .failed || attempt.state == .cancelled {
            if index + 1 < attempts.count {
                let next = attempts[index + 1]
                if next.requestID == attempt.requestID && next.iteration == attempt.iteration
                    && next.attempt == attempt.attempt + 1
                {
                    continue
                }
            }
            guard lines.count < 100 else { break }
            lines.append(
                "::error title=Rill request \(attempt.requestID)::iteration=\(attempt.iteration) attempt=\(attempt.attempt) kind=\(attempt.failureKind?.rawValue ?? "unsuccessful") status=\(attempt.status.map(String.init) ?? "none")"
            )
        }
        if !report.passed && lines.isEmpty {
            lines.append(
                "::error title=Rill run::Unsuccessful run; empty, stopped, cancelled or exhausted execution cannot pass."
            )
        }
        if !lines.isEmpty {
            try FileHandle.standardError.write(
                contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        }
    }
}
