import Foundation
import AlgoratorCore

/// A fake in-memory help desk: the "host app" of the demo.
public final class TicketDirectory: ReferenceProvider {
    public struct Ticket {
        public var title: String
        public var priority: String
        public var assignee: String
        public var opened: Date
        public var labels: [String] = []

        public init(title: String, priority: String, assignee: String, opened: Date) {
            self.title = title
            self.priority = priority
            self.assignee = assignee
            self.opened = opened
        }
    }

    public struct Notification: Equatable {
        public var user: String
        public var message: String

        public init(user: String, message: String) {
            self.user = user
            self.message = message
        }
    }

    public var tickets: [String: Ticket]
    public var users: [String: String]
    public private(set) var notifications: [Notification] = []

    public init(tickets: [String: Ticket], users: [String: String]) {
        self.tickets = tickets
        self.users = users
    }

    /// Three tickets relative to `now`: T-1 is high priority, T-2 is old, T-3 is neither.
    public static func sample(now: Date) -> TicketDirectory {
        let hour = 3600.0
        return TicketDirectory(
            tickets: [
                "T-1": Ticket(title: "Login page is down", priority: "high", assignee: "alice",
                              opened: now.addingTimeInterval(-1 * hour)),
                "T-2": Ticket(title: "Typo in the footer", priority: "low", assignee: "bob",
                              opened: now.addingTimeInterval(-5 * 24 * hour)),
                "T-3": Ticket(title: "Update the logo", priority: "low", assignee: "carol",
                              opened: now.addingTimeInterval(-3 * hour)),
            ],
            users: ["alice": "Alice", "bob": "Bob", "carol": "Carol", "ops": "Ops on call"])
    }

    /// Back to the sample data relative to `now`, with no notifications and no labels.
    public func reset(now: Date) {
        let fresh = TicketDirectory.sample(now: now)
        tickets = fresh.tickets
        users = fresh.users
        notifications = []
    }

    public func notify(user: String, message: String) {
        notifications.append(Notification(user: user, message: message))
    }

    public func candidates(kind: String, matching: String) -> [ReferenceCandidate] {
        let all: [ReferenceCandidate]
        switch kind {
        case "ticket": all = tickets.map { ReferenceCandidate(id: $0.key, label: "\($0.key) — \($0.value.title)") }
        case "user": all = users.map { ReferenceCandidate(id: $0.key, label: $0.value) }
        default: all = []
        }
        return all.filter { matching.isEmpty || $0.label.localizedCaseInsensitiveContains(matching) }
            .sorted { $0.id < $1.id }
    }
}

/// The toy vocabulary: built-ins plus four ticket blocks backed by a `TicketDirectory`.
public enum TicketVocabulary {
    public static let tickets = BlockCategory(id: "tickets", title: "Tickets", color: BlockColor(hex: 0x9966FF))
    /// A ticket is overdue once it has been open this long.
    public static let overdueAfter: TimeInterval = 3 * 24 * 3600

    public static func make(directory: TicketDirectory) -> Vocabulary {
        func ticket(_ inputs: BlockInputs) throws -> (id: String, ticket: TicketDirectory.Ticket) {
            let id = inputs.reference("ticket").id
            guard let ticket = directory.tickets[id] else { throw BlockError("There is no ticket “\(id)”") }
            return (id, ticket)
        }
        return Vocabulary([
            .statement("ticket.fetch", category: tickets, title: "fetch ticket %ticket",
                       inputs: [.reference("ticket", kind: "ticket")],
                       outputs: [OutputDefinition("title", .text), OutputDefinition("priority", .text),
                                 OutputDefinition("assignee", .reference, referenceKind: "user"),
                                 OutputDefinition("opened", .timestamp)]) { inputs, _ in
                let found = try ticket(inputs).ticket
                return ["title": .text(found.title), "priority": .text(found.priority),
                        "assignee": .reference(Reference(kind: "user", id: found.assignee)),
                        "opened": .timestamp(found.opened)]
            },
            .statement("ticket.notify", category: tickets, title: "notify %user message %message",
                       inputs: [.reference("user", kind: "user"), .value("message", .text)]) { inputs, context in
                let user = inputs.reference("user").id
                guard let name = directory.users[user] else { throw BlockError("There is no user “\(user)”") }
                directory.notify(user: user, message: inputs.text("message"))
                context.note("Sent to \(name)")
                return [:]
            },
            .statement("ticket.addLabel", category: tickets, title: "add label %label to %ticket",
                       inputs: [.value("label", .text), .reference("ticket", kind: "ticket")]) { inputs, context in
                let (id, _) = try ticket(inputs)
                let label = inputs.text("label")
                if directory.tickets[id]?.labels.contains(label) == true {
                    context.note("Already labelled")
                } else {
                    directory.tickets[id]?.labels.append(label)
                }
                return [:]
            },
            .predicate("ticket.isOverdue", category: tickets, title: "ticket is overdue %ticket",
                       inputs: [.reference("ticket", kind: "ticket")]) { inputs, context in
                context.now.timeIntervalSince(try ticket(inputs).ticket.opened) > overdueAfter
            },
        ])
    }
}

/// The two acceptance scripts of the spec (§10), hand-written as JSON.
public enum AcceptanceDocument {
    public static let escalateTicketID = "escalate-ticket"
    public static let allClearID = "escalate-all-clear"

    public static func load() throws -> Document {
        guard let url = Bundle.module.url(forResource: "acceptance", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Document(json: Data(contentsOf: url))
    }
}
