## Reprobuild project file for nim-agents.
##
## **Typed-Cross-Project-Deps rollout — a CROSS-REPO CONSUMER.** ``nim-agents``
## is the shared composition layer over ACP and Agent Harbor: its ``src/`` and
## test corpus ``import nim_acp``, ``import nim_agent_harbor``, and
## ``import nim_everywhere`` — three sibling workspace Nim libraries that the
## ``Justfile`` resolves only via hardcoded ``--path:../nim-*/src`` flags. So
## this is NOT a leaf. All three siblings ship a landed ``repro.nim`` with a
## ``library`` export:
##
##   * ``nim-acp``           → ``library nim_acp``           (its ``repro.nim``)
##   * ``nim-agent-harbor``  → ``library nim_agent_harbor``  (its ``repro.nim``)
##   * ``nim-everywhere``    → ``library nim_everywhere``    (its ``repro.nim``)
##
## so each is consumed via the SC-11 develop-mode ``uses: "<sibling>"`` pattern:
## naming the workspace project in ``uses:`` makes reprobuild build that sibling
## from source and thread its exported ``library`` ``src/`` root onto this
## repo's ``nim c --path:`` via the ``nimPathDirs`` aux channel — replacing the
## ``Justfile``'s three hardcoded ``--path:../nim-*/src`` flags with real typed
## cross-project source edges (no direnv, no ``../<sib>/src`` literal).
##
## Note ``nim-agent-harbor`` itself ``uses: "nim-everywhere"`` transitively, but
## ``nim-agents``' OWN sources (``src/nim_agents/client.nim``, ``tests/*``)
## ``import nim_everywhere`` and ``import nim_acp`` directly, so all three
## siblings are named here explicitly rather than relied on transitively.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical ``runquota/repro.nim`` / ``nim-agent-harbor/repro.nim`` /
## ``nim-stackable-hooks/repro.nim`` recipes:
##
## * Declares the toolchain floor via ``uses:`` (``nim`` + ``gcc``) plus the
##   three sibling ``uses:`` edges. Mirrors the nimble file's
##   ``requires "nim >= 2.0.0"``.
## * Declares ``library nim_agents`` so any downstream consumer can express a
##   workspace dependency on this repo with ``uses: "nim-agents"``. The
##   importable umbrella is ``src/nim_agents.nim`` (it re-exports ``client`` +
##   the two backend surfaces); consumers may also import
##   ``src/nim_agents/client.nim`` directly.
## * Emits, per test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>`` and an
##   EXECUTE edge (``edge.testBinary.run``) that runs it — the two-edge test
##   template from ``reprobuild-specs/Package-Model.md`` §"The test template".
##   BUILD halves collect into ``test-builds``; EXECUTE halves into ``test`` so
##   ``repro build test`` / ``repro test`` materialise the runnable closure
##   (each execute edge transitively depends on its build edge).
##
## **Module search path.** ``paths = @["src"]`` reproduces the ``Justfile``'s
## ``--path:src`` (this repo ships no ``config.nims`` / ``nim.cfg``); the three
## sibling library src roots (``nim-acp/src``, ``nim-agent-harbor/src``,
## ``nim-everywhere/src``) are threaded automatically by the SC-11
## ``nimPathDirs`` channel off the three ``uses:`` edges, replacing the
## ``Justfile``'s hardcoded ``--path:../nim-*/src``.
##
## **Native-only build.** The ``Justfile`` also builds a JS target
## (``nim js``) for ``test_agents`` / ``test_consumers``, but the engine
## test template compiles native (``nim c``). All five test files compile +
## run native to exit 0 on this host; the JS matrix cell is a Justfile-only
## concern (the reprobuild rollout scope is the native corpus). No native
## test is dropped and none is run off its OS.
##
## **Per-test platform gating.** Re-derived from each file's imports + guards
## (the nimble/Justfile lists are the same five files; every one is
## native-runnable on this Linux host):
##
##   * ``test_agents.nim``   — ``import unittest``, ``std/json``,
##     ``std/strutils``, ``nim_everywhere``, ``nim_agents``. No OS ``when``
##     gate; pure-API unittest. Runs on every native host. Portable.
##   * ``test_consumers.nim`` — ``import std/strutils``, ``unittest``,
##     ``nim_agents``. No OS gate; import-smoke unittest. Portable.
##   * ``test_native_stdio_acp_transport.nim`` — head ``when defined(js):
##     {.error: "…native-only.".}`` — native-only by construction (JS is a
##     COMPILE error, not a runtime skip). On native it spawns
##     ``claude-code-acp`` / ``claude-agent-acp`` and ``skip()``s (exit 0)
##     when the binary is absent from ``PATH``. Native-runnable here.
##   * ``test_codex_acp_smoke.nim`` — same ``when defined(js): {.error.}``
##     native-only head; spawns ``codex-acp`` and ``skip()``s when absent.
##     Native-runnable here.
##   * ``test_inject_prompt_client.nim`` — same native-only ``{.error.}``
##     head; ``import nim_everywhere`` + ``nim_agents``; drives ``fromCodexAcp``
##     and ``skip()``s when ``codex-acp`` is absent. Native-runnable here.
##
## Since the engine build is native-only, ALL FIVE files compile + run native
## to exit 0 on this Linux host, so every edge is unconditionally in the graph
## — there are no ``when defined(...)`` EXTRACTION gates (the three
## ``{.error.}`` heads only exclude the JS target the engine never emits).
##
## **Subprocess serialization.** The three native-only smoke tests each spawn a
## real ACP-server subprocess over stdio (``claude-code-acp`` / ``codex-acp``)
## and drive a JSON-RPC ``initialize`` / ``session/new`` round-trip with
## timeouts. Running them concurrently — especially under a saturated host
## during the cross-repo rollout — starves those child processes of scheduler
## time and can flake the timing-bounded reads (or, when the binaries ARE
## present, contend on a single auth endpoint). A capacity-1 build pool
## sequences the three subprocess-spawning EXECUTE edges so each runs with the
## headroom its own spawn+round-trip needs. This changes ONLY scheduling: no
## ``check`` is skipped, relaxed, or removed — every test still runs in full to
## exit 0 (or its own internal ``skip()`` when a binary is absent). The two
## pure-API tests + all BUILD (compile) edges stay unpooled and parallel.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``, so
## the weak-local PATH resolver is the right default. It is also required for
## the ``uses:`` declarations to resolve at all ("typed tool provisioning is
## required for uses declarations").

import repro_project_dsl

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by every test BUILD edge and the ``edge.testBinary.run(...)``
# UFCS dispatch for the EXECUTE edges. It re-exports ``repro_project_dsl`` so
# the import order is unimportant. Like the other leaf/consumer sibling recipes
# this file does NOT import ``ct_test_runner_install`` (engine-coupled,
# reprobuild-internal): the execute edges route through the engine's default
# direct-binary runner (run the binary, key on exit status), which is exactly
# the exit-0 verification this corpus needs — Nim ``unittest`` prints per-suite
# results and exits non-zero on failure.
import ct_test_nim_unittest

type
  AgentsTestSpec = object
    ## One entry per test file. ``source`` is the repo-relative ``.nim``
    ## path; ``binary`` is the ``build/test-bin/<stem>`` output; ``serial``
    ## marks the subprocess-spawning tests routed through the capacity-1
    ## EXECUTE pool.
    source: string
    binary: string
    serial: bool

const agentsTestSpecs: seq[AgentsTestSpec] = @[
  # Pure-API unittest suites — no OS gate, no subprocess; parallel-safe.
  AgentsTestSpec(source: "tests/test_agents.nim",
    binary: "build/test-bin/test_agents", serial: false),
  AgentsTestSpec(source: "tests/test_consumers.nim",
    binary: "build/test-bin/test_consumers", serial: false),
  # Native-only ACP smoke tests (``when defined(js): {.error.}`` heads) that
  # spawn a real ACP-server subprocess and ``skip()`` when the binary is
  # absent. Serialised through the capacity-1 EXECUTE pool.
  AgentsTestSpec(source: "tests/test_native_stdio_acp_transport.nim",
    binary: "build/test-bin/test_native_stdio_acp_transport", serial: true),
  AgentsTestSpec(source: "tests/test_codex_acp_smoke.nim",
    binary: "build/test-bin/test_codex_acp_smoke", serial: true),
  AgentsTestSpec(source: "tests/test_inject_prompt_client.nim",
    binary: "build/test-bin/test_inject_prompt_client", serial: true),
]

package nim_agents:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs. ``nim``
    # compiles every test binary (the ``buildNimUnittest.build`` edges below,
    # matching the nimble file's ``requires "nim >= 2.0.0"``); ``gcc`` is the
    # C back-end ``nim c`` shells out to. Sufficient for the path-mode
    # resolver under ``nix develop``.
    "nim >=2.0"
    "gcc >=12"

    # Sibling Nim-library producers (SC-11 develop-mode from-source
    # consumption). ``src/nim_agents/client.nim`` + ``src/nim_agents.nim`` +
    # the tests ``import nim_acp`` / ``nim_agent_harbor`` / ``nim_everywhere``.
    # Naming the three workspace projects here makes reprobuild build each from
    # source (their ``library nim_acp`` / ``library nim_agent_harbor`` /
    # ``library nim_everywhere``) and thread their ``src/`` roots onto this
    # repo's ``nim c --path:`` via the ``nimPathDirs`` aux channel — replacing
    # the ``Justfile``'s hardcoded ``--path:../nim-acp/src
    # --path:../nim-agent-harbor/src --path:../nim-everywhere/src``.
    "nim-acp"
    "nim-agent-harbor"
    "nim-everywhere"

  # Library declaration — the ``src/`` tree the ``Justfile`` puts on
  # ``--path`` is importable when this package is consumed via
  # ``uses: "nim-agents"``. The umbrella is ``src/nim_agents.nim`` (it
  # re-exports ``client`` + the ACP / Agent-Harbor surfaces); consumers may
  # also import ``src/nim_agents/client.nim`` directly.
  library nim_agents

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile-only BUILD edge + one EXECUTE edge per test file. BUILD halves
    # collect into ``test-builds`` (compile-only verification); EXECUTE halves
    # collect into ``test`` so ``repro test`` / ``repro build test``
    # materialise the runnable closure (each execute edge transitively depends
    # on its build edge). ``paths = @["src"]`` reproduces the repo's
    # ``--path:src``; the three sibling ``src`` roots are threaded
    # automatically by the SC-11 ``nimPathDirs`` channel off the ``uses:``
    # sibling edges.
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    # Capacity-1 EXECUTE pool for the subprocess-spawning smoke tests. See the
    # module docstring's "Subprocess serialization" note: this sequences the
    # ACP-server spawns without skipping/relaxing any ``check``. The BUILD
    # (compile) edges stay unpooled and parallel.
    let acpPool = buildPool("nim_agents.acp-serial", 1'u32)
    discard acpPool

    proc emitTestPair(source, binary: string; serial: bool;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        paths = @["src"],
        actionId = "nim_agents.test_build." & stem,
        extraInputs = @["src", "nim_agents.nimble"])
      buildActions.add(edge.action)
      # ``registerImplicitName = false`` because the BUILD edge already owns
      # the binary basename as the implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (two-edge shape).
      let executeEdge =
        if serial:
          edge.testBinary.run(
            actionId = "nim_agents.test_execute." & stem,
            pool = "nim_agents.acp-serial",
            registerImplicitName = false)
        else:
          edge.testBinary.run(
            actionId = "nim_agents.test_execute." & stem,
            registerImplicitName = false)
      executeActions.add(executeEdge)

    for spec in agentsTestSpecs:
      emitTestPair(spec.source, spec.binary, spec.serial,
        testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
