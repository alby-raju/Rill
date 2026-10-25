import Foundation

public struct ResponseSettings: Codable, Equatable, Sendable {
    public var downloadBytes = ResourceLimits.responseBytes
    public var previewBytes = ResourceLimits.previewBytes
    public var sessionBytes = ResourceLimits.historyBytes
    public var sessionCount = ResourceLimits.historyCount
    public var recordSnapshots = false
    public var retainSnapshotBodies = false
    public var snapshotBodyBytes = ResourceLimits.previewBytes
    public var snapshotTotalBodyBytes = 8 * 1024 * 1024
    public var snapshotCount = 50
    public init() {}
    public func validate() throws {
        guard (1...(256 * 1024 * 1024)).contains(downloadBytes),
            (128...(8 * 1024 * 1024)).contains(previewBytes),
            (1...(256 * 1024 * 1024)).contains(sessionBytes), (0...500).contains(sessionCount),
            (0...(8 * 1024 * 1024)).contains(snapshotBodyBytes),
            (1...(16 * 1024 * 1024)).contains(snapshotTotalBodyBytes),
            (1...500).contains(snapshotCount)
        else { throw RillError.invalidLimits }
    }
}
public enum ResponseKind: String, Sendable {
    case json = "JSON", xml = "XML", html = "HTML source", image = "Raster image", text = "Text",
        binary = "Binary"
}
public enum ResponseInspection {
    public static func mimeType(_ exchange: Exchange) -> String {
        exchange.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?
            .value.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
            .lowercased() ?? ""
    }
    public static func kind(_ exchange: Exchange) -> ResponseKind {
        let mime = mimeType(exchange)
        let data = exchange.body.prefix(exchange.previewByteLimit)
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            || data.starts(with: [255, 216, 255]) || data.starts(with: Data("GIF8".utf8))
        {
            return .image
        }
        if mime == "application/octet-stream" || data.contains(0) { return .binary }
        if mime.contains("json") { return .json }
        if mime.contains("html") { return .html }
        if mime.contains("xml") { return .xml }
        if mime.hasPrefix("text/") { return .text }
        guard let text = String(data: data, encoding: .utf8) else { return .binary }
        if mime.contains("json")
            || text.trimmingCharacters(in: .whitespacesAndNewlines).first.map({
                $0 == "{" || $0 == "["
            }) == true
        {
            return .json
        }
        if mime.contains("html") { return .html }
        if mime.contains("xml") || text.hasPrefix("<?xml") { return .xml }
        return .text
    }
    public static func hex(_ data: Data) -> String {
        stride(from: 0, to: min(data.count, 4096), by: 16).map { start in
            String(format: "%08x  ", start)
                + data[start..<min(start + 16, data.count)].map { String(format: "%02x", $0) }
                .joined(separator: " ")
        }.joined(separator: "\n")
    }
    static func maskedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return "[unavailable]" }
        if let items = components.queryItems {
            components.queryItems = items.map { URLQueryItem(name: $0.name, value: "[redacted]") }
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        return components.url?.absoluteString ?? "[unavailable]"
    }
    public static func snapshot(_ exchange: Exchange, settings: ResponseSettings) -> Exchange {
        var snapshot = exchange
        snapshot.url = maskedURL(exchange.url)
        snapshot.headers = snapshot.headers.map { field in
            var copy = field
            let safeTypes = [
                "application/json", "application/xml", "text/xml", "text/html", "text/plain",
                "image/png", "image/jpeg", "image/gif", "application/octet-stream",
            ]
            let type = mimeType(exchange)
            copy.value =
                field.name.lowercased() == "content-type" && safeTypes.contains(type)
                ? type : "[redacted]"
            return copy
        }
        snapshot.checks = snapshot.checks.enumerated().map {
            CheckResult(title: "Check \($0.offset + 1)", passed: $0.element.passed)
        }
        if var summary = snapshot.preparedRequest {
            summary.url = maskedURL(summary.url)
            summary.headers = summary.headers.map { field in
                var copy = field
                copy.value = "[redacted]"
                return copy
            }
            snapshot.preparedRequest = summary
        }
        snapshot.events = snapshot.events?.enumerated().map {
            let allowed = [
                "Prepared request; transport started", "Response headers received",
                "Response body complete",
            ]
            return ExecutionEvent(
                elapsed: $0.element.elapsed,
                title: allowed.contains($0.element.title)
                    ? $0.element.title : "Transport event \($0.offset + 1)")
        }
        let original = exchange.originalBodyBytes ?? exchange.body.count
        snapshot.body =
            settings.retainSnapshotBodies
            ? Data(
                exchange.body.prefix(
                    min(settings.snapshotBodyBytes, settings.snapshotTotalBodyBytes))) : Data()
        snapshot.originalBodyBytes = original
        snapshot.bodyWasTruncated =
            snapshot.body.count < original || exchange.bodyWasTruncated == true
        snapshot.previewLimit = settings.previewBytes
        return snapshot
    }
}

private struct HistoryFile: Codable {
    var version = 1
    var exchanges: [Exchange] = []
}
public actor ExchangeHistory {
    private let url: URL
    private var revision: WorkspaceRevision?
    private var entries: [Exchange] = []
    public init(url: URL) { self.url = url }
    public func open() throws -> [Exchange] {
        if revision != nil { return entries }
        return try WorkspaceFileLock.withLock(at: url) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                revision = .absent
                return []
            }
            let data = try WorkspaceFile.readBounded(from: url)
            try WorkspaceFile.checkJSONBounds(data)
            let archive = try JSONDecoder().decode(HistoryFile.self, from: data)
            guard archive.version == 1, archive.exchanges.count <= 500 else {
                throw WorkspaceError.invalidStructure
            }
            var workspace = Workspace()
            workspace.history = archive.exchanges
            try WorkspaceFile.validate(workspace)
            entries = archive.exchanges
            revision = WorkspaceRevision(data: data)
            return entries
        }
    }
    public func record(_ exchange: Exchange, settings: ResponseSettings) throws {
        try settings.validate()
        _ = try open()
        var updated = entries
        updated.removeAll { $0.id == exchange.id }
        updated.insert(ResponseInspection.snapshot(exchange, settings: settings), at: 0)
        while updated.count > settings.snapshotCount
            || updated.reduce(0, { $0 + $1.body.count }) > settings.snapshotTotalBodyBytes
        { updated.removeLast() }
        try commit(updated)
    }
    public func apply(settings: ResponseSettings) throws {
        try settings.validate()
        _ = try open()
        var updated = entries.map { ResponseInspection.snapshot($0, settings: settings) }
        while updated.count > settings.snapshotCount
            || updated.reduce(0, { $0 + $1.body.count }) > settings.snapshotTotalBodyBytes
        { updated.removeLast() }
        try commit(updated)
    }
    public func clear() throws {
        _ = try open()
        try commit([])
    }
    private func commit(_ updated: [Exchange]) throws {
        guard let revision else { throw WorkspaceError.unavailable }
        var updated = updated
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var encodedSizes = try updated.map { try encoder.encode($0).count + 1 }
        var estimatedBytes = encodedSizes.reduce(128, +)
        while estimatedBytes > ResourceLimits.workspaceBytes && !updated.isEmpty {
            updated.removeLast()
            estimatedBytes -= encodedSizes.removeLast()
        }
        let data = try encoder.encode(HistoryFile(exchanges: updated))
        try WorkspaceFileLock.withLock(at: url) {
            let existing =
                FileManager.default.fileExists(atPath: url.path)
                ? try WorkspaceFile.readBounded(from: url) : nil
            guard (existing.map(WorkspaceRevision.init(data:)) ?? .absent) == revision else {
                throw WorkspaceError.conflict
            }
            try WorkspaceFile.atomicWrite(data, to: url)
            self.revision = WorkspaceRevision(data: data)
            entries = updated
        }
    }
}
