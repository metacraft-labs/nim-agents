import std/json
import std/strutils
import std/uri
import nim_acp
import nim_agent_harbor
import nim_everywhere

type
  AgentBackendKind* = enum
    abkAcp
    abkHarbor
  AgentSession* = object
    id*: string
    taskId*: string
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
  WorkspaceIsolation* = enum
    wiNone = "none"
    wiGitWorktree = "git_worktree"
  AgentEventKind* = enum
    aekConnection = "connection"
    aekMessageChunk = "message_chunk"
    aekThoughtChunk = "thought_chunk"
    aekPlan = "plan"
    aekToolCall = "tool_call"
    aekToolCallUpdate = "tool_call_update"
    aekFileEdit = "file_edit"
    aekDiff = "diff"
    aekMilestoneProgress = "milestone_progress"
    aekWorkspaceReady = "workspace_ready"
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
    milestoneCompleted*: int
    milestoneTotal*: int
    workspacePath*: string
    workingCopyMode*: string
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
    labels*: JsonNode
  AgentStartMode* = object
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

proc toHarborContentBlocks*(items: openArray[ContentBlock]): seq[
    HarborContentBlock] =
  for item in items:
    result.add item.toHarborContentBlock()

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
  result = defaultAgent("acp", config.model)
  result.agent.version = if config.version.len >
      0: config.version else: "latest"
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
    labels: if config.labels == nil: newJObject() else: config.labels)
  result.workspace.executionHostId = config.workspace.executionHostId
  result.workspace.workingCopyMode = config.workspace.workingCopyMode
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

proc jsonArrayStrings(node: JsonNode; field: string): seq[string] =
  for entry in node{field}.items:
    result.add entry{"content"}.getStr(entry.getStr(""))

proc progressFromRaw(raw: JsonNode): tuple[done: int; total: int] =
  result.done = raw{"completed"}.getInt(raw{"completedMilestones"}.getInt(
    raw{"done"}.getInt(0)))
  result.total = raw{"total"}.getInt(raw{"totalMilestones"}.getInt(0))

proc harborEventToAgentEvent*(sessionId: string;
    event: HarborEvent): AgentEvent =
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
      if event.status == "ready" and event.kind == hekWorkspace:
        result.kind = aekWorkspaceReady
        result.state = acsConnected
        result.workspacePath = event.mountPath
        result.workingCopyMode = event.workingCopyMode
      else:
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
      result.planEntries = jsonArrayStrings(event.raw, "entries")
    elif rawType == "milestone" or rawType == "milestone_progress":
      let progress = progressFromRaw(event.raw)
      result.kind = aekMilestoneProgress
      result.milestoneCompleted = progress.done
      result.milestoneTotal = progress.total
      result.text = event.message
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

proc acpUpdateToAgentEvent*(sessionId: string;
    update: SessionUpdate): AgentEvent =
  result = AgentEvent(sessionId: sessionId, raw: update.raw)
  case update.kind
  of sukAgentMessageChunk:
    result.kind = aekMessageChunk
    result.text = update.content.text
  of sukAgentThoughtChunk:
    result.kind = aekThoughtChunk
    result.text = update.content.text
  of sukToolCall:
    result.kind = aekToolCall
    result.toolCallId = update.toolCallId
    result.toolName = update.title
  of sukToolCallUpdate:
    result.kind = aekToolCallUpdate
    result.toolCallId = update.toolCallId
    result.status = update.status
    result.text = update.rawOutput
  of sukStatus:
    case update.status
    of "completed":
      result.kind = aekCompleted
      result.state = acsCompleted
      result.stopReason = srEndTurn
    of "cancelled":
      result.kind = aekCancelled
      result.state = acsCancelled
      result.stopReason = srCancelled
    of "error", "failed":
      result.kind = aekError
      result.state = acsError
      result.stopReason = srError
    else:
      result.kind = aekStatus
    result.status = update.status
  else:
    let rawUpdate = update.raw{"update"}
    case rawUpdate{"sessionUpdate"}.getStr("")
    of "plan":
      result.kind = aekPlan
      result.planEntries = jsonArrayStrings(rawUpdate, "entries")
    of "file_edit":
      result.kind = aekFileEdit
      result.filePath = rawUpdate{"file_path"}.getStr(rawUpdate{"path"}.getStr(""))
      result.line = rawUpdate.lineFromRaw()
      result.linesAdded = rawUpdate{"lines_added"}.getInt(0)
      result.linesRemoved = rawUpdate{"lines_removed"}.getInt(0)
    of "diff":
      result.kind = aekDiff
      result.filePath = rawUpdate{"file_path"}.getStr(rawUpdate{"path"}.getStr(""))
      result.line = rawUpdate.lineFromRaw()
      result.linesAdded = rawUpdate{"lines_added"}.getInt(0)
      result.linesRemoved = rawUpdate{"lines_removed"}.getInt(0)
      result.diff = rawUpdate{"diff"}.getStr(rawUpdate{"patch"}.getStr(""))
    of "milestone", "milestone_progress":
      let progress = progressFromRaw(rawUpdate)
      result.kind = aekMilestoneProgress
      result.milestoneCompleted = progress.done
      result.milestoneTotal = progress.total
    of "workspace":
      result.kind = aekWorkspaceReady
      result.state = acsConnected
      result.workspacePath = rawUpdate{"mountPath"}.getStr(rawUpdate{
          "workspacePath"}.getStr(""))
      result.workingCopyMode = rawUpdate{"workingCopyMode"}.getStr("")
    else:
      result.kind = aekStatus

proc acpUpdatesToAgentEvents*(sessionId: string;
    updates: openArray[SessionUpdate]): seq[AgentEvent] =
  for update in updates:
    result.add acpUpdateToAgentEvent(sessionId, update)

proc readAgentEvents*(client: var AgentClient; session: AgentSession): seq[AgentEvent] =
  case client.backend
  of abkAcp:
    for update in client.acp.drainUpdates():
      result.add acpUpdateToAgentEvent(session.id, update)
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
    let id = if response.sessionIds.len > 0: response.sessionIds[
        0] else: response.taskId
    AgentSession(id: id, taskId: response.taskId, backend: abkHarbor)

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
      prompt: config.prompt,
      acpAgent: config.acpAgent,
      labels: config.labels)))
    let id = if response.sessionIds.len > 0: response.sessionIds[
        0] else: response.taskId
    AgentSession(id: id, taskId: response.taskId, backend: abkHarbor)

proc sendPrompt*(client: var AgentClient; session: AgentSession;
    prompt: seq[ContentBlock]): PromptTurn =
  case client.backend
  of abkAcp:
    let response = client.acp.sendPrompt(PromptRequest(sessionId: session.id,
        prompt: prompt))
    PromptTurn(session: session, stopReason: response.stopReason,
        updates: client.acp.drainUpdates())
  of abkHarbor:
    discard client.harbor.sendPrompt(session.id, prompt.toHarborContentBlocks())
    PromptTurn(session: session, stopReason: srEndTurn, updates: @[])

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
  let node = parseJson(client.harborGet("/api/v1/sessions/" & session.id &
    "/files" & suffix).body)
  result.raw = node
  for item in node{"items"}.items:
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
  let node = parseJson(client.harborGet("/api/v1/sessions/" & session.id & "/info").body)
  result = AgentSessionInfo(
    id: node{"id"}.getStr(session.id),
    status: node{"status"}.getStr(""),
    eventsUrl: node{"endpoints"}{"events"}.getStr(""),
    leader: node{"fleet"}{"leader"}.getStr(""),
    workspacePath: node{"workspacePath"}.getStr(node{"workspace"}{
        "path"}.getStr("")),
    raw: node)

proc milestoneProgress*(client: AgentClient;
    session: AgentSession): AgentMilestoneProgress =
  let taskId = if session.taskId.len > 0: session.taskId else: session.id
  let node = parseJson(client.harborGet("/api/v1/tasks/" & taskId &
      "/milestones").body)
  result = AgentMilestoneProgress(
    taskId: node{"taskId"}.getStr(node{"task_id"}.getStr(taskId)),
    pendingFeedbackCount: node{"pendingFeedback"}.len,
    raw: node)
  for item in node{"files"}.items:
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

proc eventHistory*(client: AgentClient; session: AgentSession;
    limit = 0; before: int64 = 0): seq[AgentEvent] =
  client.requireHarbor()
  result = harborEventsToAgentEvents(session.id, client.harbor.readEventHistory(
    session.id, EventHistoryQuery(limit: limit, before: before)).events)
