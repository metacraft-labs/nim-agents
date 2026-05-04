import std/json
import nim_acp
import nim_agent_harbor

type
  AgentBackendKind* = enum
    abkAcp
    abkHarbor
  AgentSession* = object
    id*: string
    backend*: AgentBackendKind
  PromptTurn* = object
    session*: AgentSession
    stopReason*: StopReason
    updates*: seq[SessionUpdate]
  AgentConnectionState* = enum
    acsDisconnected = "disconnected"
    acsConnecting = "connecting"
    acsAuthenticating = "authenticating"
    acsConnected = "connected"
    acsStreaming = "streaming"
    acsRetrying = "retrying"
    acsCancelling = "cancelling"
    acsCancelled = "cancelled"
    acsCompleted = "completed"
    acsError = "error"
  AgentEventKind* = enum
    aekConnection = "connection"
    aekMessageChunk = "message_chunk"
    aekThoughtChunk = "thought_chunk"
    aekPlan = "plan"
    aekToolCall = "tool_call"
    aekToolCallUpdate = "tool_call_update"
    aekFileEdit = "file_edit"
    aekDiff = "diff"
    aekDelivery = "delivery"
    aekReview = "review"
    aekLlmRequest = "llm_request"
    aekSubAgent = "sub_agent"
    aekStatus = "status"
    aekError = "error"
    aekCancelled = "cancelled"
    aekCompleted = "completed"
  AgentEvent* = object
    sessionId*: string
    kind*: AgentEventKind
    state*: AgentConnectionState
    text*: string
    status*: string
    toolCallId*: string
    toolName*: string
    filePath*: string
    line*: int
    linesAdded*: int
    linesRemoved*: int
    diff*: string
    reviewSeverity*: string
    reviewCategory*: string
    planEntries*: seq[string]
    stopReason*: StopReason
    raw*: JsonNode
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
    model*: string
    version*: string
    displayName*: string
    binary*: string
    args*: seq[string]
    settings*: JsonNode
  HarborTaskConfig* = object
    workspace*: AgentWorkspaceContext
    prompt*: seq[ContentBlock]
    acpAgent*: HarborAcpAgentConfig
  AgentClient* = object
    backend*: AgentBackendKind
    acp*: AcpClient
    harbor*: HarborClient

proc fromAcp*(client: AcpClient): AgentClient =
  AgentClient(backend: abkAcp, acp: client)

proc fromHarbor*(client: HarborClient): AgentClient =
  AgentClient(backend: abkHarbor, harbor: client)

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

proc toHarborContentBlocks*(items: openArray[ContentBlock]): seq[HarborContentBlock] =
  for item in items:
    result.add item.toHarborContentBlock()

proc defaultWorkspaceContext*(cwd = ""): AgentWorkspaceContext =
  AgentWorkspaceContext(repoMode: "none", cwd: cwd)

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
  result = defaultAgent("acp", config.model)
  result.agent.version = if config.version.len > 0: config.version else: "latest"
  result.displayName = config.displayName
  result.settings = if config.settings == nil: newJObject() else: config.settings
  if config.binary.len > 0:
    result.acpStdioLaunchCommand = AcpStdioLaunchCommand(
      binary: config.binary,
      args: config.args)

proc buildHarborTaskRequest*(config: HarborTaskConfig): CreateTaskRequest =
  let repoMode =
    if config.workspace.repoMode.len > 0: config.workspace.repoMode
    elif config.workspace.repoUrl.len > 0: "git"
    else: "none"
  result = CreateTaskRequest(
    tenantId: config.workspace.tenantId,
    projectId: config.workspace.projectId,
    prompt: config.prompt.toHarborContentBlocks(),
    repo: RepoConfig(
      mode: repoMode,
      url: config.workspace.repoUrl,
      branch: config.workspace.branch,
      commit: config.workspace.commit),
    runtime: defaultRuntime(),
    workspace: defaultWorkspace(),
    sandbox: defaultSandbox(),
    delivery: defaultDelivery(),
    agents: @[harborAgentConfig(config.acpAgent)],
    output: defaultOutput(),
    labels: newJObject())
  result.workspace.executionHostId = config.workspace.executionHostId
  result.workspace.workingCopyMode = config.workspace.workingCopyMode
  if config.workspace.cwd.len > 0:
    result.labels["cwd"] = %config.workspace.cwd

proc stopReasonFromStatus(status: string): StopReason =
  case status
  of "cancelled": srCancelled
  of "failed", "error": srError
  else: srEndTurn

proc connectionEvent*(state: AgentConnectionState; sessionId = "";
    text = ""): AgentEvent =
  AgentEvent(sessionId: sessionId, kind: aekConnection, state: state, text: text)

proc stateFromStatus(status: string): AgentConnectionState =
  case status
  of "connecting": acsConnecting
  of "authenticating": acsAuthenticating
  of "connected": acsConnected
  of "streaming", "ready", "running", "provisioning": acsStreaming
  of "retrying": acsRetrying
  of "cancelling": acsCancelling
  of "cancelled": acsCancelled
  of "completed": acsCompleted
  of "failed", "error": acsError
  else: acsStreaming

proc lineFromRaw(raw: JsonNode): int =
  raw{"line"}.getInt(raw{"line_start"}.getInt(raw{"start_line"}.getInt(0)))

proc harborEventToAgentEvent*(sessionId: string; event: HarborEvent): AgentEvent =
  result.sessionId = sessionId
  result.status = event.status
  result.raw = event.raw
  case event.kind
  of hekThought:
    result.kind = aekThoughtChunk
    result.text = event.message
  of hekLog:
    result.kind = aekMessageChunk
    result.text = event.message
  of hekToolUse:
    result.kind = aekToolCall
    result.toolCallId = event.toolExecutionId
    result.toolName = event.toolName
    result.status = if event.status.len > 0: event.status else: "started"
  of hekToolResult:
    result.kind = aekToolCallUpdate
    result.toolCallId = event.toolExecutionId
    result.toolName = event.toolName
    result.status = if event.status.len > 0: event.status else: "completed"
    result.text = event.raw{"tool_output"}.getStr(event.message)
  of hekFileEdit:
    result.kind = aekFileEdit
    result.filePath = event.filePath
    result.line = event.raw.lineFromRaw()
    result.linesAdded = event.linesAdded
    result.linesRemoved = event.linesRemoved
    result.status = if event.status.len > 0: event.status else: "applied"
    result.text = event.message
  of hekDiff:
    result.kind = aekDiff
    result.filePath = event.filePath
    result.line = event.raw.lineFromRaw()
    result.linesAdded = event.linesAdded
    result.linesRemoved = event.linesRemoved
    result.diff = event.raw{"diff"}.getStr(event.raw{"patch"}.getStr(""))
    result.text = event.message
  of hekDelivery:
    result.kind = aekDelivery
    result.status = event.deliveryMode
    result.text = event.deliveryUrl
  of hekLlmRequest:
    result.kind = aekLlmRequest
    result.status = event.status
    result.text = event.message
  of hekSubAgent:
    result.kind = aekSubAgent
    result.status = event.status
    result.text = event.message
  of hekWorkspace, hekStatus:
    case event.status
    of "connecting", "authenticating", "connected", "streaming", "ready",
        "running", "provisioning", "retrying", "cancelling":
      result.kind = aekConnection
      result.state = stateFromStatus(event.status)
    of "cancelled":
      result.kind = aekCancelled
      result.state = acsCancelled
      result.stopReason = srCancelled
    of "completed":
      result.kind = aekCompleted
      result.state = acsCompleted
      result.stopReason = srEndTurn
    of "failed", "error":
      result.kind = aekError
      result.state = acsError
      result.stopReason = srError
    else:
      result.kind = aekStatus
      result.state = acsStreaming
    result.text = event.message
  else:
    let rawType = event.raw{"type"}.getStr("")
    if rawType == "plan":
      result.kind = aekPlan
      for entry in event.raw{"entries"}.items:
        result.planEntries.add entry{"content"}.getStr(entry.getStr(""))
    elif rawType == "review" or rawType == "diagnostic":
      result.kind = aekReview
      result.filePath = event.filePath
      result.line = event.raw.lineFromRaw()
      result.reviewSeverity = event.raw{"severity"}.getStr("warning")
      result.reviewCategory = event.raw{"category"}.getStr("")
      result.text = event.message
    else:
      result.kind = aekStatus
      result.text = event.message
  if result.kind in {aekCancelled, aekCompleted, aekError}:
    result.stopReason = stopReasonFromStatus(event.status)

proc harborEventsToAgentEvents*(sessionId: string;
    events: openArray[HarborEvent]): seq[AgentEvent] =
  for event in events:
    result.add harborEventToAgentEvent(sessionId, event)

proc readAgentEvents*(client: var AgentClient; session: AgentSession): seq[AgentEvent] =
  case client.backend
  of abkAcp:
    for update in client.acp.drainUpdates():
      var event = AgentEvent(sessionId: session.id, raw: update.raw)
      case update.kind
      of sukAgentMessageChunk:
        event.kind = aekMessageChunk
        event.text = update.content.text
      of sukAgentThoughtChunk:
        event.kind = aekThoughtChunk
        event.text = update.content.text
      of sukToolCall:
        event.kind = aekToolCall
        event.toolCallId = update.toolCallId
        event.toolName = update.title
      of sukToolCallUpdate:
        event.kind = aekToolCallUpdate
        event.toolCallId = update.toolCallId
        event.status = update.status
        event.text = update.rawOutput
      of sukStatus:
        event.kind = aekStatus
        event.status = update.status
      else:
        event.kind = aekStatus
      result.add event
  of abkHarbor:
    result = harborEventsToAgentEvents(session.id,
      client.harbor.readSessionEvents(session.id))

proc startSession*(client: var AgentClient; cwd: string;
    prompt: seq[ContentBlock] = @[]): AgentSession =
  case client.backend
  of abkAcp:
    let session = client.acp.startSession(NewSessionRequest(cwd: cwd))
    AgentSession(id: session.sessionId, backend: abkAcp)
  of abkHarbor:
    let response = client.harbor.createTask(buildHarborTaskRequest(HarborTaskConfig(
      workspace: defaultWorkspaceContext(cwd),
      prompt: prompt,
      acpAgent: acpAgentConfig(""))))
    let id = if response.sessionIds.len > 0: response.sessionIds[0] else: response.taskId
    AgentSession(id: id, backend: abkHarbor)

proc sendPrompt*(client: var AgentClient; session: AgentSession;
    prompt: seq[ContentBlock]): PromptTurn =
  case client.backend
  of abkAcp:
    let response = client.acp.sendPrompt(PromptRequest(sessionId: session.id, prompt: prompt))
    PromptTurn(session: session, stopReason: response.stopReason, updates: client.acp.drainUpdates())
  of abkHarbor:
    discard client.harbor.sendPrompt(session.id, prompt.toHarborContentBlocks())
    PromptTurn(session: session, stopReason: srEndTurn, updates: @[])
