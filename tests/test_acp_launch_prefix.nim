## Real process acceptance for the optional ACP launch prefix. The controlled
## Python ACP peer substitutes model decisions only: real executable resolution,
## wrappers, exact argv/env, stdio transport, timeouts and shutdown run unchanged.
## No mocked transport/filesystem/compiler. Claude/Codex factories use explicit
## documented binary overrides to isolate factory semantics from model credentials.
when defined(js): {.error: "ACP launch prefix is a native process boundary".}
import std/[json, os, strutils, tempfiles, unittest]
import nim_agents

suite "ACP optional launch prefix":
  test "all factories retain exact resolved provider args and environment":
    let directory = createTempDir("agents launch prefix ", "")
    defer: removeDir(directory)
    let peer = directory / "provider with spaces.py"
    writeFile(peer, """
import json,os,sys
for line in sys.stdin:
 r=json.loads(line)
 if r.get('method')=='initialize': result={'protocolVersion':1,'agentCapabilities':{'text':True}}
 elif r.get('method')=='session/new': result={'sessionId':json.dumps({'args':sys.argv[1:],'prefix':os.environ.get('PREFIX_MARKER'),'ordinary':os.environ.get('ORDINARY_SETTING'),'executable':sys.executable})}
 else: result={}
 if 'id' in r: print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}),flush=True)
""")
    let wrapper = directory / "wrapper with spaces.py"
    writeFile(wrapper, """
import os,sys
os.environ['PREFIX_MARKER']=sys.argv[1]
os.execv(sys.argv[2],sys.argv[2:])
""")
    let python = findExe("python3")
    check python.len > 0
    let oldClaude = getEnv("ISONIM_ACP_AGENT_CMD")
    let oldCodex = getEnv("ISONIM_CODEX_ACP_CMD")
    let oldOrdinary = getEnv("ORDINARY_SETTING")
    defer:
      if oldClaude.len > 0: putEnv("ISONIM_ACP_AGENT_CMD", oldClaude)
      else: delEnv("ISONIM_ACP_AGENT_CMD")
      if oldCodex.len > 0: putEnv("ISONIM_CODEX_ACP_CMD", oldCodex)
      else: delEnv("ISONIM_CODEX_ACP_CMD")
      if oldOrdinary.len > 0: putEnv("ORDINARY_SETTING", oldOrdinary)
      else: delEnv("ORDINARY_SETTING")
    putEnv("ISONIM_ACP_AGENT_CMD", python)
    putEnv("ISONIM_CODEX_ACP_CMD", python)
    putEnv("ORDINARY_SETTING", "ordinary-value")
    let exact = @[peer, "", "space value", "quotes: '\" $()", "line\nbreak", "α"]
    for kind in [aakClaude, aakCodex, aakCustom]:
      var client = if kind == aakCustom:
          fromAcpAgent(kind, extraArgs = exact[2 .. ^1], cmd = "python3", args = exact[0 .. 1],
            idleTimeoutMs = 1000, hardDeadlineMs = 5000,
            launchPrefix = @[python, wrapper, "prefix-value"])
        else:
          fromAcpAgent(kind, extraArgs = exact, idleTimeoutMs = 1000, hardDeadlineMs = 5000,
            launchPrefix = @[python, wrapper, "prefix-value"])
      try:
        let initialization = client.acp.initialize(InitializeRequest(protocolVersion: 1,
          clientInfo: ClientInfo(name: "prefix-test", version: "1")))
        check initialization.protocolVersion == 1
        let session = client.startSession(directory)
        let observed = parseJson(session.id)
        check observed["args"] == %exact[1 .. ^1]
        check observed["prefix"].getStr == "prefix-value"
        check observed["ordinary"].getStr == "ordinary-value"
        check observed["executable"].getStr == python
      finally: shutdown(client)

  test "prefix preserves the explicit frame timeout alias":
    let directory = createTempDir("agents-prefix-timeout-", "")
    defer: removeDir(directory)
    let peer = directory / "silent.py"
    writeFile(peer, "import sys,time\nfor line in sys.stdin: time.sleep(5)\n")
    let wrapper = directory / "exec.py"
    writeFile(wrapper, "import os,sys\nos.execv(sys.argv[1],sys.argv[1:])\n")
    let python = findExe("python3")
    var client = fromStdioAcpAgent(python, @[peer], defaultTimeoutMs = 80,
      idleTimeoutMs = 1000, hardDeadlineMs = 2000, launchPrefix = @[python, wrapper])
    try:
      expect AcpError:
        discard client.acp.initialize(InitializeRequest(protocolVersion: 1))
    finally: shutdown(client)


  test "non-python executable override cannot bypass the scoped wrapper":
    let directory = createTempDir("agents-prefix-executable-", "")
    defer: removeDir(directory)
    let python = findExe("python3")
    let peer = directory / "actual-provider"
    writeFile(peer, "#!" & python & "\n" & """
import json,os,sys
for line in sys.stdin:
 r=json.loads(line)
 result={'protocolVersion':1,'agentCapabilities':{'text':True}} if r['method']=='initialize' else {'sessionId':json.dumps({'marker':os.environ.get('PREFIX_MARKER'),'args':sys.argv[1:]})}
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}),flush=True)
""")
    setFilePermissions(peer, {fpUserRead, fpUserWrite, fpUserExec})
    let wrapper = directory / "wrapper.py"
    writeFile(wrapper, "import os,sys\nos.environ['PREFIX_MARKER']='scoped-original'\nos.execv(sys.argv[1],sys.argv[1:])\n")
    let old = getEnv("ISONIM_ACP_AGENT_CMD")
    defer:
      if old.len > 0: putEnv("ISONIM_ACP_AGENT_CMD", old)
      else: delEnv("ISONIM_ACP_AGENT_CMD")
    putEnv("ISONIM_ACP_AGENT_CMD", peer)
    var client = fromClaudeCodeAcp(@["preserved", "two words"], launchPrefix = @[python, wrapper])
    try:
      discard client.acp.initialize(InitializeRequest(protocolVersion: 1))
      let session = client.startSession(directory)
      let actual = parseJson(session.id)
      check actual["marker"].getStr == "scoped-original"
      check actual["args"] == %(@["preserved", "two words"])
    finally: shutdown(client)
