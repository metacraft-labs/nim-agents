## A session's activity as a cardless timeline: one line per event, with runs
## of similar events collapsed into one group line, and every line expandable
## to its details. Signal-free and renderer-free; identical on the C and JS
## targets. Import `nim_agents/activity_groups` explicitly.
##
## The fold (`TimelineFold`) wraps the activity reducer (`ActivityTimeline`,
## `activity.nim`), which merges a tool call's updates into one entry and
## streamed text into one message, and keeps, beside its entries, what a
## timeline shows of each: an item (`TimelineItem`: its kind, its one line in
## the words every view uses, its state, its file, command and counts, its
## command trace), and the nodes the items are drawn as (`TimelineNode`: an
## operator's turn, a quiet gap line, a single item, or a group).
##
## **The grouping rules**, stated once here and nowhere else:
##
## - consecutive items of one groupable kind (`tikRead`, `tikSearch`,
##   `tikShell`, `tikEdit`) form a group of at least two; one item is not a
##   group;
## - thoughts and model requests between two items of the group's kind fold
##   into the group: they are its items, and the group line never names or
##   counts them; one after the group's last item of its kind stays outside;
## - consecutive status or hook lines with identical text and level form one
##   repeat group, drawn once with `×N`; repeats are never merged across
##   another line (unlike `activity_digest`, which merges a session's lines
##   wherever they occur);
## - anything else ends a group: an operator message (which also starts a
##   turn), an agent message, a question, a failure the agent stops on
##   (`tikFailure`), or an item of another kind; so does a gap of at least
##   `TimelinePolicies.gapMs` (five minutes by default) between two items,
##   which is drawn as its own quiet line;
## - a failed shell command inside a group is counted on the group line
##   (`failed`), not a break;
## - a group with a running item names it (`runningItem`), so a running
##   command is never hidden inside a collapsed group.
##
## **Identity.** An item's id is its reducer entry's id, which the reducer
## keeps for a tool call across its updates. A group's id is `group:` and its
## first item's id, so it keeps its identity as it grows and never shares an
## id with its own first item; a turn's id is its operator item's id, a gap's
## `gap:` and the id of the item after it. Ids never change once given, so a
## reader's expansion and focus survive new events.
##
## **Incremental and closed forms.** `apply` keeps the nodes up to date as
## each event arrives: an append re-derives only the timeline's open tail (the
## last group or groupable line and any thoughts after it), and an update
## changes an item in place. `nodesOf` derives the nodes of a whole item list
## at once; the two agree after every event, which the tests check.
##
## **Policies** (choices front-ends make differently):
##
## - `ChunkPolicy`: `cpStreamChunks` (ACP streams an agent's text in chunks,
##   merged into one message per turn, as `ActivityTimeline` does) or
##   `cpWholeLines` (Agent Harbor sends whole `log` lines and whole
##   thoughts: each is its own line, an `error`-level log line is a failure,
##   and the server's `agent question (<agent>): …` line is a question);
## - `OperatorInputPolicy`: `oiAcknowledge` (a session this front-end
##   started records the operator's turn when it sends it, so the backend's
##   `user_input` echo is dropped, as `ActivityTimeline` does) or
##   `oiObserved` (a session observed from elsewhere: each `user_input`
##   starts a turn with its content).
##
## Status events whose status is a live session state (`queued`, `running`,
## …) are not lines: the session's status is shown once, beside the timeline,
## as a fleet row shows it beside its activity digest. Endings (`completed`,
## `failed`, `cancelled`) are lines. A session's failed ending right after
## the failure it repeats is marked (`repeatsFault`), so a view draws one
## fault in the error role once; the rule reads item kinds and wire types,
## never a line's text.
##
## **Waits.** A wait (`session_awaiting_input`) is a question when the server
## says the agent is blocked on one, and a status line when its turn ended
## (an agent's stop hook, which repeats and forms `×N`). The server says so in
## a second event, `session_awaiting_input_kind` (`kind`: `question_pending`,
## `turn_ended` or `unknown`), sent right after the wait with the same
## `request`; it refines that wait in place and is no line of its own. Until
## it arrives, or when it says `unknown`, the request decides: a request that
## names a question (`<session>:native-question:<n>`) is a question.
##
## **Command traces.** A shell command may carry a trace of the processes it
## ran (`CommandTrace`: the process tree with each process's argv, working
## directory, executable, ids, times, exit status and output, the raw output,
## and the environment with private values redacted). Agent Harbor serves no
## such record yet; this module reads the proposed shape from a
## `command_trace` object on the command's `tool_result`
## (`commandTraceFromJson`). A command without one has no trace, and a view
## says so.
##
## **Test runs.** A test run of the session (`applyTestRun`) is an item of
## its own kind, `tikTestRun`, folded at the run's start time with the line
## the caller gives it (`test_runs.summaryLine`). It is never a member of a
## group and never hidden inside one, and it does not change any other
## line: the event lines are grouped exactly as they would be without it,
## and the run's line is placed after the line (single, or a whole group)
## that started at or before the run's start, so a run that started while a
## group was growing stands after that group. A run with no start time
## stands last. Updating a run (its line, its state) moves nothing else.
##
## What crosses into an item: the event's line (`activity_words`, the words
## every view uses), its structured fields, and the operator's or agent's
## own text where the server gives it (an item's `body`); a question's prompt
## and an instruction's content appear in `body`, never in `line`.

import std/[json, options, sets, strutils, tables]
# Transport-free, like `activity`: the Agent Harbor wire types and the
# `AgentEvent` projection, never a client or `nim_agent_harbor/native` (see
# `agent_events`).
import nim_agent_harbor/types
import ./[agent_events, activity, activity_presentation]
import ./agent_harbor/activity_words

export options, activity, activity_presentation, activity_words

type
  TimelineItemKind* = enum
    tikOperator = "operator"     ## the operator's message (starts a turn)
    tikAgent = "agent"           ## an agent message
    tikThought = "thought"
    tikRead = "read"             ## `file_read`
    tikSearch = "search"         ## a search tool (grep, glob, find, rg, …)
    tikShell = "shell"           ## a tool whose arguments carry a `command`
    tikEdit = "edit"             ## `file_edit`, `diff`
    tikDelete = "delete"         ## a deleted file
    tikTool = "tool"             ## any other tool
    tikPlan = "plan"
    tikModel = "model"           ## `llm_request`
    tikHarness = "harness"       ## `sub_agent`, `delegation`, `orchestration`
    tikQuestion = "question"     ## the agent asks, or waits on a question
    tikResumed = "resumed"
    tikStatus = "status"         ## a status or hook line
    tikFailure = "failure"       ## a failure the agent stops on
    tikCompleted = "completed"
    tikCancelled = "cancelled"
    tikOther = "other"
    tikTestRun = "test-run"      ## a test run of the session (`applyTestRun`)

  TimelineItemState* = enum
    tisNone = "none"             ## an item with no run state
    tisRunning = "running"
    tisOk = "ok"
    tisFailed = "failed"
    tisCancelled = "cancelled"

  TracedProcess* = object
    ## One process of a command's trace.
    pid*, ppid*: int
    argv*: seq[string]
    cwd*, exe*: string
    startMs*, endMs*: int64
      ## Milliseconds since the command started; `endMs` is -1 while the
      ## process still runs.
    exitCode*: int
    hasExit*: bool               ## false while running, or when unknown
    stdout*, stderr*: string

  TraceVariable* = object
    name*, value*: string        ## a private value reads `[private]`

  CommandTrace* = object
    ## The processes one command ran (proposed shape; see the module comment).
    processes*: seq[TracedProcess]
    rawOutput*: string
    env*: seq[TraceVariable]

  TimelineItem* = object
    id*: string
    kind*: TimelineItemKind
    turn*: int
    atMs*: int64
      ## Milliseconds since the session started (the event's timestamp); -1
      ## when the event carries none.
    line*: string                ## the one line, in the words every view uses
    sourceType*: string
      ## The wire type of the event it shows (`status`, `session_ended`, …):
      ## what a rule reads instead of the line's text.
    body*: string
      ## The operator's or agent's own text where the server gives it: an
      ## instruction or answer, an agent message, a question's prompt, a
      ## thought, a completion's summary. "" otherwise.
    withheld*: bool              ## the server withheld the operator's text
    level*: string               ## a log line's level
    state*: TimelineItemState
    answered*: bool              ## a question the operator's input followed
    filePath*, command*, toolName*, toolCallId*: string
    added*, removed*: int
    exitCode*: int
    hasExit*: bool
    options*: seq[string]        ## a question's choices
    request*: string             ## a wait's request (`session_awaiting_input`)
    waitKind*: string
      ## A wait's kind as the server refined it (`turn_ended`,
      ## `question_pending`, `unknown`); "" until a kind event names it.
    trace*: Option[CommandTrace]
    testRunId*: string           ## a `tikTestRun` item's run
    entry: int                   ## the reducer entry it shows

  TimelineDetail* = object
    ## Level 2 of an item: what it carried besides its line.
    facts*: seq[ActivityFact]    ## `activityPresentation`'s facts
    arguments*: string           ## a tool's arguments, private fields redacted
    output*: string              ## a tool's result or output
    diff*: string                ## an edit's patch
    body*: string
    options*: seq[string]
    hasTrace*: bool

  TimelineGroupKind* = enum
    tgkRead = "read", tgkSearch = "search", tgkShell = "shell",
    tgkEdit = "edit", tgkRepeat = "repeat"

  TimelineNodeKind* = enum
    tnTurn = "turn"              ## an operator message, starting a turn
    tnGap = "gap"                ## a quiet line for a gap in time
    tnItem = "item"              ## a single item
    tnGroup = "group"            ## a run of items drawn as one line

  TimelineNode* = object
    ## One top-level line. Its items are `first .. last` of the fold's items
    ## (one item for a turn or a single item; none for a gap).
    id*: string
    kind*: TimelineNodeKind
    first*, last*: int
    gapMs*: int64                ## a gap's length
    groupKind*: TimelineGroupKind
    count*: int                  ## a group's items of its kind
    failed*, running*: int
    added*, removed*: int        ## an edit group's line totals
    runningItem*: string         ## the running item a group line names

  ChunkPolicy* = enum
    cpStreamChunks = "stream-chunks"
    cpWholeLines = "whole-lines"

  OperatorInputPolicy* = enum
    oiAcknowledge = "acknowledge"
    oiObserved = "observed"

  TimelinePolicies* = object
    chunks*: ChunkPolicy
    operatorInput*: OperatorInputPolicy
    gapMs*: int64                ## the shortest gap drawn as a gap line

  TimelineChange* = object
    ## What one `apply` did.
    changed*: bool
    newItems*: int               ## items added
    updated*: seq[string]        ## ids of items changed in place

  TimelineFold* = object
    policies*: TimelinePolicies
    revision*: int               ## moves on every change
    timeline: ActivityTimeline
    items: seq[TimelineItem]
    nodes: seq[TimelineNode]
    byEntry: Table[string, int]
    seen: HashSet[string]
    runs: seq[TimelineItem]
      ## The test-run items, in the order first applied. While there are
      ## none, the fold shows `items` and `nodes` as they are; with some, it
      ## shows `shown` and `shownNodes`, the event items with the runs placed
      ## among them (`arrange`).
    shown: seq[TimelineItem]
    shownNodes: seq[TimelineNode]
    shownIndex: Table[string, int]

const
  DefaultGapMs* = 5 * 60_000'i64
  GroupableKinds* = {tikRead, tikSearch, tikShell, tikEdit}
  FoldedKinds* = {tikThought, tikModel}
    ## Kinds that fold into a group between two of its items.
  LiveStatuses = ["queued", "provisioning", "running", "pausing", "paused",
                  "resuming", "stopping"]
  SearchTools = ["grep", "glob", "find", "rg", "ripgrep", "search", "codesearch"]
  SessionEndings* = ["status", "session_ended"]
    ## The wire types of a session's own ending (a `status` event naming an
    ## end, `session_ended`), as opposed to the agent's failure it may repeat.
  AwaitingKindEvent* = "session_awaiting_input_kind"
    ## The event that refines a wait (`session_awaiting_input`) with its kind.
  Times = " \xC3\x97"
  Minus = "\xE2\x88\x92"

proc agentHarborPolicies*(): TimelinePolicies =
  ## An Agent Harbor session observed from a front-end: whole log lines, the
  ## operator's input observed.
  TimelinePolicies(chunks: cpWholeLines, operatorInput: oiObserved,
                   gapMs: DefaultGapMs)

proc acpPolicies*(): TimelinePolicies =
  ## A session this front-end runs over ACP: streamed text, the operator's
  ## turn recorded when sent.
  TimelinePolicies(chunks: cpStreamChunks, operatorInput: oiAcknowledge,
                   gapMs: DefaultGapMs)

proc initTimelineFold*(policies = agentHarborPolicies()): TimelineFold =
  TimelineFold(policies: policies)

# ---------------------------------------------------------------------------
# Command traces
# ---------------------------------------------------------------------------

proc commandTraceFromJson*(node: JsonNode): CommandTrace =
  ## A command trace in the proposed shape: `processes` (each `pid`, `ppid`,
  ## `argv`, `cwd`, `exe`, `start_ms`, `end_ms`, `exit_code`, `stdout`,
  ## `stderr`), `raw_output`, and `env` (an object of variables). A variable
  ## whose name `isPrivateKey` names is redacted, as tool arguments are.
  if node.isNil or node.kind != JObject: return
  let processes = node.fieldChild("processes")
  if not processes.isNil and processes.kind == JArray:
    for p in processes:
      var process = TracedProcess(pid: p.fieldInt("pid"),
                                  ppid: p.fieldInt("ppid"),
                                  cwd: p.fieldStr("cwd"), exe: p.fieldStr("exe"),
                                  startMs: p.fieldNum("start_ms"),
                                  stdout: p.fieldStr("stdout"),
                                  stderr: p.fieldStr("stderr"))
      let argv = p.fieldChild("argv")
      if not argv.isNil and argv.kind == JArray:
        for arg in argv:
          if arg.kind == JString: process.argv.add arg.getStr
      let ended = p.fieldChild("end_ms")
      process.endMs = if ended.isNil or ended.kind != JInt: -1'i64
                      else: ended.getBiggestInt.int64
      let exit = p.fieldChild("exit_code")
      if not exit.isNil and exit.kind == JInt:
        process.exitCode = exit.wireInt
        process.hasExit = true
      result.processes.add process
  result.rawOutput = node.fieldStr("raw_output")
  let env = node.fieldChild("env")
  if not env.isNil and env.kind == JObject:
    for name, value in env.pairs:
      let text = if value.kind == JString: value.getStr else: $value
      result.env.add TraceVariable(name: name,
                                   value: if isPrivateKey(name): "[private]" else: text)

proc failedStage*(trace: CommandTrace): int =
  ## The index of the first process that exited non-zero, or -1.
  for i, p in trace.processes:
    if p.hasExit and p.exitCode != 0: return i
  -1

# ---------------------------------------------------------------------------
# Items
# ---------------------------------------------------------------------------

proc isLiveStatusEvent(event: AgentEvent): bool =
  ## A `status` event restating a live session state, with nothing else to say.
  event.sourceType == "status" and event.status in LiveStatuses and
    event.text.len == 0

proc argumentsCommand(arguments: string): string =
  ## The `command` of a tool's (redacted) arguments, or "".
  if arguments.len == 0: return ""
  try:
    let node = parseJson(arguments)
    if node.kind == JObject: return node.fieldStr("command")
  except JsonParsingError, ValueError:
    discard
  ""

proc isQuestionRequest(request: string): bool =
  ## The fallback for a wait no kind event has refined (a server that sends
  ## none, or a kind of `unknown`): a `session_awaiting_input` request that
  ## names a question (`<session>:native-question:<n>`), as opposed to a hook,
  ## such as the agent's stop hook (`claude-stop-hook`), waiting for the turn
  ## to end. The request id is the only thing the wait event itself carries.
  "question" in request.toLowerAscii

proc waitKindOf(kind, request: string): TimelineItemKind =
  ## A wait's item kind: from its kind when the server named one
  ## (`question_pending` a question, `turn_ended` a status line), otherwise
  ## from its request (`isQuestionRequest`).
  case kind
  of "question_pending": tikQuestion
  of "turn_ended": tikStatus
  else: (if isQuestionRequest(request): tikQuestion else: tikStatus)

proc itemKindOf*(event: AgentEvent; policies: TimelinePolicies): TimelineItemKind =
  ## The timeline kind of one event, from its source type, kind, tool name and
  ## arguments, never its text -- except the server's own log conventions under
  ## `cpWholeLines`: a line's level, and its `agent question (…)` form.
  let raw = event.raw
  case event.sourceType
  of "user_input": return tikOperator
  of "file_read": return tikRead
  of "file_edit", "diff":
    return if event.status == "deleted": tikDelete else: tikEdit
  of "plan": return tikPlan
  of "llm_request": return tikModel
  of "sub_agent", "delegation", "orchestration": return tikHarness
  of "agent_question", "login_required": return tikQuestion
  of "session_awaiting_input":
    var request = ""
    for field in event.presentationFields:
      if field.name == "request": request = field.value
    return waitKindOf("", request)
  of "session_resumed": return tikResumed
  of "session_ended":
    for field in event.presentationFields:
      if field.name == "outcome" and field.value == "failed": return tikFailure
    return tikStatus
  of "error": return tikFailure
  else: discard
  case event.kind
  of aekMessageChunk:
    if policies.chunks == cpWholeLines and event.sourceType == "log":
      if raw.fieldStr("level") == "error": return tikFailure
      if questionAgentOf(event.text).len > 0: return tikQuestion
    tikAgent
  of aekThoughtChunk: tikThought
  of aekToolCall, aekToolCallUpdate:
    let name = event.toolName.toLowerAscii
    if name in SearchTools: tikSearch
    elif argumentsCommand(event.toolArguments).len > 0: tikShell
    else: tikTool
  of aekFileEdit, aekDiff: tikEdit
  of aekPlan: tikPlan
  of aekLlmRequest: tikModel
  of aekSubAgent: tikHarness
  of aekError: tikFailure
  of aekCompleted:
    if event.sourceType == "status": tikCompleted else: tikStatus
  of aekCancelled: tikCancelled
  of aekStatus, aekConnection: tikStatus
  else: tikOther

proc stateOf(entry: ActivityEntry; kind: TimelineItemKind; exitCode: int;
             hasExit: bool): TimelineItemState =
  ## A tool's run state from its entry's status and exit code.
  if kind notin {tikRead, tikSearch, tikShell, tikTool}: return tisNone
  if entry.kind == aekToolCall and entry.status in ["started", "pending",
      "in_progress", "running", ""]:
    return tisRunning
  case entry.status.toLowerAscii
  of "failed", "error": tisFailed
  of "cancelled", "stopped", "interrupted": tisCancelled
  of "started", "pending", "in_progress", "running": tisRunning
  else:
    if hasExit and exitCode != 0: tisFailed else: tisOk

proc lineOf(event: AgentEvent; entry: ActivityEntry): string =
  ## The item's line: the shared wording when the event carries its wire form;
  ## otherwise what the entry says (an ACP event).
  if not event.raw.isNil and event.raw.kind == JObject:
    return activityLine(event.raw).text
  case entry.kind
  of aekToolCall, aekToolCallUpdate:
    let command = argumentsCommand(entry.detail)
    if command.len > 0: "Ran " & command.splitLines()[0]
    else: "Called " & (if entry.title.len > 0: entry.title else: "a tool")
  else:
    let text = entry.text.strip
    if text.len > 0: text.splitLines()[0] else: $entry.kind

proc newItem(fold: TimelineFold; index: int; event: AgentEvent;
             kind: TimelineItemKind): TimelineItem =
  let entry = fold.timeline.entries[index]
  let raw = event.raw
  result = TimelineItem(id: entry.id, kind: kind, turn: entry.turn,
                        sourceType: event.sourceType,
                        atMs: (if raw.isNil or raw.fieldChild("timestamp").isNil: -1'i64
                               else: raw.fieldNum("timestamp") div 1000),
                        line: lineOf(event, entry), level: raw.fieldStr("level"),
                        filePath: event.filePath, toolName: event.toolName,
                        toolCallId: event.toolCallId,
                        added: event.linesAdded, removed: event.linesRemoved,
                        entry: index)
  if result.filePath.len == 0:
    for field in event.presentationFields:
      if field.name == "file_path": result.filePath = field.value
  if event.sourceType == "session_awaiting_input":
    result.request = raw.fieldStr("request")
  case kind
  of tikOperator:
    result.body = event.text
    let withheld = raw.fieldChild("withheld")
    if not withheld.isNil and withheld.kind == JArray:
      for name in withheld:
        if name.kind == JString and name.getStr in ["content", "prompt"]:
          result.withheld = true
  of tikAgent, tikFailure:
    var text = entry.text
    if text.startsWith("assistant: "): text = text["assistant: ".len .. ^1]
    result.body = text
  of tikThought:
    result.body = entry.text
  of tikQuestion:
    result.body = event.question
    for field in event.presentationFields:
      if field.name == "option": result.options.add field.value
  of tikCompleted, tikCancelled:
    result.body = event.text
  of tikShell, tikSearch, tikTool:
    result.command = argumentsCommand(event.toolArguments)
  else: discard
  result.state = stateOf(entry, kind, 0, false)

proc refreshItem(fold: var TimelineFold; i: int; event: AgentEvent): bool =
  ## Brings item `i` up to date with its entry after an update; true when it
  ## changed.
  let before = fold.items[i]
  let entry = fold.timeline.entries[fold.items[i].entry]
  var item = fold.items[i]
  if item.kind in {tikAgent, tikFailure}:
    var text = entry.text
    if text.startsWith("assistant: "): text = text["assistant: ".len .. ^1]
    item.body = text
  elif item.kind == tikThought:
    item.body = entry.text
  if event.kind == aekToolCallUpdate and event.toolCallId == item.toolCallId:
    let raw = event.raw
    let exit = raw.fieldChild("exit_code")
    if not exit.isNil and exit.kind == JInt:
      item.exitCode = exit.wireInt
      item.hasExit = true
    let trace = raw.fieldChild("command_trace")
    if not trace.isNil and trace.kind == JObject:
      item.trace = some(commandTraceFromJson(trace))
  item.state = stateOf(entry, item.kind, item.exitCode, item.hasExit)
  fold.items[i] = item
  item != before

# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------

proc groupKindOf(kind: TimelineItemKind): TimelineGroupKind =
  case kind
  of tikRead: tgkRead
  of tikSearch: tgkSearch
  of tikShell: tgkShell
  of tikEdit: tgkEdit
  else: tgkRepeat

proc previousEvent(items: openArray[TimelineItem]; i: int): int =
  ## The index of the last item before `i` that is not a test run, or -1:
  ## a test run's line takes no part in the gaps between event lines.
  result = i - 1
  while result >= 0 and items[result].kind == tikTestRun: dec result

proc gapBefore(items: openArray[TimelineItem]; i: int; gapMs: int64): bool =
  ## Whether a gap line goes before item `i`. Never before a test run's
  ## line, and measured from the last event item, past any test run.
  if i <= 0 or gapMs <= 0 or items[i].kind == tikTestRun: return false
  let p = items.previousEvent(i)
  p >= 0 and items[i].atMs >= 0 and items[p].atMs >= 0 and
    items[i].atMs - items[p].atMs >= gapMs

proc summarize(node: var TimelineNode; items: openArray[TimelineItem]) =
  ## A group's counts, from its items.
  node.count = 0
  node.failed = 0
  node.running = 0
  node.added = 0
  node.removed = 0
  node.runningItem = ""
  let kind = items[node.first].kind
  for i in node.first .. node.last:
    let item = items[i]
    if node.groupKind != tgkRepeat and item.kind != kind: continue
    inc node.count
    if item.state == tisFailed: inc node.failed
    if item.state == tisRunning:
      inc node.running
      node.runningItem = item.id
    node.added += item.added
    node.removed += item.removed

proc groupNode(items: openArray[TimelineItem]; first, last: int;
               kind: TimelineGroupKind): TimelineNode =
  result = TimelineNode(id: "group:" & items[first].id, kind: tnGroup,
                        first: first, last: last, groupKind: kind)
  result.summarize(items)

proc buildNodes(items: openArray[TimelineItem]; start: int;
                gapMs: int64): seq[TimelineNode] =
  ## The nodes of `items[start .. ^1]`, given that a node ends just before
  ## `start` (a gap before `start` included).
  var i = start
  while i < items.len:
    let item = items[i]
    if items.gapBefore(i, gapMs):
      result.add TimelineNode(id: "gap:" & item.id, kind: tnGap, first: i,
                              last: i - 1,
                              gapMs: item.atMs - items[items.previousEvent(i)].atMs)
    if item.kind == tikOperator:
      result.add TimelineNode(id: item.id, kind: tnTurn, first: i, last: i)
      inc i
      continue
    if item.kind in GroupableKinds:
      var lastSame = i
      var count = 1
      var j = i + 1
      while j < items.len and not items.gapBefore(j, gapMs):
        let k = items[j].kind
        if k == item.kind:
          lastSame = j
          inc count
        elif k notin FoldedKinds:
          break
        inc j
      if count >= 2:
        result.add groupNode(items, i, lastSame, groupKindOf(item.kind))
        i = lastSame + 1
        continue
    elif item.kind == tikStatus:
      var j = i + 1
      while j < items.len and not items.gapBefore(j, gapMs) and
          items[j].kind == tikStatus and items[j].line == item.line and
          items[j].level == item.level:
        inc j
      if j - i >= 2:
        result.add groupNode(items, i, j - 1, tgkRepeat)
        i = j
        continue
    result.add TimelineNode(id: item.id, kind: tnItem, first: i, last: i)
    inc i

proc nodesOf*(items: openArray[TimelineItem];
              gapMs = DefaultGapMs): seq[TimelineNode] =
  ## The closed form: the nodes of a whole item list.
  buildNodes(items, 0, gapMs)

proc openTail(fold: TimelineFold): int =
  ## The index of the first node an append may still change: trailing
  ## thoughts and model requests, and the groupable or status line (single,
  ## or a group) before them, with a gap line just before that. Every node
  ## before it is settled.
  var k = fold.nodes.len
  while k > 0 and fold.nodes[k - 1].kind == tnItem and
      fold.items[fold.nodes[k - 1].first].kind in FoldedKinds:
    dec k
  if k > 0:
    let node = fold.nodes[k - 1]
    if node.kind == tnGroup or (node.kind == tnItem and
        fold.items[node.first].kind in GroupableKinds + {tikStatus}):
      dec k
  if k > 0 and k < fold.nodes.len and fold.nodes[k - 1].kind == tnGap:
    dec k
  k

proc rebuildTail(fold: var TimelineFold) =
  ## Re-derives the open tail's nodes, after an append.
  let k = fold.openTail
  let start = if k < fold.nodes.len: fold.nodes[k].first
              else: fold.items.len - 1
  fold.nodes.setLen(k)
  fold.nodes.add buildNodes(fold.items, start, fold.policies.gapMs)

proc resummarize(fold: var TimelineFold; itemIndex: int) =
  ## Updates the counts of the group holding item `itemIndex`.
  for node in fold.nodes.mitems:
    if node.kind == tnGroup and node.first <= itemIndex and itemIndex <= node.last:
      node.summarize(fold.items)

proc nodeStart(items: openArray[TimelineItem]; node: TimelineNode): int64 =
  ## When a node starts: its first item's time (a gap's is the item after
  ## it); -1 when that item has none.
  if node.first < items.len: items[node.first].atMs else: -1'i64

proc arrange(fold: var TimelineFold) =
  ## Places the test runs among the event lines (`shown`, `shownNodes`):
  ## each run after the last event node that started at or before it (a
  ## node with no time counts as starting with the node before it), runs of
  ## one place in their start order and then in the order applied; a run
  ## with no start time last. The event nodes are kept as they are, only
  ## renumbered, so a run never splits, joins or recounts a group.
  fold.shown.setLen(0)
  fold.shownNodes.setLen(0)
  fold.shownIndex.clear()
  if fold.runs.len == 0: return
  let n = fold.nodes.len
  var slots = newSeq[seq[int]](n + 1)     # runs to place before event node k
  var effective = newSeq[int64](n)
  var last = low(int64)
  for k, node in fold.nodes:
    let t = fold.items.nodeStart(node)
    if t >= 0: last = t
    effective[k] = last
  var order = newSeq[int](fold.runs.len)
  for r in 0 ..< fold.runs.len: order[r] = r
  # Insertion sort by start time (none: last), stable on the order applied.
  proc startKey(item: TimelineItem): int64 =
    if item.atMs < 0: high(int64) else: item.atMs
  for a in 1 ..< order.len:
    var b = a
    while b > 0 and fold.runs[order[b - 1]].startKey > fold.runs[order[b]].startKey:
      swap(order[b - 1], order[b])
      dec b
  for r in order:
    let t = fold.runs[r].atMs
    var slot = n
    if t >= 0:
      slot = 0
      for k in 0 ..< n:
        if effective[k] <= t: slot = k + 1
    slots[slot].add r
  var turn = 0
  proc boundary(fold: TimelineFold; k: int): int =
    if k < fold.nodes.len: fold.nodes[k].first else: fold.items.len
  var next = 0
  for k in 0 .. n:
    let upTo = fold.boundary(k)
    while next < upTo:
      turn = fold.items[next].turn
      fold.shown.add fold.items[next]
      inc next
    for r in slots[k]:
      var run = fold.runs[r]
      run.turn = turn
      fold.shownNodes.add TimelineNode(id: run.id, kind: tnItem,
                                       first: fold.shown.len, last: fold.shown.len)
      fold.shown.add run
    if k < n:
      var node = fold.nodes[k]
      let shift = fold.shown.len - upTo
      node.first += shift
      node.last += shift
      fold.shownNodes.add node
  for i, item in fold.shown: fold.shownIndex[item.id] = i

# ---------------------------------------------------------------------------
# The fold
# ---------------------------------------------------------------------------

proc addItem(fold: var TimelineFold; event: AgentEvent;
             kind: TimelineItemKind; change: var TimelineChange) =
  ## A new item for the reducer's last entry.
  let index = fold.timeline.entries.high
  var item = fold.newItem(index, event, kind)
  if kind in {tikOperator, tikResumed}:
    # The operator's input answers every question before it.
    for i in 0 ..< fold.items.len:
      if fold.items[i].kind == tikQuestion and not fold.items[i].answered:
        fold.items[i].answered = true
        change.updated.add fold.items[i].id
  fold.byEntry[item.id] = fold.items.len
  fold.items.add item
  inc change.newItems
  fold.rebuildTail()

proc refineWait(fold: var TimelineFold; event: AgentEvent;
                change: var TimelineChange) =
  ## A wait's kind (`session_awaiting_input_kind`, which the server sends
  ## right after the wait it refines, with the same request) is no line of
  ## its own: it settles whether the newest wait with that request, not yet
  ## refined, is a question or a status line.
  let request = event.raw.fieldStr("request")
  let kind = event.raw.fieldStr("kind")
  for i in countdown(fold.items.high, 0):
    if fold.items[i].sourceType != "session_awaiting_input" or
        fold.items[i].request != request or fold.items[i].waitKind.len > 0:
      continue
    let before = fold.items[i]
    var item = before
    item.waitKind = if kind.len > 0: kind else: "unknown"
    item.kind = waitKindOf(item.waitKind, request)
    if item.kind == tikQuestion and before.kind != tikQuestion:
      # A question the operator already answered stays answered.
      for j in i + 1 .. fold.items.high:
        if fold.items[j].kind in {tikOperator, tikResumed}:
          item.answered = true
          break
    fold.items[i] = item
    if item != before:
      change.updated.add item.id
      if item.kind != before.kind:
        fold.nodes = nodesOf(fold.items, fold.policies.gapMs)
    return

proc apply*(fold: var TimelineFold; event: AgentEvent): TimelineChange =
  ## Folds one event. Its `raw` wire form, when present, gives the item's
  ## line, timestamp, level and command trace.
  if event.eventId.len > 0:
    let identity = event.sessionId & ":" & event.eventId
    if identity in fold.seen: return
    fold.seen.incl identity
  if event.isLiveStatusEvent: return
  if event.sourceType == AwaitingKindEvent:
    fold.refineWait(event, result)
    result.changed = result.updated.len > 0
    if result.changed:
      inc fold.revision
      if fold.runs.len > 0: fold.arrange()
    return
  let kind = itemKindOf(event, fold.policies)
  var data = event
  data.raw = nil
  if event.sourceType == "user_input":
    if fold.policies.operatorInput == oiAcknowledge: return
    fold.timeline.beginTurn(event.text)
    fold.timeline.entries[^1].data = data
    fold.addItem(event, tikOperator, result)
  elif event.kind in {aekMessageChunk, aekThoughtChunk} and
      fold.policies.chunks == cpWholeLines:
    # Whole lines: each log line and each thought is its own entry, never
    # merged into the one before.
    if event.text.len == 0: return
    let role = if event.kind == aekMessageChunk: arAssistant else: arActivity
    fold.timeline.appendEntry(ActivityEntry(role: role, kind: event.kind,
      data: data, text: event.text, status: "completed"))
    fold.addItem(event, kind, result)
  else:
    let before = fold.timeline.entries.len
    if not fold.timeline.reduce(event): return
    if fold.timeline.entries.len > before:
      fold.addItem(event, kind, result)
    else:
      # An update in place: a tool call's result, or streamed text merged
      # into the entry before.
      var target = -1
      if event.kind in {aekToolCall, aekToolCallUpdate} and event.toolCallId.len > 0:
        for i in countdown(fold.items.high, 0):
          if fold.items[i].toolCallId == event.toolCallId:
            target = i
            break
      elif fold.items.len > 0:
        target = fold.items.high
      if target >= 0:
        let oldKind = fold.items[target].kind
        if fold.refreshItem(target, event):
          result.updated.add fold.items[target].id
        if fold.items[target].kind != oldKind:
          fold.nodes = nodesOf(fold.items, fold.policies.gapMs)
        else:
          fold.resummarize(target)
    # A terminal event settles streamed prose of the turn.
    if event.kind in {aekCompleted, aekCancelled, aekError}:
      for i in 0 ..< fold.items.len:
        if fold.items[i].turn == fold.timeline.turn and
            fold.items[i].kind in {tikAgent, tikThought}:
          discard fold.refreshItem(i, event)
  result.changed = result.newItems > 0 or result.updated.len > 0
  if result.changed:
    inc fold.revision
    if fold.runs.len > 0: fold.arrange()

proc applyJson*(fold: var TimelineFold; sessionId: string;
                event: JsonNode): TimelineChange =
  ## Folds one Agent Harbor event as its stream sends it (`type`,
  ## `timestamp`, its own fields): decoded by nim-agent-harbor and projected
  ## by `harborEventToAgentEvent`, which keeps its wire form for the line.
  if event.isNil or event.kind != JObject: return
  fold.apply(harborEventToAgentEvent(sessionId, eventFromJson(event)))

proc testRunItemId*(runId: string): string =
  ## A test run's item id (and its line's node id).
  "test-run:" & runId

proc applyTestRun*(fold: var TimelineFold; runId: string; startedMs: int64;
                   line: string; state = tisNone; body = ""): TimelineChange =
  ## Folds a test run of the session as one item, `tikTestRun`, at its start
  ## (milliseconds since the session started; -1 when unknown), with the line
  ## the caller words (`test_runs.summaryLine`), its state (`tisRunning`
  ## while a platform runs, then `tisOk` or `tisFailed`) and an optional
  ## body. Applying the same run again updates it in place; its start time
  ## is the first one given. No other line changes (see the module comment).
  if runId.len == 0: return
  let id = testRunItemId(runId)
  var at = -1
  for i, run in fold.runs:
    if run.id == id: at = i
  if at < 0:
    fold.runs.add TimelineItem(id: id, kind: tikTestRun, atMs: startedMs, line: line,
                               sourceType: "test-run", body: body, state: state,
                               testRunId: runId, entry: -1)
    inc result.newItems
  else:
    var run = fold.runs[at]
    run.line = line
    run.state = state
    run.body = body
    if run == fold.runs[at]: return
    fold.runs[at] = run
    result.updated.add id
  result.changed = true
  inc fold.revision
  fold.arrange()

# ---------------------------------------------------------------------------
# Reading the fold
# ---------------------------------------------------------------------------

# What a reader sees: the event items and nodes as they are, or, once a test
# run has been applied, the arrangement that places the runs among them.

proc items*(fold: TimelineFold): seq[TimelineItem] =
  if fold.runs.len == 0: fold.items else: fold.shown
proc nodes*(fold: TimelineFold): seq[TimelineNode] =
  if fold.runs.len == 0: fold.nodes else: fold.shownNodes
proc itemCount*(fold: TimelineFold): int =
  if fold.runs.len == 0: fold.items.len else: fold.shown.len
proc timeline*(fold: TimelineFold): ActivityTimeline = fold.timeline

proc item*(fold: TimelineFold; index: int): TimelineItem =
  if fold.runs.len == 0: fold.items[index] else: fold.shown[index]

proc findItem*(fold: TimelineFold; id: string): int =
  ## The index of the item `id`, or -1.
  if fold.runs.len == 0: fold.byEntry.getOrDefault(id, -1)
  else: fold.shownIndex.getOrDefault(id, -1)

proc findNode*(fold: TimelineFold; id: string): int =
  ## The index of the top-level node `id`, or -1.
  let shown = if fold.runs.len == 0: fold.nodes else: fold.shownNodes
  for i, node in shown:
    if node.id == id: return i
  -1

proc testRuns*(fold: TimelineFold): seq[TimelineItem] =
  ## The test-run items, in the order first applied.
  fold.runs

proc isSessionEnding*(item: TimelineItem): bool =
  ## The session's own ending (a `status` or `session_ended` event), as
  ## opposed to an agent's failure or any other line.
  item.sourceType in SessionEndings

proc repeatsFault*(fold: TimelineFold; index: int): bool =
  ## Whether item `index` is a session's failed ending that repeats the
  ## failure right before it (one fault is red once): a `tikFailure` that is
  ## a session ending, whose item before is a `tikFailure` (the agent's own,
  ## or another ending). Read from the items, so a filter over the lines
  ## does not change it.
  if index <= 0 or index >= fold.itemCount: return false
  var prev = index - 1
  while prev >= 0 and fold.item(prev).kind == tikTestRun: dec prev
  fold.item(index).kind == tikFailure and fold.item(index).isSessionEnding and
    prev >= 0 and fold.item(prev).kind == tikFailure

proc itemsOf*(fold: TimelineFold; node: TimelineNode): seq[TimelineItem] =
  ## A node's items (none for a gap).
  for i in node.first .. node.last: result.add fold.item(i)

proc summary*(node: TimelineNode): string =
  ## A group line's words: `Read 4 files`, `Searched 3 times`, `Ran 2 shell
  ## commands`, `Edited 3 files`; a repeat group says nothing here (its line
  ## is its items' line, `repeatText`).
  let n = node.count
  case node.groupKind
  of tgkRead: "Read " & $n & (if n == 1: " file" else: " files")
  of tgkSearch: "Searched " & $n & (if n == 1: " time" else: " times")
  of tgkShell: "Ran " & $n & (if n == 1: " shell command" else: " shell commands")
  of tgkEdit: "Edited " & $n & (if n == 1: " file" else: " files")
  of tgkRepeat: ""

proc failedText*(node: TimelineNode): string =
  ## `(1 failed)`, or "".
  if node.failed > 0: "(" & $node.failed & " failed)" else: ""

proc totalsText*(node: TimelineNode): string =
  ## An edit group's `+40 −12`, or "".
  if node.groupKind == tgkEdit and node.added + node.removed > 0:
    "+" & $node.added & " " & Minus & $node.removed
  else: ""

proc nodeText*(fold: TimelineFold; node: TimelineNode): string =
  ## A node's whole line as one string: a group's summary with its totals and
  ## failures, a repeat's line with `×N`, an item's line, a gap's length.
  case node.kind
  of tnGap:
    let minutes = node.gapMs div 60_000
    if minutes >= 60: $(minutes div 60) & " h later" else: $minutes & " min later"
  of tnTurn, tnItem: fold.item(node.first).line
  of tnGroup:
    if node.groupKind == tgkRepeat:
      fold.item(node.first).line & Times & $node.count
    else:
      var parts = @[node.summary]
      if node.totalsText.len > 0: parts.add node.totalsText
      if node.failedText.len > 0: parts.add node.failedText
      parts.join(" ")

proc detailOf*(fold: TimelineFold; id: string): TimelineDetail =
  ## Level 2 of the item `id`: its facts, redacted arguments, output, diff and
  ## body. An unknown id has no detail.
  let i = fold.findItem(id)
  if i < 0: return
  let item = fold.item(i)
  if item.kind == tikTestRun:
    # A test run has no reducer entry: its detail is its body.
    result.body = item.body
    return
  let entry = fold.timeline.entries[item.entry]
  result.facts = activityPresentation(entry).facts
  result.body = item.body
  result.options = item.options
  result.hasTrace = item.trace.isSome
  case entry.kind
  of aekToolCall, aekToolCallUpdate:
    result.arguments = entry.detail
    result.output = entry.text
  of aekDiff:
    result.diff = entry.data.diff
  else: discard
  if item.kind == tikEdit and result.diff.len == 0:
    result.diff = entry.data.diff
