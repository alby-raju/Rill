import Foundation

public struct MockSessionSnapshot: Sendable {
    public let project: MockProject
    public let baseURL: URL?
    public let starting: Bool
    public let records: [MockRequestRecord]
    public let requestCount: Int
}

/// Owns listeners independently of editors. Nothing starts from saved data automatically.
public actor MockSessions {
    private struct Entry {
        let token: UUID
        let server: MockServer
        let project: MockProject
        var baseURL: URL?
        var starting = true
    }
    private var entries: [UUID: Entry] = [:]
    public init() {}
    public func start(_ project: MockProject) async throws {
        try MockProject.validateStorage([project])
        try MockServer.validate(project.routes)
        guard
            entries.values.filter({ $0.starting || $0.baseURL != nil }).count < 4
                || entries[project.id].map({ $0.starting || $0.baseURL != nil }) == true
        else { throw WorkflowError.limit }
        let previous = entries[project.id]
        let token = UUID()
        let server = MockServer()
        entries[project.id] = Entry(token: token, server: server, project: project)
        await previous?.server.stop()
        guard entries[project.id]?.token == token else { throw CancellationError() }
        do {
            let url = try await server.start(routes: project.routes, port: project.port)
            guard entries[project.id]?.token == token else {
                await server.stop()
                throw CancellationError()
            }
            entries[project.id]?.baseURL = url
            entries[project.id]?.starting = false
        } catch {
            if entries[project.id]?.token == token { entries.removeValue(forKey: project.id) }
            await server.stop()
            throw error
        }
    }
    public func stop(_ id: UUID) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        await entry.server.stop()
    }
    public func stopAll() async {
        let old = entries.values.map(\.server)
        entries.removeAll()
        for server in old { await server.stop() }
    }
    public func retain(_ ids: Set<UUID>) async {
        for id in Array(entries.keys) where !ids.contains(id) { await stop(id) }
    }
    public func runningIDs() -> Set<UUID> {
        Set(entries.filter { $0.value.starting || $0.value.baseURL != nil }.map(\.key))
    }
    public func reset(_ id: UUID) async { await entries[id]?.server.resetScenarios() }
    public func clearJournal(_ id: UUID) async { await entries[id]?.server.clearJournal() }
    public func snapshot(_ id: UUID) async -> MockSessionSnapshot? {
        guard let entry = entries[id] else { return nil }
        let records = await entry.server.journal()
        let count = await entry.server.requestCount()
        guard entries[id]?.token == entry.token else { return nil }
        return MockSessionSnapshot(
            project: entry.project, baseURL: entry.baseURL,
            starting: entry.starting, records: records, requestCount: count)
    }
}
