## Opt-in, renderer-free conversation reducer. Import nim_agents/activity explicitly.
## Hosts own signals, editor permissions and supported response actions. Backend
## events cross the safe AgentEvent projection; raw frames are never inspected.
import std/[strutils, sets]
import ./client

type
  ActivityRole* = enum arUser, arAssistant, arActivity
  ActivityEntry* = object
    id*: string
    turn*: int
    data*: AgentEvent
    role*: ActivityRole
    kind*: AgentEventKind
    title*, text*, detail*, status*, toolCallId*: string
  ActivityTimeline* = object
    entries*: seq[ActivityEntry]
    turn*: int
    revision*: int
    sequence: int
    seen: HashSet[string]
    lastPlainStatus, lastPlainSession: string
    lastPlainTurn: int

proc appendEntry(timeline: var ActivityTimeline; entry: ActivityEntry) =
  var value = entry
  inc timeline.sequence
  inc timeline.revision
  value.id = "activity-" & $timeline.sequence
  value.turn = timeline.turn
  timeline.entries.add value

proc beginTurn*(timeline: var ActivityTimeline; text: string) =
  inc timeline.turn
  timeline.appendEntry(ActivityEntry(role: arUser, kind: aekMessageChunk,
    text: text))

proc appendAssistant*(timeline: var ActivityTimeline; text: string) =
  if text.len == 0: return
  if timeline.entries.len > 0 and timeline.entries[^1].role == arAssistant and
      timeline.entries[^1].turn == timeline.turn:
    timeline.entries[^1].text.add text
    inc timeline.revision
  else:
    timeline.appendEntry(ActivityEntry(role: arAssistant, kind: aekMessageChunk,
      text: text, status: "streaming"))

proc reduce*(timeline: var ActivityTimeline; event: AgentEvent): bool {.discardable.} =
  if event.eventId.len > 0:
    let identity = event.sessionId & ":" & event.eventId
    if identity in timeline.seen: return false
    timeline.seen.incl identity
  # Local human turn is recorded on admitted send. Typed backend input is an
  # acknowledgement, including identical assistant content and user: prefixes.
  if event.sourceType == "user_input": return false
  if event.kind == aekMessageChunk:
    if event.text.len == 0: return false
    timeline.appendAssistant(event.text)
    return true
  # Harbor's plain running status projects to aekConnection. Suppress only
  # its exact empty heartbeat (including kind/state), preserving durable seen
  # identities above and every meaningful status detail or actual transition.
  let plainStatus = event.kind in {aekStatus, aekConnection} and event.sourceType == "status" and
    event.text.len == 0 and event.presentationFields.len == 0 and event.status.len > 0
  if not plainStatus and event.kind in {aekStatus, aekConnection, aekCompleted, aekCancelled, aekError, aekWorkspaceReady}:
    timeline.lastPlainStatus = ""
  if plainStatus:
    let plain = $event.kind & ":" & $event.state & ":" & event.status
    if timeline.lastPlainTurn == timeline.turn and
        timeline.lastPlainSession == event.sessionId and
        timeline.lastPlainStatus == plain:
      return false
    timeline.lastPlainTurn = timeline.turn
    timeline.lastPlainSession = event.sessionId
    timeline.lastPlainStatus = plain
  # Only genuine terminal events settle streaming prose; heartbeats and tool
  # phases never imply that the provider has finished the turn.
  if event.kind in {aekCompleted, aekCancelled, aekError}:
    for item in timeline.entries.mitems:
      if item.turn == timeline.turn and item.status == "streaming" and
          (item.role == arAssistant or item.kind == aekThoughtChunk):
        item.status = case event.kind
          of aekCompleted: "completed"
          of aekCancelled: "stopped"
          else: "interrupted"
        inc timeline.revision
  var data = event
  data.raw = nil
  var entry = ActivityEntry(role: arActivity, kind: event.kind, data: data,
    status: event.status, text: event.text, toolCallId: event.toolCallId)
  case event.kind
  of aekToolCall, aekToolCallUpdate:
    entry.title = event.toolName
    entry.detail = event.toolArguments
    for i in countdown(timeline.entries.high, 0):
      if event.toolCallId.len > 0 and timeline.entries[i].turn == timeline.turn and
          timeline.entries[i].toolCallId == event.toolCallId:
        var changed = false
        if event.toolName.len > 0 and event.toolName != timeline.entries[i].title:
          timeline.entries[i].title = event.toolName
          changed = true
        if event.status.len > 0 and event.status != timeline.entries[i].status:
          timeline.entries[i].status = event.status
          changed = true
        if event.text.len > 0 and event.text != timeline.entries[i].text:
          timeline.entries[i].text = event.text
          changed = true
        if event.toolArguments.len > 0 and event.toolArguments != timeline.entries[i].detail:
          timeline.entries[i].detail = event.toolArguments
          changed = true
        # The card identity/category is stable; data is a safe semantic aggregate
        # with the latest event kind and durable provenance. Empty optional name,
        # arguments, output and status mean omitted, so the prior supplied value
        # survives. Nonempty presentation fields replace their previous snapshot;
        # omission preserves it. Envelope-only changes never announce new output.
        let previous = timeline.entries[i].data
        if data.presentationFields.len == 0:
          data.presentationFields = previous.presentationFields
        elif data.presentationFields != previous.presentationFields:
          changed = true
        if data.sessionId.len == 0: data.sessionId = previous.sessionId
        # eventId/sourceType describe this update, including absent identities;
        # retaining an old event ID would falsely attribute the new aggregate.
        data.toolName = timeline.entries[i].title
        data.toolArguments = timeline.entries[i].detail
        data.status = timeline.entries[i].status
        data.text = timeline.entries[i].text
        timeline.entries[i].data = data
        if changed: inc timeline.revision
        return true
  of aekThoughtChunk:
    entry.status = "streaming"
    if event.text.len == 0: return false
    if timeline.entries.len > 0 and timeline.entries[^1].kind == aekThoughtChunk and
        timeline.entries[^1].turn == timeline.turn:
      timeline.entries[^1].text.add event.text
      inc timeline.revision
      return true
  of aekPlan: entry.text = event.planEntries.join("\n")
  of aekDiff: entry.detail = event.diff
  of aekConnection: entry.status = $event.state
  of aekStatus:
    if event.text.len == 0 and event.status.len == 0 and event.sourceType.len == 0: return false

  else: discard
  timeline.appendEntry entry
  true
