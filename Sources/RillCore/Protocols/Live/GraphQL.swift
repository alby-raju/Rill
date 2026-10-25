import Foundation

public struct GraphQLConfiguration: Codable, Equatable, Sendable {
    public var query = "query { __typename }"
    public var variables = "{}"
    public var operationName = ""
    public var introspectOnEndpointChange = false
    public var schemaSnapshot: Data?
    public var schemaEndpoint: String?
    public init() {}
}
public enum GraphQLError: LocalizedError {
    case invalidInput, invalidResponse, unavailableSchema, protocolFailure
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "GraphQL requires a nonempty bounded query, JSON-object variables, a valid operation name and HTTP POST. Full query syntax/type validation is performed by the server."
        case .invalidResponse: "The server response is not a valid bounded GraphQL result. Inspect HTTP status and raw response separately."
        case .unavailableSchema: "Introspection did not return a usable schema. It may be disabled or require credentials; no automatic retry was performed."
        case .protocolFailure: "The subscription server returned an invalid or unsupported graphql-transport-ws message."
        }
    }
}
public struct GraphQLResult: Sendable {
    public let errors: [String]
    public let hasData: Bool
    public let valid: Bool
}
public enum GraphQL {
    public static func validateStorage(_ configuration: GraphQLConfiguration) throws {
        guard configuration.query.utf8.count <= 1024 * 1024, !configuration.query.contains("\0"), configuration.variables.utf8.count <= 1024 * 1024,
              configuration.operationName.utf8.count <= 128,
              (configuration.schemaSnapshot?.count ?? 0) <= 8 * 1024 * 1024, (configuration.schemaEndpoint?.utf8.count ?? 0) <= 16384 else { throw GraphQLError.invalidInput }
    }
    public static func validate(_ configuration: GraphQLConfiguration) throws {
        try validateStorage(configuration)
        guard !configuration.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              configuration.operationName.isEmpty || isName(configuration.operationName) else { throw GraphQLError.invalidInput }
    }
    static func isName(_ name: String) -> Bool {
        guard name.utf8.count <= 256, let first = name.first, first.isASCII && (first.isLetter || first == "_") else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
    static func payload(_ configuration: GraphQLConfiguration, resolve: (String) throws -> String) throws -> JSONValue {
        try validate(configuration)
        let query = try resolve(configuration.query), variableText = try resolve(configuration.variables)
        guard query.utf8.count <= 1024 * 1024, variableText.utf8.count <= 1024 * 1024 else { throw WorkflowError.limit }
        let variables = try JSONValueParser(Data(variableText.utf8)).parse()
        guard case .object = variables, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GraphQLError.invalidInput }
        var object: [JSONKey: JSONValue] = [JSONKey("query"): .string(Data(query.utf8)), JSONKey("variables"): variables]
        let name = try resolve(configuration.operationName)
        guard name.isEmpty || isName(name) else { throw GraphQLError.invalidInput }
        if !name.isEmpty { object[JSONKey("operationName")] = .string(Data(name.utf8)) }
        return .object(object)
    }
    public static func body(_ configuration: GraphQLConfiguration, variables: [String: String] = [:]) throws -> Data {
        let data = try Data(ResponseJSON.encoded(payload(configuration, resolve: { try VariableExpansion.resolve($0, values: variables) })).utf8)
        guard data.count <= 4 * 1024 * 1024 else { throw WorkflowError.limit }
        return data
    }
    public static func result(_ data: Data) throws -> GraphQLResult {
        let root = try JSONValueParser(data).parse()
        guard root.object != nil else { throw GraphQLError.invalidResponse }
        var messages: [String] = [], valid = true
        if let errors = root["errors"] {
            guard let errors = errors.array else { throw GraphQLError.invalidResponse }
            guard errors.count <= 1000 else { throw WorkflowError.limit }
            for error in errors {
                guard let message = error["message"]?.string else { throw GraphQLError.invalidResponse }
                if messages.count < 30 { messages.append(String(decoding: message.utf8.prefix(1024), as: UTF8.self)) }
            }
            valid = !errors.isEmpty
        }
        let hasData = root["data"] != nil
        if let data = root["data"], data != .null, data.object == nil { valid = false }
        return GraphQLResult(errors: messages, hasData: hasData, valid: valid && (hasData || !messages.isEmpty))
    }
    // Independently authored bounded introspection selection, no external schema refs.
    public static let introspectionQuery = """
    query RillSchema {
      __schema {
        queryType { name } mutationType { name } subscriptionType { name }
        types {
          kind name description
          fields(includeDeprecated: true) { name description args { name description defaultValue type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } }
          inputFields { name description type { kind name ofType { kind name ofType { kind name } } } }
          enumValues(includeDeprecated: true) { name description }
        }
      }
    }
    """
    public static func introspect(_ draft: RequestDraft, environment: Environment?, profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil, tlsProfiles: [TLSProfile] = []) async throws -> Data {
        var request = draft, configuration = GraphQLConfiguration(); configuration.query = introspectionQuery; configuration.operationName = "RillSchema"
        request.graphql = configuration; request.method = .POST; request.apiLink = nil; request.preHook = nil; request.postHook = nil
        request.expectedStatus = ""; request.bodyContains = ""; request.assertions = nil; request.extractions = nil
        let response = try await RequestEngine.execute(request, environment: environment, budget: ResponseBudget(downloadBytes: 8 * 1024 * 1024), profiles: profiles, secrets: secrets, tlsProfiles: tlsProfiles)
        guard (200...299).contains(response.status), try result(response.body).errors.isEmpty else { throw GraphQLError.unavailableSchema }
        _ = try GraphQLSchema(response.body)
        return response.body
    }
}
public struct GraphQLSchema: Sendable {
    public let names: [String]
    public let typeCount: Int
    public init(_ data: Data) throws {
        let root = try JSONValueParser(data).parse()
        guard let types = root["data"]?["__schema"]?["types"]?.array, types.count <= 10_000 else { throw GraphQLError.unavailableSchema }
        var names = Set<String>()
        for type in types {
            try Task.checkCancellation()
            if let name = type["name"]?.string, GraphQL.isName(name) { names.insert(name) }
            for field in (type["fields"]?.array ?? []) + (type["inputFields"]?.array ?? []) + (type["enumValues"]?.array ?? []) {
                if let name = field["name"]?.string, GraphQL.isName(name) { names.insert(name) }
                for argument in field["args"]?.array ?? [] { if let name = argument["name"]?.string, GraphQL.isName(name) { names.insert(name) } }
                guard names.count <= 20_000 else { throw WorkflowError.limit }
            }
        }
        self.names = names.sorted(); typeCount = types.count
    }
    public func completions(prefix: String) -> [String] { Array(names.lazy.filter { $0.hasPrefix(prefix) }.prefix(100)) }
}
