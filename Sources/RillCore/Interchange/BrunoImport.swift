import Foundation

public enum BrunoImportError: LocalizedError {
    case invalid, unsupported
    public var errorDescription: String? {
        switch self {
        case .invalid:
            "Expected a bounded .bru request/environment or a collection folder/ZIP containing one bruno.json."
        case .unsupported:
            "This Bru representation uses unsupported blocks, indentation, inheritance, auth, path parameters or body/file semantics. No data was applied."
        }
    }
}
struct BruDocument {
    var blocks: [String: [String]] = [:]
    var arrays = Set<String>()
    init(_ data: Data) throws {
        guard data.count <= BoundedArchive.fileBytes,
            let text = String(data: data, encoding: .utf8), !text.contains("\0")
        else { throw BrunoImportError.invalid }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.count <= 100_000 else { throw ArchiveImportError.limit }
        let opener = try NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z0-9_:-]*)\s*([\{\[])\s*$"#)
        var index = 0
        while index < lines.count {
            try Task.checkCancellation()
            let line = lines[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            guard
                let match = opener.firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line)),
                let nameRange = Range(match.range(at: 1), in: line),
                let typeRange = Range(match.range(at: 2), in: line)
            else { throw BrunoImportError.unsupported }
            let name = String(line[nameRange])
            let array = line[typeRange] == "["
            let closing = array ? "]" : "}"
            guard blocks[name] == nil else { throw BrunoImportError.unsupported }
            var content: [String] = []
            var ended = false
            while index < lines.count {
                let value = lines[index]
                index += 1
                if value == closing {
                    ended = true
                    break
                }
                if value.isEmpty {
                    content.append("")
                    continue
                }
                guard value.hasPrefix("  ") else { throw BrunoImportError.unsupported }
                content.append(String(value.dropFirst(2)))
            }
            guard ended else { throw BrunoImportError.invalid }
            blocks[name] = content
            if array { arrays.insert(name) }
        }
    }
    func fields(_ name: String) throws -> [Field] {
        guard !arrays.contains(name) else { throw BrunoImportError.unsupported }
        let lines = blocks[name] ?? []
        var output: [Field] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("@description(") {
                if !line.hasSuffix("''')") {
                    while index < lines.count && !lines[index].hasSuffix("''')") { index += 1 }
                    guard index < lines.count else { throw BrunoImportError.invalid }
                    index += 1
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { throw BrunoImportError.unsupported }
            var key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(
                in: .whitespaces)
            let enabled = !key.hasPrefix("~")
            if !enabled { key.removeFirst() }
            guard !key.isEmpty, !key.contains("\""), !key.contains("'") else {
                throw BrunoImportError.invalid
            }
            if name == "meta" && key == "tags" && value == "[" {
                while index < lines.count
                    && lines[index].trimmingCharacters(in: .whitespaces) != "]"
                { index += 1 }
                guard index < lines.count else { throw BrunoImportError.invalid }
                index += 1
                continue
            }
            if value == "'''" {
                var content: [String] = []
                while index < lines.count
                    && lines[index].trimmingCharacters(in: .whitespaces) != "'''"
                {
                    content.append(lines[index])
                    index += 1
                }
                guard index < lines.count else { throw BrunoImportError.invalid }
                index += 1
                value = content.map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }.joined(
                    separator: "\n")
            } else if value.hasPrefix("'''") {
                guard value.count >= 6, value.hasSuffix("'''") else {
                    throw BrunoImportError.unsupported
                }
                value = String(value.dropFirst(3).dropLast(3))
            }
            var field = Field(name: key, value: value)
            field.enabled = enabled
            output.append(field)
            guard output.count <= 10_000 else { throw ArchiveImportError.limit }
        }
        return output
    }
    func secrets() throws -> Set<String> {
        guard blocks["vars:secret"] == nil || arrays.contains("vars:secret") else {
            throw BrunoImportError.unsupported
        }
        var names = Set<String>()
        var token = ""
        var separators = 0
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        func finish() throws {
            separators += 1
            guard separators <= 10_001 else { throw ArchiveImportError.limit }
            let name = token.trimmingCharacters(in: .whitespaces)
            token = ""
            if name.isEmpty { return }
            guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw BrunoImportError.unsupported
            }
            names.insert(name)
        }
        for line in blocks["vars:secret"] ?? [] {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            for character in line {
                if character == "," { try finish() } else { token.append(character) }
                guard token.utf8.count <= 1024 else { throw ArchiveImportError.limit }
            }
            try finish()
            try Task.checkCancellation()
        }
        return names
    }
    func dictionary(_ name: String) throws -> [String: String] {
        let values = try fields(name)
        guard values.allSatisfy(\.enabled), Set(values.map(\.name)).count == values.count else {
            throw BrunoImportError.unsupported
        }
        return Dictionary(uniqueKeysWithValues: values.map { ($0.name, $0.value) })
    }
    func text(_ name: String) -> String { (blocks[name] ?? []).joined(separator: "\n") }
}
public enum BrunoImporter {
    public static func load(from url: URL) throws -> ForeignWorkspaceImport {
        try Task.checkCancellation()
        if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            return try parse(BoundedFileInput.brunoFolder(url))
        }
        switch url.pathExtension.lowercased() {
        case "zip":
            return try parse(
                BoundedArchive.readZIP(BoundedFileInput.read(url, limit: BoundedArchive.totalBytes))
            )
        case "bru":
            return try parse(
                [ImportFile(path: url.lastPathComponent, data: BoundedFileInput.read(url))],
                standalone: true)
        case "json":
            guard url.lastPathComponent == "bruno.json" else { throw BrunoImportError.invalid }
            return try parse(BoundedFileInput.brunoFolder(url.deletingLastPathComponent()))
        default: throw BrunoImportError.invalid
        }
    }
    public static func parse(_ files: [ImportFile], standalone: Bool = false) throws
        -> ForeignWorkspaceImport
    {
        try Task.checkCancellation()
        guard files.count <= BoundedArchive.entryCount,
            files.reduce(0, { $0 + $1.data.count }) <= BoundedArchive.totalBytes
        else { throw ArchiveImportError.limit }
        var seen = Set<String>()
        for file in files {
            _ = try BoundedArchive.components(file.path)
            guard file.data.count <= BoundedArchive.fileBytes,
                seen.insert(BoundedArchive.key(file.path)).inserted
            else { throw ArchiveImportError.unsafePath }
        }
        let markers = files.filter {
            URL(fileURLWithPath: $0.path).lastPathComponent == "bruno.json"
        }
        var name = "Imported Bruno"
        var prefix = ""
        if !standalone {
            guard markers.count == 1 else { throw BrunoImportError.invalid }
            try WorkspaceFile.checkJSONBounds(markers[0].data)
            guard
                let config = try JSONSerialization.jsonObject(with: markers[0].data)
                    as? [String: Any], config["type"] as? String == "collection",
                config["version"] as? String == "1", let title = config["name"] as? String
            else { throw BrunoImportError.invalid }
            name = title
            prefix = String(markers[0].path.dropLast("bruno.json".count))
        } else {
            guard files.count == 1, markers.isEmpty else { throw BrunoImportError.invalid }
        }
        guard name.utf8.count <= 4000 else { throw ArchiveImportError.limit }
        var encodedBytes = 0
        var extraWarnings = Set<String>()
        var imported = ForeignWorkspaceImport(workspace: Workspace(), warnings: [])
        var groups: [String: UUID] = [:]
        var requests: [(sequence: Double, path: String, request: RequestDraft)] = []
        for file in files.sorted(by: { $0.path < $1.path })
        where file.path.lowercased().hasSuffix(".bru") && !file.path.hasPrefix("__MACOSX/") {
            try Task.checkCancellation()
            guard file.path.hasPrefix(prefix) else { throw BrunoImportError.unsupported }
            let relative = String(file.path.dropFirst(prefix.count))
            let document = try BruDocument(file.data)
            let meta = try document.dictionary("meta")
            let basename = URL(fileURLWithPath: relative).lastPathComponent
            if ["collection.bru", "folder.bru"].contains(basename) {
                guard
                    document.blocks.keys.allSatisfy({
                        ["meta", "docs"].contains($0)
                            || document.text($0).trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                    })
                else { throw BrunoImportError.unsupported }
                continue
            }
            if relative.hasPrefix("environments/") || document.blocks["vars"] != nil
                || document.blocks["vars:secret"] != nil
            {
                guard
                    document.blocks.keys.allSatisfy({
                        ["vars", "vars:secret", "meta", "docs"].contains($0)
                    })
                else { throw BrunoImportError.unsupported }
                let secretNames = try document.secrets()
                var environment = Environment(
                    name: meta["name"]
                        ?? URL(fileURLWithPath: relative).deletingPathExtension().lastPathComponent)
                var fields = try document.fields("vars")
                for secret in secretNames where !fields.contains(where: { $0.name == secret }) {
                    fields.append(Field(name: secret))
                }
                guard fields.count <= 10_000, Set(fields.map(\.name)).count == fields.count else {
                    throw BrunoImportError.unsupported
                }
                for var field in fields {
                    if secretNames.contains(field.name) {
                        guard (imported.workspace.namedSecrets?.count ?? 0) < 10_000,
                            field.value.utf8.count <= 1024 * 1024
                        else { throw ArchiveImportError.limit }
                        let secret = NamedSecret(name: "bruno-" + UUID().uuidString)
                        imported.workspace.namedSecrets =
                            (imported.workspace.namedSecrets ?? []) + [secret]
                        imported.secretValues[secret.id] = field.value
                        field.value = "{{secret:" + secret.name + "}}"
                    }
                    environment.variables.append(field)
                }
                encodedBytes += try JSONEncoder().encode(environment).count
                guard encodedBytes <= BoundedArchive.totalBytes else {
                    throw ArchiveImportError.limit
                }
                imported.workspace.environments.append(environment)
                continue
            }
            let methods = HTTPMethod.allCases.filter {
                document.blocks[$0.rawValue.lowercased()] != nil
            }
            guard methods.count == 1, let method = methods.first,
                meta["type"] == nil || meta["type"] == "http"
            else { throw BrunoImportError.unsupported }
            let settings = try document.dictionary(method.rawValue.lowercased())
            guard let address = settings["url"],
                settings.keys.allSatisfy({ ["url", "body", "auth"].contains($0) })
            else { throw BrunoImportError.unsupported }
            guard try document.fields("params:path").isEmpty else {
                throw BrunoImportError.unsupported
            }
            var object: [String: Any] = [
                "method": method.rawValue, "url": address,
                "header": try document.fields("headers").map {
                    ["key": $0.name, "value": $0.value, "disabled": !$0.enabled] as [String: Any]
                },
            ]
            let auth = settings["auth"] ?? "none"
            switch auth {
            case "none": object["auth"] = ["type": "noauth"]
            case "basic":
                let values = try document.dictionary("auth:basic")
                object["auth"] = [
                    "type": "basic",
                    "basic": [
                        ["key": "username", "value": values["username"] ?? ""],
                        ["key": "password", "value": values["password"] ?? ""],
                    ],
                ]
            case "bearer":
                let values = try document.dictionary("auth:bearer")
                object["auth"] = [
                    "type": "bearer", "bearer": [["key": "token", "value": values["token"] ?? ""]],
                ]
            default: throw BrunoImportError.unsupported
            }
            for block in ["auth:basic", "auth:bearer"] where block != "auth:" + auth {
                guard document.text(block).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw BrunoImportError.unsupported }
            }
            let bodies = document.blocks.keys.filter { $0 == "body" || $0.hasPrefix("body:") }
            guard bodies.count <= 1 else { throw BrunoImportError.unsupported }
            if let body = bodies.first {
                let mode = body == "body" ? "json" : String(body.dropFirst("body:".count))
                guard settings["body"] == nil || settings["body"] == mode else {
                    throw BrunoImportError.unsupported
                }
                switch body {
                case "body", "body:json", "body:text", "body:xml":
                    object["body"] = ["mode": "raw", "raw": document.text(body)]
                    let mime =
                        body == "body:text"
                        ? "text/plain"
                        : (body == "body:xml" ? "application/xml" : "application/json")
                    var headers = object["header"] as! [[String: Any]]
                    if !headers.contains(where: {
                        ($0["key"] as? String)?.lowercased() == "content-type"
                            && $0["disabled"] as? Bool == false
                    }) {
                        headers.append(["key": "Content-Type", "value": mime])
                    }
                    object["header"] = headers
                case "body:form-urlencoded", "body:multipart-form":
                    let mode = body == "body:form-urlencoded" ? "urlencoded" : "formdata"
                    object["body"] = [
                        "mode": mode,
                        mode: try document.fields(body).map { field -> [String: Any] in
                            if field.value.hasPrefix("@file") {
                                guard mode == "formdata", field.value.hasPrefix("@file("),
                                    field.value.hasSuffix(")")
                                else { throw BrunoImportError.unsupported }
                                let path = String(field.value.dropFirst(6).dropLast())
                                guard
                                    !path.contains(where: {
                                        ["'", "\"", ",", "(", ")"].contains($0)
                                    })
                                else { throw BrunoImportError.unsupported }
                                return [
                                    "key": field.name, "src": path, "type": "file",
                                    "disabled": !field.enabled,
                                ]
                            }
                            return [
                                "key": field.name, "value": field.value, "type": "text",
                                "disabled": !field.enabled,
                            ]
                        },
                    ]
                default: throw BrunoImportError.unsupported
                }
            } else if let body = settings["body"], body != "none" {
                throw BrunoImportError.unsupported
            }
            let allowed = Set(
                [
                    "meta", method.rawValue.lowercased(), "headers", "params:query", "params:path",
                    "auth:basic", "auth:bearer", "docs", "settings", "script:pre-request",
                    "script:post-response", "tests",
                ] + bodies)
            guard document.blocks.keys.allSatisfy(allowed.contains) else {
                throw BrunoImportError.unsupported
            }
            let root: [String: Any] = [
                "info": [
                    "name": name,
                    "schema":
                        "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
                ], "item": [["name": meta["name"] ?? basename, "request": object]],
            ]
            let parsed = try PostmanImporter.parse(JSONSerialization.data(withJSONObject: root))
            var request = parsed.workspace.requests[0]
            for warning in parsed.warnings where !warning.hasPrefix("Unspecified defaults") {
                extraWarnings.insert(warning)
            }
            let query = try document.fields("params:query")
            if !query.isEmpty {
                var url = request.url
                if let question = url.firstIndex(of: "?") {
                    let fragment = url[question...].firstIndex(of: "#")
                    let end = fragment ?? url.endIndex
                    let raw = String(url[url.index(after: question)..<end])
                    let pairs =
                        URLComponents(string: "https://query.invalid/?" + raw)?.queryItems ?? []
                    guard
                        pairs.allSatisfy({ pair in
                            query.contains {
                                $0.name == pair.name && $0.value == (pair.value ?? "")
                            }
                        })
                    else { throw BrunoImportError.unsupported }
                    url.removeSubrange(question..<end)
                }
                request.url = url
                request.parameters = query
            }
            let path = relative.split(separator: "/").dropLast().joined(separator: "/")
            let group = path.isEmpty ? name : name + " / " + path
            guard group.utf8.count <= 4096 else { throw ArchiveImportError.limit }
            if groups[group] == nil {
                let collection = RequestCollection(name: group)
                groups[group] = collection.id
                imported.workspace.collections.append(collection)
            }
            request.collectionID = groups[group]
            let sources = ["script:pre-request", "script:post-response", "tests"].compactMap {
                block -> ForeignScriptSource? in
                guard document.blocks[block] != nil else { return nil }
                return ForeignScriptSource(
                    origin: "Bruno: " + basename, stage: block, source: document.text(block))
            }
            request.foreignScripts = sources.isEmpty ? nil : sources
            let sequence = meta["seq"].flatMap(Double.init) ?? Double.greatestFiniteMagnitude
            guard sequence.isFinite else { throw BrunoImportError.invalid }
            guard request.credential.utf8.count <= 1024 * 1024 else {
                throw ArchiveImportError.limit
            }
            encodedBytes += try JSONEncoder().encode(request).count
            guard encodedBytes <= BoundedArchive.totalBytes else { throw ArchiveImportError.limit }
            requests.append((sequence, relative, request))
        }
        imported.workspace.requests = requests.sorted {
            $0.sequence == $1.sequence ? $0.path < $1.path : $0.sequence < $1.sequence
        }.map(\.request)
        if !standalone && imported.workspace.requests.isEmpty
            && imported.workspace.environments.isEmpty
        {
            imported.workspace.collections = [RequestCollection(name: name)]
        }
        guard
            !imported.workspace.requests.isEmpty || !imported.workspace.environments.isEmpty
                || !imported.workspace.collections.isEmpty
        else { throw BrunoImportError.invalid }
        imported.warnings =
            extraWarnings.sorted() + [
                "Bru input uses a bounded two-space-indented block subset. Body indentation and CRLF are normalized. Query rows are authoritative and can re-encode raw query spelling. Unsupported syntax fails before Apply.",
                "Collection/folder defaults with active content, inherited/unsupported auth, path parameters and unsupported body/file/annotation forms reject. Tags/docs and transport settings are omitted; Rill transport defaults apply.",
                "Foreign scripts/tests remain DISABLED plain-text review material and may contain secrets. No script, module or external file is executed/read. Environment marked secrets move to Keychain; unmarked values remain plain text. Choose an environment before Send.",
                "Only .bru source and bruno.json metadata are read from folders. .git/node_modules are skipped, upload files and .env files are not read. ZIP entries stay in memory; unknown bundle files are not attached.",
            ]
        try WorkspaceFile.validate(imported.workspace)
        return imported
    }
}
