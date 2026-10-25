import Foundation

public enum APIDrift: String, Codable, Sendable { case added, changed, removed, locallyEdited, unchanged, configurationOnly }
public struct APIDriftItem: Sendable { public let key: String; public let state: APIDrift }
public struct APIImportPlan: Sendable {
    private let baseline: Workspace
    private let updated: Workspace
    public let changes: [APIDriftItem]
    public let warnings: [String]
    public let sourceID: UUID
    public init(_ definition: APIDefinition, current: Workspace, refreshing sourceID: UUID? = nil) throws {
        try WorkspaceFile.validate(current)
        baseline = current
        let id = sourceID ?? definition.source.id; self.sourceID = id
        let oldSource = (current.apiDefinitions ?? []).first { $0.id == id }
        if sourceID != nil && oldSource == nil { throw SchemaError.invalid }
        let old = try oldSource.map { try APIDefinitionLoader.parse($0.snapshot, location: $0.location, sourceID: id) }
        let prior = Dictionary(uniqueKeysWithValues: (old?.operations ?? []).map { ($0.key, $0) })
        let new = Dictionary(uniqueKeysWithValues: definition.operations.map { ($0.key, $0) })
        var result = current, changes: [APIDriftItem] = [], warnings = definition.warnings
        var collections: [String: UUID] = [:]
        for operation in definition.operations {
            let name = definition.source.title + " / " + operation.group
            let reference = current.requests.first { $0.apiLink?.sourceID == id && new[$0.apiLink!.operationKey]?.group == operation.group }
            let savedCollection = reference?.apiLink.flatMap { try? JSONDecoder().decode(RequestDraft.self, from: $0.baseline) }?.collectionID
            if let savedCollection, current.collections.contains(where: { $0.id == savedCollection }) { collections[operation.group] = savedCollection }
            else if let collection = current.collections.first(where: { collection in
                collection.name == name && current.requests.contains { $0.collectionID == collection.id && $0.apiLink?.sourceID == id }
            }) { collections[operation.group] = collection.id }
            else if collections[operation.group] == nil { let collection = RequestCollection(name: name); collections[operation.group] = collection.id; result.collections.append(collection) }
        }
        for key in Set(prior.keys).union(new.keys).sorted() {
            let linked = result.requests.indices.filter { result.requests[$0].apiLink?.sourceID == id && result.requests[$0].apiLink?.operationKey == key }
            guard linked.count <= 1 else { throw SchemaError.invalid }
            let index = linked.first
            if let operation = new[key] {
                var generated = operation.request; generated.collectionID = collections[operation.group]
                if let index {
                    let existing = result.requests[index]
                    var snapshot = existing; snapshot.apiLink = nil
                    let encoded = try APIImportPlan.encode(snapshot)
                    if encoded != existing.apiLink?.baseline {
                        changes.append(APIDriftItem(key: key, state: .locallyEdited)); continue
                    }
                    generated.id = existing.id
                    let drift: APIDrift = prior[key]?.fingerprint != operation.fingerprint ? .changed : oldSource?.snapshot == definition.source.snapshot ? .unchanged : .configurationOnly
                    changes.append(APIDriftItem(key: key, state: drift))
                    // Preserve unchanged local values and identities even when unrelated source metadata changes.
                    if drift == .unchanged { continue }
                    generated.apiLink = APIRequestLink(sourceID: id, operationKey: key, baseline: try Self.encode(generated))
                    result.requests[index] = generated
                } else {
                    generated.apiLink = APIRequestLink(sourceID: id, operationKey: key, baseline: try Self.encode(generated))
                    result.requests.append(generated); changes.append(APIDriftItem(key: key, state: .added))
                }
                if warnings.count < 100 { warnings += operation.gaps.prefix(min(8, 100 - warnings.count)).map { key + ": " + $0 } }
            } else if let index {
                var existing = result.requests[index]; existing.apiLink = nil
                if try Self.encode(existing) == result.requests[index].apiLink?.baseline {
                    result.requests.remove(at: index); changes.append(APIDriftItem(key: key, state: .removed))
                } else {
                    result.requests[index].apiLink = nil; changes.append(APIDriftItem(key: key, state: .locallyEdited))
                    warnings.append("Removed operation kept as an unlinked locally edited request: " + key)
                }
            }
        }
        var source = definition.source; source.id = id
        if result.apiDefinitions == nil { result.apiDefinitions = [] }
        result.apiDefinitions?.removeAll { $0.id == id }; result.apiDefinitions?.append(source)
        try WorkspaceFile.validate(result)
        _ = try WorkspaceFile.encode(result)
        updated = result; self.changes = changes; self.warnings = Array(warnings.prefix(100))
    }
    static func encode(_ request: RequestDraft) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }
    public func applying(to current: Workspace) throws -> Workspace {
        guard !current.needsSave(comparedTo: baseline) else { throw WorkspaceError.conflict }
        var copy = updated; copy.history = current.history; return copy
    }
}
