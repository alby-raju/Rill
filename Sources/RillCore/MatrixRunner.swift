import Foundation

public struct MatrixRun: Sendable {
    public let environmentID: UUID
    public let report: RunReport
}
public struct MatrixComparison: Sendable {
    public let requestID: UUID
    public let statesDiffer: Bool
    public let checksDiffer: Bool
    public let bodiesDiffer: Bool
    public let includesNotRun: Bool
}
public struct MatrixReport: Sendable {
    public let runs: [MatrixRun]
    public let comparisons: [MatrixComparison]
    public var passed: Bool { !runs.isEmpty && runs.allSatisfy { $0.report.passed } }
}
public enum MatrixRunner {
    public static func run(requests: [RequestDraft], environments: [Environment], concurrency: Int, configuration: RunConfiguration,
                           profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil, tlsProfiles: [TLSProfile] = []) async throws -> MatrixReport {
        guard (1...16).contains(environments.count), (1...4).contains(concurrency), Set(environments.map(\.id)).count == environments.count else { throw WorkflowError.invalidConfiguration }
        try configuration.validate()
        var shared = configuration; shared.retentionBytes = min(configuration.retentionBytes, 32 * 1024 * 1024 / environments.count)
        let settings = shared
        let runs = try await withThrowingTaskGroup(of: (Int, MatrixRun).self) { group in
            func submit(_ index: Int) {
                let environment = environments[index]
                group.addTask {
                    let report = try await CollectionRunner.run(requests: requests, environment: environment, configuration: settings, profiles: profiles, secrets: secrets, tlsProfiles: tlsProfiles)
                    return (index, MatrixRun(environmentID: environment.id, report: report))
                }
            }
            var next = 0, results: [(Int, MatrixRun)] = []
            while next < min(concurrency, environments.count) { submit(next); next += 1 }
            while let result = try await group.next() {
                results.append(result)
                if next < environments.count { submit(next); next += 1 }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let comparisons = requests.map { request in
            let outcomes = runs.map { $0.report.outcomes.last { $0.requestID == request.id && $0.state != .notRun } }
            let states = outcomes.map { "\($0?.state.rawValue ?? "notRun")/\($0?.status ?? 0)" }
            let checks = outcomes.map { $0?.checks.map(\.passed) ?? [] }
            let fingerprints = outcomes.map { $0?.fingerprint }
            return MatrixComparison(requestID: request.id, statesDiffer: Set(states).count > 1,
                                    checksDiffer: checks.dropFirst().contains { $0 != checks.first },
                                    bodiesDiffer: fingerprints.dropFirst().contains { $0 != fingerprints.first }, includesNotRun: outcomes.contains { $0 == nil })
        }
        return MatrixReport(runs: runs, comparisons: comparisons)
    }
}
