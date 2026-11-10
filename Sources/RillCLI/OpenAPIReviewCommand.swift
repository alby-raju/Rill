import Foundation
import RillCore

extension RillCLI {
    static func reviewOpenAPI(_ args: Arguments) throws {
        guard args.operands.count == 1, let id = UUID(uuidString: try args.operand()),
            Set(args.values.keys).isSubset(of: ["source", "workspace"]),
            args.flags.isSubset(of: ["json", "quiet", "show-messages"])
        else {
            throw CLIError.usage("Use openapi-review SOURCE_ID --source FILE [--workspace FILE].")
        }
        let source = URL(fileURLWithPath: try args.required("source"))
        let workspace: Workspace
        do {
            workspace = try WorkspaceFile.decode(
                BoundedFileInput.read(args.workspaceURL, limit: ResourceLimits.workspaceBytes))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIError.usage("Could not read the workspace for review. Input content omitted.")
        }
        guard (workspace.apiDefinitions ?? []).contains(where: { $0.id == id }) else {
            throw CLIError.usage("Definition source ID is missing from the workspace.")
        }
        let plan: APIImportPlan
        do {
            let definition = try APIDefinitionLoader.load(source)
            plan = try APIImportPlan(definition, current: workspace, refreshing: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIError.usage(
                "Could not prepare an offline refresh plan. Check the local definition and workspace limits. Input content omitted."
            )
        }
        struct Row: Encodable {
            let method: HTTPMethod
            let baselinePosition: Int?
            let candidatePosition: Int?
            let definitionState: APIDrift
            let workspaceState: APIDrift?
            let linkedRequestID: UUID?
            let operation: String?
        }
        let showOperations = args.flags.contains("show-messages")
        let rows = plan.review.compactMap { item -> Row? in
            guard
                item.definitionState != .unchanged
                    || (item.workspaceState != nil && item.workspaceState != .unchanged)
            else { return nil }
            return Row(
                method: item.method, baselinePosition: item.baselinePosition,
                candidatePosition: item.candidatePosition, definitionState: item.definitionState,
                workspaceState: item.workspaceState, linkedRequestID: item.linkedRequestID,
                operation: showOperations ? item.key : nil)
        }
        if args.flags.contains("json") {
            struct Report: Encodable {
                let schemaVersion = 1
                let sourceID: UUID
                let operations: [Row]
            }
            try args.json(Report(sourceID: id, operations: rows))
        } else {
            var lines = ["OpenAPI refresh review · \(rows.count) operations to review"]
            for row in rows {
                let before = row.baselinePosition.map(String.init) ?? "—"
                let after = row.candidatePosition.map(String.init) ?? "—"
                let workspace = row.workspaceState?.rawValue ?? "no linked change"
                let request = row.linkedRequestID.map { " · request " + $0.uuidString } ?? ""
                let operation = row.operation.map { " · " + RunConsole.label($0, limit: 128) } ?? ""
                lines.append(
                    "\(row.method.rawValue) \(before) → \(after) · \(row.definitionState.rawValue) · \(workspace)\(request)\(operation)"
                )
            }
            try args.text(lines.joined(separator: "\n"))
        }
    }
}
