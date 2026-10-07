import Foundation
import AlgoratorCore
import TicketDemo

/// `swift run AlgoratorDemo --trace`: runs the acceptance scripts in the terminal and prints their traces.
func printTraces() throws {
    let directory = TicketDirectory.sample(now: Date())
    let vocabulary = TicketVocabulary.make(directory: directory)
    let document = try AcceptanceDocument.load()

    let issues = Validator.validate(document, vocabulary: vocabulary)
    print("Validation: \(issues.isEmpty ? "no issues" : issues.map { "\($0.severity) [\($0.blockID)] \($0.message)" }.joined(separator: "; "))")

    for (scriptID, ticket) in [(AcceptanceDocument.allClearID, "T-1"), (AcceptanceDocument.allClearID, "T-2"),
                               (AcceptanceDocument.allClearID, "T-3"), (AcceptanceDocument.detailsID, "T-1"),
                               (AcceptanceDocument.escalateTicketID, "T-4")] {
        let arguments: [String: Value] = ["ticket": .reference(Reference(kind: "ticket", id: ticket))]
        let result = Interpreter(document: document, vocabulary: vocabulary).run(scriptID: scriptID, arguments: arguments)
        let outputs = result.outputs.keys.sorted()
            .map { "\($0) = \(Coercion.toText(result.outputs[$0] ?? .empty, in: RunEnvironment()))" }.joined(separator: ", ")
        print("\n\(document.script(id: scriptID)?.name ?? scriptID)(\(ticket)) → \(result.status.rawValue)\(outputs.isEmpty ? "" : "  " + outputs)")
        for step in result.trace {
            let indent = String(repeating: "    ", count: step.depth)
            let details = [step.message, step.note].compactMap { $0 }.joined(separator: "; ")
            print("  \(indent)\(step.succeeded ? "✓" : "✗") \(step.label)\(details.isEmpty ? "" : "  — \(details)")")
        }
    }

    print("\nLog:")
    for line in directory.log { print("  \(line)") }

    print("\nNotifications sent:")
    for notification in directory.notifications {
        print("  \(notification.user): \(notification.message)")
    }
}
