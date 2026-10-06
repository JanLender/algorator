import SwiftUI
import UniformTypeIdentifiers
import AlgoratorCore
import AlgoratorEditor
import TicketDemo

@main
enum Main {
    static func main() throws {
        if CommandLine.arguments.contains("--trace") {
            try printTraces()
        } else {
            DemoApp.main()
        }
    }
}

/// The host app's state: its fake help desk, the vocabulary built on it, and the document being edited.
final class DemoModel: ObservableObject {
    let directory = TicketDirectory.sample(now: Date())
    let vocabulary: Vocabulary
    @Published var document: Document
    @Published var selectedScript: String?
    @Published var result: RunResult?
    @Published var notifications: [TicketDirectory.Notification] = []
    @Published var error: String?

    init() {
        vocabulary = TicketVocabulary.make(directory: directory)
        document = (try? AcceptanceDocument.load()) ?? Document()
    }

    var script: Script? {
        document.scripts.first { $0.id == selectedScript } ?? document.scripts.first
    }

    var issues: [Issue] {
        script.map { Validator.validate($0, in: document, vocabulary: vocabulary) } ?? []
    }

    /// Runs the script on the canvas against fresh sample data, so every run starts from the same state.
    func run(arguments: [String: Value]) {
        guard let script else { return }
        directory.reset(now: Date())
        result = Interpreter(document: document, vocabulary: vocabulary).run(scriptID: script.id, arguments: arguments)
        notifications = directory.notifications
    }

    func replaceDocument(_ new: Document) {
        document = new
        selectedScript = nil
        result = nil
        notifications = []
    }

    // MARK: Files — the document's JSON is its persisted form

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            replaceDocument(try Document(json: Data(contentsOf: url)))
        } catch {
            self.error = "Could not open \(url.lastPathComponent): \(error)"
        }
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "scripts.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.jsonData().write(to: url)
        } catch {
            self.error = "Could not save: \(error)"
        }
    }
}

struct DemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = DemoModel()

    var body: some Scene {
        WindowGroup("Algorator — ticket triage demo") {
            VSplitView {
                AlgoratorEditorView(document: $model.document, vocabulary: model.vocabulary, references: model.directory,
                                    selectedScript: $model.selectedScript)
                    .frame(minHeight: 320)
                    .layoutPriority(1)
                RunPanel(model: model)
                    .frame(minHeight: 130, idealHeight: 180, maxHeight: 260)
            }
            .frame(minWidth: 940, minHeight: 640)
            .onAppear {
                if let drags = UISelfTest.drags { UISelfTest.run(drags) { model.document } }
            }
            .toolbar {
                ToolbarItemGroup {
                    Button("Empty") { model.replaceDocument(Document()) }
                        .help("Start from an empty document, to build the scripts by dragging")
                    Button("Acceptance") { model.replaceDocument((try? AcceptanceDocument.load()) ?? Document()) }
                        .help("Load the two ready-made acceptance scripts")
                    Button("Open…", action: model.open)
                        .help("Load a document from JSON")
                    Button("Save…", action: model.save)
                        .help("Save the document as JSON")
                }
            }
            .alert("Algorator", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
        }
        .defaultSize(width: 1180, height: 820)
    }
}

/// Arguments, a Run button, the trace, and what the run did to the fake help desk.
struct RunPanel: View {
    @ObservedObject var model: DemoModel
    /// Typed or picked argument values, by parameter name.
    @State private var arguments: [String: String] = [:]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                if let script = model.script {
                    Text("Run “\(script.name)”").font(.headline)
                    ForEach(script.parameters, id: \.name) { parameter in
                        argumentField(parameter)
                    }
                    let errors = model.issues.filter { $0.severity == .error }.count
                    HStack {
                        Button("Run") { model.run(arguments: values(for: script)) }
                            .keyboardShortcut("r", modifiers: .command)
                        if errors > 0 {
                            Label("\(errors) validation error\(errors == 1 ? "" : "s")", systemImage: "exclamationmark.octagon.fill")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                } else {
                    Text("No script to run.").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 250, alignment: .leading)

            Divider()

            if let result = model.result {
                RunTraceView(result: result)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notifications sent").font(.headline)
                    if model.notifications.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.notifications.enumerated()), id: \.offset) { _, notification in
                        Text("\(model.directory.users[notification.user] ?? notification.user): \(notification.message)")
                            .font(.system(size: 12))
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 240, alignment: .leading)
            } else {
                Text("Press Run (⌘R) to execute the script on the canvas against the sample tickets.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }

    @ViewBuilder private func argumentField(_ parameter: Param) -> some View {
        let text = Binding(get: { arguments[parameter.name] ?? defaultText(parameter) }, set: { arguments[parameter.name] = $0 })
        if parameter.type == .reference, let kind = parameter.referenceKind {
            Picker(parameter.name, selection: text) {
                ForEach(model.directory.candidates(kind: kind, matching: "")) { Text($0.label).tag($0.id) }
            }
        } else {
            TextField(parameter.name, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func defaultText(_ parameter: Param) -> String {
        guard parameter.type == .reference, let kind = parameter.referenceKind else { return "" }
        return model.directory.candidates(kind: kind, matching: "").first?.id ?? ""
    }

    private func values(for script: Script) -> [String: Value] {
        script.parameters.reduce(into: [:]) { result, parameter in
            let text = arguments[parameter.name] ?? defaultText(parameter)
            if parameter.type == .reference {
                result[parameter.name] = .reference(Reference(kind: parameter.referenceKind ?? "", id: text))
            } else {
                result[parameter.name] = .text(text)
            }
        }
    }
}

/// A SwiftPM executable has no bundle, so it must ask to be a regular, frontmost app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
