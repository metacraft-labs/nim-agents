alias t := test
alias fmt := format

paths := "--path:src --path:../nim-everywhere/src --path:../nim-acp/src --path:../nim-agent-harbor/src"

build: build-native build-js

build-native:
    nim c {{paths}} tests/test_agents.nim
    nim c {{paths}} tests/test_consumers.nim

build-js:
    nim js {{paths}} tests/test_agents.nim
    nim js {{paths}} tests/test_consumers.nim

test: test-native test-js

test-native:
    nim c -r {{paths}} tests/test_agents.nim
    nim c -r {{paths}} tests/test_consumers.nim

test-js:
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_agents.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_consumers.nim

lint: lint-nim lint-nix

lint-nim:
    nim check {{paths}} tests/test_agents.nim
    nim check {{paths}} tests/test_consumers.nim

lint-nix:
    nixfmt --check flake.nix

format: format-nim format-nix

format-nim:
    nimpretty src/nim_agents.nim src/nim_agents/*.nim tests/*.nim

format-nix:
    nixfmt flake.nix

bump-version version:
    sed -i "s/^version       = .*/version       = \"{{version}}\"/" nim_agents.nimble
    printf "%s\n" "{{version}}" > VERSION
