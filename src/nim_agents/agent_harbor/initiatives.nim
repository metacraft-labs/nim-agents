## Initiatives -- the running plans an Agent Harbor server knows -- and their
## progress, as signal-free records and reducers.
##
## Two wire shapes:
##
## - `MilestoneFileProgress` is today's: what `GET /api/v1/tasks/{id}/milestones`
##   returns for each `.milestones.org` file (`files[]` of
##   `MilestoneProgressResponse`). `parseMilestoneFile` computes the same value
##   from a plan's text by the server's own rules (Agent Harbor's
##   `milestone_parser.rs`, ported line for line, including what it does not
##   count: a verification `status:` whose value carries more than the bare
##   word -- `passing 2026-11-04 (review) …` -- counts as none of passing,
##   failing or pending), so a front-end fed plan files shows the numbers the
##   server would send.
## - `Initiative` is proposed, not served yet: one entry of the planned
##   `GET /api/v1/initiatives` (a plan, its manager, the sessions launched for
##   it, and its progress). `initiativeFromJson` reads it leniently, so the
##   shape can grow.
##
## `applyMilestoneStatus` is the reducer for a progress event (a milestone's
## status changed in the plan); every count is derived from the milestones, so
## an event changes each count once, and an event that changes nothing is
## reported as such.

import std/[json, strutils]

type
  DeliverableCounts* = object
    done*, total*: int

  VerificationCounts* = object
    passing*, failing*, pending*: int

  MilestoneDetail* = object
    id*: string
    title*: string
    status*: string  ## as the plan writes it: `planned`, `in_progress`, …

    deliverables*: DeliverableCounts
    verifications*: VerificationCounts

  MilestoneSummary* = object
    totalMilestones*: int
    completedMilestones*: int
    progressPercent*: int
    currentMilestoneTitle*: string

  MilestoneFileProgress* = object
    path*: string
    title*: string
    currentMilestone*: string
    status*: string
    lastUpdated*: string
    milestones*: seq[MilestoneDetail]
    summary*: MilestoneSummary

  Initiative* = object
    ## One running plan (proposed `GET /api/v1/initiatives` entry).
    id*: string
    title*: string
    repository*: string     ## the repository the plan lives in (a label)
    planPath*: string
    manager*: string        ## the manager session's alias, when one runs it
    executiveSummary*: string
    sessionIds*: seq[string]
    progress*: MilestoneFileProgress

  MilestoneStatusClass* = enum
    ## How a front-end groups milestone statuses, in display order.
    mscInProgress = "in progress"
    mscPartial = "partially completed"
    mscBlocked = "blocked"
    mscPlanned = "planned"
    mscCompleted = "completed"
    mscOther = "other"

# ---------------------------------------------------------------------------
# Parsing a plan (Agent Harbor's milestone_parser.rs, ported)
# ---------------------------------------------------------------------------

proc extractProperty(line, key: string): string =
  ## `:key: value` -> value; "" when absent or empty.
  let pattern = ":" & key & ":"
  if line.startsWith(pattern): line[pattern.len .. ^1].strip else: ""

proc extractYamlValue(line, key: string): string =
  ## `status: passing` (optionally `- status: …`) -> `passing`.
  var stripped = line.strip
  while stripped.startsWith("- "): stripped = stripped[2 .. ^1]
  let pattern = key & ":"
  if stripped.startsWith(pattern): stripped[pattern.len .. ^1].strip else: ""

proc isMilestoneId*(id: string): bool =
  ## `M0`, `M0b`, `F.13`, `EP17`, `IP-M1`, `CTF-P2`; not `Notes`, `Step 1`.
  var rest = id
  let dash = id.find('-')
  if dash >= 0:
    let prefix = id[0 ..< dash]
    if prefix.len == 0 or not prefix.allCharsInSet({'A'..'Z'}): return false
    rest = id[dash + 1 .. ^1]
  var i = 0
  while i < rest.len and rest[i] in {'A'..'Z'}: inc i
  let letters = i
  if i < rest.len and rest[i] == '.': inc i
  let digitsStart = i
  while i < rest.len and rest[i] in Digits: inc i
  let digits = i - digitsStart
  if letters == 0 or digits == 0: return false
  while i < rest.len:
    if rest[i] notin Letters: return false
    inc i
  true

proc parseMilestoneHeading(line: string): tuple[ok: bool, id, title: string] =
  if not line.startsWith("** "): return
  let rest = line[3 .. ^1].strip
  let colon = rest.find(':')
  if colon < 0: return
  let id = rest[0 ..< colon]
  if not isMilestoneId(id): return
  (true, id, rest[colon + 1 .. ^1].strip)

proc summarize*(progress: var MilestoneFileProgress) =
  ## Recomputes `summary` from the milestones (the server's rule: completed
  ## means `status == completed`; the percentage is rounded half up).
  var completed = 0
  for m in progress.milestones:
    if m.status == "completed": inc completed
  let total = progress.milestones.len
  progress.summary = MilestoneSummary(
    totalMilestones: total, completedMilestones: completed,
    progressPercent: if total == 0: 0 else: (completed * 200 + total) div (2 * total))
  for m in progress.milestones:
    if m.id == progress.currentMilestone:
      progress.summary.currentMilestoneTitle = m.title
      break

proc parseMilestoneFile*(path, content: string): MilestoneFileProgress =
  ## A plan's progress, as the server computes it.
  result = MilestoneFileProgress(path: path, status: "unknown")
  var hasMilestonesSection = false
  for line in content.splitLines:
    if line.strip(leading = false) == "* Milestones":
      hasMilestonesSection = true
      break
  var inMilestones = not hasMilestonesSection
  var current: MilestoneDetail
  var hasCurrent = false
  var inVerification, inDeliverables = false
  template flush() =
    if hasCurrent:
      result.milestones.add current
      hasCurrent = false
  for line in content.splitLines:
    let trimmed = line.strip
    if line.startsWith("* "):
      if hasMilestonesSection:
        inMilestones = line[2 .. ^1].strip == "Milestones"
      flush()
      inVerification = false
      inDeliverables = false
      continue
    if trimmed.startsWith("#+TITLE:"):
      result.title = trimmed["#+TITLE:".len .. ^1].strip
      continue
    let cm = extractProperty(trimmed, "current_milestone")
    if cm.len > 0:
      result.currentMilestone = cm
      continue
    let lu = extractProperty(trimmed, "last_updated")
    if lu.len > 0:
      result.lastUpdated = lu
      continue
    let heading = parseMilestoneHeading(trimmed)
    if heading.ok and inMilestones:
      flush()
      current = MilestoneDetail(id: heading.id, title: heading.title,
                                status: "planned")
      hasCurrent = true
      inVerification = false
      inDeliverables = false
      continue
    if trimmed.startsWith("***"):
      let name = trimmed.strip(trailing = false, chars = {'*'}).strip
      inDeliverables = cmpIgnoreCase(name, "Deliverables") == 0
      inVerification = cmpIgnoreCase(name, "Verification") == 0
      continue
    let status = extractProperty(trimmed, "status")
    if status.len > 0:
      if hasCurrent: current.status = status
      else: result.status = status
      continue
    if inDeliverables and hasCurrent:
      let t = line.strip(trailing = false)
      if t.startsWith("- [x]") or t.startsWith("- [X]"):
        inc current.deliverables.done
        inc current.deliverables.total
      elif t.startsWith("- [ ]"):
        inc current.deliverables.total
    if inVerification and hasCurrent:
      case extractYamlValue(trimmed, "status")
      of "passing": inc current.verifications.passing
      of "failing": inc current.verifications.failing
      of "pending": inc current.verifications.pending
      else: discard
  flush()
  result.summarize()

proc planExecutiveSummary*(content: string): string =
  ## The document's `:executive_summary:` (before `* Milestones`), or "".
  for line in content.splitLines:
    if line.strip(leading = false) == "* Milestones": break
    let value = extractProperty(line.strip, "executive_summary")
    if value.len > 0: return value

# ---------------------------------------------------------------------------
# Status classes and counts
# ---------------------------------------------------------------------------

proc classOf*(status: string): MilestoneStatusClass =
  case status.toLowerAscii.replace('-', '_').replace(' ', '_')
  of "in_progress", "started", "active": mscInProgress
  of "partially_completed", "partial": mscPartial
  of "blocked", "failed": mscBlocked
  of "planned", "not_started", "pending", "": mscPlanned
  of "completed", "done": mscCompleted
  else: mscOther

proc statusCounts*(progress: MilestoneFileProgress): array[MilestoneStatusClass, int] =
  for m in progress.milestones: inc result[classOf(m.status)]

proc milestonesByStatus*(progress: MilestoneFileProgress):
    seq[tuple[status: MilestoneStatusClass, milestones: seq[MilestoneDetail]]] =
  ## The milestones grouped by status class, in `MilestoneStatusClass` order,
  ## each group in plan order; empty groups are left out.
  for cls in MilestoneStatusClass:
    var group: seq[MilestoneDetail]
    for m in progress.milestones:
      if classOf(m.status) == cls: group.add m
    if group.len > 0: result.add (cls, group)

proc verificationTotals*(progress: MilestoneFileProgress): VerificationCounts =
  for m in progress.milestones:
    result.passing += m.verifications.passing
    result.failing += m.verifications.failing
    result.pending += m.verifications.pending

proc applyMilestoneStatus*(progress: var MilestoneFileProgress;
                           milestoneId, status: string;
                           advanceCurrent = true): bool =
  ## A progress event: the milestone's status changed. True when anything
  ## changed (an unknown milestone or an unchanged status changes nothing).
  ## With `advanceCurrent`, a current milestone that completes hands
  ## "current" to the next milestone in plan order that is not completed (as
  ## the plan's author would before the next scan), or to none.
  for i, m in progress.milestones.mpairs:
    if m.id == milestoneId:
      if m.status == status: return false
      m.status = status
      if advanceCurrent and status == "completed" and
          progress.currentMilestone == milestoneId:
        progress.currentMilestone = ""
        for j in countup(i + 1, progress.milestones.high):
          if progress.milestones[j].status != "completed":
            progress.currentMilestone = progress.milestones[j].id
            break
      progress.summarize()
      return true
  false

# ---------------------------------------------------------------------------
# Wire decoding and encoding
# ---------------------------------------------------------------------------

proc str(node: JsonNode; key: string): string =
  if node.isNil or node.kind != JObject: return ""
  let v = node.getOrDefault(key)
  if v.isNil or v.kind != JString: "" else: v.getStr

proc int0(node: JsonNode; key: string): int =
  if node.isNil or node.kind != JObject: return 0
  let v = node.getOrDefault(key)
  if v.isNil: 0
  elif v.kind == JInt: v.getInt
  elif v.kind == JFloat: v.getFloat.int
  else: 0

proc milestoneFileProgressFromJson*(node: JsonNode): MilestoneFileProgress =
  result = MilestoneFileProgress(path: node.str("path"), title: node.str("title"),
                                 currentMilestone: node.str("currentMilestone"),
                                 status: node.str("status"),
                                 lastUpdated: node.str("lastUpdated"))
  let ms = if node.isNil or node.kind != JObject: nil else: node.getOrDefault("milestones")
  if not ms.isNil and ms.kind == JArray:
    for m in ms:
      let d = m.getOrDefault("deliverables")
      let v = m.getOrDefault("verifications")
      result.milestones.add MilestoneDetail(
        id: m.str("id"), title: m.str("title"), status: m.str("status"),
        deliverables: DeliverableCounts(done: d.int0("done"), total: d.int0("total")),
        verifications: VerificationCounts(passing: v.int0("passing"),
                                          failing: v.int0("failing"),
                                          pending: v.int0("pending")))
  let s = if node.isNil or node.kind != JObject: nil else: node.getOrDefault("summary")
  if s.isNil:
    result.summarize()
  else:
    result.summary = MilestoneSummary(
      totalMilestones: s.int0("totalMilestones"),
      completedMilestones: s.int0("completedMilestones"),
      progressPercent: s.int0("progressPercent"),
      currentMilestoneTitle: s.str("currentMilestoneTitle"))

proc toJson*(progress: MilestoneFileProgress): JsonNode =
  var milestones = newJArray()
  for m in progress.milestones:
    milestones.add %*{"id": m.id, "title": m.title, "status": m.status,
      "deliverables": {"done": m.deliverables.done, "total": m.deliverables.total},
      "verifications": {"passing": m.verifications.passing,
                        "failing": m.verifications.failing,
                        "pending": m.verifications.pending}}
  result = %*{"path": progress.path, "title": progress.title,
              "status": progress.status, "milestones": milestones,
              "summary": {"totalMilestones": progress.summary.totalMilestones,
                          "completedMilestones": progress.summary.completedMilestones,
                          "progressPercent": progress.summary.progressPercent}}
  if progress.currentMilestone.len > 0:
    result["currentMilestone"] = %progress.currentMilestone
  if progress.lastUpdated.len > 0:
    result["lastUpdated"] = %progress.lastUpdated
  if progress.summary.currentMilestoneTitle.len > 0:
    result["summary"]["currentMilestoneTitle"] = %progress.summary.currentMilestoneTitle

proc initiativeFromJson*(node: JsonNode): Initiative =
  result = Initiative(id: node.str("id"), title: node.str("title"),
                      repository: node.str("repository"),
                      planPath: node.str("planPath"), manager: node.str("manager"),
                      executiveSummary: node.str("executiveSummary"))
  let sessions = if node.isNil or node.kind != JObject: nil else: node.getOrDefault("sessions")
  if not sessions.isNil and sessions.kind == JArray:
    for s in sessions:
      if s.kind == JString: result.sessionIds.add s.getStr
      elif s.kind == JObject: result.sessionIds.add s.str("id")
  let progress = if node.isNil or node.kind != JObject: nil else: node.getOrDefault("progress")
  if not progress.isNil: result.progress = milestoneFileProgressFromJson(progress)
  if result.title.len == 0: result.title = result.progress.title

proc toJson*(initiative: Initiative): JsonNode =
  var sessions = newJArray()
  for id in initiative.sessionIds: sessions.add %id
  %*{"id": initiative.id, "title": initiative.title,
     "repository": initiative.repository, "planPath": initiative.planPath,
     "manager": initiative.manager,
     "executiveSummary": initiative.executiveSummary,
     "sessions": sessions, "progress": initiative.progress.toJson}

proc initiativesFromJson*(node: JsonNode): seq[Initiative] =
  ## `{"items": [...]}` or a bare array.
  var items = node
  if not node.isNil and node.kind == JObject: items = node.getOrDefault("items")
  if not items.isNil and items.kind == JArray:
    for item in items: result.add initiativeFromJson(item)
