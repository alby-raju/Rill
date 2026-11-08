import Foundation

struct ScriptVariables: Sendable {
    var layers: [ScriptVariableScope: [String: String]]
    var effective: [String: String] {
        var result: [String: String] = [:]
        for scope in [ScriptVariableScope.globals, .collection, .environment, .data, .local] {
            result.merge(layers[scope] ?? [:]) { _, new in new }
        }
        return result
    }
    func validate() throws {
        let fields = layers.values.flatMap { $0.map { ($0.key, $0.value) } }
        guard fields.count <= 4096,
            fields.allSatisfy({
                ResponseRules.validVariable($0.0) && $0.1.utf8.count <= 1024 * 1024
            }),
            fields.reduce(0, { $0 + $1.0.utf8.count + $1.1.utf8.count }) <= 4 * 1024 * 1024
        else { throw WorkflowError.limit }
        try WorkflowEngine.validateVariables(effective)
    }
    mutating func write(_ value: String?, scope: ScriptVariableScope, key: String) throws {
        var staged = self
        staged.layers[scope, default: [:]][key] = value
        try staged.validate()
        self = staged
    }
}

actor PostmanScriptSession {
    private let plan: PostmanScriptPlan
    private let requests: [RequestDraft]
    private let requestIndices: [UUID: Int]
    private let initial: ScriptVariables
    private let data: IterationData?
    private let overrides: [String: String]
    private let secrets: NamedSecretResolver
    private var variables: ScriptVariables
    private var iteration: Int?
    private var operations = 0
    private var phaseStarted = ProcessInfo.processInfo.systemUptime
    private var next: String?
    private var stop = false
    private var skip = false
    private var checks: [CheckResult] = []
    private var responseJSON: Result<JSONValue, WorkflowError>?
    init(
        plan: PostmanScriptPlan, requests: [RequestDraft], initial: ScriptVariables,
        data: IterationData?, overrides: [String: String], secrets: NamedSecretResolver
    ) {
        self.plan = plan
        self.requests = requests
        var indices: [UUID: Int] = [:]
        for (index, request) in requests.enumerated() { indices[request.id] = index }
        requestIndices = indices
        self.initial = initial
        variables = initial
        self.data = data
        self.overrides = overrides
        self.secrets = secrets
    }
    func snapshot() -> [String: String] { variables.effective }
    private func budget() throws {
        try Task.checkCancellation()
        guard operations <= 1024, ProcessInfo.processInfo.systemUptime - phaseStarted <= 0.25 else {
            throw WorkflowError.limit
        }
    }
    private func value(_ expression: ScriptExpression, response: Exchange?) throws -> String? {
        switch expression {
        case .literal(let value): return value
        case .get(let scope, let name):
            let raw = scope == .local ? variables.effective[name] : variables.layers[scope]?[name]
            if let raw, raw.hasPrefix("{{secret:"), raw.hasSuffix("}}") {
                return try secrets.resolve(String(raw.dropFirst(9).dropLast(2)))
            }
            return raw
        case .header(let name):
            guard let response else { throw WorkflowError.invalidConfiguration }
            return response.headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?
                .value
        case .json(let path):
            guard let response else { throw WorkflowError.invalidConfiguration }
            guard case .string(let text) = try jsonValue(path, response: response)
            else { throw WorkflowError.missingValue }
            return String(decoding: text, as: UTF8.self)
        }
    }
    private func jsonValue(_ path: [String], response: Exchange) throws -> JSONValue {
        if responseJSON == nil {
            do {
                guard response.bodyWasTruncated != true else { throw WorkflowError.invalidJSON }
                responseJSON = .success(
                    try ResponseJSON.parse(response.body, preserveNumberSpelling: true))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                responseJSON = .failure(.invalidJSON)
            }
            try budget()
        }
        guard let responseJSON else { throw WorkflowError.invalidJSON }
        return try ResponseJSON.value(responseJSON.get(), tokens: path)
    }
    private func matches(_ assertion: ScriptAssertion, response: Exchange) throws -> Bool {
        switch assertion {
        case .status(let status):
            return response.status == status
        case .header(let header):
            return response.headers.contains {
                $0.name.caseInsensitiveCompare(header) == .orderedSame
            }
        case .parseJSON:
            do {
                _ = try jsonValue([], response: response)
                return true
            } catch WorkflowError.invalidJSON {
                return false
            }
        case .equal(let expression, let expected, let deep):
            let actual: JSONValue
            if case .json(let path) = expression {
                do {
                    actual = try jsonValue(path, response: response)
                } catch WorkflowError.missingValue {
                    return false
                } catch WorkflowError.invalidJSON {
                    return false
                }
            } else {
                guard let text = try value(expression, response: response) else { return false }
                actual = .string(Data(text.utf8))
            }
            switch (actual, expected) {
            case (.string(let data), .string(let text)): return data.elementsEqual(text.utf8)
            case (.number(let spelling), .integer(let number)):
                guard let value = Double(spelling), value == Double(number) else { return false }
                return !deep || value != 0 || value.sign == .plus
            case (.bool(let actual), .bool(let expected)): return actual == expected
            case (.null, .null): return true
            default: return false
            }
        }
    }
    private func execute(_ program: [ScriptOperation], response: Exchange?) throws {
        for operation in program {
            operations += 1
            try budget()
            switch operation {
            case .set(let scope, let name, let expression):
                guard let text = try value(expression, response: response) else {
                    throw WorkflowError.missingValue
                }
                try variables.write(text, scope: scope, key: name)
            case .unset(let scope, let name): try variables.write(nil, scope: scope, key: name)
            case .parseJSON:
                guard let response else { throw WorkflowError.invalidConfiguration }
                _ = try jsonValue([], response: response)
            case .test(let assertions):
                guard let response else { throw WorkflowError.invalidConfiguration }
                var passed = true
                for assertion in assertions {
                    operations += 1
                    try budget()
                    if try !matches(assertion, response: response) {
                        passed = false
                        break
                    }
                }
                checks.append(CheckResult(title: "Translated Postman test", passed: passed))
            case .next(let target):
                if let target {
                    guard let index = plan.targetIndices[Data(target.utf8)] else {
                        throw WorkflowError.invalidBranch
                    }
                    next = requests[index].id.uuidString
                    stop = false
                } else {
                    next = nil
                    stop = true
                }
            case .skip:
                skip = true
                return
            case .condition(let expression, let expected, let negative, let yes, let no):
                let actual = try value(expression, response: response)
                let condition =
                    expected.map { target in
                        actual.map { $0.utf8.elementsEqual(target.utf8) } ?? false
                    } ?? (actual?.isEmpty == false)
                try execute((negative ? !condition : condition) ? yes : no, response: response)
                if skip { return }
            }
        }
    }
    func run(
        _ request: RequestDraft, context: RunStepContext, fileTLS: FileTLSConfiguration?,
        cookieJar: CookieJar?
    ) async throws -> WorkflowStepResult {
        guard let index = requestIndices[request.id] else {
            throw WorkflowError.invalidConfiguration
        }
        if iteration != context.iteration {
            if let data {
                variables = initial
                variables.layers[.data] = data.rows[context.iteration - 1]
                variables.layers[.local] = overrides
            }
            iteration = context.iteration
        }
        try variables.validate()
        operations = 0
        next = nil
        stop = false
        skip = false
        checks = []
        responseJSON = nil
        defer { responseJSON = nil }
        phaseStarted = ProcessInfo.processInfo.systemUptime
        for source in plan.requests[index].pre {
            try execute(plan.programs[source].operations, response: nil)
            if skip { break }
        }
        if skip {
            let exchange = Exchange(
                requestID: request.id, requestName: "", method: request.method, url: "", status: 0,
                duration: 0, headers: [], body: Data(), checks: [])
            return WorkflowStepResult(
                exchange: exchange, variables: variables.effective, stop: false, skipped: true,
                commitVariablesOnFailure: true)
        }
        var exchange = try await RequestEngine.execute(
            request, environment: WorkflowEngine.environment(variables.effective), secrets: secrets,
            fileTLS: fileTLS, cookieJar: cookieJar)
        try Task.checkCancellation()
        phaseStarted = ProcessInfo.processInfo.systemUptime
        for source in plan.requests[index].post {
            try execute(plan.programs[source].operations, response: exchange)
        }
        if checks.isEmpty {
            checks.append(
                CheckResult(
                    title: "HTTP status is 2xx (no translated tests)",
                    passed: (200...299).contains(exchange.status)))
        }
        exchange.checks = checks
        return WorkflowStepResult(
            exchange: exchange, variables: variables.effective, next: next, stop: stop,
            commitVariablesOnFailure: true)
    }
}
