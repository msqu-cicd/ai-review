# shellcheck shell=bash
# Tests for scripts/secret-scan.sh. The tests that need the gitleaks binary run only
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

# leaky_tree: a checkout holding the token file that leaky.diff adds.
leaky_tree() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/group_vars/all"
  sed -n 's/^+\([a-z]\)/\1/p' "$(fixture leaky.diff)" > "$d/group_vars/all/tokens.yml"
  printf '%s\n' "$d"
}

# The checkout is the PR head: nothing in it may switch the gate off.
test_repo_gitleaks_toml_does_not_hide_a_leak() {
  [[ -n "${GITLEAKS_TEST:-}" ]] || return 0
  local d
  d=$(leaky_tree)
  cat > "$d/.gitleaks.toml" <<'EOF'
[extend]
useDefault = true

[allowlist]
paths = ['''.*''']
EOF
  assert_exit 1 scripts/secret-scan.sh tree "$d" '' "$(mktemp -d)"
}

test_repo_gitleaksignore_does_not_hide_a_leak() {
  [[ -n "${GITLEAKS_TEST:-}" ]] || return 0
  local d out
  d=$(leaky_tree)
  out=$(mktemp -d)
  scripts/secret-scan.sh tree "$d" '' "$out" >/dev/null 2>&1 || true
  jq -r '.[].Fingerprint' "$out/gitleaks.json" > "$d/.gitleaksignore"
  [[ -s "$d/.gitleaksignore" ]]
  assert_exit 1 scripts/secret-scan.sh tree "$d" '' "$out"
}

test_gitleaks_allow_comment_does_not_hide_a_leak_in_the_tree() {
  [[ -n "${GITLEAKS_TEST:-}" ]] || return 0
  local d
  d=$(leaky_tree)
  sed -i 's/$/ # gitleaks:allow/' "$d/group_vars/all/tokens.yml"
  assert_exit 1 scripts/secret-scan.sh tree "$d" '' "$(mktemp -d)"
}

# Zabbix item keys look like generic API keys; gitleaks.toml allows exactly these.
zabbix_item_keys='          key: sma.emeter.l1_voltage
          key: sma.emeter.l2_voltage
          key: sma.emeter.l3_voltage'
# Made-up values that generic-api-key reports: the allowlist must not swallow them.
fake_keys='  key: Zq8vN3kLp7RtX2wB9mYc4HdF
  api_key: zq8vn3klp7rtx2wb9myc4hdf6s'

# as_diff LINES: a diff that adds LINES
as_diff() {
  printf 'diff --git a/t.yaml b/t.yaml\n--- a/t.yaml\n+++ b/t.yaml\n@@ -0,0 +1,3 @@\n'
  sed 's/^/+/' <<< "$1"
}

test_zabbix_item_keys_pass_in_the_tree() {
  [[ -n "${GITLEAKS_TEST:-}" ]] || return 0
  local d
  d=$(mktemp -d)
  printf '%s\n' "$zabbix_item_keys" > "$d/template.yaml"
  assert_exit 0 scripts/secret-scan.sh tree "$d" '' "$(mktemp -d)"
}

test_zabbix_item_keys_pass_in_the_diff() { # stdin mode reports no line: the allowlist targets the match
  [[ -n "${GITLEAKS_TEST:-}" ]] || return 0
  local diff
  diff=$(mktemp)
  as_diff "$zabbix_item_keys" > "$diff"
  assert_exit 0 scripts/secret-scan.sh diff "$diff" '' "$(mktemp -d)"
}

test_other_keys_still_hit_in_the_tree() {
  [[ -n "${GITLEAKS_TEST:-}" ]] || return 0
  local d out
  d=$(mktemp -d)
  out=$(mktemp -d)
  printf '%s\n' "$fake_keys" > "$d/x.yml"
  assert_exit 1 scripts/secret-scan.sh tree "$d" '' "$out"
  assert_eq 2 "$(jq length "$out/gitleaks.json")"
}

test_other_keys_still_hit_in_the_diff() {
  [[ -n "${GITLEAKS_TEST:-}" ]] || return 0
  local diff out
  diff=$(mktemp)
  out=$(mktemp -d)
  as_diff "$fake_keys" > "$diff"
  assert_exit 1 scripts/secret-scan.sh diff "$diff" '' "$out"
  assert_eq 2 "$(jq length "$out/gitleaks.json")"
}

test_gitleaks_allow_comment_does_not_hide_a_leak_in_the_diff() {
  [[ -n "${GITLEAKS_TEST:-}" ]] || return 0
  local diff
  diff=$(mktemp)
  sed 's/^\(+[a-z].*\)$/\1 # gitleaks:allow/' "$(fixture leaky.diff)" > "$diff"
  assert_exit 1 scripts/secret-scan.sh diff "$diff" '' "$(mktemp -d)"
}
