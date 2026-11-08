import Foundation

struct OfflineRunPlan: Encodable {
    struct Step: Encodable {
        let position: Int
        let source: String
        let method: String
        let runtimeValidationDeferred: Bool
    }

    let schemaVersion = 1
    let kind = "rill.offline-run-plan"
    let passed = true
    let sendsRequests = false
    let inputFormat: String
    let selection: String
    let environmentSource: String
    let iterations: Int
    let baseSteps: Int
    let retries: Int
    let dynamicOrder: Bool
    let tlsInputsDeferred: Bool
    let steps: [Step]

    func terminal(detail: Bool) -> String {
        var lines = [
            "Rill offline run plan · \(inputFormat) · \(selection)",
            "\(steps.count) requests · \(iterations) iterations · \(baseSteps) base steps · \(retries) retries allowed per visit",
            "Environment source · \(environmentSource)",
            "No requests sent or run outputs written.",
        ]
        if tlsInputsDeferred {
            lines.append("TLS file contents and credentials are checked during execution.")
        }
        if dynamicOrder {
            lines.append("Scripts or hooks can change the execution order.")
        }
        let deferred = steps.filter(\.runtimeValidationDeferred).count
        if deferred > 0 {
            lines.append("\(deferred) requests have validation deferred until execution.")
        }
        if detail {
            for step in steps {
                lines.append(
                    "\(step.position)  \(step.method)  \(step.source)"
                        + (step.runtimeValidationDeferred ? "  deferred" : ""))
            }
        }
        return lines.joined(separator: "\n")
    }
}
