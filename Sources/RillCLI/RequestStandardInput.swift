import Darwin
import Foundation

enum RequestStandardInput {
    static func read(timeout: Double) async throws -> String {
        guard isatty(STDIN_FILENO) == 0 else {
            throw CLIError.usage("--stdin requires a pipe or redirected input.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let limit = 1024 * 1024
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw CLIError.usage("Timed out reading standard input.")
            }
            let ready = Darwin.poll(&descriptor, 1, 0)
            if ready == 0 {
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else {
                throw CLIError.usage("Could not read standard input.")
            }
            let count = Darwin.read(
                STDIN_FILENO, &buffer, min(buffer.count, limit - data.count + 1))
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count + count <= limit else {
                throw CLIError.usage("Standard input is unreadable or exceeds 1 MiB.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError.usage("Standard input must be UTF-8.")
        }
        return text
    }
}
