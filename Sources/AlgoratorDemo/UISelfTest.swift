import AppKit
import AlgoratorCore

/// `swift run AlgoratorDemo --ui-test "x1,y1,x2,y2;…"`: replays mouse drags inside the app's own window
/// (points in editor coordinates, top-left origin, below the toolbar), prints the resulting first script and
/// quits. Events are injected in-process, so the real pointer is not touched and no permission is needed.
enum UISelfTest {
    static var drags: [[CGFloat]]? {
        guard let index = CommandLine.arguments.firstIndex(of: "--ui-test"), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1].split(separator: ";").map { $0.split(separator: ",").compactMap { Double($0).map { CGFloat($0) } } }
    }

    static func run(_ drags: [[CGFloat]], document: @escaping () -> Document) {
        var events: [(NSEvent.EventType, CGPoint)] = []
        for drag in drags where drag.count == 4 {
            let from = CGPoint(x: drag[0], y: drag[1]), to = CGPoint(x: drag[2], y: drag[3])
            events.append((.leftMouseDown, from))
            for step in 1...12 {
                let t = CGFloat(step) / 12
                events.append((.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
            }
            events.append((.leftMouseUp, to))
        }
        func send(_ index: Int) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return finish("no window") }
            guard index < events.count else { return finish(describe(document())) }
            let (type, point) = events[index]
            let area = window.contentLayoutRect
            let location = CGPoint(x: area.minX + point.x, y: area.maxY - point.y)
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: index, clickCount: 1,
                                              pressure: type == .leftMouseUp ? 0 : 1) {
                window.sendEvent(event)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { send(index + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { send(0) }
    }

    private static func finish(_ text: String) {
        print(text)
        exit(0)
    }

    private static func describe(_ document: Document) -> String {
        func line(_ block: Block, _ depth: Int) -> [String] {
            let inputs = block.inputs.sorted { $0.key < $1.key }.map { name, input -> String in
                switch input {
                case .reporter(let reporter): return "\(name)=(\(reporter.kind))"
                case .variable(let variable): return "\(name)=$\(variable)"
                case .literal: return "\(name)=lit"
                case .empty: return "\(name)=∅"
                }
            }.joined(separator: " ")
            var lines = [String(repeating: "  ", count: depth) + block.kind + (inputs.isEmpty ? "" : " [\(inputs)]")]
            for name in block.regions.keys.sorted() {
                lines.append(String(repeating: "  ", count: depth + 1) + "\(name):")
                lines += (block.regions[name] ?? []).flatMap { line($0, depth + 2) }
            }
            return lines
        }
        return (document.scripts.first?.body ?? []).flatMap { line($0, 0) }.joined(separator: "\n")
    }
}
