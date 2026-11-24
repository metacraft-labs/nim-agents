import std/json
import std/strutils
import std/uri
when not defined(js):
  import std/[os, atomics, locks]
import nim_acp
import nim_agent_harbor
import nim_everywhere
import ./agent_events

export agent_events

type
  AgentBackendKind* = enum
    abkAcp
    abkHarbor
  AcpAgentKind* = enum
    ## Which stdio ACP server to spawn when callers don't supply a
    ## binary path directly. ``aakCustom`` defers the choice to the
    ## caller (binary + args must be passed alongside).
    aakClaude = "claude"
    aakCodex = "codex"
    aakCustom = "custom"
  AgentEventCursor* = ref object
    value*: int
  AgentSessionLifecycle* = enum
    aslReady, aslFailed, aslClosing, aslClosed
  AgentTurnState* = enum
    atsIdle, atsWorking, atsCompleted, atsFailed
  AgentSessionRuntime* = ref object
    delivering: bool
    when defined(js):
      lifecycleValue: AgentSessionLifecycle
      turnValue: AgentTurnState
    else:
      stateLock: Lock
      deliveryFinished: Cond
      lifecycleValue: Atomic[AgentSessionLifecycle]
      turnValue: Atomic[AgentTurnState]
  AgentSessionCapabilities* = object
    persistent*: bool
    cancelTurn*: bool
    closeSession*: bool
  AgentSession* = object
    id*: string
    taskId*: string
    backend*: AgentBackendKind
    eventCursor*: AgentEventCursor
    capabilities*: AgentSessionCapabilities
    runtime*: AgentSessionRuntime
  PromptRejectedError* = object of HarborError
    response*: PromptAcceptedResponse
  PromptTurn* = object
    session*: AgentSession
    stopReason*: StopReason
    updates*: seq[SessionUpdate]
  WorkspaceIsolation* = enum
    wiNone = "none"
    wiGitWorktree = "git_worktree"
  AgentWorkspaceContext* = object
    tenantId*: string
    projectId*: string
    cwd*: string
    repoMode*: string
    repoUrl*: string
    branch*: string
    commit*: string
    executionHostId*: string
    workingCopyMode*: string
  HarborAcpAgentConfig* = object
    software*: string ## Empty keeps the existing external ACP-agent selection.
    model*: string
    version*: string
    displayName*: string
    binary*: string
    args*: seq[string]
    settings*: JsonNode
  HarborTaskConfig* = object
    allowNetwork*: bool
    workspace*: AgentWorkspaceContext
    prompt*: seq[ContentBlock]
    acpAgent*: HarborAcpAgentConfig
    labels*: JsonNode
  AgentStartMode* = object
    allowNetwork*: bool
    workspace*: AgentWorkspaceContext
    prompt*: seq[ContentBlock]
    acpAgent*: HarborAcpAgentConfig
    labels*: JsonNode
  AgentFileStat* = object
    path*: string
    oldPath*: string
    status*: string
    linesAdded*: int
    linesRemoved*: int
    binary*: bool
    sizeBytes*: int64
    contentType*: string
    raw*: JsonNode
  AgentChangedFiles* = object
    items*: seq[AgentFileStat]
    total*: int
    page*: int
    perPage*: int
    nextPage*: int
    raw*: JsonNode
  AgentFileContent* = object
    path*: string
    content*: string
    status*: int
    contentType*: string
    contentRange*: string
    acceptRanges*: string
  AgentFileDiff* = object
    path*: string
    oldPath*: string
    status*: string
    diff*: string
    linesAdded*: int
    linesRemoved*: int
    binary*: bool
    contextLines*: int
    raw*: JsonNode
  AgentSessionInfo* = object
    id*: string
    status*: string
    eventsUrl*: string
    leader*: string
    workspacePath*: string
    workingCopyMode*: string
    raw*: JsonNode
  AgentMilestoneFile* = object
    path*: string
    title*: string
    currentMilestone*: string
    status*: string
    totalMilestones*: int
    completedMilestones*: int
    progressPercent*: int
    raw*: JsonNode
  AgentMilestoneProgress* = object
    taskId*: string
    files*: seq[AgentMilestoneFile]
    pendingFeedbackCount*: int
    raw*: JsonNode
  AgentClient* = object
    backend*: AgentBackendKind
    acp*: AcpClient
    harbor*: HarborClient
  AgentSessionLoadState* = enum
    ## Outcome of :proc:`loadSession`.
    ##
    ## The three states are kept apart because a consumer has to *say*
    ## which one happened.  "The agent holds this session and it is
    ## empty" and "this session could not be fetched" render as the same
    ## blank panel unless the difference survives the call, and a blank
    ## panel reads as "the agent did nothing" — a statement neither
    ## failure supports.
    aslsLoaded = "loaded"
      ## The backend answered and the transcript below is what it holds.
      ## Zero events is a legitimate ``aslsLoaded``: the session exists
      ## and carries nothing.
    aslsUnsupported = "unsupported"
      ## The backend cannot replay sessions *at all* — an ACP agent that
      ## does not advertise ``loadSession``.  No session on this agent
      ## will load, so retrying another id is pointless.
    aslsUnavailable = "unavailable"
      ## The backend could have replayed a session but not *this* one:
      ## pruned, unknown, belonging to another workspace, or unreachable.
      ## :field:`AgentSessionLoad.message` carries the backend's own
      ## words, which are the only thing that can explain which.
  AgentSessionLoad* = object
    ## What :proc:`loadSession` returned, backend-agnostic.
    session*: AgentSession
    state*: AgentSessionLoadState
    message*: string
      ## The backend's diagnostic for a non-``aslsLoaded`` state, and the
      ## empty string otherwise.  Never invented here: it is the agent's
      ## or Harbor's own message, so a user reading it is reading the
      ## system that actually refused.
    events*: seq[AgentEvent]

proc fromAcp*(client: AcpClient): AgentClient =
  AgentClient(backend: abkAcp, acp: client)

proc lifecycle*(state: AgentSessionRuntime): AgentSessionLifecycle =
  when defined(js): state.lifecycleValue
  else: state.lifecycleValue.load()

proc `lifecycle=`(state: AgentSessionRuntime; value: AgentSessionLifecycle) =
  when defined(js): state.lifecycleValue = value
  else: state.lifecycleValue.store(value)

proc turn*(state: AgentSessionRuntime): AgentTurnState =
  when defined(js): state.turnValue
  else: state.turnValue.load()

proc `turn=`(state: AgentSessionRuntime; value: AgentTurnState) =
  when defined(js): state.turnValue = value
  else: state.turnValue.store(value)

proc newSessionRuntime(): AgentSessionRuntime =
  result = AgentSessionRuntime()
  when not defined(js):
    initLock(result.stateLock)
    initCond(result.deliveryFinished)
  result.lifecycle = aslReady
  result.turn = atsWorking

template withSessionState(state: AgentSessionRuntime; body: untyped) =
  when defined(js):
    body
  else:
    withLock state.stateLock:
      body

proc finishTurn(state: AgentSessionRuntime; reason: StopReason) =
  if state == nil: return
  withSessionState(state):
    if state.lifecycle != aslClosed:
      state.turn = if reason in {srEndTurn, srMaxTokens}: atsCompleted else: atsFailed
      if reason notin {srEndTurn, srMaxTokens} and state.lifecycle != aslClosing:
        state.lifecycle = aslFailed

proc admitTurn(state: AgentSessionRuntime) =
  if state == nil: return
  withSessionState(state):
    if state.lifecycle != aslReady:
      raise newException(HarborError, "Session is not ready for another prompt")
    if state.turn == atsWorking:
      raise newException(HarborError, "A turn is already running")
    state.turn = atsWorking

proc beginDelivery(state: AgentSessionRuntime) =
  if state == nil: return
  withSessionState(state):
    if state.lifecycle != aslReady:
      raise newException(HarborError, "Session closed before prompt delivery")
    state.delivering = true

proc endDelivery(state: AgentSessionRuntime) =
  if state == nil: return
  withSessionState(state):
    state.delivering = false
    when not defined(js): broadcast(state.deliveryFinished)

proc shutdown*(client: var AgentClient) {.gcsafe.} =
  ## Release any resources the agent client holds.  For
  ## :const:`abkAcp` clients this terminates the underlying ACP
  ## transport (including any spawned stdio child process).  Idempotent
  ## and safe to call on partially-initialised clients; harbor clients
  ## currently have no analogous resource to release, so the call is a
  ## no-op there.
  case client.backend
  of abkAcp:
    if client.acp.shutdown != nil:
      client.acp.shutdown()
      client.acp.shutdown = nil
  of abkHarbor:
    discard

proc fromHarbor*(client: HarborClient): AgentClient =
  AgentClient(backend: abkHarbor, harbor: client)

when not defined(js):
  proc fromStdioAcpAgent*(cmd: string; args: openArray[string] = [];
      defaultTimeoutMs = -1;
      idleTimeoutMs = DefaultNativeStdioTimeoutMs;
      hardDeadlineMs = DefaultNativeStdioHardDeadlineMs;
      launchPrefix: seq[string] = @[]): AgentClient =
    ## Generic factory: spawn ``cmd`` (a stdio-speaking ACP server)
    ## with ``args`` and wrap it in an :type:`AgentClient`. ``cmd`` is
    ## resolved via :proc:`findExe` when it looks like a bare binary
    ## name; absolute paths are passed straight through. Used as the
    ## building block by the kind-specific factories below — callers
    ## that already know exactly which binary they want should reach
    ## for this entrypoint directly.
    ##
    ## *Timeout knobs (follow-up 1).*  ``idleTimeoutMs`` bounds the
    ## silence between frames (default 60 s); ``hardDeadlineMs`` is
    ## the wall-clock cap (default 30 min).  The legacy
    ## ``defaultTimeoutMs`` parameter is still accepted as an alias for
    ## ``idleTimeoutMs`` for backwards compatibility — when non-
    ## negative it overrides the explicit ``idleTimeoutMs`` value.
    # Optional prefix wraps the resolved provider executable without changing
    # provider choice, argument order or ACP transport timeout semantics.
    if cmd.len == 0:
      raise newException(AcpError,
        "fromStdioAcpAgent: empty command")
    # Resolve the documented explicit override BEFORE applying a launch prefix.
    # The lower transport must not replace the wrapper executable afterward.
    let selected = getEnv("ISONIM_ACP_AGENT_CMD", cmd)
    let resolved =
      if selected.contains(DirSep) or fileExists(selected): selected
      else: findExe(selected)
    if resolved.len == 0:
      raise newException(AcpError,
        "fromStdioAcpAgent: command not found on PATH: " & cmd)
    var launchBinary = resolved
    var argsSeq = @args
    if launchPrefix.len > 0:
      launchBinary = launchPrefix[0]
      argsSeq = launchPrefix[1 .. ^1] & @[resolved] & argsSeq
    let transport = newNativeStdioAcpTransport(launchBinary, argsSeq,
      defaultTimeoutMs = defaultTimeoutMs,
      idleTimeoutMs = idleTimeoutMs,
      hardDeadlineMs = hardDeadlineMs, allowCommandOverride = false)
    fromAcp(newAcpClient(transport))

  proc resolveFirstOnPath(candidates: openArray[string]): string =
    for c in candidates:
      if c.len == 0: continue
      let resolved =
        if c.contains(DirSep) or fileExists(c): c
        else: findExe(c)
      if resolved.len > 0:
        return resolved
    ""

  proc fromClaudeCodeAcp*(extraArgs: seq[string] = @[];
      defaultTimeoutMs = -1;
      idleTimeoutMs = DefaultNativeStdioTimeoutMs;
      hardDeadlineMs = DefaultNativeStdioHardDeadlineMs;
      launchPrefix: seq[string] = @[]): AgentClient =
    ## Convenience factory that spawns the ``claude-code-acp`` (formerly
    ## ``@anthropic-ai/claude-code-acp``, now packaged in nixpkgs as
    ## ``claude-agent-acp``) binary as an ACP-speaking subprocess and
    ## wraps it in an :type:`AgentClient`. The ``ISONIM_ACP_AGENT_CMD``
    ## environment variable overrides the binary, which is the recommended
    ## way to redirect tests at a stub.
    let envOverride = getEnv("ISONIM_ACP_AGENT_CMD")
    let candidates =
      if envOverride.len > 0: @[envOverride]
      else: @["claude-code-acp", "claude-agent-acp"]
    let binary = resolveFirstOnPath(candidates)
    if binary.len == 0:
      raise newException(AcpError,
        "fromClaudeCodeAcp: none of " & $candidates &
        " resolved on PATH; set ISONIM_ACP_AGENT_CMD to override")
    fromStdioAcpAgent(binary, extraArgs,
      defaultTimeoutMs = defaultTimeoutMs,
      idleTimeoutMs = idleTimeoutMs,
      hardDeadlineMs = hardDeadlineMs, launchPrefix = launchPrefix)

  proc fromCodexAcp*(extraArgs: seq[string] = @[];
      defaultTimeoutMs = -1;
      idleTimeoutMs = DefaultNativeStdioTimeoutMs;
      hardDeadlineMs = DefaultNativeStdioHardDeadlineMs;
      launchPrefix: seq[string] = @[]): AgentClient =
    ## Sibling of :proc:`fromClaudeCodeAcp` for the OpenAI Codex ACP
    ## adapter (``pkgs.codex-acp`` in nixpkgs).  Resolution order:
    ## ``$ISONIM_CODEX_ACP_CMD`` env → ``findExe("codex-acp")``.
    let envOverride = getEnv("ISONIM_CODEX_ACP_CMD")
    let candidates =
      if envOverride.len > 0: @[envOverride]
      else: @["codex-acp"]
    let binary = resolveFirstOnPath(candidates)
    if binary.len == 0:
      raise newException(AcpError,
        "fromCodexAcp: none of " & $candidates &
        " resolved on PATH; set ISONIM_CODEX_ACP_CMD to override")
    fromStdioAcpAgent(binary, extraArgs,
      defaultTimeoutMs = defaultTimeoutMs,
      idleTimeoutMs = idleTimeoutMs,
      hardDeadlineMs = hardDeadlineMs, launchPrefix = launchPrefix)

  proc fromAcpAgent*(kind: AcpAgentKind; extraArgs: seq[string] = @[];
      cmd: string = ""; args: seq[string] = @[];
      defaultTimeoutMs = -1;
      idleTimeoutMs = DefaultNativeStdioTimeoutMs;
      hardDeadlineMs = DefaultNativeStdioHardDeadlineMs;
      launchPrefix: seq[string] = @[]): AgentClient =
    ## Kind-discriminated convenience entry point so HTTP handlers,
    ## CLI dispatchers and tests can switch backends with a single
    ## ``case`` rather than an if/else tree.
    ##
    ## ``aakClaude`` → :proc:`fromClaudeCodeAcp` (``extraArgs`` is forwarded).
    ## ``aakCodex``  → :proc:`fromCodexAcp` (``extraArgs`` is forwarded).
    ## ``aakCustom`` → :proc:`fromStdioAcpAgent` — the caller must supply
    ##                 ``cmd`` (and optionally ``args``); ``extraArgs``
    ##                 is appended after ``args`` so config-level args
    ##                 stay separable from per-call overrides.
    case kind
    of aakClaude:
      fromClaudeCodeAcp(extraArgs,
        defaultTimeoutMs = defaultTimeoutMs,
        idleTimeoutMs = idleTimeoutMs,
        hardDeadlineMs = hardDeadlineMs, launchPrefix = launchPrefix)
    of aakCodex:
      fromCodexAcp(extraArgs,
        defaultTimeoutMs = defaultTimeoutMs,
        idleTimeoutMs = idleTimeoutMs,
        hardDeadlineMs = hardDeadlineMs, launchPrefix = launchPrefix)
    of aakCustom:
      if cmd.len == 0:
        raise newException(AcpError,
          "fromAcpAgent(aakCustom): ``cmd`` is required for the custom backend")
      var combined = args
      combined.add extraArgs
      fromStdioAcpAgent(cmd, combined,
        defaultTimeoutMs = defaultTimeoutMs,
        idleTimeoutMs = idleTimeoutMs,
        hardDeadlineMs = hardDeadlineMs, launchPrefix = launchPrefix)

proc toHarborContentBlock*(item: ContentBlock): HarborContentBlock =
  case item.kind
  of cbText:
    nim_agent_harbor.HarborContentBlock(kind: hcbText, text: item.text)
  of cbImage:
    nim_agent_harbor.HarborContentBlock(kind: hcbImage, uri: item.uri,
      mimeType: item.mimeType, data: item.data)
  of cbAudio:
    nim_agent_harbor.HarborContentBlock(kind: hcbAudio, uri: item.uri,
      mimeType: item.mimeType, data: item.data)
  of cbResource:
    nim_agent_harbor.HarborContentBlock(kind: hcbResource, uri: item.uri,
      mimeType: item.mimeType, data: item.data)

proc toHarborContentBlocks*(items: openArray[ContentBlock]): seq[
    HarborContentBlock] =
  for item in items:
    result.add item.toHarborContentBlock()

proc promptText*(items: openArray[ContentBlock]): string =
  ## Harbor accepts a string prompt. Preserve resource identity as one JSON
  ## context line without fetching URIs; JSON escaping prevents embedded URI
  ## or MIME newlines from changing the block framing. Text-only bytes retain
  ## their existing representation and order.
  for item in items:
    var blockText: string
    case item.kind
    of cbText:
      blockText = item.text
    of cbResource:
      if item.uri.len == 0:
        raise newException(ValueError, "resource context requires a nonempty URI")
      var resource = %*{"uri": item.uri}
      if item.mimeType.len > 0:
        resource["mimeType"] = %item.mimeType
      blockText = "resource: " & $resource
    else:
      discard
    if blockText.len > 0:
      if result.len > 0:
        result.add "\n\n"
      result.add blockText

proc defaultWorkspaceContext*(cwd = ""): AgentWorkspaceContext =
  AgentWorkspaceContext(repoMode: "none", cwd: cwd)

proc gitWorktreeWorkspace*(cwd: string; tenantId = ""; projectId = "";
    repoUrl = ""; branch = ""; commit = "";
        executionHostId = ""): AgentWorkspaceContext =
  AgentWorkspaceContext(
    tenantId: tenantId,
    projectId: projectId,
    cwd: cwd,
    repoMode: if repoUrl.len > 0: "git" else: "none",
    repoUrl: repoUrl,
    branch: branch,
    commit: commit,
    executionHostId: executionHostId,
    workingCopyMode: $wiGitWorktree)

proc taskPrompt*(instructions: string; context: openArray[string] = [];
    evidenceCommand = ""; evidenceRequirement = ""): seq[ContentBlock] =
  result.add textBlock(instructions)
  for item in context:
    if item.len > 0:
      result.add textBlock(item)
  if evidenceCommand.len > 0:
    let requirement =
      if evidenceRequirement.len > 0: evidenceRequirement
      else: "Run this command after executing one or more tests that demonstrate the change."
    result.add textBlock(requirement & "\n\n" & evidenceCommand)

proc acpAgentConfig*(binary: string; args: seq[string] = @[];
    model = "default"; version = "latest"; displayName = "";
    settings: JsonNode = nil): HarborAcpAgentConfig =
  HarborAcpAgentConfig(
    model: model,
    version: version,
    displayName: displayName,
    binary: binary,
    args: args,
    settings: if settings == nil: newJObject() else: settings)

proc harborAgentConfig*(config: HarborAcpAgentConfig): AgentConfig =
  result = defaultAgent(if config.software.len > 0: config.software else: "acp", config.model)
  result.agent.version = if config.version.len >
      0: config.version else: "latest"
  result.displayName = config.displayName
  result.settings = if config.settings == nil: newJObject() else: config.settings
  if config.binary.len > 0:
    result.acpStdioLaunchCommand = AcpStdioLaunchCommand(
      binary: config.binary,
      args: config.args)

proc harborPromptText*(items: openArray[ContentBlock]): string =
  # REST accepts one string. Preserve canonical resource identity and admitted
  # textual content through the existing ordered text-block representation.
  # No resource URI is opened and no new resource JSON fields are introduced.
  var expanded: seq[ContentBlock]
  for item in items:
    case item.kind
    of cbText:
      expanded.add item
    of cbResource:
      if item.data.len > 0 and not (item.mimeType.startsWith("text/") or
          item.mimeType == "application/json"):
        raise newException(HarborError, "Harbor REST prompts cannot embed binary resources")
      expanded.add item
      if item.data.len > 0:
        expanded.add textBlock(item.data)
    else:
      raise newException(HarborError, "Harbor REST prompts currently support text and textual resource references only")
  promptText(expanded)

proc buildHarborTaskRequest*(config: HarborTaskConfig): CreateTaskRequest =
  let repoMode =
    if config.workspace.repoMode.len > 0: config.workspace.repoMode
    elif config.workspace.repoUrl.len > 0: "git"
    else: "none"
  result = CreateTaskRequest(
    tenantId: config.workspace.tenantId,
    projectId: config.workspace.projectId,
    prompt: harborPromptText(config.prompt),
    repo: RepoConfig(
      mode: repoMode,
      url: config.workspace.repoUrl,
      branch: config.workspace.branch,
      commit: config.workspace.commit),
    runtime: defaultRuntime(),
    workspacePath: config.workspace.cwd,
    workingCopyMode: config.workspace.workingCopyMode,
    executionHostId: config.workspace.executionHostId,
    sandbox: defaultSandbox(),
    delivery: defaultDelivery(),
    agents: @[harborAgentConfig(config.acpAgent)],
    output: defaultOutput(),
    labels: if config.labels == nil: newJObject() else: config.labels)
  result.sandbox.allowNetwork = config.allowNetwork
  if config.workspace.cwd.len > 0:
    result.labels["cwd"] = %config.workspace.cwd

proc harborWorktreeTaskConfig*(cwd: string; prompt: seq[ContentBlock];
    acpAgent: HarborAcpAgentConfig; tenantId = ""; projectId = "";
    repoUrl = ""; branch = ""; commit = ""; executionHostId = "";
    labels: JsonNode = nil): HarborTaskConfig =
  HarborTaskConfig(
    workspace: gitWorktreeWorkspace(cwd, tenantId, projectId, repoUrl, branch,
      commit, executionHostId),
    prompt: prompt,
    acpAgent: acpAgent,
    labels: if labels == nil: newJObject() else: labels)

type
  AgentEventCallback* = proc(event: AgentEvent) {.closure, gcsafe.}
    ## Called once per decoded agent event during streaming prompt delivery.
    ## Invoked synchronously from the transport reader loop; callbacks must not
    ## block on additional frames from the same transport.

proc readAgentEvents*(client: var AgentClient; session: AgentSession): seq[AgentEvent] =
  case client.backend
  of abkAcp:
    for update in client.acp.drainUpdates():
      result.add acpUpdateToAgentEvent(session.id, update)
  of abkHarbor:
    result = harborEventsToAgentEvents(session.id,
      client.harbor.readSessionEvents(session.id))

# --------------------------------------------------------------------------- #
#  Loading an *existing* session (RV-6).
#
#  ``startSession`` + ``readAgentEvents`` cover a session this process
#  started.  ``loadSession`` covers the other case: a session that ran
#  earlier, possibly in another process, which something now holds a
#  reference to — a CodeTracer review dataset naming the agent run that
#  produced it, say.  The two backends get there very differently:
#
#    * ACP    — the protocol's optional ``session/load``, which must be
#               capability-checked before it is issued;
#    * Harbor — ``readSessionEvents(sessionId)``, which has always been
#               able to read any session by id.
#
#  Callers see neither difference.
# --------------------------------------------------------------------------- #

proc parseAgentSessionLoadState*(value: string): AgentSessionLoadState =
  ## Inverse of ``$`` for :type:`AgentSessionLoadState`.
  ##
  ## An unrecognised spelling resolves to :const:`aslsUnavailable` rather
  ## than to :const:`aslsLoaded`, because the failure mode of guessing
  ## wrong in the other direction is a panel that silently claims an
  ## empty conversation.
  case value
  of "loaded": aslsLoaded
  of "unsupported": aslsUnsupported
  else: aslsUnavailable

proc agentBackendName*(backend: AgentBackendKind): string =
  ## Wire spelling of a backend, for the JSON forms below.
  case backend
  of abkAcp: "acp"
  of abkHarbor: "harbor"

proc parseAgentBackendKind*(value: string): AgentBackendKind =
  if value == "harbor": abkHarbor else: abkAcp

proc toJson*(load: AgentSessionLoad): JsonNode =
  ## Serialise a resolved session for hand-off to another process.
  ##
  ## The *state* travels with the transcript on purpose: a consumer that
  ## received only events could not tell an empty session from a failed
  ## fetch, which is precisely the distinction :type:`AgentSessionLoadState`
  ## exists to preserve.
  result = %*{
    "state": $load.state,
    "sessionId": load.session.id,
    "taskId": load.session.taskId,
    "backend": agentBackendName(load.session.backend),
    "message": load.message
  }
  var events = newJArray()
  for event in load.events:
    events.add event.toJson()
  result["events"] = events

proc agentSessionLoadFromJson*(node: JsonNode): AgentSessionLoad =
  result = AgentSessionLoad(
    session: AgentSession(
      id: node{"sessionId"}.getStr(""),
      taskId: node{"taskId"}.getStr(""),
      backend: parseAgentBackendKind(node{"backend"}.getStr("acp"))),
    state: parseAgentSessionLoadState(node{"state"}.getStr("unavailable")),
    message: node{"message"}.getStr(""))
  for entry in node{"events"}.items:
    result.events.add agentEventFromJson(entry)

proc loadSession*(client: var AgentClient; sessionId: string; cwd = "";
    mcpServers: seq[string] = @[]; taskId = ""): AgentSessionLoad =
  ## Re-open the session `sessionId` on whichever backend this client
  ## speaks, and return its whole conversation.
  ##
  ## One API, backend-agnostic to callers: ACP goes through the
  ## protocol's ``session/load`` (negotiating the ``initialize``
  ## handshake first if the caller has not, since the capability check
  ## needs its answer), Harbor through the REST events endpoint it has
  ## always had.  Both produce :type:`AgentEvent` values — the same type
  ## :proc:`readAgentEvents` yields for a *live* session — so a consumer
  ## renders a finished session and a running one with one code path.
  ##
  ## *Failures are returned, not raised.*  A reference that will not
  ## resolve is an ordinary, expected outcome (the session was pruned;
  ## the agent cannot replay sessions; the workspace is elsewhere) and it
  ## has to be *shown* rather than logged.  Making it a state on the
  ## result means a caller cannot accidentally swallow it in a `try`
  ## around unrelated work and end up painting an empty conversation,
  ## which reads as "the agent did nothing".  Programming errors — a
  ## malformed URL, a transport that was never wired — still propagate.
  ##
  ## ``cwd`` and ``mcpServers`` are ACP's workspace context: an agent
  ## resolves a session against the directory it ran in, so passing the
  ## review's workspace is what stops a session being replayed against
  ## the wrong tree.  Harbor ignores them; it addresses sessions by id
  ## alone.
  result = AgentSessionLoad(
    session: AgentSession(id: sessionId, taskId: taskId,
                          backend: client.backend),
    state: aslsUnavailable)
  case client.backend
  of abkAcp:
    if not client.acp.capabilitiesNegotiated:
      # ACP requires ``initialize`` before any other method and the
      # capability check needs its answer.  A caller that only wants to
      # read a finished session should not have to know that, so the
      # handshake happens here.
      try:
        discard client.acp.initialize(InitializeRequest(
          protocolVersion: 1,
          clientInfo: ClientInfo(name: "nim-agents", version: "0.1.0"),
          clientCapabilities: ClientCapabilities(streaming: true)))
      except AcpError as e:
        result.message = e.msg
        return
    try:
      let loaded = client.acp.loadSession(LoadSessionRequest(
        sessionId: sessionId, cwd: cwd, mcpServers: mcpServers))
      result.state = aslsLoaded
      result.session.id = loaded.sessionId
      result.events = acpUpdatesToAgentEvents(loaded.sessionId, loaded.updates)
    except AcpSessionLoadUnsupportedError as e:
      # The agent cannot replay sessions at all — a different fact from
      # "this session is gone", and the caller is told which.
      result.state = aslsUnsupported
      result.message = e.msg
    except AcpError as e:
      result.message = e.msg
  of abkHarbor:
    try:
      result.events = harborEventsToAgentEvents(sessionId,
        client.harbor.readSessionEvents(sessionId))
      result.state = aslsLoaded
    except HarborError as e:
      result.message = e.msg

proc createSession*(client: var AgentClient; config: AgentStartMode): AgentSession =
  ## A persistent conversation, distinct from the legacy task-launch API.
  ## Harbor requires a first prompt; callers keep empty conversations as local drafts.
  if client.backend != abkHarbor:
    raise newException(AcpError, "createSession currently requires Harbor REST")
  if config.acpAgent.binary.len == 0:
    raise newException(HarborError, "Persistent Harbor sessions require an ACP provider launch command")
  if config.workspace.workingCopyMode notin ["", "in_place"]:
    raise newException(HarborError, "Persistent sessions require an existing in-place workspace")
  let task = buildHarborTaskRequest(HarborTaskConfig(
    workspace: config.workspace, allowNetwork: config.allowNetwork,
    prompt: config.prompt, acpAgent: config.acpAgent, labels: config.labels))
  let response = client.harbor.createSession(CreateSessionRequest(
    prompt: task.prompt, workspacePath: config.workspace.cwd,
    agent: task.agents[0], output: defaultOutput(), sandbox: task.sandbox,
    labels: task.labels))
  AgentSession(id: response.sessionId, backend: abkHarbor,
    eventCursor: AgentEventCursor(),
    runtime: newSessionRuntime(),
    capabilities: AgentSessionCapabilities(
      persistent: true, cancelTurn: false, closeSession: true))

proc cancelTurn*(client: var AgentClient; session: AgentSession) =
  ## Stopping the process is never a fallback for cancelling its current turn.
  case client.backend
  of abkAcp: client.acp.cancel(session.id)
  of abkHarbor:
    raise newException(HarborError, "Harbor REST does not expose process-preserving turn cancellation")

proc closeSession*(client: var AgentClient; session: AgentSession) =
  case client.backend
  of abkHarbor:
    var previous = aslReady
    if session.runtime != nil:
      withSessionState(session.runtime):
        previous = session.runtime.lifecycle
        if previous == aslClosed: return
        if previous == aslClosing:
          raise newException(HarborError, "Session closure is already pending")
        when defined(js):
          if session.runtime.delivering:
            raise newException(HarborError, "Prompt delivery is pending; retry closure after admission")
        session.runtime.lifecycle = aslClosing
        when not defined(js):
          while session.runtime.delivering:
            wait(session.runtime.deliveryFinished, session.runtime.stateLock)
    try:
      client.harbor.stopSession(session.id)
      if session.runtime != nil:
        withSessionState(session.runtime):
          session.runtime.lifecycle = aslClosed
          session.runtime.turn = atsIdle
    except CatchableError:
      if session.runtime != nil:
        withSessionState(session.runtime):
          session.runtime.lifecycle = if session.runtime.turn == atsFailed: aslFailed else: previous
      raise
  of abkAcp:
    raise newException(AcpError, "Explicit ACP session closure is not supported")

proc startSession*(client: var AgentClient; cwd: string;
    prompt: seq[ContentBlock] = @[]; systemInstructions = ""): AgentSession =
  case client.backend
  of abkAcp:
    let meta = if systemInstructions.len > 0:
                 %* {"systemPrompt": {"append": systemInstructions}}
               else: nil
    let session = client.acp.startSession(NewSessionRequest(cwd: cwd, meta: meta))
    AgentSession(id: session.sessionId, backend: abkAcp)
  of abkHarbor:
    if systemInstructions.len > 0:
      raise newException(HarborError, "Harbor REST task creation cannot deliver role instructions directly; use a provider launcher that supports system instructions")
    let response = client.harbor.createTask(buildHarborTaskRequest(HarborTaskConfig(
      workspace: defaultWorkspaceContext(cwd),
      prompt: prompt,
      acpAgent: acpAgentConfig(""))))
    let id = if response.sessionIds.len > 0: response.sessionIds[
        0] else: response.taskId
    AgentSession(id: id, taskId: response.taskId, backend: abkHarbor,
      eventCursor: AgentEventCursor())

proc startSession*(client: var AgentClient;
    config: AgentStartMode): AgentSession =
  case client.backend
  of abkAcp:
    let session = client.acp.startSession(NewSessionRequest(
        cwd: config.workspace.cwd))
    AgentSession(id: session.sessionId, backend: abkAcp)
  of abkHarbor:
    let response = client.harbor.createTask(buildHarborTaskRequest(HarborTaskConfig(
      workspace: config.workspace,
      allowNetwork: config.allowNetwork,
      prompt: config.prompt,
      acpAgent: config.acpAgent,
      labels: config.labels)))
    let id = if response.sessionIds.len > 0: response.sessionIds[
        0] else: response.taskId
    AgentSession(id: id, taskId: response.taskId, backend: abkHarbor,
      eventCursor: AgentEventCursor())

proc sendPromptStreaming*(client: var AgentClient; session: AgentSession;
    prompt: seq[ContentBlock]; onEvent: AgentEventCallback): PromptTurn

proc rejectHarborPrompt(response: PromptAcceptedResponse) {.noreturn.} =
  var details = %* {"stopReason": response.stopReason, "operationId": (if response.operationIdNull: newJNull() else: %response.operationId),
    "noOperation": response.noOperation,
    "deliveryState": (if response.deliveryStateNull: newJNull() else: %response.deliveryState), "limitChars": response.limitChars,
    "currentChars": response.currentChars, "remainingChars": response.remainingChars,
    "usedChars": response.usedChars, "overLimitBy": response.overLimitBy}
  if not response.operationIdPresent: details.delete("operationId")
  if not response.deliveryStatePresent: details.delete("deliveryState")
  else: details["deliveryStateType"] = %response.deliveryStateType
  let reason = if response.stopReason == "context_limit":
    "Session context budget exceeded; backend reports " & $response.remainingChars &
      " characters remaining. Shorten optional context/message or start a new conversation. "
    else: "Harbor rejected the follow-up prompt: "
  var error = newException(PromptRejectedError, reason & $details)
  error.response = response
  raise error

proc sendPrompt*(client: var AgentClient; session: AgentSession;
    prompt: seq[ContentBlock]): PromptTurn =
  case client.backend
  of abkAcp:
    let response = client.acp.sendPrompt(PromptRequest(sessionId: session.id,
        prompt: prompt))
    PromptTurn(session: session, stopReason: response.stopReason,
        updates: client.acp.drainUpdates())
  of abkHarbor:
    if session.capabilities.persistent:
      return client.sendPromptStreaming(session, prompt, nil)
    let accepted = client.harbor.sendPrompt(session.id, @[harborTextBlock(harborPromptText(prompt))])
    if not accepted.accepted:
      rejectHarborPrompt(accepted)
    PromptTurn(session: session, stopReason: srEndTurn, updates: @[])

# --------------------------------------------------------------------------- #
#  Inject-prompt primitive (CMP-M3b).
#
#  Lets external callers push a user message into a running ACP session
#  that the agent picks up on its next turn.  The queue lives on the
#  underlying :type:`AcpTransport`; these wrappers are thin pass-throughs
#  exposed at the :type:`AgentClient` surface so daemon/CLI/AI-assistant
#  callers don't have to descend through the ACP client layer.
#
#  Harbor backend is currently rejected with a clear :type:`AcpError`
#  ("not supported on Agent Harbor backend yet") — Harbor's HTTP/SSE
#  model doesn't have an obvious inject point.  Lands later if needed.
# --------------------------------------------------------------------------- #

proc injectPrompt*(client: var AgentClient; sessionId, text: string) =
  ## Queue a user message for the named session.  Picked up on the
  ## next :proc:`sendPrompt` / :proc:`sendPromptStreaming` call by the
  ## campaign loop (CMP-M4 wires the consumer side).  Thread-safe:
  ## the underlying :type:`AcpTransport`'s injection queue is
  ## :type:`Lock`-protected on native builds.
  ##
  ## Raises :type:`AcpError` when the backend is Agent Harbor — the
  ## HTTP/SSE model doesn't have a natural inject point yet.
  case client.backend
  of abkAcp:
    if client.acp.injectUserMessage == nil:
      raise newException(AcpError,
        "ACP client has no injectUserMessage hook; rebuild the client " &
        "via newAcpClient(transport) so injection closures are wired")
    client.acp.injectUserMessage(sessionId, text)
  of abkHarbor:
    raise newException(AcpError,
      "injectPrompt: injection not supported on Agent Harbor backend yet")

proc takeQueuedInjections*(client: var AgentClient;
    sessionId: string): seq[string] =
  ## Atomically drain the queue and return the texts in FIFO order.
  ## Returns ``@[]`` when no pending messages.  Raises
  ## :type:`AcpError` for the Harbor backend (symmetric with
  ## :proc:`injectPrompt`).
  case client.backend
  of abkAcp:
    if client.acp.takeQueuedInjections == nil:
      return @[]
    for entry in client.acp.takeQueuedInjections(sessionId):
      result.add entry.text
  of abkHarbor:
    raise newException(AcpError,
      "takeQueuedInjections: injection not supported on Agent Harbor backend yet")

proc peekQueuedInjections*(client: var AgentClient;
    sessionId: string): seq[string] =
  ## Read-only inspection (for logging / debug).  Raises
  ## :type:`AcpError` for Harbor.
  case client.backend
  of abkAcp:
    if client.acp.peekQueuedInjections == nil:
      return @[]
    for entry in client.acp.peekQueuedInjections(sessionId):
      result.add entry.text
  of abkHarbor:
    raise newException(AcpError,
      "peekQueuedInjections: injection not supported on Agent Harbor backend yet")

proc cancelSession*(client: var AgentClient; session: AgentSession) =
  ## Compatibility spelling for turn cancellation; never closes the session.
  client.cancelTurn(session)

proc streamAgentTurn*(client: var AgentClient; session: AgentSession;
    onEvent: AgentEventCallback): PromptTurn =
  ## Consume the initial Harbor task turn, or a submitted follow-up, with a
  ## durable cursor so the next turn does not replay earlier output.
  if client.backend != abkHarbor:
    raise newException(HarborError, "streamAgentTurn requires Harbor")
  var reason = srError
  var observedRunning = false
  var awaitingIdle = false
  var successfulReason = srEndTurn
  let cursor = if session.eventCursor == nil: AgentEventCursor() else: session.eventCursor
  let callback: HarborStreamCallback = proc(event: HarborEvent; id: string): bool =
    if id.len > 0:
      cursor.value = parseInt(id)
    else:
      inc cursor.value
    var mapped = harborEventToAgentEvent(session.id, event)
    if id.len > 0: mapped.eventId = id
    if session.capabilities.persistent and mapped.kind == aekCompleted and
        mapped.stopReason in {srEndTurn, srMaxTokens}:
      # Durable model completion precedes the persistent worker's repromptable
      # transition. Keep consuming this exact stream until actual paused.
      awaitingIdle = true
      successfulReason = mapped.stopReason
      mapped.kind = aekStatus
      mapped.state = acsStreaming
    if session.capabilities.persistent and event.kind == hekStatus:
      if event.status == "running": observedRunning = true
      if event.status == "paused" and (observedRunning or awaitingIdle):
        # Harbor ACP defines Paused as idle/repromptable after PromptResponse.
        mapped.kind = aekCompleted
        mapped.state = acsCompleted
        mapped.stopReason = successfulReason
        awaitingIdle = false
      elif event.status == "completed":
        mapped.kind = aekError
        mapped.state = acsError
        mapped.stopReason = srError
        mapped.text = "Persistent agent process ended unexpectedly"
    if onEvent != nil: onEvent(mapped)
    if mapped.kind in {aekCompleted, aekCancelled, aekError}:
      awaitingIdle = false
      reason = mapped.stopReason
      return false
    true
  try:
    client.harbor.streamSessionEvents(session.id, callback, $cursor.value)
    if awaitingIdle:
      raise newException(HarborError, "Persistent provider stream ended before repromptable paused transition")
    finishTurn(session.runtime, reason)
  except CatchableError:
    finishTurn(session.runtime, srError)
    raise
  PromptTurn(session: session, stopReason: reason)

proc sendPromptStreaming*(client: var AgentClient; session: AgentSession;
    prompt: seq[ContentBlock];
    onEvent: AgentEventCallback): PromptTurn =
  ## Streaming variant of :proc:`sendPrompt`. ACP clients receive events as
  ## transport notifications arrive. Harbor consumes incremental REST SSE.
  case client.backend
  of abkAcp:
    let sessionId = session.id
    var collected: seq[SessionUpdate] = @[]
    let handler: SessionUpdateHandler = proc(update: SessionUpdate) =
      collected.add update
      if onEvent != nil:
        onEvent(acpUpdateToAgentEvent(sessionId, update))
    let response = client.acp.sendPromptStreaming(
      PromptRequest(sessionId: sessionId, prompt: prompt), handler)
    result = PromptTurn(session: session, stopReason: response.stopReason,
        updates: collected)
  of abkHarbor:
    # Reserve admission before any transport call. Locks never span callbacks or
    # HTTP, so a callback can close the session without deadlocking its stream.
    admitTurn(session.runtime)
    try:
      let history = client.harbor.readEventHistory(session.id, EventHistoryQuery(limit: 1))
      if session.eventCursor != nil: session.eventCursor.value = history.totalCount
      let text = harborPromptText(prompt)
      beginDelivery(session.runtime)
      try:
        let accepted = client.harbor.sendPrompt(session.id, @[harborTextBlock(text)])
        if not accepted.accepted:
          rejectHarborPrompt(accepted)
      finally:
        endDelivery(session.runtime)
      result = client.streamAgentTurn(session, onEvent)
    except PromptRejectedError as rejection:
      if not rejection.response.accepted and rejection.response.stopReason == "context_limit" and
          rejection.response.noOperation and rejection.response.deliveryState.len == 0 and
          rejection.response.sessionId == session.id:
        # This exact payload was explicitly rejected without a durable operation.
        # Retain a usable persistent session for a deliberate edited retry.
        if session.runtime != nil:
          withSessionState(session.runtime):
            if session.runtime.lifecycle == aslReady: session.runtime.turn = atsFailed
      else:
        finishTurn(session.runtime, srError)
      raise
    except CatchableError:
      finishTurn(session.runtime, srError)
      raise

proc requireHarbor(client: AgentClient) =
  if client.backend != abkHarbor:
    raise newException(HarborError, "Agent Harbor REST fetches require Harbor backend")

proc harborGet(client: AgentClient; path: string; accept = "application/json";
    headers: seq[HttpHeader] = @[]): HttpResponse =
  client.requireHarbor()
  let response = client.harbor.transport.request(newRequest(
    hmGet,
    client.harbor.baseUrl & path,
    "",
    @[header("Accept", accept)] & headers & client.harbor.auth.authHeaders()))
  if response.status < 200 or response.status >= 300:
    raise newException(HarborError, response.body)
  response

proc encodePath(path: string): string =
  var first = true
  for part in path.split('/'):
    if first:
      first = false
    else:
      result.add "/"
    result.add encodeUrl(part)

proc fileStatFromJson(node: JsonNode): AgentFileStat =
  AgentFileStat(
    path: node{"path"}.getStr(""),
    oldPath: node{"oldPath"}.getStr(node{"old_path"}.getStr("")),
    status: node{"status"}.getStr(""),
    linesAdded: node{"linesAdded"}.getInt(node{"lines_added"}.getInt(0)),
    linesRemoved: node{"linesRemoved"}.getInt(node{"lines_removed"}.getInt(0)),
    binary: node{"binary"}.getBool(false),
    sizeBytes: node{"sizeBytes"}.getBiggestInt(node{"size_bytes"}.getBiggestInt(0)),
    contentType: node{"contentType"}.getStr(node{"content_type"}.getStr("")),
    raw: node)

proc changedFiles*(client: AgentClient; session: AgentSession; page = 0;
    perPage = 0; status = ""; path = ""; snapshotId = ""): AgentChangedFiles =
  var query: seq[string] = @[]
  if page > 0: query.add "page=" & $page
  if perPage > 0: query.add "perPage=" & $perPage
  if status.len > 0: query.add "status=" & encodeUrl(status)
  if path.len > 0: query.add "path=" & encodeUrl(path)
  if snapshotId.len > 0: query.add "snapshotId=" & encodeUrl(snapshotId)
  let suffix = if query.len > 0: "?" & query.join("&") else: ""
  let rawNode = parseJson(client.harborGet("/api/v1/sessions/" & session.id &
    "/files" & suffix).body)
  let node =
    if rawNode.kind == JString:
      parseJson(rawNode.getStr())
    else:
      rawNode
  result.raw = node
  let itemsNode =
    if node.kind == JArray:
      node
    elif node.kind == JObject and node.hasKey("items"):
      node["items"]
    else:
      newJArray()
  for item in itemsNode.items:
    result.items.add fileStatFromJson(item)
  result.total = node{"total"}.getInt(result.items.len)
  result.page = node{"page"}.getInt(0)
  result.perPage = node{"perPage"}.getInt(node{"per_page"}.getInt(0))
  result.nextPage = node{"nextPage"}.getInt(node{"next_page"}.getInt(0))

proc fileContent*(client: AgentClient; session: AgentSession; path: string;
    range = ""; snapshotId = ""): AgentFileContent =
  var query = ""
  if snapshotId.len > 0:
    query = "?snapshotId=" & encodeUrl(snapshotId)
  var headers: seq[HttpHeader] = @[]
  if range.len > 0:
    headers.add header("Range", range)
  let response = client.harborGet("/api/v1/sessions/" & session.id &
    "/files/content/" & encodePath(path) & query,
        "text/plain, application/octet-stream",
    headers)
  result = AgentFileContent(path: path, content: response.body,
      status: response.status)
  for h in response.headers:
    case h.name.toLowerAscii()
    of "content-type": result.contentType = h.value
    of "content-range": result.contentRange = h.value
    of "accept-ranges": result.acceptRanges = h.value
    else: discard

proc fileDiff*(client: AgentClient; session: AgentSession; path: string;
    context = -1; snapshotId = ""): AgentFileDiff =
  var query: seq[string] = @[]
  if context >= 0: query.add "context=" & $context
  if snapshotId.len > 0: query.add "snapshotId=" & encodeUrl(snapshotId)
  let suffix = if query.len > 0: "?" & query.join("&") else: ""
  let node = parseJson(client.harborGet("/api/v1/sessions/" & session.id &
    "/diff/" & encodePath(path) & suffix).body)
  AgentFileDiff(
    path: node{"path"}.getStr(path),
    oldPath: node{"oldPath"}.getStr(node{"old_path"}.getStr("")),
    status: node{"status"}.getStr(""),
    diff: node{"diff"}.getStr(""),
    linesAdded: node{"linesAdded"}.getInt(node{"lines_added"}.getInt(0)),
    linesRemoved: node{"linesRemoved"}.getInt(node{"lines_removed"}.getInt(0)),
    binary: node{"binary"}.getBool(false),
    contextLines: node{"contextLines"}.getInt(node{"context_lines"}.getInt(0)),
    raw: node)

proc sessionInfo*(client: AgentClient; session: AgentSession): AgentSessionInfo =
  let rawNode = parseJson(client.harborGet("/api/v1/sessions/" & session.id & "/info").body)
  let node =
    if rawNode.kind == JString:
      parseJson(rawNode.getStr())
    else:
      rawNode
  result = AgentSessionInfo(
    id:
    if node.kind == JObject: node{"id"}.getStr(session.id)
      else: session.id,
    status:
    if node.kind == JObject: node{"status"}.getStr("")
      else: "",
    eventsUrl:
    if node.kind == JObject: node{"endpoints"}{"events"}.getStr("")
      else: "",
    leader:
    if node.kind == JObject: node{"fleet"}{"leader"}.getStr("")
      else: "",
    workspacePath:
    if node.kind == JObject:
        node{"workspacePath"}.getStr(node{"workspace_path"}.getStr(
          node{"workspace"}{"path"}.getStr(node{"workspace"}{"workspacePath"}.getStr(""))))
      else: "",
    workingCopyMode:
    if node.kind == JObject:
        node{"workingCopyMode"}.getStr(node{"working_copy_mode"}.getStr(
          node{"workspace"}{"workingCopyMode"}.getStr(
            node{"workspace"}{"working_copy_mode"}.getStr(""))))
      else: "",
    raw: node)

proc milestoneProgress*(client: AgentClient;
    session: AgentSession): AgentMilestoneProgress =
  let taskId = if session.taskId.len > 0: session.taskId else: session.id
  let rawNode = parseJson(client.harborGet("/api/v1/tasks/" & taskId &
      "/milestones").body)
  let node =
    if rawNode.kind == JString:
      parseJson(rawNode.getStr())
    else:
      rawNode
  result = AgentMilestoneProgress(
    taskId:
    if node.kind == JObject: node{"taskId"}.getStr(node{"task_id"}.getStr(taskId))
      else: taskId,
    pendingFeedbackCount:
    if node.kind == JObject and not node{"pendingFeedback"}.isNil:
        node{"pendingFeedback"}.len
      else: 0,
    raw: node)
  let filesNode =
    if node.kind == JArray:
      node
    elif node.kind == JObject and node.hasKey("files") and not node["files"].isNil:
      node["files"]
    else:
      newJArray()
  for item in filesNode.items:
    let summary = item{"summary"}
    result.files.add AgentMilestoneFile(
      path: item{"path"}.getStr(""),
      title: item{"title"}.getStr(""),
      currentMilestone: item{"currentMilestone"}.getStr(""),
      status: item{"status"}.getStr(""),
      totalMilestones: summary{"totalMilestones"}.getInt(0),
      completedMilestones: summary{"completedMilestones"}.getInt(0),
      progressPercent: summary{"progressPercent"}.getInt(0),
      raw: item)

proc eventHistoryPage*(client: AgentClient; session: AgentSession;
    limit = 0; before: int64 = 0): tuple[events: seq[AgentEvent], totalCount: int, hasMore: bool] =
  ## Actual history boundary for consumers which must establish provider
  ## continuity, without exposing backend raw graphs across threads.
  client.requireHarbor()
  let page = client.harbor.readEventHistory(session.id, EventHistoryQuery(limit: limit, before: before))
  result = (harborEventsToAgentEvents(session.id, page.events), page.totalCount, page.hasMore)

proc eventHistory*(client: AgentClient; session: AgentSession;
    limit = 0; before: int64 = 0): seq[AgentEvent] =
  client.requireHarbor()
  result = harborEventsToAgentEvents(session.id, client.harbor.readEventHistory(
    session.id, EventHistoryQuery(limit: limit, before: before)).events)
