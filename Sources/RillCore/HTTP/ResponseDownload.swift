import Darwin
import Foundation

public struct DownloadResult: Sendable {
    public let status: Int
    public let duration: Double
    public let bodyBytes: Int
}

public enum ResponseDownloadError: Error {
    case unavailable
}

final class ResponseFileSink {
    private let destination: URL
    private let temporary: URL
    private let handle: FileHandle
    private let overwrite: Bool

    init(destination: URL, overwrite: Bool) throws {
        self.destination = destination
        self.overwrite = overwrite
        temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".rill-download-" + UUID().uuidString)
        let descriptor = Darwin.open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ResponseDownloadError.unavailable }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: temporary)
    }

    func stream(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Int {
        let chunkSize = 64 * 1024
        var chunk = Data()
        chunk.reserveCapacity(chunkSize)
        var count = 0
        for try await byte in bytes {
            guard count < limit else { throw RillError.responseTooLarge }
            if count.isMultiple(of: 4096) { try Task.checkCancellation() }
            chunk.append(byte)
            count += 1
            if chunk.count == chunkSize {
                try write(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { try write(chunk) }
        return count
    }

    private func write(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw ResponseDownloadError.unavailable
        }
    }

    func commit() throws {
        try Task.checkCancellation()
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            throw ResponseDownloadError.unavailable
        }
        try Task.checkCancellation()
        let status =
            overwrite
            ? Darwin.rename(temporary.path, destination.path)
            : Darwin.link(temporary.path, destination.path)
        guard status == 0 else { throw ResponseDownloadError.unavailable }
    }
}
