## The cardless timeline's fold (`nim_agents/activity_groups`), native and JS:
## its item kinds and one-line words, its grouping rules and their breaks,
## running items on a group line, gap lines, its policies, command traces,
## level-2 details, and the stability of its ids as events arrive.
##
## No test doubles: every input is an Agent Harbor event in its wire shape
## (invented), decoded by nim-agent-harbor's `eventFromJson` and projected by
## the production `harborEventToAgentEvent`, then folded. Expectations are
## written out by hand from the rules in the module comment, never computed
## through the fold; the one computed oracle, `nodesOf` (the closed form), is
## compared with the incremental fold after every event, and is itself held
## to hand-written node lists first.

import std/[json, sequtils, sets, strutils, unittest]
import nim_agents/activity_groups
import nim_agents/agent_harbor/fleet_records

const
  Session = "5ca1ab1e-0d01-4d00-8000-00000000d001"
  Times = " \xC3\x97"
  Minus = "\xE2\x88\x92"

proc at(seconds: int; body: JsonNode): JsonNode =
  ## `body` stamped `seconds` after the session started (µs, as the wire).
  result = body.copy
  result["timestamp"] = %(int64(seconds) * 1_000_000)

proc read(s: int; path: string): JsonNode =
  at(s, %*{"type": "file_read", "file_path": path})

proc thinks(s: int; text: string): JsonNode =
  at(s, %*{"type": "thought", "thought": text})

proc model(s: int): JsonNode =
  at(s, %*{"type": "llm_request", "model": "invented-model", "messageCount": 4})

proc search(s: int; id, tool, pattern: string): JsonNode =
  at(s, %*{"type": "tool_use", "tool_name": tool, "tool_execution_id": id,
           "status": "started", "tool_args": {"pattern": pattern}})

proc runs(s: int; id, command: string): JsonNode =
  at(s, %*{"type": "tool_use", "tool_name": "runCmd", "tool_execution_id": id,
           "status": "started", "tool_args": {"command": command}})

proc finishes(s: int; id: string; exit: int; output = ""; trace: JsonNode = nil): JsonNode =
  result = at(s, %*{"type": "tool_result", "tool_name": "runCmd",
                    "tool_execution_id": id,
                    "status": (if exit == 0: "completed" else: "failed"),
                    "exit_code": exit, "tool_output": output})
  if not trace.isNil: result["command_trace"] = trace

proc edits(s: int; path: string; added, removed: int): JsonNode =
  at(s, %*{"type": "file_edit", "file_path": path, "lines_added": added,
           "lines_removed": removed})

proc says(s: int; text: string; level = "info"): JsonNode =
  at(s, %*{"type": "log", "level": level, "message": text})

proc instructs(s: int; text: string): JsonNode =
  at(s, %*{"type": "user_input", "content": text})

proc asks(s: int; prompt: string): JsonNode =
  at(s, %*{"type": "agent_question", "kind": "single_choice", "prompt": prompt,
           "options": [{"label": "Full jitter"}, {"label": "Equal jitter"}]})

proc waits(s: int; request: string): JsonNode =
  at(s, %*{"type": "session_awaiting_input", "request": request})

proc status(s: int; value: string; message = ""): JsonNode =
  at(s, %*{"type": "status", "status": value, "message": message})

proc waitKind(s: int; request, kind: string): JsonNode =
  ## The server's refinement of the wait before it (`session_awaiting_input_kind`).
  at(s, %*{"type": "session_awaiting_input_kind", "request": request, "kind": kind})

proc ends(s: int; outcome: string): JsonNode =
  at(s, %*{"type": "session_ended", "outcome": outcome})

proc closedFormHolds(fold: TimelineFold): bool =
  nodesOf(fold.items, fold.policies.gapMs) == fold.nodes

proc foldOf(events: openArray[JsonNode];
            policies = agentHarborPolicies()): TimelineFold =
  result = initTimelineFold(policies)
  for event in events: discard result.applyJson(Session, event)

proc shape(fold: TimelineFold): seq[string] =
  ## Each top-level node as `<kind> <text> [<items>]`: what a reader sees at
  ## level 0, and how many items each line stands for.
  for node in fold.nodes:
    var line = $node.kind & " " & fold.nodeText(node)
    if node.kind == tnGroup: line.add " [" & $(node.last - node.first + 1) & "]"
    result.add line

proc kindsOf(fold: TimelineFold): seq[TimelineItemKind] =
  for item in fold.items: result.add item.kind

suite "items: kinds and one line each":
  test "each event kind is classified, and its line is the fleet's words":
    let events = @[
      instructs(1, "Add retry jitter to the upload client."),
      thinks(2, "Read the client first.\nThen its tests."),
      read(3, "src/upload/client.py"),
      search(4, "s1", "grep", "retry"),
      runs(5, "c1", "pytest -q"),
      edits(6, "src/upload/backoff.py", 18, 4),
      at(7, %*{"type": "file_edit", "file_path": "src/old.py", "status": "deleted"}),
      at(8, %*{"type": "tool_use", "tool_name": "fetchDocs", "tool_execution_id": "t1",
               "tool_args": {"url": "https://example.invalid/docs"}}),
      at(9, %*{"type": "plan", "entries": [{"content": "a", "status": "completed"},
                                           {"content": "b", "status": "in_progress"}]}),
      model(10),
      at(11, %*{"type": "sub_agent", "message": "reviewer started"}),
      asks(12, "Full or equal jitter?"),
      at(13, %*{"type": "session_resumed", "deliverer": "operator"}),
      says(14, "assistant: Done."),
      says(15, "error: the build broke", "error"),
      status(16, "completed", "Retry jitter is in.")]
    let fold = foldOf(events)
    check fold.kindsOf == @[tikOperator, tikThought, tikRead, tikSearch, tikShell,
      tikEdit, tikDelete, tikTool, tikPlan, tikModel, tikHarness, tikQuestion,
      tikResumed, tikAgent, tikFailure, tikCompleted]
    # One vocabulary: each single item's line is the fleet's activity line
    # for the same event.
    for i, item in fold.items:
      check item.line == activityFromJson(events[i]).text
    check fold.items[0].line == "Instruction sent"
    check fold.items[0].body == "Add retry jitter to the upload client."
    check fold.items[1].line == "Thinking: Read the client first."
    check fold.items[2].line == "Read src/upload/client.py"
    check fold.items[4].line == "Ran pytest -q"
    check fold.items[5].line == "Edited src/upload/backoff.py +18 " & Minus & "4"
    check fold.items[6].line == "Deleted src/old.py"
    check fold.items[9].line == "Model request (invented-model)"
    check fold.items[11].line == "Asked a single-choice question"
    check fold.items[11].body == "Full or equal jitter?"
    check fold.items[11].options == @["Full jitter", "Equal jitter"]
    check fold.items[13].body == "Done."
    check fold.items[15].body == "Retry jitter is in."
    # Items carry the session's own times (ms since it started).
    check fold.items.mapIt(it.atMs) == toSeq(1 .. 16).mapIt(int64(it) * 1000)

  test "the words for events the fleet had no words for":
    # These events read by their wire type before (`llm request`, `diff`, …);
    # the timeline needs words for them, and a fleet row says the same.
    check activityLine(%*{"type": "llm_request", "model": "m"}).text == "Model request (m)"
    check activityLine(%*{"type": "llm_request"}).text == "Model request"
    check activityLine(%*{"type": "error", "message": "boom\nmore"}).text == "Error: boom"
    check activityLine(%*{"type": "error"}).level == "error"
    check activityLine(%*{"type": "session_ended", "outcome": "failed"}).text ==
      "Session ended (failed)"
    check activityLine(%*{"type": "sub_agent", "message": "reviewer started"}).text ==
      "Sub-agent: reviewer started"
    check activityLine(%*{"type": "delegation", "kind": "started", "activeSubAgents": 1,
                          "totalSubAgents": 2}).text ==
      "Delegation started (1 of 2 agents active)"
    check activityLine(%*{"type": "diff", "file_path": "a.py", "lines_added": 2,
                          "lines_removed": 1}).text == "Edited a.py +2 " & Minus & "1"
    check activityLine(%*{"type": "file_edit", "file_path": "a.py",
                          "status": "deleted"}).text == "Deleted a.py"
    # Unchanged: a type with no words of its own still reads as its type.
    check activityLine(%*{"type": "context_files"}).text == "context files"

  test "a live status is no line; an ending is":
    let fold = foldOf([status(1, "queued"), status(2, "running"),
                       read(3, "a.py"), status(4, "paused"), status(5, "running"),
                       status(6, "failed", "out of memory")])
    check fold.kindsOf == @[tikRead, tikFailure]
    check fold.items[1].line == "Status: failed"
    check fold.items[1].body == "out of memory"

  test "a stop-hook wait is a status line; a question wait is a question":
    let fold = foldOf([waits(1, "claude-stop-hook"),
                       waits(2, Session & ":native-question:7")])
    check fold.kindsOf == @[tikStatus, tikQuestion]
    check fold.items[0].line == "Waiting for input (claude stop hook)"

  test "a wait's kind, when the server names it, decides; it is no line":
    let stop = "claude-stop-hook"
    let native = Session & ":native-question:7"
    # A stop-hook wait the server says is blocked on a question is one, and a
    # question-named wait whose turn ended is a status line.
    var fold = foldOf([waits(1, stop)])
    check fold.kindsOf == @[tikStatus]
    let change = fold.applyJson(Session, waitKind(1, stop, "question_pending"))
    check change.changed
    check change.newItems == 0
    check change.updated == @[fold.items[0].id]
    check fold.kindsOf == @[tikQuestion]
    check fold.items[0].waitKind == "question_pending"
    check fold.closedFormHolds
    check foldOf([waits(1, native), waitKind(1, native, "turn_ended")]).kindsOf ==
      @[tikStatus]
    # `unknown`, or no kind at all, leaves the request to decide.
    check foldOf([waits(1, native), waitKind(1, native, "unknown")]).kindsOf ==
      @[tikQuestion]
    check foldOf([waits(1, stop), waitKind(1, stop, "unknown")]).kindsOf == @[tikStatus]
    # The kind refines the newest wait with its request, once: the stop hook's
    # turn-ended waits still form one repeat line.
    let repeats = foldOf([waits(1, stop), waitKind(1, stop, "turn_ended"),
                          waits(2, stop), waitKind(2, stop, "turn_ended"),
                          waits(3, stop), waitKind(3, stop, "turn_ended")])
    check repeats.shape == @["group Waiting for input (claude stop hook)" & Times & "3 [3]"]
    check repeats.items.mapIt(it.waitKind) == @["turn_ended", "turn_ended", "turn_ended"]
    # A wait refined to a question breaks the repeat it would have joined.
    let broken = foldOf([waits(1, stop), waits(2, stop), waitKind(2, stop, "question_pending"),
                         waits(3, stop)])
    check broken.kindsOf == @[tikStatus, tikQuestion, tikStatus]
    check broken.nodes.mapIt(it.kind) == @[tnItem, tnItem, tnItem]
    check broken.closedFormHolds
    # A kind with no wait to refine changes nothing.
    var lone = foldOf([read(1, "a.py")])
    check not lone.applyJson(Session, waitKind(2, stop, "question_pending")).changed
    check lone.kindsOf == @[tikRead]
    # A wait the operator already answered stays answered as a question.
    let late = foldOf([waits(1, native), instructs(2, "Go on."),
                       waitKind(3, native, "question_pending")])
    check late.items[0].kind == tikQuestion
    check late.items[0].answered

  test "a session's failed ending right after a failure repeats it":
    # The agent's failure, then the session's failed status: one fault.
    let fold = foldOf([says(1, "the upgrade breaks the tests", "error"),
                       status(2, "failed", "The agent stopped.")])
    check fold.kindsOf == @[tikFailure, tikFailure]
    check not fold.repeatsFault(0)
    check fold.repeatsFault(1)
    # A chain of endings repeats the one fault.
    let chain = foldOf([at(1, %*{"type": "error", "message": "out of memory"}),
                        ends(2, "failed"), status(3, "failed")])
    check chain.kindsOf == @[tikFailure, tikFailure, tikFailure]
    check (0 ..< 3).toSeq.mapIt(chain.repeatsFault(it)) == @[false, true, true]
    # An ending that is itself the fault is repeated by the ending after it.
    let endings = foldOf([ends(1, "failed"), status(2, "failed")])
    check (0 ..< 2).toSeq.mapIt(endings.repeatsFault(it)) == @[false, true]
    # A failed ending with no failure right before it is the fault itself.
    let alone = foldOf([says(1, "the upgrade breaks the tests", "error"),
                        read(2, "a.py"), status(3, "failed")])
    check not alone.repeatsFault(2)
    check not foldOf([status(1, "failed")]).repeatsFault(0)
    # Two failures of the agent's own are two faults.
    let two = foldOf([says(1, "first", "error"), says(2, "second", "error")])
    check not two.repeatsFault(1)
    # A completed ending repeats nothing.
    check not foldOf([says(1, "x", "error"), status(2, "completed")]).repeatsFault(1)
    check fold.items.mapIt(it.sourceType) == @["log", "status"]

  test "the operator's input answers the questions before it":
    var fold = foldOf([asks(1, "Which jitter?"), says(2, "assistant: waiting")])
    check not fold.items[0].answered
    let change = fold.applyJson(Session, instructs(3, "Full jitter."))
    check fold.items[0].answered
    check fold.items[0].id in change.updated
    check change.newItems == 1
    var resumed = foldOf([asks(1, "Which jitter?")])
    discard resumed.applyJson(Session, at(2, %*{"type": "session_resumed"}))
    check resumed.items[0].answered

  test "an event is folded once by its id":
    var fold = initTimelineFold()
    let event = %*{"type": "file_read", "file_path": "a.py", "eventId": "e1"}
    check fold.applyJson(Session, event).changed
    check not fold.applyJson(Session, event).changed
    check fold.itemCount == 1

suite "grouping":
  test "each group kind, with its summary":
    let fold = foldOf([
      read(1, "a.py"), read(2, "b.py"), read(3, "c.py"), read(4, "d.py"),
      search(5, "s1", "grep", "retry"), search(6, "s2", "glob", "*.py"),
      search(7, "s3", "rg", "sleep"),
      runs(8, "c1", "pytest -q"), finishes(9, "c1", 0),
      runs(10, "c2", "pytest -x"), finishes(11, "c2", 1),
      edits(12, "a.py", 18, 4), edits(13, "b.py", 10, 6), edits(14, "c.py", 12, 2),
      waits(15, "claude-stop-hook"), waits(16, "claude-stop-hook"),
      waits(17, "claude-stop-hook")])
    check nodesOf(fold.items) == fold.nodes
    check fold.shape == @[
      "group Read 4 files [4]",
      "group Searched 3 times [3]",
      "group Ran 2 shell commands (1 failed) [2]",
      "group Edited 3 files +40 " & Minus & "12 [3]",
      "group Waiting for input (claude stop hook)" & Times & "3 [3]"]
    check fold.nodes[2].failed == 1
    check fold.nodes[2].failedText == "(1 failed)"
    check fold.nodes[3].totalsText == "+40 " & Minus & "12"
    check fold.nodes[4].groupKind == tgkRepeat

  test "one item is not a group":
    let fold = foldOf([read(1, "a.py"), says(2, "assistant: ok"),
                       runs(3, "c1", "make"), finishes(4, "c1", 0)])
    check nodesOf(fold.items) == fold.nodes
    check fold.shape == @["item Read a.py", "item assistant: ok", "item Ran make"]

  test "a group ends at an operator message, an agent message, a question and a failure":
    for breaker in [instructs(3, "Stop reading."), says(3, "assistant: halfway"),
                    asks(3, "Go on?"), says(3, "error: disk full", "error"),
                    at(3, %*{"type": "error", "message": "provider failed"})]:
      let fold = foldOf([read(1, "a.py"), read(2, "b.py"), breaker,
                         read(4, "c.py"), read(5, "d.py")])
      check nodesOf(fold.items) == fold.nodes
      checkpoint $breaker
      check fold.nodes.len == 3
      check fold.nodes[0].kind == tnGroup and fold.nodes[0].count == 2
      check fold.nodes[1].kind in {tnTurn, tnItem}
      check fold.nodes[1].first == 2
      check fold.nodes[2].kind == tnGroup and fold.nodes[2].first == 3

  test "a failed command is counted on its group line, not a break":
    let fold = foldOf([runs(1, "c1", "pytest -q"), finishes(2, "c1", 1),
                       runs(3, "c2", "pytest -x"), finishes(4, "c2", 0),
                       runs(5, "c3", "ruff ."), finishes(6, "c3", 1)])
    check nodesOf(fold.items) == fold.nodes
    check fold.shape == @["group Ran 3 shell commands (2 failed) [3]"]

  test "interleaved kinds give no group":
    let fold = foldOf([read(1, "a.py"), search(2, "s1", "grep", "x"),
                       read(3, "b.py"), search(4, "s2", "grep", "y")])
    check nodesOf(fold.items) == fold.nodes
    check fold.nodes.mapIt(it.kind) == @[tnItem, tnItem, tnItem, tnItem]

  test "thoughts and model requests between two items fold into the group":
    let fold = foldOf([read(1, "a.py"), thinks(2, "next"), model(3), read(4, "b.py"),
                       thinks(5, "now edit"), edits(6, "a.py", 1, 0)])
    check nodesOf(fold.items) == fold.nodes
    check fold.shape == @["group Read 2 files [4]", "item Thinking: now edit",
                          "item Edited a.py +1 " & Minus & "0"]
    check fold.nodes[0].count == 2

  test "repeats are merged only when adjacent":
    let fold = foldOf([waits(1, "claude-stop-hook"), at(2, %*{"type": "session_resumed"}),
                       waits(3, "claude-stop-hook"), waits(4, "claude-stop-hook")])
    check nodesOf(fold.items) == fold.nodes
    check fold.shape == @["item Waiting for input (claude stop hook)", "item Resumed",
                          "group Waiting for input (claude stop hook)" & Times & "2 [2]"]

  test "a group with a running command names it, until its result":
    var fold = foldOf([runs(1, "c1", "pytest -q"), finishes(2, "c1", 0),
                       runs(3, "c2", "pytest -q tests/test_client.py")])
    check nodesOf(fold.items) == fold.nodes
    check fold.nodes.len == 1
    check fold.nodes[0].running == 1
    let running = fold.items[fold.findItem(fold.nodes[0].runningItem)]
    check running.command == "pytest -q tests/test_client.py"
    check running.state == tisRunning
    check fold.nodeText(fold.nodes[0]) == "Ran 2 shell commands"
    let change = fold.applyJson(Session, finishes(4, "c2", 1))
    check change.updated == @[running.id]
    check change.newItems == 0
    check fold.nodes[0].running == 0
    check fold.nodes[0].runningItem == ""
    check fold.nodeText(fold.nodes[0]) == "Ran 2 shell commands (1 failed)"

  test "a gap of five minutes or more is a line of its own, and ends a group":
    let fold = foldOf([read(10, "a.py"), read(20, "b.py"), read(320, "c.py"),
                       read(330, "d.py"), read(400, "e.py")])
    check nodesOf(fold.items) == fold.nodes
    check fold.shape == @["group Read 2 files [2]", "gap 5 min later",
                          "group Read 3 files [3]"]
    check fold.nodes[1].id == "gap:" & fold.items[2].id
    let hour = foldOf([read(0, "a.py"), read(2 * 3600 + 60, "b.py")])
    check nodesOf(hour.items) == hour.nodes
    check hour.shape == @["item Read a.py", "gap 2 h later", "item Read b.py"]

  test "each operator message starts a turn":
    let fold = foldOf([instructs(1, "one"), read(2, "a.py"), instructs(3, "two"),
                       read(4, "b.py")])
    check nodesOf(fold.items) == fold.nodes
    check fold.nodes.mapIt(it.kind) == @[tnTurn, tnItem, tnTurn, tnItem]
    check fold.items.mapIt(it.turn) == @[1, 1, 2, 2]

suite "the fold as events arrive":
  proc longRun(): seq[JsonNode] =
    ## Every grouping case in one run, with turns, gaps and updates.
    var s = 0
    proc next(step = 2): int =
      s += step
      s
    for turn in 1 .. 6:
      result.add instructs(next(), "turn " & $turn)
      result.add thinks(next(), "plan " & $turn)
      for f in 1 .. turn mod 4 + 1: result.add read(next(), "src/f" & $f & ".py")
      result.add thinks(next(), "then search")
      result.add search(next(), "s" & $turn & "a", "grep", "x")
      result.add model(next())
      result.add search(next(), "s" & $turn & "b", "rg", "y")
      let a = "c" & $turn & "a"
      let b = "c" & $turn & "b"
      result.add runs(next(), a, "pytest -q")
      result.add runs(next(), b, "ruff check")
      result.add finishes(next(), a, turn mod 2)
      result.add finishes(next(), b, 0)
      result.add edits(next(), "src/f1.py", turn, 1)
      result.add edits(next(), "src/f2.py", 2, turn)
      for _ in 1 .. turn mod 3 + 1: result.add waits(next(), "claude-stop-hook")
      if turn == 3: result.add asks(next(), "Continue?")
      if turn == 4: result.add says(next(), "error: flaky", "error")
      result.add says(next(), "assistant: turn " & $turn & " done")
      if turn == 5: discard next(400)

  test "the closed form, by hand":
    let fold = foldOf(longRun()[0 .. 16])
    check fold.shape == @[
      "turn Instruction sent", "item Thinking: plan 1", "group Read 2 files [2]",
      "item Thinking: then search", "group Searched 2 times [3]",
      "group Ran 2 shell commands (1 failed) [2]",
      "group Edited 2 files +3 " & Minus & "2 [2]",
      "group Waiting for input (claude stop hook)" & Times & "2 [2]",
      "item assistant: turn 1 done"]
    check nodesOf(fold.items) == fold.nodes

  test "after every event the fold equals the closed form, and no id is lost":
    var fold = initTimelineFold()
    var previous: seq[TimelineNode]
    var groupIds = initHashSet[string]()
    var steps = 0
    for event in longRun():
      discard fold.applyJson(Session, event)
      inc steps
      check fold.nodes == nodesOf(fold.items)
      var now = initHashSet[string]()
      var members = initHashSet[string]()
      for node in fold.nodes:
        now.incl node.id
        if node.kind == tnGroup:
          check node.id == "group:" & fold.items[node.first].id
          for item in fold.itemsOf(node): members.incl item.id
      for node in previous:
        # A line that was drawn is still drawn: as itself, or (an item) as
        # a member of the group it joined.
        if node.id notin now and node.id notin members:
          checkpoint "step " & $steps & ": " & node.id & " (" & $node.kind & ") vanished"
          fail()
      for id in groupIds:
        if id notin now:
          checkpoint "step " & $steps & ": the group " & id & " changed its id"
          fail()
      for node in fold.nodes:
        if node.kind == tnGroup: groupIds.incl node.id
      previous = fold.nodes
    check groupIds.len >= 20
    check fold.revision > 0

  test "a control: ids rewritten on append are caught":
    var fold = foldOf(longRun()[0 .. 10])
    var renamed = fold.nodes
    renamed[^1].id = "group:" & fold.items[renamed[^1].last].id
    check renamed != nodesOf(fold.items)

  test "a history read from the server folds oldest first":
    # The server lists a session's history newest first; `rawEvents` turns
    # it around, so folding a history read mid-session gives the same lines
    # as folding its events as they arrived. Written by hand: two reads, a
    # thought, a third read, then the operator's next turn.
    let arrived = @[instructs(1, "look"), read(2, "a.py"), read(3, "b.py"),
                    thinks(4, "one more"), read(5, "c.py"), instructs(6, "next")]
    var newestFirst = newJArray()
    for i in countdown(arrived.high, 0): newestFirst.add arrived[i]
    let history = sessionEventHistoryFromJson(Session,
      %*{"total_count": arrived.len, "has_more": false, "events": newestFirst})
    check history.events.mapIt(it.text) == @["Instruction sent", "Read c.py",
      "Thinking: one more", "Read b.py", "Read a.py", "Instruction sent"]
    check history.rawEvents == arrived
    let fold = foldOf(history.rawEvents)
    check fold.shape == @["turn Instruction sent", "group Read 3 files [4]",
                          "turn Instruction sent"]
    check fold.nodes == foldOf(arrived).nodes

suite "policies":
  test "whole lines: each log line is its own message; levels and questions":
    let fold = foldOf([says(1, "assistant: first"), says(2, "assistant: second"),
                       says(3, "agent question (claude): tool=AskUserQuestion"),
                       says(4, "error: tests failed", "error"),
                       thinks(5, "one"), thinks(6, "two")])
    check fold.kindsOf == @[tikAgent, tikAgent, tikQuestion, tikFailure,
                            tikThought, tikThought]
    check fold.items[0].body == "first"
    check fold.items[1].body == "second"
    check fold.items[2].line == "Asked a question (claude)"

  test "streamed chunks: an agent's text in one message per turn":
    let fold = foldOf([says(1, "Hello, "), says(2, "world.")], acpPolicies())
    check fold.kindsOf == @[tikAgent]
    check fold.items[0].body == "Hello, world."

  test "observed operator input starts a turn; acknowledged input is dropped":
    let observed = foldOf([instructs(1, "Add jitter.")])
    check observed.kindsOf == @[tikOperator]
    check observed.items[0].body == "Add jitter."
    let acknowledged = foldOf([instructs(1, "Add jitter.")], acpPolicies())
    check acknowledged.itemCount == 0

  test "operator text the server withholds is marked withheld":
    let fold = foldOf([at(1, %*{"type": "user_input", "withheld": ["content"]})])
    check fold.items[0].withheld
    check fold.items[0].body == ""
    check fold.items[0].line == "Instruction sent"

suite "details and command traces":
  proc pipeline(): JsonNode =
    %*{"processes": [
         {"pid": 4101, "ppid": 4100, "argv": ["pytest", "-q"], "cwd": "/work/upload",
          "exe": "/usr/bin/python3", "start_ms": 0, "end_ms": 2100, "exit_code": 1,
          "stdout": "F.\n1 failed", "stderr": ""},
         {"pid": 4102, "ppid": 4100, "argv": ["tee", "test.log"], "cwd": "/work/upload",
          "exe": "/usr/bin/tee", "start_ms": 0, "end_ms": 2105, "exit_code": 0},
         {"pid": 4103, "ppid": 4100, "argv": ["tail", "-n", "5"], "cwd": "/work/upload",
          "exe": "/usr/bin/tail", "start_ms": 1, "exit_code": nil}],
       "raw_output": "F.\n1 failed",
       "env": {"PATH": "/usr/bin", "UPLOAD_TOKEN": "invented-not-a-secret",
               "DB_PASSWORD": "invented"}}

  test "a trace travels on the command's result, its private variables redacted":
    var fold = foldOf([runs(1, "c1", "pytest -q | tee test.log | tail -n 5")])
    check fold.items[0].trace.isNone
    discard fold.applyJson(Session, finishes(3, "c1", 1, "1 failed", pipeline()))
    let item = fold.items[0]
    check item.trace.isSome
    let trace = item.trace.get
    check trace.processes.len == 3
    check trace.processes[0].argv == @["pytest", "-q"]
    check trace.processes[0].exitCode == 1 and trace.processes[0].hasExit
    check trace.processes[2].endMs == -1
    check not trace.processes[2].hasExit
    check trace.failedStage == 0
    check trace.env == @[TraceVariable(name: "PATH", value: "/usr/bin"),
                         TraceVariable(name: "UPLOAD_TOKEN", value: "[private]"),
                         TraceVariable(name: "DB_PASSWORD", value: "[private]")]
    check item.exitCode == 1 and item.hasExit
    check item.state == tisFailed
    check fold.detailOf(item.id).hasTrace

  test "a command without a trace has none":
    let fold = foldOf([runs(1, "c1", "make"), finishes(2, "c1", 0, "ok")])
    check fold.items[0].trace.isNone
    check not fold.detailOf(fold.items[0].id).hasTrace

  test "level 2: arguments redacted, output, diff, facts":
    let fold = foldOf([
      at(1, %*{"type": "tool_use", "tool_name": "deploy", "tool_execution_id": "t1",
               "tool_args": {"target": "staging", "api_token": "invented"}}),
      at(2, %*{"type": "tool_result", "tool_name": "deploy", "tool_execution_id": "t1",
               "tool_output": "deployed"}),
      at(3, %*{"type": "diff", "file_path": "a.py", "lines_added": 1,
               "lines_removed": 1, "diff": "-a\n+b"}),
      read(4, "src/upload/client.py")])
    let tool = fold.detailOf(fold.items[0].id)
    check "staging" in tool.arguments
    check "invented" notin tool.arguments
    check tool.output == "deployed"
    check fold.detailOf(fold.items[1].id).diff == "-a\n+b"
    check fold.detailOf(fold.items[2].id).facts.anyIt(
      it.label == "File" and it.value == "src/upload/client.py")
    check fold.detailOf("no-such-item").facts.len == 0
