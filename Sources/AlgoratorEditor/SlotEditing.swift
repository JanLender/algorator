import Foundation
import AlgoratorCore

/// What typing into a slot means. Pure, so the inline editors need no logic of their own.
public enum SlotEditing {
    /// The literal for text typed into a slot with this editor. A number field stores a number when the text
    /// is numeric and `0` when it is blank; text that is not a number is kept as text (validation warns).
    public static func input(fromText text: String, editor: SlotEditor) -> Input {
        switch editor {
        case .number:
            if let number = Coercion.numeric(.text(text)) { return .literal(.number(number)) }
            return .literal(text.trimmingCharacters(in: .whitespaces).isEmpty ? .number(0) : .text(text))
        default:
            return .literal(.text(text))
        }
    }

    /// The text an inline editor starts with.
    public static func text(of input: Input?, timeZone: TimeZone = .current) -> String {
        guard case .literal(let value)? = input else { return "" }
        return Coercion.toText(value, in: RunEnvironment(timeZone: timeZone))
    }

    /// A bool slot flips on click.
    public static func toggled(_ input: Input?) -> Input {
        guard case .literal(let value)? = input else { return .literal(.bool(true)) }
        return .literal(.bool(!Coercion.toBool(value)))
    }

    /// The instant a date/time picker starts on for the slot's current content.
    public static func date(of input: Input?, now: Date = Date(), timeZone: TimeZone = .current) -> Date {
        guard case .literal(let value)? = input else { return now }
        let environment = RunEnvironment(timeZone: timeZone, now: { now })
        switch value {
        case .time(let time):
            // Today at that time.
            let today = Coercion.toDate(.timestamp(now), in: environment)
            return today.flatMap { Coercion.timestamp(date: $0, time: time, in: environment) } ?? now
        default:
            return Coercion.toTimestamp(value, in: environment) ?? now
        }
    }

    /// The literal a date/time picker stores, by the slot's editor.
    public static func input(from date: Date, editor: SlotEditor, timeZone: TimeZone = .current) -> Input {
        let environment = RunEnvironment(timeZone: timeZone)
        switch editor {
        case .date: return Coercion.toDate(.timestamp(date), in: environment).map { .literal(.date($0)) } ?? .empty
        case .time:
            // Pickers work in minutes; drop the seconds.
            guard let time = Coercion.toTime(.timestamp(date), in: environment) else { return .empty }
            return LocalTime(hour: time.hour, minute: time.minute).map { .literal(.time($0)) } ?? .empty
        default:
            // Whole minutes, so a timestamp reads the same on the block as in the picker.
            return .literal(.timestamp(Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)))
        }
    }
}

/// Applies document edits and registers their undo with an `UndoManager`, so ⌘Z, ⇧⌘Z and the Edit menu
/// work the way they do everywhere else on the Mac. Main-actor, like the undo manager it talks to.
@MainActor
public final class UndoBridge: ObservableObject {
    /// Stores a document (the editor points this at its binding).
    public var write: @MainActor (Document) -> Void = { _ in }

    public init() {}

    /// Replaces `old` by `new`; undoing puts `old` back, and redoing `new` again.
    public func commit(from old: Document, to new: Document, name: String, undoManager: UndoManager?) {
        guard old != new else { return }
        write(new)
        undoManager?.registerUndo(withTarget: self) { bridge in
            // The undo manager calls back on the main thread, where it lives.
            MainActor.assumeIsolated {
                bridge.commit(from: new, to: old, name: name, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(name)
    }
}
