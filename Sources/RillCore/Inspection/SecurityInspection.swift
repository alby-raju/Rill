import Foundation

public enum FindingLevel: String, Codable, Sendable { case information, warning }
public struct SecurityFinding: Codable, Equatable, Sendable {
    public let rule: String
    public let level: FindingLevel
    public let evidence: String
    public let guidance: String
}
public enum SecurityInspection {
    public static func passive(_ exchange: Exchange) -> [SecurityFinding] {
        func header(_ name: String) -> String? {
            exchange.headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        var findings: [SecurityFinding] = []
        if URL(string: exchange.url)?.scheme == "https" {
            let hsts = header("Strict-Transport-Security")?.lowercased() ?? ""
            let maxAge = hsts.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("max-age=") }.flatMap {
                    Int($0.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                }
            if maxAge == nil || maxAge! <= 0 {
                findings.append(
                    SecurityFinding(
                        rule: "hsts", level: .warning,
                        evidence: "HTTPS response lacks a positive HSTS max-age",
                        guidance:
                            "Consider HSTS for browser-facing HTTPS origins after verifying all required HTTPS coverage."
                    ))
            }
        }
        let type = APIContractContext.mediaType(header("Content-Type"))
        if type == "text/html",
            (header("Content-Security-Policy") ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        {
            findings.append(
                SecurityFinding(
                    rule: "csp", level: .warning,
                    evidence: "HTML response lacks an enforced Content-Security-Policy header",
                    guidance:
                        "Design a CSP for the application's actual script/resource model. Report-only policies do not enforce it."
                ))
        }
        if header("X-Content-Type-Options")?.lowercased() != "nosniff" {
            findings.append(
                SecurityFinding(
                    rule: "sniffing", level: .warning,
                    evidence: "X-Content-Type-Options is absent or not nosniff",
                    guidance:
                        "Consider nosniff and accurate Content-Type values for browser-facing responses."
                ))
        }
        if let origin = header("Access-Control-Allow-Origin") {
            if origin == "*", header("Access-Control-Allow-Credentials")?.lowercased() == "true" {
                findings.append(
                    SecurityFinding(
                        rule: "cors", level: .warning,
                        evidence: "Wildcard origin and credentialed CORS headers appear together",
                        guidance:
                            "Browsers reject this combination; use a deliberate origin policy. This does not demonstrate exploitable access."
                    ))
            } else if origin != "*",
                header("Vary")?.lowercased().split(separator: ",").contains(where: {
                    $0.trimmingCharacters(in: .whitespaces) == "origin"
                }) != true
            {
                findings.append(
                    SecurityFinding(
                        rule: "cors-cache", level: .information,
                        evidence: "Specific CORS origin without Vary: Origin",
                        guidance:
                            "If the response varies by Origin, include Vary: Origin and review intermediary caching."
                    ))
            }
        }
        return findings
    }
}
public enum ActiveProbeKind: String, CaseIterable, Sendable {
    case quote = "Query quote", reflection = "Reflection marker", rate = "Rate sample"
}
public struct ActiveProbeReport: Sendable {
    public let statuses: [Int]
    public let findings: [SecurityFinding]
    public let cancelled: Bool
}
public enum ActiveProbes {
    /// Explicit invocation only. Does not execute hooks, mutate bodies or expand target templates.
    public static func run(
        url: String, method: HTTPMethod, kind: ActiveProbeKind, queryName: String, count: Int = 1
    ) async throws -> ActiveProbeReport {
        guard [.GET, .HEAD].contains(method), (1...10).contains(count), kind == .rate || count == 1,
            var components = URLComponents(string: url),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.host?.isEmpty == false,
            components.user == nil, components.password == nil, !url.contains("{{"),
            url.utf8.count <= 16384
        else { throw WorkflowError.invalidConfiguration }
        let marker = "rill-probe-" + UUID().uuidString.lowercased()
        if kind != .rate {
            guard !queryName.isEmpty, queryName.utf8.count <= 128 else {
                throw WorkflowError.invalidConfiguration
            }
            var items = components.queryItems ?? []
            guard items.filter({ $0.name == queryName }).count == 1,
                let index = items.firstIndex(where: { $0.name == queryName })
            else { throw WorkflowError.invalidConfiguration }
            items[index].value = (items[index].value ?? "") + (kind == .quote ? "'" : marker)
            components.queryItems = items
        }
        guard let address = components.url?.absoluteString else {
            throw WorkflowError.invalidConfiguration
        }
        var statuses: [Int] = []
        var findings: [SecurityFinding] = []
        var cancelled = false
        for _ in 0..<count {
            do {
                try Task.checkCancellation()
                var request = RequestDraft()
                request.url = address
                request.method = method
                request.timeout = 10
                let response = try await RequestEngine.execute(
                    request, environment: nil, budget: ResponseBudget(downloadBytes: 1024 * 1024),
                    followRedirects: false)
                statuses.append(response.status)
                if kind == .reflection
                    && String(data: response.body, encoding: .utf8)?.contains(marker) == true
                {
                    findings.append(
                        SecurityFinding(
                            rule: "reflection", level: .information,
                            evidence: "The unique query marker appeared in the response body",
                            guidance:
                                "Reflection alone does not prove XSS or another vulnerability; inspect output context and encoding."
                        ))
                }
                if kind == .quote && response.status >= 500 {
                    findings.append(
                        SecurityFinding(
                            rule: "quote", level: .information,
                            evidence: "The quote probe received a server-error status",
                            guidance:
                                "This is an indicator only; no baseline comparison or injection exploit has been established."
                        ))
                }
                if kind == .rate && statuses.count < count {
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError {
                cancelled = true
                break
            } catch let error as URLError where error.code == .cancelled {
                cancelled = true
                break
            }
        }
        if kind == .rate {
            findings.append(
                SecurityFinding(
                    rule: "rate", level: .information,
                    evidence: statuses.contains(429)
                        ? "At least one sample returned HTTP 429"
                        : "No HTTP 429 in this bounded sample",
                    guidance:
                        "At most ten sequential requests cannot establish presence or absence of effective rate limiting."
                ))
        }
        return ActiveProbeReport(statuses: statuses, findings: findings, cancelled: cancelled)
    }
}
