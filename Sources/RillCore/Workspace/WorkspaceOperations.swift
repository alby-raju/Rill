import Foundation

public enum EditingError: LocalizedError, Equatable {
    case missingItem, invalidName, invalidParent, unsavedChanges, invalidSession, expansionLimit,
        variableCycle(String)
    public var errorDescription: String? {
        switch self {
        case .missingItem: "The selected item no longer exists."
        case .invalidName: "Enter a nonempty name."
        case .invalidParent:
            "Environment inheritance has a missing parent, a cycle or more than 64 levels."
        case .unsavedChanges: "Save or discard this draft before closing."
        case .invalidSession: "The editor session is invalid or exceeds its limits."
        case .expansionLimit: "Variable expansion exceeds its depth or size limit."
        case .variableCycle(let name): "Variable references form a cycle at {{\(name)}}."
        }
    }
}

public enum WorkspaceOperations {
    public static func renameCollection(_ id: UUID, to name: String, in workspace: inout Workspace)
        throws
    {
        guard let index = workspace.collections.firstIndex(where: { $0.id == id }) else {
            throw EditingError.missingItem
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EditingError.invalidName }
        workspace.collections[index].name = name
    }
    @discardableResult public static func deleteCollection(
        _ id: UUID, in workspace: inout Workspace
    ) throws -> Set<UUID> {
        guard workspace.collections.contains(where: { $0.id == id }) else {
            throw EditingError.missingItem
        }
        let removed = Set(workspace.requests.filter { $0.collectionID == id }.map(\.id))
        workspace.requests.removeAll { removed.contains($0.id) }
        workspace.collections.removeAll { $0.id == id }
        return removed
    }
    public static func duplicate(_ id: UUID, in workspace: inout Workspace) throws -> RequestDraft {
        guard var copy = workspace.requests.first(where: { $0.id == id }) else {
            throw EditingError.missingItem
        }
        copy.id = UUID()
        copy.name += " copy"
        workspace.requests.append(copy)
        return copy
    }
    public static func copy(
        _ request: RequestDraft, to collectionID: UUID?, in workspace: inout Workspace
    ) throws -> RequestDraft {
        try validateDestination(collectionID, in: workspace)
        var copy = request
        copy.id = UUID()
        copy.name += " copy"
        copy.collectionID = collectionID
        let anchor = workspace.requests.lastIndex { $0.collectionID == collectionID }
        workspace.requests.insert(copy, at: anchor.map { $0 + 1 } ?? workspace.requests.endIndex)
        return copy
    }
    public static func relocate(_ id: UUID, to collectionID: UUID?, in workspace: inout Workspace)
        throws
    {
        try validateDestination(collectionID, in: workspace)
        guard let index = workspace.requests.firstIndex(where: { $0.id == id }) else {
            throw EditingError.missingItem
        }
        guard workspace.requests[index].collectionID != collectionID else { return }
        var request = workspace.requests.remove(at: index)
        request.collectionID = collectionID
        let anchor = workspace.requests.lastIndex { $0.collectionID == collectionID }
        workspace.requests.insert(request, at: anchor.map { $0 + 1 } ?? workspace.requests.endIndex)
    }
    private static func validateDestination(_ id: UUID?, in workspace: Workspace) throws {
        guard id == nil || workspace.collections.contains(where: { $0.id == id }) else {
            throw EditingError.missingItem
        }
    }
    public static func move(
        _ id: UUID, before target: UUID, after: Bool = false, in workspace: inout Workspace
    ) throws {
        guard let source = workspace.requests.first(where: { $0.id == id }),
            let destination = workspace.requests.first(where: { $0.id == target }),
            source.collectionID == destination.collectionID
        else { throw EditingError.missingItem }
        try place(id, before: target, after: after, in: &workspace)
    }
    public static func place(
        _ id: UUID, before target: UUID, after: Bool = false, in workspace: inout Workspace
    ) throws {
        guard id != target else { return }
        guard let source = workspace.requests.firstIndex(where: { $0.id == id }),
            let destination = workspace.requests.first(where: { $0.id == target })
        else { throw EditingError.missingItem }
        var request = workspace.requests.remove(at: source)
        request.collectionID = destination.collectionID
        let anchor = workspace.requests.firstIndex { $0.id == target }!
        workspace.requests.insert(request, at: anchor + (after ? 1 : 0))
    }
    public static func move(_ id: UUID, offset: Int, in workspace: inout Workspace) throws {
        guard let request = workspace.requests.first(where: { $0.id == id }) else {
            throw EditingError.missingItem
        }
        let siblings = workspace.requests.filter { $0.collectionID == request.collectionID }
        let index = siblings.firstIndex { $0.id == id }!
        let target = index + offset
        guard siblings.indices.contains(target) else { return }
        try move(id, before: siblings[target].id, after: offset > 0, in: &workspace)
    }
    public static func deleteEnvironment(_ id: UUID, in workspace: inout Workspace) {
        workspace.environments.removeAll { $0.id == id }
        for index in workspace.environments.indices
        where workspace.environments[index].parentID == id {
            workspace.environments[index].parentID = nil
        }
        if workspace.selectedEnvironmentID == id { workspace.selectedEnvironmentID = nil }
    }
}

public enum EnvironmentResolver {
    public static func resolve(_ id: UUID, in environments: [Environment]) throws -> Environment {
        let indexed = Dictionary(
            environments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let selected = indexed[id] else { throw EditingError.invalidParent }
        var chain: [Environment] = []
        var seen = Set<UUID>()
        var next: UUID? = id
        while let current = next {
            guard seen.insert(current).inserted, chain.count < 64,
                let environment = indexed[current]
            else { throw EditingError.invalidParent }
            chain.append(environment)
            next = environment.parentID
        }
        var fields: [String: Field] = [:]
        for environment in chain.reversed() {
            for field in environment.variables where field.enabled && !field.name.isEmpty {
                fields[field.name] = field
            }
        }
        var effective = selected
        effective.parentID = nil
        effective.variables = fields.values.sorted { $0.name < $1.name }
        return effective
    }
    private static func hierarchyDepths(_ environments: [Environment]) throws -> [UUID: Int] {
        let indexed = Dictionary(
            environments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard indexed.count == environments.count else { throw EditingError.invalidParent }
        var depths: [UUID: Int] = [:]
        for environment in environments where depths[environment.id] == nil {
            var chain: [UUID] = []
            var seen = Set<UUID>()
            var next: UUID? = environment.id
            var base = 0
            while let id = next {
                if let cached = depths[id] {
                    base = cached
                    break
                }
                guard chain.count < 64, seen.insert(id).inserted, let current = indexed[id] else {
                    throw EditingError.invalidParent
                }
                chain.append(id)
                next = current.parentID
            }
            guard chain.count + base <= 64 else { throw EditingError.invalidParent }
            for id in chain.reversed() {
                base += 1
                depths[id] = base
            }
        }
        return depths
    }
    public static func validateHierarchy(_ environments: [Environment]) throws {
        _ = try hierarchyDepths(environments)
    }
    public static func validParents(for id: UUID, in environments: [Environment]) -> [Environment] {
        guard let depths = try? hierarchyDepths(environments), depths[id] != nil else { return [] }
        var children: [UUID: [UUID]] = [:]
        for environment in environments {
            if let parent = environment.parentID {
                children[parent, default: []].append(environment.id)
            }
        }
        var excluded = Set<UUID>()
        var stack = [(id, 0)]
        var height = 0
        while let (current, level) = stack.popLast() {
            excluded.insert(current)
            height = max(height, level)
            stack += (children[current] ?? []).map { ($0, level + 1) }
        }
        return environments.filter {
            !excluded.contains($0.id) && (depths[$0.id] ?? 64) + 1 + height <= 64
        }
    }
    public static func canSetParent(_ parent: UUID?, for id: UUID, in environments: [Environment])
        -> Bool
    {
        var copy = environments
        guard let index = copy.firstIndex(where: { $0.id == id }) else { return false }
        copy[index].parentID = parent
        return (try? validateHierarchy(copy)) != nil
    }
}

public enum RequestTemplate: String, CaseIterable, Sendable {
    case rest = "REST GET", json = "JSON POST", bearer = "Bearer GET", graphql = "GraphQL POST"
    public func make(in collection: UUID?) -> RequestDraft {
        var request = RequestDraft(collectionID: collection)
        request.name = rawValue
        switch self {
        case .rest: request.url = "{{baseUrl}}/resources"
        case .json:
            request.method = .POST
            request.url = "{{baseUrl}}/resources"
            request.body = "{\n  \"name\": \"Example\"\n}"
        case .bearer:
            request.url = "{{baseUrl}}/resources"
            request.auth = .bearer
            request.credential = "{{token}}"
        case .graphql:
            request.method = .POST
            request.url = "{{baseUrl}}/graphql"
            request.body = "{\n  \"query\": \"query { __typename }\",\n  \"variables\": {}\n}"
        }
        return request
    }
}

public enum SearchKind: String, Sendable { case request, collection, environment, history }
public struct WorkspaceSearchResult: Identifiable, Sendable {
    public var id: String { kind.rawValue + targetID.uuidString }
    public let kind: SearchKind
    public let targetID: UUID
    public let title: String
    public let detail: String
}
public enum WorkspaceSearch {
    public static func results(_ query: String, in workspace: Workspace) -> [WorkspaceSearchResult]
    {
        var results = workspace.requests.map {
            WorkspaceSearchResult(
                kind: .request, targetID: $0.id, title: $0.name,
                detail: "\($0.method.rawValue) \($0.url)")
        }
        results += workspace.collections.map {
            WorkspaceSearchResult(
                kind: .collection, targetID: $0.id, title: $0.name, detail: "Collection")
        }
        results += workspace.environments.map {
            WorkspaceSearchResult(
                kind: .environment, targetID: $0.id, title: $0.name, detail: "Environment")
        }
        results += workspace.history.prefix(50).map {
            WorkspaceSearchResult(
                kind: .history, targetID: $0.id, title: $0.requestName,
                detail: "\($0.status) \($0.url)")
        }
        return results.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }
}
