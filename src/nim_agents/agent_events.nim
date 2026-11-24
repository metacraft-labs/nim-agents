## The agent event: what a front-end shows of one ACP or Agent Harbor event,
## and the projections that produce it from each backend's own frames.
##
## `AgentEvent` is the safe projection of one backend event: the fields a
## conversation or activity view renders, with credential and configuration
## values removed (`isPrivateKey`) and the backend's frame kept only in `raw`.
## `harborEventToAgentEvent` projects an Agent Harbor event
## (`nim_agent_harbor/types.HarborEvent`), `acpUpdateToAgentEvent` an ACP
## session update (`nim_acp/types.SessionUpdate`), and `toJson` /
## `agentEventFromJson` carry an event across a process boundary.
##
## **Transport-free.** This module imports the two backends' type modules and
## nothing else of them: not the ACP client (which spawns agents through
## `std/osproc`) and not the Agent Harbor client or its native HTTP transport
## (`nim_agent_harbor/native`, over `std/httpclient` and `std/asyncdispatch`).
## That is what lets the activity modules (`activity`, `activity_presentation`,
## `activity_groups`), which see a session only through `AgentEvent`, compile
## in a build that links no host module, such as CodeTracer's host-free
## ViewModel build. Keep it so: a transport belongs in `nim_agents/client`.
## `tests/test_activity_modules_are_transport_free.nim` checks it.
##
## `nim_agents/client` imports and re-exports this module, so every caller of
## the client sees these names where it always has.
import std/[json, strutils]
import nim_acp/types
import nim_agent_harbor/types

type
  AgentConnectionState* = enum
    acsDisconnected = "disconnected"
    acsConnecting = "connecting"
    acsAuthenticating = "authenticating"
    acsConnected = "connected"
    acsStreaming = "streaming"
    acsRetrying = "retrying"
    acsCancelling = "cancelling"
    acsCancelled = "cancelled"
    acsCompleted = "completed"
    acsError = "error"
  AgentEventKind* = enum
    aekConnection = "connection"
    aekMessageChunk = "message_chunk"
    aekThoughtChunk = "thought_chunk"
    aekPlan = "plan"
    aekToolCall = "tool_call"
    aekToolCallUpdate = "tool_call_update"
    aekFileEdit = "file_edit"
    aekDiff = "diff"
    aekMilestoneProgress = "milestone_progress"
    aekWorkspaceReady = "workspace_ready"
    aekDelivery = "delivery"
    aekReview = "review"
    aekLlmRequest = "llm_request"
    aekSubAgent = "sub_agent"
    aekStatus = "status"
    aekError = "error"
    aekCancelled = "cancelled"
    aekCompleted = "completed"
  AgentPresentationField* = object
    name*, value*: string
  AgentEvent* = object
    sessionId*: string
    kind*: AgentEventKind
    state*: AgentConnectionState
    text*: string
    status*: string
    toolCallId*: string
    toolName*: string
    filePath*: string
    line*: int
    linesAdded*: int
    linesRemoved*: int
    diff*: string
    reviewSeverity*: string
    reviewCategory*: string
    planEntries*: seq[string]
    milestoneCompleted*: int
    milestoneTotal*: int
    workspacePath*: string
    workingCopyMode*: string
    stopReason*: StopReason
    presentationFields*: seq[AgentPresentationField]
    sourceType*: string ## Safe backend event discriminator, never inferred from text.
    eventId*: string ## Durable stream identity when the backend provides it.
    toolArguments*: string ## Presentation copy with credential/config fields removed.
    model*, usageSource*: string
    inputTokens*, outputTokens*: int
    hasUsage*: bool
    question*: string
    raw*: JsonNode

proc stopReasonFromStatus(status: string): StopReason =
  case status
  of "cancelled", "stopped": srCancelled
  of "failed", "error": srError
  else: srEndTurn

proc connectionEvent*(state: AgentConnectionState; sessionId = "";
    text = ""): AgentEvent =
  AgentEvent(sessionId: sessionId, kind: aekConnection, state: state, text: text)

proc stateFromStatus(status: string): AgentConnectionState =
  case status
  of "connecting": acsConnecting
  of "authenticating": acsAuthenticating
  of "connected": acsConnected
  of "streaming", "ready", "running", "provisioning": acsStreaming
  of "retrying": acsRetrying
  of "cancelling": acsCancelling
  of "cancelled": acsCancelled
  of "completed": acsCompleted
  of "failed", "error": acsError
  else: acsStreaming

proc lineFromRaw(raw: JsonNode): int =
  raw{"line"}.getInt(raw{"line_start"}.getInt(raw{"start_line"}.getInt(0)))

proc jsonArrayStrings(node: JsonNode; field: string): seq[string] =
  for entry in node{field}.items:
    result.add entry{"content"}.getStr(entry.getStr(""))

proc progressFromRaw(raw: JsonNode): tuple[done: int; total: int] =
  result.done = raw{"completed"}.getInt(raw{"completedMilestones"}.getInt(
    raw{"done"}.getInt(0)))
  result.total = raw{"total"}.getInt(raw{"totalMilestones"}.getInt(0))

proc isPrivateKey*(key: string): bool =
  ## Whether a field or variable named `key` holds a value that must not cross
  ## the presentation boundary (a credential, an environment, configuration).
  ## The one rule for tool arguments and for a command trace's environment.
  let name = key.toLowerAscii()
  name.contains("token") or name.contains("password") or
    name.contains("secret") or name.contains("credential") or
    name in ["env", "environment", "authorization", "headers", "settings", "config"]

proc presentationArguments(node: JsonNode): JsonNode =
  ## Tool arguments are content, but environment/config/auth values must not cross
  ## the presentation boundary. Preserve structure while removing these fields.
  if node == nil: return newJNull()
  case node.kind
  of JObject:
    result = newJObject()
    for key, value in node.pairs:
      if isPrivateKey(key):
        result[key] = %"[private]"
      else: result[key] = presentationArguments(value)
  of JArray:
    result = newJArray()
    for value in node.items: result.add presentationArguments(value)
  else: result = node

proc harborEventToAgentEvent*(sessionId: string;
    event: HarborEvent): AgentEvent =
  result.sessionId = sessionId
  result.status = event.status
  result.raw = event.raw
  result.sourceType = event.raw{"type"}.getStr($event.kind)
  result.eventId = event.raw{"eventId"}.getStr("")
  # Explicit presentation allowlists for the full SessionEvent REST union.
  # Credential-account names, auth surfaces, provider configuration and arbitrary
  # payload/innerEvent objects never enter this projection.
  let fields = case result.sourceType
    of "llm_request": @["messageCount", "hasToolCalls"]
    of "tool_result": @["exit_code"]
    of "file_read": @["file_path", "start_line", "end_line"]
    of "diff": @["oldText", "newText", "oldTextHead", "oldTextTail", "newTextHead", "newTextTail", "truncated"]
    of "turn_complete": @["stop_reason", "input_tokens", "output_tokens"]
    of "delegation": @["kind", "activeSubAgents", "totalSubAgents"]
    of "orchestration": @["kind", "targetSessionId"]
    of "sub_agent": @["subAgentId", "parentSessionId"]
    of "fleet_fence": @["kind", "fenceId", "durationMs"]
    of "fleet_host": @["kind", "host", "os", "command", "exitCode", "stream"]
    of "session_awaiting_input", "agent_question": @["request", "kind"]
    of "session_resumed": @["deliverer"]
    of "session_ended": @["outcome"]
    of "proxy_credential_rotated": @["provider", "triggerStatus"]
    of "proxy_rate_limit_absorbed": @["attempts", "cumulativeWaitMs"]
    of "dispatcher_restarted": @["restartSeq"]
    of "anti_halting_resume_confirmed": @["stallType"]
    of "session_leadership_migrated": @["sourceExecutor", "targetExecutor", "targetOs", "flushedSeq"]
    of "participant": @["kind", "display_name", "transition"]
    of "context_injection": @["tag"]
    of "login_required": @["provider", "request"]
    of "context_files": @["kind", "totalCount"]
    else: newSeq[string]()
  for key in fields:
    let value = event.raw{key}
    if value != nil and value.kind in {JString, JInt, JBool}:
      result.presentationFields.add AgentPresentationField(name: key,
        value: if value.kind == JString: value.getStr() else: $value)
  if result.sourceType == "context_files":
    let files = event.raw{"files"}
    if files != nil and files.kind == JArray:
      for file in files.items:
        if file{"path"} != nil and file{"path"}.kind == JString:
          result.presentationFields.add AgentPresentationField(name: "file", value: file{"path"}.getStr())
  if result.sourceType == "agent_question":
    let options = event.raw{"options"}
    if options != nil and options.kind == JArray:
      for option in options.items:
        let label = option{"label"}.getStr("")
        if label.len > 0:
          result.presentationFields.add AgentPresentationField(name: "option", value: label)
  if result.sourceType == "plan":
    let entries = event.raw{"entries"}
    if entries != nil and entries.kind == JArray:
      for entry in entries.items:
        let content = entry{"content"}.getStr("")
        let status = entry{"status"}.getStr("")
        if content.len > 0 and status.len > 0:
          result.presentationFields.add AgentPresentationField(name: content, value: status)
  if result.sourceType == "link_spans":
    let spans = event.raw{"spans"}
    if spans != nil and spans.kind == JArray:
      for span in spans.items:
        let targets = span{"targets"}
        if targets != nil and targets.kind == JArray:
          for target in targets.items:
            let path = target{"path"}.getStr("")
            if path.len > 0:
              result.presentationFields.add AgentPresentationField(name: "path", value: path)
  case event.kind
  of hekThought:
    result.kind = aekThoughtChunk
    result.text = event.message
  of hekLog:
    result.kind = aekMessageChunk
    result.text = event.message
  of hekToolUse:
    result.kind = aekToolCall
    result.toolCallId = event.toolExecutionId
    result.toolName = event.toolName
    let args = event.raw{"tool_args"}
    if args != nil:
      if args.kind == JString:
        try: result.toolArguments = $presentationArguments(parseJson(args.getStr()))
        except JsonParsingError: result.toolArguments = "[unstructured arguments]"
      else: result.toolArguments = $presentationArguments(args)
    result.status = if event.status.len > 0: event.status else: "started"
  of hekToolResult:
    result.kind = aekToolCallUpdate
    result.toolCallId = event.toolExecutionId
    result.toolName = event.toolName
    result.status = if event.status.len > 0: event.status else: "completed"
    result.text = event.raw{"tool_output"}.getStr(event.message)
  of hekFileEdit:
    result.kind = aekFileEdit
    result.filePath = event.filePath
    result.line = event.raw.lineFromRaw()
    result.linesAdded = event.linesAdded
    result.linesRemoved = event.linesRemoved
    result.status = if event.status.len > 0: event.status else: "applied"
    # The public file_edit DTO carries readable prose in description, not
    # message. Project only that typed string; arbitrary raw fields stay private.
    result.text = event.raw{"description"}.getStr(event.message)
  of hekDiff:
    result.kind = aekDiff
    result.filePath = event.filePath
    result.line = event.raw.lineFromRaw()
    result.linesAdded = event.linesAdded
    result.linesRemoved = event.linesRemoved
    result.diff = event.raw{"diff"}.getStr(event.raw{"patch"}.getStr(""))
    result.text = event.message
  of hekDelivery:
    result.kind = aekDelivery
    result.status = event.deliveryMode
    result.text = event.deliveryUrl
  of hekLlmRequest:
    result.kind = aekLlmRequest
    result.status = event.status
    result.model = event.raw{"model"}.getStr("")
    result.text = event.raw{"responseSummary"}.getStr(event.message)
    let usage = event.raw{"usage"}
    if usage != nil and usage.kind == JObject:
      result.inputTokens = usage{"input_tokens"}.getInt(usage{"inputTokens"}.getInt(-1))
      result.outputTokens = usage{"output_tokens"}.getInt(usage{"outputTokens"}.getInt(-1))
      result.hasUsage = result.inputTokens >= 0 or result.outputTokens >= 0
      result.usageSource = usage{"source"}.getStr("")
  of hekSubAgent:
    result.kind = aekSubAgent
    result.status = event.status
    result.text = event.message
    let inner = event.raw{"innerEvent"}
    if inner != nil and inner.kind == JObject:
      # Only the actual inner content discriminator and readable text, never
      # arbitrary nested configuration. Host navigation still has no fake action.
      result.presentationFields.add AgentPresentationField(name: "event", value: inner{"type"}.getStr(""))
      result.text = inner{"message"}.getStr(inner{"thought"}.getStr(event.message))
  of hekWorkspace, hekStatus:
    case event.status
    of "connecting", "authenticating", "connected", "streaming", "ready",
        "running", "provisioning", "retrying", "cancelling":
      if event.kind == hekWorkspace and
          (event.status == "ready" or event.mountPath.len > 0):
        result.kind = aekWorkspaceReady
        result.state = acsConnected
        result.workspacePath = event.mountPath
        result.workingCopyMode = event.workingCopyMode
      else:
        result.kind = aekConnection
        result.state = stateFromStatus(event.status)
    of "cancelled", "stopped":
      result.kind = aekCancelled
      result.state = acsCancelled
      result.stopReason = srCancelled
    of "completed":
      result.kind = aekCompleted
      result.state = acsCompleted
      result.stopReason = srEndTurn
    of "failed", "error":
      result.kind = aekError
      result.state = acsError
      result.stopReason = srError
    else:
      if event.kind == hekWorkspace and event.mountPath.len > 0:
        result.kind = aekWorkspaceReady
        result.state = acsConnected
        result.workspacePath = event.mountPath
        result.workingCopyMode = event.workingCopyMode
      else:
        result.kind = aekStatus
        result.state = acsStreaming
    result.text = event.message
    if result.kind == aekError and result.text.len == 0:
      result.text = "Harbor session " & sessionId & " failed"
  else:
    let rawType = event.raw{"type"}.getStr("")
    if rawType == "user_input":
      # Harbor's typed input is human activity, never assistant output. Keep
      # its original content/raw envelope without guessing from message text.
      result.kind = aekStatus
      result.text = event.raw{"content"}.getStr("")
    elif rawType == "agent_question":
      result.kind = aekStatus
      result.question = event.raw{"prompt"}.getStr("")
      result.text = result.question
    elif rawType in ["file_read", "delegation", "orchestration", "context_files",
        "fleet_fence", "fleet_host", "session_started", "session_awaiting_input",
        "session_resumed", "session_ended", "proxy_credential_rotated",
        "proxy_rate_limit_absorbed", "dispatcher_restarted", "anti_halting_resume_confirmed",
        "session_leadership_migrated", "participant", "context_injection", "login_required", "link_spans"]:
      result.kind = aekStatus
      result.text = event.raw{"description"}.getStr(event.raw{"output"}.getStr(event.message))
      if rawType == "context_injection": result.text = event.raw{"text"}.getStr("")
    elif rawType == "error":
      result.kind = aekError
      result.text = event.message
      result.stopReason = srError
    elif rawType == "turn_complete":
      let reason = event.raw{"stop_reason"}.getStr("end_turn")
      if reason == "tool_use":
        result.kind = aekStatus
      else:
        result.kind = aekCompleted
        result.state = acsCompleted
        result.stopReason = parseStopReason(reason)
    elif rawType == "plan":
      result.kind = aekPlan
      result.planEntries = jsonArrayStrings(event.raw, "entries")
    elif rawType == "milestone" or rawType == "milestone_progress":
      let progress = progressFromRaw(event.raw)
      result.kind = aekMilestoneProgress
      result.milestoneCompleted = progress.done
      result.milestoneTotal = progress.total
      result.text = event.message
    elif rawType == "review" or rawType == "diagnostic":
      result.kind = aekReview
      result.filePath = event.filePath
      result.line = event.raw.lineFromRaw()
      result.reviewSeverity = event.raw{"severity"}.getStr("warning")
      result.reviewCategory = event.raw{"category"}.getStr("")
      result.text = event.message
    else:
      result.kind = aekStatus
      result.text = event.message
  if result.kind in {aekCancelled, aekCompleted, aekError} and event.status.len > 0:
    result.stopReason = stopReasonFromStatus(event.status)

proc harborEventsToAgentEvents*(sessionId: string;
    events: openArray[HarborEvent]): seq[AgentEvent] =
  for event in events:
    result.add harborEventToAgentEvent(sessionId, event)

proc acpUpdateToAgentEvent*(sessionId: string;
    update: SessionUpdate): AgentEvent =
  result = AgentEvent(sessionId: sessionId, raw: update.raw)
  case update.kind
  of sukAgentMessageChunk:
    result.kind = aekMessageChunk
    result.text = update.content.text
  of sukAgentThoughtChunk:
    result.kind = aekThoughtChunk
    result.text = update.content.text
  of sukToolCall:
    result.kind = aekToolCall
    result.toolCallId = update.toolCallId
    result.toolName = update.title
  of sukToolCallUpdate:
    result.kind = aekToolCallUpdate
    result.toolCallId = update.toolCallId
    result.status = update.status
    result.text = update.rawOutput
  of sukStatus:
    case update.status
    of "completed":
      result.kind = aekCompleted
      result.state = acsCompleted
      result.stopReason = srEndTurn
    of "cancelled", "stopped":
      result.kind = aekCancelled
      result.state = acsCancelled
      result.stopReason = srCancelled
    of "error", "failed":
      result.kind = aekError
      result.state = acsError
      result.stopReason = srError
    else:
      result.kind = aekStatus
    result.status = update.status
  else:
    let rawUpdate = update.raw{"update"}
    case rawUpdate{"sessionUpdate"}.getStr("")
    of "plan":
      result.kind = aekPlan
      result.planEntries = jsonArrayStrings(rawUpdate, "entries")
    of "file_edit":
      result.kind = aekFileEdit
      result.filePath = rawUpdate{"file_path"}.getStr(rawUpdate{"path"}.getStr(""))
      result.line = rawUpdate.lineFromRaw()
      result.linesAdded = rawUpdate{"lines_added"}.getInt(0)
      result.linesRemoved = rawUpdate{"lines_removed"}.getInt(0)
    of "diff":
      result.kind = aekDiff
      result.filePath = rawUpdate{"file_path"}.getStr(rawUpdate{"path"}.getStr(""))
      result.line = rawUpdate.lineFromRaw()
      result.linesAdded = rawUpdate{"lines_added"}.getInt(0)
      result.linesRemoved = rawUpdate{"lines_removed"}.getInt(0)
      result.diff = rawUpdate{"diff"}.getStr(rawUpdate{"patch"}.getStr(""))
    of "milestone", "milestone_progress":
      let progress = progressFromRaw(rawUpdate)
      result.kind = aekMilestoneProgress
      result.milestoneCompleted = progress.done
      result.milestoneTotal = progress.total
    of "workspace":
      result.kind = aekWorkspaceReady
      result.state = acsConnected
      result.workspacePath = rawUpdate{"mountPath"}.getStr(rawUpdate{
          "workspacePath"}.getStr(""))
      result.workingCopyMode = rawUpdate{"workingCopyMode"}.getStr("")
    else:
      result.kind = aekStatus

proc acpUpdatesToAgentEvents*(sessionId: string;
    updates: openArray[SessionUpdate]): seq[AgentEvent] =
  for update in updates:
    result.add acpUpdateToAgentEvent(sessionId, update)

proc parseAgentEventKind*(value: string): AgentEventKind =
  ## Inverse of ``$`` for :type:`AgentEventKind`; anything unrecognised
  ## degrades to :const:`aekStatus`, which renders as a neutral line
  ## rather than as a message the agent never wrote.
  for kind in AgentEventKind:
    if $kind == value:
      return kind
  aekStatus

proc parseAgentConnectionState*(value: string): AgentConnectionState =
  for state in AgentConnectionState:
    if $state == value:
      return state
  acsDisconnected

proc toJson*(event: AgentEvent): JsonNode =
  ## Project one event into the transport form used when a resolved
  ## session crosses a process boundary (``ct`` resolves it; the
  ## renderer paints it).
  ##
  ## Only the fields a conversation view renders are carried; ``raw`` is
  ## deliberately dropped, because it is the backend's own frame and can
  ## contain arbitrary session content that has no business being copied
  ## into a file.  :proc:`agentEventFromJson` is its exact inverse over
  ## the fields that are carried.
  result = %*{
    "sourceType": event.sourceType,
    "eventId": event.eventId,
    "toolArguments": event.toolArguments,
    "model": event.model,
    "usageSource": event.usageSource,
    "hasUsage": event.hasUsage,
    "inputTokens": event.inputTokens,
    "outputTokens": event.outputTokens,
    "question": event.question,
    "sessionId": event.sessionId,
    "kind": $event.kind,
    "state": $event.state,
    "text": event.text,
    "status": event.status,
    "stopReason": $event.stopReason,
    "toolCallId": event.toolCallId,
    "toolName": event.toolName,
    "filePath": event.filePath,
    "line": event.line,
    "linesAdded": event.linesAdded,
    "linesRemoved": event.linesRemoved,
    "diff": event.diff,
    "reviewSeverity": event.reviewSeverity,
    "reviewCategory": event.reviewCategory,
    "milestoneCompleted": event.milestoneCompleted,
    "milestoneTotal": event.milestoneTotal,
    "workspacePath": event.workspacePath,
    "workingCopyMode": event.workingCopyMode
  }
  var entries = newJArray()
  for entry in event.planEntries:
    entries.add %entry
  result["planEntries"] = entries
  var fields = newJArray()
  for field in event.presentationFields:
    fields.add %*{"name": field.name, "value": field.value}
  result["presentationFields"] = fields

proc agentEventFromJson*(node: JsonNode): AgentEvent =
  result = AgentEvent(
    sourceType: node{"sourceType"}.getStr(""),
    eventId: node{"eventId"}.getStr(""),
    toolArguments: node{"toolArguments"}.getStr(""),
    model: node{"model"}.getStr(""),
    usageSource: node{"usageSource"}.getStr(""),
    hasUsage: node{"hasUsage"}.getBool(false),
    inputTokens: node{"inputTokens"}.getInt(0),
    outputTokens: node{"outputTokens"}.getInt(0),
    question: node{"question"}.getStr(""),
    sessionId: node{"sessionId"}.getStr(""),
    stopReason: parseStopReason(node{"stopReason"}.getStr("end_turn")),
    kind: parseAgentEventKind(node{"kind"}.getStr("status")),
    state: parseAgentConnectionState(node{"state"}.getStr("disconnected")),
    text: node{"text"}.getStr(""),
    status: node{"status"}.getStr(""),
    toolCallId: node{"toolCallId"}.getStr(""),
    toolName: node{"toolName"}.getStr(""),
    filePath: node{"filePath"}.getStr(""),
    line: node{"line"}.getInt(0),
    linesAdded: node{"linesAdded"}.getInt(0),
    linesRemoved: node{"linesRemoved"}.getInt(0),
    diff: node{"diff"}.getStr(""),
    reviewSeverity: node{"reviewSeverity"}.getStr(""),
    reviewCategory: node{"reviewCategory"}.getStr(""),
    milestoneCompleted: node{"milestoneCompleted"}.getInt(0),
    milestoneTotal: node{"milestoneTotal"}.getInt(0),
    workspacePath: node{"workspacePath"}.getStr(""),
    workingCopyMode: node{"workingCopyMode"}.getStr(""),
    raw: node)
  let fields = node{"presentationFields"}
  if fields != nil and fields.kind == JArray:
    for field in fields.items:
      if field.kind == JObject:
        result.presentationFields.add AgentPresentationField(
          name: field{"name"}.getStr(""), value: field{"value"}.getStr(""))
  let entries = node{"planEntries"}
  if entries != nil and entries.kind == JArray:
    for entry in entries.items:
      if entry.kind == JString: result.planEntries.add entry.getStr("")
  elif entries != nil:
    # Malformed recognized payloads are visible diagnostics, never a fabricated
    # turn-complete signal. The caller still waits for its actual terminal frame.
    result.kind = aekError
    result.text = "Malformed agent plan entries"
    result.stopReason = srError
