import Foundation
import Darwin

public enum UploadError: LocalizedError {
    case unavailable, changed, tooLarge, invalidPart, requiresFreeze
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The upload file is missing, unreadable or not a regular file. Select it again."
        case .changed: "The upload file changed since selection. Select it again before sending."
        case .tooLarge: "The complete upload exceeds the 256 MiB limit."
        case .invalidPart: "Multipart names, filenames and MIME types cannot contain control characters. Select a file for each enabled file part."
        case .requiresFreeze: "File bodies require RequestEngine.freeze to retain the prepared streaming body."
        }
    }
}
public struct UploadFileReference: Codable, Equatable, Sendable {
    public var path: String
    public var byteCount: UInt64
    public var modificationDate: Date
    public var fileID: UInt64
    public static func capture(_ url: URL) throws -> Self {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) } catch { throw UploadError.unavailable }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date,
              let id = attributes[.systemFileNumber] as? NSNumber else { throw UploadError.unavailable }
        guard size.uint64Value <= UInt64(UploadBody.maximumBytes) else { throw UploadError.tooLarge }
        return Self(path: url.path, byteCount: size.uint64Value, modificationDate: modified, fileID: id.uint64Value)
    }
    public func validate() throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw UploadError.unavailable }
        guard try Self.capture(URL(fileURLWithPath: path)) == self else { throw UploadError.changed }
    }
}
public enum MultipartPartKind: String, Codable, CaseIterable, Sendable { case text = "Text", json = "JSON", file = "File" }
public struct MultipartPart: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var name = ""
    public var kind: MultipartPartKind = .text
    public var value = ""
    public var filename = ""
    public var contentType = "text/plain"
    public var file: UploadFileReference?
    public init() {}
}

public final class PreparedHTTPRequest: @unchecked Sendable {
    public let request: URLRequest
    public let temporaryBody: URL?
    init(request: URLRequest, temporaryBody: URL? = nil) { self.request = request; self.temporaryBody = temporaryBody }
    public func newBodyStream() -> InputStream? { temporaryBody.flatMap(InputStream.init(url:)) }
    public func removeTemporaryBody() { if let temporaryBody { try? FileManager.default.removeItem(at: temporaryBody) } }
    deinit { removeTemporaryBody() }
}

enum UploadBody {
    static let maximumBytes = 256 * 1024 * 1024
    static func create(_ draft: RequestDraft, environment: Environment?, limit: Int = maximumBytes) throws -> (url: URL, count: Int, contentType: String) {
        guard (1...maximumBytes).contains(limit) else { throw UploadError.tooLarge }
        let variables = environment?.variables.filter { $0.enabled && !$0.name.isEmpty }.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
        var expandedBytes = 0
        func expand(_ value: String) throws -> String {
            let output = try VariableExpansion.resolve(value, values: variables)
            expandedBytes += output.utf8.count
            guard expandedBytes <= ResourceLimits.workspaceBytes else { throw EditingError.expansionLimit }
            return output
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rill-upload-" + UUID().uuidString)
        let descriptor = Darwin.open(directory.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw UploadError.unavailable }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var complete = false, count = 0
        defer { try? output.close(); if !complete { try? FileManager.default.removeItem(at: directory) } }
        func write(_ data: Data) throws {
            try Task.checkCancellation()
            guard data.count <= limit - count else { throw UploadError.tooLarge }
            try output.write(contentsOf: data); count += data.count
        }
        func file(_ reference: UploadFileReference) throws {
            try reference.validate()
            let fd = Darwin.open(reference.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw UploadError.unavailable }
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? input.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  UInt64(info.st_ino) == reference.fileID, info.st_size >= 0,
                  UInt64(info.st_size) == reference.byteCount else { throw UploadError.changed }
            var readCount = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty { try write(chunk); readCount += chunk.count }
            guard UInt64(readCount) == reference.byteCount else { throw UploadError.changed }
            try reference.validate()
            var after = stat()
            guard fstat(fd, &after) == 0, info.st_size == after.st_size,
                  info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw UploadError.changed }
        }
        func quoted(_ value: String) throws -> String {
            guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw UploadError.invalidPart }
            return value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let contentType: String
        if draft.bodyMode == .binary {
            guard let reference = draft.binaryFile else { throw UploadError.unavailable }
            try file(reference)
            contentType = try expand(draft.contentType)
        } else {
            let boundary = "RillBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            contentType = "multipart/form-data; boundary=" + boundary
            for part in draft.multipartParts ?? [] where part.enabled && !part.name.isEmpty {
                let name = try quoted(expand(part.name))
                var header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\""
                if part.kind == .file {
                    guard let reference = part.file else { throw UploadError.invalidPart }
                    let filename = try quoted(expand(part.filename.isEmpty ? URL(fileURLWithPath: reference.path).lastPathComponent : part.filename))
                    header += "; filename=\"\(filename)\""
                }
                let type = part.kind == .json ? "application/json" : try expand(part.contentType)
                guard !type.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw UploadError.invalidPart }
                header += "\r\nContent-Type: \(type)\r\n\r\n"
                try write(Data(header.utf8))
                if part.kind == .file { try file(part.file!) }
                else { try write(Data(expand(part.value).utf8)) }
                try write(Data("\r\n".utf8))
            }
            try write(Data("--\(boundary)--\r\n".utf8))
        }
        guard !contentType.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw UploadError.invalidPart }
        try output.synchronize(); try output.close(); complete = true
        return (directory, count, contentType)
    }
}
