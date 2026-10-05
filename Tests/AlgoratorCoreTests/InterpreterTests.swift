import XCTest
import AlgoratorCore
import TicketDemo

final class InterpreterTests: XCTestCase {
    private let host = TestHost()

    private func script(_ body: [Block], parameters: [Param] = [], outputs: [Param] = [], id: String = "main") -> Script {
        Script(id: id, name: id.capitalized, parameters: parameters, outputs: outputs, body: body)
    }

    // MARK: Sequence, variables, branching

    func testStatementsRunInOrderAndAreTraced() {
        let result = host.run(script([log("a", lit("one")), log("b", lit(2))]))
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(host.logged, ["one", 2])
        XCTAssertEqual(result.trace, [
            StepOutcome(blockID: "a", scriptID: "main", depth: 0, label: "log one", succeeded: true),
            StepOutcome(blockID: "b", scriptID: "main", depth: 0, label: "log 2", succeeded: true),
        ])
        XCTAssertNil(result.message)
    }

    func testEmptyScriptCompletes() {
        let result = host.run(script([], outputs: [Param(name: "x", type: .number)]))
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.outputs, ["x": .empty])
        XCTAssertEqual(result.trace, [])
    }

    func testVariablesParametersAndUnsetReads() {
        let result = host.run(script([
            log("a", variable("given")),
            log("b", variable("missing")),
            log("c", variable("never")),
            set("d", "x", rep("operator.add", ["a": variable("given"), "b": lit(1)])),
            log("e", variable("x")),
        ], parameters: [Param(name: "given", type: .number), Param(name: "missing", type: .text)]),
                              arguments: ["given": 41, "unknown": "ignored"])
        XCTAssertEqual(host.logged, [41, .empty, .empty, 42])
        XCTAssertEqual(result.trace.map(\.label), ["log 41", "log \"\"", "log \"\"", "set x to 42", "log 42"])
    }

    func testIfRunsOnlyTheMatchingRegion() {
        _ = host.run(script([
            ifThen("i1", yes, then: [log("a", lit("then-1"))]),
            ifThen("i2", no, then: [log("b", lit("then-2"))]),
            ifElse("i3", yes, then: [log("c", lit("then-3"))], else: [log("d", lit("else-3"))]),
            ifElse("i4", no, then: [log("e", lit("then-4"))], else: [log("f", lit("else-4"))]),
        ]))
        XCTAssertEqual(host.logged, ["then-1", "then-3", "else-4"])
    }

    func testTraceListsOnlyExecutedBlocksInExecutionOrder() {
        let result = host.run(script([
            ifElse("i", no, then: [log("skipped", lit("x"))], else: [log("taken", lit("y"))]),
            log("after", lit("z")),
        ]))
        XCTAssertEqual(result.trace.map(\.blockID), ["i", "taken", "after"])
        XCTAssertEqual(result.trace[0].label, "if false then")
    }

    func testVariableBoundInBranchIsVisibleAfterwardsAndEmptyOtherwise() {
        func body(_ condition: Input) -> [Block] {
            [ifThen("i", condition, then: [set("s", "inner", lit("bound"))]), log("l", variable("inner"))]
        }
        _ = host.run(script(body(yes)))
        _ = host.run(script(body(no)))
        XCTAssertEqual(host.logged, ["bound", .empty])
    }

    func testEmptySlotsUseDefaults() {
        _ = host.run(script([stmt("d", "test.defaults")]))
        XCTAssertEqual(host.logged, [7, false])
    }

    func testOutputBindings() {
        let result = host.run(script([
            stmt("p", "test.pair", bindings: ["first": "one", "second": "two", "nonexistent": "ghost", "first ": ""]),
            log("a", variable("one")), log("b", variable("two")), log("c", variable("ghost")),
        ]))
        XCTAssertEqual(host.logged, [1, "two", .empty])
        XCTAssertEqual(result.trace[0].note, "made a pair\nat depth 0")
        XCTAssertNil(result.trace[1].note)
    }

    // MARK: Return

    func testReturnSetsDeclaredOutputs() {
        let result = host.run(script([ret("r", ["total": lit(3), "label": lit("ok"), "undeclared": lit("x")]),
                                      log("never", lit("x"))],
                                     outputs: [Param(name: "total", type: .number), Param(name: "label", type: .text),
                                               Param(name: "unset", type: .text)]))
        XCTAssertEqual(result.status, .returned)
        XCTAssertEqual(result.outputs, ["total": 3, "label": "ok", "unset": .empty])
        XCTAssertEqual(result.trace.map(\.blockID), ["r"])
        XCTAssertEqual(host.logged, [])
    }

    func testReturnInsideNestedRegionEndsTheScript() {
        let result = host.run(script([
            log("before", lit("before")),
            ifThen("outer", yes, then: [
                ifElse("inner", no, then: [], else: [
                    log("deep", lit("deep")),
                    ret("r", ["done": lit(true)]),
                    log("after-return", lit("unreachable")),
                ]),
                log("after-inner", lit("unreachable")),
            ]),
            log("after-outer", lit("unreachable")),
        ], outputs: [Param(name: "done", type: .bool)]))
        XCTAssertEqual(result.status, .returned)
        XCTAssertEqual(result.outputs, ["done": true])
        XCTAssertEqual(result.trace.map(\.blockID), ["before", "outer", "inner", "deep", "r"])
        XCTAssertEqual(host.logged, ["before", "deep"])
    }

    func testHostCapEndsTheScript() {
        let result = host.run(script([stmt("s", "test.stop"), log("never", lit("x"))]))
        XCTAssertEqual(result.status, .returned)
        XCTAssertEqual(host.logged, [])
    }

    // MARK: Calling

    func testCalledScriptReturnResumesTheCaller() {
        let callee = script([
            log("c1", variable("n")),
            ret("c2", ["doubled": rep("operator.multiply", ["a": variable("n"), "b": lit(2)])]),
            log("c3", lit("unreachable")),
        ], parameters: [Param(name: "n", type: .number)], outputs: [Param(name: "doubled", type: .number)], id: "double")
        let caller = script([
            set("m0", "n", lit(100)),
            call("m1", "double", ["n": lit(21)], bindings: ["doubled": "answer"]),
            log("m2", variable("answer")),
            log("m3", variable("n")),
        ])
        let result = host.run(caller, others: [callee])
        XCTAssertEqual(result.status, .completed, "the callee's return must not end the caller")
        XCTAssertEqual(host.logged, [21, 42, 100], "the callee has its own variables")
        XCTAssertEqual(result.trace.map(\.blockID), ["m0", "m1", "c1", "c2", "m2", "m3"])
        XCTAssertEqual(result.trace.map(\.depth), [0, 0, 1, 1, 0, 0])
        XCTAssertEqual(result.trace.map(\.scriptID), ["main", "main", "double", "double", "main", "main"])
        XCTAssertEqual(result.trace[1].label, "call Double n 21")
    }

    func testCalleeFallingOffTheEndGivesEmptyOutputs() {
        let callee = script([], outputs: [Param(name: "out", type: .text)], id: "noop")
        _ = host.run(script([set("s", "v", lit("old")), call("c", "noop", bindings: ["out": "v"]), log("l", variable("v"))]),
                     others: [callee])
        XCTAssertEqual(host.logged, [.empty])
    }

    func testCallingAMissingScriptFails() {
        let result = host.run(script([call("c", "nowhere"), log("never", lit("x"))]))
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.trace.map(\.blockID), ["c"])
        XCTAssertEqual(result.message, "The called script does not exist")
    }

    func testRecursionIsLimited() {
        let recursive = script([call("again", "main")])
        let result = host.run(recursive)
        XCTAssertEqual(result.status, .failed)
        // Depths 0…29 call successfully; the call at depth 30 is refused.
        XCTAssertEqual(result.trace.count, 31)
        XCTAssertEqual(result.trace.filter(\.succeeded).count, 30)
        XCTAssertEqual(result.trace.last?.depth, 30)
        XCTAssertEqual(result.message, "Scripts are nested more than 30 calls deep — is “Main” calling itself?")
    }

    func testRecursionLimitIsConfigurableAndMutualRecursionIsCaught() {
        let ping = script([call("to-pong", "pong")], id: "ping")
        let pong = script([call("to-ping", "ping")], id: "pong")
        let shallow = RunEnvironment(timeZone: prague, now: { fixedNow }, maxCallDepth: 3)
        let result = host.run(ping, others: [pong], environment: shallow)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.trace.map(\.blockID), ["to-pong", "to-ping", "to-pong", "to-ping"])
    }

    func testBoundedRecursionWorks() {
        // countdown(n): log n; if n > 1 then countdown(n - 1)
        let countdown = script([
            log("l", variable("n")),
            ifThen("i", rep("operator.greater", ["a": variable("n"), "b": lit(1)]), then: [
                call("c", "main", ["n": rep("operator.subtract", ["a": variable("n"), "b": lit(1)])]),
            ]),
        ], parameters: [Param(name: "n", type: .number)])
        let result = host.run(countdown, arguments: ["n": 3])
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(host.logged, [3, 2, 1])
    }

    // MARK: Failure and cancellation

    func testFailingStepStopsTheRunAndEndsTheTrace() {
        let result = host.run(script([
            log("a", lit("kept")),
            ifThen("i", yes, then: [stmt("f", "test.fail", ["message": lit("disk full")]), log("b", lit("x"))]),
            log("c", lit("x")),
        ]))
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "disk full")
        XCTAssertEqual(result.trace.map(\.blockID), ["a", "i", "f"])
        XCTAssertEqual(result.trace.map(\.succeeded), [true, true, false])
        XCTAssertEqual(result.trace.last?.message, "disk full")
        XCTAssertEqual(host.logged, ["kept"], "nothing is rolled back")
    }

    func testFailureInsideACalledScriptFailsTheWholeRun() {
        let callee = script([stmt("f", "test.fail", ["message": lit("inner")])], id: "callee")
        let result = host.run(script([call("c", "callee"), log("never", lit("x"))]), others: [callee])
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.trace.map(\.blockID), ["c", "f"])
        XCTAssertEqual(result.trace.map(\.succeeded), [true, false], "the trace ends at the step that failed")
    }

    func testThrowingReporterFailsItsStatement() {
        let result = host.run(script([log("l", rep("operator.join", ["a": rep("test.boom"), "b": lit("x")]))]))
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.trace.last?.message, "reporter exploded")
        XCTAssertEqual(host.logged, [])
    }

    func testUnknownBlockKindsFail() {
        let statement = host.run(script([stmt("u", "vendor.gone"), log("never", lit("x"))]))
        XCTAssertEqual(statement.status, .failed)
        XCTAssertEqual(statement.message, "Unknown block kind “vendor.gone”")
        let reporter = host.run(script([log("l", rep("vendor.gone"))]))
        XCTAssertEqual(reporter.status, .failed)
        XCTAssertEqual(reporter.trace.map(\.blockID), ["l"])
    }

    func testMisplacedShapesFail() {
        XCTAssertEqual(host.run(script([stmt("s", "time.now")])).status, .failed)
        XCTAssertEqual(host.run(script([log("l", rep("test.log"))])).status, .failed)
    }

    func testCancelledErrorEndsTheRunAsCancelled() {
        let result = host.run(script([log("a", lit("kept")), stmt("x", "test.cancel"), log("b", lit("x"))]))
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.trace.map(\.blockID), ["a", "x"])
        XCTAssertNil(result.message)
        XCTAssertEqual(host.logged, ["kept"])
    }

    func testCancellationFlagIsPolledBeforeEveryStatement() {
        let limit = 2
        let environment = RunEnvironment(timeZone: prague, now: { fixedNow }, isCancelled: { [host] in host.logged.count >= limit })
        let result = host.run(script([log("a", lit(1)), log("b", lit(2)), log("c", lit(3))]), environment: environment)
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.trace.map(\.blockID), ["a", "b"])
    }

    func testRunningAnUnknownScriptFails() {
        let result = Interpreter(document: Document(), vocabulary: host.vocabulary).run(scriptID: "nope")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "There is no script with id “nope”")
    }

    // MARK: Acceptance scripts (spec §10), from hand-written JSON

    private func acceptance(_ scriptID: String, ticket: String) throws -> (RunResult, TicketDirectory) {
        let directory = TicketDirectory.sample(now: fixedNow)
        let interpreter = Interpreter(document: try AcceptanceDocument.load(),
                                      vocabulary: TicketVocabulary.make(directory: directory), environment: env)
        return (interpreter.run(scriptID: scriptID, arguments: ["ticket": ref("ticket", ticket)]), directory)
    }

    func testEscalateTicketEscalatesAHighPriorityTicket() throws {
        let (result, directory) = try acceptance(AcceptanceDocument.escalateTicketID, ticket: "T-1")
        XCTAssertEqual(result.status, .returned)
        XCTAssertEqual(result.outputs, ["escalated": true])
        XCTAssertEqual(result.trace.map(\.blockID), ["fetch", "decide", "notify-assignee", "label", "return-true"])
        XCTAssertEqual(result.trace.map(\.label), [
            "fetch ticket T-1", "if true then", "notify alice message Escalated: Login page is down",
            "add label escalated to T-1", "return escalated true",
        ])
        XCTAssertTrue(result.trace.allSatisfy(\.succeeded))
        XCTAssertEqual(result.trace[2].note, "Sent to Alice")
        XCTAssertEqual(directory.notifications, [.init(user: "alice", message: "Escalated: Login page is down")])
        XCTAssertEqual(directory.tickets["T-1"]?.labels, ["escalated"])
    }

    func testEscalateTicketEscalatesAnOldLowPriorityTicket() throws {
        let (result, directory) = try acceptance(AcceptanceDocument.escalateTicketID, ticket: "T-2")
        XCTAssertEqual(result.outputs, ["escalated": true])
        XCTAssertEqual(directory.notifications.map(\.user), ["bob"])
    }

    func testEscalateTicketLeavesAFreshLowPriorityTicketAlone() throws {
        let (result, directory) = try acceptance(AcceptanceDocument.escalateTicketID, ticket: "T-3")
        XCTAssertEqual(result.status, .returned)
        XCTAssertEqual(result.outputs, ["escalated": false])
        XCTAssertEqual(result.trace.map(\.blockID), ["fetch", "decide", "return-false"])
        XCTAssertEqual(directory.notifications, [])
        XCTAssertEqual(directory.tickets["T-3"]?.labels, [])
    }

    func testEscalateTicketFailsForAMissingTicket() throws {
        let (result, directory) = try acceptance(AcceptanceDocument.escalateTicketID, ticket: "T-404")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "There is no ticket “T-404”")
        XCTAssertEqual(result.trace.map(\.blockID), ["fetch"])
        XCTAssertEqual(result.outputs, ["escalated": .empty])
        XCTAssertEqual(directory.notifications, [])
    }

    func testAllClearCallsEscalateAndBranchesOnItsOutput() throws {
        let (escalated, first) = try acceptance(AcceptanceDocument.allClearID, ticket: "T-1")
        XCTAssertEqual(escalated.status, .completed)
        XCTAssertEqual(escalated.trace.map(\.blockID), ["call-escalate", "fetch", "decide", "notify-assignee", "label",
                                                       "return-true", "branch", "tell-ops"])
        XCTAssertEqual(escalated.trace.map(\.depth), [0, 1, 1, 1, 1, 1, 0, 0])
        XCTAssertEqual(escalated.trace[0].label, "call Escalate ticket ticket T-1")
        XCTAssertEqual(first.notifications.map(\.message), ["Escalated: Login page is down", "A ticket was escalated"])

        let (clear, second) = try acceptance(AcceptanceDocument.allClearID, ticket: "T-3")
        XCTAssertEqual(clear.trace.map(\.blockID), ["call-escalate", "fetch", "decide", "return-false", "branch", "all-clear"])
        XCTAssertEqual(second.notifications, [.init(user: "ops", message: "All clear")])
    }

    func testOverduePredicate() {
        let directory = TicketDirectory.sample(now: fixedNow)
        let vocabulary = TicketVocabulary.make(directory: directory)
        func overdue(_ ticket: String) -> Value {
            let script = Script(id: "s", name: "S", outputs: [Param(name: "r", type: .bool)], body: [
                ret("r", ["r": rep("ticket.isOverdue", ["ticket": lit(ref("ticket", ticket))])]),
            ])
            return Interpreter(document: Document(scripts: [script]), vocabulary: vocabulary, environment: env)
                .run(scriptID: "s").outputs["r"] ?? .empty
        }
        XCTAssertEqual(overdue("T-1"), false)
        XCTAssertEqual(overdue("T-2"), true)
    }
}
