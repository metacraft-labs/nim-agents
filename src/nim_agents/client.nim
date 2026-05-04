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

proc startSession*(client: var AgentClient; cwd: string;
    prompt: seq[ContentBlock] = @[]): AgentSession =
  case client.backend
  of abkAcp:
    let session = client.acp.startSession(NewSessionRequest(cwd: cwd))
    AgentSession(id: session.sessionId, backend: abkAcp)
  of abkHarbor:
    let response = client.harbor.createTask(CreateTaskRequest(
      prompt: prompt.toHarborContentBlocks(),
      repo: RepoConfig(mode: "none"),
      runtime: defaultRuntime(),
      agents: @[defaultAgent("acp", "default")],
      output: defaultOutput(),
      labels: newJObject()))
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
