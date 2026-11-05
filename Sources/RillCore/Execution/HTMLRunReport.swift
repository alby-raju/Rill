import CryptoKit
import Foundation

extension RunReportExporter {
    /// Called only after the shared report allowlist and resource validation.
    static func html(_ report: RunReport) -> Data {
        let script = """
            const state = document.getElementById('state');
            const search = document.getElementById('search');
            const rows = Array.from(document.querySelectorAll('tbody tr'));
            function filter() {
              let count = 0;
              const query = search.value.toLowerCase();
              for (const row of rows) {
                row.hidden = (state.value !== 'all' && row.dataset.state !== state.value) ||
                  !row.dataset.request.includes(query);
                if (!row.hidden) count++;
              }
              document.getElementById('visible').textContent = count + ' attempts shown';
            }
            state.addEventListener('change', filter);
            search.addEventListener('input', filter);
            filter();
            """
        let digest = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        let peak = max(report.outcomes.map(\.duration).max() ?? 0, 0.000001)
        let rows = report.outcomes.map { outcome in
            let width = Int(min(100, max(0, outcome.duration / peak * 100)))
            let checks = outcome.checkCount ?? outcome.checks.count
            let failed = outcome.failedCheckCount ?? outcome.checks.filter { !$0.passed }.count
            return """
                <tr data-state="\(xml(outcome.state.rawValue))" data-request="\(outcome.requestID.uuidString.lowercased())">
                <th scope="row"><code>\(outcome.requestID)</code></th>
                <td>\(outcome.iteration)</td><td>\(outcome.attempt)</td>
                <td>\(xml(outcome.state.rawValue))</td><td>\(outcome.status.map(String.init) ?? "—")</td>
                <td>\(failed) / \(checks)</td>
                <td><span class="bar" style="width:\(width)%"></span>\(outcome.duration.formatted(.number.precision(.fractionLength(3)))) s</td>
                </tr>
                """
        }.joined(separator: "\n")
        let document = """
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'sha256-\(digest)'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
            <title>Rill run report</title>
            <style>
            :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
            body { margin: 0 auto; padding: 2rem; max-width: 90rem; }
            h1 { margin-bottom: .5rem; } p { line-height: 1.5; }
            .summary { border: 1px solid #8888; border-radius: .75rem; padding: 1rem; }
            .controls { display: flex; flex-wrap: wrap; gap: 1rem; align-items: center; margin: 1.5rem 0; }
            input, select { font: inherit; padding: .5rem; max-width: 100%; box-sizing: border-box; }
            .table { overflow-x: auto; } table { width: 100%; border-collapse: collapse; }
            th, td { text-align: left; padding: .75rem; border-bottom: 1px solid #8885; white-space: nowrap; }
            th { font-weight: 500; } thead th { font-weight: 700; }
            code { font-size: .8rem; } td:last-child { min-width: 10rem; }
            .bar { display: block; height: .3rem; background: #169b84; margin-bottom: .3rem; }
            tr[data-state="failed"] td:nth-child(4) { font-weight: 700; }
            [hidden] { display: none; }
            @media print { .controls { display: none; } body { padding: 0; } }
            </style></head><body>
            <h1>Rill run report</h1>
            <p>Offline, redacted execution results. Request IDs identify saved requests; labels, URLs, headers, bodies and runtime messages are omitted.</p>
            <div class="summary"><strong>\(report.passed ? "Passed" : "Unsuccessful")</strong>
            · \(report.outcomes.count) attempts · \(report.duration.formatted(.number.precision(.fractionLength(3)))) s
            <p>Cancelled: \(report.cancelled) · Execution budget exhausted: \(report.exhausted) · Stopped: \(report.stopped)</p></div>
            <div class="controls">
            <label>State <select id="state"><option value="all">All</option><option value="failed">Failed</option><option value="passed">Passed</option><option value="cancelled">Cancelled</option><option value="notRun">Not run</option></select></label>
            <label>Request ID <input id="search" type="search" placeholder="Filter by request ID"></label>
            <span id="visible" role="status" aria-live="polite">\(report.outcomes.count) attempts</span></div>
            <noscript><p>All attempts are shown. Enable JavaScript for local filters.</p></noscript>
            <div class="table"><table><caption>All attempts, including retries and unvisited steps. Timing bars are relative to the slowest attempt.</caption>
            <thead><tr><th scope="col">Request ID</th><th scope="col">Iteration</th><th scope="col">Attempt</th><th scope="col">State</th><th scope="col">HTTP status</th><th scope="col">Failed / total checks</th><th scope="col">Duration</th></tr></thead>
            <tbody>\(rows)</tbody></table></div>
            <script>\(script)</script></body></html>
            """
        return Data(document.utf8)
    }
}
