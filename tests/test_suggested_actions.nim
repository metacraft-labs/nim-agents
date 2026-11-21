## Suggested UI actions (`nim_agents/suggested_actions`), native and JS: an
## action the front-end cannot perform is never checked or approved; the
## approve button's label; one decision per suggestion; the record lines;
## the auto-approve match; and the operator action that answers Agent
## Harbor.
##
## No test doubles: the module is plain data and a reducer, driven as a
## viewmodel drives it. Every expectation is written out by hand from the
## rules in the module comment. The data is invented (an upload client's
## retry work), as everything in this public repository.

import std/unittest
import nim_agents/suggested_actions
import nim_agents/agent_harbor/operator_actions

proc act(id, action, description: string; doneText = "";
         unavailable = ""): SuggestedAction =
  SuggestedAction(id: id, action: action, description: description,
                  doneText: doneText, unavailable: unavailable)

proc suggestion(actions: varargs[SuggestedAction]): ActionSuggestion =
  ActionSuggestion(requestId: "req-1", sessionId: "s-upload",
                   reason: "Look at the failing retry before changing it.",
                   actions: @actions)

let openTrace = act("a1", "open-url", "Open the recording of test_retry in a new tab",
                    doneText = "Opened the recording of test_retry in a new tab")
let showCalls = act("a2", "show-panel", "Show the call trace beside the editor",
                    doneText = "Showed the call trace beside the editor")
let showVars = act("a3", "show-panel", "Show the Variables panel",
                   doneText = "Showed the Variables panel")
let missingTrace = act("a4", "open-url", "Open the recording of test_retry on macos-arm64",
                       unavailable = "No recording of test_retry on macos-arm64 has been uploaded")
let notOffered = act("a5", "run-command", "Run the tests again")

suite "what can be checked":
  test "every performable action starts checked":
    let d = newDecision(suggestion(openTrace, showCalls, showVars))
    check d.checkedIds == @["a1", "a2", "a3"]
    check d.phase == spPending

  test "an action the front-end cannot perform is never checked":
    var d = newDecision(suggestion(openTrace, missingTrace))
    check d.cannotPerform("a4") == "No recording of test_retry on macos-arm64 has been uploaded"
    check not d.isChecked("a4")
    check not d.toggle("a4")
    check not d.isChecked("a4")
    check d.checkedIds == @["a1"]

  test "an action outside the vocabulary is refused with that reason":
    var d = newDecision(suggestion(openTrace, notOffered))
    check d.cannotPerform("a5") == "CodeTracer does not offer the action run-command"
    check not d.toggle("a5")
    check d.performableCount == 1

  test "toggle unchecks and checks again":
    var d = newDecision(suggestion(openTrace, showCalls, showVars))
    check d.toggle("a2")
    check d.checkedIds == @["a1", "a3"]
    check d.toggle("a2")
    check d.checkedIds == @["a1", "a2", "a3"]
    check not d.toggle("no-such-action")

suite "the approve button":
  test "Approve when every performable action is checked":
    let d = newDecision(suggestion(openTrace, showCalls, showVars))
    check d.approveLabel == "Approve"
    check d.approveDisabledReason == ""
    check d.canApprove

  test "Approve N of M when only some are; M counts performable actions only":
    var d = newDecision(suggestion(openTrace, showCalls, showVars, missingTrace))
    check d.approveLabel == "Approve"   # the unperformable one does not count
    check d.toggle("a2")
    check d.approveLabel == "Approve 2 of 3"

  test "disabled with its reason when nothing is checked":
    var d = newDecision(suggestion(openTrace))
    check d.toggle("a1")
    check not d.canApprove
    check d.approveLabel == "Approve"
    check d.approveDisabledReason == ChooseAnActionReason
    let none = newDecision(suggestion(missingTrace, notOffered))
    check none.approveDisabledReason == NothingPerformableReason

suite "one decision":
  test "approve takes only the checked, performable actions, in the block's order":
    var d = newDecision(suggestion(openTrace, showCalls, missingTrace, showVars))
    check d.toggle("a2")
    check d.beginApprove()
    check d.phase == spApproving
    check d.approvedIds == @["a1", "a3"]

  test "after approving, no toggle and no second decision changes it":
    var d = newDecision(suggestion(openTrace, showCalls))
    check d.beginApprove()
    check not d.toggle("a1")
    check not d.beginApprove()
    check not d.dismiss()
    check d.approvedIds == @["a1", "a2"]

  test "after dismissing, nothing is approved":
    var d = newDecision(suggestion(openTrace, showCalls))
    check d.dismiss()
    check not d.beginApprove()
    check not d.toggle("a1")
    check d.checkedIds.len == 0
    check d.approvedIds.len == 0

  test "approved once every approved action has its outcome; strays are ignored":
    var d = newDecision(suggestion(openTrace, showCalls, showVars))
    check d.toggle("a3")
    check d.beginApprove()
    d.applyOutcome("a3", Receipt(outcome: uoDone))      # not approved
    d.applyOutcome("a1", Receipt(outcome: uoDone))
    check d.phase == spApproving
    d.applyOutcome("a1", Receipt(outcome: uoRefused))   # a second answer
    d.applyOutcome("a2", Receipt(outcome: uoDone))
    check d.phase == spApproved
    check d.outcomes.len == 2
    check d.outcomeOf("a1")[1].receipt.outcome == uoDone

suite "the record":
  test "nothing while the suggestion waits or is being performed":
    var d = newDecision(suggestion(openTrace))
    check d.recordLines.len == 0
    check d.beginApprove()
    check d.recordLines.len == 0

  test "Approved N UI actions, each outcome at level 1":
    var d = newDecision(suggestion(openTrace, showCalls))
    check d.beginApprove()
    d.applyOutcome("a1", Receipt(outcome: uoDone))
    d.applyOutcome("a2", Receipt(outcome: uoRefused, result: "the call trace is not in this layout"))
    check d.recordLines == @[
      RecordLine(text: "Approved 2 UI actions", role: "body"),
      RecordLine(text: "Opened the recording of test_retry in a new tab", role: "body", level: 1),
      RecordLine(text: "Refused: the call trace is not in this layout", role: "warning", level: 1)]

  test "one approved action is singular":
    var d = newDecision(suggestion(openTrace))
    check d.beginApprove()
    d.applyOutcome("a1", Receipt(outcome: uoPartial, result: "Done 1 of 2: opened the tab"))
    check d.recordLines[0].text == "Approved 1 UI action"
    check d.recordLines[1] == RecordLine(text: "Done 1 of 2: opened the tab",
                                         role: "warning", level: 1)

  test "Dismissed N suggested UI actions, in the quiet role, counting every action":
    var d = newDecision(suggestion(openTrace, missingTrace))
    check d.dismiss()
    check d.recordLines == @[RecordLine(text: "Dismissed 2 suggested UI actions", role: "quiet")]
    var one = newDecision(suggestion(openTrace))
    check one.dismiss()
    check one.recordLines[0].text == "Dismissed 1 suggested UI action"

  test "an auto-approved action is a line with a quiet tag, its outcome under it":
    var d = newDecision(suggestion(showVars), autoApproved = true)
    check d.approvedIds == @["a3"]
    d.applyOutcome("a3", Receipt(outcome: uoDone))
    check d.recordLines == @[
      RecordLine(text: "Ran 1 UI action", role: "body", tag: AutoApprovedTag),
      RecordLine(text: "Showed the Variables panel", role: "body", level: 1)]

  test "several auto-approved actions list their outcomes":
    var d = newDecision(suggestion(showCalls, showVars), autoApproved = true)
    d.applyOutcome("a2", Receipt(outcome: uoDone))
    d.applyOutcome("a3", Receipt(outcome: uoDone))
    let lines = d.recordLines
    check lines[0] == RecordLine(text: "Ran 2 UI actions", role: "body",
                                 tag: AutoApprovedTag)
    check lines.len == 3
    check lines[2].level == 1

  test "a failed reply is said under the decision, which stands":
    var d = newDecision(suggestion(openTrace))
    check d.dismiss()
    d.applyReplyFailure("the server closed the connection")
    check d.phase == spDismissed
    check d.recordLines[^1] == RecordLine(
      text: "Could not tell the agent: the server closed the connection",
      role: "error", level: 1)

suite "auto-approval":
  test "an entry names the front-end and the action":
    let list = ["codetracer:show-panel", "webui:open-url"]
    check autoApproves(list, "show-panel")
    check not autoApproves(list, "open-url")   # another front-end's
    check autoApproves(list, "open-url", frontEnd = "webui")

  test "a suggestion splits into the auto-approved part and the rest":
    let (auto, asked) = splitAutoApproved(suggestion(openTrace, showVars),
                                          ["codetracer:show-panel"])
    check auto.actions == @[showVars]
    check asked.actions == @[openTrace]
    check auto.requestId == "req-1" and asked.reason == auto.reason

suite "answering Agent Harbor":
  test "decideSuggestion names the request, the decision and the approved actions":
    let a = decideSuggestion("s-upload", "req-1", "approve", @["a1", "a3"])
    check a.kind == oaDecideSuggestion
    check a.choices == @["a1", "a3"]
    check a.decision == "approve"
    check routeOf(a) == ("", "")    # proposed: Agent Harbor documents no route yet
    check targetOf(a) == "request::s-upload:req-1"
    check targetOf(decideSuggestion("s-upload", "req-2", "dismiss")) != targetOf(a)
