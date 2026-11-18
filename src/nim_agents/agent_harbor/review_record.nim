## The review record of a plan: what a campaign changed, in the order a
## reviewer reads it -- spec changes, tests, implementation details, code
## (INV-D-08 … INV-D-12) -- as signal-free records, read from the plan's
## milestones file.
##
## **Where the record is.** Each milestone of an Agent Harbor plan file
## (`** <id>: <title>`) may carry four subsections, one per reviewer's view:
##
## - `*** Spec Changes`: one list entry per changed spec file, a record of
##   `key: value` lines -- `spec`, `sections` (`;`-separated), `summary`,
##   `commits` (space-separated short SHAs), `approval`. Required: `spec`,
##   `summary`, `commits`, `approval`.
## - `*** Verification`: the milestone's tests (`test_name`, `file`,
##   `description`, `status`, and the assurance fields).
## - `*** Implementation Details`: notes, kept as written.
## - `*** Key Source Files`: one entry per file, `- <path> — <what it does>`.
##
## **Approval.** An entry's `approval` is exactly one of `pending`,
## `editorial`, `approved <date> by <who> (feedback <id>)` or
## `approved <date> by <who> (relayed by <relay>)`. The date is ten ASCII
## characters, `YYYY-MM-DD`, naming a real calendar day; `who`, `id` and
## `relay` are non-empty; one matched pair of outer `'…'` or `"…"` quotes is
## stripped before the value is read. Anything else is malformed. A missing
## or blank required field, or a field named twice, makes the entry malformed
## too, and a malformed entry is never shown as approved. A field the record
## does not define is ignored, as Agent Harbor's own completion gate ignores
## it: the record's rule refuses unknown *approvals*, not unknown fields.
## Every list entry of a `*** Spec Changes` subsection directly under the
## milestone (a heading with a suffix, such as `*** Spec Changes (follow-up)`,
## included) is a record; its fields come from its own paragraphs only (blank
## lines between them allowed), so a nested list or source block can never
## grant an approval. A legacy entry that is not a record at all
## (`- =specs/x.md= — what changed`) is kept with its text and read as
## `approval not recorded`: free text never implies an approval.
##
## **Tiers.** The Spec Changes tab shows three tiers. Tiers 1 and 2 are read
## from the change's diff, deterministically (no model is involved in what a
## screen shows): one tier-1 card per authoritative requirement -- a
## `### <NS>-AREQ<n>` heading -- added, changed or removed in a hunk of a
## spec file, and one tier-2 card per changed governance file (`AGENTS.md`,
## `CLAUDE.md`, `.ah/manager/**`, `.ah/autonomy.md`). Tier 3 is the
## record's entries, one card per changed spec. An entry's `sections` never
## makes it a tier-1 card: the diff decides. A distilled update that a
## workspace holds back for the operator's approval is a *staged* tier-1 or
## tier-2 card (`TierCard.staged`, with Approve & Apply, Discard and Request
## Changes); it is not committed, so neither the plan nor the diff can say
## it, and only the served record carries it (`ReviewRecord.stagedCards`).
##
## **Tests.** The Tests tab classifies a status by its leading token
## (`passing`, `failing`, `pending`, and the aliases `passed`, `failed`,
## `completed`, `done`), and keeps the rest of the value as its annotation
## (`passing 2026-11-04 (review) …` is passing). This differs on purpose from
## `initiatives.parseMilestoneFile`, which ports the server's progress
## counter: that counter counts an annotated status as none of the three,
## and Initiative Progress shows what the server would send.
##
## Only the inline layout (the four subsections inside each milestone) is
## read. `reviewRecordFromJson` reads the proposed served form of the same
## record leniently, as `initiativeFromJson` reads the proposed initiatives.
##
## Signal-free and app-agnostic; identical on the C and JS targets.

import std/[algorithm, json, strutils]
import ./[initiatives, change_diff]

type
  ApprovalState* = enum
    apPending = "pending"
    apApproved = "approved"
    apEditorial = "editorial"
    apMalformed = "malformed"
    apUnstructured = "approval not recorded"

  SpecApproval* = object
    state*: ApprovalState
    date*: string         ## apApproved: `YYYY-MM-DD`
    who*: string          ## apApproved: who approved
    feedbackId*: string   ## apApproved through a feedback request
    relay*: string        ## apApproved and relayed
    reason*: string       ## apMalformed: what is wrong (`approval`, `missing spec`, …)

  SpecTier* = enum
    stRequirement = "requirements"  ## tier 1, from the diff
    stGovernance = "governance"     ## tier 2, from the diff
    stSpec = "specs"                ## tier 3, from the record

  SpecChange* = object
    ## One tier-3 card: an entry of a `*** Spec Changes` subsection.
    milestoneId*: string
    spec*: string
    sections*: seq[string]
    summary*: string
    commits*: seq[string]
    approval*: SpecApproval
    raw*: string          ## the entry's paragraphs as written
    problems*: seq[string]
      ## why the entry is malformed, each `missing <field>` (absent or
      ## blank), `duplicate <field>` or `approval`

  RequirementChange* = enum
    rcAdded = "added"
    rcModified = "modified"
    rcRemoved = "removed"

  TierCard* = object
    ## A tier-1 or tier-2 card, read from the diff.
    tier*: SpecTier
    path*: string
    requirement*: string     ## tier 1: the requirement's id (`ACME-AREQ3`)
    heading*: string         ## tier 1: its heading line, without `###`
    change*: RequirementChange
    hunks*: seq[DiffHunk]    ## the hunks that touch it, for its inline diff
    origin*: string
      ## `operator-distilled` or `branch-commit`: a proposed served field;
      ## "" when nothing says it
    staged*: bool
      ## a distilled update held back until the operator presses Approve &
      ## Apply (a proposed served field; never read from a plan or a diff)

  VerificationStatus* = enum
    vsFailing = "failing"
    vsPending = "pending"
    vsPassing = "passing"
    vsUnknown = "unknown"

  VerificationEntry* = object
    milestoneId*: string
    testName*: string
    file*: string
    description*: string
    status*: VerificationStatus
    rawStatus*: string
    annotation*: string     ## what follows the leading token
    vacuityGuard*: string
    negativeControl*: string
    falsifyingMutation*: string
    allowedMocks*: string

  KeySourceFile* = object
    path*: string
    purpose*: string

  Deliverable* = object
    text*: string
    done*: bool

  ReviewMilestone* = object
    id*, title*, status*: string
    specChanges*: seq[SpecChange]
    verifications*: seq[VerificationEntry]
    implementationDetails*: string
    keySourceFiles*: seq[KeySourceFile]
    deliverables*: seq[Deliverable]

  ReviewRecord* = object
    path*: string
    title*: string
    milestones*: seq[ReviewMilestone]
    stagedCards*: seq[TierCard]
      ## the staged tier-1 and tier-2 cards the server holds (served only)

  ReviewTab* = enum
    ## The Changes panel's tabs, in the reviewer's order.
    rtSpecChanges = "Spec Changes"
    rtTests = "Tests"
    rtImplementation = "Implementation Details"
    rtCode = "Code"

  SpecCard* = object
    ## One card of the Spec Changes tab, in its tier.
    tier*: SpecTier
    fromDiff*: TierCard   ## tiers 1 and 2: read from the diff
    entry*: SpecChange    ## tier 3: the record's entry

  TestGroup* = object
    milestoneId*, title*: string
    entries*: seq[VerificationEntry]

const
  SpecFields* = ["spec", "sections", "summary", "commits", "approval"]
  RequiredSpecFields* = ["spec", "summary", "commits", "approval"]
  DefaultSpecRoots* = ["specs/"]
  NoSpecChangesText* = "No spec changes in this scope."
  NoImplementationDetailsText* = "No implementation details in this scope."
  NoTestsText* = "No tests in this scope."

# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

proc stripOuterQuotes*(value: string): string =
  ## One matched pair of outer `'…'` or `"…"` removed; anything else as it is.
  let v = value.strip
  if v.len >= 2 and v[0] == v[^1] and v[0] in {'\'', '"'}: v[1 .. ^2] else: v

proc isLeapYear(y: int): bool = (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0

proc isCalendarDate*(text: string): bool =
  ## Exactly `YYYY-MM-DD` in ten ASCII characters, naming a real day
  ## (`2026-02-30`, `+2026-11-04` and `20261-11-04` are not).
  if text.len != 10 or text[4] != '-' or text[7] != '-': return false
  for i in [0, 1, 2, 3, 5, 6, 8, 9]:
    if text[i] notin Digits: return false
  let y = parseInt(text[0 .. 3])
  let m = parseInt(text[5 .. 6])
  let d = parseInt(text[8 .. 9])
  if m < 1 or m > 12 or d < 1: return false
  let days = case m
    of 2: (if isLeapYear(y): 29 else: 28)
    of 4, 6, 9, 11: 30
    else: 31
  d <= days

proc parseApproval*(value: string): SpecApproval =
  ## An entry's `approval` value, read exactly as the record's grammar says;
  ## anything it does not allow is `apMalformed` (never approved).
  let v = stripOuterQuotes(value)
  if v == "pending": return SpecApproval(state: apPending)
  if v == "editorial": return SpecApproval(state: apEditorial)
  result = SpecApproval(state: apMalformed, reason: "approval")
  const Lead = "approved "
  if not v.startsWith(Lead): return
  let rest = v[Lead.len .. ^1]
  let space = rest.find(' ')
  if space < 0: return
  let date = rest[0 ..< space]
  if not isCalendarDate(date): return
  var tail = rest[space + 1 .. ^1]
  if not tail.startsWith("by ") or not tail.endsWith(")"): return
  tail = tail[3 ..< ^1]
  # The source is the last ` (feedback ` -- else the last ` (relayed by ` --
  # so both `who` and the relay may hold parentheses of their own
  # (`Alice (operator)`, `relayed by Morgan (manager)`), as in Agent
  # Harbor's own gate.
  const FeedbackMark = " (feedback "
  const RelayMark = " (relayed by "
  var at = tail.rfind(FeedbackMark)
  let byFeedback = at >= 0
  if not byFeedback: at = tail.rfind(RelayMark)
  if at < 0: return
  let who = tail[0 ..< at].strip
  let reference = tail[at + (if byFeedback: FeedbackMark.len else: RelayMark.len) .. ^1].strip
  if who.len == 0 or reference.len == 0: return
  result =
    if byFeedback: SpecApproval(state: apApproved, date: date, who: who, feedbackId: reference)
    else: SpecApproval(state: apApproved, date: date, who: who, relay: reference)

proc isApproved*(approval: SpecApproval): bool =
  ## The only test a view uses to show a change as approved.
  approval.state == apApproved

proc approvalText*(approval: SpecApproval): string =
  ## The words a card shows for its state: `pending`, `approved 2026-11-04
  ## by operator (feedback fb-1)`, `editorial`, `malformed: <reason>`,
  ## `approval not recorded`. (A staged card is a tier-1 or tier-2 card,
  ## `TierCard.staged`, not an approval state.)
  case approval.state
  of apApproved:
    "approved " & approval.date & " by " & approval.who &
      (if approval.feedbackId.len > 0: " (feedback " & approval.feedbackId & ")"
       else: " (relayed by " & approval.relay & ")")
  of apMalformed: "malformed: " & approval.reason
  else: $approval.state

proc verificationStatusOf*(value: string): tuple[status: VerificationStatus,
                                                 annotation: string] =
  ## A verification `status` by its leading token, with the rest as the
  ## annotation (`passing 2026-11-04 (review) …` -> passing, `2026-11-04 …`).
  let v = value.strip
  var i = 0
  while i < v.len and v[i] in Letters + {'_'}: inc i
  let token = v[0 ..< i]
  let annotation = v[i .. ^1].strip(chars = Whitespace + {';', ',', ':'})
  let status = case token
    of "passing", "passed", "completed", "done": vsPassing
    of "failing", "failed": vsFailing
    of "pending": vsPending
    else: vsUnknown
  (status, if status == vsUnknown: v else: annotation)

# ---------------------------------------------------------------------------
# Parsing a plan
# ---------------------------------------------------------------------------

type
  Section = enum
    secNone, secSpecChanges, secVerification, secImplementation,
    secKeySourceFiles, secDeliverables, secOther

  ListEntry = object
    ## One list entry of a subsection: its own paragraphs (the first line and
    ## the lines continuing it), without nested lists or blocks.
    paragraph: seq[string]

proc indentOf(line: string): int =
  while result < line.len and line[result] == ' ': inc result

proc isListItem(trimmed: string): bool =
  trimmed.startsWith("- ") or trimmed.startsWith("+ ") or trimmed == "-"

proc listEntries(lines: openArray[string]): seq[ListEntry] =
  ## The top-level list entries of a subsection's body, each with the lines
  ## of its own paragraphs: every line indented past the entry's bullet,
  ## across blank lines, except the lines of a nested list item (a bullet
  ## indented past the entry's, and everything indented past that bullet)
  ## and of a `#+begin_…` / `#+end_…` block. A line back at the list's
  ## margin that is not a bullet ends the list.
  var entryIndent = -1    # the current entry's bullet indent; -1 outside one
  var nestedIndent = -1   # the bullet indent of the nested item being skipped
  var inBlock = false
  for line in lines:
    let trimmed = line.strip
    let indent = line.indentOf
    if inBlock:
      if trimmed.toLowerAscii.startsWith("#+end_"): inBlock = false
      continue
    if trimmed.len == 0: continue
    if trimmed.isListItem and (entryIndent < 0 or indent <= entryIndent):
      entryIndent = indent
      nestedIndent = -1
      result.add ListEntry(paragraph: @[if trimmed.len > 2: trimmed[2 .. ^1].strip else: ""])
      continue
    if entryIndent < 0: continue
    if indent <= entryIndent:
      entryIndent = -1    # text at the margin: the list is over
      nestedIndent = -1
      continue
    if nestedIndent >= 0 and indent > nestedIndent: continue
    if trimmed.isListItem:
      nestedIndent = indent   # a nested list: never part of the record
      continue
    nestedIndent = -1
    if trimmed.toLowerAscii.startsWith("#+begin_"):
      inBlock = true
      continue
    result[^1].paragraph.add trimmed

proc fieldOf(line: string): tuple[ok: bool, key, value: string] =
  ## `key: value`, split at the first colon as Agent Harbor's parser splits
  ## it: the key is case-insensitive and must be an identifier (letters,
  ## digits, `_`, starting with a letter), the value is raw to the end of
  ## the line, trimmed.
  let colon = line.find(':')
  if colon <= 0: return
  let key = line[0 ..< colon].strip.toLowerAscii
  if key.len == 0 or not key.allCharsInSet({'a'..'z', '_', '0'..'9'}) or
      key[0] notin {'a'..'z'}:
    return
  (true, key, line[colon + 1 .. ^1].strip)

proc splitPathAndText(text: string): tuple[path, rest: string] =
  ## `=path= — text`, `path - text`, `path :: text`: the leading path (Org
  ## verbatim markup removed) and what follows the separator.
  let t = text.strip
  var path, rest: string
  if t.startsWith("="):
    let close = t.find('=', 1)
    if close > 0:
      path = t[1 ..< close]
      rest = t[close + 1 .. ^1]
  if path.len == 0:
    let space = t.find(' ')
    if space < 0: return (t, "")
    path = t[0 ..< space]
    rest = t[space .. ^1]
  rest = rest.strip
  for sep in ["\xE2\x80\x94", "\xE2\x80\x93", "::", "-", ":"]:
    if rest.startsWith(sep):
      rest = rest[sep.len .. ^1].strip
      break
  (path, rest)

proc specChangeOf(entry: ListEntry; milestoneId: string): SpecChange =
  result = SpecChange(milestoneId: milestoneId, raw: entry.paragraph.join("\n"))
  if entry.paragraph.len == 0 or not fieldOf(entry.paragraph[0]).ok:
    # Not a record: a legacy line. Kept for its text; never approved.
    let (path, rest) = splitPathAndText(entry.paragraph.join(" "))
    result.spec = path
    result.summary = rest
    result.approval = SpecApproval(state: apUnstructured)
    return
  var seen: seq[string]
  var approvalValue = ""
  for line in entry.paragraph:
    let f = fieldOf(line)
    if not f.ok: continue   # free text inside a record carries no field
    if f.key in seen:
      result.problems.add "duplicate " & f.key
      continue
    seen.add f.key
    case f.key
    of "spec": result.spec = f.value
    of "sections":
      for s in f.value.split(';'):
        if s.strip.len > 0: result.sections.add s.strip
    of "summary": result.summary = f.value
    of "commits": result.commits = f.value.splitWhitespace()
    of "approval": approvalValue = f.value
    else: discard
  # A field the record does not define (`reviewer: …`) is ignored, as the
  # gate ignores it. A required field that is absent or blank is missing.
  let present = [result.spec.len > 0, result.summary.len > 0,
                 result.commits.len > 0, approvalValue.len > 0]
  for i, required in RequiredSpecFields:
    if not present[i]: result.problems.add "missing " & required
  result.approval = parseApproval(approvalValue)
  if result.approval.state == apMalformed and present[3]:
    result.problems.add "approval"
  if result.problems.len > 0:
    result.approval = SpecApproval(state: apMalformed, reason: result.problems[0])

proc verificationOf(entry: ListEntry; milestoneId: string): VerificationEntry =
  result = VerificationEntry(milestoneId: milestoneId, status: vsUnknown)
  for line in entry.paragraph:
    let f = fieldOf(line)
    if not f.ok: continue
    case f.key
    of "test_name": result.testName = stripOuterQuotes(f.value)
    of "file": result.file = f.value
    of "description": result.description = f.value
    of "status":
      result.rawStatus = f.value
      let s = verificationStatusOf(f.value)
      result.status = s.status
      result.annotation = s.annotation
    of "vacuity_guard", "anti_vacuity": result.vacuityGuard = f.value
    of "negative_control", "control_arm": result.negativeControl = f.value
    of "falsifying_mutation", "mutation", "falsifier": result.falsifyingMutation = f.value
    of "allowed_mocks": result.allowedMocks = f.value
    else: discard

proc dedent(lines: openArray[string]): string =
  ## The lines without their common indentation and outer blank lines.
  var common = high(int)
  for l in lines:
    if l.strip.len > 0: common = min(common, l.indentOf)
  var kept: seq[string]
  for l in lines:
    kept.add(if l.strip.len == 0: "" else: l[min(common, l.len) .. ^1].strip(leading = false))
  while kept.len > 0 and kept[0].len == 0: kept.delete(0)
  while kept.len > 0 and kept[^1].len == 0: kept.setLen(kept.len - 1)
  kept.join("\n")

proc sectionOf(name: string): Section =
  ## A `***` subsection by its name; a suffix after the name is allowed
  ## (`Spec Changes (follow-up)`). Every subsection whose name starts with
  ## `Spec Changes` is one, as Agent Harbor's gate reads them.
  let n = name.strip.toLowerAscii
  proc named(n, word: string): bool =
    n == word or n.startsWith(word & " ") or n.startsWith(word & ":") or
      n.startsWith(word & "(")
  if n.startsWith("spec changes"): secSpecChanges
  elif n.named("verification"): secVerification
  elif n.named("implementation details"): secImplementation
  elif n.named("key source files"): secKeySourceFiles
  elif n.named("deliverables"): secDeliverables
  else: secOther

proc parseReviewRecord*(path, content: string): ReviewRecord =
  ## A plan's review record: its milestones (the headings
  ## `initiatives.parseMilestoneHeading` accepts, under `* Milestones` when
  ## the plan has that section), each with its four subsections.
  result = ReviewRecord(path: path)
  var hasMilestonesSection = false
  for line in content.splitLines:
    if line.strip(leading = false) == "* Milestones":
      hasMilestonesSection = true
      break
  var inMilestones = not hasMilestonesSection
  var current: ReviewMilestone
  var hasCurrent = false
  var section = secNone
  var body: seq[string]
  template flushSection() =
    if hasCurrent:
      case section
      of secSpecChanges:
        for e in listEntries(body): current.specChanges.add specChangeOf(e, current.id)
      of secVerification:
        for e in listEntries(body):
          let v = verificationOf(e, current.id)
          if v.testName.len > 0 or v.description.len > 0: current.verifications.add v
      of secImplementation:
        let text = dedent(body)
        if text.len > 0:
          current.implementationDetails =
            if current.implementationDetails.len == 0: text
            else: current.implementationDetails & "\n\n" & text
      of secKeySourceFiles:
        for e in listEntries(body):
          let (p, purpose) = splitPathAndText(e.paragraph.join(" "))
          if p.len > 0: current.keySourceFiles.add KeySourceFile(path: p, purpose: purpose)
      of secDeliverables:
        for e in listEntries(body):
          let first = e.paragraph[0]
          if first.startsWith("[X]") or first.startsWith("[x]"):
            current.deliverables.add Deliverable(text: first[3 .. ^1].strip, done: true)
          elif first.startsWith("[ ]") or first.startsWith("[-]"):
            current.deliverables.add Deliverable(text: first[3 .. ^1].strip)
      else: discard
    body.setLen 0
  template flushMilestone() =
    flushSection()
    if hasCurrent:
      result.milestones.add current
      hasCurrent = false
    section = secNone
  for line in content.splitLines:
    let trimmed = line.strip
    if line.startsWith("* "):
      flushMilestone()
      if hasMilestonesSection: inMilestones = line[2 .. ^1].strip == "Milestones"
      continue
    if trimmed.startsWith("#+TITLE:") and not hasCurrent:
      result.title = trimmed["#+TITLE:".len .. ^1].strip
      continue
    let heading = parseMilestoneHeading(trimmed)
    if heading.ok and inMilestones and line.startsWith("** "):
      flushMilestone()
      current = ReviewMilestone(id: heading.id, title: heading.title, status: "planned")
      hasCurrent = true
      continue
    if line.startsWith("** "):
      # A level-2 heading that is not a milestone ends the milestone.
      flushMilestone()
      continue
    if line.startsWith("*** "):
      flushSection()
      section = sectionOf(line[4 .. ^1])
      continue
    if line.startsWith("****"):
      # A deeper heading is not a direct subsection: its body is not read.
      flushSection()
      section = secOther
      continue
    if hasCurrent and section == secNone:
      # The milestone's property drawer, before its first subsection.
      if trimmed.startsWith(":status:"):
        current.status = trimmed[":status:".len .. ^1].strip
      continue
    if hasCurrent: body.add line
  flushMilestone()

# ---------------------------------------------------------------------------
# Tiers 1 and 2, from the diff
# ---------------------------------------------------------------------------

proc requirementHeading*(line: string): tuple[ok: bool, id, heading: string] =
  ## `### <NS>-AREQ<n> <title>` (the namespace upper-case letters and digits
  ## starting with a letter, `n` digits); `ok` false for any other line.
  let t = line.strip
  if not t.startsWith("### "): return
  let heading = t[4 .. ^1].strip
  var i = 0
  while i < heading.len and heading[i] in {'A'..'Z', '0'..'9'}: inc i
  if i == 0 or heading[0] notin {'A'..'Z'}: return
  if not heading.continuesWith("-AREQ", i): return
  i += "-AREQ".len
  let digitsStart = i
  while i < heading.len and heading[i] in Digits: inc i
  if i == digitsStart: return
  if i < heading.len and heading[i] notin {' ', ':', '.', '\t'}: return
  (true, heading[0 ..< i], heading)

proc isSpecFile*(path: string; specRoots: openArray[string] = DefaultSpecRoots): bool =
  ## A file under one of the spec roots, or an `Authoritative-Requirements.md`
  ## wherever it is.
  if path.endsWith("Authoritative-Requirements.md"): return true
  for root in specRoots:
    if root.len > 0 and path.startsWith(root): return true
  false

proc isGovernanceFile*(path: string): bool =
  ## A file that steers agents' behaviour across the repository: an
  ## `AGENTS.md` or `CLAUDE.md` anywhere, the manager's behaviour files
  ## (`.ah/manager/**`) and `.ah/autonomy.md`.
  let name = path.rsplit('/', maxsplit = 1)[^1]
  name in ["AGENTS.md", "CLAUDE.md"] or path.startsWith(".ah/manager/") or
    "/.ah/manager/" in path or path == ".ah/autonomy.md" or
    path.endsWith("/.ah/autonomy.md")

proc cardIndex(cards: var seq[TierCard]; path, id, heading: string): int =
  ## The index of the tier-1 card for requirement `id`, added when new.
  for i, c in cards:
    if c.requirement == id: return i
  cards.add TierCard(tier: stRequirement, path: path, requirement: id,
                     heading: heading)
  cards.high

proc extractTierCards*(diff: ChangeDiff;
                       specRoots: openArray[string] = DefaultSpecRoots): seq[TierCard] =
  ## The tier-1 cards (one per requirement heading a spec hunk adds, changes
  ## or removes, in the diff's order) followed by the tier-2 cards (one per
  ## changed governance file). A requirement whose heading line is only
  ## added is `rcAdded`, only removed `rcRemoved`; a heading on both sides,
  ## or a changed line under an unchanged heading, is `rcModified`.
  var governance: seq[TierCard]
  for file in diff.files:
    if file.path.isGovernanceFile or file.oldPath.isGovernanceFile:
      governance.add TierCard(tier: stGovernance, path: file.path, hunks: file.hunks,
                              change: (case file.status
                                       of csAdded: rcAdded
                                       of csDeleted: rcRemoved
                                       else: rcModified))
    if not (file.path.isSpecFile(specRoots) or file.oldPath.isSpecFile(specRoots)):
      continue
    var cards: seq[TierCard]
    var added, removed, body: seq[string]   # requirement ids
    for hunk in file.hunks:
      # The requirement a line belongs to: the last heading seen, seeded by
      # the heading git prints after `@@` when the hunk starts inside one
      # (with a `diff=markdown` attribute). Without that, the lines of a hunk
      # before its first heading belong to no requirement.
      var current = requirementHeading(hunk.section)
      var touched: seq[int]
      for line in hunk.lines:
        let h = requirementHeading(line.text)
        if line.text.strip.startsWith("#"): current = h
        var at = -1
        if h.ok:
          at = cardIndex(cards, file.path, h.id, h.heading)
          case line.kind
          of dlAdded: added.add h.id
          of dlRemoved: removed.add h.id
          else: discard
        elif line.kind in {dlAdded, dlRemoved} and current.ok:
          at = cardIndex(cards, file.path, current.id, current.heading)
          body.add current.id
        if at >= 0 and at notin touched: touched.add at
      for at in touched: cards[at].hunks.add hunk
    for c in cards.mitems:
      let a = c.requirement in added
      let r = c.requirement in removed
      c.change =
        if a and not r: rcAdded
        elif r and not a: rcRemoved
        else: rcModified
    for c in cards:
      if c.requirement in added or c.requirement in removed or c.requirement in body:
        result.add c
  result.add governance

proc specChangesFromDiff*(diff: ChangeDiff;
                          specRoots: openArray[string] = DefaultSpecRoots): seq[SpecChange] =
  ## For a task with no plan: one tier-3 card per changed spec file, with no
  ## summary and no recorded approval.
  for file in diff.files:
    if file.path.isSpecFile(specRoots) or file.oldPath.isSpecFile(specRoots):
      result.add SpecChange(spec: file.path, approval: SpecApproval(state: apUnstructured))

# ---------------------------------------------------------------------------
# Scope, tabs, tests
# ---------------------------------------------------------------------------

proc scopeOf*(record: ReviewRecord; milestoneId = ""): seq[ReviewMilestone] =
  ## The milestones a view shows: all of the record's for "", or the one
  ## named (none when the record has no such milestone).
  if milestoneId.len == 0: return record.milestones
  for m in record.milestones:
    if m.id == milestoneId: return @[m]

proc restrictTo*(record: ReviewRecord; milestoneIds: openArray[string]): ReviewRecord =
  ## The record of a task: only the milestones it worked on, in plan order.
  result = ReviewRecord(path: record.path, title: record.title)
  for m in record.milestones:
    if m.id in milestoneIds: result.milestones.add m

proc specChangesOf*(milestones: openArray[ReviewMilestone]): seq[SpecChange] =
  for m in milestones:
    for c in m.specChanges: result.add c

proc keySourcePaths*(milestones: openArray[ReviewMilestone]): seq[string] =
  for m in milestones:
    for k in m.keySourceFiles:
      if k.path notin result: result.add k.path

proc specCards*(milestones: openArray[ReviewMilestone]; diff: ChangeDiff;
                hasPlan = true;
                specRoots: openArray[string] = DefaultSpecRoots;
                staged: openArray[TierCard] = []): seq[SpecCard] =
  ## The Spec Changes tab, in its tiers: the requirement cards the diff
  ## yields and the staged requirement cards, the governance cards the diff
  ## yields and the staged governance cards, then one card per entry of the
  ## milestones in scope -- or, for a task with no plan, per spec file the
  ## diff changes. Tiers 1 and 2 come from the diff (and the served staged
  ## cards) alone: an entry naming a requirement in its `sections` stays a
  ## tier-3 card.
  let fromDiff = extractTierCards(diff, specRoots)
  for tier in [stRequirement, stGovernance]:
    for c in fromDiff:
      if c.tier == tier: result.add SpecCard(tier: tier, fromDiff: c)
    for c in staged:
      if c.tier == tier: result.add SpecCard(tier: tier, fromDiff: c)
  let entries = if hasPlan: specChangesOf(milestones) else: specChangesFromDiff(diff, specRoots)
  for e in entries:
    result.add SpecCard(tier: stSpec, entry: e)

proc tabsOf*(hasPlan: bool): seq[ReviewTab] =
  ## The tabs a change shows: all four, or for a task with no plan only Spec
  ## Changes (read from the diff) and Code.
  if hasPlan: @[rtSpecChanges, rtTests, rtImplementation, rtCode]
  else: @[rtSpecChanges, rtCode]

proc tabCount*(tab: ReviewTab; milestones: openArray[ReviewMilestone];
               tierCards: openArray[TierCard]; diff: ChangeDiff): int =
  ## The number a tab shows beside its label.
  case tab
  of rtSpecChanges:
    result = tierCards.len + specChangesOf(milestones).len
  of rtTests:
    for m in milestones: result += m.verifications.len
  of rtImplementation:
    for m in milestones:
      if m.implementationDetails.len > 0: inc result
      result += m.keySourceFiles.len
  of rtCode:
    result = diff.files.len

proc firstTabWithContent*(tabs: openArray[ReviewTab];
                          counts: openArray[int]): ReviewTab =
  ## The tab a Changes panel opens on: the first, in the reviewer's order,
  ## whose count is not zero; the first tab when none has content.
  for i, t in tabs:
    if i < counts.len and counts[i] > 0: return t
  if tabs.len > 0: tabs[0] else: rtCode

proc tabLabel*(tab: ReviewTab; compact = false): string =
  ## A tab's label; the compact form for a narrow panel (`Specs`, `Tests`,
  ## `Details`, `Code`), so every front-end shortens them alike.
  if not compact: return $tab
  case tab
  of rtSpecChanges: "Specs"
  of rtTests: "Tests"
  of rtImplementation: "Details"
  of rtCode: "Code"

proc testGroups*(milestones: openArray[ReviewMilestone]): seq[TestGroup] =
  ## The Tests tab: entries grouped by milestone, failing first -- groups
  ## with a failing entry before the others, and within a group failing
  ## entries first; both otherwise in plan order. Milestones with no entry
  ## are left out.
  var withFailing, rest: seq[TestGroup]
  for m in milestones:
    if m.verifications.len == 0: continue
    var g = TestGroup(milestoneId: m.id, title: m.title, entries: m.verifications)
    g.entries.sort(proc (a, b: VerificationEntry): int =
      cmp(a.status != vsFailing, b.status != vsFailing), SortOrder.Ascending)
    if g.entries[0].status == vsFailing: withFailing.add g else: rest.add g
  withFailing & rest

# ---------------------------------------------------------------------------
# The proposed served record
# ---------------------------------------------------------------------------

proc str(node: JsonNode; key: string): string =
  if node.isNil or node.kind != JObject: return ""
  let v = node.getOrDefault(key)
  if v.isNil or v.kind != JString: "" else: v.getStr

proc arr(node: JsonNode; key: string): seq[JsonNode] =
  if node.isNil or node.kind != JObject: return
  let v = node.getOrDefault(key)
  if not v.isNil and v.kind == JArray:
    for x in v: result.add x

proc strings(node: JsonNode; key: string): seq[string] =
  for x in node.arr(key):
    if x.kind == JString: result.add x.getStr

proc reviewRecordFromJson*(node: JsonNode): ReviewRecord =
  ## The proposed served review record (`GET /api/v1/tasks/{id}/review-record`),
  ## read leniently: unknown fields are ignored, missing ones are empty. An
  ## approval is read from its text with `parseApproval`, so the served form
  ## can never approve what the plan's text would not. The staged tier-1 and
  ## tier-2 cards (`stagedCards`, each `{tier, path, requirement, heading,
  ## change, origin}`) are what only a server can say.
  result = ReviewRecord(path: node.str("path"), title: node.str("title"))
  for c in node.arr("stagedCards"):
    if c.kind != JObject: continue
    result.stagedCards.add TierCard(
      tier: if c.str("tier") == $stGovernance: stGovernance else: stRequirement,
      path: c.str("path"), requirement: c.str("requirement"), heading: c.str("heading"),
      change: (case c.str("change")
               of $rcAdded: rcAdded
               of $rcRemoved: rcRemoved
               else: rcModified),
      origin: c.str("origin"), staged: true)
  for m in node.arr("milestones"):
    var rm = ReviewMilestone(id: m.str("id"), title: m.str("title"),
                             status: m.str("status"),
                             implementationDetails: m.str("implementationDetails"))
    for c in m.arr("specChanges"):
      var sc = SpecChange(milestoneId: rm.id, spec: c.str("spec"),
                          sections: c.strings("sections"), summary: c.str("summary"),
                          commits: c.strings("commits"), raw: c.str("raw"))
      let a = c.str("approval")
      sc.approval =
        if a.len == 0: SpecApproval(state: apUnstructured)
        else: parseApproval(a)
      for field in RequiredSpecFields:
        if field != "approval" and (if field == "commits": sc.commits.len == 0
                                    else: c.str(field).len == 0):
          sc.problems.add "missing " & field
      if sc.problems.len > 0 and sc.approval.state != apUnstructured:
        sc.approval = SpecApproval(state: apMalformed, reason: sc.problems[0])
      rm.specChanges.add sc
    for v in m.arr("verifications"):
      var ve = VerificationEntry(milestoneId: rm.id, testName: v.str("testName"),
                                 file: v.str("file"), description: v.str("description"),
                                 rawStatus: v.str("status"))
      let s = verificationStatusOf(ve.rawStatus)
      ve.status = s.status
      ve.annotation = s.annotation
      rm.verifications.add ve
    for k in m.arr("keySourceFiles"):
      if k.kind == JString: rm.keySourceFiles.add KeySourceFile(path: k.getStr)
      else: rm.keySourceFiles.add KeySourceFile(path: k.str("path"), purpose: k.str("purpose"))
    result.milestones.add rm
