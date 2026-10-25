import Foundation

public enum DynamicTemplates {
    public static func generate(_ key: String) throws -> String {
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
