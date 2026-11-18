## The omnibox composer's domain (`nim_agents/instruction_composer`), native
## and JS: the one-step flow (the decision shown while typing, Enter sending
## at once, or when the decision arrives), what a decision may cite,
## redirects before and after sending, deliveries and their records, the
## destinations' fixed order and states, and the launch, schedule and
## initiative forms' validation.
##
## No test doubles: the draft is the production reducer, driven step by step
## as a viewmodel drives it. Every expectation is written out by hand from the
## rules in the module comment. The data is invented (an upload client's
## retry work), as everything in this public repository.

import std/[strutils, unittest]
import nim_agents/instruction_composer
import nim_agents/agent_harbor/operator_actions

const Dot = " \xC2\xB7 "

proc targets(sessionAvailable = true; running = false): seq[RouteTarget] =
  @[RouteTarget(kind: tkSession, id: "sess-upload-retry",
                label: "Make the upload client retry with jitter",
                available: sessionAvailable, running: running,
                unavailableReason: (if sessionAvailable: "" else: "No agent session in this window")),
    RouteTarget(kind: tkManager, id: "mgr-reliability",
                label: "Upload reliability manager", available: true),
    RouteTarget(kind: tkUiAction, id: "codetracer", label: "CodeTracer",
                available: true)]

proc context(): seq[ContextItem] =
  @[ContextItem(id: "file", kind: ckFile, label: "src/upload/client.py:42",
                reference: "src/upload/client.py:42"),
    ContextItem(id: "replay", kind: ckReplay, label: "Replay at step 1,284",
                reference: "trace:upload-retry#1284"),
    ContextItem(id: "pane", kind: ckPane, label: "Variables: attempt",
                reference: "state:attempt"),
    gazePausedChip()]

proc fields(problems: seq[LaunchProblem]): seq[string] =
  for p in problems: result.add p.field

proc routed(d: var ComposerDraft; decision: RoutingDecision) =
  doAssert d.beginRouting()
  doAssert d.applyDecision(decision)

proc drafted(text = "Also retry on a 503"): ComposerDraft =
  result = initDraft(targets(), context())
  result.setText(text)

suite "one step":
  test "the decision shows while typing, and Enter sends at once":
    var d = drafted()
    check d.phase == cpComposing
    check d.beginRouting()
    check d.route == rsRouting
    check d.applyDecision(RoutingDecision(target: tkManager,
      reason: "It is fleet work"))
    check d.route == rsDecided
    check d.phase == cpComposing              # shown, not sent
    check d.chosen == tkManager
    check d.beginSend()                       # one Enter
    check d.phase == cpSending
    check d.deliveries == @[Delivery(target: tkManager, state: dsSending)]

  test "Enter before the decision sends when it arrives":
    var d = drafted()
    check d.beginRouting()
    check d.beginSend()
    check d.awaitingRoute
    check d.phase == cpSending
    check d.deliveries.len == 0
    check d.headerLine == "Routing\xE2\x80\xA6" & Dot & "sends when routed"
    check not d.deliveryReady                 # no decision yet
    check d.applyDecision(RoutingDecision(target: tkUiAction))
    check d.deliveryReady
    check d.deliveries == @[Delivery(target: tkUiAction, state: dsSending)]
    check not d.awaitingRoute

  test "Enter before a failed decision sends nothing":
    var d = drafted()
    check d.beginRouting()
    check d.beginSend()
    check d.applyRouteFailure("the routing agent did not answer in 20 s")
    check d.phase == cpComposing
    check not d.awaitingRoute
    check d.deliveries.len == 0
    check d.headerLine == "Could not route: the routing agent did not answer in 20 s"
    check d.beginSend()                       # the destination shown: the session
    check d.deliveries[0].target == tkSession

  test "Enter while routing, after the operator chose, sends at once":
    var d = drafted()
    check d.beginRouting()
    check d.choose(tkManager)
    check d.beginSend()
    check not d.awaitingRoute
    check d.deliveries[0].target == tkManager

  test "an empty instruction is neither routed nor sent":
    var d = drafted("   ")
    check not d.beginRouting()
    check not d.beginSend()
    check d.phase == cpComposing

  test "typing drops the decision and keeps the operator's choices":
    var d = drafted()
    d.routed(RoutingDecision(target: tkManager, reason: "fleet work", cited: @["file"]))
    check d.choose(tkUiAction)
    check d.toggleContext("replay")           # cited by the operator
    d.setText("Also retry on a 503 and a 504")
    check not d.decided
    check d.route == rsNone
    check d.chosen == tkUiAction
    check d.cited.len == 1 and d.cited[0].id == "replay"
    d.routed(RoutingDecision(target: tkSession, cited: @["file"]))
    check d.chosen == tkUiAction              # the router does not override it
    check d.cited.len == 2

  test "an answer for a step the draft left changes nothing":
    var d = drafted()
    check d.beginRouting()
    d.setText("Something else")               # the routing was superseded
    check not d.applyDecision(RoutingDecision(target: tkManager))
    check not d.applyRouteFailure("late")
    check d.route == rsNone
    check not d.applyReceipt(tkSession, Receipt())

suite "what is cited":
  test "nothing is cited by default":
    var d = drafted()
    d.routed(RoutingDecision(target: tkSession))
    check d.cited.len == 0
    check d.citesLine == "Cites nothing from this window"

  test "a decision cites only what the window offered":
    var d = drafted()
    d.routed(RoutingDecision(target: tkSession, cited: @["file", "unknown", "file"]))
    check d.decision.cited == @["file"]
    check d.citesLine == "Cites src/upload/client.py:42"

  test "an excluded chip is never cited":
    var d = drafted()
    d.routed(RoutingDecision(target: tkSession, cited: @["file", "replay"]))
    check d.toggleContext("replay")           # uncited by the operator
    check d.context[1].excluded
    check d.citesLine == "Cites src/upload/client.py:42"
    d.setText("Also retry on a 503, now")
    d.routed(RoutingDecision(target: tkSession, cited: @["file", "replay"]))
    check d.citesLine == "Cites src/upload/client.py:42"   # still uncited

  test "the operator cites a chip the router did not":
    var d = drafted()
    d.routed(RoutingDecision(target: tkSession))
    check d.toggleContext("pane")
    check d.citesLine == "Cites Variables: attempt"
    check d.toggleContext("pane")             # and uncites it again
    check d.cited.len == 0

  test "a note is never cited and cannot be switched":
    var d = drafted()
    check not d.toggleContext("gaze-paused")
    d.routed(RoutingDecision(target: tkSession, cited: @["gaze-paused", "pane"]))
    check d.decision.cited == @["pane"]

  test "attached context is cited":
    var d = drafted()
    check d.addContext(ContextItem(id: "att-1", kind: ckAttachment,
                                   label: "tests/test_retry.py",
                                   reference: "tests/test_retry.py"))
    d.routed(RoutingDecision(target: tkSession))
    check d.citesLine == "Cites tests/test_retry.py"

  test "a new instruction starts with no operator choices":
    var d = drafted()
    d.routed(RoutingDecision(target: tkSession))
    check d.choose(tkManager)
    check d.toggleContext("file")
    check d.beginSend()
    check d.applyReceipt(tkManager, Receipt())
    d.setText("Next")
    check not d.operatorChose
    check d.chosen == tkSession
    check d.cited.len == 0

suite "the destinations":
  test "the destinations keep their fixed order":
    var d = drafted()
    d.routed(RoutingDecision(target: tkUiAction, action: "Show client.py beside the test"))
    let rows = d.destinationRows
    check rows.len == 3
    check rows[0].target == tkSession
    check rows[1].target == tkManager
    check rows[2].target == tkUiAction
    check rows[0].title == "This session"
    check rows[1].title == "Manager agent"
    check rows[2].title == "UI action"
    check rows[2].label == "Show client.py beside the test"
    check rows[2].mark == rmRouted
    check rows[2].selected
    check not rows[0].selected
    check rows[0].mark == rmNone

  test "a redirect keeps what the router chose":
    var d = drafted()
    d.routed(RoutingDecision(target: tkManager, reason: "fleet work"))
    check d.choose(tkSession)
    check d.decision.target == tkManager
    check d.decision.reason == "fleet work"
    check d.chosen == tkSession
    check d.chosenByOperator
    let rows = d.destinationRows
    check rows[0].mark == rmChosen
    check rows[0].selected
    check rows[1].mark == rmRouterChoice
    check rows[1].reason == "fleet work"
    check not rows[1].selected
    check d.headerLine == "Enter sends it where you chose"
    check d.beginSend()
    check d.deliveries[0].target == tkSession

  test "an unavailable destination is never chosen, routed to or sent to":
    var d = initDraft(targets(sessionAvailable = false), context())
    check d.chosen == tkManager               # the first available one
    d.setText("Retry on a 503")
    check d.beginRouting()
    check d.applyDecision(RoutingDecision(target: tkSession))
    check d.route == rsFailed
    check d.routeError == "The router chose this session, which this window " &
                          "cannot reach: No agent session in this window"
    check not d.choose(tkSession)
    let rows = d.destinationRows
    check not rows[0].enabled
    check rows[0].reason == "No agent session in this window"
    check rows[1].enabled and rows[1].selected
    check d.beginSend()
    check d.deliveries[0].target == tkManager

  test "a running session offers Stop":
    var d = initDraft(targets(running = true), context())
    check d.destinationRows[0].canStop
    check not d.destinationRows[1].canStop
    check not initDraft(targets(), context()).destinationRows[0].canStop

  test "while the router decides no destination is selected":
    var d = drafted()
    check d.beginRouting()
    for row in d.destinationRows:
      check not row.selected and row.mark == rmNone
    check d.citesLine == ""
    check d.applyRouteFailure("no answer")
    check d.destinationRows[0].selected       # the first available, to send to
    check d.citesLine == "Cites nothing from this window"

  test "the destination in a sentence":
    check destinationPhrase(tkSession) == "this session"
    check destinationPhrase(tkManager) == "the manager agent"
    check destinationPhrase(tkUiAction) == "the UI-action agent"

  test "with nothing typed no destination is selected":
    let d = initDraft(targets(), context())
    for row in d.destinationRows:
      check not row.selected and not row.enabled and row.mark == rmNone

suite "deliveries":
  test "a delivery that arrives is recorded and clears the field":
    var d = drafted()
    d.routed(RoutingDecision(target: tkSession))
    check d.beginSend()
    check d.applyReceipt(tkSession, Receipt())
    check d.phase == cpSent
    check d.text == ""
    check d.sentText == "Also retry on a 503"
    check d.recent.len == 1
    check d.recent[0].text == "Also retry on a 503"
    check d.recent[0].labels == @["Make the upload client retry with jitter"]
    check d.deliveryLine(d.recent[0]) == "Sent to this session"
    let rows = d.destinationRows
    check rows[0].delivery == dsSent and rows[0].selected
    check rows[1].canSendAgain and rows[2].canSendAgain
    check not rows[0].canSendAgain

  test "sending again adds a delivery":
    var d = drafted()
    d.routed(RoutingDecision(target: tkSession))
    check d.beginSend()
    check d.applyReceipt(tkSession, Receipt())
    check d.sendAgain(tkManager)
    check d.phase == cpSending
    check d.deliveries.len == 2
    check d.deliveries[0] == Delivery(target: tkSession, state: dsSent)
    check d.applyReceipt(tkManager, Receipt())
    check d.recent.len == 1                 # the same record, updated
    check d.deliveryLine(d.recent[0]) == "Sent to this session" & Dot &
                                         "redirected to the manager agent"
    check not d.sendAgain(tkSession)        # never twice to one destination

  test "a failed delivery says why and can be retried":
    var d = drafted()
    d.routed(RoutingDecision(target: tkManager))
    check d.beginSend()
    check d.applyDeliveryFailure(tkManager, "Agent Harbor answered 503")
    check d.phase == cpSendFailed
    check d.text == "Also retry on a 503"   # nothing sent: kept
    check d.recent.len == 0
    check d.destinationRows[1].error == "Agent Harbor answered 503"
    check d.retry() == (true, tkManager)
    check d.phase == cpSending
    check d.applyReceipt(tkManager, Receipt())
    check d.phase == cpSent

  test "two failed deliveries are retried one at a time, each to its own target":
    var d = drafted()
    d.routed(RoutingDecision(target: tkSession))
    check d.beginSend()
    check d.applyDeliveryFailure(tkSession, "Agent Harbor answered 503")
    check d.sendAgain(tkManager)
    check d.applyDeliveryFailure(tkManager, "Agent Harbor answered 503")
    check d.phase == cpSendFailed
    check d.retry() == (true, tkSession)       # the first that failed
    check d.deliveries[0].state == dsSending
    check d.deliveries[1].state == dsFailed     # untouched
    check d.applyReceipt(tkSession, Receipt())
    check d.phase == cpSendFailed               # the manager's still failed
    check d.retry() == (true, tkManager)
    check d.applyReceipt(tkManager, Receipt())
    check d.phase == cpSent
    check d.retry() == (false, tkSession)       # nothing left to retry

  test "a delivery that failed stays retryable after a redirect that arrived":
    var d = drafted()
    d.routed(RoutingDecision(target: tkSession))
    check d.beginSend()
    check d.applyDeliveryFailure(tkSession, "Agent Harbor answered 503")
    check d.sendAgain(tkManager)
    check d.applyReceipt(tkManager, Receipt())
    check d.phase == cpSendFailed
    check d.retry() == (true, tkSession)

  test "a UI action's outcome is in its receipt":
    var d = drafted("Show the client beside the test")
    d.routed(RoutingDecision(target: tkUiAction, action: "Show client.py beside the test"))
    check d.beginSend()
    check d.applyReceipt(tkUiAction, Receipt(outcome: uoRefused,
                                             result: "no recording is open in this window"))
    check outcomeLine(d.destinationRows[2].receipt) ==
      "Refused: no recording is open in this window"
    check outcomeLine(Receipt(outcome: uoDone, result: "Opened client.py beside the test")) ==
      "Opened client.py beside the test"

  test "typing after a delivery starts the next instruction":
    var d = drafted()
    d.routed(RoutingDecision(target: tkSession))
    check d.beginSend()
    check d.applyReceipt(tkSession, Receipt())
    d.setText("Now the 504")
    check d.phase == cpComposing
    check d.deliveries.len == 0
    check d.recent.len == 1

  test "Recent keeps five, newest first, and gives a text back":
    var d = initDraft(targets(), context())
    for i in 1 .. 7:
      d.setText("instruction " & $i)
      d.routed(RoutingDecision(target: tkSession))
      check d.beginSend()
      check d.applyReceipt(tkSession, Receipt())
    check d.recent.len == RecentLimit
    check d.recent[0].text == "instruction 7"
    check d.recent[4].text == "instruction 3"
    check d.recall(2)
    check d.text == "instruction 5"
    check d.phase == cpComposing

suite "launching and starting an initiative":
  test "a launch goes to the manager with its options":
    var d = drafted("Start a task: add a 503 retry test")
    d.routed(RoutingDecision(target: tkManager, intent: riLaunchTask))
    check d.intentOf == riLaunchTask
    check sendLabel(d.intentOf) == "Launch"
    check d.sendProblems.fields == @["repository", "agents"]
    check not d.beginSend()
    d.launch.repository = "upload-service"
    d.launch.agents = @["Claude Code"]
    check d.sendProblems.len == 0
    check d.beginSend()
    check d.sentIntent == riLaunchTask
    check d.applyReceipt(tkManager, Receipt(notice: "Started on server-a" & Dot &
      "executor exec-7" & Dot & "session 5ca1ab1e"))
    check outcomeLine(d.deliveries[0].receipt) ==
      "Started on server-a" & Dot & "executor exec-7" & Dot & "session 5ca1ab1e"

  test "a launch sent to the session instead is an instruction":
    var d = drafted("Start a task: add a 503 retry test")
    d.routed(RoutingDecision(target: tkManager, intent: riLaunchTask))
    check d.choose(tkSession)
    check d.sendProblems.len == 0
    check d.beginSend()
    check d.sentIntent == riInstruct

  test "a cron expression has five fields":
    check validateCron("0 9 * * MON-FRI") == ""
    check validateCron("*/15 0-6,22-23 1 jan,jul 0") == ""
    check validateCron("0 9 * * 1 2026") ==
      "A cron expression has five fields (minute hour day month weekday); this one has 6"
    check validateCron("0 25 * * *") ==
      "The hour field allows 0-23; 25 is out of range"
    check validateCron("0 9 * FOO *") ==
      "The month field: FOO is not a number or a name"
    check validateCron("0 9 0 * *") ==
      "The day of the month field allows 1-31; 0 is out of range"
    check validateCron("*/0 * * * *") ==
      "The minute field: the step in */0 is not a positive number"
    check validateCron("0 17-9 * * *") ==
      "The hour field: the range 17-9 runs backwards"
    check validateCron("x * * * *") ==
      "The minute field: x is not a number"

  test "an over-long number is out of range, never an exception":
    check validateCron("99999999999999999999 * * * *") ==
      "The minute field allows 0-59; 99999999999999999999 is out of range"
    check validateCron("*/99999999999999999999 * * * *") ==
      "The minute field: the step in */99999999999999999999 is out of range (1-59)"
    check validateCron("0 1-99999999999999999999 * * *") ==
      "The hour field allows 0-23; 99999999999999999999 is out of range"
    check validateCron("*/75 * * * *") ==
      "The minute field: the step in */75 is out of range (1-59)"
    check validateCron("0007 * * * *") == ""   # leading zeros are a small number
    let o = LaunchOptions(repository: "r", agents: @["a"], schedule: Schedule(
      enabled: true, cron: "99999999999999999999 * * * *", timezone: "UTC"))
    check validateLaunch(o) == @[LaunchProblem(field: "cron",
      text: "The minute field allows 0-59; 99999999999999999999 is out of range")]

  test "a schedule's problems are the form's":
    var o = LaunchOptions(repository: "upload-service", agents: @["Codex"],
                          runOn: roExecutor)
    o.schedule = Schedule(enabled: true, cron: "0 9 * *", timezone: "Sofia",
                          jitterSeconds: 4000)
    let problems = validateLaunch(o)
    check problems.len == 4
    check problems[0] == LaunchProblem(field: "executor", text: "Choose an executor")
    check problems[1].field == "cron"
    check problems[2] == LaunchProblem(field: "timezone",
      text: "Use a time zone name such as Europe/Sofia or UTC")
    check problems[3] == LaunchProblem(field: "jitter",
      text: "Jitter is between 0 and 3600 seconds")
    o.executor = "exec-7"
    o.schedule = Schedule(enabled: true, cron: "30 6 * * 1-5",
                          timezone: "Europe/Sofia", jitterSeconds: 60)
    check validateLaunch(o).len == 0
    o.schedule.enabled = false
    o.schedule.cron = "nonsense"
    check validateLaunch(o).len == 0        # a schedule switched off is not checked

  test "the plan file's preview":
    let f = NewInitiativeForm(goal: "Make uploads survive a flaky network, end to end",
                              iteration: imAuto)
    check slugOf(f.goal) == "make-uploads-survive-a-flaky-network"
    check planFilePreview(f, "2026-11-17") ==
      "milestones/2026-11-17-make-uploads-survive-a-flaky-network.milestones.org"
    check planFilePreview(NewInitiativeForm(goal: "!!!"), "2026-11-17") ==
      "milestones/2026-11-17-initiative.milestones.org"
    check planFilePreview(NewInitiativeForm(goal: "x", planPath: " plans/uploads.milestones.org "),
                          "2026-11-17") == "plans/uploads.milestones.org"

  test "an initiative's problems":
    check validateInitiative(NewInitiativeForm(goal: "Uploads", iteration: imOnce)).len == 0
    let bad = validateInitiative(NewInitiativeForm(goal: " ", iteration: imCount,
                                                   iterations: 0,
                                                   planPath: "../elsewhere.milestones.org"))
    check bad.len == 3
    check bad[0].field == "goal"
    check bad[1].field == "iterations"
    check bad[2] == LaunchProblem(field: "plan",
      text: "The plan file is a path inside the workspace")
    check validateInitiative(NewInitiativeForm(goal: "Uploads",
      planPath: "milestones/uploads.org"))[0].text == "A plan file ends in .milestones.org"

suite "words":
  test "the field shows the first line and how many follow":
    check firstLineAndMore("one") == ("one", 0)
    check firstLineAndMore("one\ntwo\nthree") == ("one", 2)
    check moreLinesLabel(0) == ""
    check moreLinesLabel(1) == "+1 line"
    check moreLinesLabel(2) == "+2 lines"

  test "the gaze chip and mark":
    let chip = gazeChip("gaze", "retries += 1", "src/upload/client.py:44", 1360)
    check chip.label == "Looked at retries += 1" & Dot & "1.4 s"
    check chip.kind == ckGaze and not chip.note
    check gazeMark(gsOff) == (false, "")
    check gazeMark(gsTracking) == (true, "Gaze")
    check gazeMark(gsPaused) == (true, "Gaze paused")
    check gazePausedChip().note

  test "the header line follows the flow":
    var d = initDraft(targets(), context())
    check d.headerLine == "Type an instruction. Enter sends it where it shows; " &
                          "\xE2\x86\x91\xE2\x86\x93 another destination."
    d.setText("Retry")
    check d.headerLine == "Enter sends it" & Dot & "\xE2\x86\x91\xE2\x86\x93 another destination"
    check d.beginRouting()
    check d.headerLine == "Routing\xE2\x80\xA6" & Dot & "Enter sends it when routed"
    check d.applyDecision(RoutingDecision(target: tkSession))
    check d.headerLine == "Enter sends it" & Dot & "\xE2\x86\x91\xE2\x86\x93 another destination"
    check d.beginSend()
    check d.headerLine == "Sending\xE2\x80\xA6"

suite "what a destination receives":
  test "the instruction after the header of what it cites":
    let cited = @[ContextItem(id: "file", kind: ckFile, label: "src/upload/client.py:42",
                              reference: "src/upload/client.py:42"),
                  ContextItem(id: "replay", kind: ckReplay, label: "Replay at step 1,284",
                              reference: "trace:upload-retry#1284")]
    check deliveredText("Retry on a 503", []) == "Retry on a 503"
    check deliveredText("Retry on a 503", cited) ==
      "Context from the operator's window:\n" &
      "- src/upload/client.py:42\n" &
      "- trace:upload-retry#1284 (Replay at step 1,284)\n\n" &
      "Retry on a 503"

  test "a launch's and an initiative's options, named":
    var o = LaunchOptions(repository: "upload-service", agents: @["Claude", "Codex"],
                          runOn: roExecutor, executor: "exec-7", openIn: oiSplit, focus: true)
    check launchParams(o) == @[("repository", "upload-service"), ("agents", "Claude,Codex"),
      ("run-on", "Executor"), ("executor", "exec-7"), ("open-in", "Split, focused")]
    o.schedule = Schedule(enabled: true, cron: "30 6 * * 1-5", timezone: "UTC",
                          jitterSeconds: 60)
    check launchParams(o)[^5 .. ^1] == @[("cron", "30 6 * * 1-5"), ("timezone", "UTC"),
      ("jitter-seconds", "60"), ("concurrency", "Allow overlap"),
      ("misfire", "Run once, drop catch-up")]
    check initiativeParams(NewInitiativeForm(goal: "Uploads survive", iteration: imCount,
                                             iterations: 3, relatedSpecs: @["a.md", "b.md"]),
                           "2026-11-18") ==
      @[("iterations", "3"), ("plan", "milestones/2026-11-18-uploads-survive.milestones.org"),
        ("related-specs", "a.md,b.md")]

suite "the composer's actions":
  test "each delivery is an operator action with its route":
    let toManager = instructManager("mgr-1", "Which milestone next?", taskId = "task-9")
    check routeOf(toManager) == ("POST", "/api/v1/sessions/mgr-1/prompt")
    check $toManager == "instruct-manager session=mgr-1 task=task-9 text=\"Which milestone next?\""
    let launch = launchTask("Add a 503 test", @[("repository", "upload-service"),
                            ("agents", "Claude")], managerSessionId = "mgr-1")
    check routeOf(launch) == ("POST", "/api/v1/tasks")
    check $launch == "launch-task session=mgr-1 repository=upload-service agents=Claude " &
                     "text=\"Add a 503 test\""
    let initiative = startInitiative("Uploads survive", @[("plan", "milestones/x.milestones.org")])
    check routeOf(initiative) == ("", "")     # proposed: no route yet
    check $initiative == "start-initiative plan=milestones/x.milestones.org text=\"Uploads survive\""
    let stop = stopSession("sess-1")
    check routeOf(stop) == ("POST", "/api/v1/sessions/sess-1/stop")
    check $stop == "stop-session session=sess-1"

  test "a stop and each launch have their own in-flight key":
    check targetOf(stopSession("sess-1")) == "stop::sess-1"
    check targetOf(stopSession("sess-1")) != targetOf(sendInstruction("sess-1", "go on"))
    let a = launchTask("Add a 503 test", @[], managerSessionId = "mgr-1")
    let b = launchTask("Add a 504 test", @[], managerSessionId = "mgr-1")
    check targetOf(a) == "launch::mgr-1:Add a 503 test"
    check targetOf(a) != targetOf(b)
    check targetOf(a) != targetOf(instructManager("mgr-1", "Add a 503 test"))
    check targetOf(a) == targetOf(launchTask("Add a 503 test", @[], managerSessionId = "mgr-1"))
    check targetOf(startInitiative("Uploads", @[], managerSessionId = "mgr-1")) ==
      "initiative::mgr-1:Uploads"

