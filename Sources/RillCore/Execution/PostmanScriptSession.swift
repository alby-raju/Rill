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
            let pointer =
                "/"
                + path.map {
                    $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(
                        of: "/", with: "~1")
                }.joined(separator: "/")
            guard case .string(let text) = try ResponseJSON.value(response.body, path: pointer)
            else { throw WorkflowError.missingValue }
            return String(decoding: text, as: UTF8.self)
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
            case .testStatus(let expected):
                guard let response else { throw WorkflowError.invalidConfiguration }
                var passed = true
                for status in expected {
                    operations += 1
                    try budget()
                    if response.status != status {
                        passed = false
                        break
                    }
                }
                checks.append(CheckResult(title: "Translated status test", passed: passed))
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
