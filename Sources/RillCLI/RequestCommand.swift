import Foundation
import RillCore

extension RillCLI {
    static func request(_ args: Arguments) async throws {
        let tlsValues = FileTLSOptions.values.subtracting(["ssl-client-map"])
        let requestValues: Set<String> = [
            "header", "data", "data-file", "binary-file", "form", "env-var", "output", "download",
            "timeout",
            "color", "workspace", "environment", "auth-profile", "tls", "session",
            "session-key-file",
        ]
        let requestFlags: Set<String> = [
            "json", "quiet", "overwrite", "allow-insecure", "multipart",
        ]
        guard args.operands.count == 2,
            Set(args.values.keys).isSubset(of: requestValues.union(tlsValues)),
            args.flags.isSubset(of: requestFlags.union(FileTLSOptions.flags)),
            let method = HTTPMethod(rawValue: args.operands[0].uppercased()),
            ["data", "data-file", "binary-file", "form"].filter({ args.values[$0] != nil }).count
                <= 1
        else {
            throw CLIError.usage(
                "Use request METHOD URL with one body option: --data, --data-file, --binary-file or repeatable --form. See help request."
            )
        }
        let hasFileTLS =
            !tlsValues.isDisjoint(with: args.values.keys)
            || !FileTLSOptions.flags.isDisjoint(with: args.flags)
        guard args.value("tls") == nil || !hasFileTLS else {
            throw CLIError.usage("Choose a saved TLS profile or explicit file TLS options.")
        }
        let form = try (args.values["form"] ?? []).map(RequestFormField.init)
        guard !args.flags.contains("multipart") || !form.isEmpty else {
            throw CLIError.usage("--multipart requires at least one --form field.")
        }
        let bodyInputs =
            [args.value("data-file"), args.value("binary-file")].compactMap { $0 }
            + form.compactMap(\.file)
        let tlsInputs = FileTLSOptions.inputNames.compactMap { args.value($0) }
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
        let destination = rawOutput ?? download
        guard !args.flags.contains("overwrite") || destination != nil else {
            throw CLIError.usage("--overwrite requires --output or --download.")
        }
        if let output = destination {
            let target = URL(fileURLWithPath: output).resolvingSymlinksInPath()
            guard target != args.workspaceURL.resolvingSymlinksInPath(),
                !(bodyInputs + tlsInputs).contains(where: {
                    target == URL(fileURLWithPath: $0).resolvingSymlinksInPath()
                })
            else {
                throw CLIError.usage(
                    "Output cannot replace the workspace, request body or TLS inputs.")
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
                + (bodyInputs + tlsInputs + [destination].compactMap { $0 })
                .map { URL(fileURLWithPath: $0) })
        var draft = RequestDraft()
        draft.name = "Ad-hoc request"
        draft.method = method
        draft.url = args.operands[1]
        draft.headers = try args.fields("header")
        draft.timeout = try args.seconds()
        guard draft.timeout >= 1 else {
            throw CLIError.usage("--timeout must be between 1 and 300 seconds.")
        }
        if ["data", "data-file", "binary-file", "form"].contains(where: { args.values[$0] != nil })
        {
            guard method != .GET && method != .HEAD else {
                throw CLIError.usage("GET/HEAD bodies are not supported; no payload was discarded.")
            }
            do {
                if let path = args.value("binary-file") {
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
        let fileTLS = try FileTLSOptions(args).load(args)
        let profiles = workspace.authProfiles ?? []
        let secrets = NamedSecretResolver(catalog: workspace.namedSecrets ?? [])
        let tlsProfiles = workspace.tlsProfiles ?? []
        let session = try sessionOptions?.open()
        let summary: RequestSummary
        do {
            if let download {
                let result = try await RequestEngine.download(
                    draft, environment: environment, to: URL(fileURLWithPath: download),
                    overwrite: args.flags.contains("overwrite"), profiles: profiles,
                    secrets: secrets,
                    tlsProfiles: tlsProfiles, fileTLS: fileTLS, cookieJar: session?.jar)
                summary = RequestSummary(
                    status: result.status, duration: result.duration, bodyBytes: result.bodyBytes)
            } else {
                let exchange = try await RequestEngine.execute(
                    draft, environment: environment, profiles: profiles, secrets: secrets,
                    tlsProfiles: tlsProfiles, fileTLS: fileTLS, cookieJar: session?.jar)
                if let output = rawOutput { try args.write(exchange.body, to: output) }
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
        if args.flags.contains("json") {
            try args.json(summary)
        } else {
            try args.text(
                "HTTP \(summary.status) · \(summary.bodyBytes) response bytes · \(String(format: "%.3f", summary.duration)) s"
            )
        }
        if !(200...299).contains(summary.status) { throw CLIError.runtime }
    }
}

private struct RequestSummary: Encodable {
    let schemaVersion = 1
    let status: Int
    let duration: Double
    let bodyBytes: Int
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
