# Algorator — design notes

Kept up to date per milestone. See `SPEC.md` for the requirements.

## Decisions log

Places where the spec was ambiguous, and what was chosen.

### M0 — values, coercion, document model

| # | Question | Decision | Why |
|---|---|---|---|
| 1 | `reference(kind)` as a type | `ValueType` is a plain enum with a `.reference` case; the kind travels beside it (`Param.referenceKind`, `Reference.kind`). | Matches the `Param { type, referenceKind? }` shape in spec §6 and keeps the JSON a plain string. |
| 2 | "Undefined combinations yield the target type's empty value" — but a date, time or timestamp has no empty value | `toDate` / `toTime` / `toTimestamp` return an optional; `Coercion.convert(_:to:)` returns `Value.empty` (`""`) where no conversion exists. | `""` is already what an unset variable reads as, so "no value" has one representation. |
| 3 | `compare` when both sides are temporal but of different types | date vs timestamp compares **days**, time vs timestamp compares **times of day** (both in the environment's zone); date vs time falls back to text. | The spec's "convert the other one" depends on argument order; meeting at the coarser type keeps `compare(a, b)` the mirror of `compare(b, a)`. |
| 4 | Is a `bool` numeric in `compare`? | Yes (`true` = 1), because `toNumber` defines it. `true` vs `"true"` is still equal through the text rule. | Follows "both convert to numbers" literally. |
| 5 | Reference vs reference | Ordered by kind, then id, both **case-sensitive**. A reference against anything else compares its id as text (case-insensitive, per the general rule). | Ids are opaque; two ids differing only in case are different objects. |
| 6 | Decimal text syntax | Optional sign, digits, one `.` or `,`, optional exponent. `1,234.5`, `inf`, `nan`, hex → not numeric. | "Parsed as a decimal"; a comma is a decimal separator, never a thousands separator. |
| 7 | Timestamp precision | Milliseconds, in both text and JSON. JSON is always UTC (`…Z`); `toText` uses the environment's offset (`+02:00`, and `+00:00` rather than `Z`). | Stable, diffable files regardless of the machine's zone. Sub-millisecond precision is lost on save. |
| 8 | Zoneless timestamp text (`2026-10-04 12:00`) | Interpreted in the environment's zone. `T` or a space is accepted as the separator. | What a person typing into a slot means. |
| 9 | `toList` of a non-list | `""` → empty list; any other value → a one-item list. | An unset variable then has length 0. |
| 10 | Ids | `String` (a UUID by default). | Readable in hand-written JSON and in validation messages. |
| 11 | JSON shape of `Value` and `Input` | Single-key objects: `{"text": "high"}`, `{"variable": "priority"}`, `{"reporter": {…}}`, `{"empty": true}`. Empty `inputs` / `bindings` / `regions` are omitted on save and optional on load. | Compact and diffable; sorted keys make output byte-stable. |
| 12 | Non-finite numbers in JSON | Saved as `0`. | JSON cannot express them; a document must never become unsaveable. |
| 13 | `schemaVersion` | A newer version than this build knows is rejected (`DocumentError.unsupportedSchemaVersion`); older ones would be migrated in `Document.init(from:)`. | Spec §6. |
| 14 | Unknown block kinds | `Block` carries no knowledge of the vocabulary, so any kind round-trips untouched. Unknown *JSON fields* are not preserved. | Simplest thing that satisfies §6. |

### M1 — vocabulary, built-ins, interpreter, validation

| # | Question | Decision | Why |
|---|---|---|---|
| 15 | Spec §5.3 says value slots accept "any non-predicate reporter" | Value slots **also accept predicates**, as in Scratch. Boolean slots stay strict (predicates only — no variables, no literals). | Otherwise a computed condition could never be stored in a variable or returned. The price: branching on a boolean variable is `if (escalated = true)`, which is what the second acceptance script does. |
| 16 | Where the toy vocabulary lives | A fourth, non-product target `TicketDemo` (fake directory, four ticket blocks, `acceptance.json`), used by the demo executable and by the tests. | Tests cannot cleanly import an executable target; products are still exactly the two libraries. |
| 17 | `Category` in spec §7 | Named `BlockCategory`; colour is a UI-free `BlockColor` (sRGB). | A public `Category` would collide with the Objective-C runtime's `Category` in consumers. |
| 18 | Handler signature for reporters | One stored signature (`(BlockInputs, RunContext) throws -> [String: Value]`, as in the spec); reporters put their value under `"result"`. Factories `.statement` / `.reporter` / `.predicate` hide this. | One closure type keeps the definition a plain struct. |
| 19 | Are definitions `Sendable`? | No. `Vocabulary` and `BlockDefinition` are not `Sendable`, and handlers are not `@Sendable`. Document types are. | Host handlers touch the host's own (often main-actor) objects; the engine is synchronous and never hops threads. |
| 20 | Slot coercion "per §5.2" | Inputs reach the handler raw; the typed accessors on `BlockInputs` (`text`, `number`, `bool`, `date`, `reference`, …) coerce. | The handler knows what it needs; nothing is lost by an early cast (a date slot would otherwise turn unparsable text into empty before the handler could see it). |
| 21 | Dynamic slots of `return` and `call script` | `Vocabulary.signature(of:in:document:)` resolves a block's actual title, slots and outputs. `return` gets one slot per declared output (keyed by its name); `call script` has a `script` slot (the callee's id) plus `arg.<parameter>` slots, and the callee's outputs. | One function shared by the interpreter, validation and (later) layout, so they cannot disagree. Titles are `[TitlePart]`, not strings, because parameter names may contain spaces. |
| 22 | `set variable` | The variable name is a text literal in a slot whose editor is `.variable`. | Fits the model without a new `Input` case. |
| 23 | What is traced | One step per executed **statement** (C-blocks and calls included, recorded before their children). Reporters are part of their statement; a throwing reporter fails that statement. Labels are the title with evaluated inputs, e.g. `fetch ticket T-1`. | "One per executed block" taken as stack blocks; tracing every nested reporter would bury the trace. |
| 24 | Failure inside a called script or a branch | Only the failing step is marked failed; the enclosing `call` / `if` steps stay as they were. `RunResult.message` repeats the reason. | "The trace ends at it." |
| 25 | Recursion limit | Depth 0 is the script that was run; a call from depth 30 is refused (`RunEnvironment.maxCallDepth`). | Spec §4.2. |
| 26 | Cancellation flag | `RunEnvironment.isCancelled`, polled before every statement; handlers see it as `RunContext.isCancelled` and may also throw `Cancelled`. | Spec §7.2. |
| 27 | Arithmetic that leaves the finite numbers | Division by zero and overflow give `0`. | Numbers stay finite, so they always print, compare and save. (Scratch gives `Infinity`.) |
| 28 | `and` / `or` | Both sides are always evaluated. | Reporters are pure, so short-circuiting is unobservable. |
| 29 | `contains`, `starts with`, `list contains` | Case-insensitive, like `=`. `x contains ""` is false; `x starts with ""` is true. | Consistent with `compare`. |
| 30 | `matches regex` with an invalid pattern | False. | Coercion-style: never raise. |
| 31 | `add days` | To a date: calendar days. To a timestamp: calendar days in the environment's zone (wall-clock time survives a DST change). `add hours/minutes`: exact seconds on a timestamp; wraps around midnight on a time. | The least surprising reading of each. |
| 32 | `item n of list` | 1-based; out of range is empty. `split` by an empty separator gives one item. | As in Scratch. |
| 33 | Severity of validation findings | Errors: unknown kind, missing callee, wrong shape, wrong reference kind, variable read before it can be set (or never set), empty required slot, `return` not matching the outputs. Warnings: type mismatches and a dropdown literal outside its options. | Spec §8 and §5.3. |
| 34 | When does a type mismatch warn? | Not when the slot accepts text (everything converts), not for an untyped slot or a variable/reporter of unknown type, and not for a text literal that converts (`"12"` in a number slot). | Keeps warnings meaningful. |
| 35 | Variable types for validation | Parameters and output bindings are typed; a `set` target, or a name bound to outputs of different types, is "unknown" and is accepted everywhere. | Flow-insensitive and simple. |
| 36 | Empty slots | A slot with a default evaluates to it and is not "empty" for validation; a boolean slot without a predicate is false at run time and an error in validation. An empty text literal is a value, not a missing input. | So freshly dragged blocks validate. |
| 37 | Host-defined C-blocks and caps | A host cap ends the script (as `returned`, no outputs). A host C-block runs its handler and its regions are ignored. | Loops are out of scope; this is where `for each` will hook in (§14). |

### M2 — layout, rendering, static editor

| # | Question | Decision | Why |
|---|---|---|---|
| 38 | How layout measures text without SwiftUI | `LayoutMetrics` carries a `measure(text, role)` closure. `.standard` measures with the system font through AppKit; `.fixed()` makes every character 7×14 for tests. | Layout stays a pure function, and its tests compare against hand-computed frames. |
| 39 | Layout algorithm | Each block is laid out at the origin (rows of pieces, then regions) and translated into place by its parent. Frames in the `LayoutTree` are absolute canvas coordinates. | Simplest correct thing; the tree is small, so repeated translation costs nothing noticeable. |
| 40 | A C-block's `frame` | Covers its own bars only. Children wider than the block stick out (as in Scratch); `bounds` includes them and the canvas grows to fit. | A parent that widened with its children would make every drop reflow the whole stack. |
| 41 | Shape of a misplaced block | Decided by position: anything in a stack is drawn as a statement, anything in a slot as a reporter. | A hand-edited or broken document must still show every block. |
| 42 | Unknown kinds | Grey, dashed red outline, label `unknown: <kind>`, error badge. Their regions are still drawn (sorted by name); their inputs are not. | "Visibly broken, never dropped." |
| 43 | Output bindings | A `→` and one menu-style chip per output. One output shares the title row; several get a second row. The chip reads `title` when bound to a variable of the same name, `opened → since` when renamed, `priority → …` when unbound. | Four chips on the title row made `fetch ticket` far too wide. |
| 44 | Fresh blocks | `BlockFactory.make` fills typeable slots with their default literals and binds every output to a variable of its own name. | A dropped `fetch ticket` is immediately useful and validates. |
| 45 | `call script` in the palette | One prototype per script of the document, already pointing at it. | Like Scratch's "My Blocks": no picker step after the drop. |
| 46 | Entry block | A hat showing the script name, parameters as variable chips, then `→` and the declared outputs. | Spec §4.1. |
| 47 | Literal styles | Typeable literals (text, number, date, time, timestamp) are white pills; picked ones (dropdown, reference, variable name, script, bool) are darker pills with a ▾. Long text is truncated at 32 characters. | Mirrors Scratch's fields vs. menus. |
| 48 | Geometry | Straight-sided notches (Scratch 2 style), 4 pt corners, 14 pt arm, hexagon tips capped at 12 pt. More compact than Scratch 3. | Reads well at 12 pt system font; all of it lives in `LayoutMetrics`. |
| 49 | Dark mode | Blocks keep their colours; only the canvas background follows the system. | As in Scratch; block colours carry meaning. |
| 50 | Snapshots | `SnapshotTests` render through `ImageRenderer` into `Snapshots/` (committed), using the same `BlockRenderer` as the on-screen `Canvas`. | The pictures can be reviewed without running anything. |

### M3 — editing operations, hit-testing, drag and drop

| # | Question | Decision | Why |
|---|---|---|---|
| 51 | How a move avoids dropping a block into itself | Picking up **removes** the dragged blocks; hit-testing runs against the layout of the *remaining* script, and the drop inserts into that. `moving` = `removing` + `inserting`. | No index fix-ups and no "is the target inside the dragged subtree" check: the subtree is simply not there. |
| 52 | Which point is hit-tested | A stack snaps by the **top-left corner of the dragged stack** (puzzle-piece feel). A reporter or variable goes into the slot **under the pointer**. | A wide reporter grabbed at its right end should land where you point. |
| 53 | Snapping of stacks | The nearest insertion point within 28 pt vertically and −40…+120 pt horizontally of the region's left edge; score `|dy| + 0.3·|dx|`, so indentation picks between "end of the mouth" and "after the C-block". Anywhere below the script appends to it. | Forgiving, and still deterministic enough to table-test. |
| 54 | Caps | Nothing may follow a cap: no insertion after one in a region, and a dragged stack that ends in a cap only fits at the end of a region. | Otherwise unreachable blocks could be built by dragging. |
| 55 | Dropping onto an occupied slot | A slot holding a literal, a variable chip or nothing is a target (its content is replaced). A slot holding a **reporter is not**: drag that reporter out first. | There is no free-floating workspace for an ejected reporter to land in, and silently discarding a whole expression is too destructive. |
| 56 | What a slot is left with when its reporter or variable is dragged out | Its default literal if it is typeable, otherwise empty (`BlockFactory.emptyInput`). | Same state as a freshly created block. |
| 57 | Dropping nowhere | Cancels: the script is unchanged. (Deleting by dropping on the palette comes in M4.) | One script per canvas means there is nowhere for loose blocks to stay. |
| 58 | Reference-kind check on drop | A reporter or variable whose type is statically **unknown** is accepted by a reference slot; a known wrong kind or a known non-reference type is refused. Same rule as validation. | A `set` variable has no type; refusing it would make such variables unusable. |
| 59 | Parameter chips on the entry block | Draggable; dragging one **copies** it. | As in Scratch's `define` block. |
| 60 | Drop indicator | A blue bar at the insertion point, or a blue outline round the target slot. The canvas does not open a gap. | Simple and unambiguous; a Scratch-style gap would need a second layout per pointer move. |
| 61 | Where the logic lives | `Script` operations (pure), `HitTest` (pure), `DragController` (pure: begin / move / drop on a `DragState` value). The SwiftUI view converts pointer positions to canvas coordinates and calls these three. | Spec §9.4; everything but the gesture wiring is tested headless. |
| 62 | Coordinates across panes | One named coordinate space on the editor; the canvas and the palette report their frames in it (a `GeometryReader` with `onChange`), and the ghost is drawn in an overlay above the whole editor. | One mechanism for canvas drags, palette-to-canvas drags and the delete zone. A first version passed the frames up as SwiftUI preferences; they never arrived, so every pointer position was offset and no drag worked until the M4 fix. |

### M4 — palette, slot editors, pickers, scripts, delete, undo

| # | Question | Decision | Why |
|---|---|---|---|
| 63 | Undo mechanism | Every edit replaces the whole `Document` through `UndoBridge`, which registers the inverse with the window's `UndoManager`. | ⌘Z, ⇧⌘Z and the Edit menu work as in any Mac app, and a host's own undo stack (e.g. a document-based app) includes editor changes. Documents are small values, so snapshots are cheap. |
| 64 | Granularity of undo | One step per drop, per committed literal, per picker choice, per "Done" in the script form. Typing inside a field is the field's own undo until committed. | Matches what the user thinks of as one action. |
| 65 | Deleting | Dropping blocks taken from the script onto the palette deletes them (the palette turns red with a trash icon). Delete/Backspace deletes the **selected block only**; statements beneath it stay. | Dragging carries the stack, so the key is the way to remove one block from the middle. |
| 66 | Selection | A click on a block selects it (yellow outline); a click on a slot opens its editor instead; a click elsewhere deselects. | Slots are much more often edited than their blocks selected. |
| 67 | Slot editors | Text and number: an inline field over the slot (Return or clicking away commits, Esc cancels). Bool: flips on click. Date / time / timestamp: a popover with a date picker. Dropdown, reference, variable name, script: a popover list; the reference list is searchable through the host's `ReferenceProvider`. | Spec §7 and §9.2 with the least custom UI. |
| 68 | A number field given non-numeric text | Kept as text (validation warns); blank becomes `0`. | Never silently discard what was typed. |
| 69 | Date pickers | Work in whole minutes; a time slot stores `HH:mm`. | What the standard picker offers. |
| 70 | Output bindings | Clicking a chip lists the script's variables, takes a new name, or unbinds ("Don’t store it"). | Spec §7. |
| 71 | The entry block's data | Edited in a form ("Edit Script…": name, parameters, outputs, delete), not on the canvas. "New Script" opens it straight away. | The entry block is "not draggable, not deletable"; a small form is the simplest honest editor for a signature. |
| 72 | Renaming a parameter or variable | Does not rename its uses; validation then flags them as never set. | A rename refactoring is out of scope for the PoC. |
| 73 | Validation messages | A bubble next to the pointer lists the issues of the block under it. | A standard tooltip cannot be given a different text per region of one `Canvas`. |
| 75 | Testing the gesture wiring | `swift run AlgoratorDemo --ui-test "x1,y1,x2,y2;…"` replays mouse drags inside the app's own window (in-process events, editor coordinates), prints the resulting script and quits. | The pure layers were fully tested and the app was still broken; this exercises the one layer the unit tests cannot reach, without moving the real pointer or needing permissions. |
| 74 | Double-clicking a `call` block to open the callee | Not built. | Marked nice-to-have in the spec; a second tap gesture would delay every single click. |

### M5 — demo, run panel, packaging

| # | Question | Decision | Why |
|---|---|---|---|
| 76 | Where the Run control lives | The demo owns the argument form and the Run button; the library offers a reusable `RunTraceView(result:)`. | Arguments are the host's business (where they come from, how they are picked); showing a trace is generic. |
| 77 | How the demo knows which script to run | `AlgoratorEditorView` takes an optional `selectedScript` binding; without one it tracks the selection itself. | The smallest addition to the public surface that lets a host act on the visible script. |
| 78 | State between demo runs | Every run starts from fresh sample tickets. | Runs are repeatable; "add label" does not pile up. |
| 79 | Persistence in the demo | Open… / Save… read and write the document's JSON; nothing is saved automatically. | Shows the round-trip without inventing a document architecture. |
| 80 | Consumer example | `Examples/Consumer` depends on the package by path, registers a block, validates, runs, round-trips, lays a script out and embeds `AlgoratorEditorView` in a view. It exits non-zero if any of that misbehaves. | Catches missing `public`s and wrong product wiring from the outside. |

## What is verified, and how

| Area | How |
|---|---|
| Coercion, compare, dates and times | Table-driven unit tests with a fixed time zone and clock. |
| Document JSON | Byte-identical round-trip; hand-written JSON; unknown kinds; newer schema rejected; malformed input rejected. |
| Built-in blocks, interpreter | Unit tests per block and per rule of spec §8, plus the acceptance scripts on fake data. |
| Validation | Unit tests for every finding of spec §8, including the three named in §10. |
| Layout | Unit tests against hand-computed frames with a fixed-width measurer. |
| Rendering | 13 snapshot PNGs in `Snapshots/`. Eight were inspected by eye during development (both acceptance scripts, the dark variant of one, the shapes sheet, three palettes, both drag pictures). |
| Hit-testing, editing operations, drag logic | Table-driven and scenario unit tests; no view involved. |
| Undo / redo | Eleven kinds of edit round-tripped through a real `UndoManager`. |
| Building the acceptance scripts from nothing | A unit test performs the same operations the editor performs, checking each drop against the slot rules, and compares the traces with the hand-written document. |
| Drag gestures in the real window | `--ui-test` replays: palette → canvas, moving a stack, a reporter into a slot, deleting on the palette. The author also tried the demo by hand. |
| Consumer package | `swift build` and `swift run Consumer` in `Examples/Consumer`. |

**Not verified by any test or replay** (tried only by hand, or not at all):

- the inline text field (focus, Return, Esc, committing on click-away);
- the picker popovers and the date picker;
- the Delete key (it needs the canvas to hold keyboard focus);
- ⌘Z / ⇧⌘Z arriving from the Edit menu (the bridge behind them is tested);
- the hover bubble with validation messages;
- dragging after the canvas or the palette has been scrolled;
- the Run panel's controls, and Open… / Save…;
- light mode in the running app (snapshots only);
- that on-screen text is exactly as wide as the layout measured it (AppKit measures, SwiftUI draws).

## Known limitations

- **Loops are not built.** A host-defined C-block runs its handler and ignores its regions; this is where `for each` and `repeat` will hook in (decision 37).
- **One script per canvas, no loose blocks.** Hence: a drop on nothing cancels (57), and a slot holding a reporter is not a drop target (55).
- **Picking a block up reflows the canvas at once**, so what is under the pointer shifts; the drop indicator is a bar, not a Scratch-style gap (60).
- **Renaming a parameter or variable does not rename its uses** (72). Variables have no declaration of their own: they exist because something binds or sets them.
- **Variable types are flow-insensitive** (35): a name bound to outputs of different types is "unknown" and accepted everywhere.
- **The entry block is edited in a form**, not on the canvas (71); double-click on a `call` block does not open the callee (74).
- **Undo snapshots whole documents** (63). Fine at this size; a very large document would want per-edit inverses.
- **Layout is recomputed on every pointer move** during a drag. Unmeasured; unnoticeable at the acceptance scripts' size.
- **Text is truncated, never wrapped**: a literal longer than 32 characters is cut on the block (it is intact in the document and in the inline editor).
- `LocalTime` has whole-second precision; a timestamp's fraction is dropped when taking its time of day. Timestamps are saved with millisecond precision (7).
- A local time that does not exist (DST gap) is resolved by `Calendar` (moved forward), not rejected.
- Unknown JSON *fields* are not preserved on save; unknown block *kinds* are (14).
- No accessibility support: the canvas is one drawing, invisible to VoiceOver.

## Hardest problems

1. **Nested C-block layout.** Solved by not solving it in SwiftUI: every block is laid out at the origin by a pure function and translated into place by its parent, so nesting is plain recursion, and the outline of a C-block is one path derived from its bars. The design choice that kept it simple is that a C-block does *not* grow with its children (40); otherwise every edit deep inside would resize every ancestor.

2. **Drag and drop over nested containers.** The classic difficulties — dropping a block into itself, indices shifting as the source is removed, deciding between "end of the inner mouth" and "after the outer block" — went away with one move: pick-up *removes* the dragged blocks, and hit-testing and insertion both work on the remaining script (51). The inner/outer ambiguity is settled by scoring distance with a small weight on indentation (53).

3. **The view layer lied while every test passed.** The pure layers (layout, hit-testing, operations, drag logic) had full unit coverage, and M3 was reported as done on that basis. In the real window nothing could be dragged: the canvas and palette positions were handed up as SwiftUI preferences and never arrived, so every pointer position was offset by some 400 points. It surfaced only when the author tried the palette in M4. The fix was small (62); the lesson was the `--ui-test` replay mode (75), which drives the actual window with in-process mouse events. The strict split of spec §9.4 made the bug easy to locate — the log showed correct logic fed wrong coordinates — but it does not make the thin wiring layer correct by itself.

4. **Dynamic block signatures.** `return` and `call script` take their slots from a script, not from their definition. Letting the interpreter, validation and layout each work that out would have made them drift; one `signature(of:in:document:)` in the core (21) is used by all three.

5. **Strict where the spec is strict, forgiving elsewhere.** Runtime never raises a type error, validation warns, and only shape and reference kind block a drop. The awkward corner is a variable of unknown type meeting a reference slot; refusing it would have made `set` variables unusable there, so "unknown" is allowed and "known wrong" is refused, identically in validation and in drops (58).
