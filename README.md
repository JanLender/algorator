# Algorator

A reusable, Scratch-style block editor and interpreter for Swift apps. Proof of concept; see [SPEC.md](SPEC.md)
for the requirements and [DESIGN.md](DESIGN.md) for the decisions taken.

A host app registers its own **blocks** (with native handler closures) in a **vocabulary**. Users snap those
blocks, plus a small built-in set (`if`, `return`, `call script`, variables, operators, time, lists), into
named **scripts**. The library validates, runs, lays out, draws and edits them.

| Product | Contains | Imports |
|---|---|---|
| `AlgoratorCore` | values and coercion, the document model and its JSON, vocabulary, validation, interpreter | Foundation only |
| `AlgoratorEditor` | layout, rendering, hit-testing, editing operations, the SwiftUI editor | SwiftUI, AppKit |

macOS 14+, Swift tools 5.9, no third-party dependencies.

## Try the demo

```bash
swift run AlgoratorDemo
```

A toy "ticket triage" app. It opens with the two acceptance scripts; **Empty** clears the document so they can
be built by dragging, **Open…** / **Save…** read and write the JSON, and **Run** (⌘R) executes the script on
the canvas against fake tickets and shows the trace.

- Drag blocks from the palette; drag them back onto the palette to delete them.
- Click a white field to type; click a darker pill to pick (variables, references, scripts, true/false).
- Click a block to select it, Delete to remove it, ⌘Z / ⇧⌘Z to undo and redo.
- **Edit Script…** sets a script's name, parameters and outputs.

Without a window:

```bash
swift run AlgoratorDemo --trace
```

## Tests

```bash
swift test
```

Snapshot tests render PNGs into [`Snapshots/`](Snapshots) through the same renderer the editor uses.

The gesture wiring can be exercised without touching the mouse. This replays a drag inside the app's own
window (points are in editor coordinates: top-left origin, below the toolbar), prints the resulting script
and quits:

```bash
swift run AlgoratorDemo --ui-test "155,26,456,442"
```

## Using it from another package

During development, depend on a local checkout:

```swift
dependencies: [
    .package(path: "../algorator"),
],
```

Once there is a release, depend on the repository (the URL below is a placeholder) and a version. **A release is a git tag** (`0.1.0`, …);
nothing is published to a registry and consumers build from source:

```swift
dependencies: [
    .package(url: "https://example.com/you/algorator.git", from: "0.1.0"),
],
```

Then add the products a target needs. An app that only runs scripts needs `AlgoratorCore` alone:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "AlgoratorCore", package: "algorator"),
    .product(name: "AlgoratorEditor", package: "algorator"),   // only where the editor is shown
]),
```

[`Examples/Consumer`](Examples/Consumer) is a minimal package doing exactly this by path:

```bash
cd Examples/Consumer && swift run Consumer
```

## The API in one screen

```swift
import AlgoratorCore
import AlgoratorEditor

// A block of the host's own, backed by native code.
let tickets = BlockCategory(id: "tickets", title: "Tickets", color: BlockColor(hex: 0x9966FF))
let vocabulary = Vocabulary([
    .statement("ticket.notify", category: tickets, title: "notify %user message %message",
               inputs: [.reference("user", kind: "user"), .value("message", .text)]) { inputs, context in
        try mailer.send(to: inputs.reference("user").id, inputs.text("message"))   // may throw: the step fails
        context.note("sent")
        return [:]                                                                 // outputs, by name
    },
])

// Persisted form: versioned, diffable JSON.
var document = try Document(json: data)
let saved = try document.jsonData()

// Side-effect-free checks, then a synchronous run with a per-step trace.
let issues = Validator.validate(document, vocabulary: vocabulary)
let result = Interpreter(document: document, vocabulary: vocabulary)
    .run(scriptID: script.id, arguments: ["ticket": .reference(Reference(kind: "ticket", id: "T-1"))])
// result.status: completed | returned | failed | cancelled; result.outputs; result.trace

// The editor. `references` backs the reference pickers; edits register with the window's undo manager.
AlgoratorEditorView(document: $document, vocabulary: vocabulary, references: myDirectory)
```

The pieces underneath the view are public and pure, for hosts that want their own chrome or tests:
`LayoutEngine` (script → frames), `BlockRenderer` (frames → drawing), `HitTest` (point → drop target),
`DragController` (pick up / move / drop on a value) and the `Script` editing operations.

## Status

A proof of concept. Not built on purpose: loops, events and async execution, several scripts on one canvas,
user-defined block kinds, a textual form, a debugger, localization, iOS. Known limitations and what has and
has not been verified are listed in [DESIGN.md](DESIGN.md).
