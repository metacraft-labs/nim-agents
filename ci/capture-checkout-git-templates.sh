#!/usr/bin/env bash
# PRIVATE proposed read-only actual checkout template authority capture.
# No mocks; real Git initializes an exclusively owned template probe.
# No actual hooks/config/source/index writes; receipts contain hashes only.
set -euo pipefail
shopt -s dotglob nullglob
test -z "${GLOBIGNORE-}"
receipt=$1
test ! -e "$receipt"
mkdir -m 700 "$receipt"
test -z "${GIT_CONFIG-}${GIT_DIR-}${GIT_WORK_TREE-}${GIT_COMMON_DIR-}${GIT_TEMPLATE_DIR-}${GIT_CONFIG_PARAMETERS-}${GIT_CONFIG_COUNT-}${GIT_INDEX_FILE-}${GIT_OBJECT_DIRECTORY-}${GIT_ALTERNATE_OBJECT_DIRECTORIES-}${NIM_AGENTS_NATIVE_DIRECTORY_AUTHORITY-}"
test -z "${!GIT_CONFIG_KEY_@}${!GIT_CONFIG_VALUE_@}"
git_exe=$(command -v git)
git_real=$(realpath "$git_exe")
test -f "$git_real" && test -x "$git_real"
case "$git_real" in
  /nix/store/*/bin/git) git_root=${git_real%/bin/git} ;;
  /usr/bin/git)
    # Actual hosted checkout principal; diagnostic only, never hook admission.
    test "$(git --exec-path)" = /usr/lib/git-core
    git_root=/usr ;;
  *) echo 'unqualified checkout Git prefix' >&2; exit 1 ;;
esac
templates="$git_root/share/git-core/templates"
test ! -e "$templates/config" && test ! -L "$templates/config"
git_body_before=$(sha256sum "$git_real")
test -d "$templates/hooks" && test ! -L "$templates" && test ! -L "$templates/hooks"
# An inherited template selector is outside this source-qualified authority.
if git config --get init.templateDir >/dev/null; then
  echo 'inherited Git template selector refused' >&2; exit 1
else
  test "$?" = 1
fi
own_root=$(git rev-parse --show-toplevel)
test -d "$own_root/.git" && test ! -L "$own_root/.git"
common=$(realpath "$(git rev-parse --path-format=absolute --git-common-dir)")
test "$common" = "$(realpath "$own_root/.git")"
refuse_hooks_path() {
  if git config --get core.hooksPath >/dev/null; then
    echo 'configured hooksPath refused by ordinary checkout capture' >&2
    return 1
  else
    test "$?" = 1
  fi
}
refuse_hooks_path
record_source() {
  local entry fields name kind mode body
  git ls-files --stage -z > "$receipt/source-index-census-input" || return 1
  while IFS= read -r -d '' entry; do
    fields=${entry%%$'\t'*}; name=${entry#*$'\t'}
    test "${fields##* }" = 0 || return 1
    kind=${fields%% *}
    mode=$(stat -c %a -- "$name") || return 1
    case "$kind" in
      100644|100755) test -f "$name" && test ! -L "$name" || return 1; body=$(sha256sum -- "$name" | cut -d ' ' -f1) || return 1 ;;
      120000) test -L "$name" || return 1; body=$(readlink -z -- "$name" | sha256sum | cut -d ' ' -f1) || return 1 ;;
      *) echo 'unsupported tracked source kind refused' >&2; return 1 ;;
    esac
    printf '%s\0%s\0%s\0' "$entry" "$mode" "$body"
  done < "$receipt/source-index-census-input"
}
hooks="$common/hooks"
test -d "$hooks" && test ! -L "$hooks"
test -z "$(git --no-optional-locks status --porcelain=v1 --untracked-files=no)"
source_before=$(record_source | sha256sum)
record_directories() {
  local name directory identity
  for name in root common hooks; do
    case "$name" in root) directory=$own_root ;; common) directory=$common ;; hooks) directory=$hooks ;; esac
    test -d "$directory" && test ! -L "$directory" || return 1
    identity=$(stat -c '%d:%i:%a' -- "$directory") || return 1
    printf '%s\t%s\t%s\n' "$name" "$directory" "$identity"
  done
}
record_directories > "$receipt/directory-authority.tsv"
index_before=$(sha256sum "$common/index")
config_before=$(sha256sum "$common/config")
record_inventory() {
  local root=$1 member name mode body
  local members=("$root"/*)
  test "${#members[@]}" -gt 0 || { echo 'empty hook inventory refused' >&2; return 1; }
  for member in "${members[@]}"; do
    test -f "$member" && test ! -L "$member" || return 1
    name=${member##*/}
    case "$name" in *.sample) ;; *) echo 'unexpected checkout hook entry refused' >&2; return 1 ;; esac
    mode=$(stat -c %a -- "$member") || return 1
    body=$(sha256sum -- "$member" | cut -d ' ' -f1) || return 1
    printf '%s\t%s\t%s\n' "$name" "$mode" "$body"
  done | LC_ALL=C sort
}
record_inventory "$templates/hooks" > "$receipt/template-source-before.tsv"
# Genuine constructor fixtures use a child-only no-system/no-global configuration.
# Caller configuration and permission policy are preserved.
# Record actual creation policy before the genuine initialization, without changing it.
umask > "$receipt/creator-umask-before.txt"
if git config --get-all core.sharedRepository > "$receipt/caller-shared-policy.txt"; then
  :
else
  test "$?" = 1
fi
GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git init --template="$templates" "$receipt/probe" > "$receipt/probe.stdout" 2> "$receipt/probe.stderr"
umask > "$receipt/creator-umask-after.txt"
test "$(sha256sum < "$receipt/creator-umask-before.txt")" = "$(sha256sum < "$receipt/creator-umask-after.txt")"
# The original repository's local policy is not the fresh probe's effective policy.
if GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$receipt/probe" config --show-origin --show-scope --get-all core.sharedRepository > "$receipt/probe-shared-policy.txt"; then
  :
else
  test "$?" = 1
fi
record_inventory "$hooks" > "$receipt/initialized-before.tsv"
record_inventory "$receipt/probe/.git/hooks" > "$receipt/actual-template-initialized.tsv"
test "$(sha256sum < "$receipt/initialized-before.tsv")" = "$(sha256sum < "$receipt/actual-template-initialized.tsv")"
record_inventory "$templates/hooks" > "$receipt/actual-template-source.tsv"
# Hosted source is mutable: require the entire template body/mode inventory
# and executable image unchanged across the read-only probe.
test "$(sha256sum < "$receipt/template-source-before.tsv")" = "$(sha256sum < "$receipt/actual-template-source.tsv")"
test "$git_body_before" = "$(sha256sum "$git_real")"
record_directories > "$receipt/directory-authority-after.tsv"
test "$(sha256sum < "$receipt/directory-authority.tsv")" = "$(sha256sum < "$receipt/directory-authority-after.tsv")"
# Revalidate actual whole inventory after probe, before treating capture stable.
record_inventory "$hooks" > "$receipt/initialized-after.tsv"
test "$(sha256sum < "$receipt/initialized-before.tsv")" = "$(sha256sum < "$receipt/initialized-after.tsv")"
test "$source_before" = "$(record_source | sha256sum)"
test "$index_before" = "$(sha256sum "$common/index")"
test "$config_before" = "$(sha256sum "$common/config")"
test "$common" = "$(realpath "$(git rev-parse --path-format=absolute --git-common-dir)")"
test -d "$own_root/.git" && test ! -L "$own_root/.git"
refuse_hooks_path
printf '%s\n' "$own_root" > "$receipt/own-root.txt"
printf '%s\n' "$source_before" > "$receipt/tracked-source.sha256"
printf '%s\n' "$index_before" > "$receipt/index.sha256"
printf '%s\n' "$config_before" > "$receipt/config.sha256"
printf '%s\n' "$git_real" > "$receipt/git-image.txt"
sha256sum "$git_real" > "$receipt/git-image.sha256"
printf '%s\n' "$templates" > "$receipt/templates-source.txt"
printf '%s\n' "$(git rev-parse HEAD)" > "$receipt/source-head.txt"
printf '%s\n' 'read-only exact initialized inventory equals actual source constructor; whole state stable' > "$receipt/result.txt"
