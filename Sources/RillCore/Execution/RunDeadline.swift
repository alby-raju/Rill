import Foundation

enum RunDeadlineError: Error { case exceeded }
enum RunDeadline {
    static func perform<T: Sendable>(
        until deadline: ContinuousClock.Instant?,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard let deadline else { return try await operation() }
        guard ContinuousClock.now < deadline else { throw RunDeadlineError.exceeded }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                let value = try await operation()
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw RunDeadlineError.exceeded }
                return value
            }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                throw RunDeadlineError.exceeded
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
