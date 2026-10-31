# shellcheck shell=bash
# Tests for the diff helpers in scripts/lib.sh.

paths_after_filter() { # EXCLUDE_GLOBS -> space-separated b/ paths left in the diff
  filter_diff "$(fixture sample.diff)" "$1" | grep '^diff --git' | sed 's#.* b/##' | xargs
}

test_filter_drops_vault_and_lock() {
  assert_eq "tasks/main.yml old.txt b.yml logo.png" "$(paths_after_filter '')"
}

test_filter_applies_globs() {
  assert_eq "old.txt b.yml logo.png" "$(paths_after_filter 'tasks/*')"
}

test_filter_keeps_binary_marker() {
  filter_diff "$(fixture sample.diff)" '' | grep -q 'Binary files a/logo.png and b/logo.png differ'
}

test_filter_drops_modified_vault() { # re-encrypted vault: header is a context line, not an added one
  assert_eq "" "$(filter_diff "$(fixture vault-modified.diff)" '' | grep '^diff --git' || true)"
}

test_filter_hides_vault_turned_plaintext_but_reports_it() { # plaintext of a former vault never reaches the model, the reviewer is told
  assert_eq "" "$(filter_diff "$(fixture vault-to-plain.diff)" '' | grep '^diff --git' || true)"
  assert_eq $'vars/secrets.yml\tvault-removed' "$(filter_diff_dropped "$(fixture vault-to-plain.diff)" '')"
}

test_filter_dropped_lists_paths_with_reasons() {
  assert_eq $'vars/secrets.yml\tvault\npoetry.lock\tlockfile' "$(filter_diff_dropped "$(fixture sample.diff)" '')"
}

test_filter_dropped_reports_excluded_glob() {
  assert_eq $'tasks/main.yml\texcluded' "$(filter_diff_dropped "$(fixture sample.diff)" 'tasks/*' | head -1)"
}

# secret-scan.sh deletes a directory with everything below it; the diff filter must drop the
# same files, or a PR that changes one sends it to the model
test_filter_dropped_reports_excluded_directory() {
  assert_eq $'tasks/main.yml\texcluded' "$(filter_diff_dropped "$(fixture sample.diff)" 'tasks' | head -1)"
}

test_glob_matches_no_partial_directory_name() {
  ! _glob_matches tasks-extra/main.yml 'tasks'
}

# Every file secret-scan.sh deletes from the checkout must also be dropped from the diff;
# globstar `**/` matches zero directories there, and `./` or a trailing `/` still expand.
test_glob_matches_every_file_the_tree_removal_deletes() {
  local d before after globs='**/git.yml,roles/**/vars,./group_vars/*,host_vars/' path
  d=$(mktemp -d)
  mkdir -p "$d/roles/x/vars" "$d/roles/vars" "$d/sub" "$d/group_vars" "$d/host_vars/h"
  for path in git.yml sub/git.yml roles/vars/main.yml roles/x/vars/main.yml \
    group_vars/all.yml host_vars/h/main.yml keep.yml; do
    : > "$d/$path"
  done
  before=$(cd "$d" && find . -type f | sed 's|^\./||' | sort)
  GITLEAKS_BIN=/bin/true scripts/secret-scan.sh tree "$d" "$globs" "$(mktemp -d)" >/dev/null
  after=$(cd "$d" && find . -type f | sed 's|^\./||' | sort)
  assert_eq keep.yml "$after" "tree removal"
  while read -r path; do
    [[ $path == keep.yml ]] && continue
    _glob_matches "$path" "$globs" || { echo "deleted from the tree but sent in the diff: $path" >&2; return 1; }
  done <<<"$before"
  ! _glob_matches keep.yml "$globs"
}

test_glob_matches_ignores_cwd_files() { # patterns must not be pathname-expanded in the caller's cwd
  local d
  d=$(mktemp -d)
  mkdir -p "$d/tasks"
  : > "$d/tasks/x"
  (cd "$d" && _glob_matches tasks/main.yml 'tasks/*')
}

test_filter_exit_zero_on_empty() {
  local empty
  empty=$(mktemp)
  assert_exit 0 filter_diff "$empty" ''
}

test_too_large_true() {
  assert_exit 0 diff_too_large "$(fixture sample.diff)" 5
}

test_too_large_false() {
  assert_exit 1 diff_too_large "$(fixture sample.diff)" 4000
}

test_file_list_counts() {
  diff_file_list "$(fixture sample.diff)" | grep -q '^tasks/main.yml (+1/-0)$'
}

test_new_side_lines_from_hunk() {
  assert_eq $'tasks/main.yml\t12' "$(diff_new_side_lines "$(fixture sample.diff)" | head -1)"
}
