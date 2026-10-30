import Foundation

public enum PostmanFileRunError: Error {
    case blocked(CollectionPreflight)
    case unsupportedBody
    case invalidOverrides
}

/// A transient execution input: no workspace repository or native credential store is opened.
public struct PostmanFileRun: Sendable {
    public let requests: [RequestDraft]
    public let environment: Environment
    public let secrets: NamedSecretResolver
    private let iterationData: IterationData?
    private let iterationOverrides: [String: String]

    public static func prepare(
        collection: Data, environment inputEnvironment: Data? = nil,
        overrides: [String: String] = [:], folder: String? = nil,
        iterationData: IterationData? = nil
    ) throws -> Self {
        try Task.checkCancellation()
        guard overrides.count <= 10_000,
            overrides.allSatisfy({
                !$0.key.isEmpty && $0.key.utf8.count <= 4096 && $0.value.utf8.count <= 1024 * 1024
            }),
            overrides.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count })
                <= ResourceLimits.workspaceBytes
        else { throw PostmanFileRunError.invalidOverrides }
        let selection = try PostmanFolderSelection.prepare(collection, folder: folder)
        var preflightOverrides = iterationData?.rows.first ?? [:]
        preflightOverrides.merge(overrides) { _, override in override }
        let preflight = try CollectionPreflight.inspect(
            selection, environment: inputEnvironment, overrides: preflightOverrides)
        guard preflight.passed else { throw PostmanFileRunError.blocked(preflight) }
        let imported = try PostmanImporter.parse(selection.data)
        guard imported.workspace.requests.count * (iterationData?.rows.count ?? 1) <= 10_000 else {
            throw WorkflowError.invalidConfiguration
        }
        // Referenced upload files must not be silently opened or converted into empty bodies.
        guard
            imported.workspace.requests.allSatisfy({
                $0.bodyMode != .binary && $0.bodyMode != .multipart
            })
        else {
            throw PostmanFileRunError.unsupportedBody
        }
        var fields: [String: Field] = [:]
        var catalog = imported.workspace.namedSecrets ?? []
        var secretValues = imported.secretValues
        func apply(_ environments: [Environment]) {
            for environment in environments {
                for field in environment.variables where field.enabled {
                    fields[field.name] = field
                }
            }
        }
        apply(imported.workspace.environments)
        if let inputEnvironment {
            let importedEnvironment = try PostmanImporter.parse(inputEnvironment)
            apply(importedEnvironment.workspace.environments)
            catalog += importedEnvironment.workspace.namedSecrets ?? []
            secretValues.merge(importedEnvironment.secretValues) { _, new in new }
        }
        for (name, value) in overrides { fields[name] = Field(name: name, value: value) }
        var environment = Environment(name: "Collection file")
        environment.variables = fields.keys.sorted().compactMap { fields[$0] }
        try WorkflowEngine.validateVariables(WorkflowEngine.variables(in: environment))
        let secrets = NamedSecretResolver(
            catalog: catalog, credentials: TransientCredentials(values: secretValues),
            processEnvironment: [:])
        let baseVariables = WorkflowEngine.variables(in: environment)
        for index in 0..<(iterationData?.rows.count ?? 1) {
            let values =
                try iterationData?.variables(at: index, base: baseVariables, overrides: overrides)
                ?? baseVariables
            let rowEnvironment =
                iterationData == nil ? environment : WorkflowEngine.environment(values)
            for request in imported.workspace.requests {
                try Task.checkCancellation()
                _ = try RequestEngine.prepare(
                    request, environment: rowEnvironment, secrets: secrets)
            }
        }
        return Self(
            requests: imported.workspace.requests, environment: environment, secrets: secrets,
            iterationData: iterationData, iterationOverrides: iterationData == nil ? [:] : overrides
        )
    }

    /// File-run success explicitly requires HTTP 2xx, not unexecuted Postman assertions.
    public func run(configuration: RunConfiguration, timeout: Double? = nil) async throws
        -> RunReport
    {
        var requests = self.requests
        if let timeout {
            guard timeout.isFinite, (1...300).contains(timeout) else {
                throw RillError.invalidTimeout
            }
            for index in requests.indices { requests[index].timeout = timeout }
        }
        let secrets = self.secrets
        return try await CollectionRunner.run(
            requests: requests, environment: environment, configuration: configuration,
            iterationData: iterationData, iterationOverrides: iterationOverrides,
            executor: { request, variables in
                var result = try await WorkflowEngine.execute(
                    request, variables: variables, secrets: secrets)
                result.exchange.checks.append(
                    CheckResult(
                        title: "HTTP status is 2xx",
                        passed: (200...299).contains(result.exchange.status)))
                return result
            })
    }

}

struct TransientCredentials: CredentialStore {
    let values: [UUID: String]
    func read(_ id: UUID) throws -> String { values[id] ?? "" }
    func write(_ value: String, id: UUID) throws { throw CocoaError(.featureUnsupported) }
}
