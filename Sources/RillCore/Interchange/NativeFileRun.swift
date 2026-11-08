import Foundation

public enum NativeFileRunError: Error {
    case invalidSelection
    case emptySelection
    case unsupportedScripts
    case unsupportedUpload
    case unsupportedIdentity
    case insecureNotAllowed
}

/// Read-only native file execution. No WorkspaceSession, personal credentials or TLS identities.
public struct NativeFileRun: Sendable {
    public let requests: [RequestDraft]
    public let hasSelectedEnvironment: Bool
    public let deferredRequestPositions: Set<Int>
    private let planningOnly: Bool
    public let sourceLocations: [String: String]
    public let environment: Environment
    public let secrets: NamedSecretResolver
    private let profiles: [AuthenticationProfile]
    private let tlsProfiles: [TLSProfile]
    private let definitions: [APIDefinitionSource]
    private let iterationData: IterationData?
    private let iterationOverrides: [String: String]
    private let fileTLS: FileTLSConfiguration?

    public static func prepare(
        workspace data: Data, collection: String? = nil, environment selection: String? = nil,
        overrides: [String: String] = [:], processEnvironment: [String: String] = [:],
        allowInsecure: Bool = false, iterationData: IterationData? = nil,
        fileTLS: FileTLSConfiguration? = nil,
        planningTLS: (identityDeclared: Bool, overridesTrust: Bool)? = nil
    ) throws -> Self {
        try Task.checkCancellation()
        let workspace = try WorkspaceFile.decode(data)
        func selectedID<T: Identifiable>(
            _ selection: String, in values: [T], name: (T) -> String
        ) throws -> UUID where T.ID == UUID {
            let matches = values.filter {
                $0.id == UUID(uuidString: selection) || name($0) == selection
            }
            guard matches.count == 1, let match = matches.first else {
                throw NativeFileRunError.invalidSelection
            }
            return match.id
        }
        let collectionID = try collection.map {
            try selectedID($0, in: workspace.collections, name: { $0.name })
        }
        let requests = workspace.requests.filter {
            collectionID == nil || $0.collectionID == collectionID
        }
        guard !requests.isEmpty, requests.count <= 10_000 else {
            throw NativeFileRunError.emptySelection
        }
        guard requests.count * (iterationData?.rows.count ?? 1) <= 10_000 else {
            throw WorkflowError.invalidConfiguration
        }
        let environmentID =
            try selection.map {
                try selectedID($0, in: workspace.environments, name: { $0.name })
            } ?? workspace.selectedEnvironmentID
        let inherited = try environmentID.map {
            try EnvironmentResolver.resolve($0, in: workspace.environments)
        }
        var variables = WorkflowEngine.variables(in: inherited)
        for (name, value) in overrides {
            guard !name.isEmpty else { throw WorkflowError.invalidConfiguration }
            variables[name] = value
        }
        try WorkflowEngine.validateVariables(variables)
        if let iterationData {
            for index in iterationData.rows.indices {
                try Task.checkCancellation()
                _ = try iterationData.variables(at: index, base: variables, overrides: overrides)
            }
        }
        let identityAvailable =
            planningTLS?.identityDeclared ?? (fileTLS?.hasClientIdentity == true)
        let overridesTrust = planningTLS?.overridesTrust ?? (fileTLS?.overridesTrust == true)
        let profiles = workspace.authProfiles ?? []
        let tlsProfiles = workspace.tlsProfiles ?? []
        let definitions = workspace.apiDefinitions ?? []
        for request in requests {
            try Task.checkCancellation()
            guard !(request.foreignScripts ?? []).contains(where: { !$0.source.isEmpty }) else {
                throw NativeFileRunError.unsupportedScripts
            }
            guard request.bodyMode != .binary, request.bodyMode != .multipart,
                request.binaryFile == nil,
                !(request.multipartParts ?? []).contains(where: { $0.file != nil })
            else { throw NativeFileRunError.unsupportedUpload }
            for hook in [request.preHook, request.postHook].compactMap({ $0 }) {
                try HookRuntime.validate(hook)
            }
            _ = try AuthenticationProfiles.applying(to: request, profiles: profiles)
            if let tls = try TLSProfiles.selected(
                request.tlsProfileID, from: tlsProfiles,
                fileIdentityAvailable: identityAvailable)
            {
                guard
                    (!tls.requiresClientIdentity && tls.identityReference == nil)
                        || identityAvailable
                else {
                    throw NativeFileRunError.unsupportedIdentity
                }
                guard tls.mode != .insecure || allowInsecure || overridesTrust
                else {
                    throw NativeFileRunError.insecureNotAllowed
                }
            }
            _ = try APIContractContext(request.apiLink, definitions: definitions)
        }
        var deferredRequestPositions = Set<Int>()
        if planningTLS != nil {
            var changesVariables = false
            for (position, request) in requests.enumerated() {
                try ResponseRules.validate(request.assertions ?? [], request.extractions ?? [])
                if changesVariables || request.preHook != nil {
                    deferredRequestPositions.insert(position)
                }
                changesVariables =
                    changesVariables || request.preHook != nil || request.postHook != nil
                    || !(request.extractions ?? []).isEmpty
            }
            for index in 0..<(iterationData?.rows.count ?? 1) {
                let values =
                    try iterationData?.variables(at: index, base: variables, overrides: overrides)
                    ?? variables
                let environment = WorkflowEngine.environment(values)
                for (position, request) in requests.enumerated()
                where !deferredRequestPositions.contains(position) {
                    try Task.checkCancellation()
                    if try RequestEngine.prepareForPlanning(
                        request, environment: environment, profiles: profiles)
                    {
                        deferredRequestPositions.insert(position)
                    }
                }
            }
            if changesVariables { deferredRequestPositions.formUnion(requests.indices) }
        }
        // Bind only explicitly supplied process values to this file's descriptors. Never consult
        // the native provider or change its normal catalog-before-process precedence.
        let catalog = workspace.namedSecrets ?? []
        var values: [UUID: String] = [:]
        for secret in catalog {
            if let value = processEnvironment[
                try NamedSecretResolver.environmentKey(for: secret.name)]
            {
                values[secret.id] = value
            }
        }
        let secrets = NamedSecretResolver(
            catalog: catalog, credentials: TransientCredentials(values: values),
            processEnvironment: processEnvironment.filter { $0.key.hasPrefix("RILL_SECRET_") })
        return Self(
            requests: requests, hasSelectedEnvironment: environmentID != nil,
            deferredRequestPositions: deferredRequestPositions,
            planningOnly: planningTLS != nil,
            sourceLocations: Dictionary(
                uniqueKeysWithValues: workspace.requests.enumerated().map {
                    ($0.element.id.uuidString, "/requests/\($0.offset)")
                }),
            environment: WorkflowEngine.environment(variables),
            secrets: secrets,
            profiles: profiles, tlsProfiles: tlsProfiles, definitions: definitions,
            iterationData: iterationData,
            iterationOverrides: iterationData == nil ? [:] : overrides,
            fileTLS: fileTLS
        )
    }

    /// Native checks retain their semantics; unchecked responses receive an explicit 2xx check.
    public func run(
        configuration: RunConfiguration, timeout: Double? = nil,
        exportEnvironment: CollectionRunner.EnvironmentExport? = nil, cookieJar: CookieJar? = nil
    ) async throws -> RunReport {
        guard !planningOnly else { throw WorkflowError.invalidConfiguration }
        var report = try await executeRun(
            configuration: configuration, timeout: timeout, exportEnvironment: exportEnvironment,
            cookieJar: cookieJar)
        let ids = Set(requests.map { $0.id.uuidString })
        report.sources = sourceLocations.filter { ids.contains($0.key) }
        report.sourceFormat = "native-id-v1"
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
        let profiles = self.profiles
        let secrets = self.secrets
        let tlsProfiles = self.tlsProfiles
        let definitions = self.definitions
        let fileTLS = self.fileTLS
        let cookieJar = cookieJar ?? (configuration.cookieSession == true ? CookieJar() : nil)
        return try await CollectionRunner.run(
            requests: requests, environment: environment, configuration: configuration,
            iterationData: iterationData, iterationOverrides: iterationOverrides,
            exportEnvironment: exportEnvironment,
            executor: { request, variables in
                var result: WorkflowStepResult
                do {
                    result = try await WorkflowEngine.execute(
                        request, variables: variables, profiles: profiles, secrets: secrets,
                        tlsProfiles: tlsProfiles, definitions: definitions, fileTLS: fileTLS,
                        cookieJar: cookieJar)
                } catch {
                    if error is AuthenticationError || error is TLSError || error is ContractError
                        || error is FileTLSError
                    {
                        throw WorkflowError.invalidConfiguration
                    }
                    throw error
                }
                if result.exchange.checks.isEmpty {
                    result.exchange.checks.append(
                        CheckResult(
                            title: "HTTP status is 2xx (no native checks configured)",
                            passed: (200...299).contains(result.exchange.status)))
                }
                return result
            })
    }
}
