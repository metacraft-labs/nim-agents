## The panel's words (`nim_agents/activity_text`), native and JS: a turn's
## header, the paragraph a finished turn promotes, a tool call's dot, a file's
## lines and the agent's markdown as spans. Pure functions of the values they
## are given; every expectation is written out by hand. Copied from CodeTracer's
## `test_plat54_agent_activity` ("the panel's words, decided once"), which keeps
## them as the shim's integration check.

import std/unittest
import nim_agents/activity_model
import nim_agents/activity_text

suite "PLAT-54 the panel's words, decided once":

  test "a turn's header":
    var m = AgentActivityMessageEntry(id: "a", role: aamrAgent)
    check thoughtHeaderLabel(m) == ""
    m.isLoading = true
    check thoughtHeaderLabel(m) == "Thinking"
    m.thinkingEndedAt = 3000.0
    m.createdAt = 1000.0
    check thoughtHeaderLabel(m) == "Thinking 2s"
    m.duration = 75.0
    check thoughtHeaderLabel(m) == "Thought for 1m 15s"
    m.failed = true
    check thoughtHeaderLabel(m) == "Failed"
    check canceledSuffix("") == "(canceled)"
    check canceledSuffix("Thinking") == " (canceled)"

  test "the paragraph a finished turn promotes, and the recap":
    var m = AgentActivityMessageEntry(id: "a", role: aamrAgent, segments: @[
      AgentActivitySegment(content: "first\n\nsecond paragraph"),
      AgentActivitySegment(isToolCall: true, toolName: "ls",
                           toolStatus: "completed")])
    let groups = computeSegGroups(m.segments)
    check groups.len == 2
    let f = finalTurnText(m, groups)
    check f.text == "second paragraph"
    check f.groupIndex == 0
    m.segments[0].content = "Last agent message: Some(\"done\\nnow\")"
    check finalTurnText(m, computeSegGroups(m.segments)).text == "done\nnow"
    m.isLoading = true
    check finalTurnText(m, groups).groupIndex == -1
    check not startsCollapsed(m, groups)
    m.isLoading = false
    check startsCollapsed(m, groups)
    check not startsCollapsed(AgentActivityMessageEntry(content: "flat"), @[])

  test "a tool call's dot, a file's lines, the card states":
    check toolState("completed") == atsDone
    check toolState("failed") == atsFailed
    check toolState("in_progress") == atsRunning
    check toolState("") == atsRunning
    check computeDiffStats("a\nb\nc", "a\nc\nd\ne") == (2, 1)
    check computeDiffStats("", "") == (0, 0)
    check filesChangedText(1) == "1 file changed"
    check filesChangedText(3) == "3 files changed"
    check wallClockTime(0.0) == ""
    check relativeTimeAt(0.0, 5000.0) == ""
    check relativeTimeAt(1000.0, 61_000.0) == "1m ago"

  test "agent markdown as spans":
    let segs = parseInlineCode("run `ls` **now**\n| a | b |\n|---|---|\n| 1 | 2 |")
    check segs[1].kind == mskCode
    check segs[1].content == "ls"
    check segs[3].kind == mskBold
    var tables = 0
    for s in segs:
      if s.kind == mskTable: inc tables
    check tables == 1
