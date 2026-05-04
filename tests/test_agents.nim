import unittest
import std/json
import std/strutils
import nim_everywhere
import nim_agents

proc harborSseTransport(): HttpTransport =
  proc(req: HttpRequest): HttpResponse =
    if req.httpMethod == hmPost and req.url.endsWith("/api/v1/tasks"):
      return HttpResponse(status: 201, body: $(%*{
        "task_id": "task-1",
        "session_ids": ["session-typed"],
        "status": "queued"
      }))
    if req.httpMethod == hmGet and req.url.contains("/api/v1/sessions/session-typed/events"):
      return HttpResponse(status: 200, body:
        "event: message\n" &
        "data: {\"type\":\"status\",\"status\":\"retrying\",\"message\":\"retrying stream\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"file_edit\",\"file_path\":\"src/app.nim\",\"line\":12,\"lines_added\":3,\"lines_removed\":1,\"message\":\"patched source\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"diff\",\"file_path\":\"src/app.nim\",\"line_start\":12,\"lines_added\":3,\"lines_removed\":1,\"diff\":\"@@ -12 +12 @@\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"review\",\"file_path\":\"src/app.nim\",\"line\":12,\"severity\":\"warning\",\"category\":\"accessibility\",\"message\":\"Missing alt text\",\"status\":\"fixable\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"status\",\"status\":\"cancelling\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"status\",\"status\":\"cancelled\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"status\",\"status\":\"error\",\"message\":\"stream failed\"}\n\n")
    HttpResponse(status: 404, body: "not found")

suite "nim-agents":
  test "nim_agents_composes_acp_and_harbor_without_hiding_protocols":
    let fakeAcp = newFakeAcpTransport("composed response")
    var acpClient = newAcpClient(fakeAcp)
    var agents = fromAcp(acpClient)
    let session = agents.startSession("/tmp/project")
    let turn = agents.sendPrompt(session, @[textBlock("hello")])
    check turn.stopReason == srEndTurn
    check turn.updates.len == 5
    check turn.updates[0].kind == sukAgentThoughtChunk
    check turn.updates[1].kind == sukToolCall
    check turn.updates[2].kind == sukToolCallUpdate
    check turn.updates[3].content.text == "composed response"
    check turn.updates[4].kind == sukStatus

    let harbor = newHarborClient("http://localhost:18080", fakeHarborTransport())
    var harborAgents = fromHarbor(harbor)
    let harborSession = harborAgents.startSession("/tmp/project", @[textBlock("start")])
    check harborSession.id == "session-1"
    check toHarborContentBlock(resourceBlock("file:///tmp/repo")).kind == hcbResource

    var rawAcp = agents.acp
    discard rawAcp.startSession(NewSessionRequest(cwd: "/tmp/advanced"))
    check harborAgents.harbor.baseUrl == "http://localhost:18080"

  test "agent_client_harbor_task_request_supports_acp_agent":
    let req = buildHarborTaskRequest(HarborTaskConfig(
      workspace: AgentWorkspaceContext(
        tenantId: "tenant-a",
        projectId: "project-a",
        cwd: "/work/repo",
        repoMode: "git",
        repoUrl: "git@example.com:repo.git",
        branch: "feature/m22"),
      prompt: @[textBlock("wire Harbor")],
      acpAgent: acpAgentConfig(
        "mock-agent",
        @["--scenario", "m22.yaml"],
        model = "mock-agent",
        displayName = "Scenario ACP",
        settings = %*{"temperature": 0})))

    let node = taskToJson(req)
    check node["projectId"].getStr() == "project-a"
    check node["repo"]["mode"].getStr() == "git"
    check node["labels"]["cwd"].getStr() == "/work/repo"
    check node["prompt"][0]["type"].getStr() == "text"
    check node["agents"][0]["agent"]["software"].getStr() == "acp"
    check node["agents"][0]["model"].getStr() == "mock-agent"
    check node["agents"][0]["displayName"].getStr() == "Scenario ACP"
    check node["agents"][0]["settings"]["temperature"].getInt() == 0
    check node["agents"][0]["acpStdioLaunchCommand"]["binary"].getStr() == "mock-agent"
    check node["agents"][0]["acpStdioLaunchCommand"]["args"][0].getStr() == "--scenario"

  test "agent_client_harbor_sse_translates_typed_shared_events":
    var agents = fromHarbor(newHarborClient("http://localhost:18080", harborSseTransport()))
    let session = agents.startSession("/tmp/project", @[textBlock("start")])
    let events = agents.readAgentEvents(session)

    check events[0].kind == aekConnection
    check events[0].state == acsRetrying
    check events[1].kind == aekFileEdit
    check events[1].filePath == "src/app.nim"
    check events[1].line == 12
    check events[1].linesAdded == 3
    check events[2].kind == aekDiff
    check events[2].diff == "@@ -12 +12 @@"
    check events[3].kind == aekReview
    check events[3].reviewSeverity == "warning"
    check events[3].reviewCategory == "accessibility"
    check events[4].kind == aekConnection
    check events[4].state == acsCancelling
    check events[5].kind == aekCancelled
    check events[6].kind == aekError
