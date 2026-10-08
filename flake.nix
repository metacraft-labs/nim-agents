{
  description = "nim-agents - shared Nim agent abstraction";

  inputs = {
    mcl-standard-hook-source = {
      url = "github:metacraft-labs/devops-modules/c8ef41d446e211892fe9775182b43d5d517554ac";
      flake = false;
    };
    # Exact constructor authority for guarded native hook activation.
    managed-hook-reprobuild.url = "github:metacraft-labs/reprobuild/76659f5730ecf698b1963c656494d2cb66eb256d";
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      git-hooks,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        let
          # git-hooks.nix installs `.pre-commit-config.yaml` and git hooks into
          # `git rev-parse --show-toplevel` of the directory the shell is entered
          # from, so `nix develop /path/to/<this repo>` run inside another checkout
          # would plant this repository's hooks there. `ownRepoOnly` runs a snippet
          # only when that toplevel is this repository, recognised by a `flake.nix`
          # identical to the one this shell was evaluated from; anything it cannot
          # establish counts as another repository, so it fails safe.
          # tests/test_dev_shell_writes_nothing_elsewhere.sh
          ownRepoOnly = script: ''
            _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
              && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
                = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
            ${script}
            fi
            unset _own_repo_root
          '';

          legacyPreCommit = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              check-added-large-files.enable = true;
              check-merge-conflicts.enable = true;
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                language = "system";
                pass_filenames = false;
              };
            };
          };
          standardHooks = import (inputs.mcl-standard-hook-source + "/git-hooks/standard-hooks.nix") {
            inherit pkgs;
            lib = pkgs.lib;
            src = inputs.mcl-standard-hook-source;
          };
          # Exact reviewed public capability; other package versions keep their
          # original native constructor and previously qualified authority.
          nativePrek =
            if pkgs.prek.version == "0.3.11" then
              (pkgs.writeShellScriptBin "prek" ''
                exec ${pkgs.python3}/bin/python3 ${./nix/native-package-adapter.py} ${pkgs.lib.getExe pkgs.prek} ${pkgs.git}/bin/git "$@"
              '').overrideAttrs
                (_: {
                  pname = pkgs.prek.pname;
                  version = pkgs.prek.version;
                })
            else
              pkgs.prek;
          preCommit = git-hooks.lib.${system}.run {
            src = ./.;
            package = nativePrek;
            hooks = standardHooks // {
              check-merge-conflicts.enable = true;
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                language = "system";
                pass_filenames = false;
              };
            };
          };
          nativeHookFactory =
            configuration:
            pkgs.runCommand "nim-agents-native-hook-factory"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.bash
                  configuration.config.package
                ];
              }
              ''
                export PRE_COMMIT_HOME="$TMPDIR/nim-agents-native-hook-cache"
                export XDG_CACHE_HOME="$TMPDIR/nim-agents-native-factory-cache"
                export GIT_CONFIG_GLOBAL="$TMPDIR/nim-agents-native-factory-gitconfig"
                export GIT_CONFIG_NOSYSTEM=1
                : > "$GIT_CONFIG_GLOBAL"
                mkdir -p "$PRE_COMMIT_HOME" "$XDG_CACHE_HOME" fixture
                cd fixture
                git init --template= >/dev/null
                if git config --get core.hooksPath; then
                  echo 'Unexpected native factory hooksPath authority' >&2
                  exit 1
                fi
                test "$(git rev-parse --path-format=absolute --git-path hooks)" = "$PWD/.git/hooks"
                ln -s ${configuration.config.configFile} ${configuration.config.configPath}
                mkdir -p "$out"
                for hook in pre-commit pre-push; do
                  ${pkgs.lib.getExe configuration.config.package} install -c ${configuration.config.configPath} -t "$hook"
                  install -m 0755 ".git/hooks/$hook" "$out/$hook"
                done
              '';
          expectedNativeHook = nativeHookFactory preCommit;
          expectedLegacyNativeHook = nativeHookFactory legacyPreCommit;
          hookOwnershipGuard = ./nix/hook-ownership-guard.py;
          hookTransaction = ./nix/hook-transaction.py;
          actualNativeInstaller = pkgs.writeShellScript "nim-agents-native-hook-installer" preCommit.shellHook;
          managedHookConstructor = inputs.managed-hook-reprobuild.packages.${system}.reprobuild;
          guardedHookInstall = ''
            if [ -n "''${REPROBUILD_REPRO:-}" ] && [ "$REPROBUILD_REPRO" != "${managedHookConstructor}/bin/repro" ]; then
              echo 'Foreign inherited managed constructor authority' >&2
              exit 1
            fi
            export REPROBUILD_REPRO="${managedHookConstructor}/bin/repro"
            ${pkgs.python3}/bin/python3 ${hookTransaction} "$_own_repo_root" ${hookOwnershipGuard} ${expectedNativeHook} ${pkgs.git}/share/git-core/templates ${expectedLegacyNativeHook} ${preCommit.config.configFile} ${legacyPreCommit.config.configFile} ${actualNativeInstaller} ${pkgs.git}/bin/git ${pkgs.bash}/bin/bash >&2
            _nim_agents_hook_status=$?
            if [ "$_nim_agents_hook_status" -ne 0 ]; then
              unset _nim_agents_hook_status
              exit 1
            fi
            unset _nim_agents_hook_status
          '';
        in
        {
          checks.pre-commit = preCommit;
          apps = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            prepare-ci-hook-samples = {
              type = "app";
              program = toString (
                pkgs.writeShellScript "prepare-ci-hook-samples" ''
                  exec ${pkgs.python3}/bin/python3 -I ${./nix/ci-initial-samples-transition.py} \
                    ${pkgs.git}/bin/git \
                    ${builtins.hashFile "sha256" ./ci/capture-checkout-git-templates.sh} \
                    ${builtins.hashFile "sha256" ./flake.nix} "$@"
                ''
              );
            };
          };
          devShells.default = pkgs.mkShell {
            packages =
              preCommit.enabledPackages
              ++ (with pkgs; [
                nim
                nimble
                just
                nodejs
                nixfmt-rfc-style
                git
                bash
                python3
                prek
              ]);
            shellHook = ''
              ${ownRepoOnly guardedHookInstall}
            '';
          };
          packages.default = pkgs.stdenvNoCC.mkDerivation {
            pname = "nim-agents";
            version = builtins.readFile ./VERSION;
            src = ./.;
            installPhase = ''
              mkdir -p $out
              cp -R src nim_agents.nimble VERSION README.md $out/
            '';
          };
        };
    };
}
