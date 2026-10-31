# shellcheck shell=bash
# Tests for scripts/secret-scan.sh. The two tests that need the gitleaks binary run only
# with GITLEAKS_TEST=1 (they download it once into the out dir).

test_rejects_parent_traversal() {
  assert_exit 2 scripts/secret-scan.sh tree /tmp/x '../etc' "$(mktemp -d)"
}

test_rejects_absolute_glob() {
  assert_exit 2 scripts/secret-scan.sh tree /tmp/x '/etc/*' "$(mktemp -d)"
}

test_removes_excluded_paths() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/group_vars/all"
  : > "$d/group_vars/all/git.yml"
  : > "$d/keep.yml"
  GITLEAKS_BIN=/bin/true scripts/secret-scan.sh tree "$d" 'group_vars/*' "$(mktemp -d)"
  [[ ! -e "$d/group_vars" && -e "$d/keep.yml" ]]
}

test_removes_nested_globstar_match() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/group_vars/all" "$d/roles/x/vars"
  : > "$d/group_vars/all/git.yml"
  : > "$d/roles/x/vars/git.yml"
  : > "$d/git.yml"
  : > "$d/keep.yml"
  GITLEAKS_BIN=/bin/true scripts/secret-scan.sh tree "$d" '**/git.yml' "$(mktemp -d)"
  [[ ! -e "$d/group_vars/all/git.yml" && ! -e "$d/roles/x/vars/git.yml" && ! -e "$d/git.yml" && -e "$d/keep.yml" ]]
}

test_detects_leak_in_diff() {
  [[ -n "${GITLEAKS_TEST:-}" ]] || return 0
  local out
  out=$(mktemp -d)
  assert_exit 1 scripts/secret-scan.sh diff "$(fixture leaky.diff)" '' "$out"
  grep -q 'AI review skipped: secret-like content' "$out/skip-reason.txt"
}

test_clean_diff_passes() {
  [[ -n "${GITLEAKS_TEST:-}" ]] || return 0
  local out
  out=$(mktemp -d)
  assert_exit 0 scripts/secret-scan.sh diff "$(fixture sample.diff)" '' "$out"
}
