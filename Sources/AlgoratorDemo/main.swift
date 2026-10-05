import Foundation
import AlgoratorCore
import TicketDemo

// Until the editor exists (M2+), the demo runs the acceptance scripts in the terminal and prints their traces.
let directory = TicketDirectory.sample(now: Date())
let vocabulary = TicketVocabulary.make(directory: directory)
let document = try AcceptanceDocument.load()

let issues = Validator.validate(document, vocabulary: vocabulary)
print("Validation: \(issues.isEmpty ? "no issues" : issues.map { "\($0.severity) [\($0.blockID)] \($0.message)" }.joined(separator: "; "))")

for ticket in ["T-1", "T-2", "T-3"] {
    let arguments: [String: Value] = ["ticket": .reference(Reference(kind: "ticket", id: ticket))]
    let result = Interpreter(document: document, vocabulary: vocabulary)
        .run(scriptID: AcceptanceDocument.allClearID, arguments: arguments)
    print("\nEscalate all-clear(\(ticket)) → \(result.status.rawValue)")
    for step in result.trace {
        let indent = String(repeating: "    ", count: step.depth)
        let details = [step.message, step.note].compactMap { $0 }.joined(separator: "; ")
        print("  \(indent)\(step.succeeded ? "✓" : "✗") \(step.label)\(details.isEmpty ? "" : "  — \(details)")")
    }
}

print("\nNotifications sent:")
for notification in directory.notifications {
    print("  \(notification.user): \(notification.message)")
}
