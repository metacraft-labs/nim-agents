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
##
## `sessionAt` is `foldEvent` repeated from the session's start, so a front-end
## that folds a live session's events one at a time (`fleet_fold`) and one
## that rebuilds the session at a moment read the same session.

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

proc eventTimeMs*(event: JsonNode; startMs: int64): int64 =
  ## When `event` happened: its timestamp is microseconds since the session
  ## started, and `startMs` places that start in time.
  startMs + event{"timestamp"}.getBiggestInt(0).int64 div 1000

proc foldEvent*(session: var FleetSession; event: JsonNode; ordinal: int;
                startMs: int64; takeStatus = true) =
  ## One more event of the session's history folded into `session`: the step
  ## `sessionAt` repeats, and the one a fleet that follows a live session
  ## takes per event (`fleet_fold`). `ordinal` is the event's 1-based place in
  ## the history, which names a pending question's request. With
  ## `takeStatus = false` a `status` event is kept as activity but does not
  ## move the status, for a caller whose status comes from the lifecycle feed.
  ##
  ## The step owns only the waits it can see in the stream: a question. After
  ## it, a live session waits on a question exactly when this event is the
  ## agent asking; any other event ends a question wait. A wait the listing
  ## reports for another reason (a hook such as the end of the agent's turn,
  ## the server's settle heuristic, a permission or a login) is the
  ## listing's: an event neither ends nor renames it, except the operator's
  ## input reaching the session (`session_resumed`, `user_input`), which ends
  ## every wait. A session replayed from its start (`sessionAt`) only ever
  ## holds question waits. The session has ended at its last update exactly
  ## when its status is no longer live.
  let at = event.eventTimeMs(startMs)
  session.updatedAtMs = max(session.updatedAtMs, at)
  if takeStatus and event{"type"}.getStr == "status":
    session.rawStatus = event{"status"}.getStr
    session.status = parseFleetStatus(session.rawStatus)
  var line = activityFromJson(event)
  line.timestampMs = at
  session.recent.add line
  if session.recent.len > ReplayRecentLimit:
    session.recent = session.recent[^ReplayRecentLimit .. ^1]
  if not session.status.isActive:
    session.endedAtMs = session.updatedAtMs
    session.awaitingInput = false
    session.awaitingInputSource = ""
  else:
    session.endedAtMs = 0
    let kind = event{"type"}.getStr
    let questionWait = not session.awaitingInput or
      "question" in session.awaitingInputSource.toLowerAscii
    if kind in ["session_resumed", "user_input"] or
        (questionWait and not event.isQuestionEvent):
      session.awaitingInput = false
      session.awaitingInputSource = ""
    elif questionWait:
      session.awaitingInput = true
      session.awaitingInputSource = session.id & ":native-question:" & $ordinal

proc sessionAt*(session: FleetSession; eventsOldestFirst: openArray[JsonNode];
                count: int; startMs: int64): FleetSession =
  ## `session` after its first `count` events. Event timestamps are
  ## microseconds since the session started; `startMs` places them in time.
  result = session
  let n = max(0, min(count, eventsOldestFirst.len))
  result.rawStatus = "queued"
  result.status = fsQueued
  result.awaitingInput = false
  result.awaitingInputSource = ""
  result.endedAtMs = 0
  result.recent = @[]
  result.startedAtMs = startMs
  result.createdAtMs = startMs
  result.updatedAtMs = startMs
  for i in 0 ..< n:
    result.foldEvent(eventsOldestFirst[i], i + 1, startMs)

proc eventsOldestFirst*(history: JsonNode): seq[JsonNode] =
  ## The events of a history answer, oldest first.
  let events = history{"events"}
  if events.isNil or events.kind != JArray: return
  for i in countdown(events.len - 1, 0): result.add events[i]
