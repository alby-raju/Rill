import Foundation

public struct WorkflowStepResult: Sendable {
    public var exchange: Exchange
    public var variables: [String: String]
    public var next: String?
    public var stop: Bool
    public var passed: Bool { exchange.checks.allSatisfy(\.passed) }
}
public enum WorkflowEngine {
    public static func variables(in environment: Environment?) -> [String: String] {
        environment?.variables.filter { $0.enabled && !$0.name.isEmpty }.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
    }
    public static func environment(_ variables: [String: String]) -> Environment {
        var environment = Environment(name: "Run-local snapshot")
        environment.variables = variables.sorted { $0.key < $1.key }.map { Field(name: $0.key, value: $0.value) }
        return environment
    }
    public static func prepare(_ request: RequestDraft, variables: [String: String]) throws -> HookOutcome {
        try ResponseRules.validate(request.assertions ?? [], request.extractions ?? [])
        let result = try HookRuntime.execute(request.preHook, request: request, variables: variables)
        guard !result.stop, result.next == nil, result.checks.allSatisfy(\.passed) else { throw WorkflowError.hookFailure }
        return result
    }
    public static func execute(_ request: RequestDraft, variables: [String: String], budget: ResponseBudget = .standard,
                               profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil,
                               tlsProfiles: [TLSProfile] = []) async throws -> WorkflowStepResult {
        try Task.checkCancellation()
        let prepared = try prepare(request, variables: variables)
        var exchange = try await RequestEngine.execute(prepared.request, environment: environment(prepared.variables), budget: budget,
                                                       profiles: profiles, secrets: secrets, tlsProfiles: tlsProfiles)
        exchange.checks += prepared.checks
        guard exchange.checks.allSatisfy(\.passed) else { return WorkflowStepResult(exchange: exchange, variables: variables, stop: false) }
        do {
            var updates = prepared.variables
            for (key, value) in try ResponseRules.extract(request.extractions ?? [], response: exchange) { updates[key] = value }
            let post = try HookRuntime.execute(request.postHook, request: prepared.request, variables: updates, response: exchange)
            exchange.checks += post.checks
            guard post.checks.allSatisfy(\.passed) else { return WorkflowStepResult(exchange: exchange, variables: variables, stop: false) }
            return WorkflowStepResult(exchange: exchange, variables: post.variables, next: post.next, stop: post.stop)
        } catch is CancellationError { throw CancellationError() }
        catch {
            exchange.checks.append(CheckResult(title: "Extraction or post-hook failed", passed: false))
            return WorkflowStepResult(exchange: exchange, variables: variables, stop: false)
        }
    }
}
