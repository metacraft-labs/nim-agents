## The Agent Workspace sidebar's signal-free rules (`nim_agents/workspace`),
## native and JS: which file row is selected when the selection or the file
## list changes, the coverage badge a row shows, and when there is a workspace
## to show at all. Plain values; every expectation is written out by hand. The
## data is invented, as everything in this public repository.

import std/unittest
import nim_agents/activity_model
import nim_agents/workspace

proc file(path: string; covered, total: int): AgentWorkspaceFileEntry =
  AgentWorkspaceFileEntry(path: path, coveredLines: covered, totalLines: total)

suite "agent workspace":
  test "a selection stays inside the file list":
    check clampSelectedIndex(0, 0) == 0
    check clampSelectedIndex(5, 0) == 0
    check clampSelectedIndex(-1, 3) == 0
    check clampSelectedIndex(1, 3) == 1
    check clampSelectedIndex(3, 3) == 2
    check clampSelectedIndex(99, 3) == 2

  test "the coverage badge: covered over total, or -- with no lines":
    check coverageBadgeText(file("src/a.nim", 4, 10)) == "4/10"
    check coverageBadgeText(file("src/b.nim", 0, 7)) == "0/7"
    check coverageBadgeText(file("src/c.nim", 0, 0)) == "--"

  test "the selected file follows the clamped selection":
    let files = @[file("a", 1, 2), file("b", 3, 4)]
    check selectedFileOf(files, 0).path == "a"
    check selectedFileOf(files, 1).path == "b"
    check selectedFileOf(files, 7).path == "b"
    check selectedFileOf(@[], 0).path == ""

  test "there is a workspace once it has files or a session":
    check not hasWorkspaceOf(0, "")
    check hasWorkspaceOf(2, "")
    check hasWorkspaceOf(0, "s-1")
