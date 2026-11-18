## The inbox of nim-agents: the served inbox read in the server's order, the
## stream reducer that never re-sorts, the cursor rule Previous and Next
## follow, the chips, the kind words, the answer form's rules and the
## operator's actions. Every input is invented JSON in the served (or
## proposed) shape, written out here; no fake or mock is involved.

import std/[json, strutils, unittest]
import nim_agents/agent_harbor/[inbox, operator_actions, session_directory]

# Five items in the order a server would serve them. The order is the
# server's: a `low` item ahead of an `urgent` one is deliberate, so a reader
# that sorted by priority would be caught.
const Served = """{
  "items": [
    {"id": "s-low@1", "kind": "ended_turn", "position": 1,
     "session": {"id": "s-low", "title": "Tidy the step counter", "host": "orbit-ws-1",
                 "agent": "Claude", "status": "running",
                 "label": "Tidy the step counter (orbit-ws-1)"},
     "priority": "low", "effectivePriority": "normal",
     "boost": {"reason": "recent", "reasons": ["cache_warm", "recent"],
               "deadline": "2026-11-04T21:10:00Z"},
     "explanation": "Low priority, raised · stopped just now",
     "enteredAt": "2026-11-04T21:00:00Z",
     "cacheWarmth": {"state": "warm", "deadline": "2026-11-04T21:03:12Z",
                     "confidence": "exact"}},
    {"id": "s-urgent@2", "kind": "blocked_question", "position": 2,
     "session": {"id": "s-urgent", "title": "Telemetry retries", "host": "orbit-ws-2",
                 "agent": "Codex", "status": "running",
                 "handle": {"display": "orbit-ws-2:retries"},
                 "label": "orbit-ws-2:retries · Telemetry retries"},
     "priority": "urgent", "effectivePriority": "urgent",
     "explanation": "Urgent priority · cache cold", "question": "Which backoff?",
     "enteredAt": "2026-11-04T20:00:00Z",
     "cacheWarmth": {"state": "cold"}},
    {"id": "s-perm@3", "kind": "permission_gate", "position": 3, "server": "lab",
     "session": {"id": "s-perm", "title": "Route cache", "label": "Route cache (lab-1)"},
     "priority": "normal", "effectivePriority": "normal",
     "explanation": "Normal priority · waiting 2 hours",
     "cacheWarmth": {"state": "neutral"}},
    {"id": "s-new@4", "kind": "approval_request", "position": 4,
     "session": {"id": "s-new", "title": "Release notes", "label": "Release notes"},
     "priority": "high", "explanation": "High priority · waiting 5 minutes",
     "heldBy": "manager"},
    {"id": "s-fb@5", "kind": "async_feedback", "position": 5,
     "session": {"id": "s-fb", "title": "Docs pass"},
     "priority": "normal", "effectivePriority": "normal",
     "explanation": "Normal priority · agent still working"}
  ],
  "generatedAt": "2026-11-04T21:00:15Z",
  "nextChangeAt": "2026-11-04T21:03:40Z",
  "degraded": [{"server": "hub-2", "reason": "connection refused"}]
}"""

proc ids(snapshot: InboxSnapshot): seq[string] =
  for item in snapshot.items: result.add item.id

proc positions(snapshot: InboxSnapshot): seq[int] =
  for item in snapshot.items: result.add item.position

proc r(id: string; server = ""): InboxItemRef = InboxItemRef(server: server, id: id)

proc item(id: string; kind = ikEndedTurn; priority = ipNormal; position = 0): InboxItem =
  InboxItem(id: id, kind: kind, kindText: $kind, priority: priority,
            effectivePriority: priority, position: position,
            session: InboxSession(id: id.split('@')[0]))

let at = parseIsoMs("2026-11-04T21:00:00Z")

suite "the served inbox":
  let inboxNow = inboxFromJson(parseJson(Served))

  test "items in the order served, never re-sorted":
    check inboxNow.ids == @["s-low@1", "s-urgent@2", "s-perm@3", "s-new@4", "s-fb@5"]
    check inboxNow.positions == @[1, 2, 3, 4, 5]
    check inboxNow.items[0].priority == ipLow
    check inboxNow.items[1].priority == ipUrgent

  test "every field a row shows":
    let first = inboxNow.items[0]
    check first.kind == ikEndedTurn
    check first.session.label == "Tidy the step counter (orbit-ws-1)"
    check first.effectivePriority == ipNormal
    check first.boost.active
    check first.boost.reasons == @["cache_warm", "recent"]
    check first.boost.deadlineMs == parseIsoMs("2026-11-04T21:10:00Z")
    check first.explanation == "Low priority, raised · stopped just now"
    check first.enteredAtMs == at
    check first.warmth == CacheWarmth(state: wsWarm,
                                      deadlineMs: parseIsoMs("2026-11-04T21:03:12Z"),
                                      confidence: wcExact)
    check inboxNow.items[1].question == "Which backoff?"
    check inboxNow.items[1].session.handle == "orbit-ws-2:retries"
    check inboxNow.items[2].server == "lab"
    check inboxNow.items[2].refOf == r("s-perm@3", "lab")
    check inboxNow.generatedAtMs == parseIsoMs("2026-11-04T21:00:15Z")
    check inboxNow.nextChangeAtMs == parseIsoMs("2026-11-04T21:03:40Z")
    check inboxNow.degraded == @[DegradedServer(server: "hub-2", reason: "connection refused")]

  test "an unknown kind is kept in its place, with its name":
    let unknown = inboxNow.items[3]
    check unknown.id == "s-new@4"
    check unknown.kind == ikUnknown
    check unknown.kindText == "approval_request"
    check unknown.kindWord == "approval request"
    # A missing effective priority is the priority; a missing label the title.
    check unknown.effectivePriority == ipHigh
    check inboxNow.items[4].session.label == "Docs pass"

  test "an item whose agent died says who has it":
    check inboxNow.items[3].heldBy == ihManager
    check inboxNow.items[3].holderText == "with the Manager"
    check inboxNow.items[0].holderText == ""

  test "an empty or odd answer is an empty inbox":
    check inboxFromJson(parseJson("""{"items": []}""")).items.len == 0
    check inboxFromJson(newJNull()).items.len == 0
    check inboxFromJson(parseJson("""{"items": [1, "x"]}""")).items.len == 0

suite "the stream reducer keeps the order the events carry":
  test "an added item goes where its position puts it, or last":
    var s = InboxSnapshot(items: @[item("a", position = 1), item("b", position = 2)])
    check s.applyInboxEvent(InboxEvent(kind: ieAdded,
      item: item("c", ikBlockedQuestion, ipUrgent, position = 2)))
    check s.ids == @["a", "c", "b"]
    check s.positions == @[1, 2, 3]
    check s.applyInboxEvent(InboxEvent(kind: ieAdded, item: item("d", priority = ipUrgent)))
    check s.ids == @["a", "c", "b", "d"]

  test "an updated item stays where it is, whatever its new priority":
    var s = InboxSnapshot(items: @[item("a", priority = ipLow), item("b"), item("c")])
    check s.applyInboxEvent(InboxEvent(kind: ieUpdated,
      item: item("c", ikBlockedQuestion, ipUrgent)))
    check s.ids == @["a", "b", "c"]
    check s.items[2].priority == ipUrgent
    check not s.applyInboxEvent(InboxEvent(kind: ieUpdated,
      item: item("c", ikBlockedQuestion, ipUrgent, position = 3)))

  test "a resolved item leaves; the rest close up":
    var s = InboxSnapshot(items: @[item("a"), item("b"), item("c")])
    check s.applyInboxEvent(InboxEvent(kind: ieResolved, target: r("b")))
    check s.ids == @["a", "c"]
    check s.positions == @[1, 2]
    check not s.applyInboxEvent(InboxEvent(kind: ieResolved, target: r("zz")))

  test "a carried order is taken exactly, priorities notwithstanding":
    var s = InboxSnapshot(items: @[item("a", priority = ipUrgent), item("b", priority = ipLow),
                                   item("c", priority = ipHigh)])
    check s.applyInboxEvent(InboxEvent(kind: ieReordered, hasOrder: true,
                                       order: @[r("b"), r("c"), r("a")]))
    check s.ids == @["b", "c", "a"]
    # A ref the inbox does not hold is skipped; an item the order leaves out
    # keeps its place after the ordered ones.
    check s.applyInboxEvent(InboxEvent(kind: ieReordered, hasOrder: true,
                                       order: @[r("a"), r("ghost")]))
    check s.ids == @["a", "b", "c"]
    # An event's own order wins over the added item's position.
    check s.applyInboxEvent(InboxEvent(kind: ieAdded, item: item("d", position = 1),
                                       hasOrder: true,
                                       order: @[r("a"), r("b"), r("c"), r("d")]))
    check s.ids == @["a", "b", "c", "d"]

  test "fleet items are told apart by their server":
    var s = InboxSnapshot(items: @[InboxItem(id: "x", server: "lab"), InboxItem(id: "x")])
    check s.applyInboxEvent(InboxEvent(kind: ieResolved, target: r("x", "lab")))
    check s.items.len == 1
    check s.items[0].server == ""

  test "stream events read from the wire":
    let added = inboxEventFromJson(parseJson("""{"type": "item.added",
      "item": {"id": "q@1", "kind": "login_request", "position": 1},
      "order": ["q@1", {"server": "lab", "id": "s-perm@3"}]}"""))
    check added.kind == ieAdded
    check added.item.kind == ikLoginRequest
    check added.hasOrder
    check added.order == @[r("q@1"), r("s-perm@3", "lab")]
    let resolved = inboxEventFromJson(parseJson("""{"type": "item.resolved", "id": "q@1"}"""))
    check resolved.kind == ieResolved
    check resolved.target == r("q@1")
    check not resolved.hasOrder

suite "the cursor: Next to the top, Previous along the visited items":
  test "Next goes to the top of the order, excluding the item on screen":
    var c: InboxCursor
    let order = @[r("a"), r("b"), r("c")]
    check cursorNext(order, c) == (true, r("a"))
    check cursorNext(order, c) == (true, r("b"))
    # The order is recomputed: `a` is on top again and is offered again.
    check cursorNext(@[r("a"), r("c"), r("b")], c) == (true, r("a"))
    check c.visited == @[r("a"), r("b")]

  test "Next at the last item goes to the top, not around the end":
    var c = InboxCursor(current: r("c"))
    check cursorNext(@[r("a"), r("b"), r("c")], c) == (true, r("a"))

  test "Previous walks the visited items, not the order's neighbour":
    var c: InboxCursor
    check cursorNext(@[r("a"), r("b"), r("c")], c).item == r("a")
    check cursorNext(@[r("c"), r("b"), r("a")], c).item == r("c")
    check cursorNext(@[r("b"), r("c"), r("a")], c).item == r("b")
    # In the order `b, c, a` the neighbour before `b` is none and after it
    # `c`; Previous returns to `c`, then `a`, the items visited.
    check c.canPrev
    check cursorPrev(c) == (true, r("c"))
    check cursorPrev(c) == (true, r("a"))
    check not c.canPrev
    check cursorPrev(c) == (false, r("a"))

  test "an item visited and answered since is still where Previous goes":
    var c: InboxCursor
    discard cursorNext(@[r("a"), r("b")], c)
    discard cursorNext(@[r("b")], c)      # `a` was answered
    check cursorPrev(c).item == r("a")

  test "nothing to move to":
    var empty: InboxCursor
    check cursorNext(newSeq[InboxItemRef](), empty) == (false, InboxItemRef())
    check not empty.canPrev
    var only = InboxCursor(current: r("a"))
    check cursorNext(@[r("a")], only) == (false, r("a"))
    check only.visited.len == 0

suite "chips and counts":
  let inboxNow = inboxFromJson(parseJson(Served))

  test "the warmth chip counts down on the reader's clock":
    let w = inboxNow.items[0].warmth
    check warmthChip(w, at) == "warm 3:12"
    check warmthChip(w, at + 60_000) == "warm 2:12"
    check warmthChip(w, at + 500_000) == "warm 0:00"
    check warmthChip(CacheWarmth(state: wsWarm, confidence: wcEstimated,
                                 deadlineMs: at + 3_723_000), at) == "warm 1:02:03"
    check warmthChip(CacheWarmth(state: wsWarm, confidence: wcLearned,
                                 deadlineMs: at + 60_000), at) == "likely warm"
    check warmthChip(CacheWarmth(state: wsWarm), at) == "warm"
    check warmthChip(CacheWarmth(state: wsExpiring, deadlineMs: at + 30_000), at) == "expiring"
    check warmthChip(CacheWarmth(state: wsCold), at) == "cold"
    check warmthChip(CacheWarmth(state: wsNeutral), at) == ""
    check warmthChip(CacheWarmth(state: wsUnknown), at) == ""

  test "the priority chip":
    check inboxNow.items[0].priorityChip == "normal, raised"
    check inboxNow.items[1].priorityChip == "urgent"
    check inboxNow.items[2].priorityChip == ""
    check item("x", priority = ipLow).priorityChip == "low"

  test "the control's count, its title, a session's pending mark, the position":
    check countText(3) == "3 waiting"
    check countText(0) == ""
    check controlTitle(3) == "3 tasks need input"
    check controlTitle(1) == "1 task needs input"
    check controlTitle(0) == "No input required"
    check pendingCountText(0) == ""
    check pendingCountText(1) == "Needs Follow-up"
    check pendingCountText(4) == "4 pending"
    check inboxNow.positionText(r("s-perm@3", "lab")) == "3 of 5"
    check inboxNow.positionText(r("s-perm@3")) == "5 waiting"
    check InboxSnapshot().positionText(r("a")) == ""
    var blocked = 0
    for it in inboxNow.items:
      if it.isBlocked: inc blocked
    check blocked == 4

suite "one vocabulary":
  test "each kind's words, the same as a waiting session's tab says":
    check item("a", ikBlockedQuestion).kindWord == "needs your answer"
    check item("a", ikEndedTurn).kindWord == "waiting for your next instruction"
    check item("a", ikPermissionGate).kindWord == "asks for permission"
    check item("a", ikLoginRequest).kindWord == "asks you to sign in"
    check item("a", ikAsyncFeedback).kindWord == "asks for feedback"
    proc waiting(source: string): FleetSession =
      FleetSession(id: "s", status: fsRunning, rawStatus: "running",
                   awaitingInput: true, awaitingInputSource: source)
    check waiting("s:native-question:1").waitKindWord == item("a", ikBlockedQuestion).kindWord
    check waiting("claude-stop-hook").waitKindWord == item("a", ikEndedTurn).kindWord
    check waiting("s:permission-request:1").waitKindWord == item("a", ikPermissionGate).kindWord
    check waiting("s:login-request:1").waitKindWord == item("a", ikLoginRequest).kindWord
    check waiting("settle").waitKindWord == ""
    check FleetSession(id: "s", status: fsRunning).waitKindWord == ""

suite "an item's page":
  let detail = inboxItemDetailFromJson(parseJson("""{
    "itemId": "s-urgent@2", "sessionId": "s-urgent", "kind": "blocked_question",
    "blocked": true, "requestId": "q-7", "prompt": "Which backoff?",
    "form": "single_choice",
    "options": [{"id": "full", "label": "Full jitter"}, "none"],
    "draft": {"text": "", "choices": ["full"], "rationale": "Matches the client.",
              "confidence": "high", "drafter": "orbit-manager"},
    "familiar": false, "executiveSummary": "Telemetry retries, milestone 2 of 3."}"""))

  test "a question's form, options and draft":
    check detail.blocked
    check detail.bannerText == "Agent has stopped and is waiting for your answer"
    check InboxItemDetail().bannerText == "Agent is waiting for an answer"
    check detail.form == qfSingle
    check detail.options == @[AnswerOption(id: "full", label: "Full jitter"),
                              AnswerOption(id: "none", label: "none")]
    check detail.draft.present
    check detail.draft.choices == @["full"]
    check detail.draft.drafter == "orbit-manager"
    check not detail.familiar
    check detail.executiveSummary == "Telemetry retries, milestone 2 of 3."

  test "permission options, approvals and a login request":
    let d = inboxItemDetailFromJson(parseJson("""{"kind": "permission_gate",
      "permissionOptions": [{"id": "o1", "kind": "allow_once"},
                            {"id": "o2", "kind": "reject_always", "label": "Never"}],
      "approvals": [{"requestId": "sudo-1", "command": "systemctl restart orbit",
                     "reason": "apply the new unit"},
                    {"requestId": "domain-1", "scope": "network",
                     "domain": "pypi.org", "reason": "install a dependency"}],
      "login": {"provider": "GitHub", "prompt": "Sign in to push", "state": "completed"}}"""))
    check d.permissionOptions[0].label == "Allow once"
    check d.permissionOptions[1].label == "Never"
    check permissionLabel("allow_always") == "Allow always"
    check permissionLabel("reject_once") == "Reject once"
    check d.approvals[0].scope == asSudo
    check d.approvals[0].approvalSummary == "systemctl restart orbit in order to: apply the new unit"
    check d.approvals[1].approvalSummary == "pypi.org in order to: install a dependency"
    check d.login.provider == "GitHub"
    check d.login.mode == lmLocalDesktop
    check d.login.state == lsCompleted

suite "the answer form's rules":
  test "free form and an ended turn need text":
    let q = InboxItemDetail(kind: ikBlockedQuestion, form: qfFreeForm)
    check validateAnswer(q, Answer(text: "   "), at) == EmptyResponseText
    check validateAnswer(q, Answer(text: "Full jitter."), at) == ""
    let turn = InboxItemDetail(kind: ikEndedTurn)
    check validateAnswer(turn, Answer(), at) == "Response cannot be empty"
    check validateAnswer(turn, Answer(text: "Ship it."), at) == ""

  test "choices: at least one, only one for a single choice, only known ones":
    let single = InboxItemDetail(kind: ikBlockedQuestion, form: qfSingle,
      options: @[AnswerOption(id: "a"), AnswerOption(id: "b")])
    check validateAnswer(single, Answer(), at) == "Please select at least one option"
    check validateAnswer(single, Answer(choices: @["a", "b"]), at) == SelectOneText
    check validateAnswer(single, Answer(choices: @["z"]), at) == "Unknown option: z"
    check validateAnswer(single, Answer(choices: @["b"]), at) == ""
    var multi = single
    multi.form = qfMulti
    check validateAnswer(multi, Answer(choices: @["a", "b"]), at) == ""
    let noOptions = InboxItemDetail(kind: ikBlockedQuestion, form: qfMulti)
    check validateAnswer(noOptions, Answer(choices: @["a"]), at) == NoOptionsText
    check NoOptionsText == "No options were provided for this question."

  test "a confirmation needs a decision":
    let c = InboxItemDetail(kind: ikBlockedQuestion, form: qfConfirmation)
    check validateAnswer(c, Answer(), at) == DecideText
    check validateAnswer(c, Answer(decision: "reject"), at) == ""

  test "a feedback request: its type's rules, its limits, its expiry":
    var fb = InboxItemDetail(kind: ikAsyncFeedback, feedback: FeedbackRequest(
      feedbackType: ftQuestion, minLength: 5, maxLength: 10, expiresAtMs: at + 1000))
    check validateAnswer(fb, Answer(text: ""), at) == "Response cannot be empty"
    check validateAnswer(fb, Answer(text: "abc"), at) == "Response must be at least 5 characters"
    check validateAnswer(fb, Answer(text: "abcdefghijk"), at) ==
      "Response must be at most 10 characters"
    check validateAnswer(fb, Answer(text: "abcdef"), at) == ""
    check validateAnswer(fb, Answer(text: "abcdef"), at + 1000) == ExpiredText
    fb.feedback.feedbackType = ftOptions
    fb.feedback.options = @[AnswerOption(id: "x")]
    check validateAnswer(fb, Answer(), at) == SelectOptionText
    check validateAnswer(fb, Answer(choices: @["x"]), at) == ""
    fb.feedback.feedbackType = ftInformation
    check validateAnswer(fb, Answer(), at) == ""
    fb.feedback.feedbackType = ftConfirmation
    check validateAnswer(fb, Answer(), at) == DecideText

  test "a permission or approval is a button":
    check validateAnswer(InboxItemDetail(kind: ikPermissionGate), Answer(), at) == ""

suite "the operator's actions":
  test "a password is never printed":
    let password = "hunter2-orbit"
    var a = decideApproval("s-1", "sudo-1", adApprove, password = password, itemId = "s-1@9")
    let text = $a
    check password notin text
    check "secret supplied" in text
    check text.startsWith("decide-approval ")
    check $a.password == "[secret]"
    check a.password.reveal == password
    a.clearSecrets()
    check not a.password.isSet
    check "secret supplied" notin $a
    check "secret" notin $decideApproval("s-1", "sudo-1", adDeny)

  test "each action's route, where one is served":
    check answerQuestion("s-1", "q-7", choices = @["full"]).routeOf ==
      ("POST", "/api/v1/sessions/s-1/feedback/q-7/respond")
    check sendInstruction("s-1", "Ship it.").routeOf == ("POST", "/api/v1/sessions/s-1/prompt")
    check decideApproval("s-1", "sudo-1", adApproveForSession).routeOf ==
      ("POST", "/api/v1/sessions/s-1/sudo-approvals/sudo-1/decision")
    check decideApproval("s-1", "net-4", adDeny, asNetwork).routeOf ==
      ("POST", "/api/v1/sessions/s-1/domain-approvals/net-4/decision")
    # The approval's scope picks the route, never the shape of its id.
    check decideApproval("s-1", "domain-5", adDeny).routeOf ==
      ("POST", "/api/v1/sessions/s-1/sudo-approvals/domain-5/decision")
    check respondFeedback("t-1", "fb-2", text = "ok").routeOf ==
      ("POST", "/api/v1/tasks/t-1/feedback/fb-2/respond")
    check setPriority("s-1", "high").routeOf == ("PATCH", "/api/v1/sessions/s-1")
    check markViewing("s-1").routeOf == ("PUT", "/api/v1/sessions/s-1/viewing")
    check ViewingHeartbeatMs == 20_000
    check cancelLogin("s-1", "l-1").routeOf == ("", "")
    check revertSpecChange("t-1", "ORB-M1", "specs/A.md").routeOf == ("", "")

  test "one target per item, per spec card, per session's priority":
    check answerQuestion("s-1", "q-7", itemId = "s-1@9").targetOf ==
      sendInstruction("s-1", "x", itemId = "s-1@9").targetOf
    check answerQuestion("s-1", "q-7", itemId = "s-1@9", server = "lab").targetOf !=
      answerQuestion("s-1", "q-7", itemId = "s-1@9").targetOf
    check approveSpecChange("t-1", "ORB-M1", "specs/A.md", "fb-1").targetOf ==
      revertSpecChange("t-1", "ORB-M1", "specs/A.md").targetOf
    check applyStaged("t-1", "specs/A.md").targetOf != applyStaged("t-1", "specs/B.md").targetOf
    check setPriority("s-1", "low").targetOf != markViewing("s-1").targetOf

  test "the record line names the fields":
    check $answerQuestion("s-1", "q-7", text = "Full \"jitter\"") ==
      "answer-question session=s-1 request=q-7 text=\"Full \\\"jitter\\\"\""
    check $setPriority("s-1", "high") == "set-priority session=s-1 priority=high"
