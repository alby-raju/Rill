import Foundation

public enum DynamicTemplates {
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
