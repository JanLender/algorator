import XCTest
import AlgoratorCore

final class DocumentTests: XCTestCase {

    /// Uses every model feature: all value types, all input forms, bindings, nested regions and reporters.
    private var sample: Document {
        let condition = Block(id: "b3", kind: "operator.or", inputs: [
            "a": .reporter(Block(id: "b4", kind: "operator.equals",
                                 inputs: ["a": .variable("priority"), "b": .literal("high")])),
            "b": .empty,
        ])
        let branch = Block(id: "b2", kind: "control.ifElse", inputs: ["condition": .reporter(condition)], regions: [
            "then": [Block(id: "b5", kind: "control.return", inputs: ["escalated": .literal(true)])],
            "else": [],
        ])
        let fetch = Block(id: "b1", kind: "ticket.fetch", inputs: ["ticket": .variable("ticket")],
                          bindings: ["title": "title", "priority": "priority"])
        let literals = Block(id: "b6", kind: "test.literals", inputs: [
            "text": .literal("a \"quoted\" / slashed text"),
            "number": .literal(2.5),
            "bool": .literal(false),
            "date": .literal(date("2026-10-04")),
            "time": .literal(time("09:30:15")),
            "timestamp": .literal(stamp("2026-10-04T10:00:00.250Z")),
            "reference": .literal(ref("user", "u1")),
            "list": .literal(.list(["a", 1, .list([true])])),
        ])
        return Document(scripts: [
            Script(id: "s1", name: "Escalate ticket", trigger: "onTicketOpened",
                   parameters: [Param(name: "ticket", type: .reference, referenceKind: "ticket")],
                   outputs: [Param(name: "escalated", type: .bool)],
                   body: [fetch, branch, literals]),
            Script(id: "s2", name: "Empty"),
        ])
    }

    func testRoundTripIsLossless() throws {
        let json = try sample.jsonData()
        let decoded = try Document(json: json)
        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(try decoded.jsonData(), json, "re-encoding must be byte-identical")
    }

    func testJSONIsStable() throws {
        XCTAssertEqual(try sample.jsonData(), try sample.jsonData())
    }

    func testReadsHandWrittenJSONWithOmittedFields() throws {
        let json = """
        {
          "schemaVersion": 1,
          "scripts": [
            { "id": "s1", "name": "Hello",
              "parameters": [ { "name": "who", "type": "reference", "referenceKind": "user" } ],
              "body": [
                { "id": "b1", "kind": "demo.notify",
                  "inputs": {
                    "user": { "variable": "who" },
                    "message": { "literal": { "text": "hi" } },
                    "at": { "literal": { "timestamp": "2026-10-04T12:00:00+02:00" } },
                    "extra": { "empty": true }
                  } },
                { "id": "b2", "kind": "control.if",
                  "inputs": { "condition": { "reporter": { "id": "b3", "kind": "operator.not" } } },
                  "regions": { "then": [] } }
              ] }
          ]
        }
        """
        let document = try Document(json: Data(json.utf8))
        let script = try XCTUnwrap(document.scripts.first)
        XCTAssertNil(script.trigger)
        XCTAssertEqual(script.outputs, [])
        XCTAssertEqual(script.parameters, [Param(name: "who", type: .reference, referenceKind: "user")])
        XCTAssertEqual(script.body[0], Block(id: "b1", kind: "demo.notify", inputs: [
            "user": .variable("who"),
            "message": .literal("hi"),
            "at": .literal(.timestamp(fixedNow)),
            "extra": .empty,
        ]))
        XCTAssertEqual(script.body[1].inputs["condition"], .reporter(Block(id: "b3", kind: "operator.not")))
        XCTAssertEqual(script.body[1].regions, ["then": []])
    }

    func testValueJSONForms() throws {
        let block = Block(id: "b", kind: "k", inputs: [
            "d": .literal(date("2026-10-04")),
            "t": .literal(time("09:30")),
            "s": .literal(stamp("2026-10-04T12:00:00+02:00")),
            "n": .literal(3),
        ])
        let json = String(decoding: try Document(scripts: [Script(id: "s", name: "S", body: [block])]).jsonData(),
                          as: UTF8.self)
        XCTAssertTrue(json.contains(#""date" : "2026-10-04""#), json)
        XCTAssertTrue(json.contains(#""time" : "09:30""#), json)
        XCTAssertTrue(json.contains(#""timestamp" : "2026-10-04T10:00:00Z""#), json)   // always UTC on disk
        XCTAssertTrue(json.contains(#""number" : 3"#), json)
    }

    func testUnknownBlockKindSurvivesLoadAndSave() throws {
        let unknown = Block(id: "x1", kind: "vendor.removedInV2",
                            inputs: ["what": .literal("kept"), "nested": .reporter(Block(id: "x2", kind: "vendor.alsoGone"))],
                            bindings: ["out": "result"],
                            regions: ["body": [Block(id: "x3", kind: "vendor.child")]])
        let document = Document(scripts: [Script(id: "s", name: "S", body: [unknown])])
        let reloaded = try Document(json: try document.jsonData())
        XCTAssertEqual(reloaded.scripts[0].body, [unknown])
        XCTAssertEqual(try reloaded.jsonData(), try document.jsonData())
    }

    func testRejectsNewerSchemaVersion() {
        let json = Data(#"{ "schemaVersion": 3, "scripts": [] }"#.utf8)
        XCTAssertThrowsError(try Document(json: json)) { error in
            XCTAssertEqual(error as? DocumentError, .unsupportedSchemaVersion(3))
        }
    }

    func testRejectsMalformedValuesAndInputs() {
        func document(input: String) -> Data {
            Data(#"{"schemaVersion":1,"scripts":[{"id":"s","name":"S","body":[{"id":"b","kind":"k","inputs":{"a":\#(input)}}]}]}"#.utf8)
        }
        for input in [#"{"literal":{"date":"2026-02-30"}}"#, #"{"literal":{"time":"25:00"}}"#,
                      #"{"literal":{"timestamp":"yesterday"}}"#, #"{"literal":{}}"#,
                      #"{"literal":{"text":"a","number":1}}"#, #"{"literal":{"colour":"red"}}"#, #"{}"#] {
            XCTAssertThrowsError(try Document(json: document(input: input)), input)
        }
        XCTAssertNoThrow(try Document(json: document(input: #"{"literal":{"text":"ok"}}"#)))
    }

    func testNonFiniteNumberDoesNotBreakSaving() throws {
        let block = Block(id: "b", kind: "k", inputs: ["n": .literal(.number(.infinity))])
        let document = Document(scripts: [Script(id: "s", name: "S", body: [block])])
        let reloaded = try Document(json: try document.jsonData())
        XCTAssertEqual(reloaded.scripts[0].body[0].inputs["n"], .literal(0))
    }

    func testNewBlocksAndScriptsGetDistinctIds() {
        XCTAssertNotEqual(Block(kind: "k").id, Block(kind: "k").id)
        XCTAssertNotEqual(Script(name: "S").id, Script(name: "S").id)
    }
}

import TicketDemo

/// Spec §10: the acceptance document round-trips, and an unknown block kind survives a load and a save.
final class AcceptanceRoundTripTests: XCTestCase {
    func testAcceptanceDocumentRoundTripsThroughAFile() throws {
        let document = try AcceptanceDocument.load()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("algorator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try document.jsonData().write(to: url)
        let reloaded = try Document(json: Data(contentsOf: url))
        XCTAssertEqual(reloaded, document)
        XCTAssertEqual(try reloaded.jsonData(), try document.jsonData())
    }

    func testUnknownKindSurvivesInsideTheAcceptanceDocument() throws {
        // As if the host had dropped `ticket.addLabel` from its vocabulary: the block stays in the file,
        // validation flags it, and the rest of the script is untouched.
        var document = try AcceptanceDocument.load()
        document.scripts[0].body[2].regions["then"]?[1].kind = "ticket.removedInV2"
        let reloaded = try Document(json: try document.jsonData())
        XCTAssertEqual(reloaded, document)
        let kept = try XCTUnwrap(reloaded.scripts[0].body[2].regions["then"]?[1])
        XCTAssertEqual(kept.kind, "ticket.removedInV2")
        XCTAssertEqual(kept.inputs, ["label": .literal("escalated"), "ticket": .variable("ticket")])

        let directory = TicketDirectory.sample(now: fixedNow)
        let vocabulary = TicketVocabulary.make(directory: directory)
        XCTAssertEqual(Validator.validate(reloaded, vocabulary: vocabulary),
                       [Issue(scriptID: "escalate-ticket", blockID: "label", severity: .error,
                              message: "Unknown block kind “ticket.removedInV2”")])
        let result = Interpreter(document: reloaded, vocabulary: vocabulary, environment: env)
            .run(scriptID: "escalate-ticket", arguments: ["ticket": ref("ticket", "T-1")])
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.trace.map(\.blockID), ["fetch", "guard", "decide", "notify-assignee", "label"])
    }

    func testDirectoryResetRestoresTheSampleData() {
        let directory = TicketDirectory.sample(now: fixedNow)
        directory.notify(user: "alice", message: "x")
        directory.tickets["T-1"]?.labels.append("escalated")
        directory.tickets["T-9"] = directory.tickets["T-1"]
        directory.reset(now: fixedNow)
        XCTAssertEqual(directory.notifications, [])
        XCTAssertEqual(directory.tickets.keys.sorted(), ["T-1", "T-2", "T-3", "T-4"])
        XCTAssertEqual(directory.tickets["T-1"]?.labels, [])
    }
}
