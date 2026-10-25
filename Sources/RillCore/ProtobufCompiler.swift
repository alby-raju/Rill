import Foundation

public enum ProtobufCompiler {
    public static func bundledExecutable() throws -> URL {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("protoc"), Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("protoc")].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw ProtobufError.compilerUnavailable }
        return url
    }
    public static func compile(_ source: URL, importRoots: [URL] = [], compiler: URL? = nil, wellKnownRoot: URL? = nil) async throws -> ProtobufSchema {
        let executable = try compiler ?? bundledExecutable()
        let bundledIncludes = wellKnownRoot ?? Bundle.main.resourceURL?.appendingPathComponent("protobuf-includes")
        let root = source.deletingLastPathComponent().resolvingSymlinksInPath()
        var roots = [root] + importRoots.map { $0.resolvingSymlinksInPath() }
        if let bundledIncludes, FileManager.default.fileExists(atPath: bundledIncludes.path) { roots.append(bundledIncludes.resolvingSymlinksInPath()) }
        guard source.isFileURL, roots.count <= 10, source.pathExtension == "proto" else { throw ProtobufError.malformed }
        let ownedRoots = roots
        let preflight = Task.detached { try inspect(source, roots: ownedRoots) }
        try await withTaskCancellationHandler { try await preflight.value } onCancel: { preflight.cancel() }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("rill-protobuf-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("schema.desc")
        let arguments = ["--descriptor_set_out=" + output.path, "--include_imports"] + roots.map { "--proto_path=" + $0.path } + [source.path]
        let result = try await BoundedProcess.run(executable: executable, arguments: arguments, directory: root, timeout: 10, outputLimit: 65536, diagnosticsLimit: 65536, environment: ["LANG": "en_US.UTF-8", "TMPDIR": temporary.path])
        guard result.status == 0 else {
            let diagnostics = String(decoding: result.diagnostics, as: UTF8.self)
            let pattern = try NSRegularExpression(pattern: #":([0-9]{1,7}):([0-9]{1,7}):"#)
            if let match = pattern.firstMatch(in: diagnostics, range: NSRange(diagnostics.startIndex..., in: diagnostics)),
               let lineRange = Range(match.range(at: 1), in: diagnostics), let columnRange = Range(match.range(at: 2), in: diagnostics),
               let line = Int(diagnostics[lineRange]), let column = Int(diagnostics[columnRange]) { throw ProtobufError.compilationLocation(line, column) }
            throw ProtobufError.compilerFailed
        }
        let worker = Task.detached { try ProtobufSchema(descriptorSet: BoundedFileInput.read(output, limit: 8 * 1024 * 1024)) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private static func inspect(_ source: URL, roots: [URL]) throws {
        var seen: Set<String> = [], bytes = 0
        func visit(_ file: URL, depth: Int) throws {
            try Task.checkCancellation()
            let resolved = file.resolvingSymlinksInPath()
            guard roots.contains(where: { resolved.path.hasPrefix($0.path + "/") }), depth <= 32 else { throw ProtobufError.malformed }
            guard seen.insert(resolved.path).inserted else { return }
            guard seen.count <= 128 else { throw BrokerError.limit }
            let data = try BoundedFileInput.read(file, limit: 1024 * 1024); bytes += data.count
            guard bytes <= 16 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw BrokerError.limit }
            for name in try imports(text) {
                guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw ProtobufError.malformed }
                guard let target = roots.map({ $0.appendingPathComponent(name) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw ProtobufError.missingImport(String(name.prefix(1024))) }
                try visit(target, depth: depth + 1)
            }
        }
        try visit(source, depth: 0)
    }
    private static func imports(_ text: String) throws -> [String] {
        let bytes = Array(text.utf8); var offset = 0, result: [String] = [], importState = 0, tokens = 0
        while offset < bytes.count {
            tokens += 1; guard tokens <= 100000 else { throw BrokerError.limit }
            let next = bytes[offset]
            if next <= 32 { offset += 1; continue }
            if next == 47 && offset + 1 < bytes.count && bytes[offset + 1] == 47 { offset += 2; while offset < bytes.count && bytes[offset] != 10 { offset += 1 }; continue }
            if next == 47 && offset + 1 < bytes.count && bytes[offset + 1] == 42 {
                offset += 2; while offset + 1 < bytes.count && !(bytes[offset] == 42 && bytes[offset + 1] == 47) { offset += 1 }
                guard offset + 1 < bytes.count else { throw ProtobufError.malformed }; offset += 2; continue
            }
            if next == 34 || next == 39 {
                let quote = next; offset += 1; let start = offset; var escaped = false
                while offset < bytes.count && bytes[offset] != quote { if bytes[offset] == 92 { escaped = true; offset += 1 }; offset += 1 }
                guard offset < bytes.count else { throw ProtobufError.malformed }
                if importState > 0 { guard !escaped, let path = String(bytes: bytes[start..<offset], encoding: .utf8) else { throw ProtobufError.malformed }; result.append(path) }
                importState = 0; offset += 1; continue
            }
            if (65...90).contains(next) || (97...122).contains(next) || next == 95 {
                let start = offset; offset += 1
                while offset < bytes.count && ((65...90).contains(bytes[offset]) || (97...122).contains(bytes[offset]) || (48...57).contains(bytes[offset]) || bytes[offset] == 95) { offset += 1 }
                let token = String(decoding: bytes[start..<offset], as: UTF8.self)
                if token == "import" { importState = 1 } else if importState == 1 && (token == "public" || token == "weak") { importState = 2 } else { importState = 0 }
            } else { importState = 0; offset += 1 }
        }
        return result
    }
}
