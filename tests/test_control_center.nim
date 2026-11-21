## The control center's rules (`nim_agents/control_center`) and the parts of
## the instruction composer it relies on (`chooseIntent`, the gaze mark's
## words), native and JS: the layout rule, which records are recent launches
## and what each says, the waiting heading, the operator's chosen intent, and
## the gaze mark's tooltip, toggle and "nothing in view" note.
##
## No test doubles: the draft is the production reducer, driven as a
## viewmodel drives it, and the rest is plain functions. Every expectation is
## written out by hand from the rules in the module comments. The data is
## invented (an upload client's retry work), as everything in this public
## repository.

import std/unittest
import nim_agents/control_center
import nim_agents/agent_harbor/[fleet_records, session_directory]

const Dot = " \xC2\xB7 "

proc launchTargets(manager = true): seq[RouteTarget] =
  ## What the control center offers: the manager it launches through, and no
  ## session or UI action (it is no session's window).
  @[RouteTarget(kind: tkSession, available: false,
                unavailableReason: "The control center has no agent session"),
    RouteTarget(kind: tkManager, id: "mgr-reliability",
                label: "Manager of Upload reliability", available: manager),
    RouteTarget(kind: tkUiAction, available: false,
                unavailableReason: "The control center performs no UI actions")]

proc windowTargets(): seq[RouteTarget] =
  ## A debugging window's destinations: its session, a manager, CodeTracer.
  @[RouteTarget(kind: tkSession, id: "sess-upload", label: "Retry uploads",
                available: true),
    RouteTarget(kind: tkManager, id: "mgr-reliability",
                label: "Manager of Upload reliability", available: true),
    RouteTarget(kind: tkUiAction, id: "codetracer", label: "CodeTracer",
                available: true)]

proc delivered(state: DeliveryState; notice = ""; error = ""): Delivery =
  Delivery(target: tkManager, state: state, error: error,
           receipt: Receipt(notice: notice))

proc rec(text: string; intent: RouteIntent; deliveries: varargs[Delivery];
         label = "Manager of Upload reliability"): ComposerRecord =
  ComposerRecord(text: text, intent: intent, deliveries: @deliveries,
                 labels: (if deliveries.len > 0: @[label] else: @[]))

suite "layout":
  test "two columns, one below the narrow width":
    check layoutFor(1440, 720) == clTwoColumns
    check layoutFor(720, 720) == clTwoColumns   # the edge is wide
    check layoutFor(719, 720) == clOneColumn
    check layoutFor(45, 100) == clOneColumn     # cells, as a terminal measures

suite "recent launches":
  test "only launches and new initiatives, in the order given":
    let records = @[
      rec("Add a 503 retry test\nwith jitter", riLaunchTask,
          delivered(dsSent, "Started on hub-a" & Dot & "session 5ca1ab1e")),
      rec("Why does the retry give up?", riInstruct, delivered(dsSent)),
      rec("Uploads survive a hub restart", riNewInitiative, delivered(dsSent)),
      rec("Run the upload benchmarks", riLaunchTask,
          delivered(dsFailed, error = "Agent Harbor answered 503"))]
    let recent = recentLaunches(records)
    check recent.len == 3
    check recent[0].text == "Add a 503 retry test"     # the first line only
    check recent[0].mode == lmTask
    check recent[0].line == "Started on hub-a" & Dot & "session 5ca1ab1e"
    check not recent[0].failed and not recent[0].pending
    check recentLine(recent[0]) ==
      "Manager of Upload reliability" & Dot & "Started on hub-a" & Dot & "session 5ca1ab1e"
    check recent[1].text == "Uploads survive a hub restart"
    check recent[1].mode == lmInitiative
    check recent[1].line == "Started"                   # no notice: the verb
    check recent[2].failed
    check recent[2].line == "Could not launch: Agent Harbor answered 503"

  test "a launch still waiting, a failed initiative, a launch with no notice":
    let recent = recentLaunches(@[
      rec("Add a 503 retry test", riLaunchTask, delivered(dsSending)),
      rec("Uploads survive", riNewInitiative, delivered(dsFailed)),
      rec("Run the benchmarks", riLaunchTask, delivered(dsSent))])
    check recent[0].pending
    check recent[0].line == "Launching\xE2\x80\xA6"
    check recent[1].line == "Could not start: no answer"
    check recent[2].line == "Launched"

  test "at most the limit; a record with no target reads its line alone":
    var records: seq[ComposerRecord]
    for i in 1 .. 7:
      records.add rec("Task " & $i, riLaunchTask, delivered(dsSent))
    check recentLaunches(records).len == RecentLimit
    check recentLaunches(records, limit = 2).len == 2
    let bare = recentLaunches(@[ComposerRecord(text: "Task", intent: riLaunchTask)])
    check bare[0].target == ""
    check recentLine(bare[0]) == "Launching\xE2\x80\xA6"

suite "words":
  test "the waiting list counts what waits":
    check waitingCountText(0) == ""
    check waitingCountText(1) == "1 session"
    check waitingCountText(3) == "3 sessions"

  test "modes, managers and the send tooltip":
    check modeLabel(lmTask) == "New task"
    check modeLabel(lmInitiative) == "New initiative"
    check intentOf(lmTask) == riLaunchTask
    check intentOf(lmInitiative) == riNewInitiative
    check modeOf(riNewInitiative) == lmInitiative
    check modeOf(riInstruct) == lmTask
    check managerLabel("Upload reliability") == "Manager of Upload reliability"
    check launchForLabel("Upload reliability") == "Launch for Upload reliability"
    check launchForLabel("  ") == "Launch outside every initiative"
    check NoInitiativesWords == "No initiatives yet."

suite "the waiting sessions":
  test "inbox order: waiting on a question first, then ended turns, longest first":
    let sessions = @[
      FleetSession(id: "running", status: fsRunning, updatedAtMs: 10),
      FleetSession(id: "idle-new", status: fsRunning, awaitingInput: true,
                   awaitingInputSource: "claude-stop-hook", updatedAtMs: 50),
      FleetSession(id: "completed", status: fsCompleted, updatedAtMs: 60),
      FleetSession(id: "asks-late", status: fsRunning, awaitingInput: true, updatedAtMs: 40),
      FleetSession(id: "asks-early", status: fsRunning, awaitingInput: true, updatedAtMs: 20),
      FleetSession(id: "failed", status: fsFailed, updatedAtMs: 5)]
    var ids: seq[string]
    for i in inboxOrder(sessions): ids.add sessions[i].id
    check ids == @["asks-early", "asks-late", "idle-new"]

suite "the operator's chosen intent":
  test "New task: the launch form applies whatever the router says":
    var d = initDraft(launchTargets())
    check d.chooseIntent(riLaunchTask)
    check d.chosen == tkManager
    d.setText("Add a 503 retry test")
    check d.intentOf == riLaunchTask
    check d.beginRouting()
    check d.applyDecision(RoutingDecision(target: tkManager, intent: riInstruct))
    check d.intentOf == riLaunchTask                # the operator's, not the router's
    check d.sendProblems.len == 2                   # repository, agents
    d.launch.repository = "upload-service"
    d.launch.agents = @["Claude"]
    check d.beginSend()
    check d.sentIntent == riLaunchTask

  test "Enter does not wait for the router once the operator chose":
    var d = initDraft(launchTargets())
    discard d.chooseIntent(riNewInitiative)
    d.setText("Uploads survive a hub restart")
    d.initiative.goal = "Uploads survive a hub restart"
    check d.beginRouting()                          # still deciding
    check d.beginSend()
    check not d.awaitingRoute
    check d.sentIntent == riNewInitiative

  test "the choice stands for the next instruction, and in a window with a session":
    var d = initDraft(windowTargets())
    check d.chosen == tkSession
    check d.chooseIntent(riLaunchTask)
    check d.chosen == tkManager
    d.setText("Add a 503 retry test")
    check d.chosen == tkManager
    d.setText("")                                   # emptied: choices reset
    check d.chosen == tkManager                     # the intent stands
    check d.intentOf == riLaunchTask
    check d.beginRouting() == false                 # nothing typed
    d.setText("Add a 504 retry test")
    check d.beginRouting()
    check d.applyDecision(RoutingDecision(target: tkSession))
    check d.chosen == tkManager                     # the router does not move it

  test "switching the mode, giving it back, and the refusals":
    var d = initDraft(launchTargets())
    check d.chooseIntent(riLaunchTask)
    check not d.chooseIntent(riLaunchTask)          # nothing changed
    check d.chooseIntent(riNewInitiative)
    check d.intentOf == riNewInitiative
    check d.chooseIntent(riInstruct)
    check not d.intentChosen
    check not d.chooseIntent(riInstruct)
    var none = initDraft(launchTargets(manager = false))
    check not none.chooseIntent(riLaunchTask)       # no manager to launch through
    var sent = initDraft(launchTargets())
    discard sent.chooseIntent(riNewInitiative)
    sent.setText("Uploads survive")
    sent.initiative.goal = "Uploads survive"
    check sent.beginSend()
    check not sent.chooseIntent(riLaunchTask)       # sending: refused

suite "the gaze mark":
  test "the tooltip names the key; no mark, no tooltip":
    check gazeMarkTooltip(gsOff, "Ctrl+Alt+G") == ""
    check gazeMarkTooltip(gsTracking, "Ctrl+Alt+G") ==
      "Gaze tracking is on: what you look at can be attached to an instruction. " &
      "Ctrl+Alt+G pauses it."
    check gazeMarkTooltip(gsPaused, "Ctrl+Alt+G") ==
      "Gaze tracking is paused: nothing you look at is attached. Ctrl+Alt+G resumes it."
    check gazeMarkTooltip(gsPaused, "") ==
      "Gaze tracking is paused: nothing you look at is attached. The gaze key resumes it."

  test "the pause key never turns tracking on":
    check toggledGaze(gsTracking) == gsPaused
    check toggledGaze(gsPaused) == gsTracking
    check toggledGaze(gsOff) == gsOff

  test "looked at nothing: a note, never cited":
    let chip = gazeNothingChip()
    check chip.kind == ckGaze
    check chip.note
    check chip.label == "Looked at nothing in view"
    var d = initDraft(windowTargets(), [chip])
    d.setText("Why does the retry give up?")
    check not d.toggleContext("gaze-nothing")
    check d.beginRouting()
    check d.applyDecision(RoutingDecision(target: tkSession, cited: @["gaze-nothing"]))
    check d.cited.len == 0
