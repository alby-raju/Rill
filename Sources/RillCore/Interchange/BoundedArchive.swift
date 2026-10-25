import Foundation
import ZIPFoundation

public enum ArchiveImportError: LocalizedError {
    case invalid, unsupported, unsafePath, limit, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalid: "The archive is corrupt or its metadata, sizes or checksums disagree."
        case .unsupported: "The input uses an unsupported archive/filesystem representation: encryption, ZIP64, non-UTF-8 paths, links, special files or nested archives."
        case .unavailable: "The selected input is missing, unreadable or changed. Reselect it before importing."
        case .unsafePath: "An input contains an unsafe, duplicate or conflicting path. Nothing was extracted."
        case .limit: "Import exceeds 32 MiB total, 4 MiB per file, 4,096 entries, 16 path components or 1,024 path bytes."
        }
    }
}
public struct ImportFile: Sendable {
    public let path: String
    public let data: Data
    public init(path: String, data: Data) { self.path = path; self.data = data }
}
public enum BoundedArchive {
    public static let fileBytes = 4 * 1024 * 1024
    public static let totalBytes = 32 * 1024 * 1024
    public static let entryCount = 4096
    static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
    static func components(_ path: String) throws -> [String] {
        guard path.utf8.count <= 1024 else { throw ArchiveImportError.limit }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ArchiveImportError.unsafePath }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 16 else { throw ArchiveImportError.limit }
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ArchiveImportError.unsafePath }
        return parts
    }
    private struct Record {
        let path: String
        let size: Int
        let crc: UInt32
        let directory: Bool
    }
    public static func readZIP(_ input: Data) throws -> [ImportFile] {
        try Task.checkCancellation()
        guard input.count <= totalBytes else { throw ArchiveImportError.limit }
        let records = try inspect(Array(input))
        let archive: Archive
        do { archive = try Archive(data: input, accessMode: .read, pathEncoding: .utf8) } catch { throw ArchiveImportError.invalid }
        var output: [ImportFile] = [], index = 0, expanded = 0
        for entry in archive {
            try Task.checkCancellation()
            guard index < records.count else { throw ArchiveImportError.invalid }
            let record = records[index]; index += 1
            guard entry.path == record.path, entry.uncompressedSize == UInt64(record.size), entry.checksum == record.crc else { throw ArchiveImportError.invalid }
            guard entry.type == (record.directory ? .directory : .file) else { throw ArchiveImportError.unsupported }
            if record.directory { continue }
            var data = Data()
            let checksum: UInt32
            do {
                checksum = try archive.extract(entry, bufferSize: 65536, skipCRC32: false) { chunk in
                    try Task.checkCancellation()
                    guard chunk.count <= fileBytes - data.count, chunk.count <= totalBytes - expanded else { throw ArchiveImportError.limit }
                    data.append(chunk); expanded += chunk.count
                }
            } catch let error as ArchiveImportError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch { throw ArchiveImportError.invalid }
            guard data.count == record.size, checksum == record.crc else { throw ArchiveImportError.invalid }
            output.append(ImportFile(path: record.path, data: data))
        }
        guard index == records.count else { throw ArchiveImportError.invalid }
        return output
    }
    private static func inspect(_ bytes: [UInt8]) throws -> [Record] {
        guard bytes.count >= 22 else { throw ArchiveImportError.invalid }
        func value(_ offset: Int, _ count: Int) throws -> UInt64 {
            guard offset >= 0, count <= bytes.count, offset <= bytes.count - count else { throw ArchiveImportError.invalid }
            return (0..<count).reduce(0) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
        }
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
            if try value(offset, 4) == 0x06054b50, offset + 22 + Int(try value(offset + 20, 2)) == bytes.count { end = offset; break }
        }
        guard let end else { throw ArchiveImportError.invalid }
        guard try value(end + 4, 2) == 0, try value(end + 6, 2) == 0 else { throw ArchiveImportError.unsupported }
        let count = Int(try value(end + 10, 2)), directory = Int(try value(end + 16, 4)), directorySize = Int(try value(end + 12, 4))
        guard count != 65535, directory != Int(UInt32.max), directorySize != Int(UInt32.max) else { throw ArchiveImportError.unsupported }
        guard count > 0, count <= entryCount else { throw ArchiveImportError.limit }
        guard try value(end + 8, 2) == UInt64(count), directory <= end, directorySize == end - directory else { throw ArchiveImportError.invalid }
        var cursor = directory, total = 0, names = Set<String>(), files = Set<String>(), paths: [[String]] = [], ranges: [Range<Int>] = [], records: [Record] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            guard try value(cursor, 4) == 0x02014b50 else { throw ArchiveImportError.invalid }
            let flags = try value(cursor + 8, 2), method = try value(cursor + 10, 2), crc = UInt32(try value(cursor + 16, 4))
            let compressed = Int(try value(cursor + 20, 4)), size = Int(try value(cursor + 24, 4))
            let nameLength = Int(try value(cursor + 28, 2)), extraLength = Int(try value(cursor + 30, 2)), commentLength = Int(try value(cursor + 32, 2))
            let attributes = try value(cursor + 38, 4), local = Int(try value(cursor + 42, 4)), mode = (attributes >> 16) & 0xf000
            guard flags & ~UInt64(0x080e) == 0, [0, 8].contains(method), try value(cursor + 34, 2) == 0, [0, 0x4000, 0x8000].contains(mode) else { throw ArchiveImportError.unsupported }
            guard size <= fileBytes, size <= totalBytes - total, nameLength <= 1024 else { throw ArchiveImportError.limit }; total += size
            let recordEnd = cursor + 46 + nameLength + extraLength + commentLength
            guard recordEnd <= end, cursor + 46 <= recordEnd else { throw ArchiveImportError.invalid }
            guard let path = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8) else { throw ArchiveImportError.unsupported }
            let parts = try components(path), normalized = key(parts.joined(separator: "/"))
            guard names.insert(normalized).inserted else { throw ArchiveImportError.unsafePath }
            guard !["zip", "rillbackup", "tar", "gz", "7z", "rar"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { throw ArchiveImportError.unsupported }
            let isDirectory = path.hasSuffix("/") || mode == 0x4000 || attributes & 0x10 != 0
            guard !isDirectory || (size == 0 && compressed == 0) else { throw ArchiveImportError.invalid }
            if !isDirectory { files.insert(normalized) }; paths.append(parts)
            var extra = cursor + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra < extraEnd {
                guard extra + 4 <= extraEnd else { throw ArchiveImportError.invalid }
                guard try value(extra, 2) != 1 else { throw ArchiveImportError.unsupported }
                extra += 4 + Int(try value(extra + 2, 2)); guard extra <= extraEnd else { throw ArchiveImportError.invalid }
            }
            guard local < directory, try value(local, 4) == 0x04034b50, try value(local + 6, 2) == flags, try value(local + 8, 2) == method else { throw ArchiveImportError.invalid }
            let localName = Int(try value(local + 26, 2)), localExtra = Int(try value(local + 28, 2)), start = local + 30 + localName + localExtra
            guard localName == nameLength, start <= directory, compressed <= directory - start,
                  bytes[(local + 30)..<(local + 30 + localName)] == bytes[(cursor + 46)..<(cursor + 46 + nameLength)] else { throw ArchiveImportError.invalid }
            var rangeEnd = start + compressed
            if flags & 8 == 0 {
                guard try value(local + 14, 4) == UInt64(crc), try value(local + 18, 4) == UInt64(compressed), try value(local + 22, 4) == UInt64(size) else { throw ArchiveImportError.invalid }
            } else {
                if try value(rangeEnd, 4) == 0x08074b50 { rangeEnd += 4 }
                guard try value(rangeEnd, 4) == UInt64(crc), try value(rangeEnd + 4, 4) == UInt64(compressed), try value(rangeEnd + 8, 4) == UInt64(size) else { throw ArchiveImportError.invalid }
                rangeEnd += 12; guard rangeEnd <= directory else { throw ArchiveImportError.invalid }
            }
            ranges.append(local..<rangeEnd); records.append(Record(path: path, size: size, crc: crc, directory: isDirectory)); cursor = recordEnd
        }
        guard cursor == end else { throw ArchiveImportError.invalid }
        var priorEnd = 0
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) { guard range.lowerBound == priorEnd else { throw ArchiveImportError.invalid }; priorEnd = range.upperBound }
        guard priorEnd == directory else { throw ArchiveImportError.invalid }
        for parts in paths {
            for length in 1..<parts.count { guard !files.contains(key(parts.prefix(length).joined(separator: "/"))) else { throw ArchiveImportError.unsafePath } }
        }
        return records
    }
}
