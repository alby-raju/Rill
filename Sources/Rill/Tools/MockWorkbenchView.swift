import RillCore
import SwiftUI
import UniformTypeIdentifiers

struct MockWorkbenchView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                RillToolHeading(
                    title: "Local mocks",
                    subtitle: "Saved fixtures, predictable scenarios and local calls.",
                    icon: "server.rack")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            MockWorkbenchContent()
        }.padding(RillSpacing.sheet).frame(width: 1000, height: 740).rillToolControls()
    }
}

struct MockWorkbenchContent: View {
    @EnvironmentObject private var store: WorkbenchStore
    @ViewState<UUID?> private var selection: UUID?
    @ViewState<UUID?> private var routeSelection: UUID?
    @ViewState<String> private var tab = "Routes"
    @ViewState<MockSessionSnapshot?> private var session: MockSessionSnapshot?
    @ViewState<Set<UUID>> private var runningIDs = []
    @ViewState<Bool> private var busy = false
    @ViewState<String?> private var error: String?
    @ViewState<Bool> private var deleting = false
    private var projects: [MockProject] { store.workspace.mockProjects ?? [] }
    private var project: MockProject? { projects.first { $0.id == selection } }
    var body: some View {
        HStack(alignment: .top, spacing: RillSpacing.section) {
            VStack(alignment: .leading, spacing: 12) {
                Text("PROJECTS · \(projects.count)/16").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(projects) { item in
                            SelectionRow(
                                title: item.name,
                                detail: "\(item.routes.count) routes"
                                    + (runningIDs.contains(item.id) ? " · Listening" : ""),
                                icon: "server.rack", selected: selection == item.id
                            ) { selection = item.id }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Button("New project", systemImage: "plus") { add(MockProject()) }.disabled(
                    projects.count >= 16)
                Button("From response…") { responseFixture() }.disabled(
                    store.response == nil || projects.count >= 16)
                Button("Import project…", systemImage: "square.and.arrow.down") { importProject() }
                    .disabled(projects.count >= 16)
            }.padding(14).frame(width: 195).frame(maxHeight: .infinity).rillToolPanel()
            VStack(alignment: .leading, spacing: 12) {
                if let project {
                    projectContent(project).id(project.id)
                } else {
                    RillToolEmpty(
                        title: "Create a local mock",
                        detail:
                            "Projects save fixtures. Listeners start only when you choose Start, and continue when you close this editor.",
                        icon: "server.rack")
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).rillToolControls()
            .onAppear { selection = projects.first?.id }
            .task(id: selection) {
                session = nil
                routeSelection = project?.routes.first?.id
                while !Task.isCancelled {
                    runningIDs = await store.mockSessions.runningIDs()
                    if let id = selection {
                        let snapshot = await store.mockSessions.snapshot(id)
                        if !Task.isCancelled && selection == id { session = snapshot }
                    }
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                }
            }
            .confirmationDialog("Stop and delete this mock project?", isPresented: $deleting) {
                Button("Stop and delete", role: .destructive) {
                    guard let id = selection else { return }
                    store.workspace.mockProjects?.removeAll { $0.id == id }
                    selection = projects.first?.id
                }
            } message: {
                Text("Its saved routes and unapplied JSON draft will be removed.")
            }
    }
    private func binding(_ original: MockProject) -> Binding<MockProject> {
        Binding(
            get: { projects.first { $0.id == original.id } ?? original },
            set: { value in
                guard
                    let index = store.workspace.mockProjects?.firstIndex(where: {
                        $0.id == original.id
                    })
                else { return }
                var updated = projects
                updated[index] = value
                do {
                    try MockProject.validateStorage(updated)
                    store.workspace.mockProjects = updated
                } catch {
                    self.error =
                        "Project storage limit reached. Shorten this draft or remove unused fixtures."
                }
            })
    }
    private func projectContent(_ original: MockProject) -> some View {
        let value = binding(original)
        let active = session?.baseURL != nil
        let changed =
            active
            && (session?.project.routes != original.routes
                || session?.project.port != original.port)
        return VStack(alignment: .leading, spacing: 12) {
            TextField("Project name", text: value.name).accessibilityLabel("Mock project name")
            HStack {
                Text("Port")
                TextField("0", value: value.port, format: .number).frame(
                    width: RillControlWidth.number
                ).accessibilityLabel("Mock port, zero chooses a free port")
                Button(active ? "Restart" : "Start", systemImage: "play.fill") { start(original) }
                    .disabled(busy || session?.starting == true)
                Button("Stop", systemImage: "stop.fill") {
                    let id = original.id
                    Task {
                        await store.mockSessions.stop(id)
                        if selection == id { session = nil }
                    }
                }.disabled(!active && session?.starting != true)
                Spacer()
                RillToolStatus(
                    title: session?.starting == true
                        ? "Starting" : active ? "Listening" : "Stopped", active: active)
            }
            if let url = session?.baseURL {
                HStack {
                    Text(url.absoluteString).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy URL") { copy(url.absoluteString) }
                }
            }
            Text(
                changed
                    ? "Restart to apply edited routes or port. The listener still serves its previous snapshot."
                    : "Loopback only · Up to 4 listeners · Closing this editor keeps servers running until Stop or Quit."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            RillTabs(titles: ["Routes", "JSON", "Calls"], selection: $tab)
            Group {
                switch tab {
                case "JSON": jsonEditor(original, value: value)
                case "Calls": journal(original)
                default: routes(original, value: value, examples: active && !changed)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button("Export project…", systemImage: "square.and.arrow.up") {
                    exportProject(original)
                }
                Spacer()
                Button("Delete project", role: .destructive) { deleting = true }
            }
        }
    }
    private func routes(_ original: MockProject, value: Binding<MockProject>, examples: Bool)
        -> some View
    {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(original.routes.enumerated()), id: \.element.id) {
                            index, route in
                            Button {
                                routeSelection = route.id
                            } label: {
                                Text("\(index + 1). \(route.method.rawValue) \(route.path)").font(
                                    .caption
                                ).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(
                                RillButtonStyle(
                                    emphasis: routeSelection == route.id ? .primary : .quiet,
                                    size: .row))
                        }
                    }
                }
                Button("Add route", systemImage: "plus") {
                    var route = MockRoute()
                    route.path = "/route-\(original.routes.count + 1)"
                    value.wrappedValue.routes.append(route)
                    routeSelection = route.id
                }.disabled(projects.reduce(0) { $0 + $1.routes.count } >= 1000)
            }.frame(width: 155).frame(maxHeight: .infinity)
            if let route = original.routes.first(where: { $0.id == routeSelection }) {
                routeForm(route, project: value, examples: examples).id(route.id)
            } else {
                RillToolEmpty(
                    title: "Add a route",
                    detail:
                        "Routes match in list order. Use different conditions or scenario states for the same path.",
                    icon: "arrow.triangle.branch")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func routeForm(_ original: MockRoute, project: Binding<MockProject>, examples: Bool)
        -> some View
    {
        let route = Binding(
            get: { project.wrappedValue.routes.first { $0.id == original.id } ?? original },
            set: { updated in
                guard
                    let index = project.wrappedValue.routes.firstIndex(where: {
                        $0.id == original.id
                    })
                else { return }
                project.wrappedValue.routes[index] = updated
            })
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RillSection(
                    title: "Request match",
                    subtitle:
                        "Required predicates; extra query parameters and headers are allowed.",
                    icon: "line.3.horizontal.decrease.circle"
                ) {
                    HStack {
                        Picker("Method", selection: route.method) {
                            ForEach(HTTPMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(width: 140)
                        TextField("/path/{id}", text: route.path).accessibilityLabel("Route path")
                    }
                    Text("Query parameters").font(.caption)
                    FieldEditor(
                        fields: Binding(
                            get: { route.wrappedValue.query ?? [] },
                            set: { route.wrappedValue.query = $0 }), noun: "query parameter")
                    Text("Request headers").font(.caption)
                    FieldEditor(
                        fields: Binding(
                            get: { route.wrappedValue.requestHeaders ?? [] },
                            set: { route.wrappedValue.requestHeaders = $0 }), noun: "request header"
                    )
                    Toggle(
                        "Match exact UTF-8 request body",
                        isOn: Binding(
                            get: { route.wrappedValue.expectedBody != nil },
                            set: { route.wrappedValue.expectedBody = $0 ? "" : nil }))
                    if route.wrappedValue.expectedBody != nil {
                        TextEditor(
                            text: Binding(
                                get: { route.wrappedValue.expectedBody ?? "" },
                                set: { route.wrappedValue.expectedBody = $0 })
                        ).frame(height: 90).border(.quaternary)
                    }
                }
                RillSection(
                    title: "Response",
                    subtitle: "Examples are editable fixtures, not schema conformance evidence.",
                    icon: "arrow.turn.down.right"
                ) {
                    HStack {
                        Text("Status")
                        TextField("200", value: route.status, format: .number).frame(
                            width: RillControlWidth.number)
                        Text("Delay (ms)")
                        TextField(
                            "0",
                            value: Binding(
                                get: { route.wrappedValue.delayMilliseconds ?? 0 },
                                set: { route.wrappedValue.delayMilliseconds = $0 }), format: .number
                        ).frame(width: RillControlWidth.number)
                    }
                    Toggle(
                        "Disconnect without a response",
                        isOn: Binding(
                            get: { route.wrappedValue.fault != nil },
                            set: { route.wrappedValue.fault = $0 ? .disconnect : nil }))
                    FieldEditor(fields: route.headers, noun: "response header")
                    CodeEditor(text: route.body, contentType: "application/json", completions: [])
                        .frame(height: 160)
                }
                RillSection(
                    title: "Scenario",
                    subtitle:
                        "States start at ‘start’. A matched request advances state before its response delay.",
                    icon: "arrow.triangle.branch"
                ) {
                    Toggle(
                        "Use scenario state",
                        isOn: Binding(
                            get: { route.wrappedValue.scenario != nil },
                            set: {
                                route.wrappedValue.scenario =
                                    $0 ? MockScenario(name: "scenario") : nil
                            }))
                    if let scenario = route.wrappedValue.scenario {
                        TextField(
                            "Scenario name",
                            text: Binding(
                                get: { route.wrappedValue.scenario?.name ?? scenario.name },
                                set: { route.wrappedValue.scenario?.name = $0 }))
                        TextField(
                            "Required state",
                            text: Binding(
                                get: {
                                    route.wrappedValue.scenario?.requiredState
                                        ?? scenario.requiredState
                                }, set: { route.wrappedValue.scenario?.requiredState = $0 }))
                        TextField(
                            "Next state (empty keeps state)",
                            text: Binding(
                                get: { route.wrappedValue.scenario?.nextState ?? "" },
                                set: {
                                    route.wrappedValue.scenario?.nextState = $0.isEmpty ? nil : $0
                                }))
                    }
                }
                if let origin = original.origin {
                    Text(
                        "Fixture source: \(origin.kind.rawValue) · \(origin.sourceID.uuidString) · \(origin.operation)"
                    ).font(.caption).textSelection(.enabled)
                }
                HStack {
                    Button("Copy cURL") {
                        do {
                            if let base = session?.baseURL {
                                copy(try MockExamples.curl(base: base, route: original))
                            }
                        } catch { self.error = "Validate this route before copying an example." }
                    }.disabled(!examples)
                    Spacer()
                    Button("Move up") { move(original.id, in: project, offset: -1) }.disabled(
                        project.wrappedValue.routes.first?.id == original.id)
                    Button("Move down") { move(original.id, in: project, offset: 1) }.disabled(
                        project.wrappedValue.routes.last?.id == original.id)
                    Button("Delete route", role: .destructive) {
                        project.wrappedValue.routes.removeAll { $0.id == original.id }
                        routeSelection = project.wrappedValue.routes.first?.id
                    }
                }
            }.padding(.trailing, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func move(_ id: UUID, in project: Binding<MockProject>, offset: Int) {
        guard let index = project.wrappedValue.routes.firstIndex(where: { $0.id == id }),
            project.wrappedValue.routes.indices.contains(index + offset)
        else { return }
        project.wrappedValue.routes.swapAt(index, index + offset)
    }
    private func jsonEditor(_ original: MockProject, value: Binding<MockProject>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Unapplied JSON is saved with this project. Apply replaces its routes; restart a running listener separately. Portable exports contain applied routes only."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
            CodeEditor(
                text: Binding(
                    get: { value.wrappedValue.jsonDraft ?? "" },
                    set: { value.wrappedValue.jsonDraft = $0 }), contentType: "application/json",
                completions: [])
            HStack {
                Button("Load applied routes") {
                    do {
                        value.wrappedValue.jsonDraft = String(
                            decoding: try MockRouteFile.encode(original.routes), as: UTF8.self)
                    } catch {
                        self.error =
                            "Routes are invalid. Fix their method, path, status, headers, conditions or limits first."
                    }
                }.disabled(original.jsonDraft?.isEmpty == false)
                Button("Apply JSON") {
                    do {
                        let routes = try MockRouteFile.decode(Data((original.jsonDraft ?? "").utf8))
                        value.wrappedValue.routes = routes
                        value.wrappedValue.jsonDraft = nil
                        routeSelection = routes.first?.id
                        error = nil
                    } catch {
                        self.error =
                            "Invalid route JSON. Check supported fields and limits; the applied routes are preserved."
                    }
                }.disabled(original.jsonDraft?.isEmpty != false)
                Button("Discard draft", role: .destructive) { value.wrappedValue.jsonDraft = nil }
            }
        }
    }
    private func journal(_ project: MockProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "\(session?.requestCount ?? 0) calls · Latest 1,000 retained in memory. Query, headers and payloads are omitted; paths may contain identifiers. Stop discards this session."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
            HStack {
                Button("Reset scenarios and calls") {
                    Task { await store.mockSessions.reset(project.id) }
                }
                Button("Clear calls") { Task { await store.mockSessions.clearJournal(project.id) } }
            }.disabled(session == nil)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach((session?.records ?? []).reversed()) { record in
                        HStack {
                            Text(record.date, style: .time).monospacedDigit()
                            Text(record.method.rawValue + " " + record.path).lineLimit(2)
                            Spacer()
                            Text(record.responseStatus.map(String.init) ?? "Disconnected")
                        }.font(.caption).textSelection(.enabled)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func start(_ project: MockProject) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                guard store.canEdit, projects.contains(where: { $0.id == project.id }) else {
                    return
                }
                try await store.mockSessions.start(project)
                if selection == project.id {
                    session = await store.mockSessions.snapshot(project.id)
                }
            } catch is CancellationError {} catch {
                self.error =
                    "Could not start. Check route validation, duplicate matches, the 4-listener limit and whether the port is already in use."
            }
        }
    }
    private func add(_ project: MockProject) {
        do {
            var all = projects
            all.append(project)
            try MockProject.validateStorage(all)
            store.workspace.mockProjects = all
            selection = project.id
            error = nil
        } catch { self.error = "Project storage limits reached (16 projects, 1,000 total routes)." }
    }
    private func responseFixture() {
        guard let response = store.response else { return }
        let alert = NSAlert()
        alert.messageText = "Create a sanitized response template?"
        alert.informativeText =
            "All payload scalar values are replaced. JSON key names remain: review them before sharing. Original headers and URL are omitted. The route uses /recorded-response; edit it to suit your test."
        alert.addButton(withTitle: "Create template")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let route = try await Task.detached { try MockResponseFixture.route(response) }
                    .value
                add(MockProject(name: "Response template", routes: [route]))
            } catch { self.error = "Response must be complete and within the 1 MiB fixture limit." }
        }
    }
    private func importProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let project = try await Task.detached {
                    try MockProjectFile.decode(
                        BoundedFileInput.read(url, limit: MockProjectFile.maximumBytes))
                }.value
                add(project)
            } catch { self.error = "Invalid mock project file. Existing projects were preserved." }
        }
    }
    private func exportProject(_ project: MockProject) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "mock-project.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await Task.detached {
                    try MockProjectFile.encode(project).write(to: url, options: .atomic)
                }.value
            } catch {
                self.error =
                    "Could not export. Check route validation, file size and destination permissions."
            }
        }
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
