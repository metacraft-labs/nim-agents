## A session as it was at a moment of its history: the listing entry folded
## back from its event history, the way a front-end shows a session it seeks
## to (a read-only snapshot at a timeline moment).
##
## Agent Harbor's event history (`GET /api/v1/sessions/{id}/events/history`)
## lists events newest first; `sessionAt` takes them oldest first and keeps the
## first `count`. What it derives from them:
##
## - the status: the last `status` event kept (`queued` when there is none);
## - a pending question: when the last event kept is the agent asking (an
##   `agent_question`, a `session_awaiting_input`, or the server's log line
##   `agent question (<agent>): …`), the session waits for an answer;
## - the recent events: the last three kept, oldest first, as the listing
##   carries them;
## - the update time: the last kept event's.
##
## Everything else (prompt, agent, workspace) is the session's own.

import std/[json, strutils]
import ./fleet_records

export fleet_records

const ReplayRecentLimit* = 3

proc isQuestionEvent*(event: JsonNode): bool =
  let kind = event{"type"}.getStr
  kind in ["agent_question", "session_awaiting_input"] or
    (kind == "log" and event{"message"}.getStr.startsWith("agent question"))

proc questionIndexes*(eventsOldestFirst: openArray[JsonNode]): seq[int] =
  ## The positions where the agent asked something.
  for i, event in eventsOldestFirst:
    if event.isQuestionEvent: result.add i

proc sessionAt*(session: FleetSession; eventsOldestFirst: openArray[JsonNode];
                count: int; startMs: int64): FleetSession =
  ## `session` after its first `count` events. Event timestamps are
  ## microseconds since the session started; `startMs` places them in time.
  result = session
  let n = max(0, min(count, eventsOldestFirst.len))
  result.rawStatus = "queued"
  result.awaitingInput = false
  result.awaitingInputSource = ""
  result.endedAtMs = 0
  result.recent = @[]
  result.startedAtMs = startMs
  result.createdAtMs = startMs
  result.updatedAtMs = startMs
  for i in 0 ..< n:
    let event = eventsOldestFirst[i]
    let at = startMs + event{"timestamp"}.getBiggestInt(0).int64 div 1000
    result.updatedAtMs = max(result.updatedAtMs, at)
    if event{"type"}.getStr == "status":
      result.rawStatus = event{"status"}.getStr
  result.status = parseFleetStatus(result.rawStatus)
  if not result.status.isActive:
    result.endedAtMs = result.updatedAtMs
  elif n > 0 and eventsOldestFirst[n - 1].isQuestionEvent:
    result.awaitingInput = true
    result.awaitingInputSource = result.id & ":native-question:" & $n
  for i in max(0, n - ReplayRecentLimit) ..< n:
    var line = activityFromJson(eventsOldestFirst[i])
    line.timestampMs = startMs + eventsOldestFirst[i]{"timestamp"}.getBiggestInt(0).int64 div 1000
    result.recent.add line

proc eventsOldestFirst*(history: JsonNode): seq[JsonNode] =
  ## The events of a history answer, oldest first.
  let events = history{"events"}
  if events.isNil or events.kind != JArray: return
  for i in countdown(events.len - 1, 0): result.add events[i]
