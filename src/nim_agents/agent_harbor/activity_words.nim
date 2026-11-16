## The one-line wording of an Agent Harbor session event: what a fleet row's
## activity line, a tab's tooltip and a session's activity timeline all say
## for the same event ("Ran just test", "Read src/app.nim", "Edited
## src/app.nim +4 −2", "Asked a single-choice question", "Waiting for input
## (claude stop hook)", "Plan: 3 steps, 1 done, 1 in progress").
##
## It is one function (`activityLine`) so that every view says the same words
## for the same event: `fleet_records.activityFromJson` builds a fleet
## activity from it, and `nim_agents/activity_groups` takes a timeline
## item's line from it.
##
## The words are built from the event's structured fields only. A question's
## prompt and options, and an instruction's content, are never part of the
## line, because a fleet listing's caller may not own the session; a view
## that shows a session's own content (its timeline) shows that content
## beside the line, never inside it.
##
## Signal-free and app-agnostic; identical on the C and JS targets.

import std/[json, strutils]

type
  FleetActivityKind* = enum
    fakQuestion          ## `agent_question`
    fakAwaitingInput     ## `session_awaiting_input`
    fakResumed           ## `session_resumed`
    fakStatus            ## `status`
    fakLog               ## `log`
    fakOrchestration     ## `orchestration`
    fakAntiHalting       ## `anti_halting_resume_confirmed`
    fakThought           ## `thought`
    fakToolUse           ## `tool_use` (a tool call started)
    fakToolResult        ## `tool_result`
    fakFileEdit          ## `file_edit`, `diff`
    fakFileRead          ## `file_read`
    fakPlan              ## `plan`
    fakUserInput         ## `user_input` (an instruction the operator sent)
    fakOther             ## anything else, shown by its wire type

  ActivityLine* = object
    ## One event's line: its kind, the words, and a log line's level
    ## (`info`, `warn`, `error`; a failed tool result reads `error`).
    kind*: FleetActivityKind
    eventType*: string     ## the wire `type`
    text*: string
    level*: string

proc fieldStr*(node: JsonNode; key: string): string =
  ## A string field, or "" when it is absent, null or not a string.
  if node.isNil or node.kind != JObject: return ""
  let value = node.getOrDefault(key)
  if value.isNil or value.kind != JString: "" else: value.getStr

proc fieldNum*(node: JsonNode; key: string): int64 =
  ## An integer field (a float is truncated), or 0.
  if node.isNil or node.kind != JObject: return 0
  let value = node.getOrDefault(key)
  if value.isNil: return 0
  case value.kind
  of JInt: value.getBiggestInt.int64
  of JFloat: value.getFloat.int64
  else: 0

proc fieldFlag*(node: JsonNode; key: string): bool =
  ## A boolean field; false when absent or not a boolean.
  if node.isNil or node.kind != JObject: return false
  let value = node.getOrDefault(key)
  not value.isNil and value.kind == JBool and value.getBool

proc fieldChild*(node: JsonNode; key: string): JsonNode =
  ## A field of any kind, or nil.
  if node.isNil or node.kind != JObject: return nil
  node.getOrDefault(key)

proc requestLabel*(request: string): string =
  ## A readable name for an input request id. The server names a request
  ## either by its source (`claude-stop-hook`) or as
  ## `<session id>:<kind>:<sequence>`; the ids and sequence numbers mean
  ## nothing to a reader, so only the words are kept, dashes as spaces
  ## (`native question`, `claude stop hook`).
  var words: seq[string]
  for part in request.split(':'):
    let p = part.strip
    if p.len == 0 or p.allCharsInSet(Digits): continue
    # A UUID (8-4-4-4-12 hex digits) names a session, not a request kind.
    if p.len == 36 and p.count('-') == 4 and
        p.allCharsInSet(HexDigits + {'-'}): continue
    words.add(p.replace('-', ' ').replace('_', ' '))
  words.join(" ")

const AgentQuestionLogPrefix* = "agent question ("
  ## How Agent Harbor logs an agent's question: `agent question (<agent>):
  ## tool=<tool name>`.

proc questionAgentOf*(logMessage: string): string =
  ## The agent named by a question log line (`agent question (<agent>): …`),
  ## or "" when the line is not one.
  let close = logMessage.find(')')
  if logMessage.startsWith(AgentQuestionLogPrefix) and
      close > AgentQuestionLogPrefix.len:
    logMessage[AgentQuestionLogPrefix.len ..< close]
  else:
    ""

proc activityLine*(node: JsonNode): ActivityLine =
  ## The line for one session event (its wire JSON).
  let eventType = node.fieldStr("type")
  result = ActivityLine(eventType: eventType, level: node.fieldStr("level"))
  case eventType
  of "agent_question":
    result.kind = fakQuestion
    let kind = node.fieldStr("kind").replace('_', '-')
    result.text = "Asked a " & (if kind.len > 0: kind else: "") &
      (if kind.len > 0: " question" else: "question")
  of "session_awaiting_input":
    result.kind = fakAwaitingInput
    let request = requestLabel(node.fieldStr("request"))
    result.text = "Waiting for input" &
      (if request.len > 0: " (" & request & ")" else: "")
  of "session_resumed":
    result.kind = fakResumed
    let by = node.fieldStr("deliverer")
    result.text = "Resumed" & (if by.len > 0: " by " & by else: "")
  of "status":
    result.kind = fakStatus
    result.text = "Status: " & node.fieldStr("status")
  of "log":
    result.kind = fakLog
    let message = node.fieldStr("message")
    # The tool name in a question log line is the agent's implementation
    # detail, so the line reads as the question it stands for, as
    # `agent_question` does; the question's own words are not in the line.
    let agent = questionAgentOf(message)
    if agent.len > 0:
      result.kind = fakQuestion
      result.text = "Asked a question (" & agent & ")"
    else:
      result.text = message
  of "orchestration":
    result.kind = fakOrchestration
    result.text = node.fieldStr("description")
    let model = node.fieldChild("payload").fieldStr("model")
    if model.len > 0:
      result.text.add(": " & model)
  of "anti_halting_resume_confirmed":
    result.kind = fakAntiHalting
    let stall = node.fieldStr("stallType").replace('_', ' ')
    result.text = "Anti-halting resumed a stalled turn" &
      (if stall.len > 0 and stall != "unknown": " (" & stall & ")" else: "")
  of "thought":
    result.kind = fakThought
    let thought = node.fieldStr("thought").strip
    result.text = "Thinking" &
      (if thought.len > 0: ": " & thought.splitLines()[0] else: "")
  of "tool_use":
    result.kind = fakToolUse
    let tool = node.fieldStr("tool_name")
    let args = node.fieldChild("tool_args")
    let command = args.fieldStr("command")
    let path = args.fieldStr("path")
    result.text =
      if command.len > 0: "Ran " & command.splitLines()[0]
      elif path.len > 0: (if tool.len > 0: tool else: "Tool") & " " & path
      else: "Called " & (if tool.len > 0: tool else: "a tool")
  of "tool_result":
    result.kind = fakToolResult
    let tool = node.fieldStr("tool_name")
    let failed = node.fieldStr("status") in ["failed", "error"]
    result.text = (if tool.len > 0: tool else: "Tool") &
      (if failed: " failed" else: " finished")
    if failed: result.level = "error"
  of "file_edit", "diff":
    result.kind = fakFileEdit
    let added = node.fieldNum("lines_added")
    let removed = node.fieldNum("lines_removed")
    let path = node.fieldStr("file_path")
    result.text =
      if node.fieldStr("status") == "deleted": "Deleted " & path
      else: "Edited " & path &
        (if added + removed > 0: " +" & $added & " \xE2\x88\x92" & $removed else: "")
  of "file_read":
    result.kind = fakFileRead
    result.text = "Read " & node.fieldStr("file_path")
  of "plan":
    result.kind = fakPlan
    let entries = node.fieldChild("entries")
    var total, active, done = 0
    if not entries.isNil and entries.kind == JArray:
      for entry in entries:
        inc total
        case entry.fieldStr("status")
        of "in_progress": inc active
        of "completed": inc done
        else: discard
    result.text = (if node.fieldFlag("is_update"): "Plan updated: " else: "Plan: ") &
      $total & " steps, " & $done & " done, " & $active & " in progress"
  of "user_input":
    # The instruction itself may quote private prompt text: named, never echoed.
    result.kind = fakUserInput
    result.text = "Instruction sent"
  of "sub_agent":
    result.kind = fakOther
    let message = node.fieldStr("message").strip
    result.text = "Sub-agent" & (if message.len > 0: ": " & message.splitLines()[0] else: "")
  of "delegation":
    result.kind = fakOther
    let kind = node.fieldStr("kind").replace('_', ' ')
    let active = node.fieldNum("activeSubAgents")
    let total = node.fieldNum("totalSubAgents")
    result.text = "Delegation" & (if kind.len > 0: " " & kind else: "") &
      (if total > 0: " (" & $active & " of " & $total & " agents active)" else: "")
  of "llm_request":
    result.kind = fakOther
    let model = node.fieldStr("model")
    result.text = "Model request" & (if model.len > 0: " (" & model & ")" else: "")
  of "error":
    result.kind = fakOther
    let message = node.fieldStr("message").strip
    result.text = "Error" & (if message.len > 0: ": " & message.splitLines()[0] else: "")
    result.level = "error"
  of "session_ended":
    result.kind = fakOther
    let outcome = node.fieldStr("outcome").replace('_', ' ')
    result.text = "Session ended" & (if outcome.len > 0: " (" & outcome & ")" else: "")
  else:
    result.kind = fakOther
    result.text = eventType.replace('_', ' ')
