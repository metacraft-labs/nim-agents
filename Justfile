alias t := test
alias fmt := format

paths := "--path:src --path:../nim-everywhere/src --path:../nim-acp/src --path:../nim-agent-harbor/src"

# Build: compile every test module, native and JS, through the reprobuild graph
# (`repro.nim`). CI runs the same command. `build-native` and `build-js` below
# compile the same modules directly with the compiler, for a quick edit loop.
build:
    repro build .#test-builds

build-native:
    nim c {{paths}} tests/test_acp_launch_prefix.nim
    nim c {{paths}} tests/test_agents.nim
    nim c {{paths}} tests/test_consumers.nim
    nim c {{paths}} tests/test_session_load_client.nim
    nim c {{paths}} tests/test_native_stdio_acp_transport.nim
    nim c {{paths}} tests/test_codex_acp_smoke.nim
    nim c {{paths}} tests/test_inject_prompt_client.nim
    nim c {{paths}} tests/test_nimcache_is_worktree_local.nim
    nim c {{paths}} tests/test_agent_harbor_domain.nim
    nim c {{paths}} tests/test_agent_harbor_fleet_fold.nim
    nim c {{paths}} tests/test_activity_groups.nim
    nim c {{paths}} tests/test_review_record.nim
    nim c {{paths}} tests/test_change_diff.nim
    nim c {{paths}} tests/test_inbox.nim
    nim c {{paths}} tests/test_instruction_composer.nim
    nim c {{paths}} tests/test_result_commands.nim
    nim c {{paths}} tests/test_suggested_actions.nim
    nim c {{paths}} tests/test_control_center.nim

build-js:
    nim js {{paths}} tests/test_agents.nim
    nim js {{paths}} tests/test_consumers.nim
    nim js {{paths}} tests/test_session_load_client.nim
    nim js {{paths}} tests/test_agent_harbor_domain.nim
    nim js {{paths}} tests/test_agent_harbor_fleet_fold.nim
    nim js {{paths}} tests/test_activity_groups.nim
    nim js {{paths}} tests/test_review_record.nim
    nim js {{paths}} tests/test_change_diff.nim
    nim js {{paths}} tests/test_inbox.nim
    nim js {{paths}} tests/test_instruction_composer.nim
    nim js {{paths}} tests/test_result_commands.nim
    nim js {{paths}} tests/test_suggested_actions.nim
    nim js {{paths}} tests/test_control_center.nim

# Test: run the native and JS test corpus through `repro test` (one build edge
# and one execute edge per module; the JS modules run under node). CI runs the
# same command. `test-native` and `test-js` below run the same modules directly
# with the compiler. `test-js` also applies `tools/nim-js-test-gate.sh`, which
# additionally fails a module whose log has a failure sentinel or no `[OK]`
# line; the graph keys on the exit status of `node` and does not read the log,
# so that stricter check lives only in `test-js`.
test:
    repro test

test-native:
    nim c -r {{paths}} tests/test_activity.nim
    nim c -r {{paths}} tests/test_activity_groups.nim
    nim c -r {{paths}} tests/test_instruction_composer.nim
    nim c -r {{paths}} tests/test_result_commands.nim
    nim c -r {{paths}} tests/test_suggested_actions.nim
    nim c -r {{paths}} tests/test_control_center.nim
    nim c -r {{paths}} tests/test_agent_harbor_domain.nim
    nim c -r {{paths}} tests/test_agent_harbor_fleet_fold.nim
    nim c -r {{paths}} tests/test_review_record.nim
    nim c -r {{paths}} tests/test_change_diff.nim
    nim c -r {{paths}} tests/test_inbox.nim
    nim c -r {{paths}} tests/test_acp_launch_prefix.nim
    nim c -r {{paths}} tests/test_harbor_lifecycle_threads.nim
    nim c -r {{paths}} tests/test_harbor_rest_native.nim
    nim c -r {{paths}} tests/test_agents.nim
    nim c -r {{paths}} tests/test_consumers.nim
    nim c -r {{paths}} tests/test_session_load_client.nim
    nim c -r {{paths}} tests/test_native_stdio_acp_transport.nim
    nim c -r {{paths}} tests/test_codex_acp_smoke.nim
    nim c -r {{paths}} tests/test_inject_prompt_client.nim
    nim c -r {{paths}} tests/test_nimcache_is_worktree_local.nim

test-js:
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_activity.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_activity_groups.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_instruction_composer.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_result_commands.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_suggested_actions.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_control_center.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_agent_harbor_domain.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_agent_harbor_fleet_fold.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_review_record.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_change_diff.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_inbox.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_agents.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_consumers.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_session_load_client.nim

lint: lint-nim lint-nix

lint-nim:
    nim check {{paths}} tests/test_acp_launch_prefix.nim
    nim check {{paths}} tests/test_agents.nim
    nim check {{paths}} tests/test_consumers.nim
    nim check {{paths}} tests/test_session_load_client.nim
    nim check {{paths}} tests/test_native_stdio_acp_transport.nim
    nim check {{paths}} tests/test_codex_acp_smoke.nim
    nim check {{paths}} tests/test_inject_prompt_client.nim
    nim check {{paths}} tests/test_nimcache_is_worktree_local.nim
    nim check {{paths}} tests/test_agent_harbor_domain.nim
    nim check {{paths}} tests/test_agent_harbor_fleet_fold.nim
    nim check {{paths}} tests/test_activity_groups.nim
    nim check {{paths}} tests/test_review_record.nim
    nim check {{paths}} tests/test_change_diff.nim
    nim check {{paths}} tests/test_inbox.nim
    nim check {{paths}} tests/test_instruction_composer.nim
    nim check {{paths}} tests/test_result_commands.nim
    nim check {{paths}} tests/test_suggested_actions.nim

lint-nix:
    nixfmt --check flake.nix

format: format-nim format-nix

format-nim:
    nimpretty src/nim_agents.nim src/nim_agents/*.nim src/nim_agents/agent_harbor/*.nim tests/*.nim

format-nix:
    nixfmt flake.nix

bump-version version:
    sed -i "s/^version       = .*/version       = \"{{version}}\"/" nim_agents.nimble
    printf "%s\n" "{{version}}" > VERSION

# Entering the dev shell from another git repository must write nothing there.
# Runs `nix develop`, so it is not part of the in-shell test recipes.
test-dev-shell:
    bash tests/test_dev_shell_writes_nothing_elsewhere.sh
    bash tests/test_dev_shell_linked_worktree.sh
