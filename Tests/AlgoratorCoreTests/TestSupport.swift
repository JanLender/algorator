import Foundation
import AlgoratorCore

/// Prague is UTC+2 in summer and UTC+1 in winter, so zone handling cannot pass by accident.
let prague = TimeZone(identifier: "Europe/Prague")!
let utc = TimeZone(secondsFromGMT: 0)!

/// 2026-10-04 12:00:00 in Prague (10:00:00Z).
let fixedNow = Date(timeIntervalSince1970: 1_791_108_000)

let env = RunEnvironment(timeZone: prague, now: { fixedNow })
let utcEnv = RunEnvironment(timeZone: utc, now: { fixedNow })

func date(_ iso: String) -> Value { .date(LocalDate(iso: iso)!) }
func time(_ iso: String) -> Value { .time(LocalTime(iso: iso)!) }
func stamp(_ iso: String) -> Value { .timestamp(Coercion.toTimestamp(.text(iso), in: utcEnv)!) }
func ref(_ kind: String, _ id: String) -> Value { .reference(Reference(kind: kind, id: id)) }
