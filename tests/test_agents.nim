## Fake ACP/HTTP peers here isolate common-library dispatch and wire contracts.
## Real Harbor/provider process continuity is covered separately by integration tests.
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
  test "typed Harbor user input preserves raw content without becoming assistant output":
    let raw = %* {"type": "user_input", "content": "user: exact prompt",
      "input_type": "text", "user_name": "user", "timestamp": 123}
    let mapped = harborEventToAgentEvent("session", eventFromJson(raw))
    check mapped.kind == aekStatus
    check mapped.status == ""
    check mapped.raw{"type"}.getStr() == "user_input"
    check mapped.text == "user: exact prompt"
    check mapped.raw == raw
    check mapped.sessionId == "session"

  test "assistant logs keep user prefixes and exact submitted text":
    # Text cannot establish authorship: an assistant may quote the user's
    # entire input, including the legacy Harbor log prefix, verbatim.
    for text in ["user: exact prompt", "exact prompt", "user: legitimate assistant explanation"]:
      let raw = %* {"type": "log", "message": text, "level": "info", "timestamp": 124}
      let mapped = harborEventToAgentEvent("session", eventFromJson(raw))
      check mapped.kind == aekMessageChunk
      check mapped.text == text
      check mapped.raw == raw

  test "persistent idle ends only the turn and process completion is an error":
    for status in ["paused", "completed"]:
      let transport: HttpTransport = proc(req: HttpRequest): HttpResponse =
        HttpResponse(status: 201, body: $(%* {"session_id": "persistent", "status": "queued"}))
      var harbor = newHarborClient("http://harbor.invalid", transport)
      let wireStatus = status
      harbor.streamTransport = proc(req: HttpRequest; callback: HarborStreamCallback) =
        check callback(eventFromJson(%* {"type": "status", "status": "paused"}), "1")
        check callback(eventFromJson(%* {"type": "status", "status": "running"}), "2")
        let keepReading = callback(eventFromJson(%* {"type": "status", "status": wireStatus}), "3")
        check not keepReading
      var client = fromHarbor(harbor)
      let session = client.createSession(AgentStartMode(workspace: defaultWorkspaceContext("/repo"),
        prompt: @[textBlock("hello")], acpAgent: acpAgentConfig("provider")))
      let turn = client.streamAgentTurn(session, nil)
      if status == "paused":
        check turn.stopReason == srEndTurn
        check session.runtime.lifecycle == aslReady
        check session.runtime.turn == atsCompleted
      else:
        check turn.stopReason == srError
        check session.runtime.lifecycle == aslFailed
        check session.runtime.turn == atsFailed

  test "persistent nonstream waits and completion cannot revive a closed session":
    for terminal in ["paused", "failed"]:
      var deliveries = 0
      var nestedRejected = false
      var client: AgentClient
      var session: AgentSession
      var competing = false
      let transport: HttpTransport = proc(req: HttpRequest): HttpResponse =
        if req.url.endsWith("/api/v1/sessions"):
          return HttpResponse(status: 201, body: "{\"session_id\":\"live\"}")
        if req.url.contains("/events/history"):
          if competing:
            expect HarborError:
              discard client.sendPrompt(session, @[textBlock("concurrent")])
            nestedRejected = true
          return HttpResponse(status: 200, body: "{\"events\":[],\"total_count\":0}")
        if req.url.endsWith("/prompt"):
          inc deliveries
          return HttpResponse(status: 200, body: "{\"accepted\":true}")
        HttpResponse(status: 200, body: "{}")
      var harbor = newHarborClient("http://harbor.invalid", transport)
      var streamCount = 0
      let finalStatus = terminal
      harbor.streamTransport = proc(req: HttpRequest; callback: HarborStreamCallback) =
        inc streamCount
        discard callback(eventFromJson(%* {"type": "status", "status": "running"}), "1")
        if competing:
          client.closeSession(session)
        discard callback(eventFromJson(%* {"type": "status",
          "status": (if competing: finalStatus else: "paused")}), "2")
      client = fromHarbor(harbor)
      session = client.createSession(AgentStartMode(workspace: defaultWorkspaceContext("/repo"),
        prompt: @[textBlock("first")], acpAgent: acpAgentConfig("provider")))
      discard client.streamAgentTurn(session, nil)
      competing = true
      let turn = client.sendPrompt(session, @[textBlock("second")])
      check turn.stopReason == (if terminal == "paused": srEndTurn else: srError)
      check streamCount == 2
      check deliveries == 1
      check nestedRejected
      check session.runtime.lifecycle == aslClosed
      check session.runtime.turn == atsIdle
      expect HarborError:
        discard client.sendPrompt(session, @[textBlock("after close")])
      check deliveries == 1

  test "followup preserves textual resource context and rejects unsupported media":
    var bodies: seq[JsonNode]
    let transport: HttpTransport = proc(req: HttpRequest): HttpResponse =
      bodies.add parseJson(req.body)
      HttpResponse(status: 202, body: $(%* {"sessionId": "live", "accepted": true}))
    var client = fromHarbor(newHarborClient("http://harbor.invalid", transport))
    let prompt = @[textBlock("follow up"), ContentBlock(kind: cbResource,
      uri: "file:///work/Button.nim#L9", mimeType: "text/plain", data: "button source")]
    discard client.sendPrompt(AgentSession(id: "live", backend: abkHarbor), prompt)
    check bodies.len == 1
    check bodies[0]["prompt"].getStr() == harborPromptText(prompt)
    check bodies[0]["prompt"].getStr().contains("file:///work/Button.nim#L9")
    check bodies[0]["prompt"].getStr().contains("button source")
    expect HarborError:
      discard client.sendPrompt(AgentSession(id: "live", backend: abkHarbor),
        @[ContentBlock(kind: cbImage, data: "encoded")])
    check bodies.len == 1

  test "persistent session uses creation API and cancellation never stops process":
    var requests: seq[HttpRequest]
    let transport: HttpTransport = proc(req: HttpRequest): HttpResponse =
      requests.add req
      if req.url.endsWith("/api/v1/sessions"):
        return HttpResponse(status: 201, body: $(%*{"session_id": "persistent", "status": "queued"}))
      HttpResponse(status: 200, body: "{}")
    var client = fromHarbor(newHarborClient("http://harbor.invalid", transport))
    var workspace = defaultWorkspaceContext("/repo")
    workspace.workingCopyMode = "in_place"
    let session = client.createSession(AgentStartMode(workspace: workspace,
      prompt: @[textBlock("user text")], acpAgent: acpAgentConfig("provider-acp")))
    check session.id == "persistent"
    check session.taskId.len == 0
    check session.capabilities.persistent
    check not session.capabilities.cancelTurn
    check session.capabilities.closeSession
    check session.runtime.lifecycle == aslReady
    check session.runtime.turn == atsWorking
    check requests.len == 1
    check requests[0].url.endsWith("/api/v1/sessions")
    let body = parseJson(requests[0].body)
    check body["output"]["nonInteractive"].getBool() == false
    check body["prompt"].getStr() == "user text"
    expect HarborError:
      client.cancelTurn(session)
    check requests.len == 1
    client.closeSession(session)
    check session.runtime.lifecycle == aslClosed
    check requests.len == 2
    check requests[1].url.endsWith("/sessions/persistent/stop")

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

  test "harbor_rest_prompt_preserves_resource_reference_and_text":
    let request = buildHarborTaskRequest(HarborTaskConfig(
      prompt: @[textBlock("Update the selected component"),
        ContentBlock(kind: cbResource, uri: "file:///work/Button.nim#L42",
          mimeType: "text/plain", data: "button source")]))
    let prompt = taskToJson(request)["prompt"].getStr()
    check prompt.contains("Update the selected component")
    check prompt.contains("file:///work/Button.nim#L42")
    check prompt.contains("text/plain")
    check prompt.contains("button source")

  test "harbor_rest_prompt_rejects_unsupported_media":
    expect HarborError:
      discard buildHarborTaskRequest(HarborTaskConfig(
        prompt: @[ContentBlock(kind: cbImage, mimeType: "image/png", data: "binary")]))
    expect HarborError:
      discard buildHarborTaskRequest(HarborTaskConfig(
        prompt: @[ContentBlock(kind: cbResource, uri: "file:///work/binary",
          mimeType: "application/octet-stream", data: "binary")]))

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
    check node["prompt"].getStr() == "wire Harbor"
    check node["agents"][0]["type"].getStr() == "acp"
    check node["agents"][0]["settings"]["model"].getStr() == "mock-agent"
    check node["agents"][0]["display_name"].getStr() == "Scenario ACP"
    check node["agents"][0]["settings"]["temperature"].getInt() == 0
    check node["agents"][0]["acpStdioLaunchCommand"]["binary"].getStr() == "mock-agent"
    check node["agents"][0]["acpStdioLaunchCommand"]["args"][0].getStr() == "--scenario"
    check node["sandbox"]["mode"].getStr() == "dynamic"
    check node["sandbox"]["debug"].getBool()
    check not node["sandbox"].hasKey("tmpfs-size")

  test "agent_client_harbor_sse_translates_typed_shared_events":
    var agents = fromHarbor(newHarborClient("http://localhost:18080",
        harborSseTransport()))
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

  test "test_nim_agents_codetracer_harbor_worktree_request_shape":
    var requests: seq[HttpRequest] = @[]
    proc transport(req: HttpRequest): HttpResponse =
      requests.add req
      if req.httpMethod == hmPost and req.url.endsWith("/api/v1/tasks"):
        return HttpResponse(status: 201, body: $(%*{
          "task_id": "task-worktree",
          "session_ids": ["session-worktree"],
          "status": "queued"
        }))
      HttpResponse(status: 404, body: "not found")

    var agents = fromHarbor(newHarborClient("http://harbor.invalid", transport))
    let prompt = taskPrompt(
      "Implement the CodeTracer tab workflow.",
      @["Workspace must stay isolated."],
      evidenceCommand = "ct agent-session record --session session-worktree")
    let session = agents.startSession(AgentStartMode(
      workspace: gitWorktreeWorkspace(
        "/repo",
        tenantId = "tenant-ct",
        projectId = "project-ct",
        repoUrl = "git@example.invalid/repo.git",
        branch = "feature/agentic"),
      prompt: prompt,
      acpAgent: acpAgentConfig(
        "codex",
        @["--acp"],
        model = "gpt-test",
        version = "2026-06",
        displayName = "Codex ACP",
        settings = %*{"effort": "medium"}),
      labels: %*{"consumer": "codetracer", "trace": "deepreview"}))

    check session.id == "session-worktree"
    check session.taskId == "task-worktree"
    check requests.len == 1
    check requests[0].httpMethod == hmPost
    check requests[0].url == "http://harbor.invalid/api/v1/tasks"
    let body = parseJson(requests[0].body)
    check body["tenantId"].getStr() == "tenant-ct"
    check body["projectId"].getStr() == "project-ct"
    check body["workspace_path"].getStr() == "/repo"
    check body["working_copy_mode"].getStr() == "git_worktree"
    check body["repo"]["mode"].getStr() == "git"
    check body["repo"]["branch"].getStr() == "feature/agentic"
    check body["labels"]["cwd"].getStr() == "/repo"
    check body["labels"]["consumer"].getStr() == "codetracer"
    check body["labels"]["trace"].getStr() == "deepreview"
    check body["prompt"].getStr().contains(
      "Implement the CodeTracer tab workflow.")
    check body["prompt"].getStr().contains("Workspace must stay isolated.")
    check body["prompt"].getStr().contains("ct agent-session record")
    check body["agents"][0]["type"].getStr() == "acp"
    check body["agents"][0]["version"].getStr() == "2026-06"
    check body["agents"][0]["settings"]["model"].getStr() == "gpt-test"
    check body["agents"][0]["display_name"].getStr() == "Codex ACP"
    check body["agents"][0]["settings"]["effort"].getStr() == "medium"
    check body["agents"][0]["acpStdioLaunchCommand"]["binary"].getStr() == "codex"
    check body["agents"][0]["acpStdioLaunchCommand"]["args"][0].getStr() == "--acp"
    check body["sandbox"]["mode"].getStr() == "dynamic"
    check body["sandbox"]["debug"].getBool()
    check not body["sandbox"].hasKey("tmpfs-size")

  test "test_nim_agents_codetracer_event_normalization_matrix":
    let acpTurn = promptTurn(@[
      %*{"sessionUpdate": "plan", "entries": [
        {"content": "Inspect"}, {"content": "Patch"}]},
      toolCall("tool-1", "bash", """{"cmd":"nim test"}"""),
      %*{"sessionUpdate": "file_edit", "file_path": "src/app.nim",
        "line": 7, "lines_added": 2, "lines_removed": 1},
      %*{"sessionUpdate": "diff", "file_path": "src/app.nim",
        "line_start": 7, "lines_added": 2, "lines_removed": 1,
        "diff": "@@ -7 +7 @@"},
      %*{"sessionUpdate": "milestone_progress", "completed": 2, "total": 5},
      %*{"sessionUpdate": "workspace", "workspacePath": "/tmp/acp-worktree",
        "workingCopyMode": "git_worktree"},
      statusUpdate("completed"),
      statusUpdate("cancelled"),
      statusUpdate("error")
    ])
    var acpAgents = fromAcp(newAcpClient(newFakeAcpTransport(@[acpTurn])))
    let acpSession = acpAgents.startSession("/repo")
    let acpTurnResult = acpAgents.sendPrompt(acpSession, @[textBlock("go")])
    let acpEvents = acpUpdatesToAgentEvents(acpSession.id,
        acpTurnResult.updates)

    proc harborMatrixTransport(req: HttpRequest): HttpResponse =
      if req.httpMethod == hmPost and req.url.endsWith("/api/v1/tasks"):
        return HttpResponse(status: 201, body: $(%*{
          "task_id": "task-events",
          "session_ids": ["session-events"],
          "status": "queued"
        }))
      if req.httpMethod == hmGet and req.url.contains("/api/v1/sessions/session-events/events"):
        return HttpResponse(status: 200, body:
          "event: message\n" &
          "data: {\"type\":\"plan\",\"entries\":[{\"content\":\"Inspect\"},{\"content\":\"Patch\"}]}\n\n" &
          "event: message\n" &
          "data: {\"type\":\"tool_use\",\"tool_name\":\"bash\",\"tool_execution_id\":\"tool-1\",\"status\":\"started\"}\n\n" &
          "event: message\n" &
          "data: {\"type\":\"file_edit\",\"file_path\":\"src/app.nim\",\"line\":7,\"lines_added\":2,\"lines_removed\":1}\n\n" &
          "event: message\n" &
          "data: {\"type\":\"diff\",\"file_path\":\"src/app.nim\",\"line_start\":7,\"lines_added\":2,\"lines_removed\":1,\"diff\":\"@@ -7 +7 @@\"}\n\n" &
          "event: message\n" &
          "data: {\"type\":\"milestone_progress\",\"completed\":2,\"total\":5}\n\n" &
          "event: message\n" &
          "data: {\"type\":\"workspace_ready\",\"workspace_path\":\"/tmp/harbor-worktree\",\"working_copy_mode\":\"git_worktree\"}\n\n" &
          "event: message\n" &
          "data: {\"type\":\"status\",\"status\":\"completed\"}\n\n" &
          "event: message\n" &
          "data: {\"type\":\"status\",\"status\":\"cancelled\"}\n\n" &
          "event: message\n" &
          "data: {\"type\":\"status\",\"status\":\"error\"}\n\n")
      HttpResponse(status: 404, body: "not found")

    var harborAgents = fromHarbor(newHarborClient("http://harbor.invalid",
      harborMatrixTransport))
    let harborSession = harborAgents.startSession("/repo", @[textBlock("go")])
    let harborEvents = harborAgents.readAgentEvents(harborSession)

    check acpEvents.len == harborEvents.len
    for i in 0 ..< acpEvents.len:
      check acpEvents[i].kind == harborEvents[i].kind
    check acpEvents[0].planEntries == harborEvents[0].planEntries
    check acpEvents[1].toolCallId == harborEvents[1].toolCallId
    check acpEvents[1].toolName == harborEvents[1].toolName
    check acpEvents[2].filePath == harborEvents[2].filePath
    check acpEvents[2].linesAdded == harborEvents[2].linesAdded
    check acpEvents[3].diff == harborEvents[3].diff
    check acpEvents[4].milestoneCompleted == harborEvents[4].milestoneCompleted
    check acpEvents[4].milestoneTotal == harborEvents[4].milestoneTotal
    check acpEvents[5].workspacePath == "/tmp/acp-worktree"
    check harborEvents[5].workspacePath == "/tmp/harbor-worktree"
    check acpEvents[5].workingCopyMode == harborEvents[5].workingCopyMode
    check acpEvents[6].stopReason == harborEvents[6].stopReason
    check acpEvents[7].stopReason == harborEvents[7].stopReason
    check acpEvents[7].state == acsCancelled
    check harborEvents[7].state == acsCancelled
    check acpEvents[8].stopReason == harborEvents[8].stopReason

  test "test_nim_agents_codetracer_rest_fetches_changed_files":
    var seen: seq[string] = @[]
    proc restTransport(req: HttpRequest): HttpResponse =
      seen.add req.httpMethod.httpMethodName() & " " & req.url
      if req.httpMethod == hmGet and req.url.endsWith("/api/v1/sessions/session-rest/files?page=1&perPage=50"):
        return HttpResponse(status: 200, body: $(%*{
          "items": [
            {
              "path": "src/app.nim",
              "oldPath": "src/old_app.nim",
              "status": "renamed",
              "linesAdded": 3,
              "linesRemoved": 1,
              "binary": false,
              "sessionId": "session-rest"
            },
            {
              "path": "assets/logo.bin",
              "status": "added",
              "binary": true,
              "sizeBytes": 4,
              "contentType": "application/octet-stream",
              "sessionId": "session-rest"
            }
          ],
          "total": 2,
          "page": 1,
          "perPage": 50
        }))
      if req.httpMethod == hmGet and req.url.endsWith("/api/v1/sessions/session-wrapped/files"):
        return HttpResponse(status: 200, body: $(%(
          "{\"items\":[{\"path\":\"src/wrapped.nim\",\"status\":\"modified\"}],\"total\":1}")))
      if req.httpMethod == hmGet and req.url.endsWith("/api/v1/sessions/session-array/files"):
        return HttpResponse(status: 200, body: $(%*[
          {"path": "src/array.nim", "status": "modified"}
        ]))
      if req.httpMethod == hmGet and req.url.endsWith("/api/v1/sessions/session-rest/files/content/src/app.nim"):
        return HttpResponse(
          status: 200,
          headers: @[header("Content-Type", "text/plain; charset=utf-8"),
            header("Accept-Ranges", "bytes")],
          body: "echo 1\n")
      if req.httpMethod == hmGet and req.url.endsWith("/api/v1/sessions/session-rest/diff/src/app.nim?context=5"):
        return HttpResponse(status: 200, body: $(%*{
          "path": "src/app.nim",
          "oldPath": "src/old_app.nim",
          "status": "renamed",
          "diff": "@@ -1 +1 @@",
          "linesAdded": 3,
          "linesRemoved": 1,
          "binary": false,
          "contextLines": 5,
          "sessionId": "session-rest"
        }))
      if req.httpMethod == hmGet and req.url.endsWith("/api/v1/tasks/task-rest/milestones"):
        return HttpResponse(status: 200, body: $(%*{
          "taskId": "task-rest",
          "files": [{
            "path": "Agentic.milestones.org",
            "title": "Agentic",
            "currentMilestone": "M2",
            "status": "active",
            "milestones": [],
            "summary": {
              "totalMilestones": 8,
              "completedMilestones": 2,
              "progressPercent": 25,
              "currentMilestoneTitle": "nim-agents"
          }
        }],
          "pendingFeedback": []
        }))
      if req.httpMethod == hmGet and req.url.endsWith("/api/v1/tasks/task-wrapped/milestones"):
        return HttpResponse(status: 200, body: $(%($(%*{
          "task_id": "task-wrapped",
          "files": [{
            "path": "Wrapped.milestones.org",
            "summary": {
              "totalMilestones": 1,
              "completedMilestones": 1
            }
          }]
        }))))
      if req.httpMethod == hmGet and req.url.endsWith("/api/v1/tasks/task-empty/milestones"):
        return HttpResponse(status: 200, body: $(%*{
          "task_id": "task-empty",
          "pendingFeedback": nil
        }))
      if req.httpMethod == hmGet and req.url.endsWith("/api/v1/sessions/session-rest/info"):
        return HttpResponse(status: 200, body: $(%*{
          "id": "session-rest",
          "status": "running",
          "fleet": {"leader": "local", "followers": []},
          "endpoints": {"events": "/api/v1/sessions/session-rest/events"},
          "workspacePath": "/tmp/agent-worktree",
          "workingCopyMode": "git_worktree"
        }))
      if req.httpMethod == hmGet and req.url.endsWith("/api/v1/sessions/session-info-wrapped/info"):
        return HttpResponse(status: 200, body: $(%($(%*{
          "id": "session-info-wrapped",
          "status": "running",
          "workspace_path": "/tmp/wrapped-agent-worktree",
          "working_copy_mode": "git_worktree"
        }))))
      if req.httpMethod == hmGet and req.url.endsWith("/api/v1/sessions/session-rest/events/history?limit=10"):
        return HttpResponse(status: 200, body: $(%*{
          "events": [
            {"type": "file_edit", "file_path": "src/app.nim", "lines_added": 3}
          ],
          "has_more": false,
          "oldest_timestamp": 1,
          "total_count": 1
        }))
      HttpResponse(status: 404, body: "not found: " & req.url)

    let client = fromHarbor(newHarborClient("http://harbor.invalid",
        restTransport))
    let session = AgentSession(id: "session-rest", taskId: "task-rest",
        backend: abkHarbor)

    let files = client.changedFiles(session, page = 1, perPage = 50)
    check files.total == 2
    check files.items[0].path == "src/app.nim"
    check files.items[0].oldPath == "src/old_app.nim"
    check files.items[0].linesAdded == 3
    check files.items[0].sizeBytes == 0
    check files.items[1].binary
    check files.items[1].contentType == "application/octet-stream"

    let wrappedFiles = client.changedFiles(AgentSession(id: "session-wrapped",
        taskId: "task-rest", backend: abkHarbor))
    check wrappedFiles.total == 1
    check wrappedFiles.items[0].path == "src/wrapped.nim"

    let arrayFiles = client.changedFiles(AgentSession(id: "session-array",
        taskId: "task-rest", backend: abkHarbor))
    check arrayFiles.total == 1
    check arrayFiles.items[0].path == "src/array.nim"

    let content = client.fileContent(session, "src/app.nim")
    check content.content == "echo 1\n"
    check content.contentType == "text/plain; charset=utf-8"
    check content.acceptRanges == "bytes"

    let diff = client.fileDiff(session, "src/app.nim", context = 5)
    check diff.oldPath == "src/old_app.nim"
    check diff.diff == "@@ -1 +1 @@"
    check diff.contextLines == 5

    let milestones = client.milestoneProgress(session)
    check milestones.taskId == "task-rest"
    check milestones.files[0].currentMilestone == "M2"
    check milestones.files[0].completedMilestones == 2

    let wrappedMilestones = client.milestoneProgress(AgentSession(
        id: "session-wrapped", taskId: "task-wrapped", backend: abkHarbor))
    check wrappedMilestones.taskId == "task-wrapped"
    check wrappedMilestones.files[0].completedMilestones == 1

    let emptyMilestones = client.milestoneProgress(AgentSession(
        id: "session-empty", taskId: "task-empty", backend: abkHarbor))
    check emptyMilestones.taskId == "task-empty"
    check emptyMilestones.pendingFeedbackCount == 0
    check emptyMilestones.files.len == 0

    let info = client.sessionInfo(session)
    check info.id == "session-rest"
    check info.workspacePath == "/tmp/agent-worktree"
    check info.workingCopyMode == "git_worktree"
    check info.eventsUrl.endsWith("/events")

    let wrappedInfo = client.sessionInfo(AgentSession(
        id: "session-info-wrapped", taskId: "task-rest", backend: abkHarbor))
    check wrappedInfo.id == "session-info-wrapped"
    check wrappedInfo.workspacePath == "/tmp/wrapped-agent-worktree"
    check wrappedInfo.workingCopyMode == "git_worktree"

    let history = client.eventHistory(session, limit = 10)
    check history.len == 1
    check history[0].kind == aekFileEdit
    check history[0].filePath == "src/app.nim"
    check seen.contains("GET http://harbor.invalid/api/v1/sessions/session-rest/files?page=1&perPage=50")
    check seen.contains("GET http://harbor.invalid/api/v1/sessions/session-rest/files/content/src/app.nim")
    check seen.contains("GET http://harbor.invalid/api/v1/sessions/session-rest/diff/src/app.nim?context=5")
    check seen.contains("GET http://harbor.invalid/api/v1/tasks/task-rest/milestones")
    check seen.contains("GET http://harbor.invalid/api/v1/sessions/session-rest/info")
    check seen.contains("GET http://harbor.invalid/api/v1/sessions/session-rest/events/history?limit=10")
