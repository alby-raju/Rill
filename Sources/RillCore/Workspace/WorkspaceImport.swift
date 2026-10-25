import Foundation

public enum WorkspaceImport {
    /// Build an entirely validated value before publishing any imported edits.
    /// Imported auth credentials are never trusted as local Keychain material.
    public static func merging(_ incoming: Workspace, into existing: Workspace) throws -> Workspace {
        try WorkspaceFile.validate(incoming)
        try WorkspaceFile.validate(existing)
        var result = existing
        var sourceIDs: [UUID: UUID] = [:]
        for var source in incoming.apiDefinitions ?? [] {
            let old = source.id; source.id = UUID(); sourceIDs[old] = source.id
            if result.apiDefinitions == nil { result.apiDefinitions = [] }; result.apiDefinitions?.append(source)
        }
        var collections: [UUID: UUID] = [:]
        let tlsIDs = Dictionary(uniqueKeysWithValues: (incoming.tlsProfiles ?? []).map { ($0.id, UUID()) })
        for var profile in incoming.tlsProfiles ?? [] {
            profile.id = tlsIDs[profile.id]!; profile.requiresClientIdentity = profile.requiresClientIdentity || profile.identityReference != nil; profile.identityReference = nil
            if result.tlsProfiles == nil { result.tlsProfiles = [] }; result.tlsProfiles?.append(profile)
        }
        let profileIDs = Dictionary(uniqueKeysWithValues: (incoming.authProfiles ?? []).map { ($0.id, UUID()) })
        var secretNames: [String: String] = [:]
        var used = Set(try (existing.namedSecrets ?? []).map { try NamedSecretResolver.environmentKey(for: $0.name) })
        for secret in incoming.namedSecrets ?? [] {
            var name = secret.name
            if used.contains(try NamedSecretResolver.environmentKey(for: name)) { name = String(name.prefix(100)) + "-import-" + UUID().uuidString.prefix(8) }
            used.insert(try NamedSecretResolver.environmentKey(for: name)); secretNames[secret.name] = name
            if result.namedSecrets == nil { result.namedSecrets = [] }
            result.namedSecrets?.append(NamedSecret(name: name))
        }
        let secretPattern = try NSRegularExpression(pattern: #"\{\{\s*secret:([A-Za-z0-9_.-]+)\s*\}\}"#)
        func rewrite(_ text: String) -> String {
            guard !secretNames.isEmpty else { return text }
            var result = text
            for match in secretPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let keyRange = Range(match.range(at: 1), in: text), let range = Range(match.range, in: result), let name = secretNames[String(text[keyRange])] else { continue }
                result.replaceSubrange(range, with: "{{secret:" + name + "}}")
            }
            return result
        }
        for var profile in incoming.authProfiles ?? [] {
            profile.id = profileIDs[profile.id]!
            profile.secretName = secretNames[profile.secretName] ?? profile.secretName
            profile.username = rewrite(profile.username); profile.apiKeyName = rewrite(profile.apiKeyName)
            if let name = profile.oauth?.clientSecretName { profile.oauth?.clientSecretName = secretNames[name] ?? name }
            profile.tokenExpiresAt = nil
            if result.authProfiles == nil { result.authProfiles = [] }
            result.authProfiles?.append(profile)
        }
        for var collection in incoming.collections {
            let original = collection.id
            collection.id = UUID()
            collections[original] = collection.id
            result.collections.append(collection)
        }
        for var request in incoming.requests {
            request.id = UUID()
            request.collectionID = request.collectionID.flatMap { collections[$0] }
            request.credential = ""
            if let id = request.apiLink?.sourceID { request.apiLink?.sourceID = sourceIDs[id]!; request.apiLink?.baseline = Data() }
            request.graphql?.introspectOnEndpointChange = false
            request.preHook?.enabled = false; request.postHook?.enabled = false
            if let id = request.tlsProfileID { request.tlsProfileID = tlsIDs[id] ?? UUID() }
            if let id = request.authProfileID { request.authProfileID = profileIDs[id] ?? UUID() }
            request.url = rewrite(request.url); request.body = rewrite(request.body); request.username = rewrite(request.username)
            request.contentType = rewrite(request.contentType); request.apiKeyName = request.apiKeyName.map(rewrite)
            func fields(_ fields: [Field]) -> [Field] { fields.map { field in var copy = field; copy.name = rewrite(copy.name); copy.value = rewrite(copy.value); return copy } }
            request.headers = fields(request.headers); request.parameters = fields(request.parameters); request.formFields = request.formFields.map(fields)
            request.multipartParts = request.multipartParts?.map { part in var copy = part; copy.name = rewrite(copy.name); copy.value = rewrite(copy.value); copy.filename = rewrite(copy.filename); copy.contentType = rewrite(copy.contentType); return copy }
            result.requests.append(request)
        }
        let environmentIDs = Dictionary(uniqueKeysWithValues: incoming.environments.map { ($0.id, UUID()) })
        for var environment in incoming.environments {
            environment.id = environmentIDs[environment.id]!
            environment.parentID = environment.parentID.flatMap { environmentIDs[$0] }
            environment.variables = environment.variables.map { field in var copy = field; copy.value = rewrite(copy.value); return copy }
            result.environments.append(environment)
        }
        try WorkspaceFile.validate(result)
        return result
    }
}
