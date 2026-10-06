# Algorator — Maps and strict concurrency (change specification)

Status: change request on top of the existing PoC (`SPEC.md`, `DESIGN.md`, milestones M0–M5 done). Read those first;
this document only adds what is new. It contains **two independent changes**: maps (sections 1–8) and making the
library safe to use under Swift 6 strict concurrency (section 9, milestone M8). Where it is silent, `SPEC.md` still applies (including: no third-party
dependencies, Swift tools 5.9, `AlgoratorCore` imports Foundation only, strict core/editor split, headless tests).

## 1. Why

A block's slots are fixed in number (that stays: a host block such as `show notification` has three slots, `move to
mailbox` one). Some host operations, however, take a **variable number of named inputs** — "run this AppleScript with
parameters *a*, *b*, *c*" or "show these named values for review". A fixed list of slots cannot express that.

The solution is a new **value type: an ordered map of named values**. A block that needs a variable set of named inputs
declares **one** slot of type `map`. The script builds the map with ordinary blocks, one entry per block, and passes the
variable. No new layout or editor machinery is involved: it is a new `Value` case and some built-in blocks.

A repeating-row constructor (a block with a "+" to add entries) is **explicitly not wanted** for now; do not build it.

## 2. The value

### 2.1 Type
`ValueType` gains `map`. `Value` gains a map case holding an **ordered map** with these properties:

- **Keys** are text, compared **exactly** (case-sensitive, no trimming). Keys are unique.
- Entries keep their **insertion order**. Setting an existing key **replaces its value and keeps its position**; setting
  a new key appends. Removing a key removes its entry.
- **Values** are any `Value`, including lists and other maps (arbitrarily nested).
- It is a **value type with value semantics**: copying a map and changing the copy never affects the original.
- Implement it as a small `OrderedMap` struct in `AlgoratorCore` (an array of `(key, value)` plus lookup is fine;
  maps here are tiny). It must be `Equatable`, `Hashable`, `Sendable`, `Codable` where `Value` is.

### 2.2 Coercion (Scratch-style: total, never raises) — add to `Coercion` with tests
- `toMap(value)`: a map passes through; **text that is a valid JSON object** is parsed into a map (nested JSON arrays
  become lists, objects maps, numbers numbers, booleans bools, strings text; `null` becomes the empty value);
  **anything else becomes the empty map**.
- `toText(map)`: compact JSON object text with keys in entry order, no whitespace, e.g. `{"title":"High","n":2}`.
  Value mapping: text → string; number → number (integral without `.0`); bool → bool; date/time/timestamp → their
  `toText` string; reference → its id as a string; list → array; map → object.
- `toBool(map)`: `false` for the empty map, `true` otherwise.
- `toNumber(map)`: `0`.
- `toList(map)`: like any non-list (decision 9): a one-item list holding the map.
- `compare(a, b)` with a map on either side: if **both** are maps, they are equal iff they have the same keys with
  `compare`-equal values (**order does not matter for equality**); if they differ, order by `toText`.
  A map against a non-map compares `toText` of both, case-insensitively, as for any other pair that is not numeric
  or temporal.
- Round trip: `toMap(.text(toText(map))) == map` for maps whose values survive JSON (text, number, bool, list, map).
  Dates/times/references come back as text; this is expected and documented.

### 2.3 Documents (JSON)
- A map value serializes as an **array of key/value pairs**, not a JSON object (object key order is not guaranteed):
  `{"map": [{"key": "title", "value": {"text": "x"}}, {"key": "n", "value": {"number": 2}}]}`.
  This matches the existing single-key-object shape of `Value` (decision 11). Output stays byte-stable (sorted keys
  inside each pair object, entries in map order).
- `schemaVersion` becomes **2**. Version 1 documents load unchanged. A version newer than this build is rejected as
  before (decision 13). Record the choice in `DESIGN.md`.
- Duplicate keys in a hand-edited document: the **last** one wins (and keeps the first one's position); do not fail.

### 2.4 Parameters, outputs, slots
- `ValueType.map` is allowed for script parameters, declared outputs and block outputs, and in `Param` / `OutputDefinition`.
- A slot expecting a map is a normal **round (`value`) slot with `types: [.map]`** and **no literal editor**
  (`SlotEditor.none`): it takes a variable or a reporter. As with every other type, a mismatch is a validation
  **warning**, never a blocked drop (spec §5.3).
- `InputDefinition` gets a convenience `.map(_ name:)` constructor; `BlockInputs` gets `map(_ name:) -> OrderedMap`
  (via `toMap`). A handler may return map values as outputs like any other value.
- The editor: type names/colors for `map` wherever the other types appear (variable chips in the Variables tab,
  validation messages). **No change to layout** is expected; if one turns out to be needed, say why in `DESIGN.md`.

## 3. Built-in blocks (new category "Maps")

All pure; none of them mutates a map in place. Use a new `BlockCategory` with its own colour.

| Block | Shape | Meaning |
|---|---|---|
| `empty map` | reporter | the empty map |
| `%map with %key = %value` | reporter | a **new** map: `map` with `key` set to `value` (replace keeping position, or append) |
| `%map without %key` | reporter | a **new** map with that entry removed (unchanged if absent) |
| `value of %key in %map` | reporter | the entry's value; the **empty value** if the key is absent |
| `%map has key %key` | predicate | whether the key is present |
| `keys of %map` | reporter | a list of the keys as text, in order |
| `number of entries in %map` | reporter | a number |
| `set entry %key of %variable to %value` | statement | rebinds `variable` to a new map: `toMap(variable)` with that entry set. If the variable is unset or not a map it **starts from the empty map**. |
| `remove entry %key of %variable` | statement | rebinds `variable` to a new map without the entry |

Notes:
- `key` slots are text; the value is coerced with `toText`. `value` slots accept anything.
- The two statements use the existing "names a variable" slot editor (`SlotEditor.variable`) for `variable`, like an
  output binding. They are **sugar over rebinding**: after them the variable holds a *new* map. A map already
  copied into another variable or passed to a block is **unchanged** (state this in the block's doc comment).
- Validation: treat `set entry` / `remove entry` as **binding** the named variable (so it counts as set, with type
  `map`, for the "variable read before it can be set" check and for the Variables tab).
- Labels/wording above are suggestions; keep them short and consistent with the existing built-ins.

## 4. Demo (toy domain — still nothing from a real app)

Extend the ticket-triage demo so the feature is visible and testable:

- Host block `log details %details` (statement) taking a **map** slot; its handler writes the entries to the demo's
  fake log (key order preserved) and adds a `note` to the trace.
- Host block `review details %details → %reviewed` (statement, map in, map out). The handler **stands in for a
  person editing values**: it returns the map with each text value trimmed and the key `"reviewed"` set to `true`.
  (It demonstrates the *map in, map out* pattern a real host uses for a blocking review form; the library itself
  gets no such block.)
- A third acceptance script, `Escalate with details` (parameter `ticket: reference(ticket)`):
  1. `fetch ticket (ticket)` → `title`, `priority`, `assignee`;
  2. `set entry "title" of details to (title)`, `set entry "priority" of details to (priority)`,
     `set entry "assignee" of details to (assignee)`  — **three blocks in a row** starting from the unset variable;
  3. `review details (details) → reviewed`;
  4. `log details (reviewed)`;
  5. `return` an output `escalated` = `(value of "reviewed" in reviewed)`.
  It must be buildable **by dragging** exactly like the other two, run in the demo, and its trace must show each step.
- Add it to `acceptance.json`, the demo's initial document and the snapshot tests.

## 5. Tests (extend the existing suites; same standards as before)

- **Core**: every rule in 2.2 table-driven (fixed time zone/clock where dates appear); `OrderedMap` semantics
  (replace keeps position, append, remove, duplicates in input, value semantics under copy); JSON round trip,
  byte-identical, including nested maps/lists; a version-1 document loads; a hand-edited document with duplicate
  keys; every new block (including the two statements rebinding **without** changing a copy held elsewhere —
  test this explicitly); validation of `set entry` as a binding; `toMap` of valid and invalid JSON text.
- **Interpreter**: the third acceptance script from hand-written JSON gives the expected outputs and trace.
- **Editor**: palette lists the new category and blocks; a layout test and a snapshot of the third script; the
  "build it from nothing" test (the existing one that performs the editor's own operations) extended to the third
  script; hit-test/drop tests for a map-typed slot (variable chip accepted, wrong shape rejected, wrong type only warns).
- **Consumer example** (`Examples/Consumer`) keeps building; add a few lines using a map.

## 6. Documentation
- `README`: a short "Maps" paragraph (what they are, the nine blocks, the host pattern "one `map` slot instead of a
  variable number of slots", and **how a host block receives one**: `inputs.map("params")`).
- `DESIGN.md`: continue the decisions log (numbering from 81) for every ambiguity settled here, add the new limitations
  (no literal map editor; no constructor with rows; map equality ignores order), and update "what is verified".

## 7. Milestones (stop and report after each)

| # | Deliverable | Exit criterion |
|---|---|---|
| M6 | `OrderedMap`, `Value`/`ValueType` map case, coercion, JSON, schemaVersion 2, `BlockInputs.map`, `InputDefinition.map` | all core tests of 5 (value, coercion, JSON) pass; a version-1 document still loads |
| M7 | Built-in map blocks, validation, palette category, demo blocks, third acceptance script, snapshots, README/DESIGN | all of section 5 passes; the third script is built by the editor operations test and runs with the right trace; the demo launches (`swift run AlgoratorDemo`) |
| M8 | Strict concurrency, section 9 | `AlgoratorCore` and `AlgoratorEditor` build with complete strict-concurrency checking without warnings; `Examples/Consumer6` (Swift 6 language mode) builds without warnings or errors and runs scripts off the main thread |

Report at each milestone as before: what was built, what the tests cover, what is **not** verified (name the GUI
behaviours that only a human can check), and the command to launch the demo.

## 8. Out of scope
- A constructor block with repeating rows ("+" to add entries), any layout change for variable-length blocks.
- Loops over a map or list (`for each` stays for later).
- Map literals typed into a slot; editing a map in a popover.
- Calling scripts across documents, a typed-operation layer on top of `BlockDefinition`
  (both considered, neither requested here).

## 9. Strict concurrency (Sendable)

### 9.1 Why
`Tajman` is built in the Swift 6 language mode (`swift-tools-version: 6.0`), `Mindler` and `Mailbuster` in Swift 5 mode
(tools 5.9) and run actions on background tasks. Today `BlockHandler`, `Vocabulary`, `Interpreter` and others are not
`Sendable`, so a Swift 6 consumer cannot hand a vocabulary or an interpreter to another task, and a Swift 5 consumer
gets no help from the compiler. The library must be **correct to use from either**, while keeping
`swift-tools-version:5.9` and Swift 5 language mode (the consumers on 5.9 must still be able to load the package).

### 9.2 Threading contract (write it into the doc comments and the README)
- **`AlgoratorCore` is thread-agnostic.** `Interpreter.run` is synchronous and runs on whatever thread calls it; the
  handlers it calls run on that same thread. The same `Document`/`Vocabulary`/`Interpreter` value may be used from
  several threads at once. Nothing in the core touches the main thread or any global mutable state.
- **`AlgoratorEditor` is main-actor.** Every type and function that touches SwiftUI/AppKit, the undo manager or the
  drag state is `@MainActor`. Its pure parts (`LayoutEngine`, `HitTest`, `DragController`, the `Script` editing
  operations) stay **non-isolated and `Sendable`**, as they are pure functions over values.

### 9.3 What to change
- **`BlockHandler`** becomes `@Sendable (BlockInputs, RunContext) throws -> [String: Value]`, and the `reporter` /
  `predicate` convenience constructors take `@Sendable` closures too. (A handler therefore may capture only
  `Sendable` state — a host passes an actor, a lock-protected object or immutable values. This is intended, and a
  source-breaking change for hosts; it is acceptable because nothing is released yet.)
- **`Sendable` conformance** (checked, not assumed) for: every public value type of the document model (`Document`,
  `Script`, `Block`, `Input`, `Param`, `Value`, `ValueType`, `OrderedMap`, `Reference`, `LocalDate`, `LocalTime`, …),
  `BlockDefinition`, `BlockCategory`, `InputDefinition`, `OutputDefinition`, `BlockSignature`, `Vocabulary`,
  `Interpreter`, `BlockInputs`, `RunEnvironment` (already), `RunResult`, `StepOutcome`, `Issue`, `Cancelled`,
  `BlockError`, `ReferenceCandidate`. Prefer real conformance over `@unchecked Sendable`.
- **`RunContext`** is a class handed to handlers; make it genuinely safe: immutable state plus a note sink that is
  guarded (a lock) so a handler that calls `note` from a worker thread cannot corrupt the trace. Document that a
  handler should not keep the context after it returns. Use `@unchecked Sendable` only here, with the lock, and say so.
- **`ReferenceProvider`**: the editor calls it on the main actor. Do **not** force `Sendable` on host implementations;
  document that it is called on the main actor, and make the editor's use of it `@MainActor`.
- **Statics**: any `static let`/`var` holding a non-`Sendable` type (formatters, calendars, `TimeZone` values) must be
  made safe or computed on demand.
- **Closures stored in public types** (`RunEnvironment.now`, `isCancelled`, `BlockDefinition.handler`, the editor's
  callbacks) carry the right `@Sendable`/`@MainActor` annotation.

### 9.4 Checking it (this is what makes the change trustworthy)
- Turn on **complete strict-concurrency checking for the library targets** in `Package.swift` while keeping tools 5.9
  and Swift 5 language mode: `swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]` on `AlgoratorCore`,
  `AlgoratorEditor` and `TicketDemo`. `swift build` must then produce **no concurrency warnings** from the library.
  (If the toolchain spells the setting differently, use the spelling that enables `complete` checking and say which.)
- Add **`Examples/Consumer6`**: a second throwaway consumer like `Examples/Consumer`, but with
  `// swift-tools-version: 6.0` (Swift 6 language mode), depending on the package by path. It registers a block whose
  handler captures only `Sendable` state, runs an `Interpreter` **inside a `Task.detached`**, hands the `Vocabulary`
  and `Document` across the task boundary, shows `AlgoratorEditorView` from a `@MainActor` view, and must build with
  **zero warnings and zero errors**. Wire it so `swift build` there is the check.
- Add a **concurrency test** in `AlgoratorCoreTests`: run the same `Interpreter` from many tasks at once (a
  `TaskGroup` of ~50 runs, including a script that calls another script and one whose handler adds a note) and assert
  every `RunResult` is identical to the single-threaded one.
- Keep every existing test green; update `TicketDemo`, `AlgoratorDemo` and `Examples/Consumer` for the new
  `@Sendable` handler type (their handlers must capture only safe state — fix the demo's fake log/directory with a lock or
  an actor rather than silencing the compiler).

### 9.5 Out of scope for this change
- Making handlers `async`, an async interpreter, or cancellation beyond the existing `isCancelled` poll.
- Reworking the editor into actors; `@MainActor` isolation of the existing view types is the whole story there.
