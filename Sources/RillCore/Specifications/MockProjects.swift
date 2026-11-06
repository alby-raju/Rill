import Foundation

public struct MockScenario: Codable, Equatable, Sendable {
    public var name: String
    public var requiredState: String
    public var nextState: String?
    public init(name: String, requiredState: String = "start", nextState: String? = nil) {
        self.name = name
        self.requiredState = requiredState
        self.nextState = nextState
    }
}
public enum MockFault: String, Codable, CaseIterable, Sendable { case disconnect }
public struct MockFixtureOrigin: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case definition, response }
    public let kind: Kind
    public let sourceID: UUID
    public let operation: String
    public init(kind: Kind, sourceID: UUID, operation: String = "") {
        self.kind = kind
        self.sourceID = sourceID
        self.operation = operation
    }
}
public struct MockProject: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = "New mock project"
    public var port: UInt16 = 0
    public var routes: [MockRoute] = []
    /// An unapplied editor draft is saved as data; it never configures a listener implicitly.
    public var jsonDraft: String?
    public init(name: String = "New mock project", routes: [MockRoute] = []) {
        self.name = name
        self.routes = routes
    }
    public static func validateStorage(_ projects: [MockProject]) throws {
        guard projects.count <= 16, Set(projects.map(\.id)).count == projects.count,
            projects.reduce(0, { $0 + $1.routes.count }) <= 1000,
            projects.reduce(0, { $0 + ($1.jsonDraft?.utf8.count ?? 0) }) <= 4 * 1024 * 1024,
            projects.flatMap(\.routes).reduce(0, { $0 + $1.body.utf8.count }) <= 16 * 1024 * 1024,
            projects.flatMap(\.routes).reduce(0, { $0 + ($1.expectedBody?.utf8.count ?? 0) }) <= 4
                * 1024 * 1024
        else { throw WorkflowError.limit }
        guard
            projects.flatMap(\.routes).reduce(
                0,
                { sum, route in
                    sum
                        + (route.headers + (route.query ?? []) + (route.requestHeaders ?? []))
                        .reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count })
                }) <= 4 * 1024 * 1024
        else { throw WorkflowError.limit }
        for project in projects {
            guard project.name.utf8.count <= 4096,
                Set(project.routes.map(\.id)).count == project.routes.count
            else { throw WorkflowError.invalidConfiguration }
            for route in project.routes {
                guard route.path.utf8.count <= 4096, route.body.utf8.count <= 1024 * 1024,
                    (route.expectedBody?.utf8.count ?? 0) <= 1024 * 1024,
                    route.headers.count <= 100, (route.query?.count ?? 0) <= 100,
                    (route.requestHeaders?.count ?? 0) <= 100,
                    (route.origin?.operation.utf8.count ?? 0) <= 8192
                else { throw WorkflowError.limit }
                let fields = route.headers + (route.query ?? []) + (route.requestHeaders ?? [])
                guard fields.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 49152
                else { throw WorkflowError.limit }
                if let scenario = route.scenario {
                    guard scenario.name.utf8.count <= 128, scenario.requiredState.utf8.count <= 128,
                        (scenario.nextState?.utf8.count ?? 0) <= 128
                    else { throw WorkflowError.limit }
                }
            }
        }
    }
}

/// Versioned portable configuration shared by desktop and CLI. No running state or draft export.
public enum MockProjectFile {
    public static let maximumBytes = 2 * 1024 * 1024
    public static func decode(_ data: Data) throws -> MockProject {
        guard data.count <= maximumBytes else { throw WorkflowError.limit }
        let parsed = try JSONValueParser(data).parse()
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(root.keys).isSubset(of: ["kind", "version", "name", "port", "routes"]),
            root["kind"] as? String == "rill.mock-project",
            let version = parsed["version"], try ExactSchemaNumber(version).nonnegativeInt == 1,
            let name = root["name"] as? String, let routes = root["routes"] as? [[String: Any]],
            let portValue = parsed["port"],
            let port = try ExactSchemaNumber(portValue).nonnegativeInt,
            (0...65535).contains(port)
        else { throw WorkflowError.invalidConfiguration }
        var project = MockProject(
            name: name,
            routes: try MockRouteFile.decode(JSONSerialization.data(withJSONObject: routes)))
        project.port = UInt16(port)
        try MockProject.validateStorage([project])
        return project
    }
    public static func encode(_ project: MockProject) throws -> Data {
        try MockProject.validateStorage([project])
        let routes = try JSONSerialization.jsonObject(with: MockRouteFile.encode(project.routes))
        let result = try JSONSerialization.data(
            withJSONObject: [
                "kind": "rill.mock-project", "version": 1, "name": project.name,
                "port": Int(project.port), "routes": routes,
            ], options: [.prettyPrinted, .sortedKeys])
        guard result.count <= maximumBytes else { throw WorkflowError.limit }
        return result
    }
}

public struct MockRequestRecord: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let method: HTTPMethod
    /// Query-free, control-stripped, bounded display path. No bodies or headers are retained.
    public let path: String
    public let routeIndex: Int?
    public let responseStatus: Int?
    public let requestBytes: Int
    public let configuredDelayMilliseconds: Int
}
