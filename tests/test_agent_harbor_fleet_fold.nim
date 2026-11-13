## The fleet fold of nim-agents (`agent_harbor/fleet_fold`): a fleet list that
## follows lifecycle frames, listing entries and session events after its
## first listing. Signal-free code, tested with plain values; no fake server
## or mock is involved -- every input is a record or JSON event of the shapes
## Agent Harbor sends, written out here.
##
## The run below is invented. Its oracle is independent of the fold: the fleet
## a listing would show at a moment is rebuilt from scratch, each session
## replayed from its start to that moment by `replayedFromScratch`, a replay
## written out in this file that shares no step with the fold (the fold and
## `sessionAt` both repeat `foldEvent`, so a defect in that step would pass a
## comparison of the one with the other). The fold only ever sees the frames
## one at a time.

import std/[algorithm, json, strutils, tables, unittest]
import nim_agents/agent_harbor/[fleet_fold, session_replay]

# ---------------------------------------------------------------------------
# An invented run, and the listing it gives at any moment
# ---------------------------------------------------------------------------

type
  RunSession = object
    entry: FleetSession      ## what the listing says besides its state
    startMs: int64
    removedAtMs: int64       ## 0: never removed
    history: seq[JsonNode]   ## oldest first; timestamps in µs since start

  Run = object
    firstMs: int64           ## the first listing's moment
    sessions: seq[RunSession]

const T0 = 1_800_000_000_000'i64

proc ev(sec: int; body: JsonNode): JsonNode =
  result = body
  result["timestamp"] = %(sec * 1_000_000)

proc status(sec: int; s: string): JsonNode = ev(sec, %*{"type": "status", "status": s})
proc tool(sec: int; cmd: string): JsonNode =
  ev(sec, %*{"type": "tool_use", "status": "started", "tool_name": "runCmd",
             "tool_args": {"command": cmd}})
proc said(sec: int; text: string; level = "info"): JsonNode =
  ev(sec, %*{"type": "log", "level": level, "message": text})
proc asked(sec: int): JsonNode =
  ev(sec, %*{"type": "agent_question", "kind": "single_choice", "prompt": "invented"})
proc answered(sec: int): JsonNode = ev(sec, %*{"type": "user_input", "content": "invented"})

proc entry(id, prompt: string; plan = ""): FleetSession =
  FleetSession(id: id, prompt: prompt, agentSoftware: "Claude",
               agentVersion: "2.1.0", agentCount: 1, planId: plan,
               originFrontEnd: "cli")

proc inventedRun(): Run =
  ## Four sessions: two running when the first listing is taken (one later
  ## asks, is answered and completes; one is removed), one that starts during
  ## the run and fails, and one that was already ended.
  result.firstMs = T0
  result.sessions = @[
    RunSession(entry: entry("a1", "Retry uploads with backoff", "plan-1"),
               startMs: T0 - 120_000, history: @[
      status(0, "queued"), status(1, "running"), tool(30, "just test"),
      said(130, "assistant: The retry test passes."), asked(150),
      answered(170), tool(175, "just lint"), status(200, "completed")]),
    RunSession(entry: entry("b2", "Port the cache to the new layer", "plan-1"),
               startMs: T0 - 300_000, removedAtMs: T0 + 90_000, history: @[
      status(0, "queued"), status(2, "running"), tool(60, "just bench"),
      said(320, "assistant: Benchmarking again.")]),
    RunSession(entry: entry("c3", "Split the settings page"),
               startMs: T0 + 40_000, history: @[
      status(1, "running"), tool(5, "just build"),
      said(20, "error: the build failed", "error"), status(25, "failed")]),
    RunSession(entry: entry("d4", "Update the headers", "plan-2"),
               startMs: T0 - 900_000, history: @[
      status(0, "running"), said(100, "assistant: Done."),
      status(101, "completed")])]

proc timeOf(s: RunSession; event: JsonNode): int64 =
  s.startMs + event["timestamp"].getBiggestInt div 1000

proc replayedFromScratch(session: FleetSession; events: openArray[JsonNode];
                         count: int; startMs: int64): FleetSession =
  ## The session after its first `count` events, derived from the whole
  ## prefix at once rather than event by event: the status is the last
  ## `status` event's, the session waits on a question when it is live and
  ## its last event is the agent asking, it ended at its last update when it
  ## is no longer live, and it carries its last three events.
  result = session
  let n = max(0, min(count, events.len))
  result.rawStatus = "queued"
  result.awaitingInput = false
  result.awaitingInputSource = ""
  result.endedAtMs = 0
  result.recent = @[]
  result.startedAtMs = startMs
  result.createdAtMs = startMs
  result.updatedAtMs = startMs
  for i in 0 ..< n:
    let at = startMs + events[i]{"timestamp"}.getBiggestInt div 1000
    result.updatedAtMs = max(result.updatedAtMs, at)
    if events[i]{"type"}.getStr == "status":
      result.rawStatus = events[i]{"status"}.getStr
  result.status = parseFleetStatus(result.rawStatus)
  if not result.status.isActive:
    result.endedAtMs = result.updatedAtMs
  elif n > 0:
    let last = events[n - 1]
    let kind = last{"type"}.getStr
    if kind in ["agent_question", "session_awaiting_input"] or
        (kind == "log" and last{"message"}.getStr.startsWith("agent question")):
      result.awaitingInput = true
      result.awaitingInputSource = result.id & ":native-question:" & $n
  for i in max(0, n - 3) ..< n:
    var line = activityFromJson(events[i])
    line.timestampMs = startMs + events[i]{"timestamp"}.getBiggestInt div 1000
    result.recent.add line

proc listedAt(run: Run; t: int64): FleetSnapshot =
  ## The oracle: the listing a server would give at `t`, every session
  ## replayed from its start (`replayedFromScratch`), in start order.
  result = FleetSnapshot(capturedAtMs: t, sourceLabel: "invented run")
  for s in run.sessions:
    if s.startMs > t or (s.removedAtMs > 0 and s.removedAtMs <= t): continue
    var count = 0
    for event in s.history:
      if s.timeOf(event) <= t: inc count
    result.sessions.add s.entry.replayedFromScratch(s.history, count, s.startMs)
  result.total = result.sessions.len

proc framesOf(run: Run): seq[FleetFrame] =
  ## What a live feed delivers after the first listing, in time order: a new
  ## session's `session_created` and its listing entry, every event, a
  ## lifecycle frame beside every status event (the feed mirrors them), and
  ## removals.
  var timed: seq[(int64, int, FleetFrame)]
  proc add(t: int64; frame: FleetFrame) =
    var stamped = frame
    stamped.atMs = t
    timed.add (t, timed.len, stamped)
  for s in run.sessions:
    let id = s.entry.id
    if s.startMs > run.firstMs:
      add(s.startMs, lifecycleFrame(LifecycleFrame(event: "lifecycle",
        kind: "session_created", sessionId: id, status: "queued",
        agent: s.entry.agentSoftware, atMs: s.startMs)))
      add(s.startMs, sessionFrame(s.entry.sessionAt(s.history, 0, s.startMs)))
    for i, event in s.history:
      let t = s.timeOf(event)
      if t <= run.firstMs: continue
      add(t, eventFrame(id, event, i + 1))
      if event["type"].getStr == "status":
        let st = event["status"].getStr
        add(t, lifecycleFrame(LifecycleFrame(event: "lifecycle",
          kind: (if parseFleetStatus(st).isActive: "session_status_changed"
                 else: "session_completed"),
          sessionId: id, status: st, atMs: t)))
    if s.removedAtMs > run.firstMs:
      add(s.removedAtMs, lifecycleFrame(LifecycleFrame(event: "lifecycle",
        kind: "session_removed", sessionId: id, atMs: s.removedAtMs)))
  timed.sort proc(a, b: (int64, int, FleetFrame)): int =
    cmp((a[0], a[1]), (b[0], b[1]))
  for entry in timed: result.add entry[2]

proc momentOf(frame: FleetFrame): int64 = frame.atMs

# ---------------------------------------------------------------------------
# What a fleet list shows, compared
# ---------------------------------------------------------------------------

proc byId(sessions: openArray[FleetSession]): Table[string, FleetSession] =
  for s in sessions: result[s.id] = s

proc groupsOf(sessions: openArray[FleetSession]): string =
  ## The sessions by plan, attention first within each: the fleet's groups.
  let order = orderedIndexes(sessions, defaultSessionPolicy())
  for g in groupByPlan(sessions, order, ["plan-1", "plan-2"]):
    var ids: seq[string]
    for i in g.indexes: ids.add sessions[i].id
    result.add g.planId & ":" & ids.join(",") & " "

proc differences(fold: FleetFold; listed: FleetSnapshot): seq[string] =
  ## Everything a fleet list shows that differs between the fold and the
  ## listing: the clock, the total, each session, its digest, the counts
  ## and the groups.
  if fold.capturedAtMs != listed.capturedAtMs:
    result.add "clock " & $fold.capturedAtMs & " != " & $listed.capturedAtMs
  if fold.total != listed.total:
    result.add "total " & $fold.total & " != " & $listed.total
  let held = fold.sessions.byId
  let want = listed.sessions.byId
  for id, s in want:
    if id notin held: result.add "missing " & id
    elif $held[id] != $s:
      result.add "session " & id & ": " & $held[id] & " != " & $s
    elif fold.digestOf(id) != sessionDigest(s):
      result.add "digest " & id & ": " & $fold.digestOf(id) & " != " &
        $sessionDigest(s)
  for id in held.keys:
    if id notin want: result.add "extra " & id
  if fold.counts != categoryCounts(listed.sessions):
    result.add "counts " & $fold.counts & " != " & $categoryCounts(listed.sessions)
  if groupsOf(fold.sessions) != groupsOf(listed.sessions):
    result.add "groups " & groupsOf(fold.sessions) & " != " &
      groupsOf(listed.sessions)

proc foldRun(run: Run): seq[string] =
  ## Folds the run's frames from its first listing; after each frame that
  ## completes a moment (the next frame is later), compares the fold with the
  ## listing taken then. Returns the failures, each naming its frame.
  var fold = initFleetFold(run.listedAt(run.firstMs))
  for d in fold.differences(run.listedAt(run.firstMs)):
    result.add "the first listing: " & d
  let frames = run.framesOf
  for i, frame in frames:
    let outcome = fold.apply(frame)
    if outcome notin {foApplied, foUnchanged}:
      result.add "frame " & $i & " (" & $frame & ") was " & $outcome
    if i < frames.high and frames[i + 1].momentOf == frame.momentOf: continue
    for d in fold.differences(run.listedAt(frame.momentOf)):
      result.add "after frame " & $i & " (" & $frame & "): " & d

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "the fleet fold":
  test "test_ctf_p1c_fleet_folds_lifecycle_frames":
    # Folding the run from its first listing gives, at every moment, the
    # sessions, digests, counts, groups, total and clock of the listing taken
    # at that moment.
    let run = inventedRun()
    let frames = run.framesOf
    check frames.len == 16
    let failures = foldRun(run)
    for f in failures: checkpoint f
    check failures.len == 0

  test "the run reaches every state the fold must follow":
    # The positive control for the test above: its run does start, ask,
    # answer, end, fail and remove sessions, so a fold that missed any of
    # them would be compared against a listing that shows it.
    let run = inventedRun()
    var fold = initFleetFold(run.listedAt(run.firstMs))
    var seen: set[FleetCategory]
    var asked, removed, created = false
    for frame in run.framesOf:
      discard fold.apply(frame)
      for s in fold.sessions: seen.incl s.category
      if frame.kind == ffLifecycle and frame.lifecycle.kind == "session_removed":
        removed = true
      if frame.kind == ffLifecycle and frame.lifecycle.kind == "session_created":
        created = true
      if fold.counts[fcNeedsInput] > 0: asked = true
    check seen == {fcNeedsInput, fcRunning, fcQueued, fcFailed, fcEnded}
    check asked and removed and created
    check fold.len == 3
    check fold.total == 3

  test "one listing folded is the listing, in its order":
    let listed = inventedRun().listedAt(T0)
    let fold = initFleetFold(listed)
    check fold.snapshot == listed
    check fold.differences(listed).len == 0
    check initFleetFold().len == 0

  test "an appended event recomputes the session's digest and its category":
    var fold = initFleetFold(inventedRun().listedAt(T0))
    let before = fold.digestOf("a1")
    check fold.counts[fcNeedsInput] == 0
    check fold.apply(eventFrame("a1", asked(150), 5)) == foApplied
    check fold.digestOf("a1") != before
    check fold.digestOf("a1")[0].kind == fakQuestion
    check fold.counts[fcNeedsInput] == 1
    let a1 = fold.sessions[fold.find("a1")]
    check a1.awaitingInput
    check a1.awaitingInputSource == "a1:native-question:5"
    check fold.capturedAtMs == T0 - 120_000 + 150_000

  test "the status is the feed's: a status event is activity only":
    var fold = initFleetFold(inventedRun().listedAt(T0))
    check fold.apply(eventFrame("a1", status(200, "completed"), 5)) == foApplied
    check fold.sessions[fold.find("a1")].status == fsRunning
    check fold.sessions[fold.find("a1")].recent[^1].kind == fakStatus
    check fold.applyFrame(LifecycleFrame(event: "lifecycle",
      kind: "session_completed", sessionId: "a1", status: "completed",
      atMs: T0 + 80_000)) == foApplied
    let a1 = fold.sessions[fold.find("a1")]
    check a1.status == fsCompleted
    check a1.endedAtMs == T0 + 80_000
    check fold.counts[fcEnded] == 2

  test "a new session arrives as a stub and its listing entry fills it":
    var fold = initFleetFold(inventedRun().listedAt(T0))
    check fold.applyFrame(LifecycleFrame(event: "lifecycle",
      kind: "session_created", sessionId: "e5", status: "queued",
      agent: "Codex", atMs: T0 + 5_000)) == foApplied
    check fold.total == 4
    check fold.sessions[fold.find("e5")].prompt == ""
    var listed = entry("e5", "Draft the release notes")
    listed.rawStatus = "queued"
    listed.status = fsQueued
    listed.createdAtMs = T0 + 5_000
    listed.updatedAtMs = T0 + 5_000
    check fold.apply(sessionFrame(listed)) == foApplied
    check fold.total == 4
    check fold.sessions[fold.find("e5")].prompt == "Draft the release notes"
    check fold.counts[fcQueued] == 1

  test "a removed session leaves the counts, the total and the digests":
    var fold = initFleetFold(inventedRun().listedAt(T0))
    check fold.applyFrame(LifecycleFrame(event: "lifecycle",
      kind: "session_removed", sessionId: "b2", atMs: T0 + 1)) == foApplied
    check fold.find("b2") < 0
    check fold.total == 2
    check fold.digestOf("b2").len == 0
    check fold.counts[fcRunning] == 1

  test "frames about a session the fold lacks are reported, not guessed":
    var fold = initFleetFold(inventedRun().listedAt(T0))
    let revision = fold.revision
    check fold.apply(eventFrame("zz", tool(1, "x"), 1)) == foUnknownSession
    check fold.applyFrame(LifecycleFrame(event: "lifecycle",
      kind: "session_removed", sessionId: "zz")) == foUnknownSession
    check fold.revision == revision
    check fold.len == 3

  test "malformed frames are reported and change nothing":
    var fold = initFleetFold(inventedRun().listedAt(T0))
    let before = fold.snapshot
    check fold.applyFrame(LifecycleFrame(event: "lifecycle",
      kind: "session_status_changed", status: "running")) == foMalformed
    check fold.applyFrame(LifecycleFrame(event: "lifecycle",
      kind: "session_teleported", sessionId: "a1")) == foMalformed
    check fold.apply(eventFrame("a1", nil, 5)) == foMalformed
    check fold.apply(eventFrame("a1", %*["not", "an", "object"], 5)) == foMalformed
    check fold.apply(eventFrame("", tool(1, "x"), 1)) == foMalformed
    check fold.apply(sessionFrame(FleetSession())) == foMalformed
    check fold.snapshot == before

  test "a frame older than what the fold holds is stale and ignored":
    var fold = initFleetFold(inventedRun().listedAt(T0))
    check fold.apply(eventFrame("a1", said(130, "first"), 4)) == foApplied
    check fold.apply(eventFrame("a1", asked(150), 5)) == foApplied
    let held = fold.snapshot
    # The same event again, and one from before it, arriving late.
    check fold.apply(eventFrame("a1", asked(150), 5)) == foStale
    check fold.apply(eventFrame("a1", said(130, "first"), 4)) == foStale
    # A status frame stamped before the session's last update.
    check fold.applyFrame(LifecycleFrame(event: "lifecycle",
      kind: "session_status_changed", sessionId: "a1", status: "paused",
      atMs: T0 - 119_000)) == foStale
    # A listing entry older than the session as held.
    var old = fold.sessions[fold.find("a1")]
    old.updatedAtMs = T0 - 119_000
    old.prompt = "an older entry"
    check fold.apply(sessionFrame(old)) == foStale
    check fold.snapshot == held

  test "an event without its place in the history is counted by the fold":
    var fold = initFleetFold(inventedRun().listedAt(T0))
    check fold.apply(eventFrame("a1", asked(150))) == foApplied
    check fold.sessions[fold.find("a1")].awaitingInputSource == "a1:native-question:1"
    check fold.apply(eventFrame("a1", answered(170))) == foApplied
    check not fold.sessions[fold.find("a1")].awaitingInput

  test "a frame repeating the known status changes nothing":
    var fold = initFleetFold(inventedRun().listedAt(T0))
    let revision = fold.revision
    check fold.applyFrame(LifecycleFrame(event: "lifecycle",
      kind: "session_status_changed", sessionId: "a1", status: "running",
      atMs: T0 + 1)) == foUnchanged
    check fold.revision == revision
    check fold.capturedAtMs == T0

  test "resync and caught-up frames mark the fold":
    var fold = initFleetFold(inventedRun().listedAt(T0))
    check fold.applyFrame(LifecycleFrame(event: "resync")) == foApplied
    check fold.resyncing
    check fold.applyFrame(LifecycleFrame(event: "caught_up")) == foApplied
    check fold.applyFrame(LifecycleFrame(event: "caught_up")) == foUnchanged

  test "a wait the listing reports for another reason than a question is kept":
    # The listing says a1's turn ended (Agent Harbor's stop hook) and c3's
    # wait is estimated; the fleet list shows both as needing input. An
    # event that is not the operator's input does not end or rename either
    # wait; the operator's input ends it.
    var listed = inventedRun().listedAt(T0)
    for s in listed.sessions.mitems:
      if s.id == "a1":
        s.awaitingInput = true
        s.awaitingInputSource = "claude-stop-hook"
    var fold = initFleetFold(listed)
    proc a1(fold: FleetFold): FleetSession = fold.sessions[fold.find("a1")]
    check fold.a1.statusLabelOf == "needs input"
    check fold.a1.statusLabelOf(espIdlePromptApart) == "idle"
    check fold.counts[fcNeedsInput] == 1
    check fold.apply(eventFrame("a1", said(130, "assistant: still here"), 4)) == foApplied
    check fold.apply(eventFrame("a1", tool(140, "just test"), 5)) == foApplied
    check fold.a1.awaitingInput
    check fold.a1.statusLabelOf == "needs input"
    check fold.counts[fcNeedsInput] == 1
    check fold.apply(eventFrame("a1", %*{"type": "session_awaiting_input",
      "request": "claude-stop-hook", "timestamp": 145_000_000}, 6)) == foApplied
    check fold.apply(eventFrame("a1", asked(150), 7)) == foApplied
    check fold.a1.awaitingInput
    check fold.a1.awaitingInputSource == "claude-stop-hook"
    check fold.a1.statusLabelOf == "needs input"
    check fold.a1.statusLabelOf(espIdlePromptApart) == "idle"
    check fold.counts[fcNeedsInput] == 1
    check fold.apply(eventFrame("a1", answered(170), 8)) == foApplied
    check not fold.a1.awaitingInput
    check fold.a1.awaitingInputSource == ""
    check fold.counts[fcNeedsInput] == 0
    # A settle-heuristic wait stays estimated through a log line, and a
    # resumed session waits no longer.
    listed.sessions[0].awaitingInputSource = "settle"
    fold = initFleetFold(listed)
    check fold.apply(eventFrame("a1", said(130, "assistant: still here"), 4)) == foApplied
    check fold.a1.statusLabelOf == "needs input (estimated)"
    check fold.apply(eventFrame("a1", %*{"type": "session_resumed",
      "deliverer": "human", "timestamp": 160_000_000}, 5)) == foApplied
    check not fold.a1.awaitingInput

  test "a question wait ends with the next event that is not a question":
    var fold = initFleetFold(inventedRun().listedAt(T0))
    check fold.apply(eventFrame("a1", asked(150), 5)) == foApplied
    check fold.sessions[fold.find("a1")].statusLabelOf(espIdlePromptApart) == "needs input"
    check fold.apply(eventFrame("a1", tool(160, "just lint"), 6)) == foApplied
    check not fold.sessions[fold.find("a1")].awaitingInput
    check fold.counts[fcNeedsInput] == 0

suite "folding a session one event at a time":
  test "sessionAt is foldEvent repeated, and the replay from scratch":
    # `sessionAt` repeats `foldEvent`; both must equal the replay written out
    # above at every count, for every invented session and for a history
    # that asks through the server's log line and ends.
    var histories: seq[(FleetSession, seq[JsonNode], int64)]
    for s in inventedRun().sessions:
      histories.add (s.entry, s.history, s.startMs)
    histories.add (FleetSession(id: "s9", prompt: "invented"), @[
      status(0, "queued"), status(0, "running"),
      ev(1, %*{"type": "log", "level": "info",
               "message": "agent question (Claude Code): tool=AskUserQuestion"}),
      ev(2, %*{"type": "session_awaiting_input", "request": "s9:question:1"}),
      answered(3), tool(4, "make test"), said(9, "assistant: Done."),
      status(10, "completed"), said(11, "late line")], 1_000_000'i64)
    var compared = 0
    for (entry, history, startMs) in histories:
      for count in 0 .. history.len:
        var stepped = entry.sessionAt(history, 0, startMs)
        for i in 0 ..< count:
          stepped.foldEvent(history[i], i + 1, startMs)
        let replayed = entry.sessionAt(history, count, startMs)
        let reference = entry.replayedFromScratch(history, count, startMs)
        check $stepped == $replayed
        check $replayed == $reference
        inc compared
    check compared == 33

  test "a directory keeps a listing's order and replaces a repeated id":
    let dir = initSessionDirectory([entry("z", "1"), entry("a", "2"), entry("z", "3")])
    check dir.len == 2
    check dir.sessions[0].id == "z"
    check dir.sessions[0].prompt == "3"
    check dir.find("a") == 1

  test "upsert replaces in place or appends, and refuses a session without id":
    var dir = initSessionDirectory([entry("a", "1"), entry("b", "2")])
    check not dir.upsert(entry("a", "one"))
    check dir.sessions[0].prompt == "one"
    check dir.upsert(entry("c", "3"))
    check dir.find("c") == 2
    check not dir.upsert(FleetSession())
    check dir.len == 3
