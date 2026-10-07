import XCTest
import AlgoratorCore

/// SPEC-templates §3: `{name}` substitution. Table-driven; zone and clock fixed (Prague).
final class TemplateTests: XCTestCase {
    private let variables: [String: Value] = [
        "name": "Ada", "a": "1", "b": "2", "empty": "",
        "first_name": "Grace", "x-y": "dash", "v1.2": "dotted", "ticket 7": "spaced", "jméno": "Božena", "名前": "花子", "2nd": "digit",
        "inner": "{name}", "braces": "{{not escaped here}}",
        "n": 2.5, "whole": 3, "flag": true,
        "day": date("2026-10-04"), "at": time("09:30"), "when": stamp("2026-10-04T10:00:00Z"),
        "who": ref("user", "alice"), "items": .list(["x", 1, true]), "nothing": .list([]),
        "facts": .map(["title": "High", "n": 2]),
    ]

    private func render(_ text: String) -> String { Template(text).render(variables, in: env) }

    func testRendering() {
        let cases: [(String, String)] = [
            // plain text
            ("", ""), ("no placeholders", "no placeholders"), ("line\nbreak\ttab", "line\nbreak\ttab"),
            // one and several
            ("{name}", "Ada"), ("Hello {name}!", "Hello Ada!"), ("{a} + {b} = 3", "1 + 2 = 3"), ("{name} and {name}", "Ada and Ada"),
            // adjacent
            ("{a}{b}", "12"), ("{a}{b}{a}", "121"),
            // whitespace inside the braces is trimmed
            ("{ a }", "1"), ("{  name\t}", "Ada"), ("{\nname\n}", "Ada"),
            // names
            ("{first_name}", "Grace"), ("{x-y}", "dash"), ("{v1.2}", "dotted"), ("{2nd}", "digit"), ("{jméno}", "Božena"), ("{名前}", "花子"),
            ("{ticket 7}", "spaced"),                          // inner whitespace belongs to the name
            // escapes
            ("{{", "{"), ("}}", "}"), ("{{}}", "{}"), ("{{x}}", "{x}"), ("{{name}}", "{name}"), ("{{{name}}}", "{Ada}"),
            ("a {{ b }} c", "a { b } c"), ("{{{{", "{{"), ("}}}}", "}}"), ("{name}}}", "Ada}"), ("{{{a}{b}}}", "{12}"),
            // left as written
            ("{}", "{}"), ("{ }", "{ }"), ("a {} b", "a {} b"),
            ("{", "{"), ("}", "}"), ("{name", "{name"), ("name}", "name}"), ("{a {b}", "{a 2"), ("{a}}", "1}"), ("} {a} {", "} 1 {"),
            ("{a\n", "{a\n"), ("{{a}", "{a}"),
            // unset
            ("{unset}", ""), ("[{unset}]", "[]"), ("{empty}", ""), ("{NAME}", ""),   // names are exact
            // single pass
            ("{inner}", "{name}"), ("{inner}{name}", "{name}Ada"), ("{braces}", "{{not escaped here}}"),
            // every type, by the usual coercion
            ("{n}", "2.5"), ("{whole}", "3"), ("{flag}", "true"),
            ("{day}", "2026-10-04"), ("{at}", "09:30"), ("{when}", "2026-10-04T12:00:00+02:00"),
            ("{who}", "alice"), ("{items}", "x\n1\ntrue"), ("{nothing}", ""),
            ("{facts}", #"{"title":"High","n":2}"#),
            ("{name} ({n}) on {day}", "Ada (2.5) on 2026-10-04"),
        ]
        for (template, expected) in cases {
            XCTAssertEqual(render(template), expected, "“\(template)”")
        }
    }

    func testATimestampFollowsTheEnvironmentZone() {
        XCTAssertEqual(Template("{when}").render(variables, in: utcEnv), "2026-10-04T10:00:00+00:00")
        XCTAssertEqual(Template("{when}").render(variables, in: env), "2026-10-04T12:00:00+02:00")
    }

    func testParts() {
        XCTAssertEqual(Template("").parts, [])
        XCTAssertEqual(Template("plain").parts, [.text("plain")])
        XCTAssertEqual(Template("{a}").parts, [.placeholder("a")])
        XCTAssertEqual(Template("Hi { name }, {{ok}} {} {").parts, [.text("Hi "), .placeholder("name"), .text(", {ok} {} {")])
        XCTAssertEqual(Template("{a}{b}").parts, [.placeholder("a"), .placeholder("b")])
        XCTAssertEqual(Template("x{a}y"), Template("x{ a }y"), "equal once parsed")
    }

    func testPlaceholders() {
        XCTAssertEqual(Template("plain {{text}} {} {").placeholders, [])
        XCTAssertEqual(Template("{b} {a} { b } {c}{a}").placeholders, ["b", "a", "c"], "in order of appearance, once each")
        XCTAssertEqual(Template("{ticket 7}{x-y}").placeholders, ["ticket 7", "x-y"])
    }

    func testRenderingNeverFails() {
        // A soup of braces: every prefix parses and renders to something.
        let soup = "{{{}}}{a}{{b}}{ }{c{d}e}}{{{f}}}{g{"
        for length in 0...soup.count {
            _ = Template(String(soup.prefix(length))).render(variables, in: env)
        }
        XCTAssertEqual(render(soup), "{{}}1{b}{ }{ce}{}{g{", "d and f are unset")
        XCTAssertEqual(Template("{a}").render([:], in: env), "")
    }
}

/// SPEC-templates §3.2–3.4: where templates apply, and how they are validated.
final class InterpolationTests: XCTestCase {
    /// `t.shout %message` interpolates; `t.say %message` does not. Both log what they were given.
    private let logged = Locked<[Value]>([])
    private lazy var vocabulary: Vocabulary = {
        let logged = self.logged
        let category = BlockCategory(id: "t", title: "T", color: BlockColor(hex: 0))
        return Vocabulary([
            .statement("t.shout", category: category, title: "shout %message",
                       inputs: [.value("message", .text, interpolates: true)]) { inputs, _ in
                logged.update { $0.append(inputs["message"]) }
                return [:]
            },
            .statement("t.say", category: category, title: "say %message", inputs: [.value("message", .text)]) { inputs, _ in
                logged.update { $0.append(inputs["message"]) }
                return [:]
            },
            .statement("t.pair", category: category, title: "pair", outputs: [OutputDefinition("left", .text)]) { _, _ in ["left": "L"] },
        ])
    }()

    private func run(_ body: [Block], parameters: [Param] = [], arguments: [String: Value] = [:]) -> RunResult {
        let script = Script(id: "main", name: "Main", parameters: parameters, outputs: [Param(name: "out", type: .text)], body: body)
        return Interpreter(document: Document(scripts: [script]), vocabulary: vocabulary, environment: env).run(scriptID: "main", arguments: arguments)
    }

    private func issues(_ body: [Block], parameters: [Param] = []) -> [String] {
        let script = Script(id: "main", name: "Main", parameters: parameters, outputs: [Param(name: "out", type: .text)], body: body)
        return Validator.validate(Document(scripts: [script]), vocabulary: vocabulary).map { "\($0.severity) \($0.blockID): \($0.message)" }
    }

    private func text(_ template: String, id: String = UUID().uuidString) -> Input { rep(BuiltIn.text, ["template": lit(.text(template))], id: id) }

    // MARK: Slot metadata

    func testInterpolationIsOptInPerSlot() {
        XCTAssertFalse(InputDefinition.value("m", .text).interpolates)
        XCTAssertFalse(InputDefinition(name: "m").interpolates)
        XCTAssertTrue(InputDefinition.value("m", .text, interpolates: true).interpolates)
        XCTAssertTrue(InputDefinition.value("m", interpolates: true).interpolates)
        XCTAssertEqual(InputDefinition.value("m", .text, default: "x", interpolates: true).defaultValue, "x")
        let long = InputDefinition.longText("body", default: "Hi", interpolates: true)
        XCTAssertEqual([long.editor, long.types.first.map { _ in SlotEditor.longText }], [.longText, .longText])
        XCTAssertEqual(long.defaultValue, "Hi")
        XCTAssertTrue(long.interpolates)
        XCTAssertFalse(InputDefinition.longText("script").interpolates, "a long text need not be a template")
        // The built-ins that interpolate, and none other.
        let interpolating = Vocabulary().definitions.filter { $0.inputs.contains(where: \.interpolates) }.map(\.id)
        XCTAssertEqual(interpolating, [BuiltIn.fail, BuiltIn.text])
    }

    func testItIsNotStoredInDocuments() throws {
        let block = stmt("s", "t.shout", ["message": lit("Hello {name}")])
        let json = String(decoding: try Document(scripts: [Script(id: "m", name: "M", body: [block])]).jsonData(), as: UTF8.self)
        XCTAssertFalse(json.contains("interpolates"))
        XCTAssertTrue(json.contains("Hello {name}"), "the literal is saved as written")
        XCTAssertEqual(Document.currentSchemaVersion, 2, "no schema change")
    }

    // MARK: Evaluation

    func testAnInterpolatingSlotRendersALiteral() {
        let result = run([
            set("s", "name", lit("Ada")),
            stmt("shout", "t.shout", ["message": lit("Hello {name}, you are {age}{unset}!")]),
        ], parameters: [Param(name: "age", type: .number)], arguments: ["age": 36])
        XCTAssertEqual(logged.value, ["Hello Ada, you are 36!"])
        XCTAssertEqual(result.trace.last?.label, "shout Hello Ada, you are 36!", "the trace shows the rendered text")
    }

    func testANonInterpolatingSlotLeavesBracesUntouched() {
        _ = run([
            set("s", "name", lit("Ada")),
            stmt("say", "t.say", ["message": lit("Hello {name} {{x}} {")]),
            stmt("json", "t.say", ["message": lit(.text(#"{"json": {"a": [1]}}"#))]),
        ])
        XCTAssertEqual(logged.value, ["Hello {name} {{x}} {", .text(#"{"json": {"a": [1]}}"#)])
    }

    func testAVariableOrReporterInAnInterpolatingSlotIsNotInterpolated() {
        _ = run([
            set("s1", "name", lit("Ada")),
            set("s2", "raw", lit("literally {name}")),
            stmt("variable", "t.shout", ["message": variable("raw")]),
            stmt("reporter", "t.shout", ["message": rep("operator.join", ["a": lit("joined {name}"), "b": lit(" {{x}}")])]),
            stmt("literal", "t.shout", ["message": lit("literal {name} {{x}}")]),
        ])
        XCTAssertEqual(logged.value, ["literally {name}", "joined {name} {{x}}", "literal Ada {x}"])
    }

    func testOnlyTextLiteralsAreTemplates() {
        _ = run([stmt("number", "t.shout", ["message": lit(42)]), stmt("map", "t.shout", ["message": lit(.map(["k": "{name}"]))])])
        XCTAssertEqual(logged.value, [42, .map(["k": "{name}"])])
    }

    func testTextReporter() {
        let result = run([
            set("s1", "title", lit("Login page is down")),
            set("s2", "priority", lit("high")),
            ret("r", ["out": text("Escalated: {title} ({priority})")]),
        ])
        XCTAssertEqual(result.outputs["out"], "Escalated: Login page is down (high)")
        XCTAssertEqual(run([ret("r", ["out": text("")])]).outputs["out"], "")
        XCTAssertEqual(run([ret("r", ["out": text("line one\n{unset}line two")])]).outputs["out"], "line one\nline two")
        XCTAssertEqual(run([ret("r", ["out": rep(BuiltIn.text)])]).outputs["out"], "", "an empty slot is its default")
        XCTAssertEqual(Vocabulary()[BuiltIn.text]?.category.id, "operators")
        XCTAssertEqual(Vocabulary()[BuiltIn.text]?.result, .text)
        XCTAssertEqual(Vocabulary()[BuiltIn.text]?.inputs.first?.editor, .longText)
    }

    func testVariablesInScopeAreParametersBindingsAndSetTargets() {
        let result = run([
            stmt("p", "t.pair", bindings: ["left": "bound"]),
            set("s", "assigned", lit("S")),
            stmt("e", BuiltIn.setEntry, ["key": lit("k"), "name": lit("facts"), "value": lit(1)]),
            ret("r", ["out": text("{given}/{bound}/{assigned}/{facts}")]),
        ], parameters: [Param(name: "given", type: .text)], arguments: ["given": "P"])
        XCTAssertEqual(result.outputs["out"], #"P/L/S/{"k":1}"#)
    }

    func testATemplateReadsTheVariablesAsTheyAreWhenTheBlockRuns() {
        _ = run([
            stmt("before", "t.shout", ["message": lit("[{v}]")]),
            set("s1", "v", lit("one")),
            stmt("between", "t.shout", ["message": lit("[{v}]")]),
            set("s2", "v", lit("two")),
            stmt("after", "t.shout", ["message": lit("[{v}]")]),
        ])
        XCTAssertEqual(logged.value, ["[]", "[one]", "[two]"])
    }

    /// The nested case: a template containing text produced by another `text` block is not expanded again.
    func testNestedTemplatesAreASinglePassEach() {
        let result = run([
            set("s0", "name", lit("Ada")),
            set("s1", "greeting", text("Hello {name} {{name}}")),          // → "Hello Ada {name}"
            set("s2", "wrapped", text("<{greeting}>")),                    // → "<Hello Ada {name}>", braces kept
            stmt("shout", "t.shout", ["message": lit("{wrapped} and {name}")]),
            ret("r", ["out": variable("wrapped")]),
        ])
        XCTAssertEqual(result.outputs["out"], "<Hello Ada {name}>")
        XCTAssertEqual(logged.value, ["<Hello Ada {name}> and Ada"])
    }

    func testCalleeTemplatesSeeOnlyTheCalleesVariables() {
        let callee = Script(id: "callee", name: "Callee", parameters: [Param(name: "who", type: .text)],
                            outputs: [Param(name: "line", type: .text)], body: [ret("cr", ["line": text("{who}/{secret}")])])
        let main = Script(id: "main", name: "Main", outputs: [Param(name: "out", type: .text)], body: [
            set("s", "secret", lit("caller's")),
            call("c", "callee", ["who": lit("guest")], bindings: ["line": "line"]),
            ret("r", ["out": variable("line")]),
        ])
        let result = Interpreter(document: Document(scripts: [main, callee]), vocabulary: vocabulary, environment: env).run(scriptID: "main")
        XCTAssertEqual(result.outputs["out"], "guest/")
    }

    // MARK: fail with a template

    func testFailWithATemplatedMessage() {
        let result = run([set("s", "what", lit("title")), stmt("f", BuiltIn.fail, ["message": lit("Missing {what} for {{id}} {unset}")])])
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "Missing title for {id} ")
        XCTAssertEqual(result.trace.last?.label, "fail with Missing title for {id} ")
        // A template that renders to nothing falls back like an empty message.
        XCTAssertEqual(run([stmt("f", BuiltIn.fail, ["message": lit("{unset}")])]).message, "The script failed")
        // A variable in the slot is taken as it is.
        XCTAssertEqual(run([set("s", "m", lit("{raw}")), stmt("f", BuiltIn.fail, ["message": variable("m")])]).message, "{raw}")
    }

    // MARK: Validation

    func testPlaceholdersAreValidatedLikeVariableReads() {
        XCTAssertEqual(issues([
            stmt("early", "t.shout", ["message": lit("{later} and {given}")]),
            set("s", "later", lit(1)),
            stmt("ok", "t.shout", ["message": lit("{later} {given} {bound}")]),
            stmt("p", "t.pair", bindings: ["left": "bound"]),
            stmt("typo", "t.shout", ["message": lit("{latr}")]),
            stmt("twice", "t.shout", ["message": lit("{nope} {nope} {also}")]),
            ret("r", ["out": text("{later}{missing}", id: "t")]),
        ], parameters: [Param(name: "given", type: .text)]), [
            "error early: The variable “later” is read before it can be set",
            "error ok: The variable “bound” is read before it can be set",
            "error typo: The variable “latr” is never set",
            "error twice: The variable “nope” is never set",
            "error twice: The variable “also” is never set",
            "error t: The variable “missing” is never set",
        ])
    }

    func testTheFindingIsTheSameAsForAVariableChip() {
        let chip = issues([stmt("b", "t.shout", ["message": variable("nope")])])
        let placeholder = issues([stmt("b", "t.shout", ["message": lit("{nope}")])])
        XCTAssertEqual(chip, placeholder)
        XCTAssertEqual(chip, ["error b: The variable “nope” is never set"])
    }

    func testNothingIsReportedForPlainTextOrWhereTheSlotDoesNotInterpolate() {
        XCTAssertEqual(issues([
            stmt("plain", "t.shout", ["message": lit("no placeholders, {{escaped}}, {} and {")]),
            stmt("untouched", "t.say", ["message": lit("{nope} is just text here")]),
            stmt("number", "t.shout", ["message": lit(5)]),
            stmt("empty", "t.shout", ["message": lit("")]),
            stmt("f", BuiltIn.fail, ["message": lit("plain")]),
        ]), [])
    }

    func testPlaceholdersReferringToParametersBindingsAndSetTargetsAreFine() {
        XCTAssertEqual(issues([
            stmt("p", "t.pair", bindings: ["left": "bound"]),
            set("s", "assigned", lit(1)),
            stmt("e", BuiltIn.setEntry, ["key": lit("k"), "name": lit("facts"), "value": lit(1)]),
            ifElse("i", yes, then: [set("s2", "branch", lit(1))], else: []),
            stmt("ok", "t.shout", ["message": lit("{given} {bound} {assigned} {facts} { branch }")]),
            stmt("f", BuiltIn.fail, ["message": lit("{given} {bound}")]),
        ], parameters: [Param(name: "given", type: .text)]), [])
    }

    func testFailMessageTemplateIsValidated() {
        XCTAssertEqual(issues([stmt("f", BuiltIn.fail, ["message": lit("Ticket {tickt} has no title")])]),
                       ["error f: The variable “tickt” is never set"])
    }
}
