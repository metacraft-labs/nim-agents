## The review record of nim-agents: a plan's spec changes, tests,
## implementation details and key source files read from its milestones
## file, the approval grammar, the tiers read from the change's diff, and the
## tabs. Every input is an invented plan or `git diff` text written out
## here; no fake or mock is involved.

import std/[json, unittest]
import nim_agents/agent_harbor/[review_record, change_diff, initiatives]

const Plan = """
#+TITLE: Orbit Simulator Milestones

* Document
  :PROPERTIES:
  :current_milestone: ORB-M2
  :END:

* Milestones

** ORB-M1: Step counter
   :PROPERTIES:
   :status: completed
   :END:

*** Spec Changes
    - spec: specs/Propagator.md
      sections: Stepping; ORB-AREQ9
      summary: The propagator counts its steps and reports them.
      commits: 1a2b3c4 5d6e7f8
      approval: approved 2026-11-04 by operator (feedback fb-81c2)
    - spec: specs/Telemetry.md
      summary: Telemetry carries the step count.
      commits: 9a8b7c6
      approval: approved 2026-11-05 by operator (relayed by orbit-manager)
    - spec: specs/Glossary.md
      summary: Fixes a typo.
      commits: 0f0f0f0
      approval: "editorial"
    - spec: specs/Units.md
      summary: Distances are metres throughout.
      commits: 1111111
      approval: pending

*** Verification
    - test_name: just test step-counter
      file: tests/test_step.nim
      description: Steps are counted once per tick.
      status: passing 2026-11-04 (review) at 1a2b3c4
      vacuity_guard: asserts a non-zero count
      negative_control: a zero-length run counts nothing
      falsifying_mutation: counting twice per tick fails it
    - test_name: 'telemetry: carries the count'
      file: tests/test_telemetry.nim
      description: The count reaches the telemetry frame.
      status: failed; frame lost at high rates
    - test_name: just test units
      description: Metres throughout.
      status: pending
    - test_name: just test glossary
      description: Links resolve.
      status: done

*** Implementation Details
    The step counter lives in the propagator state:
    - =State.steps= is incremented in =step=.
    - Telemetry reads it once per frame.

    No new module was needed.

*** Key Source Files
    - =src/orbit/propagator.nim= — the stepping loop and its counter.
    - src/orbit/telemetry.nim - the frame encoder.
    - =src/orbit/measures.nim= :: unit constants.

*** Deliverables
    - [X] The counter.
    - [ ] The telemetry field.

** ORB-M2: Malformed and legacy records
   :PROPERTIES:
   :status: in_progress
   :END:

*** Spec Changes
    - spec: specs/Missing-Commits.md
      summary: No commits named.
      approval: approved 2026-11-04 by operator (feedback fb-1)
    - spec: specs/Duplicate.md
      summary: First summary.
      summary: Second summary.
      commits: 2222222
      approval: approved 2026-11-04 by operator (feedback fb-2)
    - spec: specs/Unknown-Field.md
      summary: Has a field the record does not define.
      commits: 3333333
      reviewer: someone
      approval: approved 2026-11-04 by operator (feedback fb-3)
    - spec: specs/Bad-Date.md
      summary: A date that names no day.
      commits: 4444444
      approval: approved 2026-02-30 by operator (feedback fb-4)
    - =specs/Legacy.md= — Approved by the operator in chat; the old free-text form.
    - spec: specs/Nested.md
      summary: Its approval is only in a nested list and a block.
      commits: 5555555
      - approval: approved 2026-11-04 by operator (feedback fb-5)
      #+begin_example
      approval: approved 2026-11-04 by operator (feedback fb-6)
      #+end_example
    - spec: specs/Blank-Summary.md
      summary:
      commits: 8888888
      approval: approved 2026-11-04 by operator (feedback fb-8)
    - spec: specs/Split.md
      Summary: Its fields are spread over paragraphs, around a nested list.

      commits: 9999999
      - a nested note: not a field
        approval: pending
      Approval: approved 2026-11-06 by operator (relayed by orbit-manager)

*** Spec Changes (follow-up)
    - spec: specs/Follow-Up.md
      summary: A heading with a suffix is still a Spec Changes subsection.
      commits: 6666666
      approval: pending

**** Spec Changes
     - spec: specs/Too-Deep.md
       summary: Not a direct subsection.
       commits: 7777777
       approval: approved 2026-11-04 by operator (feedback fb-7)

** ORB-M3: Nothing recorded yet
   :PROPERTIES:
   :status: planned
   :END:

*** Verification
    - test_name: just test later
      description: Pending work.
      status: pending
"""

# A change to a spec file holding requirements, two governance files, a file
# that only looks like governance, and a non-spec file with a requirement-like
# heading.
const SpecDiff = """
diff --git a/specs/Propagator.md b/specs/Propagator.md
index 1111111..2222222 100644
--- a/specs/Propagator.md
+++ b/specs/Propagator.md
@@ -10,6 +10,9 @@
 ### ORB-AREQ3 Steps are counted

-The propagator counts its steps.
+The propagator counts every step, including rejected ones.

+### ORB-AREQ7 Steps are reported
+
+Telemetry reports the step count.
-### ORB-AREQ2 The old rule
-
-Removed.
@@ -40,3 +40,3 @@ ### ORB-AREQ5 Bounded steps
 Steps are bounded.
-At most 10 per tick.
+At most 12 per tick.
 ## Notes
@@ -60,3 +60,3 @@
-### ORB-AREQ4 Old title
+### ORB-AREQ4 New title
 ## Background
-An unrelated paragraph.
+A changed unrelated paragraph.
diff --git a/AGENTS.md b/AGENTS.md
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -1 +1 @@
-Old rule.
+New rule.
diff --git a/.ah/manager/behaviour.md b/.ah/manager/behaviour.md
new file mode 100644
--- /dev/null
+++ b/.ah/manager/behaviour.md
@@ -0,0 +1 @@
+Be brief.
diff --git a/docs/AGENTS-guide.md b/docs/AGENTS-guide.md
--- a/docs/AGENTS-guide.md
+++ b/docs/AGENTS-guide.md
@@ -1 +1 @@
-a
+b
diff --git a/src/README.md b/src/README.md
--- a/src/README.md
+++ b/src/README.md
@@ -1 +1,2 @@
 x
+### ORB-AREQ8 Not a spec
"""

proc states(changes: openArray[SpecChange]): seq[ApprovalState] =
  for c in changes: result.add c.approval.state

proc specs(changes: openArray[SpecChange]): seq[string] =
  for c in changes: result.add c.spec

suite "the approval grammar":
  test "the four forms":
    check parseApproval("pending").state == apPending
    check parseApproval("editorial").state == apEditorial
    let byFeedback = parseApproval("approved 2026-11-04 by operator (feedback fb-81c2)")
    check byFeedback.state == apApproved
    check (byFeedback.date, byFeedback.who, byFeedback.feedbackId, byFeedback.relay) ==
      ("2026-11-04", "operator", "fb-81c2", "")
    let relayed = parseApproval("approved 2026-11-04 by operator (relayed by fm-mgr)")
    check relayed.state == apApproved
    check (relayed.who, relayed.relay) == ("operator", "fm-mgr")
    # Who and the relay may carry parentheses of their own, as Agent
    # Harbor's own gate reads them.
    check parseApproval("approved 2026-11-04 by Ada (lead) (feedback fb-9)").who == "Ada (lead)"
    let nestedRelay = parseApproval("approved 2026-11-04 by operator (relayed by Morgan (manager))")
    check nestedRelay.state == apApproved
    check (nestedRelay.who, nestedRelay.relay) == ("operator", "Morgan (manager)")
    check parseApproval("approved 2026-11-04 by A Human (feedback fb-81c2)").who == "A Human"
    check parseApproval("'approved 2026-11-04 by operator (relayed by fm-mgr)'").relay == "fm-mgr"
    check parseApproval("'pending'").state == apPending

  test "the malformed dates the record's rule names, and others":
    for value in ["approved +2026-11-04 by operator (feedback fb-1)",
                  "approved 20261-11-04 by operator (feedback fb-1)",
                  "approved 2026-02-30 by operator (feedback fb-1)",
                  "approved 2026-02-29 by operator (feedback fb-1)",
                  "approved 1900-02-29 by operator (feedback fb-1)",
                  "approved 2026-13-01 by operator (feedback fb-1)",
                  "approved 2026-11-00 by operator (feedback fb-1)",
                  "approved 2026-11-4 by operator (feedback fb-1)",
                  "approved 2026/11/04 by operator (feedback fb-1)",
                  "approved -2026-11-04 by operator (feedback fb-1)",
                  "approved 2025-02-29 by operator (feedback fb-1)",
                  "approved 2026-11-31 by operator (feedback fb-1)",
                  "approved 2026-1-04 by operator (feedback fb-1)",
                  "approved \xEF\xBC\x92\xEF\xBC\x90\xEF\xBC\x92\xEF\xBC\x96-11-04 by operator (feedback fb-1)",
                  "approved  2026-11-04 by operator (feedback fb-1)"]:
      checkpoint value
      check parseApproval(value).state == apMalformed
      check not parseApproval(value).isApproved
    # Real days, leap days included.
    check isCalendarDate("2028-02-29")
    check isCalendarDate("2000-02-29")
    check isCalendarDate("2026-12-31")
    check not isCalendarDate("2026-04-31")

  test "who, the feedback id and the relay are never empty; nothing else is a form":
    for value in ["approved 2026-11-04 by  (feedback fb-1)",
                  "approved 2026-11-04 by operator (feedback )",
                  "approved 2026-11-04 by operator (relayed by )",
                  "approved 2026-11-04 by operator",
                  "approved 2026-11-04 operator (feedback fb-1)",
                  "approved 2026-11-04 by operator (feedback fb-1) later",
                  "approved", "Approved 2026-11-04 by operator (feedback fb-1)",
                  "APPROVED 2026-11-04 by operator (feedback fb-1)",
                  "=editorial=", "[editorial]", "\"'editorial'\"", "'editorial\"",
                  "unknown", "pending review", "staged", "yes", ""]:
      checkpoint value
      check parseApproval(value).state == apMalformed

  test "one matched pair of outer quotes is stripped, and only that":
    check parseApproval("\"pending\"").state == apPending
    check parseApproval("'approved 2026-11-04 by operator (feedback fb-1)'").isApproved
    check parseApproval("\"pending'").state == apMalformed
    check parseApproval("\"\"pending\"\"").state == apMalformed
    check stripOuterQuotes("'can't'") == "can't"

  test "the words a card shows":
    check parseApproval("approved 2026-11-04 by operator (feedback fb-1)").approvalText ==
      "approved 2026-11-04 by operator (feedback fb-1)"
    check parseApproval("approved 2026-11-04 by operator (relayed by m)").approvalText ==
      "approved 2026-11-04 by operator (relayed by m)"
    check parseApproval("2026").approvalText == "malformed: approval"
    check SpecApproval(state: apUnstructured).approvalText == "approval not recorded"

suite "reading a plan's review record":
  let record = parseReviewRecord("milestones/Orbit.milestones.org", Plan)

  test "its milestones, by the same heading rule as the progress counts":
    check record.title == "Orbit Simulator Milestones"
    var ids: seq[string]
    for m in record.milestones: ids.add m.id
    check ids == @["ORB-M1", "ORB-M2", "ORB-M3"]
    check record.milestones[0].status == "completed"
    check record.milestones[1].status == "in_progress"
    check parseMilestoneHeading("** ORB-M1: Step counter") == (true, "ORB-M1", "Step counter")
    check parseMilestoneFile("p", Plan).milestones.len == record.milestones.len

  test "structured entries in every approval state":
    let m1 = record.milestones[0]
    check m1.specChanges.specs == @["specs/Propagator.md", "specs/Telemetry.md",
                                    "specs/Glossary.md", "specs/Units.md"]
    check m1.specChanges.states == @[apApproved, apApproved, apEditorial, apPending]
    let first = m1.specChanges[0]
    check first.sections == @["Stepping", "ORB-AREQ9"]
    check first.commits == @["1a2b3c4", "5d6e7f8"]
    check first.summary == "The propagator counts its steps and reports them."
    check first.approval.feedbackId == "fb-81c2"
    check first.problems.len == 0
    check first.milestoneId == "ORB-M1"
    check m1.specChanges[1].approval.relay == "orbit-manager"

  test "a missing, blank or duplicate field, or a bad approval, is malformed":
    let m2 = record.milestones[1]
    check m2.specChanges.specs[0 .. 3] == @["specs/Missing-Commits.md", "specs/Duplicate.md",
                                            "specs/Unknown-Field.md", "specs/Bad-Date.md"]
    check m2.specChanges[0].approval.state == apMalformed
    check m2.specChanges[0].approval.reason == "missing commits"
    check m2.specChanges[1].problems == @["duplicate summary"]
    check m2.specChanges[1].summary == "First summary."
    check m2.specChanges[3].problems == @["approval"]
    check m2.specChanges[3].approval.approvalText == "malformed: approval"
    let blank = m2.specChanges[6]
    check blank.spec == "specs/Blank-Summary.md"
    check blank.problems == @["missing summary"]
    check blank.approval.approvalText == "malformed: missing summary"
    for i in [0, 1, 3, 6]:
      check not m2.specChanges[i].approval.isApproved

  test "a field the record does not define is ignored, as the gate ignores it":
    # The record's rule refuses unknown approvals, not unknown fields.
    let unknown = record.milestones[1].specChanges[2]
    check unknown.problems.len == 0
    check unknown.approval.isApproved
    check unknown.approval.feedbackId == "fb-3"

  test "a record's fields across its paragraphs; keys in any case":
    let split = record.milestones[1].specChanges[7]
    check split.spec == "specs/Split.md"
    check split.summary == "Its fields are spread over paragraphs, around a nested list."
    check split.commits == @["9999999"]
    check split.problems.len == 0
    # The nested item's `approval: pending` is not the record's; the
    # paragraph after the nested list is.
    check split.approval.state == apApproved
    check split.approval.relay == "orbit-manager"

  test "an unstructured entry keeps its text and is never approved":
    let legacy = record.milestones[1].specChanges[4]
    check legacy.approval.state == apUnstructured
    check not legacy.approval.isApproved
    check legacy.spec == "specs/Legacy.md"
    check legacy.summary == "Approved by the operator in chat; the old free-text form."
    check legacy.approval.approvalText == "approval not recorded"

  test "a nested list or block never grants an approval":
    let nested = record.milestones[1].specChanges[5]
    check nested.spec == "specs/Nested.md"
    check nested.approval.state == apMalformed
    check nested.problems == @["missing approval"]

  test "a heading with a suffix is read; a deeper heading is not":
    let m2 = record.milestones[1]
    check m2.specChanges.len == 9
    check m2.specChanges[8].spec == "specs/Follow-Up.md"
    check m2.specChanges[8].approval.state == apPending
    check "specs/Too-Deep.md" notin m2.specChanges.specs

  test "verification entries by their leading token, with the annotation kept":
    let v = record.milestones[0].verifications
    check v.len == 4
    check v[0].status == vsPassing
    check v[0].annotation == "2026-11-04 (review) at 1a2b3c4"
    check v[0].vacuityGuard == "asserts a non-zero count"
    check v[0].negativeControl == "a zero-length run counts nothing"
    check v[0].falsifyingMutation == "counting twice per tick fails it"
    check v[1].testName == "telemetry: carries the count"
    check v[1].status == vsFailing
    check v[1].annotation == "frame lost at high rates"
    check v[2].status == vsPending
    check v[3].status == vsPassing
    check verificationStatusOf("flaky sometimes").status == vsUnknown
    # The server's progress counter, ported in `initiatives`, counts an
    # annotated status as none of the three; the Tests tab reads it by its
    # token. Both rules are kept, each where it belongs.
    let counts = parseMilestoneFile("p", Plan).milestones[0].verifications
    check (counts.passing, counts.failing, counts.pending) == (0, 0, 1)

  test "implementation details as written, key source files, deliverables":
    let m1 = record.milestones[0]
    check m1.implementationDetails ==
      "The step counter lives in the propagator state:\n" &
      "- =State.steps= is incremented in =step=.\n" &
      "- Telemetry reads it once per frame.\n\nNo new module was needed."
    check m1.keySourceFiles == @[
      KeySourceFile(path: "src/orbit/propagator.nim", purpose: "the stepping loop and its counter."),
      KeySourceFile(path: "src/orbit/telemetry.nim", purpose: "the frame encoder."),
      KeySourceFile(path: "src/orbit/measures.nim", purpose: "unit constants.")]
    check m1.deliverables == @[Deliverable(text: "The counter.", done: true),
                               Deliverable(text: "The telemetry field.")]
    check record.milestones[2].implementationDetails == ""

  test "a plan with no milestones, and an empty one":
    check parseReviewRecord("p", "").milestones.len == 0
    check parseReviewRecord("p", "* Milestones\n** Notes: none\n").milestones.len == 0

suite "tiers 1 and 2, from the diff":
  let diff = parseUnifiedDiff(SpecDiff)
  let cards = extractTierCards(diff)

  test "one tier-1 card per requirement the diff adds, changes or removes":
    var tier1: seq[(string, RequirementChange)]
    for c in cards:
      if c.tier == stRequirement: tier1.add (c.requirement, c.change)
    check tier1 == @[("ORB-AREQ3", rcModified), ("ORB-AREQ7", rcAdded),
                     ("ORB-AREQ2", rcRemoved), ("ORB-AREQ5", rcModified),
                     ("ORB-AREQ4", rcModified)]
    check cards[1].heading == "ORB-AREQ7 Steps are reported"
    check cards[0].path == "specs/Propagator.md"
    check cards[0].hunks.len == 1
    check cards[3].hunks[0].section == "### ORB-AREQ5 Bounded steps"

  test "an entry's sections never make a tier-1 card; the diff decides":
    # The record's first entry names ORB-AREQ9 in its sections; the diff
    # does not touch it, so it stays a tier-3 card only.
    let record = parseReviewRecord("p", Plan)
    check "ORB-AREQ9" in record.milestones[0].specChanges[0].sections
    for c in cards:
      check c.requirement != "ORB-AREQ9"
    # The tab's cards: the entry stays a tier-3 card, and no tier-1 card
    # names the requirement only its sections mention.
    let tab = specCards(record.milestones[0 .. 0], diff)
    var tiers: seq[(SpecTier, string)]
    for c in tab:
      tiers.add (c.tier, if c.tier == stSpec: c.entry.spec
                         elif c.tier == stRequirement: c.fromDiff.requirement
                         else: c.fromDiff.path)
    check tiers == @[(stRequirement, "ORB-AREQ3"), (stRequirement, "ORB-AREQ7"),
                     (stRequirement, "ORB-AREQ2"), (stRequirement, "ORB-AREQ5"),
                     (stRequirement, "ORB-AREQ4"), (stGovernance, "AGENTS.md"),
                     (stGovernance, ".ah/manager/behaviour.md"),
                     (stSpec, "specs/Propagator.md"), (stSpec, "specs/Telemetry.md"),
                     (stSpec, "specs/Glossary.md"), (stSpec, "specs/Units.md")]
    # With no plan, tier 3 is the diff's changed spec files.
    let noPlan = specCards([], diff, hasPlan = false)
    check noPlan.len == cards.len + 1
    check noPlan[^1].entry.spec == "specs/Propagator.md"

  test "a requirement heading outside the spec roots, or text under another heading":
    for c in cards:
      check c.requirement != "ORB-AREQ8"
    check isSpecFile("specs/x.md")
    check isSpecFile("docs/Authoritative-Requirements.md")
    check not isSpecFile("src/README.md")
    check isSpecFile("design/x.md", ["design/"])
    check requirementHeading("### ACME-AREQ12: Title").id == "ACME-AREQ12"
    check requirementHeading("### A1-AREQ3").ok
    check not requirementHeading("#### ACME-AREQ1 Deeper").ok
    check not requirementHeading("### acme-AREQ1 lower").ok
    check not requirementHeading("### ACME-AREQ Title").ok
    check not requirementHeading("### ACME-AREQ1x Title").ok

  test "one tier-2 card per changed governance file":
    var tier2: seq[(string, RequirementChange)]
    for c in cards:
      if c.tier == stGovernance: tier2.add (c.path, c.change)
    check tier2 == @[("AGENTS.md", rcModified), (".ah/manager/behaviour.md", rcAdded)]
    check isGovernanceFile("sub/dir/CLAUDE.md")
    check isGovernanceFile(".ah/autonomy.md")
    check isGovernanceFile("pkg/.ah/manager/role.md")
    check not isGovernanceFile("docs/AGENTS-guide.md")
    check not isGovernanceFile(".ah/autonomy-notes.md")

  test "a task with no plan: one tier-3 card per changed spec file":
    let fromDiff = specChangesFromDiff(diff)
    check fromDiff.specs == @["specs/Propagator.md"]
    check fromDiff[0].summary == ""
    check fromDiff[0].approval.state == apUnstructured
    check specChangesFromDiff(diff, ["docs/"]).specs == @["docs/AGENTS-guide.md"]

suite "tabs, scope and tests":
  let record = parseReviewRecord("p", Plan)

  test "the four tabs in the reviewer's order; two for a task with no plan":
    check tabsOf(hasPlan = true) == @[rtSpecChanges, rtTests, rtImplementation, rtCode]
    check tabsOf(hasPlan = false) == @[rtSpecChanges, rtCode]
    check $rtImplementation == "Implementation Details"
    check tabLabel(rtSpecChanges, compact = true) == "Specs"
    check tabLabel(rtImplementation, compact = true) == "Details"
    check tabLabel(rtImplementation) == "Implementation Details"

  test "counts, and the tab a panel opens on":
    let diff = parseUnifiedDiff(SpecDiff)
    let cards = extractTierCards(diff)
    let all = record.scopeOf()
    let tabs = tabsOf(true)
    var counts: seq[int]
    for t in tabs: counts.add tabCount(t, all, cards, diff)
    check counts == @[7 + 13, 5, 4, 5]
    check firstTabWithContent(tabs, counts) == rtSpecChanges
    # With no spec change in scope, the panel opens on Tests.
    let m3 = record.scopeOf("ORB-M3")
    counts.setLen 0
    for t in tabs: counts.add tabCount(t, m3, [], ChangeDiff())
    check counts == @[0, 1, 0, 0]
    check firstTabWithContent(tabs, counts) == rtTests
    # Nothing anywhere: the first tab.
    check firstTabWithContent(tabs, [0, 0, 0, 0]) == rtSpecChanges
    check firstTabWithContent(tabsOf(false), [0, 3]) == rtCode

  test "scope: all milestones, one, or a task's":
    check record.scopeOf().len == 3
    check record.scopeOf("ORB-M2")[0].id == "ORB-M2"
    check record.scopeOf("ORB-M9").len == 0
    check record.restrictTo(["ORB-M3", "ORB-M1"]).milestones.len == 2
    check record.restrictTo(["ORB-M3", "ORB-M1"]).milestones[0].id == "ORB-M1"
    check keySourcePaths(record.milestones).len == 3

  test "tests grouped by milestone, failing first":
    let groups = testGroups(record.milestones)
    check groups.len == 2
    check groups[0].milestoneId == "ORB-M1"
    check groups[0].entries[0].status == vsFailing
    check groups[0].entries[0].testName == "telemetry: carries the count"
    check groups[0].entries[1].testName == "just test step-counter"
    check groups[1].milestoneId == "ORB-M3"
    # A group with a failing entry goes before one without, whatever the plan order.
    let reversed = testGroups([record.milestones[2], record.milestones[0]])
    check reversed[0].milestoneId == "ORB-M1"

suite "the proposed served record":
  test "read leniently; an approval is parsed from its text":
    let node = parseJson("""{"path": "p", "title": "T", "milestones": [
      {"id": "ORB-M1", "title": "Step counter", "status": "completed",
       "implementationDetails": "Notes.",
       "specChanges": [
         {"spec": "specs/A.md", "summary": "s", "commits": ["abc"],
          "approval": "approved 2026-11-04 by operator (feedback fb-1)"},
         {"spec": "specs/B.md", "summary": "s", "commits": ["abc"],
          "approval": "approved 2026-02-30 by operator (feedback fb-1)"},
         {"spec": "specs/C.md", "summary": "s", "commits": ["abc"], "approval": "staged"},
         {"spec": "specs/D.md", "commits": ["abc"], "approval": "pending"},
         {"spec": "specs/E.md", "raw": "legacy"}],
       "verifications": [{"testName": "t", "status": "passing 2026-11-04"}],
       "keySourceFiles": ["src/a.nim", {"path": "src/b.nim", "purpose": "b"}],
       "unknownField": 1}]}""")
    let r = reviewRecordFromJson(node)
    let m = r.milestones[0]
    # `staged` is no approval: a staged change is a tier-1 or tier-2 card.
    check m.specChanges.states == @[apApproved, apMalformed, apMalformed, apMalformed,
                                    apUnstructured]
    check m.specChanges[3].problems == @["missing summary"]
    check m.verifications[0].status == vsPassing
    check m.keySourceFiles[1] == KeySourceFile(path: "src/b.nim", purpose: "b")
    check m.implementationDetails == "Notes."
    check reviewRecordFromJson(newJNull()).milestones.len == 0

  test "staged cards are served only, and sit in their tier, before the record's entries":
    let r = reviewRecordFromJson(parseJson("""{"milestones": [], "stagedCards": [
      {"tier": "governance", "path": "AGENTS.md", "origin": "operator-distilled"},
      {"tier": "requirements", "path": "specs/Propagator.md", "requirement": "ORB-AREQ11",
       "heading": "ORB-AREQ11 Steps are logged", "change": "added",
       "origin": "operator-distilled"}]}"""))
    check r.stagedCards.len == 2
    for c in r.stagedCards: check c.staged
    check r.stagedCards[0].tier == stGovernance
    check r.stagedCards[1].tier == stRequirement
    check r.stagedCards[1].change == rcAdded
    check r.stagedCards[1].origin == "operator-distilled"
    # Nothing read from a plan or a diff is staged.
    for c in extractTierCards(parseUnifiedDiff(SpecDiff)): check not c.staged
    let plan = parseReviewRecord("p", Plan)
    check plan.stagedCards.len == 0
    let tab = specCards(plan.milestones[0 .. 0], parseUnifiedDiff(SpecDiff),
                        staged = r.stagedCards)
    var shape: seq[(SpecTier, bool, string)]
    for c in tab:
      shape.add (c.tier, c.fromDiff.staged,
                 if c.tier == stSpec: c.entry.spec
                 elif c.tier == stRequirement: c.fromDiff.requirement
                 else: c.fromDiff.path)
    check shape == @[
      (stRequirement, false, "ORB-AREQ3"), (stRequirement, false, "ORB-AREQ7"),
      (stRequirement, false, "ORB-AREQ2"), (stRequirement, false, "ORB-AREQ5"),
      (stRequirement, false, "ORB-AREQ4"), (stRequirement, true, "ORB-AREQ11"),
      (stGovernance, false, "AGENTS.md"), (stGovernance, false, ".ah/manager/behaviour.md"),
      (stGovernance, true, "AGENTS.md"),
      (stSpec, false, "specs/Propagator.md"), (stSpec, false, "specs/Telemetry.md"),
      (stSpec, false, "specs/Glossary.md"), (stSpec, false, "specs/Units.md")]
