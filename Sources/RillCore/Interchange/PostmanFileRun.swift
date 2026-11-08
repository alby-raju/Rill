import Foundation

public enum PostmanFileRunError: Error {
    case blocked(CollectionPreflight)
    case invalidOverrides
}

/// A transient execution input: no workspace repository or native credential store is opened.
public struct PostmanFileRun: Sendable {
    public let requests: [RequestDraft]
    public let deferredRequestPositions: Set<Int>
    public let attachmentSlots: [PostmanAttachmentSlot]
    private let planningOnly: Bool
    public let sourceLocations: [String: String]
    public let environment: Environment
    public let secrets: NamedSecretResolver
    public var scriptsMayChangeOrder: Bool {
        scriptPlan?.programs.contains(where: \.changesOrder) == true
    }
    public var translatesScripts: Bool { scriptPlan != nil }
    private let iterationData: IterationData?
    private let iterationOverrides: [String: String]
    private let fileTLS: FileTLSConfiguration?
    private let scriptPlan: PostmanScriptPlan?
    private let scriptVariables: ScriptVariables?
    private let scriptOverrides: [String: String]

    public static func prepare(
        collection: Data, environment inputEnvironment: Data? = nil,
        overrides: [String: String] = [:], folder: String? = nil,
        iterationData: IterationData? = nil, fileTLS: FileTLSConfiguration? = nil,
        globals: Data? = nil, translateScripts: Bool = false, planningOnly: Bool = false,
        attachmentFiles: [String: URL] = [:]
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
        let scriptPlan = translateScripts ? try PostmanScriptPlan.prepare(selection) : nil
        if let scriptPlan, !scriptPlan.writes.isDisjoint(with: overrides.keys) {
            throw PostmanScriptPlanError(
                code: "script.overrideMutation", location: "/options/env-var", line: 1,
                byteColumn: 1)
        }
        var preflightOverrides = iterationData?.rows.first ?? [:]
        preflightOverrides.merge(overrides) { _, override in override }
        let preflight = try CollectionPreflight.inspect(
            selection, environment: inputEnvironment, overrides: preflightOverrides,
            globals: globals, translateScripts: translateScripts, preparedScripts: scriptPlan,
            discardUploadPaths: true)
        guard preflight.passed else { throw PostmanFileRunError.blocked(preflight) }
        let imported = try PostmanImporter.parse(selection.data, discardUploadPaths: true)
        guard imported.workspace.requests.count * (iterationData?.rows.count ?? 1) <= 10_000 else {
            throw WorkflowError.invalidConfiguration
        }
        var requests = imported.workspace.requests
        let locations = try RunSources.postman(selection)
        guard locations.count == requests.count else { throw WorkflowError.invalidConfiguration }
        let attachmentSlots = try PostmanAttachments.bind(
            &requests, locations: locations, files: attachmentFiles, planningOnly: planningOnly)
        var fields: [String: Field] = [:]
        var layers: [ScriptVariableScope: [String: String]] = [:]
        var currentScope = ScriptVariableScope.collection
        var catalog: [NamedSecret] = []
        var secretValues: [UUID: String] = [:]
        func apply(_ environments: [Environment]) {
            for environment in environments {
                for field in environment.variables where field.enabled {
                    fields[field.name] = field
                    layers[currentScope, default: [:]][field.name] = field.value
                }
            }
        }
        func applyImport(_ imported: ForeignWorkspaceImport) {
            apply(imported.workspace.environments)
            catalog += imported.workspace.namedSecrets ?? []
            if !planningOnly { secretValues.merge(imported.secretValues) { _, new in new } }
        }
        if let globals {
            currentScope = .globals
            applyImport(try PostmanImporter.parseGlobals(globals))
        }
        currentScope = .collection
        applyImport(imported)
        if let inputEnvironment {
            currentScope = .environment
            let importedEnvironment = try PostmanImporter.parse(inputEnvironment)
            applyImport(importedEnvironment)
        }
        for (name, value) in overrides { fields[name] = Field(name: name, value: value) }
        for (name, value) in overrides { layers[.environment, default: [:]][name] = value }
        layers[.local] = overrides
        let scopedVariables = ScriptVariables(layers: layers)
        if scriptPlan != nil { try scopedVariables.validate() }
        var environment = Environment(name: "Collection file")
        environment.variables = fields.keys.sorted().compactMap { fields[$0] }
        try WorkflowEngine.validateVariables(WorkflowEngine.variables(in: environment))
        let secrets = NamedSecretResolver(
            catalog: catalog, credentials: TransientCredentials(values: secretValues),
            processEnvironment: [:])
        let baseVariables = WorkflowEngine.variables(in: environment)
        var deferredRequestPositions = Set<Int>()
        if planningOnly, scriptPlan?.writes.isEmpty == false {
            deferredRequestPositions.formUnion(imported.workspace.requests.indices)
        }
        if planningOnly, let scriptPlan {
            for (position, step) in scriptPlan.requests.enumerated()
            where step.pre.contains(where: { scriptPlan.programs[$0].editsHeaders }) {
                deferredRequestPositions.insert(position)
            }
        }
        for index in 0..<(iterationData?.rows.count ?? 1) {
            let values =
                try iterationData?.variables(at: index, base: baseVariables, overrides: overrides)
                ?? baseVariables
            let rowEnvironment =
                iterationData == nil ? environment : WorkflowEngine.environment(values)
            var validationValues = values
            for name in scriptPlan?.writes ?? [] where validationValues[name] == nil {
                validationValues[name] = "https://rill-dynamic.invalid"
            }
            let validationEnvironment =
                scriptPlan == nil ? rowEnvironment : WorkflowEngine.environment(validationValues)
            for (position, input) in requests.enumerated() {
                var request = input
                try Task.checkCancellation()
                if request.bodyMode == .binary || request.bodyMode == .multipart {
                    if planningOnly {
                        deferredRequestPositions.insert(position)
                    } else {
                        try UploadBody.validate(
                            request, environment: validationEnvironment, secrets: secrets)
                    }
                    request.bodyMode = RequestBodyMode.none
                }
                if planningOnly {
                    if try RequestEngine.prepareForPlanning(
                        request, environment: validationEnvironment)
                    {
                        deferredRequestPositions.insert(position)
                    }
                } else {
                    _ = try RequestEngine.prepare(
                        request, environment: validationEnvironment, secrets: secrets)
                }
            }
        }
        for index in requests.indices { requests[index].id = RunSources.id(locations[index]) }
        let sourceLocations = Dictionary(
            uniqueKeysWithValues: zip(requests, locations).map { ($0.id.uuidString, $1) })
        if let scriptPlan {
            guard scriptPlan.requests.count == requests.count else {
                throw WorkflowError.invalidConfiguration
            }
            let collectionID = UUID()
            for index in requests.indices { requests[index].collectionID = collectionID }
        }
        return Self(
            requests: requests, deferredRequestPositions: deferredRequestPositions,
            attachmentSlots: attachmentSlots,
            planningOnly: planningOnly, sourceLocations: sourceLocations, environment: environment,
            secrets: secrets,
            iterationData: iterationData,
            iterationOverrides: iterationData == nil ? [:] : overrides,
            fileTLS: fileTLS, scriptPlan: scriptPlan,
            scriptVariables: scriptPlan == nil ? nil : scopedVariables,
            scriptOverrides: overrides
        )
    }

    /// File-run success explicitly requires HTTP 2xx, not unexecuted Postman assertions.
    public func run(
        configuration: RunConfiguration, timeout: Double? = nil,
        exportEnvironment: CollectionRunner.EnvironmentExport? = nil, cookieJar: CookieJar? = nil
    ) async throws -> RunReport {
        guard !planningOnly else { throw WorkflowError.invalidConfiguration }
        var report = try await executeRun(
            configuration: configuration, timeout: timeout, exportEnvironment: exportEnvironment,
            cookieJar: cookieJar)
        report.sources = sourceLocations
        report.sourceFormat = "postman-position-v1"
        return report
    }
    private func executeRun(
        configuration: RunConfiguration, timeout: Double? = nil,
        exportEnvironment: CollectionRunner.EnvironmentExport? = nil, cookieJar: CookieJar? = nil
    ) async throws -> RunReport {
        var requests = self.requests
        if let timeout {
            guard timeout.isFinite, (1...300).contains(timeout) else {
                throw RillError.invalidTimeout
            }
            for index in requests.indices { requests[index].timeout = timeout }
        }
        let secrets = self.secrets
        let fileTLS = self.fileTLS
        let cookieJar = cookieJar ?? (configuration.cookieSession == true ? CookieJar() : nil)
        if let scriptPlan, let scriptVariables {
            let session = PostmanScriptSession(
                plan: scriptPlan, requests: requests, initial: scriptVariables, data: iterationData,
                overrides: scriptOverrides, secrets: secrets)
            let report = try await CollectionRunner.run(
                requests: requests, environment: environment, configuration: configuration,
                iterationData: iterationData, iterationOverrides: iterationOverrides,
                contextualExecutor: { request, _, context in
                    try await session.run(
                        request, context: context, fileTLS: fileTLS, cookieJar: cookieJar)
                })
            if !report.cancelled {
                try Task.checkCancellation()
                if let exportEnvironment {
                    let values = await session.snapshot()
                    try await exportEnvironment(values)
                }
            }
            return report
        }
        return try await CollectionRunner.run(
            requests: requests, environment: environment, configuration: configuration,
            iterationData: iterationData, iterationOverrides: iterationOverrides,
            exportEnvironment: exportEnvironment,
            executor: { request, variables in
                var result = try await WorkflowEngine.execute(
                    request, variables: variables, secrets: secrets, fileTLS: fileTLS,
                    cookieJar: cookieJar)
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
