## nim_agents/activity_model.nim
##
## The data an agent activity panel renders, with no UI and no signals:
## messages, their ordered segments, tool calls, diffs and terminals, and the
## Agent Workspace sidebar's rows and counters. Moved from CodeTracer's
## `viewmodel/store/types.nim` (CTF-M1) so every front-end and every
## viewmodel library reads one definition; `store/types` re-exports it.
##
## The comments below are the ones the types carried in CodeTracer.

type
  AgentActivityMessageRole* = enum
    aamrAgent
    aamrUser

  AgentActivityDiffEntry* = object
    id*: int
    path*: string
    original*: string
    modified*: string

  AgentActivityToolCallEntry* = object
    toolCallId*: string
    name*: string
    status*: string  # "in_progress", "completed", "failed"

  AgentActivitySegment* = object
    ## VM mirror of AgentSegment: one ordered unit (text block or tool call).
    isToolCall*: bool
    content*: string
    toolCallId*: string
    toolName*: string
    toolStatus*: string

  AgentActivityMessageEntry* = object
    id*: string
    content*: string
    role*: AgentActivityMessageRole
    canceled*: bool
    isLoading*: bool
    images*: seq[string]
      ## Base64 data URLs of images the user attached to this message.
    diffs*: seq[AgentActivityDiffEntry]
    toolCalls*: seq[AgentActivityToolCallEntry]
    segments*: seq[AgentActivitySegment]
    thinkingEndedAt*: float
    toolName*: string
    createdAt*: float
    failed*: bool
      ## #862: the agent refused or aborted this turn — its `session/prompt`
      ## was answered with an error rather than a stop reason.  This is
      ## `AgentFailed` ("Task failed with error") in
      ## `DeepReview/Agentic-Coding-Integration.md` §3.2, painted with §3.3's
      ## red X.  Only ever set on an agent message.
    errorMessage*: string
      ## The agent's reason when `failed`, shown verbatim.  May be empty when
      ## the agent gave none; the view then says so rather than showing
      ## nothing.
    duration*: float
      ## Seconds the agent spent generating this response. Set when stopReason
      ## arrives; 0.0 while streaming or for user messages.
      ## AA-3 — the tool this row *is*, when it is a tool call rather than
      ## prose.  Empty for everything else, which is what makes it usable as
      ## the "is this a tool call at all" test.
      ##
      ## The agent protocols put the invocation here: ACP's `tool_call`
      ## carries it as `title` (`nim-agents`' `acpUpdateToAgentEvent` maps
      ## `update.title` → `AgentEvent.toolName`), and for a shell tool the
      ## title *is* the command line.  Both projections into this type
      ## previously collapsed it into `content` and dropped the fact that it
      ## came from a tool at all (`review_session.eventContent`,
      ## `agentic_session_vm.eventToActivityMessage`), which left the panel
      ## unable to tell an agent *saying* "ct review collect …" from an agent
      ## *running* it.  AA-3 needs that distinction: recognising an evidence
      ## handoff in prose would invent a review that was never collected.
    toolCallId*: string
      ## AA-3 — the identity that ties a tool call to the update reporting its
      ## outcome.  Empty when the producer has none.
      ##
      ## An outcome arrives as a *separate* row (ACP's `tool_call_update`), so
      ## without this the only way to pair the two is positional adjacency,
      ## which any interleaved row breaks.
    status*: string
      ## AA-3 — the backend's own word for how the call ended
      ## (`"completed"` / `"failed"` / `"in_progress"` / …), never one
      ## invented here.  Empty when the producer reported none, which is a
      ## distinct fact from "it failed" and is rendered as such.

  AgentActivityTerminalEntry* = object
    id*: string
    shellId*: int

  AgentWorkspaceViewKind* = enum
    ## Mirrors the legacy ``WorkspaceViewKind`` without importing the
    ## common/frontend agentic-coding types into the ViewModel store.
    awvkUserWorkspace
    awvkAgentWorkspace

  AgentWorkspaceFileEntry* = object
    ## One file row in the Agent Workspace sidebar.
    path*: string
    coveredLines*: int
    totalLines*: int
    hasFlow*: bool

  AgentWorkspaceSummary* = object
    ## Aggregate counters shown in the Agent Workspace summary bar.
    totalLinesCovered*: int
    totalLinesUncovered*: int
    coveragePercent*: float
    testsRun*: int
    testsPassed*: int
    testsFailed*: int
    functionsTraced*: int
