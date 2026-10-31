import Foundation
import RillCore

extension RillCLI {
    static func preflight(_ args: Arguments) async throws {
        guard args.operands.count == 1,
            Set(args.values.keys).isSubset(of: [
                "environment-file", "env-var", "ssl-client-cert", "ssl-client-key", "color",
                "folder", "globals",
            ]), args.flags.isSubset(of: ["json", "quiet", "detail"])
        else {
            throw CLIError.usage(
                "Use preflight FILE with --folder, --globals, --environment-file, --env-var, a PEM certificate/key pair, --json or --quiet."
            )
        }
        var report: CollectionPreflight
        do {
            var overrides: [String: String] = [:]
            for row in args.values["env-var"] ?? [] {
                guard let split = row.firstIndex(of: "="), split != row.startIndex else {
                    throw CLIError.usage(
                        "--env-var expects a nonempty key=value; values are never printed.")
                }
                overrides[String(row[..<split])] = String(row[row.index(after: split)...])
            }
            let data = try BoundedFileInput.read(
                URL(fileURLWithPath: args.operand()), limit: 32 * 1024 * 1024)
            let environment = try args.value("environment-file").map {
                try BoundedFileInput.read(URL(fileURLWithPath: $0), limit: 32 * 1024 * 1024)
            }
            report = try CollectionPreflight.inspect(
                collection: data, environment: environment, overrides: overrides,
                folder: args.value("folder"),
                globals: try args.value("globals").map {
                    try BoundedFileInput.read(
                        URL(fileURLWithPath: $0), limit: ResourceLimits.workspaceBytes)
                })
        } catch let error as PostmanFolderSelectionError {
            throw folderSelectionUsage(error)
        } catch CollectionPreflightInputError.insomnia {
            throw CLIError.usage(
                "This looks like an Insomnia export. Preflight accepts Postman v2 JSON; use collection-import --format insomnia for an import preview. No requests sent; source content omitted."
            )
        } catch CollectionPreflightInputError.nativeWorkspace {
            throw CLIError.usage(
                "This looks like a native Rill workspace. Preflight accepts Postman v2 JSON; use list or run-request with --workspace for saved entries. No requests sent; source content omitted."
            )
        } catch let error as CLIError { throw error } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIError.usage(
                "Preflight could not read bounded Postman v2 collection/environment/globals JSON files. No requests sent; input content omitted."
            )
        }
        if args.value("ssl-client-cert") != nil || args.value("ssl-client-key") != nil {
            do {
                let cert = try BoundedFileInput.read(
                    URL(fileURLWithPath: args.required("ssl-client-cert")), limit: 1024 * 1024)
                let key = try BoundedFileInput.read(
                    URL(fileURLWithPath: args.required("ssl-client-key")), limit: 1024 * 1024)
                let executable = URL(fileURLWithPath: "/usr/bin/openssl")
                let publicCert = try await BoundedProcess.run(
                    executable: executable, arguments: ["x509", "-pubkey", "-noout"], input: cert)
                let publicKey = try await BoundedProcess.run(
                    executable: executable,
                    arguments: ["pkey", "-pubout", "-passin", "pass:"], input: key)
                let expiry = try await BoundedProcess.run(
                    executable: executable, arguments: ["x509", "-checkend", "0", "-noout"],
                    input: cert)
                guard publicCert.status == 0, publicKey.status == 0, expiry.status == 0,
                    !publicKey.output.isEmpty, publicCert.output == publicKey.output
                else { throw CocoaError(.fileReadCorruptFile) }
            } catch is CancellationError { throw CancellationError() } catch {
                report.issueCount += 1
                if report.issues.count < 1000 {
                    report.issues.append(
                        .init(
                            "tls.invalid_expired_or_mismatched_pem_pair", "/options/ssl-client-cert"
                        ))
                }
            }
        }
        if args.flags.contains("json") {
            struct Output: Encodable {
                let passed: Bool
                let sendsRequests = false
                let checks: CollectionPreflight
            }
            try args.json(Output(passed: report.passed, checks: report))
        } else {
            try args.text("Rill preflight — offline Postman input inspection")
            if report.folderSelected {
                try args.text(
                    "Scope: selected folder and inherited settings; excluded folders are not checked."
                )
            }
            if report.globalsSupplied {
                try args.text("Inputs: explicit Postman globals supplied.")
            }
            try args.text(
                "Requests: \(report.requests) · Script blocks: \(report.scripts) · Blockers: \(report.issueCount)"
            )
            let displayed = report.issues.prefix(args.flags.contains("detail") ? 1000 : 20)
            for issue in displayed { try args.text("  \(issue.code) at \(issue.location)") }
            if report.issueCount > displayed.count {
                try args.text(
                    "\(report.issueCount - displayed.count) additional blockers; use --detail or --json (up to 1000 records retained)."
                )
            }
            let guidance = [
                "scripts.unsupported":
                    "Postman JavaScript is not executed. Migrate scripts to supported native workflows before treating the suite as equivalent.",
                "variables.unresolved_cyclic_or_limit":
                    "Supply enabled globals/environment values or --env-var overrides; check recursive references. Script-generated values are not inferred.",
                "collection.unsupported_representation":
                    "The collection contains a representation the current Postman importer cannot reproduce. Review its published format limits.",
                "transport.settings_not_applied":
                    "Collection transport settings are not applied. Configure transport explicitly before a future execution run.",
                "tls.invalid_expired_or_mismatched_pem_pair":
                    "Provide a readable, unexpired PEM certificate with its matching unencrypted PEM private key.",
            ]
            for code in Set(report.issues.map(\.code)).sorted() {
                if let text = guidance[code] { try args.text("Next step: " + text) }
            }
            try args.text(
                "No requests sent; no workspace or Keychain changes. Values and script text omitted."
            )
            try args.text(
                "Static checks only: not Newman conformance, server trust verification or an execution plan. Use run for the documented file-execution subset."
            )
            try args.text(
                report.passed
                    ? "Static checks passed."
                    : "Input blocked; resolve the diagnostics before migration.")
        }
        if !report.passed { throw CLIError.usage("Preflight blocked (exit 2); no requests sent.") }
    }
}
