import Foundation

struct ScriptProgram: Sendable {
    let operations: [ScriptOperation]
    let writes: Set<String>
    let branches: [String]
    var changesOrder: Bool { operations.contains(where: \.changesOrder) }
    var operationCount: Int { operations.reduce(0) { $0 + $1.nodeCount } }
    var estimatedCost: Int { operations.reduce(0) { $0 + $1.estimatedCost } }
}

private extension ScriptOperation {
    var changesOrder: Bool {
        switch self {
        case .next, .skip: return true
        case .condition(_, _, _, let yes, let no):
            return yes.contains(where: \.changesOrder) || no.contains(where: \.changesOrder)
        default: return false
        }
    }
    var nodeCount: Int {
        if case .condition(_, _, _, let yes, let no) = self {
            return 1 + (yes + no).reduce(0) { $0 + $1.nodeCount }
        }
        return 1
    }
    var estimatedCost: Int {
        switch self {
        case .test(let values): return 1 + values.count
        case .condition(_, _, _, let yes, let no):
            return 1
                + max(
                    yes.reduce(0) { $0 + $1.estimatedCost }, no.reduce(0) { $0 + $1.estimatedCost })
        default: return 1
        }
    }
}

struct ScriptParser {
    private var lexer: ScriptLexer
    private var token: ScriptLexer.Token
    private let phase: ScriptCompatibilityInventory.Phase
    private var count = 0
    private var responseAlias: String?
    private var writes: Set<String> = []
    private var branches: [String] = []
    init(_ source: String, phase: ScriptCompatibilityInventory.Phase) throws {
        lexer = try ScriptLexer(source)
        token = try lexer.next()
        self.phase = phase
    }
    private func fail(_ code: String = "script.unsupportedSyntax") -> ScriptSyntaxFailure {
        .init(code: code, line: token.line, byteColumn: token.column)
    }
    private mutating func advance() throws { token = try lexer.next() }
    private mutating func take(_ kind: ScriptLexer.Kind) throws {
        guard token.kind == kind else { throw fail() }
        try advance()
    }
    private mutating func name() throws -> String {
        guard case .identifier(let value) = token.kind else { throw fail() }
        try advance()
        return value
    }
    private mutating func string() throws -> String {
        guard case .string(let value) = token.kind else { throw fail() }
        try advance()
        return value
    }
    private mutating func variableName() throws -> String {
        let value = try string()
        guard ResponseRules.validVariable(value), !value.hasPrefix("request."),
            !value.hasPrefix("response.")
        else { throw fail("script.invalidVariable") }
        return value
    }
    private mutating func chain() throws -> [String] {
        var result = [try name()]
        while token.kind == .symbol(46) {
            try advance()
            result.append(try name())
            guard result.count <= 8 else { throw fail("script.limit") }
        }
        return result
    }
    private func scope(_ value: String) -> ScriptVariableScope? {
        switch value {
        case "variables": .local
        case "environment": .environment
        case "collectionVariables": .collection
        case "globals": .globals
        case "iterationData": .data
        default: nil
        }
    }
    private mutating func expression(
        assertion: Bool = false, jsonAlias: String? = nil
    ) throws -> ScriptExpression {
        if case .string = token.kind { return .literal(try string()) }
        if case .identifier(let alias) = token.kind, alias == jsonAlias || alias == responseAlias {
            try advance()
            return try jsonSelector(allowRoot: assertion)
        }
        let path = try chain()
        try take(.symbol(40))
        if path.count == 3, path[0] == "pm", let scope = scope(path[1]), path[2] == "get" {
            let key = try variableName()
            try take(.symbol(41))
            return .get(scope, key)
        }
        guard phase == .test else { throw fail("script.responseBeforeRequest") }
        if path == ["pm", "response", "headers", "get"] {
            let header = try string()
            guard HTTPEncoding.isHeaderName(header) else { throw fail("script.invalidHeader") }
            try take(.symbol(41))
            return .header(header)
        }
        guard path == ["pm", "response", "json"] else { throw fail() }
        try take(.symbol(41))
        return try jsonSelector(allowRoot: assertion)
    }
    private mutating func jsonSelector(allowRoot: Bool) throws -> ScriptExpression {
        var selector: [String] = []
        while token.kind == .symbol(46) || token.kind == .symbol(91) {
            if token.kind == .symbol(46) {
                try advance()
                selector.append(try name())
            } else {
                try advance()
                switch token.kind {
                case .integer(let value):
                    selector.append(String(value))
                    try advance()
                case .string: selector.append(try string())
                default: throw fail()
                }
                try take(.symbol(93))
            }
            guard selector.count <= 32, selector.reduce(0, { $0 + $1.utf8.count }) <= 4096 else {
                throw fail("script.limit")
            }
        }
        guard allowRoot || !selector.isEmpty else { throw fail("script.jsonScalarRequired") }
        return .json(selector)
    }
    private mutating func terminator() throws {
        if token.kind == .symbol(59) {
            try advance()
        } else if token.kind != .end && token.kind != .symbol(125) {
            throw fail("script.statementSeparator")
        }
    }
    private mutating func assertionLiteral() throws -> ScriptLiteral {
        switch token.kind {
        case .string: return .string(try string())
        case .integer(let value):
            try advance()
            return .integer(value)
        case .identifier("true"), .identifier("false"):
            return .bool(try name() == "true")
        case .identifier("null"):
            try advance()
            return .null
        default: throw fail("script.unsupportedAssertionLiteral")
        }
    }
    private mutating func assertion(jsonAlias: String?) throws -> ScriptAssertion {
        let path = try chain()
        try take(.symbol(40))
        let assertion: ScriptAssertion
        switch path {
        case ["pm", "response", "to", "have", "status"]:
            guard case .integer(let status) = token.kind, (100...599).contains(status) else {
                throw fail("script.invalidStatus")
            }
            try advance()
            assertion = .status(status)
        case ["pm", "response", "to", "have", "header"]:
            let header = try string()
            guard HTTPEncoding.isHeaderName(header) else { throw fail("script.invalidHeader") }
            assertion = .header(header)
        case ["pm", "expect"]:
            let actual = try expression(assertion: true, jsonAlias: jsonAlias)
            try take(.symbol(41))
            try take(.symbol(46))
            let comparison = try chain()
            guard comparison == ["to", "equal"] || comparison == ["to", "eql"] else {
                throw fail("script.unsupportedAssertion")
            }
            try take(.symbol(40))
            assertion = .equal(actual, try assertionLiteral(), deep: comparison.last == "eql")
        default: throw fail("script.unsupportedAssertion")
        }
        try take(.symbol(41))
        try terminator()
        return assertion
    }
    private mutating func jsonAliasDeclaration() throws -> String {
        try take(.identifier("const"))
        let alias = try name()
        let reserved: Set<String> = [
            "pm", "postman", "arguments", "eval", "await", "break", "case", "catch", "class",
            "const",
            "continue", "debugger", "default", "delete", "do", "else", "enum", "export",
            "extends", "false", "finally", "for", "function", "if", "implements", "import",
            "in", "instanceof", "interface", "let", "new", "null", "package", "private",
            "protected", "public", "return", "static", "super", "switch", "this", "throw",
            "true", "try", "typeof", "var", "void", "while", "with", "yield",
        ]
        guard !reserved.contains(alias) else { throw fail("script.invalidAlias") }
        try take(.symbol(61))
        guard try chain() == ["pm", "response", "json"] else {
            throw fail("script.unsupportedAlias")
        }
        try take(.symbol(40))
        try take(.symbol(41))
        try terminator()
        return alias
    }

    private mutating func callback() throws -> [ScriptAssertion] {
        if token.kind == .identifier("function") {
            try advance()
            try take(.symbol(40))
            try take(.symbol(41))
        } else {
            try take(.symbol(40))
            try take(.symbol(41))
            try take(.arrow)
        }
        try take(.symbol(123))
        var assertions: [ScriptAssertion] = []
        var jsonAlias: String?
        if token.kind == .identifier("const") {
            jsonAlias = try jsonAliasDeclaration()
            assertions.append(.parseJSON)
        }
        let declarationCount = assertions.count
        while token.kind != .symbol(125) {
            assertions.append(try assertion(jsonAlias: jsonAlias))
            guard assertions.count <= 128 else { throw fail("script.limit") }
        }
        guard assertions.count > declarationCount else { throw fail("script.emptyTest") }
        try advance()
        return assertions
    }
    private mutating func block(depth: Int) throws -> [ScriptOperation] {
        guard depth <= 16 else { throw fail("script.limit") }
        try take(.symbol(123))
        let result = try statements(depth: depth, end: .symbol(125))
        try take(.symbol(125))
        return result
    }
    private mutating func statements(depth: Int, end: ScriptLexer.Kind) throws -> [ScriptOperation]
    {
        var operations: [ScriptOperation] = []
        while token.kind != end {
            try Task.checkCancellation()
            count += 1
            guard count <= 1024 else { throw fail("script.limit") }
            if token.kind == .identifier("if") {
                try advance()
                try take(.symbol(40))
                let negate = token.kind == .symbol(33)
                if negate { try advance() }
                let value = try expression()
                var expected: String?
                var negative = negate
                if token.kind == .equal || token.kind == .unequal {
                    guard !negate else { throw fail() }
                    negative = token.kind == .unequal
                    try advance()
                    expected = try string()
                }
                try take(.symbol(41))
                let yes = try block(depth: depth + 1)
                var no: [ScriptOperation] = []
                if token.kind == .identifier("else") {
                    try advance()
                    no = try block(depth: depth + 1)
                }
                operations.append(.condition(value, expected, negative, yes, no))
                continue
            }
            let path = try chain()
            try take(.symbol(40))
            let operation: ScriptOperation
            if path.count == 3, path[0] == "pm", let scope = scope(path[1]), scope != .data,
                ["set", "unset"].contains(path[2])
            {
                let key = try variableName()
                writes.insert(key)
                if path[2] == "set" {
                    try take(.symbol(44))
                    operation = .set(scope, key, try expression())
                } else {
                    operation = .unset(scope, key)
                }
            } else if path == ["pm", "test"] {
                guard phase == .test else { throw fail("script.assertionBeforeResponse") }
                _ = try string()
                try take(.symbol(44))
                operation = .test(try callback())
            } else if path == ["pm", "execution", "setNextRequest"]
                || path == ["postman", "setNextRequest"]
            {
                guard phase == .test else { throw fail("script.branchBeforeResponse") }
                if token.kind == .identifier("null") {
                    try advance()
                    operation = .next(nil)
                } else {
                    let target = try string()
                    guard !target.isEmpty, target.utf8.count <= 4096 else {
                        throw fail("script.invalidBranch")
                    }
                    branches.append(target)
                    operation = .next(target)
                }
            } else if path == ["pm", "execution", "skipRequest"] {
                guard phase == .prerequest else { throw fail("script.skipAfterResponse") }
                operation = .skip
            } else {
                throw fail()
            }
            try take(.symbol(41))
            try terminator()
            operations.append(operation)
        }
        return operations
    }
    mutating func parse() throws -> ScriptProgram {
        guard phase != .other else { throw fail("script.unsupportedPhase") }
        var operations: [ScriptOperation] = []
        if token.kind == .identifier("const") {
            guard phase == .test else { throw fail("script.responseBeforeRequest") }
            responseAlias = try jsonAliasDeclaration()
            operations.append(.parseJSON)
            count += 1
        }
        operations += try statements(depth: 0, end: .end)
        return ScriptProgram(operations: operations, writes: writes, branches: branches)
    }
}
