## Opt-in semantic presentation over safe activity data. No renderer, signals,
## raw frames or host actions; a visible fact does not imply an action exists.
import std/strutils
import ./[client, activity]

type
  ActivityFact* = object
    label*, value*, tone*: string
  ActivityPresentation* = object
    surface*, tone*: string
    facts*: seq[ActivityFact]

proc stateTone(value: string): string =
  case value.toLowerAscii()
  of "completed", "complete", "success", "succeeded", "applied", "ready", "fence_complete": "success"
  of "failed", "error", "interrupted", "fence_failed", "fence_timeout": "error"
  of "started", "pending", "waiting", "awaiting_input", "in_progress", "running", "streaming", "paused": "attention"
  else: "neutral"

proc activityPresentation*(entry: ActivityEntry): ActivityPresentation =
  result.surface = if entry.role == arUser: "user"
    elif entry.role == arAssistant: "assistant"
    else:
      case entry.kind
      of aekToolCall, aekToolCallUpdate: "tool"
      of aekThoughtChunk: "thought"
      of aekPlan: "plan"
      of aekFileEdit, aekDiff: "change"
      of aekLlmRequest: "model"
      of aekError: "error"
      else: (if entry.data.sourceType.len > 0: entry.data.sourceType else: $entry.kind)
  result.tone = stateTone(entry.status)
  if entry.kind == aekError: result.tone = "error"
  if entry.data.sourceType in ["agent_question", "login_required", "session_awaiting_input"]:
    result.tone = "attention"
  template fact(labelText, valueText: string; semanticTone = "neutral") =
    if valueText.len > 0:
      result.facts.add ActivityFact(label: labelText, value: valueText, tone: semanticTone)
  let event = entry.data
  case entry.kind
  of aekFileEdit:
    fact("File", event.filePath)
    fact("Changes", "+" & $event.linesAdded & " / −" & $event.linesRemoved & " lines", "success")
  of aekDiff: fact("File", event.filePath)
  of aekWorkspaceReady:
    fact("Workspace", event.workspacePath)
    fact("Working copy", event.workingCopyMode)
  of aekLlmRequest:
    fact("Model", event.model)
    if event.hasUsage:
      if event.inputTokens >= 0: fact("Input tokens", $event.inputTokens)
      if event.outputTokens >= 0: fact("Output tokens", $event.outputTokens)
      fact("Usage source", event.usageSource)
  of aekMilestoneProgress:
    if event.milestoneTotal > 0:
      fact("Progress", $event.milestoneCompleted & " / " & $event.milestoneTotal)
  else: discard
  for field in event.presentationFields:
    if entry.kind == aekPlan:
      fact(field.value.replace("_", " "), field.name, stateTone(field.value))
    else:
      let label = case field.name
        of "file_path", "path", "file": "File"
        of "start_line": "From line"
        of "end_line": "To line"
        of "request": "Request"
        of "kind": "Event"
        of "display_name": "Participant"
        of "transition": "Presence"
        of "totalCount": "Files in context"
        of "activeSubAgents": "Active agents"
        of "totalSubAgents": "Total agents"
        of "subAgentId": "Agent"
        of "parentSessionId": "Parent session"
        of "targetSessionId": "Target session"
        of "fenceId": "Synchronization"
        of "durationMs": "Duration (ms)"
        of "cumulativeWaitMs": "Wait (ms)"
        of "attempts": "Retry attempts"
        of "restartSeq": "Restart"
        of "stallType": "Recovered stall"
        of "triggerStatus": "Provider status"
        of "sourceExecutor": "Previous executor"
        of "targetExecutor": "Current executor"
        of "targetOs": "Operating system"
        of "flushedSeq": "Flushed sequence"
        of "option": "Choice"
        of "stop_reason": "Stop reason"
        of "input_tokens": "Input tokens"
        of "output_tokens": "Output tokens"
        of "messageCount": "Messages"
        of "hasToolCalls": "Tool calls"
        of "exitCode", "exit_code": "Exit code"
        of "oldText": "Before"
        of "newText": "After"
        of "oldTextHead": "Before (start)"
        of "oldTextTail": "Before (end)"
        of "newTextHead": "After (start)"
        of "newTextTail": "After (end)"
        else: field.name.replace("_", " ").capitalizeAscii()
      fact(label, field.value, if field.name in ["kind", "outcome", "transition"]:
        stateTone(field.value) else: "neutral")
