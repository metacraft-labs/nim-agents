## nim_agents/workspace.nim
##
## The Agent Workspace sidebar's signal-free rules: which file row is selected
## when the selection or the file list changes, the coverage badge a row
## shows, and when there is a workspace to show at all. Moved from CodeTracer's
## `viewmodels/agent_workspace_vm.nim` (CTF-M1); the viewmodel keeps its
## signals and memos and calls these.

import ./activity_model

proc clampSelectedIndex*(index, fileCount: int): int =
  ## The row a selection lands on: 0 for an empty list, otherwise `index`
  ## held inside the list.
  if fileCount <= 0:
    0
  elif index < 0:
    0
  elif index >= fileCount:
    fileCount - 1
  else:
    index

proc coverageBadgeText*(entry: AgentWorkspaceFileEntry): string =
  ## `covered/total`, or `--` for a file with no lines to cover.
  if entry.totalLines == 0:
    "--"
  else:
    $entry.coveredLines & "/" & $entry.totalLines

proc selectedFileOf*(files: openArray[AgentWorkspaceFileEntry];
                     index: int): AgentWorkspaceFileEntry =
  ## The file the clamped selection is on; an empty entry for no files.
  if files.len == 0:
    AgentWorkspaceFileEntry()
  else:
    files[clampSelectedIndex(index, files.len)]

proc hasWorkspaceOf*(fileCount: int; sessionId: string): bool =
  ## There is a workspace to show once it has files or a session.
  fileCount > 0 or sessionId.len > 0
