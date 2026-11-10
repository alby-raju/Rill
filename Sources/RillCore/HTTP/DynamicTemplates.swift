import Foundation

public enum DynamicTemplates {
    @TaskLocal private static var seeded: SeededTemplates?
    /// SplitMix64-v1. Scoped to this task tree; never changes the process RNG or ambient clock.
    public static func withSeed<T: Sendable>(
        _ seed: UInt64, epochSeconds: Int64 = 0,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await $seeded.withValue(SeededTemplates(seed: seed, epoch: epochSeconds)) {
            try await operation()
        }
    }

    /// Validate syntax without generating values or consulting external providers.
    public static func supports(_ key: String) -> Bool {
        let parts = key.split(whereSeparator: \.isWhitespace)
        switch parts.first {
        case "$uuid", "$timestamp", "$email": return parts.count == 1
        case "$randomInt":
            guard parts.count == 3, let lower = Int(parts[1]), let upper = Int(parts[2]) else {
                return false
            }
            return lower <= upper
        default: return false
        }
    }

    public static func generate(_ key: String) throws -> String {
        guard supports(key) else { throw WorkflowError.invalidConfiguration }
        let parts = key.split(whereSeparator: \.isWhitespace).map(String.init)
        if let seeded { return seeded.generate(parts) }
        switch parts.first {
        case "$uuid" where parts.count == 1: return UUID().uuidString.lowercased()
        case "$timestamp" where parts.count == 1: return String(Int64(Date().timeIntervalSince1970))
        case "$email" where parts.count == 1:
            return "rill-" + UUID().uuidString.lowercased() + "@example.test"
        case "$randomInt" where parts.count == 3:
            guard let lower = Int(parts[1]), let upper = Int(parts[2]), lower <= upper else {
                throw WorkflowError.invalidConfiguration
            }
            return String(Int.random(in: lower...upper))
        default: throw WorkflowError.invalidConfiguration
        }
    }
}

/// Lock scope contains only arithmetic/formatting; no callbacks, suspension, I/O or shared globals.
final class SeededTemplates: @unchecked Sendable {
    private let lock = NSLock()
    private var state: UInt64
    private let epoch: Int64
    init(seed: UInt64, epoch: Int64) {
        state = seed
        self.epoch = epoch
    }
    private func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
    private func uuid() -> String {
        let a = next()
        let b = next()
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: a >> (56 - $0 * 8)) }
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: b >> (56 - $0 * 8)) }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.enumerated().map { index, byte in
            ([4, 6, 8, 10].contains(index) ? "-" : "") + String(format: "%02x", byte)
        }.joined()
    }
    func integer(in range: ClosedRange<Int>) -> Int {
        lock.withLock { drawInteger(in: range) }
    }
    private func drawInteger(in range: ClosedRange<Int>) -> Int {
        // Map signed order to unsigned order.
        let lower = UInt64(bitPattern: Int64(range.lowerBound)) ^ (1 << 63)
        let upper = UInt64(bitPattern: Int64(range.upperBound)) ^ (1 << 63)
        let span = upper &- lower
        let offset: UInt64
        if span == UInt64.max {
            offset = next()
        } else {
            let bound = span + 1
            let threshold = (0 &- bound) % bound
            var value = next()
            while value < threshold { value = next() }
            offset = value % bound
        }
        return Int(Int64(bitPattern: (lower &+ offset) ^ (1 << 63)))
    }
    func generate(_ parts: [String]) -> String {
        lock.lock()
        defer { lock.unlock() }
        switch parts[0] {
        case "$timestamp": return String(epoch)
        case "$uuid": return uuid()
        case "$email": return "rill-" + uuid() + "@example.test"
        default:
            // Syntax and range were validated by supports().
            return String(drawInteger(in: Int(parts[1])!...Int(parts[2])!))
        }
    }
}
