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

## Known limitations

- `LocalTime` has whole-second precision; a timestamp's fraction is dropped when taking its time of day.
- A local time that does not exist (DST gap) is resolved by `Calendar` (moved forward), not rejected.

## Hardest problems

_To be filled in from M2 onwards (nested C-block layout, drag and drop over nested containers)._
