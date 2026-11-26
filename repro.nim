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
## **Native and JavaScript builds.** The ``Justfile`` builds and runs a JS
## matrix (``nim js``, run under ``node``) next to the native one. The native
## corpus uses the engine test template (``nim c``); the JS matrix is declared
## below with the typed ``nim.js`` constructor (BUILD edge) and the typed
## ``node`` tool (EXECUTE edge). Two JS shapes mirror the two recipes:
##
##   * ``build-js`` compiles the files of ``agentsJsBuildStems`` WITHOUT ``-d:nodejs`` (the browser
##     target) and never runs them: compile-only edges, collected into
##     ``js-build``.
##   * ``test-js`` compiles the files of ``agentsJsTestStems`` with ``-d:nodejs`` (what ``nim js -r``
##     adds implicitly, and what makes a failing ``unittest`` exit non-zero
##     under ``node``) and runs each emitted ``.js`` under ``node``: a BUILD +
##     EXECUTE pair per file, collected into ``js-test-builds`` / ``js-test``
##     and also folded into ``test-builds`` / ``test``.
##
## The ``Justfile`` runs the JS tests through ``tools/nim-js-test-gate.sh``,
## which additionally greps the log for failure sentinels and requires an
## ``[OK]`` line. The graph keys on ``node``'s exit status instead, so a JS test
## module that registers no test at all passes here and fails there; the script
## stays authoritative for ``just test-js``, and CI's ``ci.yml`` runs it.
##
## ``tests/test_nimcache_is_worktree_local.nim`` is an ordinary native pair: it
## passes under ``repro`` because the repo-root ``config.nims`` still applies.
## ``tests/test_activity_modules_are_transport_free.nim`` is native-only too:
## it hands the search paths it was compiled with to the ``nim check`` probes
## it runs, so it resolves the sibling libraries the way its BUILD edge did.
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
import repro_dsl_stdlib/foreign_env

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

# Stems of the JS matrix. ``build-js`` compiles ``agentsJsBuildStems`` for the
# browser target (compile-only); ``test-js`` compiles and runs
# ``agentsJsTestStems`` under node. Keep both in step with the Justfile.
const agentsJsBuildStems: seq[string] = @[
  "test_agents", "test_consumers", "test_session_load_client",
  "test_agent_harbor_domain", "test_agent_harbor_fleet_fold",
  "test_activity_groups", "test_review_record", "test_change_diff",
  "test_inbox", "test_instruction_composer", "test_result_commands",
  "test_suggested_actions", "test_prompt_context", "test_activity_model",
  "test_control_center", "test_test_runs", "test_trace_links",
]
const agentsJsTestStems: seq[string] = @[
  "test_activity", "test_activity_groups", "test_agent_harbor_domain",
  "test_agent_harbor_fleet_fold", "test_agents", "test_consumers",
  "test_session_load_client", "test_review_record", "test_change_diff",
  "test_inbox", "test_instruction_composer", "test_result_commands",
  "test_suggested_actions", "test_prompt_context", "test_activity_model",
  "test_control_center", "test_test_runs", "test_trace_links",
]

const agentsTestSpecs: seq[AgentsTestSpec] = @[
  AgentsTestSpec(source: "tests/test_harbor_lifecycle_threads.nim",
    binary: "build/test-bin/test_harbor_lifecycle_threads", serial: true),
  AgentsTestSpec(source: "tests/test_harbor_rest_native.nim",
    binary: "build/test-bin/test_harbor_rest_native", serial: true),
  # Pure-API unittest suites — no OS gate, no subprocess; parallel-safe.
  AgentsTestSpec(source: "tests/test_acp_launch_prefix.nim",
    binary: "build/test-bin/test_acp_launch_prefix", serial: true),
  AgentsTestSpec(source: "tests/test_activity.nim",
    binary: "build/test-bin/test_activity", serial: false),
  AgentsTestSpec(source: "tests/test_activity_groups.nim",
    binary: "build/test-bin/test_activity_groups", serial: false),
  AgentsTestSpec(source: "tests/test_agent_harbor_domain.nim",
    binary: "build/test-bin/test_agent_harbor_domain", serial: false),
  AgentsTestSpec(source: "tests/test_agent_harbor_fleet_fold.nim",
    binary: "build/test-bin/test_agent_harbor_fleet_fold", serial: false),
  AgentsTestSpec(source: "tests/test_session_load_client.nim",
    binary: "build/test-bin/test_session_load_client", serial: false),
  AgentsTestSpec(source: "tests/test_nimcache_is_worktree_local.nim",
    binary: "build/test-bin/test_nimcache_is_worktree_local", serial: false),
  # Native only: it runs `nim check` on probes of the activity modules with
  # every ACP and Agent Harbor transport replaced by an `{.error.}` stub.
  AgentsTestSpec(source: "tests/test_activity_modules_are_transport_free.nim",
    binary: "build/test-bin/test_activity_modules_are_transport_free",
    serial: false),
  AgentsTestSpec(source: "tests/test_review_record.nim",
    binary: "build/test-bin/test_review_record", serial: false),
  AgentsTestSpec(source: "tests/test_change_diff.nim",
    binary: "build/test-bin/test_change_diff", serial: false),
  AgentsTestSpec(source: "tests/test_inbox.nim",
    binary: "build/test-bin/test_inbox", serial: false),
  AgentsTestSpec(source: "tests/test_test_runs.nim",
    binary: "build/test-bin/test_test_runs", serial: false),
  AgentsTestSpec(source: "tests/test_trace_links.nim",
    binary: "build/test-bin/test_trace_links", serial: false),
  AgentsTestSpec(source: "tests/test_instruction_composer.nim",
    binary: "build/test-bin/test_instruction_composer", serial: false),
  AgentsTestSpec(source: "tests/test_result_commands.nim",
    binary: "build/test-bin/test_result_commands", serial: false),
  AgentsTestSpec(source: "tests/test_suggested_actions.nim",
    binary: "build/test-bin/test_suggested_actions", serial: false),
  AgentsTestSpec(source: "tests/test_prompt_context.nim",
    binary: "build/test-bin/test_prompt_context", serial: false),
  AgentsTestSpec(source: "tests/test_activity_model.nim",
    binary: "build/test-bin/test_activity_model", serial: false),
  AgentsTestSpec(source: "tests/test_control_center.nim",
    binary: "build/test-bin/test_control_center", serial: false),
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
  devEnv:
    when not defined(windows):
      useFlakeDevShell()

  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs. ``nim``
    # compiles every test binary (the ``buildNimUnittest.build`` edges below,
    # matching the nimble file's ``requires "nim >= 2.0.0"``); ``gcc`` is the
    # C back-end ``nim c`` shells out to. Sufficient for the path-mode
    # resolver under ``nix develop``.
    "nim >=2.0"
    when defined(macosx):
      "clang >=14"
    else:
      "gcc >=12"
    # The unchanged legacy cross-checks run through repro exec. Declare their
    # runner so Windows resolves the SDK's authenticated just package.
    "just >=1"
    "python3 >=3.9"
    # Runs the ``nim js`` output of the JS test matrix (``node`` typed tool).
    "node >=20"

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
        extraInputs = @["src", "nim_agents.nimble", "tests/harbor_lifecycle_peer.py",
          "tests/harbor_rest_fixture.py"])
      when defined(macosx):
        appendRegisteredActionToolIdentityRefs(edge.action.id, ["clang"])
      elif defined(linux) or defined(windows):
        # Bind the real platform C backend to this exact typed compile.
        appendRegisteredActionToolIdentityRefs(edge.action.id, ["gcc"])
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
      # The test binaries start real Python peers (the ACP launch-prefix
      # wrapper and provider, harbor_lifecycle_peer.py, harbor_rest_fixture.py)
      # and look `python3` up on PATH. An execute action's PATH holds only the
      # tools it names, so without this the suite found no python3
      # (`findExe("python3") == ""` in test_acp_launch_prefix).
      appendRegisteredActionToolIdentityRefs(executeEdge.id, ["python3"])
      executeActions.add(executeEdge)

    for spec in agentsTestSpecs:
      emitTestPair(spec.source, spec.binary, spec.serial,
        testBuildActions, testExecuteActions)


    # --- JavaScript back-end matrix ----------------------------------------
    # ``build-js``: compile-only for the browser target (no ``-d:nodejs``),
    # exactly as the recipe does; nothing runs the output, so no EXECUTE edge.
    var jsBuildActions: seq[BuildActionDef] = @[]
    for stem in agentsJsBuildStems:
      let jsBuildEdge = nim.js(
        source = "tests/" & stem & ".nim",
        # ``.browser.js``: the implicit target name is the output basename, and
        # ``test-js`` below emits ``<stem>.js`` for the same stems.
        output = "build/js/" & stem & ".browser.js",
        paths = @["src"],
        actionId = "nim_agents.js_build." & stem,
        extraInputs = @["src", "nim_agents.nimble"])
      jsBuildActions.add(jsBuildEdge)

    # ``test-js``: ``nim js -r`` implies ``-d:nodejs`` (emit ``process.exit``).
    # Without it a failing ``unittest`` ``quit(1)`` is a no-op in the emitted
    # JS and ``node`` would exit 0 on a failed assertion, so the edge adds it
    # itself. The compile and the run are two edges so a change that leaves the
    # emitted JS identical does not re-run the tests.
    var jsTestBuildActions: seq[BuildActionDef] = @[]
    var jsTestExecuteActions: seq[BuildActionDef] = @[]
    for stem in agentsJsTestStems:
      let jsOut = "build/js-test/" & stem & ".js"
      let jsTestBuildEdge = nim.js(
        source = "tests/" & stem & ".nim",
        output = jsOut,
        defines = @["nodejs"],
        paths = @["src"],
        actionId = "nim_agents.js_test_build." & stem,
        extraInputs = @["src", "nim_agents.nimble"])
      let jsTestExecuteEdge = node(
        args = @[jsOut],
        actionId = "nim_agents.js_test_execute." & stem,
        after = @[jsTestBuildEdge],
        extraInputs = @[jsOut])
      jsTestBuildActions.add(jsTestBuildEdge)
      jsTestExecuteActions.add(jsTestExecuteEdge)

    discard collect("js-build", jsBuildActions)
    discard collect("js-test-builds", jsTestBuildActions)
    discard collect("js-test", jsTestExecuteActions)
    # The Justfile's ``test`` / ``build`` span both back-ends, so the JS halves
    # also join the aggregate collections.
    testBuildActions.add(jsBuildActions)
    testBuildActions.add(jsTestBuildActions)
    testExecuteActions.add(jsTestExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
