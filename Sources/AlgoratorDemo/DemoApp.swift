import SwiftUI
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

    init() {
        vocabulary = TicketVocabulary.make(directory: directory)
        document = (try? AcceptanceDocument.load()) ?? Document()
    }
}

struct DemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = DemoModel()

    var body: some Scene {
        WindowGroup("Algorator — ticket triage demo") {
            AlgoratorEditorView(document: $model.document, vocabulary: model.vocabulary, references: model.directory)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    if let drags = UISelfTest.drags { UISelfTest.run(drags) { model.document } }
                }
                .toolbar {
                    ToolbarItemGroup {
                        Button("Empty Document") { model.document = Document() }
                            .help("Start from nothing, to build the scripts by dragging")
                        Button("Acceptance Scripts") { model.document = (try? AcceptanceDocument.load()) ?? Document() }
                            .help("Load the two ready-made scripts")
                    }
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
