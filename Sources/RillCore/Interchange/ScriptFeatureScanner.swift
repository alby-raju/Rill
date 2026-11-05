import Foundation

/// Conservative lexical hints. Opaque syntax stops inspection rather than guessing a grammar.
/// No hint changes the enclosing source block's unsupported disposition.
enum ScriptFeatureScanner {
    struct Budget {
        var bytes = 4 * 1024 * 1024
        var tokens = 100_000
        var features = 4000
    }
    struct Result {
        var coverage = ScriptCompatibilityInventory.Coverage.lexical
        var features: [ScriptCompatibilityInventory.Feature] = []
    }
    private struct Identifier {
        let value: String
        let line: Int
        let column: Int
    }
    private static let calls: [String: String] = [
        "pm.test": "assertion.test",
        "pm.expect": "assertion.expect",
        "pm.response.json": "response.json",
        "pm.response.text": "response.text",
        "pm.response.headers.get": "response.header.read",
        "pm.response.to.have.status": "assertion.status",
        "pm.response.to.have.header": "assertion.header",
        "pm.response.to.have.body": "assertion.body",
        "pm.execution.setNextRequest": "workflow.next",
        "pm.execution.skipRequest": "workflow.skip",
        "postman.setNextRequest": "workflow.legacyNext",
        "pm.sendRequest": "runtime.http",
        "pm.vault.get": "runtime.vault",
        "pm.vault.set": "runtime.vault",
        "pm.vault.unset": "runtime.vault",
        "pm.request.headers.add": "request.header.write",
        "pm.request.headers.upsert": "request.header.write",
        "pm.request.headers.remove": "request.header.remove",
        "require": "runtime.module",
        "eval": "runtime.dynamicCode",
        "Function": "runtime.dynamicCode",
        "console.log": "runtime.log",
    ]
    private static func callCode(_ chain: String) -> String? {
        if let known = calls[chain] { return known }
        for (scope, code) in [
            ("variables", "local"), ("environment", "environment"),
            ("collectionVariables", "collection"), ("globals", "globals"),
            ("iterationData", "iterationData"),
        ] {
            for (operation, action) in [
                ("get", "read"), ("set", "write"), ("unset", "unset"),
                ("clear", "clear"), ("has", "has"), ("replaceIn", "template"),
                ("toObject", "snapshot"),
            ] where chain == "pm.\(scope).\(operation)" {
                return "variable.\(code).\(action)"
            }
        }
        return nil
    }

    static func scan(_ text: String, budget: inout Budget) throws -> Result {
        let bytes = Array(text.utf8)
        var index = 0
        var line = 1
        var column = 1
        var result = Result()
        var chain: [Identifier] = []
        var dot = false
        func advance() {
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
        func emit(_ code: String, at identifier: Identifier) -> Bool {
            guard budget.features > 0 else {
                result.coverage = .limited
                return false
            }
            budget.features -= 1
            result.features.append(
                .init(code: code, line: identifier.line, byteColumn: identifier.column))
            return true
        }
        func nameByte(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || byte == 95 || byte == 36 || byte >= 128
        }
        while index < bytes.count {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            let byte = bytes[index]
            if [9, 10, 13, 32].contains(byte) {
                advance()
                continue
            }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13 {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    advance()
                }
                continue
            }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 42 {
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
                if !closed {
                    result.coverage = .partial
                    break
                }
                continue
            }
            let point = Identifier(value: "", line: line, column: column)
            guard budget.tokens > 0 else {
                result.coverage = .limited
                _ = emit("analysis.limit", at: point)
                break
            }
            budget.tokens -= 1
            if byte == 96 || byte == 47 || byte == 92 {
                // Template interpolation, regexp/division ambiguity and escaped identifiers
                // need a real parser. Preserve a location and leave the source blocked.
                result.coverage = .partial
                _ = emit("syntax.opaque", at: point)
                break
            }
            if byte == 34 || byte == 39 {
                advance()
                var closed = false
                while index < bytes.count {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    if bytes[index] == byte {
                        advance()
                        closed = true
                        break
                    }
                    if bytes[index] == 10 || bytes[index] == 13 { break }
                    if bytes[index] == 92 {
                        advance()
                        if index < bytes.count { advance() }
                    } else {
                        advance()
                    }
                }
                chain = []
                dot = false
                if !closed {
                    result.coverage = .partial
                    break
                }
                continue
            }
            if nameByte(byte), !(48...57).contains(byte) {
                let start = index
                while index < bytes.count, nameByte(bytes[index]) {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    advance()
                }
                guard index - start <= 128 else {
                    chain = []
                    dot = false
                    continue
                }
                let identifier = Identifier(
                    value: String(decoding: bytes[start..<index], as: UTF8.self),
                    line: point.line, column: point.column)
                if dot, !chain.isEmpty, chain.count < 8 {
                    chain.append(identifier)
                } else {
                    chain = [identifier]
                }
                dot = false
                if ["for", "while", "do"].contains(identifier.value) {
                    guard emit("syntax.loop", at: identifier) else { break }
                } else if ["await", "async"].contains(identifier.value) {
                    guard emit("syntax.async", at: identifier) else { break }
                }
                continue
            }
            if byte == 46, !chain.isEmpty, !dot {
                dot = true
            } else {
                if byte == 40, let first = chain.first, !dot,
                    let code = callCode(chain.map(\.value).joined(separator: "."))
                {
                    guard emit(code, at: first) else { break }
                }
                chain = []
                dot = false
            }
            advance()
        }
        return result
    }
}
