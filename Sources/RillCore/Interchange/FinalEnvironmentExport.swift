import Foundation

/// Explicit raw export of effective variables, including workflow updates. Secret references
/// remain references: this encoder never resolves credentials or expands templates.
public enum FinalEnvironmentExport {
    public static func encode(_ variables: [String: String]) throws -> Data {
        try WorkflowEngine.validateVariables(variables)
        struct Entry: Encodable {
            let key: String
            let value: String
            let enabled = true
            let type = "default"
        }
        struct Document: Encodable {
            let name = "Rill final environment"
            let _postman_variable_scope = "environment"
            let values: [Entry]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(
            Document(values: variables.keys.sorted().map { Entry(key: $0, value: variables[$0]!) }))
    }
}
