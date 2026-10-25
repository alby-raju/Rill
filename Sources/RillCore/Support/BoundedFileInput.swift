import Darwin
import Foundation

public enum BoundedFileInput {
    public static func read(_ url: URL, limit: Int = BoundedArchive.fileBytes) throws -> Data {
        try Task.checkCancellation()
        guard (1...BoundedArchive.totalBytes).contains(limit) else {
            throw ArchiveImportError.limit
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ArchiveImportError.unavailable }
        return try consume(descriptor, limit: limit)
    }
    public static func brunoFolder(_ location: URL) throws -> [ImportFile] {
        try Task.checkCancellation()
        let selected = location.standardizedFileURL
        let descriptor = Darwin.open(selected.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ArchiveImportError.unavailable }
        defer { Darwin.close(descriptor) }
        // Canonicalize ancestor aliases only after refusing a selected root symlink.
        guard let canonical = Darwin.realpath(selected.path, nil) else {
            throw ArchiveImportError.invalid
        }
        let physicalPath = String(cString: canonical)
        free(canonical)
        let root = URL(fileURLWithPath: physicalPath, isDirectory: true)
        let failure = EnumerationFailure()
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                errorHandler: { _, _ in
                    failure.mark()
                    return false
                })
        else { throw ArchiveImportError.invalid }
        var output: [ImportFile] = []
        var total = 0
        var count = 0
        var names = Set<String>()
        let prefix = physicalPath.hasSuffix("/") ? physicalPath : physicalPath + "/"
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            count += 1
            guard count <= BoundedArchive.entryCount, url.path.hasPrefix(prefix) else {
                throw ArchiveImportError.limit
            }
            let relative = String(url.path.dropFirst(prefix.count))
            let parts = try BoundedArchive.components(relative)
            guard names.insert(BoundedArchive.key(relative)).inserted else {
                throw ArchiveImportError.unsafePath
            }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else { throw ArchiveImportError.unsupported }
            if values.isDirectory == true {
                if [".git", "node_modules"].contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { throw ArchiveImportError.unsupported }
            // Import only collection metadata/source. Never open a referenced upload.
            guard url.pathExtension.lowercased() == "bru" || url.lastPathComponent == "bruno.json"
            else { continue }
            var parent = Darwin.dup(descriptor)
            guard parent >= 0 else { throw ArchiveImportError.invalid }
            defer { Darwin.close(parent) }
            for component in parts.dropLast() {
                let next = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw ArchiveImportError.unsupported }
                Darwin.close(parent)
                parent = next
            }
            let file = Darwin.openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard file >= 0 else { throw ArchiveImportError.unsupported }
            let data = try consume(file, limit: BoundedArchive.fileBytes)
            guard data.count <= BoundedArchive.totalBytes - total else {
                throw ArchiveImportError.limit
            }
            total += data.count
            output.append(ImportFile(path: relative, data: data))
        }
        guard !failure.failed else { throw ArchiveImportError.invalid }
        return output.sorted { $0.path < $1.path }
    }
    private static func consume(_ descriptor: Int32, limit: Int) throws -> Data {
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw ArchiveImportError.unsupported
        }
        guard before.st_size >= 0, before.st_size <= limit else { throw ArchiveImportError.limit }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ArchiveImportError.invalid }
            if count == 0 { break }
            guard count <= limit - output.count else { throw ArchiveImportError.limit }
            output.append(contentsOf: chunk.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_size == after.st_size, after.st_size == output.count,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        else { throw ArchiveImportError.invalid }
        return output
    }
}
private final class EnumerationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.withLock { value = true } }
    var failed: Bool { lock.withLock { value } }
}
