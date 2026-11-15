import Foundation

public enum JSONRequestFields {
    private enum Segment {
        case key(JSONKey)
        case index(Int?)
    }

    public static func body(_ fields: [String]) throws -> String {
        var body = JSONValue.object([:])
        for field in fields {
            try Task.checkCancellation()
            guard let equals = field.firstIndex(of: "=") else {
                throw WorkflowError.invalidConfiguration
            }
            let key = field[..<equals]
            let typed = key.last == ":"
            let path = try pathSegments(typed ? key.dropLast() : key)
            let input = Data(field[field.index(after: equals)...].utf8)
            let value =
                try typed
                ? JSONValueParser(input, preserveNumberSpelling: true).parse() : .string(input)
            body = try insert(value, at: path[...], into: body)
        }
        let encoded = try ResponseJSON.encoded(body)
        // Keep literal braces in JSON strings out of the request template engine.
        var literal = Data()
        var inString = false
        var escaped = false
        for byte in encoded.utf8 {
            if inString && (byte == 123 || byte == 125) {
                literal.append(contentsOf: (byte == 123 ? "\\u007b" : "\\u007d").utf8)
            } else {
                literal.append(byte)
            }
            if escaped {
                escaped = false
            } else if byte == 34 {
                inString.toggle()
            } else if inString && byte == 92 {
                escaped = true
            }
        }
        guard literal.count <= 1024 * 1024 else { throw WorkflowError.limit }
        return String(decoding: literal, as: UTF8.self)
    }

    private static func pathSegments(_ path: Substring) throws -> [Segment] {
        let root = path.prefix(while: { $0 != "[" })
        guard !root.isEmpty, !root.contains("]") else { throw WorkflowError.invalidConfiguration }
        var result: [Segment] = [.key(JSONKey(String(root)))]
        var remaining = path.dropFirst(root.count)
        while !remaining.isEmpty {
            guard result.count < 32, remaining.first == "[",
                let end = remaining.firstIndex(of: "]")
            else { throw WorkflowError.invalidConfiguration }
            let name = remaining[remaining.index(after: remaining.startIndex)..<end]
            guard !name.contains("[") else { throw WorkflowError.invalidConfiguration }
            if name.isEmpty {
                result.append(.index(nil))
            } else if name.utf8.allSatisfy({ (48...57).contains($0) }) {
                guard let index = Int(name), index < 512 else { throw WorkflowError.limit }
                result.append(.index(index))
            } else {
                result.append(.key(JSONKey(String(name))))
            }
            remaining = remaining[remaining.index(after: end)...]
        }
        return result
    }

    private static func insert(
        _ value: JSONValue, at path: ArraySlice<Segment>, into current: JSONValue?
    ) throws -> JSONValue {
        guard let segment = path.first else {
            guard current == nil else { throw WorkflowError.invalidConfiguration }
            return value
        }
        switch (segment, current) {
        case (.key(let key), .object(var fields)):
            fields[key] = try insert(value, at: path.dropFirst(), into: fields[key])
            return .object(fields)
        case (.key(let key), nil):
            return .object([key: try insert(value, at: path.dropFirst(), into: nil)])
        case (.index(let requested), .array(var values)):
            let index = requested ?? values.count
            guard index < 512, index <= values.count else {
                throw WorkflowError.invalidConfiguration
            }
            if index == values.count {
                values.append(try insert(value, at: path.dropFirst(), into: nil))
            } else {
                values[index] = try insert(value, at: path.dropFirst(), into: values[index])
            }
            return .array(values)
        case (.index(let requested), nil) where requested == nil || requested == 0:
            return .array([try insert(value, at: path.dropFirst(), into: nil)])
        default:
            throw WorkflowError.invalidConfiguration
        }
    }
}
