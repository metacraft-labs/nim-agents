import unittest
import nim_agents

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
