import Darwin
import Foundation

public enum ProcessRunError: LocalizedError {
    case configuration, timeout, limit
    public var errorDescription: String? {
        switch self {
        case .configuration: "Invalid native process configuration."
        case .timeout: "The native operation exceeded its deadline."
        case .limit: "The native operation exceeded its bounded output limit."
        }
    }
}
public struct ProcessRunResult: Sendable {
    public let status: Int32
    public let output: Data
    public let diagnostics: Data
}
private final class ProcessRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var failure: Error?
    private var output = Data(), diagnostics = Data()
    let outputLimit: Int, diagnosticsLimit: Int
    init(outputLimit: Int, diagnosticsLimit: Int) {
        self.outputLimit = outputLimit
        self.diagnosticsLimit = diagnosticsLimit
    }
    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        try process.run()
        self.process = process
    }
    func append(_ data: Data, diagnostic: Bool) {
        lock.lock()
        let used = diagnostic ? diagnostics.count : output.count
        let limit = diagnostic ? diagnosticsLimit : outputLimit
        if data.count <= limit - used {
            if diagnostic { diagnostics += data } else { output += data }
            lock.unlock()
        } else {
            lock.unlock()
            cancel(ProcessRunError.limit)
        }
    }
    func cancel(_ error: Error) {
        lock.lock()
        guard failure == nil else {
            lock.unlock()
            return
        }
        failure = error
        let process = process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
    func result(_ status: Int32) throws -> ProcessRunResult {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        return ProcessRunResult(status: status, output: output, diagnostics: diagnostics)
    }
}
/// Explicit executable/argv only. No shell, inherited credentials, stdin scripts or hidden PATH lookup.
public enum BoundedProcess {
    public static func run(
        executable: URL, arguments: [String], directory: URL? = nil, input: Data = Data(),
        timeout: Double = 10,
        outputLimit: Int = 1024 * 1024, diagnosticsLimit: Int = 65536,
        environment: [String: String] = [:]
    ) async throws -> ProcessRunResult {
        guard executable.isFileURL, arguments.count <= 512,
            arguments.reduce(0, { $0 + $1.utf8.count }) <= 1024 * 1024,
            !arguments.contains(where: { $0.contains("\0") }), input.count <= 16 * 1024 * 1024,
            timeout.isFinite, (0.1...300).contains(timeout),
            (0...(32 * 1024 * 1024)).contains(outputLimit),
            (0...(1024 * 1024)).contains(diagnosticsLimit)
        else { throw ProcessRunError.configuration }
        let control = ProcessRunControl(
            outputLimit: outputLimit, diagnosticsLimit: diagnosticsLimit)
        let worker = Task.detached {
            try execute(
                control, executable: executable, arguments: arguments, directory: directory,
                input: input, environment: environment)
        }
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
                control.cancel(ProcessRunError.timeout)
            } catch {}
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await worker.value
        } onCancel: {
            control.cancel(CancellationError())
            worker.cancel()
        }
    }
    private static func execute(
        _ control: ProcessRunControl, executable: URL, arguments: [String], directory: URL?,
        input: Data, environment: [String: String]
    ) throws -> ProcessRunResult {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        try control.start(process)
        let group = DispatchGroup()
        for (handle, diagnostic) in [
            (standardOutput.fileHandleForReading, false),
            (standardError.fileHandleForReading, true),
        ] {
            group.enter()
            DispatchQueue.global().async {
                defer {
                    try? handle.close()
                    group.leave()
                }
                do {
                    while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
                        control.append(bytes, diagnostic: diagnostic)
                    }
                } catch { control.cancel(error) }
            }
        }
        group.enter()
        DispatchQueue.global().async {
            defer {
                try? standardInput.fileHandleForWriting.close()
                group.leave()
            }
            do {
                if !input.isEmpty {
                    try standardInput.fileHandleForWriting.write(contentsOf: input)
                }
            } catch { if process.isRunning { control.cancel(error) } }
        }
        process.waitUntilExit()
        group.wait()
        return try control.result(process.terminationStatus)
    }

}
