## The signal-free half of the Agent Activity feed (`nim_agents/activity_feed`),
## native and JS: the rows a user turn and an evidence handoff become, how rows
## wrap into the lines a pane of a given width shows, and where the reader's
## place stays while rows arrive. Every row is built by hand, with no
## viewmodel; every expectation is written out from the rules in the module.
## The data is invented, as everything in this public repository.
##
## Moved from CodeTracer's `test_plat54_agent_activity` ("lines and the
## reader's place"), which kept the cases that derive the rows from the
## viewmodel.

import std/[strutils, unittest]
import nim_agents/activity_model
import nim_agents/evidence_call
import nim_agents/activity_feed

proc textRows(n: int): seq[AgentFeedRow] =
  for i in 0 ..< n:
    result.add AgentFeedRow(kind: frText, key: "m" & $i & "/t",
                            messageId: "m" & $i,
                            spans: @[span("line " & $i)])

suite "activity feed rows":
  test "a user turn is a header, then its text, indented":
    var rows: seq[AgentFeedRow]
    rows.addUserMessage(AgentActivityMessageEntry(
      id: "u1", role: aamrUser, content: "fix the parser"), 0.0)
    check rows[0].kind == frUserHeader
    check rows[0].plainText == "You"
    check rows.len >= 2
    check rows[1].plainText == "fix the parser"
    check rows[1].indent == 1

  test "a cancelled user turn says so in its header":
    var rows: seq[AgentFeedRow]
    rows.addUserMessage(AgentActivityMessageEntry(
      id: "u2", role: aamrUser, content: "x", canceled: true), 0.0)
    check rows[0].plainText.len > 3 and "(canceled)" in rows[0].plainText

  test "an evidence handoff is a card of header, dataset and command":
    var rows: seq[AgentFeedRow]
    rows.addEvidence(EvidenceCall(
      anchorId: "e1", kind: eckHandoff, command: "ct agent evidence r.json",
      datasetPath: "r.json", state: ecsCompleted,
      dataset: EvidenceDataset(state: edsReady, fileCount: 2, commit: "abc")))
    check rows[0].kind == frEvidenceHeader
    check rows[0].buttons.len == 1
    check rows[0].buttons[0].kind == faOpenEvidence
    check rows[1].kind == frEvidenceDataset and rows[1].plainText == "r.json"
    check rows[2].kind == frEvidenceCommand
    check rows[2].plainText == "ct agent evidence r.json"

  test "an evidence card whose dataset was not read offers no review":
    var rows: seq[AgentFeedRow]
    rows.addEvidence(EvidenceCall(anchorId: "e2", kind: eckHandoff,
      command: "ct agent evidence r.json", datasetPath: "r.json",
      state: ecsCompleted, dataset: EvidenceDataset(state: edsUnknown)))
    check rows[0].buttons.len == 0

suite "activity feed lines and the reader's place":
  test "wrapping: no line wider than the pane, every row at least one line":
    let rows = @[
      AgentFeedRow(kind: frText, key: "a", spans: @[span(
        "a long paragraph that has to break at spaces where it can and mid-word where it must")]),
      AgentFeedRow(kind: frText, key: "b", spans: @[]),
      AgentFeedRow(kind: frText, key: "c", indent: 1,
        spans: @[span("supercalifragilisticexpialidocious")])]
    for width in [12, 20, 37, 80]:
      let lines = wrapFeed(rows, width)
      var seen = newSeq[bool](rows.len)
      var widest = 0
      for l in lines:
        seen[l.row] = true
        var w = 0
        for s in l.spans: w += runeMeasure(s.text)
        widest = max(widest, w)
      check widest <= width
      check false notin seen

  test "following the end, and holding a line the reader scrolled to":
    var rows = textRows(30)
    var lines = wrapFeed(rows, 40)
    var scroll = initFeedScroll()
    scroll.settle(rows, lines, 10)
    check scroll.follow
    check scroll.top == maxTop(lines.len, 10)
    scroll.scrollTo(5, rows, lines, 10)
    check not scroll.follow
    let key = rows[lines[5].row].key
    # Rows arrive below everything: the reader keeps the same line.
    rows = textRows(45)
    lines = wrapFeed(rows, 40)
    scroll.settle(rows, lines, 10)
    check scroll.top == 5
    check rows[lines[scroll.top].row].key == key
    # A notice appears above: the same line stays at the top.
    rows.insert(AgentFeedRow(kind: frNotice, key: "notice",
                             spans: @[span("Agent session s loaded.")]), 0)
    lines = wrapFeed(rows, 40)
    scroll.settle(rows, lines, 10)
    check rows[lines[scroll.top].row].key == key
    check scroll.top == 6
    # Back at the end, it follows again.
    scroll.scrollTo(lines.len, rows, lines, 10)
    check scroll.follow

  test "lineOfRow finds a row's first line, and -1 for none":
    let rows = textRows(3)
    let lines = wrapFeed(rows, 40)
    check lines.lineOfRow(1) == 1
    check lines.lineOfRow(7) == -1
