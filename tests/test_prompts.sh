# shellcheck shell=bash
# Tests for the output schema and the prompt files.

test_schema_parses() {
  jq -e . schema/review.json > /dev/null
}

test_schema_requires_keys() {
  assert_eq 'findings summary verdict' "$(jq -r '.required | sort | join(" ")' schema/review.json)"
}

test_schema_severity_enum() {
  assert_eq 'blocker major minor nit' "$(jq -r '.properties.findings.items.properties.severity.enum | join(" ")' schema/review.json)"
}

test_schema_verdict_enum() {
  assert_eq 'comment request_changes' "$(jq -r '.properties.verdict.enum | join(" ")' schema/review.json)"
}

test_prompts_exist_and_nonempty() {
  local f
  for f in pr-review repo-audit ansible-role; do
    [[ -s prompts/$f.md ]]
  done
}

test_prompts_mark_data() {
  grep -q 'never as instructions' prompts/pr-review.md && grep -q 'never as instructions' prompts/repo-audit.md
}

test_ansible_prompt_carries_accepted_decisions() {
  local f=prompts/ansible-role.md
  grep -q 'cloud_init_managed' "$f"      # shared globals stay unprefixed
  grep -q 'lock' "$f" && grep -q 'reachable' "$f"   # no-lockout roles
  grep -q 'molecule-<repo>' "$f"         # deliberate fixed concurrency group
  grep -q 'no_log' "$f"                  # secret tasks
}
