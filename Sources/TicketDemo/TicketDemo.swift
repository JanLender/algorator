import Foundation
import os
import AlgoratorCore

/// A fake in-memory help desk: the "host app" of the demo.
///
/// Block handlers run on whatever thread runs the interpreter, so everything they touch is kept behind one
/// lock. That makes the directory genuinely `Sendable`: handlers may capture it, and several runs may use it
/// at once.
public final class TicketDirectory: ReferenceProvider, Sendable {
    public struct Ticket: Sendable {
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

    public struct Notification: Equatable, Sendable {
        public var user: String
        public var message: String

        public init(user: String, message: String) {
            self.user = user
            self.message = message
        }
    }

    private struct State: Sendable {
        var tickets: [String: Ticket]
        var users: [String: String]
        var notifications: [Notification] = []
        var log: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(tickets: [String: Ticket], users: [String: String]) {
        state = OSAllocatedUnfairLock(initialState: State(tickets: tickets, users: users))
    }

    /// Snapshots. To change a ticket use `updateTicket`, which is atomic; assigning here replaces them all.
    public var tickets: [String: Ticket] {
        get { state.withLock { $0.tickets } }
        set { state.withLock { $0.tickets = newValue } }
    }

    public var users: [String: String] { state.withLock { $0.users } }
    public var notifications: [Notification] { state.withLock { $0.notifications } }
    /// What `log details` wrote: one line per entry, in the map's order.
    public var log: [String] { state.withLock { $0.log } }

    /// Three tickets relative to `now`: T-1 is high priority, T-2 is old, T-3 is neither.
    public static func sample(now: Date) -> TicketDirectory {
        TicketDirectory(tickets: sampleTickets(now: now), users: sampleUsers)
    }

    private static let sampleUsers = ["alice": "Alice", "bob": "Bob", "carol": "Carol", "ops": "Ops on call"]

    private static func sampleTickets(now: Date) -> [String: Ticket] {
        let hour = 3600.0
        return [
            "T-1": Ticket(title: "Login page is down", priority: "high", assignee: "alice", opened: now.addingTimeInterval(-1 * hour)),
            "T-2": Ticket(title: "Typo in the footer", priority: "low", assignee: "bob", opened: now.addingTimeInterval(-5 * 24 * hour)),
            "T-3": Ticket(title: "Update the logo", priority: "low", assignee: "carol", opened: now.addingTimeInterval(-3 * hour)),
        ]
    }

    /// Back to the sample data relative to `now`, with no notifications, no labels and an empty log.
    public func reset(now: Date) {
        state.withLock { $0 = State(tickets: TicketDirectory.sampleTickets(now: now), users: TicketDirectory.sampleUsers) }
    }

    public func ticket(_ id: String) -> Ticket? {
        state.withLock { $0.tickets[id] }
    }

    /// Changes one ticket atomically. Returns `false` when there is no such ticket.
    @discardableResult
    public func updateTicket(_ id: String, _ change: @Sendable (inout Ticket) -> Void) -> Bool {
        state.withLock { state in
            guard var ticket = state.tickets[id] else { return false }
            change(&ticket)
            state.tickets[id] = ticket
            return true
        }
    }

    /// Adds a label unless the ticket already has it. Returns whether it was added; `nil` for an unknown ticket.
    public func addLabel(_ label: String, to id: String) -> Bool? {
        state.withLock { state in
            guard var ticket = state.tickets[id] else { return nil }
            guard !ticket.labels.contains(label) else { return false }
            ticket.labels.append(label)
            state.tickets[id] = ticket
            return true
        }
    }

    public func writeLog(_ lines: [String]) {
        state.withLock { $0.log += lines }
    }

    public func notify(user: String, message: String) {
        state.withLock { $0.notifications.append(Notification(user: user, message: message)) }
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

/// The toy vocabulary: built-ins plus the ticket blocks, backed by a `TicketDirectory`. The handlers capture
/// only the directory, which is `Sendable`.
public enum TicketVocabulary {
    public static let tickets = BlockCategory(id: "tickets", title: "Tickets", color: BlockColor(hex: 0x9966FF))
    /// A ticket is overdue once it has been open this long.
    public static let overdueAfter: TimeInterval = 3 * 24 * 3600

    public static func make(directory: TicketDirectory) -> Vocabulary {
        @Sendable func ticket(_ inputs: BlockInputs) throws -> (id: String, ticket: TicketDirectory.Ticket) {
            let id = inputs.reference("ticket").id
            guard let ticket = directory.ticket(id) else { throw BlockError("There is no ticket “\(id)”") }
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
                if directory.addLabel(inputs.text("label"), to: id) == false { context.note("Already labelled") }
                return [:]
            },
            // One map slot instead of a variable number of slots.
            .statement("ticket.logDetails", category: tickets, title: "log details %details",
                       inputs: [.map("details")]) { inputs, context in
                let details = inputs.map("details")
                // One call, so the lines of two concurrent runs never interleave.
                directory.writeLog(details.entries.map { "\($0.key): \(Coercion.toText($0.value, in: inputs.environment))" })
                context.note("Logged \(details.count) \(details.count == 1 ? "entry" : "entries")")
                return [:]
            },
            // Map in, map out. Stands in for a person reviewing the values in a form: every text value is
            // trimmed and the result is marked as reviewed.
            .statement("ticket.reviewDetails", category: tickets, title: "review details %details",
                       inputs: [.map("details")], outputs: [OutputDefinition("reviewed", .map)]) { inputs, context in
                var reviewed = OrderedMap()
                for entry in inputs.map("details").entries {
                    if case .text(let text) = entry.value {
                        reviewed.set(entry.key, .text(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    } else {
                        reviewed.set(entry.key, entry.value)
                    }
                }
                reviewed.set("reviewed", true)
                context.note("Reviewed \(reviewed.count - 1) \(reviewed.count == 2 ? "value" : "values")")
                return ["reviewed": .map(reviewed)]
            },
            .predicate("ticket.isOverdue", category: tickets, title: "ticket is overdue %ticket",
                       inputs: [.reference("ticket", kind: "ticket")]) { inputs, context in
                context.now.timeIntervalSince(try ticket(inputs).ticket.opened) > overdueAfter
            },
        ])
    }
}

/// The acceptance scripts (SPEC.md §10, SPEC-maps.md §4), hand-written as JSON.
public enum AcceptanceDocument {
    public static let escalateTicketID = "escalate-ticket"
    public static let allClearID = "escalate-all-clear"
    public static let detailsID = "escalate-with-details"

    public static func load() throws -> Document {
        guard let url = Bundle.module.url(forResource: "acceptance", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Document(json: Data(contentsOf: url))
    }
}
