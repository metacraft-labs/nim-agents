## The Agent Harbor domain of nim-agents: the session directory and its
## policies, the activity digest, replaying a session to a moment of its
## history, and initiatives with their progress. Signal-free code, tested
## with plain values; no fake server or mock is involved -- every input is the
## JSON Agent Harbor sends, written out here.

import std/[json, strutils, unittest]
import nim_agents/agent_harbor/[fleet_records, session_directory, activity_digest,
                                session_replay, initiatives]

proc live(id: string; source = ""; status = fsRunning): FleetSession =
  FleetSession(id: id, status: status, rawStatus: $status,
               awaitingInput: source.len > 0, awaitingInputSource: source)

suite "effective status":
  test "every wait reads needs input under the WebUI's policy":
    check live("a", "claude-stop-hook").attentionOf(espNeedsInputWins) == saNeedsInput
    check live("a", "a:native-question:3").attentionOf(espNeedsInputWins) == saNeedsInput
    check live("a", "claude-stop-hook").statusLabelOf(espNeedsInputWins) == "needs input"
    # The same word the fleet records' own rule gives (INV-P2-13/14/19).
    check live("a", "claude-stop-hook").statusLabelOf(espNeedsInputWins) ==
      live("a", "claude-stop-hook").effectiveStatusLabel

  test "an ended turn reads idle when the policy keeps it apart":
    check live("a", "claude-stop-hook").attentionOf(espIdlePromptApart) == saIdle
    check live("a", "claude-stop-hook").statusLabelOf(espIdlePromptApart) == "idle"
    # A question is still a question under either policy.
    check live("a", "a:native-question:3").attentionOf(espIdlePromptApart) == saNeedsInput
    check live("a", "a:permission-request:1").inputWaitKind == iwPermission
    check live("a", "settle").statusLabelOf(espIdlePromptApart) == "needs input (estimated)"

  test "paused waits for a person; terminal states never wait":
    check live("a", status = fsPaused).attentionOf(espIdlePromptApart) == saNeedsInput
    var done = live("a", "claude-stop-hook", fsCompleted)
    check done.inputWaitKind == iwNone
    check done.attentionOf(espIdlePromptApart) == saEnded
    check live("a", status = fsCancelled).attentionOf == saFailed
    check live("a", status = fsQueued).attentionOf == saQueued
    check live("a").attentionOf == saRunning

suite "labels":
  test "a withheld prompt falls back to what a person calls the session":
    var session = FleetSession(id: "0123456789abcdef", promptWithheld: true)
    check session.titleOf == ("Session 01234567", lsId)
    session.workspaceName = "orbit-ws-2"
    check session.titleOf == ("orbit-ws-2", lsWorkspace)
    session.branch = "fix/step-count"
    check session.titleOf == ("fix/step-count", lsBranch)
    session.name = "propagator"
    check session.titleOf == ("propagator", lsName)
    session.prompt = "Fix the step counter\nand its tests"
    check session.titleOf == ("Fix the step counter", lsPrompt)
    # The sources are a policy: a front-end may prefer the branch.
    check session.titleOf([lsBranch, lsPrompt]) == ("fix/step-count", lsBranch)
    check session.titleOf([lsId]) == ("Session 01234567", lsId)

  test "front-end ids read as names, unknown ones as they are":
    check originLabel("cli") == "CLI"
    check originLabel("webui") == "WebUI"
    check originLabel("ah-tui") == "TUI"
    check originLabel("codetracer") == "CodeTracer"
    check originLabel("my-extension") == "my-extension"
    check originLabel("") == ""
    check originShortLabel("webui") == "Web"
    check originShortLabel("codetracer") == "CT"
    check originShortLabel("my-extension") == "my-ext"

  test "the proposed origin and plan fields decode from the wire":
    let s = fleetSessionFromJson(parseJson("""{"id":"s1","status":"running",
      "origin_front_end":"tui","plan":{"id":"p1","path":"milestones/P.milestones.org"}}"""))
    check s.originFrontEnd == "tui"
    check s.planId == "p1"
    check fleetSessionFromJson(parseJson("""{"id":"s2","plan":"p2"}""")).planId == "p2"
    check fleetSessionFromJson(parseJson("""{"id":"s3"}""")).planId == ""

suite "the session directory":
  test "a listing keeps known sessions in place and appends new ones by creation":
    var dir = initSessionDirectory()
    dir.replaceAll([FleetSession(id: "b", createdAtMs: 2), FleetSession(id: "a", createdAtMs: 1)])
    check dir.sessions[0].id == "a"
    check dir.sessions[1].id == "b"
    dir.replaceAll([FleetSession(id: "c", createdAtMs: 0), FleetSession(id: "b", createdAtMs: 2),
                    FleetSession(id: "a", createdAtMs: 1)])
    # `c` is the oldest, but tabs already shown do not move for it.
    check dir.sessions[0].id == "a"
    check dir.sessions[1].id == "b"
    check dir.sessions[2].id == "c"
    dir.replaceAll([FleetSession(id: "c")])
    check dir.len == 1
    check dir.find("a") == -1

  test "lifecycle frames add, update and remove sessions":
    var dir = initSessionDirectory()
    let frames = parseLifecycleSse(
      "event: lifecycle\ndata: {\"kind\":\"session_created\",\"sessionId\":\"s1\",\"status\":\"queued\",\"agent\":\"claude\"}\n\n" &
      "event: lifecycle\ndata: {\"kind\":\"session_status_changed\",\"sessionId\":\"s1\",\"status\":\"running\"}\n\n" &
      "event: lifecycle\ndata: {\"kind\":\"session_status_changed\",\"sessionId\":\"s1\",\"status\":\"running\"}\n\n" &
      "event: lifecycle\ndata: {\"kind\":\"session_completed\",\"sessionId\":\"s1\",\"status\":\"failed\",\"at\":\"2026-11-03T06:42:42Z\"}\n\n" &
      "event: caught_up\ndata: {}\n\n")
    check dir.applyFrame(frames[0])
    check dir.sessions[0].status == fsQueued
    check dir.applyFrame(frames[1])
    check dir.sessions[0].status == fsRunning
    check not dir.applyFrame(frames[2])   # nothing changed
    check dir.applyFrame(frames[3])
    check dir.sessions[0].status == fsFailed
    check dir.sessions[0].endedAtMs > 0
    check dir.applyFrame(frames[4])
    check dir.caughtUp
    check dir.applyFrame(LifecycleFrame(event: "lifecycle", kind: "session_removed",
                                        sessionId: "s1"))
    check dir.len == 0

  test "a resync frame marks the directory until the next listing":
    var dir = initSessionDirectory()
    check dir.applyFrame(LifecycleFrame(event: "resync"))
    check dir.resyncing
    dir.replaceAll([FleetSession(id: "x")])
    check not dir.resyncing

  test "attention order puts the sessions that need a person first":
    let sessions = [
      FleetSession(id: "ended", status: fsCompleted, updatedAtMs: 50),
      live("idle", "claude-stop-hook"),
      FleetSession(id: "run-old", status: fsRunning, updatedAtMs: 1),
      FleetSession(id: "run-new", status: fsRunning, updatedAtMs: 9),
      live("asks", "a:native-question:1")]
    var policy = defaultSessionPolicy()
    var ids: seq[string]
    for i in orderedIndexes(sessions, policy): ids.add sessions[i].id
    check ids == @["idle", "asks", "run-new", "run-old", "ended"] or
          ids == @["asks", "idle", "run-new", "run-old", "ended"]
    policy.status = espIdlePromptApart
    ids.setLen 0
    for i in orderedIndexes(sessions, policy): ids.add sessions[i].id
    check ids == @["asks", "idle", "run-new", "run-old", "ended"]
    # Launch order keeps the given order whatever the states.
    ids.setLen 0
    for i in orderedIndexes(sessions, tabStripSessionPolicy()): ids.add sessions[i].id
    check ids == @["ended", "idle", "run-old", "run-new", "asks"]

  test "a session can be moved, and only to a place that exists":
    var dir = initSessionDirectory()
    dir.replaceAll([FleetSession(id: "a", createdAtMs: 1), FleetSession(id: "b", createdAtMs: 2),
                    FleetSession(id: "c", createdAtMs: 3)])
    check dir.moveSession("c", 0)
    check dir.sessions[0].id == "c"
    check dir.find("a") == 1
    check not dir.moveSession("c", 0)
    check dir.moveSession("c", 99)
    check dir.sessions[^1].id == "c"
    check not dir.moveSession("nope", 0)

  test "grouping by plan keeps the plans' order and every session once":
    let sessions = [FleetSession(id: "1", planId: "p2"), FleetSession(id: "2"),
                    FleetSession(id: "3", planId: "p1"), FleetSession(id: "4", planId: "p9"),
                    FleetSession(id: "5", planId: "p2")]
    let groups = groupByPlan(sessions, [0, 1, 2, 3, 4], ["p1", "p2", "p3"])
    check groups.len == 5
    check groups[0].planId == "p1" and groups[0].indexes == @[2]
    check groups[1].planId == "p2" and groups[1].indexes == @[0, 4]
    check groups[2].planId == "p3" and groups[2].indexes.len == 0   # a plan with no session
    check groups[3].planId == "p9" and groups[3].indexes == @[3]    # a plan not named first
    check groups[4].planId == "" and groups[4].indexes == @[1]      # launched for none
    var total = 0
    for g in groups: total += g.indexes.len
    check total == sessions.len

suite "durations":
  test "a duration under a second is not shown":
    check durationLabel(1_000_000, 1_000_400) == ""
    check durationLabel(1_000_000, 1_001_000) == "1s"
    check durationLabel(1_000_000, 1_000_000 + 65 * 60_000) == "1h 05m"

suite "the activity digest":
  test "repeats collapse wherever they occur, counted":
    let a = FleetActivity(kind: fakResumed, text: "Resumed by human")
    let b = FleetActivity(kind: fakAwaitingInput, text: "Waiting for input (claude stop hook)")
    let digest = digestActivity([b, a, a, a, b], arNewest)
    check digest.len == 2
    check digest[0].lineText == "Waiting for input (claude stop hook) \xC3\x972"
    check digest[1].lineText == "Resumed by human \xC3\x973"

  test "the most informative recent event comes first":
    let events = [
      FleetActivity(kind: fakLog, level: "info", text: "assistant: wrote the migration", timestampMs: 1),
      FleetActivity(kind: fakResumed, text: "Resumed by human", timestampMs: 2),
      FleetActivity(kind: fakAwaitingInput, text: "Waiting for input (claude stop hook)", timestampMs: 3),
      FleetActivity(kind: fakStatus, text: "Status: running", timestampMs: 4)]
    let digest = digestActivity(events)
    check digest[0].text == "assistant: wrote the migration"
    check digest[0].informative
    check not digest[^1].informative
    # Recency alone would put the status line first.
    check digestActivity(events, arNewest)[0].text == "Status: running"

  test "status lines are left out where the row shows the status":
    let events = [FleetActivity(kind: fakStatus, text: "Status: running"),
                  FleetActivity(kind: fakStatus, text: "Status: failed"),
                  FleetActivity(kind: fakResumed, text: "Resumed by unknown")]
    # Repeating the shown status, or contradicting it with an older one.
    check digestActivity(events, currentStatus = "failed").len == 1
    check digestActivity(events, currentStatus = "failed")[0].text == "Resumed by unknown"
    check digestActivity(events).len == 3

  test "an error outranks everything; a scrubbed line says nothing":
    let digest = digestActivity([
      FleetActivity(kind: fakLog, level: "error", text: "Failed to start: auth"),
      FleetActivity(kind: fakQuestion, text: "Asked a single-choice question"),
      FleetActivity(kind: fakLog, level: "error", text: "[scrubbed: quoted prompt text]")])
    check digest.len == 2
    check digest[0].text == "Failed to start: auth"

suite "replaying a session to a moment":
  let history = parseJson("""{"events":[
    {"type":"status","status":"completed","timestamp":10000000},
    {"type":"log","level":"info","message":"assistant: Done.","timestamp":10000000},
    {"type":"tool_use","status":"started","tool_name":"runCmd","tool_args":{"command":"make test"},"timestamp":2000000},
    {"type":"log","level":"info","message":"agent question (Claude Code): tool=AskUserQuestion","timestamp":0},
    {"type":"user_input","content":"private words","timestamp":0},
    {"type":"status","status":"running","timestamp":0},
    {"type":"status","status":"queued","timestamp":0}]}""")
  let events = eventsOldestFirst(history)
  let listed = FleetSession(id: "s1", prompt: "Add authentication", status: fsCompleted)

  test "the events come oldest first, and the question is found":
    check events[0]{"status"}.getStr == "queued"
    check questionIndexes(events) == @[3]

  test "right after the question the session waits for its answer":
    let s = listed.sessionAt(events, 4, 1_000_000)
    check s.status == fsRunning
    check s.awaitingInput
    check s.inputWaitKind == iwQuestion
    # The logged question reads as a question (activityFromJson).
    check s.recent[^1].kind == fakQuestion
    check s.recent[^1].text.startsWith("Asked a question (")
    check s.prompt == "Add authentication"

  test "after the answer it runs, and at the end it is what was listed":
    let running = listed.sessionAt(events, 5, 1_000_000)
    check running.status == fsRunning
    check not running.awaitingInput
    check running.recent[^1].text == "Ran make test"
    check running.updatedAtMs == 1_000_000 + 2000
    let ended = listed.sessionAt(events, events.len, 1_000_000)
    check ended.status == fsCompleted
    check ended.endedAtMs == 1_000_000 + 10000
    check ended.recent.len == ReplayRecentLimit

  test "an instruction's own words are never echoed":
    check activityFromJson(events[2]).text == "Instruction sent"
    check "private" notin activityFromJson(events[2]).text

  test "an agent's logged question reads as a question, not a tool name":
    let asked = activityFromJson(%*{"type": "log", "level": "info",
      "message": "agent question (Claude Code): tool=AskUserQuestion"})
    check asked.kind == fakQuestion
    check asked.text == "Asked a question (Claude Code)"
    let other = activityFromJson(%*{"type": "log", "level": "info",
      "message": "agent question without an agent"})
    check other.kind == fakLog
    check other.text == "agent question without an agent"

const plan = """#+TITLE: Storage Layer Milestones

* Document
  :PROPERTIES:
  :current_milestone: SL-M2
  :status: in_progress
  :last_updated: 2026-01-14
  :executive_summary: The cache moves to the new store; the data model is done.
  :END:

* Introduction
** Notes: not a milestone
   :status: completed

* Milestones

** SL-M1: Data model
   :PROPERTIES:
   :status: completed
   :END:

*** Deliverables
    - [x] Schema written
    - [X] Migration written

*** Verification
    - test_name: test_schema
      status: passing
    - test_name: test_migration
      status: passing 2026-01-10 at abc123

** SL-M2: Cache on the store
   :PROPERTIES:
   :status: in_progress
   :END:

*** Deliverables
    - [x] Reads
    - [ ] Writes
    - [ ] Eviction

*** Verification
    - test_name: test_reads
      status: failing
    - test_name: test_writes
      status: pending

** SL-M3: Rollout
   :PROPERTIES:
   :status: blocked
   :END:

*** Deliverables
    - [ ] Flag flipped
"""

suite "initiatives":
  test "a plan's progress is what the server computes":
    let p = parseMilestoneFile("Storage.milestones.org", plan)
    check p.title == "Storage Layer Milestones"
    check p.currentMilestone == "SL-M2"
    # The server takes any `:status:` outside a milestone as the document's,
    # the last one winning: here the prose heading's under Introduction.
    check p.status == "completed"
    check p.lastUpdated == "2026-01-14"
    check p.milestones.len == 3    # `Notes:` is not under `* Milestones`
    check p.milestones[0].deliverables == DeliverableCounts(done: 2, total: 2)
    # Only the bare word counts, as the server counts it: the dated
    # `passing 2026-01-10 at abc123` is none of the three.
    check p.milestones[0].verifications == VerificationCounts(passing: 1)
    check p.milestones[1].deliverables == DeliverableCounts(done: 1, total: 3)
    check p.milestones[1].verifications == VerificationCounts(failing: 1, pending: 1)
    check p.milestones[2].status == "blocked"
    check p.summary.totalMilestones == 3
    check p.summary.completedMilestones == 1
    check p.summary.progressPercent == 33
    check p.summary.currentMilestoneTitle == "Cache on the store"
    check planExecutiveSummary(plan) == "The cache moves to the new store; the data model is done."

  test "milestone ids are told from prose headings":
    check isMilestoneId("M0")
    check isMilestoneId("CTF-P2")
    check isMilestoneId("F.13")
    check isMilestoneId("M17B")
    check not isMilestoneId("Notes")
    check not isMilestoneId("Step 1")
    check not isMilestoneId("lower-M1")

  test "counts by status and the groups in display order":
    let p = parseMilestoneFile("S", plan)
    let counts = statusCounts(p)
    check counts[mscCompleted] == 1
    check counts[mscInProgress] == 1
    check counts[mscBlocked] == 1
    let groups = milestonesByStatus(p)
    check groups.len == 3
    check groups[0].status == mscInProgress
    check groups[^1].status == mscCompleted
    check verificationTotals(p) == VerificationCounts(passing: 1, failing: 1, pending: 1)

  test "a progress event changes each count once":
    var p = parseMilestoneFile("S", plan)
    check p.applyMilestoneStatus("SL-M2", "completed")
    check p.summary.completedMilestones == 2
    check p.summary.progressPercent == 67
    check statusCounts(p)[mscInProgress] == 0
    check not p.applyMilestoneStatus("SL-M2", "completed")   # repeated
    check p.summary.completedMilestones == 2
    check not p.applyMilestoneStatus("SL-M9", "completed")   # unknown
    # The current milestone completed: the next one not completed is current.
    check p.currentMilestone == "SL-M3"
    check p.summary.currentMilestoneTitle == "Rollout"
    var q = parseMilestoneFile("S", plan)
    check q.applyMilestoneStatus("SL-M2", "completed", advanceCurrent = false)
    check q.currentMilestone == "SL-M2"

  test "an initiative survives the proposed wire shape":
    var initiative = Initiative(id: "storage", title: "Storage layer",
      repository: "orbit-labs/store", planPath: "Storage.milestones.org",
      manager: "sl-manager", executiveSummary: planExecutiveSummary(plan),
      sessionIds: @["s1", "s2"], progress: parseMilestoneFile("Storage.milestones.org", plan))
    let back = initiativeFromJson(initiative.toJson)
    check back == initiative
    let listed = initiativesFromJson(%*{"items": [initiative.toJson,
      {"id": "bare", "sessions": [{"id": "s9"}],
       "progress": {"title": "Bare Milestones", "milestones": []}}]})
    check listed.len == 2
    check listed[1].sessionIds == @["s9"]
    check listed[1].title == "Bare Milestones"
    check listed[1].progress.summary.totalMilestones == 0

suite "initiative state and the inbox":
  test "an initiative's state: needing a person outranks working":
    check initiativeStateOf([saRunning, saNeedsInput, saEnded], 0) == isNeedsInput
    check initiativeStateOf([saRunning, saEnded], 1) == isWorking
    check initiativeStateOf([saEnded, saIdle], 1) == isBlocked
    check initiativeStateOf([saEnded, saIdle], 0) == isIdle
    # Nothing running: idle while the plan has work left, ended once done.
    check initiativeStateOf([saEnded, saFailed], 0) == isIdle
    check initiativeStateOf([saEnded, saFailed], 0, planDone = true) == isEnded
    check initiativeStateOf(newSeq[SessionAttention](), 0) == isIdle
    check planDone(3, 3)
    check not planDone(2, 3)
    check not planDone(0, 0)

  test "Next walks the waiting sessions, blocked first, longest waiting first":
    var a = live("a", "a:native-question:1"); a.updatedAtMs = 30
    var b = live("b", "claude-stop-hook"); b.updatedAtMs = 10
    var c = live("c", "c:native-question:1"); c.updatedAtMs = 20
    let d = FleetSession(id: "d", status: fsRunning)
    let sessions = [a, b, c, d]
    let order = inboxOrder(sessions)
    check order == @[2, 0, 1]            # c, a (questions), then b (ended turn)
    check inboxStep(order, 2, 1) == 0
    check inboxStep(order, 1, 1) == 2    # wraps
    check inboxStep(order, 2, -1) == 1
    check inboxStep(order, 3, 1) == 2    # from a session not in the inbox
    check inboxStep(newSeq[int](), 0, 1) == -1

  test "input delivered: a waiting session runs again, once":
    var dir = initSessionDirectory()
    dir.replaceAll([live("w", "claude-stop-hook"), FleetSession(id: "r", status: fsRunning)])
    check dir.resumeSession("w")
    check dir.sessions[0].attentionOf(espIdlePromptApart) == saRunning
    check not dir.resumeSession("w")
    check not dir.resumeSession("r")
    check not dir.resumeSession("nope")
