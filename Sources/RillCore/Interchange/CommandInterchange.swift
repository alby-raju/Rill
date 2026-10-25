import Foundation

public enum CommandError: LocalizedError {
    case syntax, shellExpansion, tooLarge, unsupported(String), invalidRequest
    public var errorDescription: String? {
        switch self {
        case .syntax: "Use one cURL or HTTPie command with balanced POSIX quotes. Command lists, pipes and redirections are not supported."
        case .shellExpansion: "Shell variables, substitutions and backticks are not evaluated. Quote literal dollar signs with single quotes or escape them."
        case .tooLarge: "Command/snippet exceeds 1 MiB or 10,000 arguments."
        case .unsupported(let option): "This command option or combination cannot be represented safely: \(option)."
        case .invalidRequest: "The command needs one explicit HTTP(S) URL and a supported HTTP method/body combination."
        }
    }
}
public enum CommandWords {
    public static func parse(_ text: String) throws -> [String] {
        guard text.utf8.count <= 1024 * 1024, !text.contains("\0") else { throw CommandError.tooLarge }
        let characters = Array(text)
        let lastContent = characters.lastIndex(where: { !$0.isWhitespace }) ?? -1
        var words: [String] = [], word = "", started = false, quote: Character?, index = 0
        func finish() throws {
            if started { words.append(word); word = ""; started = false }
            guard words.count <= 10_000 else { throw CommandError.tooLarge }
        }
        while index < characters.count {
            if index % 4096 == 0 { try Task.checkCancellation() }
            let character = characters[index]
            if quote == "'" {
                if character == "'" { quote = nil } else { word.append(character) }
            } else if quote == "\"" {
                if character == "\"" { quote = nil }
                else if character == "$" || character == "`" { throw CommandError.shellExpansion }
                else if character == "\\", index + 1 < characters.count, ["$", "`", "\"", "\\", "\n"].contains(characters[index + 1]) {
                    index += 1; if characters[index] != "\n" { word.append(characters[index]) }
                } else { word.append(character) }
            } else {
                switch character {
                case "'", "\"": quote = character; started = true
                case "\\":
                    guard index + 1 < characters.count else { throw CommandError.syntax }
                    index += 1
                    if characters[index] != "\n" { word.append(characters[index]); started = true }
                case "$", "`": throw CommandError.shellExpansion
                case ";", "|", "&", "<", ">": throw CommandError.syntax
                case "\n":
                    if (!words.isEmpty || started) && index < lastContent { throw CommandError.syntax }
                    try finish()
                case " ", "\t", "\r": try finish()
                default: word.append(character); started = true
                }
            }
            index += 1
        }
        guard quote == nil else { throw CommandError.syntax }; try finish(); return words
    }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}
public struct CommandImport: Sendable {
    public init(request: RequestDraft, warnings: [String]) { self.request = request; self.warnings = warnings }
    public var request: RequestDraft
    public var warnings: [String]
}
public enum CommandImporter {
    public static func parse(_ text: String) throws -> CommandImport {
        var words = try CommandWords.parse(text)
        guard !words.isEmpty else { throw CommandError.syntax }
        let command = URL(fileURLWithPath: words.removeFirst()).lastPathComponent
        switch command {
        case "curl": return try curl(words)
        case "http", "https": return try httpie(words, secure: command == "https")
        default: throw CommandError.unsupported("command name")
        }
    }
    static func reference(_ path: String) throws -> UploadFileReference {
        guard !path.isEmpty, path != "-", !path.contains("\0") else { throw CommandError.unsupported("stdin or empty file reference") }
        // Never inspect/read a path from pasted text. Send requires reselection.
        return UploadFileReference(path: path, byteCount: 0, modificationDate: .distantPast, fileID: 0)
    }
    static func header(_ value: String, into request: inout RequestDraft) throws {
        guard !value.hasPrefix("@"), let colon = value.firstIndex(of: ":") else { throw CommandError.unsupported("header files, unset headers or malformed header") }
        let name = String(value[..<colon])
        var body = String(value[value.index(after: colon)...])
        if body.hasPrefix(" ") { body.removeFirst() }
        guard HTTPEncoding.isHeaderName(name), !body.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9) || $0.value == 127 }),
              !request.headers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw CommandError.unsupported("invalid or repeated header") }
        request.headers.append(Field(name: name, value: body))
        if name.lowercased() == "content-type" { request.contentType = body }
    }
    static func finalize(_ input: RequestDraft, warnings: [String]) throws -> CommandImport {
        var request = input, warnings = warnings
        guard var components = URLComponents(string: request.url), ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host?.isEmpty == false else { throw CommandError.invalidRequest }
        if let username = components.user {
            guard request.auth == .none else { throw CommandError.unsupported("conflicting URL and explicit authentication") }
            request.auth = .basic; request.username = username; request.credential = components.password ?? ""
            components.user = nil; components.password = nil; request.url = components.url!.absoluteString
            warnings.append("URL credentials move to request Auth and will be stored in Keychain only after Apply.")
        }
        if let index = request.headers.firstIndex(where: { $0.name.lowercased() == "authorization" }), request.auth == .none {
            let value = request.headers[index].value
            if value.lowercased().hasPrefix("bearer ") { request.auth = .bearer; request.credential = String(value.dropFirst(7)); request.headers.remove(at: index) }
            else if value.lowercased().hasPrefix("basic "), let data = Data(base64Encoded: String(value.dropFirst(6))), let pair = String(data: data, encoding: .utf8), let colon = pair.firstIndex(of: ":") {
                request.auth = .basic; request.username = String(pair[..<colon]); request.credential = String(pair[pair.index(after: colon)...]); request.headers.remove(at: index)
            } else { warnings.append("Unrecognized Authorization remains a plain-text header and is included in workspace exports.") }
        } else if request.auth != .none && request.headers.contains(where: { $0.name.lowercased() == "authorization" }) { throw CommandError.unsupported("conflicting Authorization and auth options") }
        if request.auth == .none, let index = request.headers.firstIndex(where: { ["x-api-key", "api-key"].contains($0.name.lowercased()) }) {
            let field = request.headers.remove(at: index)
            request.auth = .apiKey; request.apiKeyName = field.name; request.apiKeyLocation = .header; request.credential = field.value
        }
        let hasBody = request.bodyMode == .binary || request.bodyMode == .multipart || request.bodyMode == .form || request.bodyMode == .text
        guard !hasBody || (request.method != .GET && request.method != .HEAD), (1...300).contains(request.timeout) else { throw CommandError.invalidRequest }
        request.name = "Imported " + request.method.rawValue + " request"
        if request.binaryFile != nil || (request.multipartParts ?? []).contains(where: { $0.file != nil }) { warnings.append("File paths were not read. Select each referenced file locally before sending.") }
        warnings.append("Unspecified defaults use Rill headers and transport, not CLI defaults. No shell, file contents or network request was executed; URLs, headers and bodies may contain secrets.")
        return CommandImport(request: request, warnings: warnings)
    }
    private static func curl(_ original: [String]) throws -> CommandImport {
        var words: [String] = []
        let attached: Set<String> = ["-X", "-H", "-d", "-u", "-m", "-F", "-T", "-A", "-e"]
        for word in original {
            if word.hasPrefix("-") && !word.hasPrefix("--") && word.count > 2 {
                let prefix = String(word.prefix(2))
                if attached.contains(prefix) { words += [prefix, String(word.dropFirst(2))] }
                else if word.dropFirst().allSatisfy({ "sSLIgG".contains($0) }) { words += word.dropFirst().map { "-" + String($0) } }
                else { throw CommandError.unsupported("combined short options") }
            } else { words.append(word) }
        }
        var request = RequestDraft(), warnings: [String] = [], data: [String] = [], parts: [MultipartPart] = []
        var explicitMethod: HTTPMethod?, address: String?, globoff = false, get = false, binary: UploadFileReference?, upload = false, json = false, index = 0
        while index < words.count {
            let original = words[index]
            let pair = original.hasPrefix("--") ? original.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init) : [original]
            let option = pair[0]
            func argument() throws -> String {
                if pair.count == 2 { return pair[1] }
                index += 1; guard words.indices.contains(index) else { throw CommandError.syntax }; return words[index]
            }
            switch option {
            case "-X", "--request": guard let method = HTTPMethod(rawValue: try argument().uppercased()) else { throw CommandError.invalidRequest }; explicitMethod = method
            case "--url": guard address == nil else { throw CommandError.unsupported("multiple URLs") }; address = try argument()
            case "-H", "--header":
                let value = try argument()
                if value.hasSuffix(";"), !value.contains(":") { try header(String(value.dropLast()) + ":", into: &request) }
                else {
                    guard let colon = value.firstIndex(of: ":"), !value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces).isEmpty else { throw CommandError.unsupported("header removal") }
                    try header(value, into: &request)
                }
            case "-A", "--user-agent": let value = try argument(); guard !value.isEmpty else { throw CommandError.unsupported("User-Agent removal") }; try header("User-Agent: " + value, into: &request)
            case "-e", "--referer": let value = try argument(); guard !value.isEmpty else { throw CommandError.unsupported("Referer removal") }; try header("Referer: " + value, into: &request)
            case "-u", "--user":
                guard request.auth == .none else { throw CommandError.unsupported("multiple auth options") }
                let value = try argument(); guard let colon = value.firstIndex(of: ":") else { throw CommandError.unsupported("interactive password prompt") }
                request.auth = .basic; request.username = String(value[..<colon]); request.credential = String(value[value.index(after: colon)...])
            case "--oauth2-bearer": guard request.auth == .none else { throw CommandError.unsupported("multiple auth options") }; request.auth = .bearer; request.credential = try argument()
            case "-m", "--max-time": guard let value = Double(try argument()), value.isFinite, (1...300).contains(value) else { throw CommandError.unsupported("timeout outside 1–300 seconds") }; request.timeout = value
            case "-I", "--head": explicitMethod = .HEAD
            case "-G", "--get": get = true
            case "-d", "--data", "--data-ascii", "--data-raw", "--data-binary", "--json":
                let value = try argument()
                if option == "--json" { guard data.isEmpty, binary == nil, !json else { throw CommandError.unsupported("multiple/mixed JSON data options") }; json = true }
                else if json { throw CommandError.unsupported("mixed JSON data options") }
                if value.hasPrefix("@") && option != "--data-raw" {
                    guard ["--data-binary", "--json"].contains(option), binary == nil, data.isEmpty else { throw CommandError.unsupported("file stripping or combined file data") }
                    binary = try reference(String(value.dropFirst()))
                } else { guard binary == nil else { throw CommandError.unsupported("combined file data") }; data.append(value) }
            case "--data-urlencode":
                guard binary == nil, !json else { throw CommandError.unsupported("mixed encoded/file/JSON body") }
                let value = try argument()
                if let equal = value.firstIndex(of: "=") { data.append((equal == value.startIndex ? "" : String(value[...equal])) + HTTPEncoding.component(String(value[value.index(after: equal)...]))) }
                else { guard !value.contains("@") else { throw CommandError.unsupported("encoded file contents") }; data.append(HTTPEncoding.component(value)) }
            case "-T", "--upload-file": guard binary == nil, data.isEmpty else { throw CommandError.unsupported("multiple body sources") }; binary = try reference(argument()); upload = true
            case "-F", "--form", "--form-string": parts.append(try form(argument(), literal: option == "--form-string"))
            case "--compressed": warnings.append("Native compression support replaces cURL's exact encoding list.")
            case "-L", "--location": warnings.append("Rill follows same-origin redirects only; cross-origin redirects stop for inspection.")
            case "-g", "--globoff": globoff = true
            case "-q", "--disable", "-s", "--silent", "-S", "--show-error": break
            case "--":
                index += 1; guard words.indices.contains(index), address == nil, index == words.count - 1 else { throw CommandError.syntax }; address = words[index]
            default:
                guard !option.hasPrefix("-") else { throw CommandError.unsupported(String(option.prefix(80))) }
                guard address == nil else { throw CommandError.unsupported("multiple URLs or positional arguments") }; address = original
            }
            index += 1
        }
        guard let address else { throw CommandError.invalidRequest }; request.url = address
        if !globoff, let components = URLComponents(string: address), (components.path + (components.query ?? "")).contains(where: { "{}[]".contains($0) }) { throw CommandError.unsupported("URL globbing; use --globoff for literal brackets/braces") }
        request.contentType = request.headers.first { $0.name.lowercased() == "content-type" }?.value ?? (json ? "application/json" : "application/x-www-form-urlencoded")
        if json && !request.headers.contains(where: { $0.name.lowercased() == "accept" }) { request.headers.append(Field(name: "Accept", value: "application/json")) }
        guard parts.isEmpty || (data.isEmpty && binary == nil && !get) else { throw CommandError.unsupported("mixed multipart/raw body") }
        if !parts.isEmpty { request.bodyMode = .multipart; request.multipartParts = parts }
        else if let binary { guard !get else { throw CommandError.unsupported("GET with file data") }; request.bodyMode = .binary; request.binaryFile = binary }
        else if !data.isEmpty {
            request.body = data.joined(separator: "&")
            if get {
                for pair in request.body.split(separator: "&", omittingEmptySubsequences: false) {
                    let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    func decode(_ value: Substring) throws -> String { guard let decoded = String(value).replacingOccurrences(of: "+", with: "%20").removingPercentEncoding else { throw CommandError.invalidRequest }; return decoded }
                    guard !fields[0].isEmpty else { throw CommandError.unsupported("empty query name") }
                    request.parameters.append(Field(name: try decode(fields[0]), value: fields.count == 2 ? try decode(fields[1]) : ""))
                }
                request.bodyMode = RequestBodyMode.none
            } else { request.bodyMode = .text }
        } else { request.bodyMode = RequestBodyMode.none }
        request.method = explicitMethod ?? (get ? .GET : upload ? .PUT : request.bodyMode == RequestBodyMode.none ? .GET : .POST)
        return try finalize(request, warnings: warnings)
    }
    private static func form(_ value: String, literal: Bool) throws -> MultipartPart {
        guard let equal = value.firstIndex(of: "=") else { throw CommandError.unsupported("multipart part without name") }
        var part = MultipartPart(); part.name = String(value[..<equal])
        guard !part.name.isEmpty else { throw CommandError.unsupported("empty multipart name") }
        let content = String(value[value.index(after: equal)...])
        if literal { part.value = content; return part }
        guard !content.hasPrefix("<") else { throw CommandError.unsupported("multipart file-as-text") }
        let pieces = content.components(separatedBy: ";")
        if pieces[0].hasPrefix("@") {
            guard !pieces[0].contains(","), !pieces[0].contains("\""), !pieces[0].contains("\\") else { throw CommandError.unsupported("multipart file lists or internal quoting") }
            part.kind = .file; part.file = try reference(String(pieces[0].dropFirst())); part.filename = URL(fileURLWithPath: part.file!.path).lastPathComponent; part.contentType = "application/octet-stream" }
        else { part.value = pieces[0] }
        for attribute in pieces.dropFirst() {
            if attribute.hasPrefix("type=") { part.contentType = String(attribute.dropFirst(5)) }
            else if attribute.hasPrefix("filename="), part.kind == .file { part.filename = String(attribute.dropFirst(9)) }
            else { throw CommandError.unsupported("multipart attributes or semicolon quoting") }
        }
        return part
    }
}

extension CommandImporter {
    private static func httpie(_ words: [String], secure: Bool) throws -> CommandImport {
        var request = RequestDraft(), warnings: [String] = [], method: HTTPMethod?, address: String?, fields: [(String, String, Bool, Int)] = [], files: [(MultipartPart, Int)] = []
        var raw: String?, form = false, authType = "basic", auth: String?, index = 0
        while index < words.count {
            let word = words[index]
            if word.hasPrefix("-") {
                let split = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                func argument() throws -> String { if split.count == 2 { return split[1] }; index += 1; guard words.indices.contains(index) else { throw CommandError.syntax }; return words[index] }
                switch split[0] {
                case "-f", "--form": form = true
                case "-j", "--json": form = false
                case "--raw": guard raw == nil else { throw CommandError.unsupported("multiple raw bodies") }; raw = try argument()
                case "-a", "--auth": guard auth == nil else { throw CommandError.unsupported("multiple auth options") }; auth = try argument()
                case "--auth-type": authType = try argument().lowercased(); guard ["basic", "bearer"].contains(authType) else { throw CommandError.unsupported("auth type") }
                case "--timeout": guard let value = Double(try argument()), value.isFinite, (1...300).contains(value) else { throw CommandError.unsupported("timeout outside 1–300 seconds") }; request.timeout = value
                case "--follow": warnings.append("Rill follows same-origin redirects only.")
                case "--ignore-stdin", "--ignore-netrc": break
                case "--offline", "--print", "-p":
                    if split[0] != "--offline" { _ = try argument() }
                    warnings.append("HTTPie display/offline options are not retained; import itself performs no request.")
                default: throw CommandError.unsupported(String(split[0].prefix(80)))
                }
            } else if address == nil {
                if method == nil, let parsed = HTTPMethod(rawValue: word.uppercased()) { method = parsed }
                else { address = word }
            } else if word.hasSuffix(";"), HTTPEncoding.isHeaderName(String(word.dropLast())) {
                try header(String(word.dropLast()) + ":", into: &request)
            } else {
                let operators = ["==", ":=", "=", ":", "@"]
                let matches = operators.compactMap { op -> (String, Range<String.Index>)? in word.range(of: op).map { (op, $0) } }.sorted {
                    $0.1.lowerBound == $1.1.lowerBound ? $0.0.count > $1.0.count : $0.1.lowerBound < $1.1.lowerBound
                }
                guard let (op, range) = matches.first else { throw CommandError.unsupported("HTTPie item") }
                let key = String(word[..<range.lowerBound]), value = String(word[range.upperBound...])
                guard !key.isEmpty, !key.contains("\\") else { throw CommandError.unsupported("empty/escaped item keys") }
                switch op {
                case "==": request.parameters.append(Field(name: key, value: value))
                case ":": guard !value.isEmpty else { throw CommandError.unsupported("header removal") }; try header(key + ":" + value, into: &request)
                case "@": files.append((try Self.form(key + "=@" + value, literal: false), index))
                default:
                    guard !key.contains("["), !key.contains("]") else { throw CommandError.unsupported("nested JSON field syntax") }
                    if op == ":=" { _ = try JSONTextFormatter.pretty(value) }
                    fields.append((key, value, op == ":=", index))
                }
            }
            index += 1
        }
        guard var address else { throw CommandError.invalidRequest }
        if !address.contains("://") { address = (secure ? "https://" : "http://") + (address.hasPrefix(":") ? "localhost" : "") + address }
        request.url = address
        if let auth {
            if authType == "bearer" { request.auth = .bearer; request.credential = auth }
            else {
                guard let colon = auth.firstIndex(of: ":") else { throw CommandError.unsupported("interactive auth prompt") }
                request.auth = .basic; request.username = String(auth[..<colon]); request.credential = String(auth[auth.index(after: colon)...])
            }
        }
        guard raw == nil || (fields.isEmpty && files.isEmpty) else { throw CommandError.unsupported("raw and structured body combination") }
        if let raw { request.bodyMode = .text; request.body = raw }
        else if !files.isEmpty {
            guard form, !fields.contains(where: { $0.2 }) else { throw CommandError.unsupported("file upload without form mode or typed JSON form") }
            request.bodyMode = .multipart
            request.multipartParts = (fields.map { field in var part = MultipartPart(); part.name = field.0; part.value = field.1; return (part, field.3) } + files).sorted { $0.1 < $1.1 }.map { $0.0 }
            warnings.append("Unspecified file MIME types use application/octet-stream; review before sending.")
        } else if !fields.isEmpty {
            if form {
                guard !fields.contains(where: { $0.2 }) else { throw CommandError.unsupported("typed JSON form fields") }
                request.bodyMode = .form; request.formFields = fields.map { Field(name: $0.0, value: $0.1) }
            } else {
                guard Set(fields.map(\.0)).count == fields.count else { throw CommandError.unsupported("duplicate JSON keys") }
                warnings.append("Structured HTTPie JSON is reconstructed; whitespace may differ from CLI output.")
                request.bodyMode = .text; request.contentType = "application/json"
                request.body = "{" + (try fields.map { field in
                    let key = String(decoding: try JSONEncoder().encode(field.0), as: UTF8.self)
                    let value = field.2 ? field.1 : String(decoding: try JSONEncoder().encode(field.1), as: UTF8.self)
                    return key + ":" + value
                }).joined(separator: ",") + "}"
            }
        } else { request.bodyMode = RequestBodyMode.none }
        request.method = method ?? (request.bodyMode == RequestBodyMode.none ? .GET : .POST)
        return try finalize(request, warnings: warnings)
    }
}
public enum CommandTarget: String, CaseIterable, Sendable { case curl = "cURL", httpie = "HTTPie" }
public enum CommandGenerator {
    public static func generate(_ input: RequestDraft, environment inputEnvironment: Environment?, target: CommandTarget, includeCredentials: Bool = false, profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil) throws -> String {
        let prepared = try WorkflowEngine.prepare(input, variables: WorkflowEngine.variables(in: inputEnvironment))
        let draft = prepared.request, environment = WorkflowEngine.environment(prepared.variables)
        guard draft.tlsProfileID == nil else { throw CommandError.unsupported("TLS profiles require separately configured CLI trust/identity options") }
        if target == .httpie && draft.bodyMode == .binary { throw CommandError.unsupported("HTTPie binary file body snippets") }
        guard draft.bodyMode != .multipart else { throw CommandError.unsupported("multipart snippets are a subsequent slice; export the prepared request for inspection") }
        let frozen = try RequestEngine.freeze(draft, environment: environment, profiles: profiles, secrets: secrets)
        defer { frozen.removeTemporaryBody() }
        let request = frozen.request
        var words = target == .curl ? ["curl", "--disable", "--globoff", "--request", CommandWords.quote(request.httpMethod ?? "GET"), "--url", CommandWords.quote(request.url!.absoluteString)] : ["http", "--ignore-stdin", "--ignore-netrc", request.httpMethod ?? "GET", CommandWords.quote(request.url!.absoluteString)]
        let knownSecrets: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key", "x-auth-token"]
        let effective = try AuthenticationProfiles.applying(to: draft, profiles: profiles)
        let variables = prepared.variables
        let keyName = effective.auth == .apiKey ? try VariableExpansion.resolve(effective.apiKeyName ?? "", values: variables, secretLookup: { name in guard let secrets else { throw AuthenticationError.missingSecret }; return try secrets.resolve(name) }).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        words += [target == .curl ? "--max-time" : "--timeout", String(request.timeoutInterval)]
        for (name, original) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            if name.lowercased() == "content-length" && draft.bodyMode == .binary { continue }
            let customKey = effective.auth == .apiKey && effective.apiKeyLocation != .query && name.caseInsensitiveCompare(keyName) == .orderedSame
            let value = !includeCredentials && (knownSecrets.contains(name.lowercased()) || customKey) ? "[REDACTED]" : original
            let header = value.isEmpty ? name + ";" : name + ": " + value
            if target == .curl { words += ["--header", CommandWords.quote(header)] } else { words.append(CommandWords.quote(header)) }
        }
        if draft.bodyMode == .binary {
            guard target == .curl, let file = draft.binaryFile else { throw CommandError.unsupported("HTTPie binary file body snippets") }
            words += ["--data-binary", CommandWords.quote("@" + file.path)]
        } else if let data = request.httpBody {
            guard data.count <= 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw CommandError.unsupported("non-UTF-8 or oversized inline body") }
            words += [target == .curl ? "--data-raw" : "--raw", CommandWords.quote(text)]
        }
        let result = words.joined(separator: " \\\n  ")
        guard result.utf8.count <= 1024 * 1024 else { throw CommandError.tooLarge }
        return result
    }
}
