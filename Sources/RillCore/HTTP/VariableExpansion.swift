import Foundation

public enum VariableExpansion {
    public static func resolve(
        _ text: String, values: [String: String], secretLookup: ((String) throws -> String)? = nil
    ) throws -> String {
        let regex = try NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
        var cache: [String: String] = [:]
        var visiting = Set<String>()
        var cachedBytes = 0
        var substitutions = 0
        func expand(_ input: String, depth: Int) throws -> String {
            try Task.checkCancellation()
            guard depth <= 32 else { throw EditingError.expansionLimit }
            var result = ""
            var bytes = 0
            var previous = input.startIndex
            func append(_ fragment: String) throws {
                bytes += fragment.utf8.count
                guard bytes <= ResourceLimits.workspaceBytes else {
                    throw EditingError.expansionLimit
                }
                result += fragment
            }
            var failure: Error?
            regex.enumerateMatches(in: input, range: NSRange(input.startIndex..., in: input)) {
                match, _, stop in
                do {
                    try Task.checkCancellation()
                    guard let match else { return }
                    substitutions += 1
                    guard substitutions <= 10000, let range = Range(match.range, in: input),
                        let keyRange = Range(match.range(at: 1), in: input)
                    else { throw EditingError.expansionLimit }
                    try append(String(input[previous..<range.lowerBound]))
                    let key = String(input[keyRange]).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    let value: String
                    if key.hasPrefix("$") {
                        value = try DynamicTemplates.generate(key)
                    } else if let cached = cache[key] {
                        value = cached
                    } else {
                        guard visiting.insert(key).inserted else {
                            throw EditingError.variableCycle(key)
                        }
                        if key.hasPrefix("secret:") {
                            guard let secretLookup else { throw AuthenticationError.missingSecret }
                            // Secrets are opaque bytes represented as UTF-8 text, never templates.
                            value = try secretLookup(String(key.dropFirst(7)))
                        } else {
                            guard let raw = values[key] else {
                                throw RillError.missingVariable(key)
                            }
                            value = try expand(raw, depth: depth + 1)
                        }
                        visiting.remove(key)
                        cachedBytes += value.utf8.count
                        guard value.utf8.count <= 1024 * 1024,
                            cachedBytes <= ResourceLimits.workspaceBytes
                        else { throw EditingError.expansionLimit }
                        if key.hasPrefix("secret:") { cache[key] = value }
                    }
                    try append(value)
                    previous = range.upperBound
                } catch {
                    failure = error
                    stop.pointee = true
                }
            }
            if let failure { throw failure }
            try append(String(input[previous...]))
            return result
        }
        return try expand(text, depth: 0)
    }
}
