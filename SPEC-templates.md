# Algorator — `fail`, text interpolation and formatting (change specification)

Status: change request on top of the current library (`SPEC.md`, `SPEC-maps.md`, `DESIGN.md`; milestones M0–M8 done).
Read those first; this document only adds what is new. Where it is silent, they still apply — including: no
third-party dependencies, tools 5.9 / Swift 5 language mode, `AlgoratorCore` imports Foundation only, strict
core/editor split, headless tests, **complete strict-concurrency checking stays clean** (`Examples/Consumer6` must
keep building without warnings), and everything new is `Sendable`/`@MainActor` as the existing code is.

## 1. Why

The first real host (Mindler) is about to move its existing "Actions" onto Algorator. Two things it relies on have no
equivalent yet:

1. **A script that ends with an error and a message** (Mindler's "Require Value"). Today only a host handler can throw.
2. **Text templates.** Mindler's text literals contain `{variable}` placeholders (e.g. `"{code} {name}\n\n{description}"`)
   that are filled from the script's variables. Without interpolation a converted script would need a pyramid of
   nested `join` blocks.

This is deliberately **not** a template framework. Conditionals and loops already exist as blocks (`if`, later
`for each`); a second control-flow language inside strings would duplicate them. A template only **substitutes
values into text**; anything smarter is written as blocks. Formatting of dates and numbers is done by separate
reporters, not by filters inside the template.

## 2. `fail` — end the script with an error

A new built-in block, category **Control**:

| | |
|---|---|
| id | `control.fail` |
| shape | **cap** (nothing may follow it, like `return`; the existing cap rules for insertion and dragging apply) |
| title | `fail with %message` |
| slot | `message` — a text slot, default `""`, **interpolating** (see section 3) |

Semantics:
- Evaluating it ends the **whole run** as `failed`: `RunResult.status == .failed`, `RunResult.message` is the evaluated
  message, and the trace's last step is that block with `succeeded == false` and the message. This is exactly what a
  handler throwing `BlockError(message)` does today; implement it the simplest way consistent with that.
- An empty message becomes a generic one (`"The script failed"`).
- It propagates through `call script`: a callee that fails fails its caller; the trace shows both.
- It is **not catchable** inside a script. There is no try/catch and none is requested.
- Validation: nothing special beyond the cap rules; `fail` in the middle of a region is already prevented by them.
- It is a statement-like cap in the palette, layout and rendering — reuse `return`'s geometry (a flat bottom, no
  tab). Add it to the palette snapshot test.

## 3. Interpolation

### 3.1 Syntax
In a template text:
- `{name}` is replaced by `toText` of the script variable `name` at the moment the block is evaluated (lists,
  maps, dates and so on convert by the existing coercion rules, section 5.2 of `SPEC.md` and `SPEC-maps.md`).
- `{{` is a literal `{` and `}}` is a literal `}`.
- `name` is everything between the braces **except `{` and `}`**, with surrounding whitespace trimmed (variable
  names in existing data include underscores, digits, dashes and dots). An empty `{}` is left as written.
- A `{` with no matching `}` (or a stray `}`) is left **as written**. Interpolation is **total**: it never fails.
- A variable that is not set evaluates to the empty string (as an unset variable does everywhere).
- Interpolation is **single pass**: text produced by a substituted value is not scanned again.

Implement the parser/renderer as a small pure `Template` type in `AlgoratorCore` (parse to parts once, render
against a `[String: Value]` of the frame's variables) so it can be tested in isolation.

### 3.2 Where it applies (opt-in)
- **A new `InputDefinition.interpolates: Bool`**, default `false`. It is slot *metadata* (like `editor`), **not** stored
  in documents — no schema change. When `true` and the slot holds a **literal text**, the literal is rendered as a
  template when the block is evaluated. A slot holding a variable chip or a reporter is **not** interpolated (its
  value is already computed); the placeholders only live in literals.
- **Why opt-in:** many text literals legitimately contain braces (an AppleScript, a JSON snippet, a regex). They must
  stay untouched unless the slot says otherwise.
- **A new built-in reporter** in **Operators**: id `operators.text`, title `text %template`, result `text`, one slot
  `template` that interpolates and uses the multi-line editor (section 5). It is the general way to write a
  template inline, and the target of Mindler's converted literals.
- `fail with %message` interpolates (above). Hosts can set `interpolates: true` on their own slots (Mindler will for
  note content, descriptions, titles).
- `InputDefinition`'s convenience constructors get an `interpolates:` parameter where it makes sense (`.value(...)`).

### 3.3 Variables in scope
The variables of the current script frame: parameters, block output bindings, and `set` targets — the same set the
validator already knows for variable reads. Template evaluation **reads** them; it never writes.

### 3.4 Validation
- For every interpolating literal, parse its placeholders and, for each name, report the **same finding the
  validator already reports for a variable read that cannot yet be bound** (same wording style, same severity,
  attached to the block that holds the template).
- A template that parses to no placeholders is fine and silent.

## 4. Formatting reporters

Both are pure, total (invalid input → empty text) and deterministic.

| Block | Where | Meaning |
|---|---|---|
| `format %value as %pattern` | Time | Formats a date, time or timestamp with a Unicode (TR35 / `DateFormatter`) pattern, e.g. `yyyy-MM-dd`, `HH:mm`, `d. M. yyyy`. A timestamp is shown in the environment's time zone. A value that is not temporal is coerced with the existing rules (`toTimestamp`, else `toDate`, else `toTime`); if none works the result is empty. |
| `format number %number with %decimals decimals` | Operators | Fixed-point text: `.` as decimal separator, **no grouping separator**, `decimals` clamped to 0…10 (default 2). |

Use a fixed `en_US_POSIX` locale so output does not depend on the machine; say so in the doc comment and
`DESIGN.md`. (Locale-aware formatting is not requested.)

## 5. Editor: multi-line text slots

Templates are often long and contain newlines (Mindler's note content, for instance). The text-literal editor is
inline and single-line, and long text is truncated on the block. Add:

- `SlotEditor.longText`: a text literal edited in a **popover with a multi-line text editor** (Return inserts a
  newline; clicking away or a "Done" button commits; Esc cancels — consistent with the existing inline editor's
  commit/cancel rules, decision 67).
- On the block the literal is shown **truncated to its first line, with an ellipsis** if there is more (and the
  existing length cut). Its full content stays intact in the document and in the popover.
- The `text %template` reporter and `fail with %message` use `.longText`. Hosts can use it for their own slots (a
  script body, a description).
- Everything else about slots (shape, drop rules, undo granularity: one step per committed edit) is unchanged.

## 6. Demo (toy domain)

- Change the first acceptance script (`Escalate ticket`) to build its notification message with
  `text "Escalated: {title} ({priority})"` instead of `join`, and add a guard at its start:
  `if (title is empty) then fail with "Ticket {ticket} has no title"` after the `fetch`.
  Add a fake ticket without a title to the demo data so the guard can be seen failing in the trace.
- Update `acceptance.json`, the demo's initial document and the snapshots accordingly; keep the second and third
  scripts working.

## 7. Tests (extend the existing suites; same standards)

- **`Template` (core, table-driven):** plain text; one and several placeholders; adjacent `{a}{b}`; whitespace
  `{ a }`; names with `_`, `-`, `.`, digits, non-ASCII letters; `{{`/`}}` escapes including `{{x}}` → `{x}`; unmatched
  `{`, stray `}`, empty `{}`; unset variable → empty; single pass (a value containing `{x}` is not re-expanded);
  values of every type (text, number, bool, date, time, timestamp with a fixed zone, reference, list, map).
- **Interpreter:** an interpolating slot renders a literal; a non-interpolating slot leaves braces untouched; a
  variable/reporter in an interpolating slot is not re-interpolated; `text` reporter result; the nested case (a
  template containing text produced by another `text` block).
- **`fail`:** run status, `message`, trace; a failure inside a called script fails the caller; steps after it never
  run (it is a cap); an empty message falls back; `fail` with a templated message.
- **Validation:** unknown placeholder name reported with the same finding/severity as a variable read; none for
  plain text; placeholders referring to a parameter, a binding and a `set` target are fine.
- **Formatting reporters:** table-driven, fixed zone and `now`; invalid inputs; decimals clamping; `d. M. yyyy`.
- **Editor:** the palette lists the new blocks and the cap geometry of `fail` matches `return`; a layout test for a
  block with a multi-line template literal (shown truncated to its first line); snapshots (palette with `fail` and
  `text`, the updated first acceptance script); the "build it from nothing" operations test extended for the
  changed script; `longText` commit/cancel behaviour through the editing session API (not the view).
- **Concurrency:** `Examples/Consumer6` still builds with zero warnings; add a template-using script to the existing
  many-tasks run.
- GUI behaviour that cannot be tested headlessly — the multi-line popover (focus, Return vs Done, Esc) — is **named
  explicitly as unverified** in the report, not claimed to work.

## 8. Documentation
- `README`: a "Templates and formatting" paragraph (the syntax in 3.1, that it is opt-in per slot and why, the
  `text` reporter, the formatting reporters, how a host marks a slot `interpolates: true`) and `fail` in the block list.
- `DESIGN.md`: continue the decisions log for every ambiguity settled here; add the limitations (templates substitute
  only; no filters or escaping modes; fixed POSIX locale; only literals interpolate) and update "what is verified".

## 9. Milestones (stop and report after each)

| # | Deliverable | Exit criterion |
|---|---|---|
| M9 | `fail` block; `format … as …` and `format number …`; palette, validation, tests, snapshots | the `fail` and formatting tests of section 7 pass; the demo guard fails correctly in the trace |
| M10 | `Template`, `InputDefinition.interpolates`, `text %template`, interpolating `fail`, validation of placeholders, `SlotEditor.longText` popover, demo/doc updates | all of section 7 passes; `Examples/Consumer6` still clean; the demo launches and the changed script runs |

Report at each milestone as before: what was built, what the tests cover, what is **not** verified, and the command
to launch the demo.

## 10. Out of scope
- Conditional sections, loops, partials, filters or helpers inside templates; HTML/URL/shell escaping modes.
- Locale-aware formatting; user-supplied locale.
- `try`/`catch`, error values, `finally`.
- Cross-document `call script` (Mindler will keep all its scripts in one `Document`).
- The typed-operation layer on top of `BlockDefinition`.
