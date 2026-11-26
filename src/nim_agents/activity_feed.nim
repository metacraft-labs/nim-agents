## nim_agents/activity_feed.nim
##
## The signal-free half of the Agent Activity feed: the row, span and action
## types every front-end paints, the rows a user turn and an evidence handoff
## become, how rows wrap into the lines a pane shows, and where the reader's
## place stays while rows arrive (`FeedScroll`). Moved from CodeTracer's
## `viewmodels/agent_activity_feed.nim` (CTF-M1); the half that derives rows
## from `AgentActivityVM` and runs a row's press stays there, over this one.

import std/[options, sequtils, strutils, unicode]

import ./activity_model
import ./activity_text
import ./evidence_call

export activity_text

const
  AgentOmnibarQuery* = "/ai "
    ## The omnibox's agent mode (`omnibar_vm.classifyOmnibarQuery`), the
    ## desktop's: where a native front-end's prompt is typed.

type
  AgentFeedSpanStyle* = enum
    fsPlain, fsCode, fsBold, fsItalic, fsBoldItalic, fsStrike, fsMuted,
    fsHeading, fsError, fsAdded, fsRemoved, fsButton

  AgentFeedSpan* = object
    text*: string
    style*: AgentFeedSpanStyle
    button*: int
      ## 0, or `k` when this span is the caption of the row's button `k - 1`
      ## (set by `wrapFeed`, so a press is read back off the painted line).

  AgentFeedRowKind* = enum
    frNotice = "notice"
    frIdleHeading = "idle-heading"
    frIdleSubtitle = "idle-subtitle"
    frIdleChip = "idle-chip"
    frUserHeader = "user-header"
    frAgentHeader = "agent-header"
    frTurnError = "turn-error"
    frText = "text"
    frCode = "code"
    frTableRow = "table-row"
    frImage = "image"
    frToolsToggle = "tools-toggle"
    frToolCall = "tool-call"
    frWorking = "working"
    frDiffHeader = "diff-header"
    frDiffFile = "diff-file"
    frTestRun = "test-run"
    frTestRow = "test-row"
    frTestDetail = "test-detail"
    frTestRecordingFailed = "test-recording-failed"
    frTestDiagnostic = "test-diagnostic"
    frTestOutput = "test-output"
    frRunDiagnostic = "run-diagnostic"
    frRunOutput = "run-output"
    frEvidenceHeader = "evidence-header"
    frEvidenceDataset = "evidence-dataset"
    frEvidenceCommand = "evidence-command"
    frEvidenceNote = "evidence-note"
    frEvidenceOutput = "evidence-output"
    frTerminal = "terminal"
    frPasswordPrompt = "password-prompt"
    frPermissionHeading = "permission-heading"
    frPermissionText = "permission-text"
    frPermissionSubtitle = "permission-subtitle"
    frContextPath = "context-path"
      ## A path the prompt's `+` attached (the desktop's chip above the
      ## prompt), sent with the next prompt; its button removes it.

  AgentFeedActionKind* = enum
    faNone = "none"
    faToggleThought = "toggle-thought"
    faToggleToolHistory = "toggle-tool-history"
    faToggleRun = "toggle-run"
    faToggleTest = "toggle-test"
    faOpenRecording = "open-recording"
    faOpenRecordingNewTab = "open-recording-new-tab"
    faOpenEvidence = "open-evidence"
    faOpenDiff = "open-diff"
    faFillPrompt = "fill-prompt"
    faPermission = "permission"
    faRemoveContext = "remove-context"

  AgentFeedAction* = object
    kind*: AgentFeedActionKind
    label*: string
      ## A button's caption ("" for the row's own press).
    arg*: string
      ## faOpenDiff: the desktop's target (`file:<msg>:<diff>` /
      ## `unified:<msg>`); faFillPrompt: the chip's text; faPermission: the
      ## answer (`allow_once` …); faRemoveContext: the attached path.
    group*: int
      ## faToggleToolHistory: the segment group.

  AgentFeedRow* = object
    kind*: AgentFeedRowKind
    key*: string
      ## Stable identity across re-derivations (`FeedScroll` anchors on it).
    messageId*, anchorId*, testId*: string
    spans*: seq[AgentFeedSpan]
    state*: string
      ## The row's state word, as the desktop's class modifier spells it: a
      ## run's `running`/`failed`/`passed`, a test's outcome, an evidence
      ## card's `ready`/`reading`/…, a tool call's `done`/`failed`/`running`.
    indent*: int
      ## Nesting depth (a test row under its run, a detail under its test).
    press*: AgentFeedAction
      ## What a press on the row itself does (faNone: nothing).
    buttons*: seq[AgentFeedAction]
      ## The row's buttons, in the desktop's order.

  AgentFeedLine* = object
    ## One painted line: a slice of row `row`'s spans, after wrapping.
    row*: int
    part*: int
      ## 0 for the row's first line.
    spans*: seq[AgentFeedSpan]

func span*(text: string; style = fsPlain): AgentFeedSpan =
  AgentFeedSpan(text: text, style: style)

func plainText*(row: AgentFeedRow): string =
  for s in row.spans:
    result.add s.text
  for b in row.buttons:
    result.add "  [" & b.label & "]"

# ---------------------------------------------------------------------------
# Agent text → rows
# ---------------------------------------------------------------------------

func styleOf*(kind: MsgSegKind): AgentFeedSpanStyle =
  case kind
  of mskCode: fsCode
  of mskBold: fsBold
  of mskItalic: fsItalic
  of mskBoldItalic: fsBoldItalic
  of mskStrike: fsStrike
  else: fsPlain

proc inlineSpans*(text: string): seq[AgentFeedSpan] =
  ## A table cell's inline markup, flattened to spans.
  for seg in parseInlineCode(text):
    case seg.kind
    of mskText, mskCode, mskBold, mskItalic, mskBoldItalic, mskStrike:
      result.add span(seg.content, styleOf(seg.kind))
    else:
      result.add span(seg.content)

proc addMarkup*(rows: var seq[AgentFeedRow]; base: AgentFeedRow; key: string;
               text: string) =
  ## `text` — agent markdown — as rows: inline runs split at their newlines
  ## into `frText` rows, a code block's lines as `frCode`, a table's rows as
  ## `frTableRow`, an image as `frImage` naming its alt text.
  var line: seq[AgentFeedSpan] = @[]
  var n = 0
  template flush() =
    var r = base
    r.kind = frText
    r.key = key & "/" & $n
    r.spans = line
    rows.add r
    inc n
    line = @[]
  for seg in parseInlineCode(text):
    case seg.kind
    of mskText, mskCode, mskBold, mskItalic, mskBoldItalic, mskStrike:
      let parts = seg.content.split('\n')
      for i, p in parts:
        if i > 0:
          flush()
        if p.len > 0:
          line.add span(p, styleOf(seg.kind))
    of mskCodeBlock:
      if line.len > 0: flush()
      if seg.lang.len > 0:
        var r = base
        r.kind = frCode
        r.key = key & "/" & $n
        r.spans = @[span(seg.lang, fsMuted)]
        rows.add r
        inc n
      for codeLine in seg.content.split('\n'):
        var r = base
        r.kind = frCode
        r.key = key & "/" & $n
        r.spans = @[span(codeLine, fsCode)]
        rows.add r
        inc n
    of mskTable:
      if line.len > 0: flush()
      for ri, cells in seg.rows:
        var r = base
        r.kind = frTableRow
        r.key = key & "/" & $n
        for ci, cell in cells:
          if ci > 0:
            r.spans.add span(" │ ", fsMuted)
          for s in inlineSpans(cell):
            r.spans.add(if ri == 0: span(s.text, fsBold) else: s)
        rows.add r
        inc n
    of mskImage:
      if line.len > 0: flush()
      var r = base
      r.kind = frImage
      r.key = key & "/" & $n
      r.spans = @[span("[image: " & (if seg.lang.len > 0: seg.lang
                                     else: "attachment") & "]", fsMuted)]
      rows.add r
      inc n
  if line.len > 0 or n == 0:
    flush()

# ---------------------------------------------------------------------------
# One message
# ---------------------------------------------------------------------------

proc addUserMessage*(rows: var seq[AgentFeedRow];
                    message: AgentActivityMessageEntry; nowMs: float) =
  var header = AgentFeedRow(kind: frUserHeader, key: message.id & "/h",
                            messageId: message.id)
  header.spans.add span("You", fsHeading)
  let age = relativeTimeAt(message.createdAt, nowMs)
  if age.len > 0:
    header.spans.add span("  " & age, fsMuted)
  if message.canceled:
    header.spans.add span(" " & AgentCanceledText, fsMuted)
  rows.add header
  for i, _ in message.images:
    rows.add AgentFeedRow(kind: frImage, key: message.id & "/img" & $i,
                          messageId: message.id,
                          spans: @[span("[image: attachment]", fsMuted)])
  rows.addMarkup(AgentFeedRow(messageId: message.id, indent: 1),
                 message.id & "/t", message.content)


proc addEvidence*(rows: var seq[AgentFeedRow]; call: EvidenceCall) =
  let anchor = call.anchorId
  let state = $evidenceCardState(call)
  var header = AgentFeedRow(kind: frEvidenceHeader, key: anchor & "/evidence",
                            messageId: anchor, anchorId: anchor, state: state,
                            spans: @[span(evidenceCommandName(call.kind),
                                          fsHeading)])
  let shape = evidenceDatasetShapeText(call)
  if shape.len > 0:
    header.spans.add span("  " & shape, fsMuted)
  if call.canOpenEvidence():
    header.buttons = @[AgentFeedAction(kind: faOpenEvidence,
                                       label: AgentOpenReviewLabel)]
  rows.add header
  rows.add AgentFeedRow(kind: frEvidenceDataset, key: anchor & "/dataset",
                        messageId: anchor, anchorId: anchor, state: state,
                        indent: 1, spans: @[span(call.datasetPath)])
  rows.add AgentFeedRow(kind: frEvidenceCommand, key: anchor & "/command",
                        messageId: anchor, anchorId: anchor, state: state,
                        indent: 1, spans: @[span(call.command, fsCode)])
  let note = evidenceNoteText(call)
  if note.len > 0:
    rows.add AgentFeedRow(kind: frEvidenceNote, key: anchor & "/note",
                          messageId: anchor, anchorId: anchor, state: state,
                          indent: 1, spans: @[span(note, fsMuted)])
  if call.failureText.len > 0:
    for oi, l in toSeq(call.failureText.split('\n')).pairs:
      rows.add AgentFeedRow(kind: frEvidenceOutput, key: anchor & "/out" & $oi,
                            messageId: anchor, anchorId: anchor, state: state,
                            indent: 1, spans: @[span(l, fsCode)])

# ---------------------------------------------------------------------------
# Lines and scrolling
# ---------------------------------------------------------------------------

type
  FeedMeasure* = proc(text: string): int {.closure.}
    ## The extent of `text` in the front-end's unit (cells, pixels).

proc runeMeasure*(text: string): int =
  ## One unit per code point — the default measure.
  text.runeLen

proc indentText*(row: AgentFeedRow): string =
  repeat("  ", row.indent)

proc markOf*(row: AgentFeedRow): string =
  ## The mark a native front-end draws before a row's text, where the desktop
  ## draws a coloured dot or a card's coloured edge: a tool call's dot, a
  ## card's left edge — coloured by `state`. "" for every other row.
  case row.kind
  of frToolCall: "● "
  of frTestRun, frEvidenceHeader: "▌ "
  else: ""

proc markedRows*(rows: openArray[AgentFeedRow]): seq[AgentFeedRow] =
  ## The rows with their marks written in as a leading span, so wrapping
  ## measures them like the rest of the line.
  for r in rows:
    var m = r
    let mark = r.markOf()
    if mark.len > 0:
      m.spans.insert AgentFeedSpan(text: mark, style: fsPlain), 0
    result.add m

proc wrapFeed*(rows: openArray[AgentFeedRow]; width: int;
               measure: FeedMeasure = nil): seq[AgentFeedLine] =
  ## The rows as the lines a pane `width` units wide shows: each row's
  ## indent, spans and buttons (`[Open review]`), broken at spaces where it
  ## can and mid-word where it must. Every row yields at least one line, so
  ## an empty text row still holds its place.
  let m: FeedMeasure = if measure.isNil: runeMeasure else: measure
  let w = max(1, width)
  for ri, row in rows:
    var pieces = row.spans
    for bi, b in row.buttons:
      pieces.add span("  ")
      pieces.add AgentFeedSpan(text: "[" & b.label & "]", style: fsButton,
                               button: bi + 1)
    let lead = row.indentText()
    var part = 0
    var cur: seq[AgentFeedSpan] = @[]
    var used = 0
    if lead.len > 0:
      cur.add span(lead)
      used = m(lead)
    template emit() =
      result.add AgentFeedLine(row: ri, part: part, spans: cur)
      inc part
      cur = @[]
      used = 0
      if lead.len > 0:
        cur.add span(lead)
        used = m(lead)
    for s in pieces:
      var rest = s.text
      while rest.len > 0:
        let room = w - used
        if m(rest) <= room:
          cur.add AgentFeedSpan(text: rest, style: s.style, button: s.button)
          used += m(rest)
          rest = ""
          break
        # A button is never broken across lines: it moves to the next one
        # whole when it fits there (a press is read back by the span).
        let leadCells = if lead.len > 0: m(lead) else: 0
        if s.button > 0 and used > leadCells and m(rest) <= w - leadCells:
          emit()
          continue
        # Fit as many runes as the room takes, preferring the last space.
        var take = 0
        var fitBytes = 0
        var lastSpace = -1
        for r in rest.runes:
          let piece = $r
          if m(rest[0 ..< fitBytes] & piece) > room:
            break
          fitBytes += piece.len
          inc take
          if piece == " ":
            lastSpace = fitBytes
        if take == 0:
          if used > (if lead.len > 0: m(lead) else: 0):
            emit()
            continue
          # Not even one rune fits a fresh line: place one anyway.
          fitBytes = rest.runeLenAt(0)
        elif lastSpace > 0 and lastSpace < rest.len:
          fitBytes = lastSpace
        cur.add AgentFeedSpan(text: rest[0 ..< fitBytes], style: s.style,
                              button: s.button)
        rest = rest[fitBytes .. ^1]
        emit()
    if cur.len > 0 or part == 0:
      result.add AgentFeedLine(row: ri, part: part, spans: cur)

type
  FeedScroll* = object
    ## Where the reader is in the feed.
    top*: int
      ## The first line shown.
    follow*: bool
      ## At the end, and staying there as rows arrive (the default, as a
      ## conversation is read from its newest turn).
    anchorKey*: string
    anchorPart*: int
      ## The row (by `AgentFeedRow.key`) and wrapped line the top is on, so a
      ## re-derived feed — new rows, a turn collapsing above — puts the same
      ## line back at the top.

proc initFeedScroll*(): FeedScroll = FeedScroll(follow: true)

proc maxTop*(lines, view: int): int = max(0, lines - max(1, view))

proc settle*(s: var FeedScroll; rows: openArray[AgentFeedRow];
             lines: openArray[AgentFeedLine]; view: int) =
  ## Re-place the view over a (re-)derived feed: at the end when following,
  ## else on the line it was anchored to (or that row's first line, when the
  ## row now wraps differently).
  let last = maxTop(lines.len, view)
  if s.follow:
    s.top = last
  elif s.anchorKey.len > 0:
    var found = -1
    for i, l in lines:
      if rows[l.row].key == s.anchorKey:
        if found < 0 or l.part == s.anchorPart:
          found = i
        if l.part == s.anchorPart:
          break
    if found >= 0:
      s.top = found
  s.top = clamp(s.top, 0, last)
  if s.top < lines.len:
    s.anchorKey = rows[lines[s.top].row].key
    s.anchorPart = lines[s.top].part

proc scrollTo*(s: var FeedScroll; top: int; rows: openArray[AgentFeedRow];
               lines: openArray[AgentFeedLine]; view: int) =
  ## The reader moved the view (wheel, keys, the scrubber): hold this line,
  ## and follow the end again only when it is the end.
  let last = maxTop(lines.len, view)
  s.top = clamp(top, 0, last)
  s.follow = s.top >= last
  if s.top < lines.len:
    s.anchorKey = rows[lines[s.top].row].key
    s.anchorPart = lines[s.top].part
  else:
    s.anchorKey = ""
    s.anchorPart = 0

proc lineOfRow*(lines: openArray[AgentFeedLine]; row: int): int =
  for i, l in lines:
    if l.row == row:
      return i
  -1
