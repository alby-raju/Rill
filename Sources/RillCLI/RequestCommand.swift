import Foundation
import RillCore

extension RillCLI {
    static func request(_ args: Arguments) async throws {
        let tlsValues = FileTLSOptions.values.subtracting(["ssl-client-map"])
        let requestValues: Set<String> = [
            "header", "data", "data-file", "binary-file", "form", "env-var", "output", "download",
            "timeout",
            "color", "workspace", "environment", "auth-profile", "tls", "session",
            "session-key-file", "query-param", "json-field", "header-file", "default-scheme",
        ]
        let requestFlags: Set<String> = [
            "json", "quiet", "overwrite", "allow-insecure", "multipart", "offline", "raw-preview",
            "stdin", "no-follow", "body-stdout",
        ]
        let fromStdin = args.flags.contains("stdin")
        let bodyOptions = ["data", "data-file", "binary-file", "form", "json-field"].filter {
            args.values[$0] != nil
        }
        let hasBody = fromStdin || !bodyOptions.isEmpty
        guard (1...2).contains(args.operands.count),
            let urlOperand = args.operands.last,
            Set(args.values.keys).isSubset(of: requestValues.union(tlsValues)),
            args.flags.isSubset(of: requestFlags.union(FileTLSOptions.flags)),
            bodyOptions.count + (fromStdin ? 1 : 0) <= 1
        else {
            throw CLIError.usage(
                "Use request [METHOD] URL with one body option: --data, --data-file, --binary-file, --stdin, --form or --json-field. See help request."
            )
        }
        let method: HTTPMethod
        if args.operands.count == 2 {
            guard let explicitMethod = HTTPMethod(rawValue: args.operands[0].uppercased()) else {
                throw CLIError.usage("Unsupported HTTP method. See help request.")
            }
            method = explicitMethod
        } else {
            method = hasBody ? .POST : .GET
        }
        let requestURL = try expandRequestURL(
            urlOperand, defaultScheme: args.value("default-scheme"))
        let hasFileTLS =
            !tlsValues.isDisjoint(with: args.values.keys)
            || !FileTLSOptions.flags.isDisjoint(with: args.flags)
        let followRedirects = !args.flags.contains("no-follow")
        let offline = args.flags.contains("offline")
        let rawPreview = args.flags.contains("raw-preview")
        guard !offline || followRedirects else {
            throw CLIError.usage("--no-follow applies only to live requests.")
        }
        guard !rawPreview || offline else {
            throw CLIError.usage("--raw-preview requires --offline.")
        }
        guard
            !offline
                || (!hasFileTLS
                    && ["output", "download", "session", "session-key-file", "binary-file", "tls"]
                        .allSatisfy({ args.value($0) == nil })
                    && !args.flags.contains("multipart"))
        else {
            throw CLIError.usage(
                "Offline preview supports in-memory bodies without TLS, sessions, or response destinations."
            )
        }
        guard args.value("tls") == nil || !hasFileTLS else {
            throw CLIError.usage("Choose a saved TLS profile or explicit file TLS options.")
        }
        let form = try (args.values["form"] ?? []).map(RequestFormField.init)
        guard !offline || form.allSatisfy({ $0.file == nil }) else {
            throw CLIError.usage("Offline preview cannot open multipart file fields.")
        }
        guard !args.flags.contains("multipart") || !form.isEmpty else {
            throw CLIError.usage("--multipart requires at least one --form field.")
        }
        let bodyInputs =
            [args.value("data-file"), args.value("binary-file")].compactMap { $0 }
            + form.compactMap(\.file)
        let tlsInputs = FileTLSOptions.inputNames.compactMap { args.value($0) }
        let headerInputs = try (args.values["header-file"] ?? []).map(RequestHeaderFile.init)
        let inputPaths = bodyInputs + tlsInputs + headerInputs.map(\.path)
        guard
            args.value("workspace") != nil
                || ["environment", "auth-profile", "tls"].allSatisfy({ args.value($0) == nil })
        else {
            throw CLIError.usage(
                "Saved environment/auth/TLS selection requires an explicit --workspace.")
        }
        guard !args.flags.contains("allow-insecure") || args.value("tls") != nil else {
            throw CLIError.usage("--allow-insecure requires an explicitly selected --tls profile.")
        }
        let download = args.value("download")
        let rawOutput = args.value("output")
        guard download == nil || (method == .GET && rawOutput == nil) else {
            throw CLIError.usage("--download requires GET and cannot be combined with --output.")
        }
        let bodyStdout = args.flags.contains("body-stdout")
        guard
            !bodyStdout
                || (!offline && rawOutput == nil && download == nil
                    && args.flags.isDisjoint(with: ["json", "quiet"]))
        else {
            throw CLIError.usage(
                "--body-stdout requires a live request without --output, --download, --json or --quiet."
            )
        }
        let destination = rawOutput ?? download
        guard !args.flags.contains("overwrite") || destination != nil else {
            throw CLIError.usage("--overwrite requires --output or --download.")
        }
        if let output = destination {
            let target = URL(fileURLWithPath: output).resolvingSymlinksInPath()
            guard target != args.workspaceURL.resolvingSymlinksInPath(),
                !inputPaths.contains(where: {
                    target == URL(fileURLWithPath: $0).resolvingSymlinksInPath()
                })
            else {
                throw CLIError.usage(
                    "Output cannot replace the workspace, request body, header or TLS inputs.")
            }
            guard
                args.flags.contains("overwrite") || !FileManager.default.fileExists(atPath: output)
            else {
                throw CLIError.usage("Output exists; choose a new path or --overwrite.")
            }
        }
        let sessionOptions = try RequestSessionOptions(
            args,
            protected: [args.workspaceURL]
                + (inputPaths + [destination].compactMap { $0 })
                .map { URL(fileURLWithPath: $0) })
        var draft = RequestDraft()
        draft.name = "Ad-hoc request"
        draft.method = method
        draft.url = requestURL
        draft.headers = try args.fields("header") + headerInputs.map { try $0.field() }
        draft.parameters = try (args.values["query-param"] ?? []).map { argument in
            guard let split = argument.firstIndex(of: "="), split != argument.startIndex else {
                throw CLIError.usage("--query-param expects NAME=VALUE.")
            }
            return Field(
                name: String(argument[..<split]),
                value: String(argument[argument.index(after: split)...]))
        }
        draft.timeout = try args.seconds()
        guard draft.timeout >= 1 else {
            throw CLIError.usage("--timeout must be between 1 and 300 seconds.")
        }
        if hasBody {
            guard method != .GET && method != .HEAD else {
                throw CLIError.usage("GET/HEAD bodies are not supported; no payload was discarded.")
            }
            do {
                if let fields = args.values["json-field"] {
                    draft.bodyMode = .text
                    draft.body = try JSONRequestFields.body(fields)
                } else if fromStdin {
                    draft.bodyMode = .text
                    draft.body = try await RequestStandardInput.read(timeout: draft.timeout)
                } else if let path = args.value("binary-file") {
                    draft.bodyMode = .binary
                    draft.contentType = "application/octet-stream"
                    draft.binaryFile = try UploadFileReference.capture(URL(fileURLWithPath: path))
                } else if !form.isEmpty {
                    if args.flags.contains("multipart") || form.contains(where: { $0.file != nil })
                    {
                        draft.bodyMode = .multipart
                        draft.multipartParts = try form.map { try $0.part() }
                    } else {
                        draft.bodyMode = .form
                        draft.formFields = form.map { Field(name: $0.name, value: $0.value) }
                    }
                } else {
                    draft.bodyMode = .text
                    draft.body = try args.body()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.usage(
                    "Could not prepare bounded request body inputs; paths and contents omitted.")
            }
        } else {
            draft.bodyMode = RequestBodyMode.none
        }
        let overrides = try args.variableOverrides()
        let workspace: Workspace
        if args.value("workspace") != nil {
            // Read explicit saved profiles; never create or persist an ad-hoc request.
            workspace = try WorkspaceFile.load(from: args.workspaceURL)
        } else {
            workspace = Workspace()
        }
        var environment = try args.environment(workspace) ?? Environment(name: "Ad-hoc")
        environment.variables.removeAll { overrides[$0.name] != nil }
        environment.variables += overrides.keys.sorted().map {
            Field(name: $0, value: overrides[$0] ?? "")
        }
        draft = try args.transport(draft, workspace: workspace)
        if offline {
            try previewRequest(
                draft, environment: environment, profiles: workspace.authProfiles ?? [],
                raw: rawPreview, arguments: args)
            return
        }
        let fileTLS = try FileTLSOptions(args).load(args)
        let profiles = workspace.authProfiles ?? []
        let secrets = NamedSecretResolver(catalog: workspace.namedSecrets ?? [])
        let tlsProfiles = workspace.tlsProfiles ?? []
        let session = try sessionOptions?.open()
        let summary: RequestSummary
        var stdoutBody: Data?
        do {
            if let download {
                let result = try await RequestEngine.download(
                    draft, environment: environment, to: URL(fileURLWithPath: download),
                    overwrite: args.flags.contains("overwrite"), profiles: profiles,
                    secrets: secrets,
                    tlsProfiles: tlsProfiles, followRedirects: followRedirects,
                    fileTLS: fileTLS, cookieJar: session?.jar)
                summary = RequestSummary(
                    status: result.status, duration: result.duration, bodyBytes: result.bodyBytes)
            } else {
                let exchange = try await RequestEngine.execute(
                    draft, environment: environment, profiles: profiles, secrets: secrets,
                    tlsProfiles: tlsProfiles, followRedirects: followRedirects,
                    fileTLS: fileTLS, cookieJar: session?.jar)
                if let output = rawOutput { try args.write(exchange.body, to: output) }
                if bodyStdout { stdoutBody = exchange.body }
                summary = RequestSummary(
                    status: exchange.status, duration: exchange.duration,
                    bodyBytes: exchange.body.count)
            }
            try session?.save()
        } catch CookieSessionError.originMismatch {
            throw CLIError.usage(
                "This cookie session belongs to a different origin. No request sent.")
        } catch CookieSessionError.explicitCookieHeader {
            throw CLIError.usage(
                "Choose a cookie session or an explicit Cookie header. No request sent.")
        } catch CookieSessionError.insecureTransport {
            throw CLIError.usage("Cookie sessions require verified TLS settings. No request sent.")
        } catch CookieSessionError.writeFailed {
            try? FileHandle.standardError.write(
                contentsOf: Data(
                    "Could not save the encrypted cookie session. The previous file was preserved.\n"
                        .utf8))
            throw CLIError.runtime
        } catch is CookieSessionError {
            throw CLIError.usage("Invalid cookie session origin. No request sent.")
        } catch RillError.responseTooLarge {
            throw CLIError.runtime
        } catch is ResponseDownloadError {
            throw CLIError.usage("Could not write or install the download; destination omitted.")
        } catch is UploadError {
            throw CLIError.usage(
                "Request upload is invalid, changed or exceeds its limits; paths omitted.")
        } catch is RillError {
            throw CLIError.usage(
                "Invalid request URL, headers or unresolved variables; input content omitted.")
        } catch WorkflowError.invalidConfiguration {
            throw CLIError.usage(
                "Unsupported or malformed dynamic template; input content omitted.")
        } catch is EditingError {
            throw CLIError.usage(
                "Request variable expansion failed or exceeded its limits; input content omitted.")
        }
        if let stdoutBody {
            try FileHandle.standardOutput.write(contentsOf: stdoutBody)
        } else if args.flags.contains("json") {
            try args.json(summary)
        } else {
            try args.text(
                "HTTP \(summary.status) · \(summary.bodyBytes) response bytes · \(String(format: "%.3f", summary.duration)) s"
            )
        }
        if !(200...299).contains(summary.status) { throw CLIError.runtime }
    }

    private static func expandRequestURL(_ input: String, defaultScheme: String?) throws -> String {
        if let defaultScheme, !["http", "https"].contains(defaultScheme) {
            throw CLIError.usage("--default-scheme expects http or https.")
        }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix(":") else {
            guard let defaultScheme,
                value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) == nil
            else { return input }
            return "\(defaultScheme)://\(value)"
        }
        let remainder = value.dropFirst()
        let port = remainder.prefix { !"/?#".contains($0) }
        if !port.isEmpty {
            guard port.utf8.allSatisfy({ (48...57).contains($0) }),
                let number = Int(port), (1...65_535).contains(number)
            else {
                throw CLIError.usage("Use :[PORT][/PATH] with a port from 1 to 65535.")
            }
        }
        let path = remainder.dropFirst(port.count)
        let authority = port.isEmpty ? "localhost" : "localhost:\(port)"
        return "\(defaultScheme ?? "http")://\(authority)\(path.hasPrefix("/") ? "" : "/")\(path)"
    }

    private static func previewRequest(
        _ draft: RequestDraft, environment: Environment, profiles: [AuthenticationProfile],
        raw: Bool, arguments: Arguments
    ) throws {
        struct Preview: Encodable {
            let schemaVersion = 1
            let sendsRequests = false
            let method: String
            let deferredCredentials: Bool
            var bodyBytes: Int? = nil
            var url: String? = nil
            var headers: [String: String]? = nil
            var bodyBase64: String? = nil
        }
        var preview = Preview(method: draft.method.rawValue, deferredCredentials: false)
        do {
            do {
                let request = try RequestEngine.prepare(
                    draft, environment: environment, profiles: profiles)
                preview.bodyBytes = request.httpBody?.count ?? 0
                if raw {
                    preview.url = request.url?.absoluteString
                    preview.headers = request.allHTTPHeaderFields ?? [:]
                    preview.bodyBase64 = request.httpBody?.base64EncodedString()
                }
            } catch AuthenticationError.missingSecret {
                let deferred = try RequestEngine.prepareForPlanning(
                    draft, environment: environment, profiles: profiles)
                preview = Preview(method: draft.method.rawValue, deferredCredentials: deferred)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIError.usage(
                "Invalid offline request. Check the URL, headers, body and variables.")
        }
        if raw && preview.deferredCredentials {
            throw CLIError.usage(
                "Raw offline preview requires a request without named secret references.")
        }
        try arguments.json(preview)
    }
}

private struct RequestSummary: Encodable {
    let schemaVersion = 1
    let status: Int
    let duration: Double
    let bodyBytes: Int
}

private struct RequestHeaderFile {
    let name: String
    let path: String

    init(_ argument: String) throws {
        guard let delimiter = argument.firstIndex(of: "=") else {
            throw CLIError.usage("--header-file expects NAME=FILE.")
        }
        name = String(argument[..<delimiter])
        path = String(argument[argument.index(after: delimiter)...])
        guard HTTPEncoding.isHeaderName(name), !path.isEmpty, path != "-", !path.contains("\0")
        else {
            throw CLIError.usage("--header-file requires a header name and explicit local path.")
        }
    }

    func field() throws -> Field {
        let bytes: Data
        do {
            bytes = try BoundedFileInput.read(URL(fileURLWithPath: path), limit: 8192)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIError.usage(
                "Could not read a regular header file of at most 8 KiB; path omitted.")
        }
        let end =
            bytes.lastIndex(where: { $0 != 10 && $0 != 13 }).map { $0 + 1 } ?? bytes.startIndex
        guard let value = String(data: bytes[..<end], encoding: .utf8),
            value.range(of: "{{", options: .literal) == nil
        else {
            throw CLIError.usage(
                "Header files require valid UTF-8 without template markers; content omitted.")
        }
        return Field(name: name, value: value)
    }
}

private struct RequestFormField {
    let name: String
    let value: String
    let file: String?

    init(_ argument: String) throws {
        guard let delimiter = argument.firstIndex(where: { $0 == "=" || $0 == "@" }),
            delimiter != argument.startIndex
        else { throw CLIError.usage("--form expects NAME=VALUE or NAME@PATH.") }
        name = String(argument[..<delimiter])
        value = String(argument[argument.index(after: delimiter)...])
        if argument[delimiter] == "@" {
            guard !value.isEmpty, value != "-", !value.contains("\0") else {
                throw CLIError.usage("--form file fields require an explicit local path.")
            }
            file = value
        } else {
            file = nil
        }
    }

    func part() throws -> MultipartPart {
        var part = MultipartPart()
        part.name = name
        if let file {
            part.kind = .file
            part.contentType = "application/octet-stream"
            part.file = try UploadFileReference.capture(URL(fileURLWithPath: file))
        } else {
            part.value = value
        }
        return part
    }
}
