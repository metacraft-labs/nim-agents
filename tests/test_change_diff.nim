## The change diff of nim-agents: `git diff` text read into files and hunks,
## a committed and an uncommitted diff joined relative to the merge base,
## key source files first, the filters and the summary lines. Every input is
## `git diff` output written out here; no fake or mock is involved.

import std/[strutils, unittest]
import nim_agents/agent_harbor/change_diff

# One invented change: a modified file with two hunks (one of them removing
# a line that itself starts with `--`), an added file, a deleted file, a
# rename with an edit, a pure rename, a binary file and a path git quotes.
const BranchDiff = """
diff --git a/src/orbit/propagator.nim b/src/orbit/propagator.nim
index 1111111..2222222 100644
--- a/src/orbit/propagator.nim
+++ b/src/orbit/propagator.nim
@@ -3,4 +3,5 @@ proc step*(s: var State) =
   let dt = s.dt
-  s.t += dt
+  s.t += dt
+  inc s.steps
   s.x += s.v * dt
-- a removed comment line
@@ -40,2 +41,2 @@
-  echo "old"
+  echo "new"
   discard
diff --git a/src/orbit/telemetry.nim b/src/orbit/telemetry.nim
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/src/orbit/telemetry.nim
@@ -0,0 +1,2 @@
+proc report*() =
+  discard
diff --git a/src/orbit/legacy.nim b/src/orbit/legacy.nim
deleted file mode 100644
index 4444444..0000000
--- a/src/orbit/legacy.nim
+++ /dev/null
@@ -1,1 +0,0 @@
-proc old*() = discard
diff --git a/src/orbit/units.nim b/src/orbit/measures.nim
similarity index 90%
rename from src/orbit/units.nim
rename to src/orbit/measures.nim
index 5555555..6666666 100644
--- a/src/orbit/units.nim
+++ b/src/orbit/measures.nim
@@ -1,2 +1,2 @@
-const Km* = 1000
+const Km* = 1_000
 const M* = 1
diff --git a/docs/old-name.md b/docs/new-name.md
similarity index 100%
rename from docs/old-name.md
rename to docs/new-name.md
diff --git a/assets/orbit.png b/assets/orbit.png
index 7777777..8888888 100644
Binary files a/assets/orbit.png and b/assets/orbit.png differ
diff --git "a/notes/with\ttab.md" "b/notes/with\ttab.md"
index 9999999..aaaaaaa 100644
--- "a/notes/with\ttab.md"
+++ "b/notes/with\ttab.md"
@@ -1 +1 @@
-old
\ No newline at end of file
+new
\ No newline at end of file
"""

const WorkingTreeDiff = """
diff --git a/src/orbit/propagator.nim b/src/orbit/propagator.nim
index 2222222..2222223 100644
--- a/src/orbit/propagator.nim
+++ b/src/orbit/propagator.nim
@@ -10,1 +10,2 @@
 discard
+# uncommitted note
diff --git a/src/orbit/telemetry.nim b/src/orbit/telemetry.nim
deleted file mode 100644
--- a/src/orbit/telemetry.nim
+++ /dev/null
@@ -1,2 +0,0 @@
-proc report*() =
-  discard
diff --git a/src/orbit/measures.nim b/src/orbit/distance.nim
similarity index 95%
rename from src/orbit/measures.nim
rename to src/orbit/distance.nim
diff --git a/src/orbit/scratch.nim b/src/orbit/scratch.nim
new file mode 100644
--- /dev/null
+++ b/src/orbit/scratch.nim
@@ -0,0 +1 @@
+echo 1
"""

proc paths(files: openArray[ChangedFile]): seq[string] =
  for f in files: result.add f.path

suite "reading git diff":
  let diff = parseUnifiedDiff(BranchDiff)

  test "every file in the diff's order, each with its status":
    check diff.files.paths == @["src/orbit/propagator.nim", "src/orbit/telemetry.nim",
                                "src/orbit/legacy.nim", "src/orbit/measures.nim",
                                "docs/new-name.md", "assets/orbit.png",
                                "notes/with\ttab.md"]
    check diff.files[0].status == csModified
    check diff.files[1].status == csAdded
    check diff.files[2].status == csDeleted
    check diff.files[5].status == csModified
    check diff.files[5].binary
    check not diff.files[0].binary

  test "a rename is one file with its old path, never a delete and an add":
    let renamed = diff.files[3]
    check renamed.status == csRenamed
    check renamed.oldPath == "src/orbit/units.nim"
    check renamed.path == "src/orbit/measures.nim"
    check renamed.similarity == 90
    check (renamed.added, renamed.removed) == (1, 1)
    # A pure rename has no hunks and no counts.
    check diff.files[4].status == csRenamed
    check diff.files[4].oldPath == "docs/old-name.md"
    check diff.files[4].hunks.len == 0
    # Nothing else in the diff names either side of a rename.
    var deletedOrAdded: seq[string]
    for f in diff.files:
      if f.status in {csAdded, csDeleted}: deletedOrAdded.add f.path
    check deletedOrAdded == @["src/orbit/telemetry.nim", "src/orbit/legacy.nim"]
    check diff.fileIndex("src/orbit/units.nim") == 3

  test "a hunk is read by its counts, so a removed `--` line is not a header":
    let f = diff.files[0]
    check f.hunks.len == 2
    check (f.added, f.removed) == (3, 3)
    let h = f.hunks[0]
    check (h.oldStart, h.oldCount, h.newStart, h.newCount) == (3, 4, 3, 5)
    check h.section == "proc step*(s: var State) ="
    check h.lines.len == 6
    check h.lines[^1].kind == dlRemoved
    check h.lines[^1].text == "- a removed comment line"
    check h.lines[^1].oldLine == 6
    # Line numbers on both sides.
    check (h.lines[0].oldLine, h.lines[0].newLine) == (3, 3)
    check h.lines[2].kind == dlAdded
    check (h.lines[2].oldLine, h.lines[2].newLine) == (0, 4)
    check (h.lines[4].oldLine, h.lines[4].newLine) == (5, 6)
    check f.hunks[1].lines.len == 3

  test "a quoted path, and the end-of-file marker":
    let f = diff.files[6]
    check f.path == "notes/with\ttab.md"
    check f.hunks[0].lines.len == 4
    check f.hunks[0].lines[1].kind == dlNoNewline
    check (f.added, f.removed) == (1, 1)

  test "an empty diff has no files":
    check parseUnifiedDiff("").files.len == 0
    check parseUnifiedDiff("not a diff\n").files.len == 0

suite "the summary line and the roll-up":
  test "files, added and removed, with the minus sign":
    let diff = parseUnifiedDiff(BranchDiff)
    check diff.totals == DiffTotals(files: 7, added: 7, removed: 6)
    check diff.summaryText == "7 files changed +7 \xE2\x88\x926"
    check parseUnifiedDiff(WorkingTreeDiff.split("diff --git a/src/orbit/scratch")[0]
      ).files.len == 3
    let one = parseUnifiedDiff(WorkingTreeDiff).files[3 .. 3]
    check ChangeDiff(files: one).summaryText == "1 file changed +1 \xE2\x88\x920"

  test "no changes, and no data":
    check ChangeDiff().summaryText == NoChangesText
    check ChangeDiff().summaryText(hasData = false) == NoDiffDataText
    check NoChangesText == "No changes"
    check NoDiffDataText == "No diff data"

  test "the roll-up shows only an ended session's changes":
    let diff = parseUnifiedDiff(BranchDiff)
    check diff.rollUpText(ended = true, readOk = true) == "7 files +7 \xE2\x88\x926"
    check diff.rollUpText(ended = false, readOk = true) == ""
    check diff.rollUpText(ended = true, readOk = false) == ""
    check ChangeDiff().rollUpText(ended = true, readOk = true) == ""

suite "committed and uncommitted together":
  let merged = mergeBaseRelative(parseUnifiedDiff(BranchDiff),
                                 parseUnifiedDiff(WorkingTreeDiff, coUncommitted))

  test "each file once, marked with where its change is":
    # `telemetry.nim`, added by the branch and deleted in the working tree,
    # is in neither the base nor the end state: it is not listed.
    check merged.files.paths == @["src/orbit/propagator.nim",
                                  "src/orbit/legacy.nim", "src/orbit/distance.nim",
                                  "docs/new-name.md", "assets/orbit.png",
                                  "notes/with\ttab.md", "src/orbit/scratch.nim"]
    var origins: seq[ChangeOrigin]
    for f in merged.files: origins.add f.origin
    check origins == @[coBoth, coCommitted, coBoth, coCommitted, coCommitted,
                       coCommitted, coUncommitted]

  test "a file in both keeps both diffs' hunks, each with its origin":
    let f = merged.files[0]
    check f.status == csModified
    check f.hunks.len == 3
    check f.hunks[0].origin == coCommitted
    check f.hunks[2].origin == coUncommitted
    check (f.added, f.removed) == (4, 3)

  test "the status relative to the base":
    # A committed rename renamed again: the end path, from the base path.
    let moved = merged.files[2]
    check moved.status == csRenamed
    check moved.oldPath == "src/orbit/units.nim"
    check moved.path == "src/orbit/distance.nim"
    # A committed modification, a committed rename and a committed delete,
    # then the working tree deletes the first two and adds the third back.
    let committed = parseUnifiedDiff("""
diff --git a/a.nim b/a.nim
--- a/a.nim
+++ b/a.nim
@@ -1 +1 @@
-x
+y
diff --git a/old.nim b/new.nim
similarity index 100%
rename from old.nim
rename to new.nim
diff --git a/gone.nim b/gone.nim
deleted file mode 100644
--- a/gone.nim
+++ /dev/null
@@ -1 +0,0 @@
-z
""")
    let working = parseUnifiedDiff("""
diff --git a/a.nim b/a.nim
deleted file mode 100644
--- a/a.nim
+++ /dev/null
@@ -1 +0,0 @@
-y
diff --git a/new.nim b/new.nim
deleted file mode 100644
--- a/new.nim
+++ /dev/null
@@ -1 +0,0 @@
-w
diff --git a/gone.nim b/gone.nim
new file mode 100644
--- /dev/null
+++ b/gone.nim
@@ -0,0 +1 @@
+z2
""", coUncommitted)
    let joined = mergeBaseRelative(committed, working)
    var shape: seq[(string, string, ChangeStatus, ChangeOrigin)]
    for f in joined.files: shape.add (f.path, f.oldPath, f.status, f.origin)
    check shape == @[("a.nim", "", csDeleted, coBoth),
                     ("old.nim", "", csDeleted, coBoth),
                     ("gone.nim", "", csModified, coBoth)]

  test "only one side":
    check mergeBaseRelative(ChangeDiff(), ChangeDiff()).files.len == 0
    let onlyWorking = mergeBaseRelative(ChangeDiff(), parseUnifiedDiff(WorkingTreeDiff))
    check onlyWorking.files.len == 4
    for f in onlyWorking.files: check f.origin == coUncommitted

suite "key source files, filters, one file":
  let diff = parseUnifiedDiff(BranchDiff)

  test "a plan's key source files come first, matched from where the plan lives":
    let ordered = orderKeyFilesFirst(diff.files,
      ["../orbit-repo/src/orbit/measures.nim", "=assets/orbit.png=", "src/elsewhere.nim"])
    check ordered.paths[0 .. 1] == @["src/orbit/measures.nim", "assets/orbit.png"]
    check ordered.paths[2 .. ^1] == @["src/orbit/propagator.nim", "src/orbit/telemetry.nim",
                                      "src/orbit/legacy.nim", "docs/new-name.md",
                                      "notes/with\ttab.md"]
    # A rename's old path names it too; a different file with the same name does not.
    check diff.files[3].isKeyFile(["src/orbit/units.nim"])
    check not diff.files[0].isKeyFile(["other/propagator.nim"])
    check orderKeyFilesFirst(diff.files, []).paths == diff.files.paths

  test "the status filter and the search box":
    check filterFiles(diff.files, sfAdded).paths == @["src/orbit/telemetry.nim"]
    check filterFiles(diff.files, sfRenamed).paths == @["src/orbit/measures.nim",
                                                        "docs/new-name.md"]
    check filterFiles(diff.files, sfAll, "ORBIT/LEG").paths == @["src/orbit/legacy.nim"]
    check filterFiles(diff.files, sfAll, "units").paths == @["src/orbit/measures.nim"]
    check filterFiles(diff.files, sfDeleted, "telemetry").len == 0
    check filterFiles(diff.files).len == diff.files.len
    check NoMatchingFilesText == "No files match the current filters"

  test "a spec's part of the change, and a file's place":
    check diff.specDiff("src/orbit/telemetry.nim").found
    check diff.specDiff("src/orbit/telemetry.nim").file.hunks.len == 1
    check not diff.specDiff("specs/absent.md").found
    check positionText(2, 22) == "3 of 22"
    check positionText(-1, 22) == ""
