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
