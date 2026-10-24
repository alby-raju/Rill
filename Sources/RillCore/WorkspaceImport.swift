import Foundation

public enum WorkspaceImport {
    /// Build an entirely validated value before publishing any imported edits.
    /// Imported auth credentials are never trusted as local Keychain material.
    public static func merging(_ incoming: Workspace, into existing: Workspace) throws -> Workspace {
        try WorkspaceFile.validate(incoming)
        try WorkspaceFile.validate(existing)
        var result = existing
        var collections: [UUID: UUID] = [:]
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
        func rewrite(_ text: String) -> String {
            let regex = try! NSRegularExpression(pattern: #"\{\{\s*secret:([A-Za-z0-9_.-]+)\s*\}\}"#)
            var result = text
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let keyRange = Range(match.range(at: 1), in: text), let range = Range(match.range, in: result), let name = secretNames[String(text[keyRange])] else { continue }
                result.replaceSubrange(range, with: "{{secret:" + name + "}}")
            }
            return result
        }
        for var profile in incoming.authProfiles ?? [] {
            profile.id = profileIDs[profile.id]!
            profile.secretName = secretNames[profile.secretName] ?? profile.secretName
            profile.username = rewrite(profile.username); profile.apiKeyName = rewrite(profile.apiKeyName)
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
