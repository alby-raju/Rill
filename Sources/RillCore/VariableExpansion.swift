import Foundation

public enum VariableExpansion {
    public static func resolve(_ text: String, values: [String: String]) throws -> String {
        let regex = try NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)
        var cache: [String: String] = [:], visiting = Set<String>(), cachedBytes = 0, substitutions = 0
        func expand(_ input: String, depth: Int) throws -> String {
            guard depth <= 32 else { throw EditingError.expansionLimit }
            var result = "", bytes = 0, previous = input.startIndex
            func append(_ fragment: String) throws {
                bytes += fragment.utf8.count
                guard bytes <= ResourceLimits.workspaceBytes else { throw EditingError.expansionLimit }
                result += fragment
            }
            for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
                substitutions += 1
                guard substitutions <= 10000, let range = Range(match.range, in: input), let keyRange = Range(match.range(at: 1), in: input) else { throw EditingError.expansionLimit }
                try append(String(input[previous..<range.lowerBound]))
                let key = String(input[keyRange]).trimmingCharacters(in: .whitespaces)
                let value: String
                if let cached = cache[key] { value = cached }
                else {
                    guard visiting.insert(key).inserted else { throw EditingError.variableCycle(key) }
                    guard let raw = values[key] else { throw RillError.missingVariable(key) }
                    value = try expand(raw, depth: depth + 1)
                    visiting.remove(key)
                    cachedBytes += value.utf8.count
                    guard value.utf8.count <= 1024 * 1024, cachedBytes <= ResourceLimits.workspaceBytes else { throw EditingError.expansionLimit }
                    cache[key] = value
                }
                try append(value); previous = range.upperBound
            }
            try append(String(input[previous...]))
            return result
        }
        return try expand(text, depth: 0)
    }
}
