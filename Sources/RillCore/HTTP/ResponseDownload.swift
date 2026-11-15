import Darwin
import Foundation

public struct DownloadResult: Sendable {
    public let status: Int
    public let duration: Double
    public let bodyBytes: Int
}

public enum ResponseDownloadError: Error {
    case unavailable, invalidResumeResponse
}

final class ResponseFileSink {
    private let destination: URL
    private let temporary: URL
    private let handle: FileHandle
    private let overwrite: Bool
    private let resume: ResumeSource?
    private var expectedSuffix: Int?

    init(destination: URL, overwrite: Bool, resumeETag: String?) throws {
        self.destination = destination
        self.overwrite = overwrite || resumeETag != nil
        resume = try resumeETag.map { try ResumeSource(destination, etag: $0) }
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

    func configure(_ request: inout URLRequest) throws {
        guard let resume else { return }
        for name in ["Range", "If-Range", "Accept-Encoding"] {
            guard request.value(forHTTPHeaderField: name) == nil else {
                throw ResponseDownloadError.unavailable
            }
        }
        request.setValue("bytes=\(resume.size)-", forHTTPHeaderField: "Range")
        request.setValue(resume.etag, forHTTPHeaderField: "If-Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    func prepareResponse(_ response: HTTPURLResponse, limit: Int) throws -> Int {
        guard let resume else { return 0 }
        if response.statusCode == 200 { return 0 }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard response.statusCode == 206, encoding == nil || encoding == "identity",
            response.value(forHTTPHeaderField: "ETag") == resume.etag,
            let range = response.value(forHTTPHeaderField: "Content-Range"),
            range.hasPrefix("bytes "),
            let total = Int(range.split(separator: "/").last ?? ""),
            total > resume.size, total <= limit,
            range == "bytes \(resume.size)-\(total - 1)/\(total)"
        else { throw ResponseDownloadError.invalidResumeResponse }
        try resume.copy(to: handle)
        expectedSuffix = total - resume.size
        return resume.size
    }

    func validateCompletion(received: Int) throws {
        if let expectedSuffix, received != expectedSuffix {
            throw ResponseDownloadError.invalidResumeResponse
        }
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
        try resume?.validate()
        let status =
            overwrite
            ? Darwin.rename(temporary.path, destination.path)
            : Darwin.link(temporary.path, destination.path)
        guard status == 0 else { throw ResponseDownloadError.unavailable }
    }
}

private final class ResumeSource {
    let etag: String
    let size: Int
    private let info: stat
    private let source: URL
    private let handle: FileHandle

    init(_ source: URL, etag: String) throws {
        let bytes = etag.utf8
        guard (2...1024).contains(bytes.count), bytes.first == 34, bytes.last == 34,
            bytes.dropFirst().dropLast().allSatisfy({ $0 == 33 || (35...126).contains($0) })
        else { throw ResponseDownloadError.unavailable }
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ResponseDownloadError.unavailable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0,
            fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            (1..<(256 * 1024 * 1024)).contains(info.st_size)
        else { throw ResponseDownloadError.unavailable }
        self.etag = etag
        size = Int(info.st_size)
        self.info = info
        self.source = source
        handle = file
    }

    func copy(to destination: FileHandle) throws {
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: min(remaining, 64 * 1024)), !data.isEmpty
            else { throw ResponseDownloadError.unavailable }
            try destination.write(contentsOf: data)
            remaining -= data.count
        }
        try validate()
    }

    func validate() throws {
        var current = stat()
        guard lstat(source.path, &current) == 0, current.st_dev == info.st_dev,
            current.st_ino == info.st_ino, current.st_size == info.st_size,
            current.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
            current.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
            current.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
            current.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec
        else { throw ResponseDownloadError.unavailable }
    }
}
