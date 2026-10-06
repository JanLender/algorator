import AppKit
import AlgoratorCore

/// `swift run AlgoratorDemo --ui-test "x1,y1,x2,y2;x,y;…"`: replays mouse drags (four numbers) and clicks (two)
/// inside the app's own window (points in editor coordinates, top-left origin, below the toolbar), prints the
/// resulting first script and quits. Events are injected in-process, so the real pointer is not touched and no permission is needed.
enum UISelfTest {
    static var drags: [[CGFloat]]? {
        guard let index = CommandLine.arguments.firstIndex(of: "--ui-test"), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1].split(separator: ";").map { $0.split(separator: ",").compactMap { Double($0).map { CGFloat($0) } } }
    }

    static func run(_ drags: [[CGFloat]], document: @escaping () -> Document) {
        var events: [(NSEvent.EventType, CGPoint)] = []
        for click in drags where click.count == 2 {
            let point = CGPoint(x: click[0], y: click[1])
            events += [(.leftMouseDown, point), (.leftMouseUp, point)]
        }
        for drag in drags where drag.count == 4 {
            let from = CGPoint(x: drag[0], y: drag[1]), to = CGPoint(x: drag[2], y: drag[3])
            events.append((.leftMouseDown, from))
            for step in 1...12 {
                let t = CGFloat(step) / 12
                events.append((.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
            }
            events.append((.leftMouseUp, to))
        }
        // Three numbers "0,w,h" resize the window first.
        for resize in drags where resize.count == 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
                window.setFrame(CGRect(origin: window.frame.origin, size: CGSize(width: resize[1], height: resize[2])), display: true, animate: false)
            }
        }
        var attempts = 0
        func send(_ index: Int) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return finish("no window") }
            if index == 0 {
                // SwiftUI ignores the first click in a window that is not key (it only activates the window),
                // so a replay into a background window silently does nothing. Say so instead.
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                guard window.isKeyWindow || attempts >= 20 else {
                    attempts += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { send(0) }
                    return
                }
                let frame = window.frame
                FileHandle.standardError.write(Data("replay: window \(Int(frame.width))×\(Int(frame.height)), key window: \(window.isKeyWindow)\n".utf8))
                guard window.isKeyWindow else {
                    return finish("replay: the window could not become key (another app holds the focus); nothing was replayed")
                }
            }
            guard index < events.count else {
                // Give popovers, focus changes and the like time to settle (and to complain) before quitting.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { finish(describe(document())) }
                return
            }
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
                case .literal(let value): return "\(name)=\(Coercion.toText(value, in: RunEnvironment()))"
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
