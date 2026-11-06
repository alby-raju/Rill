import Foundation

enum ScriptVariableScope: String, Sendable { case local, environment, collection, globals, data }
indirect enum ScriptExpression: Sendable {
    case literal(String), get(ScriptVariableScope, String), json([String]), header(String)
}
indirect enum ScriptOperation: Sendable {
    case set(ScriptVariableScope, String, ScriptExpression), unset(ScriptVariableScope, String)
    case testStatus([Int]), next(String?), skip
    case condition(ScriptExpression, String?, Bool, [ScriptOperation], [ScriptOperation])
}
struct ScriptSyntaxFailure: Error, Sendable {
    let code: String
    let line: Int
    let byteColumn: Int
}

/// A finite language lexer. This is not an embedded JavaScript runtime.
struct ScriptLexer {
    enum Kind: Equatable {
        case identifier(String), string(String), integer(Int), symbol(UInt8), arrow, equal, unequal,
            end
    }
    struct Token {
        let kind: Kind
        let line: Int
        let column: Int
    }
    private let bytes: [UInt8]
    private var index = 0
    private var line = 1
    private var column = 1
    private var tokens = 0
    init(_ source: String) throws {
        guard source.utf8.count <= 1024 * 1024 else {
            throw ScriptSyntaxFailure(code: "script.limit", line: 1, byteColumn: 1)
        }
        bytes = Array(source.utf8)
    }
    private func fail(_ code: String = "script.unsupportedSyntax") -> ScriptSyntaxFailure {
        .init(code: code, line: line, byteColumn: column)
    }
    private mutating func advance() {
        if bytes[index] == 13 {
            line += 1
            column = 1
        } else if bytes[index] == 10 {
            if index == 0 || bytes[index - 1] != 13 { line += 1 }
            column = 1
        } else {
            column += 1
        }
        index += 1
    }
    private mutating func trivia() throws {
        while index < bytes.count {
            try Task.checkCancellation()
            if [9, 10, 13, 32].contains(bytes[index]) {
                advance()
                continue
            }
            guard bytes[index] == 47, index + 1 < bytes.count else { return }
            if bytes[index + 1] == 47 {
                while index < bytes.count, ![10, 13].contains(bytes[index]) {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    advance()
                }
            } else if bytes[index + 1] == 42 {
                advance()
                advance()
                var closed = false
                while index < bytes.count {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    if bytes[index] == 42, index + 1 < bytes.count, bytes[index + 1] == 47 {
                        advance()
                        advance()
                        closed = true
                        break
                    }
                    advance()
                }
                guard closed else { throw fail("script.unterminatedComment") }
            } else {
                return
            }
        }
    }
    private mutating func hex() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count else { throw fail() }
            let byte = bytes[index]
            let value: UInt32
            switch byte {
            case 48...57: value = UInt32(byte - 48)
            case 65...70: value = UInt32(byte - 55)
            case 97...102: value = UInt32(byte - 87)
            default: throw fail()
            }
            result = result * 16 + value
            advance()
        }
        return result
    }
    private mutating func string() throws -> String {
        let quote = bytes[index]
        advance()
        var result: [UInt8] = []
        while index < bytes.count {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            let byte = bytes[index]
            if byte == quote {
                advance()
                return String(decoding: result, as: UTF8.self)
            }
            guard byte >= 32, byte != 127 else { throw fail("script.invalidString") }
            if byte != 92 {
                result.append(byte)
                advance()
                continue
            }
            advance()
            guard index < bytes.count else { throw fail("script.invalidString") }
            let escape = bytes[index]
            advance()
            switch escape {
            case 34, 39, 92: result.append(escape)
            case 110: result.append(10)
            case 114: result.append(13)
            case 116: result.append(9)
            case 98: result.append(8)
            case 102: result.append(12)
            case 117:
                var scalar = try hex()
                if (0xD800...0xDBFF).contains(scalar) {
                    guard index + 1 < bytes.count, bytes[index] == 92, bytes[index + 1] == 117
                    else { throw fail("script.invalidString") }
                    advance()
                    advance()
                    let low = try hex()
                    guard (0xDC00...0xDFFF).contains(low) else {
                        throw fail("script.invalidString")
                    }
                    scalar = 0x10000 + (scalar - 0xD800) * 1024 + low - 0xDC00
                }
                guard let value = Unicode.Scalar(scalar), !(0xD800...0xDFFF).contains(scalar) else {
                    throw fail("script.invalidString")
                }
                result += String(value).utf8
            default: throw fail("script.unsupportedEscape")
            }
        }
        throw fail("script.unterminatedString")
    }
    mutating func next() throws -> Token {
        try trivia()
        tokens += 1
        guard tokens <= 100_000 else { throw fail("script.limit") }
        let startLine = line
        let startColumn = column
        guard index < bytes.count else { return Token(kind: .end, line: line, column: column) }
        let byte = bytes[index]
        let kind: Kind
        if byte == 34 || byte == 39 {
            kind = .string(try string())
        } else if (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte == 36
        {
            let start = index
            while index < bytes.count {
                let c = bytes[index]
                guard
                    (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c)
                        || c == 95 || c == 36
                else { break }
                advance()
            }
            guard index - start <= 128 else { throw fail("script.limit") }
            kind = .identifier(String(decoding: bytes[start..<index], as: UTF8.self))
        } else if (48...57).contains(byte) {
            let start = index
            while index < bytes.count, (48...57).contains(bytes[index]) { advance() }
            guard index - start <= 9, (index - start == 1 || byte != 48),
                let number = Int(String(decoding: bytes[start..<index], as: UTF8.self))
            else { throw fail() }
            kind = .integer(number)
        } else if byte == 61, index + 1 < bytes.count, bytes[index + 1] == 62 {
            advance()
            advance()
            kind = .arrow
        } else if (byte == 61 || byte == 33), index + 2 < bytes.count,
            bytes[index + 1] == 61, bytes[index + 2] == 61
        {
            advance()
            advance()
            advance()
            kind = byte == 61 ? .equal : .unequal
        } else {
            guard [40, 41, 123, 125, 91, 93, 46, 44, 59, 33].contains(byte) else { throw fail() }
            advance()
            kind = .symbol(byte)
        }
        return Token(kind: kind, line: startLine, column: startColumn)
    }
}
