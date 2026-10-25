import Darwin
import Foundation
import RillCore

@main struct RillCLI {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let task = Task { () -> Int32 in
            do {
                let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
                try await execute(arguments)
                return Task.isCancelled ? 130 : 0
            } catch is CancellationError { return 130 } catch CLIError.assertion {
                return 4
            } catch CLIError.usage(let text) {
                try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8))
                return 2
            } catch {
                if Task.isCancelled { return 130 }
                try? FileHandle.standardError.write(
                    contentsOf: Data(
                        ("Operation failed (" + DiagnosticFailure.classify(error).rawValue
                            + "). Check inputs, credentials and endpoint; runtime content omitted.\n")
                            .utf8))
                return 3
            }
        }
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        interrupt.setEventHandler { task.cancel() }
        terminate.setEventHandler { task.cancel() }
        interrupt.resume()
        terminate.resume()
        let status = await task.value
        interrupt.cancel()
        terminate.cancel()
        Darwin.exit(status)
    }
    static func execute(_ args: Arguments) async throws {
        switch args.command {
        case "help": try args.text(usage)
        case "version": try args.text(RillVersion.number)
        case "init":
            guard !FileManager.default.fileExists(atPath: args.workspaceURL.path) else {
                throw CLIError.usage("Workspace already exists.")
            }
            try WorkspaceFile.create(Workspace(), at: args.workspaceURL)
            try args.text("Workspace created")
        case "graphql", "grpc", "sse", "ws", "mock-serve", "share-pull":
            try await protocolCommand(args)
        default: try await workspaceCommand(args)
        }
    }
    static func waitForCancellation() async throws {
        while true { try await Task.sleep(for: .seconds(1)) }
    }
}
