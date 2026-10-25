import SwiftUI
import RillCore

struct RunnerView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<String> private var mode = "Collection"
    @ViewState<UUID?> private var collectionID: UUID?
    @ViewState<UUID?> private var requestID: UUID?
    @ViewState<Set<UUID>> private var environmentIDs = []
    @ViewState<RunConfiguration> private var configuration = RunConfiguration()
    @ViewState<LoadConfiguration> private var loadConfiguration = LoadConfiguration()
    @ViewState<Int> private var matrixConcurrency = 1
    @ViewState<RunReport?> private var report: RunReport?
    @ViewState<MatrixReport?> private var matrix: MatrixReport?
    @ViewState<LoadReport?> private var load: LoadReport?
    @ViewState<Bool> private var running = false
    @ViewState<Int> private var completed = 0
    @ViewState<String?> private var error: String?
    @ViewState<Task<Void, Never>?> private var task: Task<Void, Never>?
    @ViewState<UUID> private var generation = UUID()
    private var requests: [RequestDraft] { store.workspace.requests.filter { collectionID == nil || $0.collectionID == collectionID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Run and compare").font(.title2); Spacer(); Button("Done") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Runs use a saved-workspace snapshot. Save drafts first. These actions send real requests to your configured targets; variables stay local to the run. Cancellation and closing stop owned work.").font(.caption).foregroundStyle(.secondary)
            Group {
                Picker("Mode", selection: $mode) { Text("Collection").tag("Collection"); Text("Environment matrix").tag("Matrix"); Text("Load test").tag("Load") }.pickerStyle(.segmented)
                Picker("Saved collection", selection: $collectionID) { Text("All saved requests").tag(nil as UUID?); ForEach(store.workspace.collections) { Text($0.name).tag(Optional($0.id)) } }
                if mode == "Load" {
                    Picker("Saved request", selection: $requestID) { Text("Choose request").tag(nil as UUID?); ForEach(requests) { Text($0.name).tag(Optional($0.id)) } }
                    HStack { number("Requests", $loadConfiguration.count); number("Concurrency", $loadConfiguration.concurrency); number("Ramp (ms)", $loadConfiguration.rampMilliseconds) }
                    Text("1–10,000 requests · 1–64 concurrent · ramp up to 60,000 ms. Each request starts with isolated variables. No implicit retries.").font(.caption)
                } else {
                    HStack { number("Iterations", $configuration.iterations); number("Retries", $configuration.retries); number("Execution limit", $configuration.executionLimit) }
                    HStack { number("Delay (ms)", $configuration.delayMilliseconds); number("Retry delay (ms)", $configuration.retryDelayMilliseconds); Toggle("Stop on failure", isOn: $configuration.stopOnFailure) }
                    if mode == "Matrix" {
                        Stepper("Concurrent environments: \(matrixConcurrency)", value: $matrixConcurrency, in: 1...4)
                        ScrollView(.horizontal) { HStack {
                            ForEach(store.workspace.environments) { environment in
                                Toggle(environment.name, isOn: Binding(get: { environmentIDs.contains(environment.id) }, set: { if $0 { environmentIDs.insert(environment.id) } else { environmentIDs.remove(environment.id) } }))
                            }
                        } }.frame(height: 30)
                        Text("Choose 1–16 environments. Parent values resolve independently; body fingerprints can differ because of dynamic data.").font(.caption)
                    }
                }
            }.disabled(running)
            HStack {
                Button(running ? "Running…" : "Run selected targets") { start() }.buttonStyle(RillButtonStyle(emphasis: .primary)).disabled(running || requests.isEmpty)
                if running { Button("Cancel") { task?.cancel() }; ProgressView().controlSize(.small); Text("\(completed) completed attempts") }
                Spacer()
                if report != nil || matrix != nil {
                    Menu("Export redacted report") { ForEach(RunReportFormat.allCases, id: \.self) { format in Button(format.rawValue) { export(format) } } }
                }
                if load != nil { Button("Export load metrics") { exportLoad() } }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let report { results(report) }
                    if let matrix {
                        Text(matrix.passed ? "Matrix passed" : "Matrix unsuccessful").font(.headline)
                        ForEach(matrix.runs, id: \.environmentID) { run in
                            Text("Environment \(run.environmentID.uuidString)").font(.headline); results(run.report)
                        }
                        ForEach(matrix.comparisons, id: \.requestID) { comparison in
                            Text("\(String(comparison.requestID.uuidString.prefix(8))): states \(comparison.statesDiffer ? "differ" : "match"), checks \(comparison.checksDiffer ? "differ" : "match"), body fingerprints \(comparison.bodiesDiffer ? "differ (possibly dynamic values)" : "match"), not run: \(comparison.includesNotRun ? "yes" : "no")").font(.caption)
                        }
                    }
                    if let load {
                        Text(load.passed ? "Load run passed" : "Load run unsuccessful").font(.headline)
                        Text("Success: \(load.successes) · Failure: \(load.failures) · Cancelled/not run: \(load.cancelled ? "yes" : "no") · \(load.throughput, specifier: "%.2f") requests/sec")
                        Text("Seconds: min \(metric(load.minimum)), p50 \(metric(load.percentile(0.5))), p95 \(metric(load.percentile(0.95))), p99 \(metric(load.percentile(0.99))), max \(metric(load.maximum))")
                    }
                    if report == nil && matrix == nil && load == nil { Text("Select targets and run to see outcomes. Empty or cancelled runs cannot pass.").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 980, height: 720)
        .onAppear { collectionID = store.focusedCollectionID; environmentIDs = Set(store.workspace.selectedEnvironmentID.map { [$0] } ?? []) }
        .onDisappear { generation = UUID(); task?.cancel() }
    }
    private func number(_ label: String, _ binding: Binding<Int>) -> some View { HStack { Text(label); TextField(label, value: binding, format: .number).frame(width: 80) } }
    private func metric(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "—" }
    private func results(_ report: RunReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(report.passed ? "Passed" : "Unsuccessful") · \(report.outcomes.count) outcomes · \(report.duration, specifier: "%.3f") s · Cancelled: \(report.cancelled ? "yes" : "no") · Budget exhausted: \(report.exhausted ? "yes" : "no")").font(.headline)
            ForEach(report.outcomes) { outcome in
                Text("\(String(outcome.requestID.uuidString.prefix(8))) · iteration \(outcome.iteration), attempt \(outcome.attempt) · \(outcome.state.rawValue) · HTTP \(outcome.status.map(String.init) ?? "—") · \(outcome.duration, specifier: "%.3f") s\(outcome.bodyOmitted ? " · body omitted" : "")").font(.system(.caption, design: .monospaced))
            }
        }
    }
    private func start() {
        let snapshot = store.workspace, selectedRequests = requests, selectedMode = mode, config = configuration, loadConfig = loadConfiguration, ids = environmentIDs, parallel = matrixConcurrency, targetID = requestID
        if selectedMode == "Load" && !selectedRequests.contains(where: { $0.id == targetID }) { error = "Choose one saved request."; return }
        if (snapshot.tlsProfiles ?? []).contains(where: { profile in profile.mode == .insecure && selectedRequests.contains { $0.tlsProfileID == profile.id } }) {
            let alert = NSAlert(); alert.messageText = "Run with insecure TLS?"; alert.informativeText = "Selected targets include a profile that disables certificate and hostname verification."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Run with Insecure TLS"); guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        task?.cancel(); generation = UUID(); let id = generation
        report = nil; matrix = nil; load = nil; error = nil; completed = 0; running = true
        task = Task {
            defer { if generation == id { running = false; task = nil } }
            do {
                let environment = try snapshot.selectedEnvironmentID.map { try EnvironmentResolver.resolve($0, in: snapshot.environments) }
                let profiles = snapshot.authProfiles ?? [], secrets = NamedSecretResolver(catalog: snapshot.namedSecrets ?? []), tls = snapshot.tlsProfiles ?? []
                if selectedMode == "Matrix" {
                    let environments = try snapshot.environments.filter { ids.contains($0.id) }.map { try EnvironmentResolver.resolve($0.id, in: snapshot.environments) }
                    let result = try await MatrixRunner.run(requests: selectedRequests, environments: environments, concurrency: parallel, configuration: config, profiles: profiles, secrets: secrets, tlsProfiles: tls, definitions: snapshot.apiDefinitions ?? [])
                    if generation == id { matrix = result }
                } else if selectedMode == "Load", let request = selectedRequests.first(where: { $0.id == targetID }) {
                    let result = try await LoadRunner.run(request: request, environment: environment, configuration: loadConfig, profiles: profiles, secrets: secrets, tlsProfiles: tls, definitions: snapshot.apiDefinitions ?? [])
                    if generation == id { load = result }
                } else {
                    let result = try await CollectionRunner.run(requests: selectedRequests, environment: environment, configuration: config, profiles: profiles, secrets: secrets, tlsProfiles: tls, definitions: snapshot.apiDefinitions ?? [], progress: { progress in
                        await MainActor.run { if generation == id { completed = progress.completed } }
                    })
                    if generation == id { report = result }
                }
            } catch { if generation == id { self.error = error.localizedDescription } }
        }
    }
    private func export(_ format: RunReportFormat) {
        do {
            let reports = report.map { [$0] } ?? matrix?.runs.map(\.report) ?? []
            var files: [String: Data] = [:]
            for (index, report) in reports.enumerated() {
                for (name, data) in try RunReportExporter.files(report, format: format) { files[reports.count == 1 ? name : "environment-\(index + 1)-" + name] = data }
            }
            guard !files.isEmpty, files.values.reduce(0, { $0 + $1.count }) <= 32 * 1024 * 1024 else { throw WorkflowError.limit }
            if files.count == 1, let file = files.first {
                let panel = NSSavePanel(); panel.nameFieldStringValue = file.key
                if panel.runModal() == .OK, let url = panel.url { try RunReportExporter.write(file.value, to: url) }
            } else {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Export here"
                guard panel.runModal() == .OK, let parent = panel.url else { return }
                let stage = parent.appendingPathComponent(".rill-report-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: stage) }
                for (name, data) in files { try RunReportExporter.write(data, to: stage.appendingPathComponent(name)) }
                try FileManager.default.moveItem(at: stage, to: parent.appendingPathComponent("Rill-report-" + UUID().uuidString))
            }
        } catch { self.error = error.localizedDescription }
    }
    private func exportLoad() {
        guard let load else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(load); let panel = NSSavePanel(); panel.nameFieldStringValue = "rill-load.json"
            if panel.runModal() == .OK, let url = panel.url { try RunReportExporter.write(data, to: url) }
        } catch { self.error = error.localizedDescription }
    }
}
