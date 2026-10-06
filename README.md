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

A toy "ticket triage" app. It opens with the three acceptance scripts; **Empty** clears the document so they can
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
        try mailer.send(to: inputs.reference("user").id, inputs.text("message"))   // `mailer` must be Sendable
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

## Threading

The package builds with tools 5.9 in the Swift 5 language mode, and is checked with **complete strict
concurrency**; it is usable unchanged from Swift 5 and Swift 6 consumers.

- **`AlgoratorCore` is thread-agnostic.** `Interpreter.run` is synchronous: it runs on whatever thread calls it,
  and the handlers it calls run on that same thread. `Document`, `Vocabulary` and `Interpreter` are `Sendable`
  values with no shared mutable state, so the same ones may be handed to other tasks and used from several
  threads at once. Nothing in the core touches the main thread.
- **A block handler is `@Sendable`.** It may capture only `Sendable` state: immutable values, an actor, or an
  object that guards its own state with a lock. The `RunContext` it receives belongs to that one invocation;
  do not keep it after returning.
- **`AlgoratorEditor`'s UI is main-actor**: the views, `BlockRenderer` and `UndoBridge`. Its pure parts —
  `LayoutEngine`, `HitTest`, `DragController`, the `Script` editing operations — are non-isolated and `Sendable`.
- **`ReferenceProvider` is called on the main actor only**, by the editor. An implementation may read main-actor
  state and need not be `Sendable`.

```swift
let interpreter = Interpreter(document: document, vocabulary: vocabulary)
let result = await Task.detached { interpreter.run(scriptID: id, arguments: arguments) }.value
```

[`Examples/Consumer6`](Examples/Consumer6) is a consumer in the Swift 6 language mode doing this; it must
build without a single warning:

```bash
cd Examples/Consumer6 && swift build && swift run Consumer6
```

## Maps

A block's slots are fixed in number. When a host operation takes a **variable number of named inputs** ("run
this script with parameters *a*, *b*, *c*"), give its block **one slot of type `map`** instead: an ordered map
of named values (text keys, compared exactly; entries keep insertion order; any value, including lists and
other maps).

```swift
.statement("script.run", category: scripts, title: "run %name with %params",
           inputs: [.value("name", .text), .map("params")]) { inputs, _ in
    for entry in inputs.map("params").entries {      // an OrderedMap: entry.key, entry.value, in order
        …
    }
    return [:]
}
```

A map slot has no literal editor; it takes a variable or a reporter. The script builds the map with ordinary
blocks, one entry per block. The nine built-in map blocks (category "Maps"):

| Block | Gives |
|---|---|
| `empty map` | the empty map |
| `(map) with (key) = (value)` | a new map with the entry set (replaced in place, or appended) |
| `(map) without (key)` | a new map without the entry |
| `value of (key) in (map)` | the entry's value, or the empty value |
| `(map) has key (key)` | true or false |
| `keys of (map)` | a list of the keys, in order |
| `number of entries in (map)` | a number |
| `set entry (key) of [variable] to (value)` | statement: rebinds the variable to a new map with the entry set; starts from the empty map when the variable is unset |
| `remove entry (key) of [variable]` | statement: rebinds the variable to a new map without the entry |

Maps are values: no block changes one in place. After `set entry`, a map that was already copied to another
variable or passed to a block is unchanged. As text a map is compact JSON (`{"title":"High","n":2}`), and text
that is a JSON object can be used wherever a map is expected. A block can also *return* a map (the demo's
`review details` does: map in, map out).

The pieces underneath the view are public and pure, for hosts that want their own chrome or tests:
`LayoutEngine` (script → frames), `BlockRenderer` (frames → drawing), `HitTest` (point → drop target),
`DragController` (pick up / move / drop on a value) and the `Script` editing operations.

## Status

A proof of concept. Not built on purpose: loops, events and async execution, several scripts on one canvas,
user-defined block kinds, a textual form, a debugger, localization, iOS. Known limitations and what has and
has not been verified are listed in [DESIGN.md](DESIGN.md).
