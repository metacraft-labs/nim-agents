## One walk over a unified diff's raw lines (`nim_agents/diff_walk`), native
## and JS: each line's kind and the old and new line numbers CodeTracer's VCS
## panel and DeepReview panel show today. The numbering is pinned exactly as
## CodeTracer counts it (CTF-M1 slice 8 moves code without changing what it
## shows): both counters start at 0, a hunk header advances neither and does
## not read its `@@ -a,b +c,d @@` starts, an added line advances the new count,
## a removed line the old one, and every other line -- the `---` / `+++` file
## headers, `\ No newline` and the empty string after a trailing newline
## included -- advances both. Every expectation is written out by hand.

import std/unittest
import nim_agents/diff_walk

const Sample = "--- a/x.nim\n+++ b/x.nim\n@@ -10,3 +10,4 @@ proc f\n keep\n-old\n+new\n+more\n tail\n"

proc row(k: WalkedLineKind; c: string; o, n: int): WalkedLine =
  WalkedLine(kind: k, content: c, oldLine: o, newLine: n)

suite "diff walk":
  test "every raw line, with CodeTracer's numbering":
    check walkDiffLines(Sample) == @[
      row(wlContext, "--- a/x.nim", 1, 1),
      row(wlContext, "+++ b/x.nim", 2, 2),
      row(wlHunk, "@@ -10,3 +10,4 @@ proc f", 2, 2),
      row(wlContext, " keep", 3, 3),
      row(wlRemoved, "-old", 4, 0),
      row(wlAdded, "+new", 0, 4),
      row(wlAdded, "+more", 0, 5),
      row(wlContext, " tail", 5, 6),
      row(wlContext, "", 6, 7)]

  test "two hunks keep counting from the first; a hunk reads its position, not its header":
    let d = "@@ -1 +1 @@\n-a\n+b\n@@ -40 +40 @@\n c\n"
    check walkDiffLines(d) == @[
      row(wlHunk, "@@ -1 +1 @@", 0, 0),
      row(wlRemoved, "-a", 1, 0),
      row(wlAdded, "+b", 0, 1),
      row(wlHunk, "@@ -40 +40 @@", 1, 1),
      row(wlContext, " c", 2, 2),
      row(wlContext, "", 3, 3)]

  test "the empty diff is one empty context line":
    check walkDiffLines("") == @[row(wlContext, "", 1, 1)]

  test "a line that is only a sign is a change":
    check walkDiffLines("+\n-") == @[row(wlAdded, "+", 0, 1),
                                      row(wlRemoved, "-", 1, 0)]
