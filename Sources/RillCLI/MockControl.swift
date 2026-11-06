import Darwin
import Foundation
import RillCore

struct MockControlOutput: Encodable {
    var schemaVersion = 1
    let state: String
    var baseURL: String?
    var routeCount: Int?
    var requestCount: Int?
    func write(quiet: Bool) throws {
        guard !quiet else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(self) + Data([10]))
    }
}
extension RillCLI {
    /// Explicit pipe protocol, never an HTTP administration endpoint. EOF also stops the server.
    static func mockControl(server: MockServer, args: Arguments) async throws {
        let worker = Task.detached {
            let descriptor = dup(STDIN_FILENO)
            guard descriptor >= 0 else { throw CLIError.runtime }
            defer { close(descriptor) }
            var line = Data()
            while true {
                try Task.checkCancellation()
                var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptorState, 1, 100)
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw CLIError.runtime
                }
                var byte: UInt8 = 0
                let count = read(descriptor, &byte, 1)
                if count == 0 { return }
                guard count == 1 else { throw CLIError.runtime }
                if byte != 10 {
                    guard line.count < 64 else {
                        throw CLIError.usage("Mock control command exceeds 64 bytes.")
                    }
                    line.append(byte)
                    continue
                }
                let command = String(data: line, encoding: .utf8)
                line.removeAll(keepingCapacity: true)
                switch command {
                case "stop": return
                case "reset":
                    await server.resetScenarios()
                    try MockControlOutput(state: "reset").write(quiet: args.quiet)
                case "status":
                    try MockControlOutput(state: "ready", requestCount: await server.requestCount())
                        .write(quiet: args.quiet)
                default:
                    throw CLIError.usage(
                        "Mock control accepts status, reset or stop followed by a newline.")
                }
            }
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
