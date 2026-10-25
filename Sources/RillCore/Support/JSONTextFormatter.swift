import Foundation

/// Validates JSON, but formats the original lexical tokens rather than a decoded
/// dictionary. Duplicate keys, number spellings and string escapes survive.
public enum JSONTextFormatter {
    public static func pretty(_ text: String) throws -> String {
        let data = Data(text.utf8)
        guard data.count <= 8 * 1024 * 1024 else { throw WorkspaceError.tooLarge }
        try WorkspaceFile.checkJSONBounds(data)
        _ = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        let input = Array(data), whitespace: Set<UInt8> = [9, 10, 13, 32]
        var output = Data(), depth = 0, index = 0, previous: UInt8?
        func append(_ bytes: [UInt8]) throws {
            guard output.count + bytes.count <= ResourceLimits.workspaceBytes else { throw WorkspaceError.tooLarge }
            output.append(contentsOf: bytes)
        }
        func newline() throws { try append([10] + Array(repeating: 32, count: depth * 2)) }
        func nextToken(_ start: Int) -> UInt8? {
            var next = start
            while next < input.count && whitespace.contains(input[next]) { next += 1 }
            return next < input.count ? input[next] : nil
        }
        while index < input.count {
            let byte = input[index]
            if whitespace.contains(byte) { index += 1; continue }
            if byte == 34 {
                let start = index; index += 1
                var escaped = false
                while index < input.count {
                    let current = input[index]; index += 1
                    if escaped { escaped = false }
                    else if current == 92 { escaped = true }
                    else if current == 34 { break }
                }
                try append(Array(input[start..<index])); previous = 34; continue
            }
            switch byte {
            case 123, 91:
                try append([byte]); depth += 1
                if nextToken(index + 1) != (byte == 123 ? 125 : 93) { try newline() }
            case 125, 93:
                depth -= 1
                if previous != (byte == 125 ? 123 : 91) { try newline() }
                try append([byte])
            case 44: try append([byte]); try newline()
            case 58: try append([58, 32])
            default: try append([byte])
            }
            previous = byte; index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }
}

public enum InputSuggestions {
    public static func keys(prefix: String, headers: Bool, workspace: Workspace) -> [String] {
        let standard = headers ? ["Accept", "Authorization", "Content-Type", "User-Agent", "X-Request-ID", "Cache-Control", "If-Match", "If-None-Match"] : []
        let learned = workspace.requests.flatMap { (headers ? $0.headers : $0.parameters).map(\.name) }
        return Array(Set(standard + learned)).filter { !$0.isEmpty && (prefix.isEmpty || $0.localizedCaseInsensitiveHasPrefix(prefix)) }.sorted()
    }
    public static func variables(in environment: Environment?) -> [String] {
        environment?.variables.filter(\.enabled).map { "{{\($0.name)}}" }.sorted() ?? []
    }
}
private extension String {
    func localizedCaseInsensitiveHasPrefix(_ other: String) -> Bool { lowercased().hasPrefix(other.lowercased()) }
}
