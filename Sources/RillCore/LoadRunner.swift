import Foundation

public struct LoadConfiguration: Sendable {
    public var count = 10
    public var concurrency = 1
    public var rampMilliseconds = 0
    public init() {}
    public func validate() throws {
        guard (1...10_000).contains(count), (1...64).contains(concurrency), (0...60_000).contains(rampMilliseconds) else { throw WorkflowError.invalidConfiguration }
    }
}
public struct LatencySample: Codable, Sendable {
    public let index: Int
    public let state: RunState
    public let duration: Double
    public let status: Int?
}
public struct LoadReport: Codable, Sendable {
    public let samples: [LatencySample]
    public let duration: Double
    public var successes: Int { samples.filter { $0.state == .passed }.count }
    public var failures: Int { samples.filter { $0.state == .failed }.count }
    public var cancelled: Bool { samples.contains { $0.state == .cancelled || $0.state == .notRun } }
    public var passed: Bool { !samples.isEmpty && !cancelled && failures == 0 }
    public var throughput: Double { duration > 0 ? Double(samples.filter { $0.state == .passed || $0.state == .failed }.count) / duration : 0 }
    public var minimum: Double? { samples.filter { $0.state == .passed || $0.state == .failed }.map(\.duration).min() }
    public var maximum: Double? { samples.filter { $0.state == .passed || $0.state == .failed }.map(\.duration).max() }
    /// Nearest rank: sorted[ceil(p*n)-1], clamped at zero for p=0.
    public func percentile(_ probability: Double) -> Double? {
        guard probability.isFinite, (0...1).contains(probability) else { return nil }
        let sorted = samples.filter { $0.state == .passed || $0.state == .failed }.map(\.duration).sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[max(0, Int(ceil(probability * Double(sorted.count))) - 1)]
    }
}
public enum LoadRunner {
    public static func run(request: RequestDraft, environment: Environment?, configuration: LoadConfiguration,
                           profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil, tlsProfiles: [TLSProfile] = [],
                           executor: CollectionRunner.Executor? = nil) async throws -> LoadReport {
        try configuration.validate()
        let started = ProcessInfo.processInfo.systemUptime
        let values = WorkflowEngine.variables(in: environment)
        let budget = try ResponseBudget(downloadBytes: min(ResourceLimits.responseBytes, 32 * 1024 * 1024 / configuration.concurrency))
        let execute: CollectionRunner.Executor = executor ?? { draft, variables in
            try await WorkflowEngine.execute(draft, variables: variables, budget: budget, profiles: profiles, secrets: secrets, tlsProfiles: tlsProfiles)
        }
        return await withTaskGroup(of: LatencySample.self) { group in
            func submit(_ index: Int) {
                group.addTask {
                    var before: Double?
                    do {
                        let offset = configuration.count > 1 ? Double(configuration.rampMilliseconds) / 1000 * Double(index) / Double(configuration.count - 1) : 0
                        let remaining = offset - (ProcessInfo.processInfo.systemUptime - started)
                        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                        try Task.checkCancellation()
                        before = ProcessInfo.processInfo.systemUptime
                        let result = try await execute(request, values)
                        try Task.checkCancellation()
                        return LatencySample(index: index, state: result.passed ? .passed : .failed, duration: ProcessInfo.processInfo.systemUptime - before!, status: result.exchange.status)
                    } catch is CancellationError { return LatencySample(index: index, state: .cancelled, duration: 0, status: nil) }
                    catch let error as URLError where error.code == .cancelled { return LatencySample(index: index, state: .cancelled, duration: 0, status: nil) }
                    catch { return LatencySample(index: index, state: .failed, duration: before.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0, status: nil) }
                }
            }
            var next = 0, samples: [LatencySample] = []
            while next < min(configuration.count, configuration.concurrency) { submit(next); next += 1 }
            while let sample = await group.next() {
                samples.append(sample)
                if !Task.isCancelled && next < configuration.count { submit(next); next += 1 }
            }
            for index in next..<configuration.count { samples.append(LatencySample(index: index, state: .notRun, duration: 0, status: nil)) }
            return LoadReport(samples: samples.sorted { $0.index < $1.index }, duration: ProcessInfo.processInfo.systemUptime - started)
        }
    }
}
