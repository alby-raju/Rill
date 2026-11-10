import Foundation
import RillCore

extension RillCLI {
    static func generateMock(_ args: Arguments) throws {
        guard args.operands.count == 1, Set(args.values.keys).isSubset(of: ["output", "seed"]),
            args.flags.isSubset(of: ["overwrite", "json", "quiet"])
        else { throw CLIError.usage("Use mock-generate FILE --output PROJECT [--seed UINT64].") }
        let source = URL(fileURLWithPath: try args.operand())
        let output = try args.required("output")
        guard !args.protectsFileRunInput(URL(fileURLWithPath: output)) else {
            throw CLIError.usage("Mock output cannot replace the input definition.")
        }
        let seed = try args.value("seed").map { value in
            guard let seed = UInt64(value) else {
                throw CLIError.usage("--seed requires an unsigned 64-bit integer.")
            }
            return seed
        }
        let project: MockProject
        let data: Data
        do {
            let input = try BoundedFileInput.read(source, limit: 8 * 1024 * 1024)
            project = try DefinitionMocks.project(from: input, seed: seed)
            data = try MockProjectFile.encode(project)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIError.usage(
                "Could not generate a bounded mock project. Supply a local OpenAPI/Swagger definition with a supported 2xx response. Definition content omitted."
            )
        }
        try Task.checkCancellation()
        try args.write(data, to: output)
        if args.flags.contains("json") {
            struct Summary: Encodable {
                let schemaVersion = 1
                let routeCount: Int
                let seeded: Bool
            }
            try args.json(Summary(routeCount: project.routes.count, seeded: seed != nil))
        } else {
            try args.text("Generated \(project.routes.count) mock routes.")
        }
    }
}
