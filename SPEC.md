# Algorator — a reusable, Scratch-style block editor and interpreter for Swift apps (PoC specification)

Status: draft for a proof of concept. Name: **Algorator** (repository `algorator`, Swift package `Algorator`).

## 1. Why this exists

Three of the author's macOS apps (Mailbuster, Tajman, Mindler) each grew their own small "rules / actions" engine, and each re-solved the same problems:

- a **condition tree** (ALL / ANY / NONE groups of field-operator-value atoms) evaluated against a context object;
- an **ordered sequence of actions** whose order matters;
- **variables** flowing through that sequence, and a **stop/return** that ends it early;
- **reuse under a name** (Mailbuster's Catalog; Mindler's Actions calling Actions);
- a bespoke, form-like editor ("add step", pick a kind from a drop-down) that is tedious to use.

The vocabularies differ (`addTag`, `moveToMailbox` / `setCategory`, `takesOverhead` / `createTask`, `readTask`), but the skeleton is identical. This project extracts that skeleton into **one library every Swift app can adopt**, with a visual, Scratch-style editor in place of the drop-down forms.

The PoC must **prove the hard part** (a pleasant block editor with drag-and-drop over a nested tree, plus a small synchronous interpreter), in a toy domain, with no dependency on any of the three apps.

Prior art to *read for ideas, never to depend on or copy vocabulary from* (all under `~/workspace/jl/macos/`): `mindler/Sources/MindlerCore/{Action,ActionRunner,Filter}.swift`, `mailbuster/Sources/MailbusterCore/Rule.swift` and `mailbuster/doc/mailbuster_rules_spec.md`, `tajman/Sources/Tajman/Worklog/WorklogRule.swift`.

## 2. Goals and non-goals

### Goals
1. A **document model** (Codable, versioned, diffable JSON) for scripts built from blocks.
2. A **vocabulary registry** through which a host app supplies its own blocks (with native handler closures) and reference pickers.
3. A **synchronous interpreter** with branching, variables, early return, calling other scripts, per-step outcomes, and side-effect-free validation.
4. A **SwiftUI macOS editor** with the Scratch layout: category tabs and a block palette on the left, one script on a canvas on the right, drag blocks from the palette, snap them in.
5. A **demo app** in a toy domain and a **test suite**, so the result can be judged by running it.

### Non-goals (explicitly out of scope — do not build)
- Loops (`repeat`, `for each`). The model must make them easy to add later (they are just another C-shaped block), but build none.
- Events / hat-block triggering / concurrency / async execution. Execution is **synchronous**; there is no event loop.
- Several scripts visible on the canvas at once, or dragging between scripts.
- Users defining their own *block kinds* (they can only define **scripts** and call them).
- A textual DSL, parser or code generation.
- A debugger/stepper, zoom, minimap, copy/paste between documents, localization, iOS/iPadOS.
- Any dependency on Mindler, Mailbuster, Tajman or third-party packages.

## 3. Platform and constraints
- macOS 14+, Swift 5.9 language mode, SwiftUI, Swift Package Manager. Foundation only; **no third-party dependencies**.
- Work in its own directory/repository. Do not touch the three existing apps.
- Library code uses `public` API deliberately; keep the surface small.
- Two library targets plus a demo and tests (names are suggestions; packaging rules in 3.1):
  - `AlgoratorCore` — values, document model, vocabulary protocol, validation, interpreter. **No UI imports.**
  - `AlgoratorEditor` — SwiftUI editor. Depends on `AlgoratorCore`.
  - `AlgoratorDemo` — executable demo app with a toy vocabulary.
  - `AlgoratorCoreTests`, `AlgoratorEditorTests`.

### 3.1 Packaging and reuse (this is a library other apps will depend on)

The deliverable is a **Swift package**, consumed by other apps through SwiftPM — it is not an app. Other apps live in other repositories and will depend on it either by **local path during development** (`.package(path: "../algorator")`) or by **git URL and version tag** once stable (`.package(url: ".../algorator.git", from: "0.1.0")`). Nothing is published to any registry; consumers build it from source.

Requirements:
- `Package.swift` uses **`// swift-tools-version:5.9`** (not newer — the consuming apps use 5.9 and must be able to load the package) and `platforms: [.macOS(.v14)]`.
- Declare exactly these **products**: `.library(name: "AlgoratorCore", targets: ["AlgoratorCore"])` and `.library(name: "AlgoratorEditor", targets: ["AlgoratorEditor"])`. The demo is an `.executableTarget` and **must not** be exported as a product, so it never travels with the library into a consumer.
- Anything a consuming app needs is `public`; everything else stays `internal`. Keep the public surface small and deliberate, and document each public type with a short doc comment.
- A consumer that only needs the interpreter (no UI) must be able to depend on `AlgoratorCore` alone, without pulling in SwiftUI code.
- **Prove it is consumable**: include a tiny throwaway consumer package (e.g. `Examples/Consumer/`) with its own `Package.swift` that depends on this package via `.package(path: "../..")`, imports `AlgoratorCore` and `AlgoratorEditor`, registers one block, and runs a script. `swift build` in that directory must succeed. (This catches missing `public`s and wrong product wiring, which are invisible from inside the package.)
- The README has a short **"Using it from another package"** section showing the two dependency forms above and the `.product(name:package:)` line for a target, and says that a release is a git tag.

## 4. Core concepts

| Term | Meaning |
|---|---|
| **Script** | A named algorithm: an entry point with typed parameters, optional declared outputs, and a body (a block tree). Scripts are the unit of reuse. |
| **Block** | One node in a script's tree. Has a *kind* (defined by the vocabulary), inputs, and (for C-shaped blocks) child regions. |
| **Slot** | A place in a block that takes a value: a literal, a variable, or a nested reporter block. |
| **Variable** | A named, script-local value. Declared by being a parameter or the target of a binding / `set`. |
| **Vocabulary** | The set of block definitions available (built-in plus host-supplied), with their metadata and handlers. |
| **Host** | The app embedding the library. |

### 4.1 Block shapes (kinds of block)

| Shape | Looks like (Scratch) | Role |
|---|---|---|
| **statement** | puzzle piece with top notch and bottom tab | does something, then continues |
| **c-block** | statement wrapping one or more child regions | `if`, `if/else` (loops later) |
| **cap** | statement with no bottom tab | ends the script (`return`) |
| **reporter** | rounded | produces a value, plugs into a value slot |
| **predicate** | hexagonal | a reporter producing a boolean, plugs into a boolean slot |
| **entry** | rounded "hat" at the top of the script | the script's name and parameters (not draggable, not deletable) |

There is **no separate "condition" and "action" concept**. Conditions are predicate blocks; everything is expressed inside the algorithm.

### 4.2 Scripts, entry points, calling
- A document is a **set of named scripts**; the editor shows **one script at a time** (a selector, e.g. a popup or sidebar list). Several entry points are supported by the model from day one.
- A script may carry an optional `trigger: String?` — opaque metadata for the host (e.g. a handler name). The engine ignores it; it runs a script by id with arguments.
- **Calling a script** is a built-in statement block (`call script`). It is rendered as **one compact shape** showing the callee's name — it is never expanded inline. Its inputs follow the callee's parameters; its outputs bind to variables. Double-clicking it may switch the canvas to the callee (nice to have).
- Recursion depth is limited at run time (default 30); a cycle fails the run with a clear message rather than hanging.

## 5. Values and types

### 5.1 Value types
A small, closed set:

`text`, `number`, `bool`, `date`, `time`, `timestamp`, `reference(kind)`, `list`

- **date**: a calendar day with no time and no time zone (Tajman's `LocalDate` pitfall: do not store it as an instant).
- **time**: a time of day with no date and no zone.
- **timestamp**: an absolute instant (date + time + the instant it denotes).
- **reference(kind)**: an opaque id plus a *kind* string (`"task"`, `"context"`, `"user"` …). References are the one place typing is **strict** (see 5.3).
- **list**: an ordered list of values (element type is not tracked in the PoC).
- An unset variable reads as the empty value (`""`).
- Converting between `timestamp` and `date`/`time`, or combining `date`+`time` into a `timestamp`, needs a time zone: the run environment supplies one (default `TimeZone.current`) and a `now` provider (so tests are deterministic).

### 5.2 Runtime semantics — forgiving, Scratch-style
Scratch is dynamically typed with defined coercions (see `scratch-vm/src/util/cast.js`): values are cast by context and **never raise type errors**. Do the same:

- `toNumber`: numbers pass through; text is trimmed and parsed as a decimal (both `.` and `,` accepted as the separator); anything unparsable → `0`; `bool` → `1`/`0`; other types → `0`.
- `toText`: numbers print canonically (integral values without `.0`); `bool` → `"true"`/`"false"`; `date` → `yyyy-MM-dd`; `time` → `HH:mm` or `HH:mm:ss`; `timestamp` → ISO 8601 with the zone offset; `reference` → its id; `list` → items joined by `"\n"`.
- `toBool`: text `""`, `"0"`, `"false"` (case-insensitive) → `false`, other text → `true`; number `0` → `false`; empty list → `false`; empty reference id → `false`; dates/times/timestamps → `true`.
- `compare(a, b)`: if either is temporal, the other is converted to the same temporal type (text is parsed as ISO); on parse failure fall back to text; chronological order otherwise. Else if both convert to numbers (whitespace-only text is **not** numeric) → numeric. Else case-insensitive text comparison. References compare by kind and id; a reference against text compares its id with the text.
- Coercion functions are total: undefined combinations yield the target type's empty value. They live in `AlgoratorCore` as pure functions with exhaustive unit tests.

### 5.3 Static typing lives in the slot shapes (editor + validation)
- **Slot shapes** (as in Scratch): *boolean* slots (hexagon) accept only predicates; *value* slots (round) accept any non-predicate reporter or a literal; *reference(kind)* slots accept only reporters/variables of that kind, and their literal editor is a **picker** supplied by the host.
- Each slot declares the value types it expects (used for literal editors — a date picker, a number field, a text field — and for validation).
- Dropping is blocked only by **shape** and **reference kind**. Any other type mismatch is allowed but reported by validation as a **warning** (the runtime coerces anyway).

## 6. Document model

All types `Codable`, `Equatable`, `Sendable`. The JSON is the canonical, persisted form and must round-trip losslessly.

```text
Document   { schemaVersion: Int, scripts: [Script] }
Script     { id, name, trigger?: String, parameters: [Param], outputs: [Param], body: [Block] }
Param      { name, type: ValueType, referenceKind?: String }
Block      { id, kind: String,                       // key into the vocabulary
             inputs:   { slotName: Input },
             bindings: { outputName: variableName }, // statement blocks with outputs
             regions:  { regionName: [Block] } }     // "then", "else", ...
Input      = literal(Value) | variable(name) | reporter(Block) | empty
```

Rules:
- Block ids are stable across edits (UI identity, outcomes, validation messages).
- A block of an **unknown kind** (vocabulary changed) must be **preserved** on load/save and shown as a visibly broken block; never dropped.
- `schemaVersion` is checked on load; keep the door open for migrations (no migration code needed yet).
- Entry block data is the `Script` itself (name, parameters, outputs), not a `Block`.

## 7. Vocabulary

A host registers **block definitions**. Nothing about any real domain lives in the library.

```text
BlockDefinition {
  id: String                      // "control.if", "ticket.fetch", ...
  shape: statement | cBlock | cap | reporter | predicate
  category: Category              // id, title, color — drives palette tabs and block color
  title: template                 // e.g. "fetch ticket %ticket" — %names are slots
  inputs:  [InputDefinition]      // name, label, slot shape, accepted types, default, editor
  outputs: [OutputDefinition]     // statement blocks that produce named values (bound to variables)
  regions: [String]               // C-blocks: ["then"] or ["then","else"]
  result:  ValueType?             // reporters/predicates: the type produced
  handler: (Inputs, RunContext) throws -> Outputs   // native code; see 7.2
}
```

- **Editors for slots**: text, number, date, time, timestamp, bool toggle, dropdown (fixed options), **reference picker** (host protocol, below), variable picker.
- **Reference picker**: the host implements `ReferenceProvider { func candidates(kind: String, matching: String) -> [(id: String, label: String)] }`. The demo uses fake data.
- **Output bindings** (`outputs`): a statement block such as `fetch ticket` yields several values at once. Each output is shown as an `→ [variable ▾]` chip on the block; the user picks an existing variable or types a new name.

### 7.1 Built-in vocabulary (provided by `AlgoratorCore`, minimal)
- **Control**: `if`, `if/else`, `return` (cap; one input per declared output of the script), `call script`.
- **Variables**: `set variable to`, plus the variable reporter chips (see 9.3).
- **Operators**: `=`, `≠`, `<`, `>`, `and`, `or`, `not`, `+ − × ÷`, `join`, `contains`, `starts with`, `matches regex`, `is empty`, `length of text`.
- **Time**: `now`, `today`, `date of timestamp`, `time of timestamp`, `make timestamp from date and time`, `add days/hours/minutes`.
- **Lists**: `split text by`, `join list with`, `item n of list`, `length of list`, `list contains`.

Keep each built-in tiny and well tested. Hosts add the rest.

### 7.2 Handlers
- Synchronous and blocking: the engine calls the closure on the thread it is running on and waits. (A host handler may show UI and block; that is the host's concern.)
- A handler may **throw**: the step fails, the run stops, nothing is rolled back (side effects already happened). It may throw a distinguished `Cancelled` error: the run ends as **cancelled**, not failed.
- The `RunContext` gives access to the environment (time zone, `now`), the call depth, and a cancellation flag.

## 8. Interpreter

`run(script, arguments, vocabulary, environment) -> RunResult`

```text
RunResult { status: completed | returned | failed | cancelled,
            outputs: [String: Value],
            trace: [StepOutcome] }          // one per executed block: id, label, succeeded, message?, note?
```

Semantics:
- Blocks execute in order. `if`/`if/else` evaluate their predicate and run one region. A variable bound inside a branch is visible afterwards (empty if that branch did not run).
- `return` ends **the script it is in** (and only that one — a called script's return resumes its caller) with `status = returned`, setting the declared outputs from its inputs. Falling off the end is `completed` with all outputs empty.
- Reporter evaluation is pure and recursive; slot values are coerced per section 5.2.
- A failing step stops the run (`failed`) and the trace ends at it. Steps not reached do not appear in the trace.
- **Validation** (`validate(document) -> [Issue]`) is **side-effect free** and callable at any time. It reports: unknown block kinds; missing called scripts; a variable read where it cannot yet be bound (flow-insensitive on branches: bound in either branch counts as possibly bound after); reference-kind mismatches; empty required inputs; type-mismatch warnings (5.3); a `return` that does not match the script's declared outputs. Each issue carries a block id and a severity (error/warning).

## 9. Editor (SwiftUI, macOS)

### 9.1 Layout (copy Scratch)
- **Left**: a vertical list of **category tabs** (colored dots, titles from the vocabulary) and, beside it, the **palette flyout** listing that category's blocks.
- **Right**: the **canvas** with the current script — the entry block on top, the body stacked beneath. Scrollable. A **script selector** above the canvas.
- Blocks are drawn with **Scratch-like geometry**: category color, stack notch and tab, C-shaped blocks with arms, rounded reporters, hexagonal predicates, white inline editors for literals. Light and dark mode.

### 9.2 Interaction
- **Drag** a block from the palette onto the canvas; drag existing blocks to move them. Dragging a statement carries the blocks beneath it (as in Scratch).
- A live **drop indicator** shows where the block will land: between statements, at the start/end of a C-block region, or **into a slot** (reporters/predicates). Reporter/predicate drops are shape-checked (5.3).
- **Delete** by dragging back over the palette, or Delete/Backspace on a selected block. **Undo/redo** for every edit (⌘Z / ⇧⌘Z).
- Click a literal slot to **edit inline**; dropdown and picker slots open the host-supplied options.
- Each block shows validation issues (error/warning badge with message on hover).
- A **Run** control in the demo shows the `trace` (per-step success/failure/notes).

### 9.3 Variables tab
Lists the script's variables (parameters, bindings, `set` targets) as draggable **variable chips** — drop one into a value slot to read it. This gives Scratch-like fluency without full reporter machinery for variables.

### 9.4 Required architecture of the editor (testability — not optional)
The agent cannot watch the mouse. To keep the work verifiable and honest, split strictly:

1. **Layout is a pure function** over data: `layout(script, vocabulary, metrics) -> LayoutTree` giving every block's, slot's and region's frame. No SwiftUI in it.
2. **Rendering** draws a `LayoutTree` (use `Canvas`/`Shape`; composing nested SwiftUI views for the C-shapes is error-prone). It must render identically headless via `ImageRenderer`.
3. **Hit-testing is a pure function**: `dropTarget(point, dragged: DraggedItem, layout) -> DropTarget?` (insertion index in a region, or a slot).
4. **Editing operations are pure document transformations**: `insert`, `move`, `remove`, `setInput`, … with undo derived from them.
5. The SwiftUI view only wires gestures to 3 and 4.

## 10. Demo and acceptance scenario

The demo app ships a **toy "ticket triage" vocabulary**, deliberately unlike any real app:

- Reference kinds: `ticket`, `user`. A fake in-memory directory backs the pickers.
- Statement `fetch ticket %ticket` → outputs `title: text`, `priority: text`, `assignee: reference(user)`, `opened: timestamp`.
- Statement `notify %user message %text`, statement `add label %text to %ticket`, predicate `ticket is overdue %ticket`.

**Acceptance script** `Escalate ticket` (parameter `ticket: reference(ticket)`, output `escalated: bool`):

1. `fetch ticket (ticket)` → `title`, `priority`, `assignee`, `opened`.
2. `if (priority = "high") or (opened is older than 2 days)` then `notify (assignee) message (join "Escalated: " title)` and `add label "escalated" to (ticket)` and `return (true)`.
3. else `return (false)`.
4. A second script `Escalate all-clear` that **calls** `Escalate ticket` (shown as one shape) and branches on its output.

The PoC succeeds when:
- both scripts can be **built entirely by dragging**, from an empty document, by a person, in a few minutes;
- they run in the demo against the fake data with a correct `trace`;
- the document **round-trips** through JSON, and an unknown block kind survives a load/save;
- validation flags: use of a variable before it can be bound, a wrong reference kind in a slot, and a `return` not matching the declared outputs.

## 11. Testing and verification expectations
- **Core**: exhaustive unit tests for every coercion/compare rule in 5.2 (including date/time/timestamp with a fixed time zone and `now`), each built-in block, `if`/`return` semantics (a return inside a nested region ends the script; a called script's return resumes the caller), recursion limit, validation, JSON round-trip, unknown-kind preservation.
- **Layout**: table-driven tests on `LayoutTree` (e.g. an `if/else` with nested blocks has the expected frames) and **snapshot PNGs** rendered with `ImageRenderer` into a folder the agent **looks at** (open the images and check them against section 9.1; fix what is ugly).
- **Hit-testing**: table-driven tests: given a layout and a point, the expected `DropTarget` (between statements, region start/end, slot, none; shape/kind rejection).
- **Operations**: undo/redo round-trips for each edit.
- GUI behaviour that cannot be tested headlessly is **named explicitly** in the report as untested, not claimed as working.

## 12. Milestones (stop and report after each)

| # | Deliverable | Exit criterion |
|---|---|---|
| M0 | Package skeleton, value types, coercion/compare, document model, JSON | core tests pass |
| M1 | Vocabulary protocol, built-ins, interpreter, validation | acceptance scripts (hand-written JSON) run with the right trace; validation cases pass |
| M2 | Layout engine + static rendering, palette and canvas display (no dragging) | snapshot PNGs of both acceptance scripts look like Scratch blocks |
| M3 | Editing operations + hit-testing + drag and drop on the canvas | table-driven drop tests pass; blocks can be moved/inserted in the demo |
| M4 | Palette → canvas, variables tab, slot editors, reference pickers, undo/redo, delete | acceptance scripts buildable by dragging |
| M5 | Demo polish, run/trace panel, round-trip, `DESIGN.md`, consumer example | all of section 10 demonstrated; `Examples/Consumer` builds against the package by path |

Report at each milestone: what was built, what tests cover, what is **not** verified, and a command to launch the demo.

## 13. Deliverables
- The package and demo, building with `swift build` and testing with `swift test`; a short README with the launch command and the "Using it from another package" section (3.1); the `Examples/Consumer` package.
- **`DESIGN.md`** with a *decisions log*: every place this spec was ambiguous and what was chosen (and why), known limitations, and the hardest problems met (expected: nested C-block layout and drag-and-drop over nested containers). Choose the simplest option when in doubt, and record it.
- The demo must be runnable by the author; the **author judges feel** — optimize for something launchable and honest, not for volume of code.

## 14. Later (design for it, do not build)
- `for each` over a list and a plain `repeat` — additional C-blocks; they will be driven by actions over a multi-selection in the host apps.
- Host-supplied reporter families for filtering/selection (e.g. "attribute of subject"), replacing hard-coded saved-filter engines.
- Typed lists, user-defined reporters, async handlers, localization of block titles.
