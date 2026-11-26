## The activity model (`nim_agents/activity_model`), native and JS: the data
## an agent activity panel renders keeps the shape and the defaults the
## viewmodels, the feed and the views rely on. Plain data: every expectation is
## written out by hand.

import std/unittest
import nim_agents/activity_model

suite "activity model":
  test "a message starts empty, as an agent's, with no failure":
    let m = AgentActivityMessageEntry()
    check m.role == aamrAgent
    check m.content == "" and m.id == ""
    check not m.canceled and not m.isLoading and not m.failed
    check m.segments.len == 0 and m.toolCalls.len == 0 and m.diffs.len == 0
    check m.duration == 0.0 and m.thinkingEndedAt == 0.0

  test "a tool call row is told apart from prose by its tool name":
    let prose = AgentActivityMessageEntry(content: "I ran the tests.")
    let call = AgentActivityMessageEntry(toolName: "cargo test",
      toolCallId: "t1", status: "completed")
    check prose.toolName.len == 0
    check call.toolName.len > 0 and call.status == "completed"

  test "segments keep the order of text blocks and tool calls":
    var m = AgentActivityMessageEntry(role: aamrUser)
    m.segments.add AgentActivitySegment(content: "first")
    m.segments.add AgentActivitySegment(isToolCall: true, toolCallId: "t1",
      toolName: "read", toolStatus: "in_progress")
    check m.role == aamrUser
    check m.segments[0].isToolCall == false
    check m.segments[1].toolStatus == "in_progress"

  test "the workspace view kinds and counters":
    check [awvkUserWorkspace, awvkAgentWorkspace].len == 2
    let s = AgentWorkspaceSummary(testsRun: 3, testsPassed: 2, testsFailed: 1)
    check s.testsRun == s.testsPassed + s.testsFailed
    let f = AgentWorkspaceFileEntry(path: "src/a.nim", coveredLines: 4,
      totalLines: 10, hasFlow: true)
    check f.coveredLines < f.totalLines and f.hasFlow
