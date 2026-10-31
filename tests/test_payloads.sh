# shellcheck shell=bash
# Tests for validate_claude_output and the Gitea payload builders in scripts/lib.sh.

structured() { # -> path of a file holding the validated structured_output of claude_ok.json
  local f
  f=$(mktemp)
  validate_claude_output "$(fixture claude_ok.json)" > "$f"
  printf '%s' "$f"
}

pr_payload() { # -> PR review payload for claude_ok.json against sample.diff
  build_pr_review_payload "$(structured)" abc123 "$(fixture sample.diff)" opus
}

test_validate_ok_prints_structured() {
  assert_eq request_changes "$(validate_claude_output "$(fixture claude_ok.json)" | jq -r .verdict)"
}

test_validate_rejects_is_error() {
  assert_exit 1 validate_claude_output "$(fixture claude_is_error.json)"
}

test_validate_rejects_missing() {
  assert_exit 1 validate_claude_output "$(fixture claude_no_structured.json)"
}

test_comment_payload() {
  assert_json_eq '{"body":"hi"}' "$(build_comment_payload hi)"
}

test_pr_review_is_comment_event() {
  assert_eq COMMENT "$(pr_payload | jq -r .event)"
}

test_pr_review_places_only_diff_lines() {
  assert_eq '1 12' "$(pr_payload | jq -r '[(.comments|length), .comments[0].new_position]|join(" ")')"
}

test_pr_review_body_lists_unplaced() {
  pr_payload | jq -r .body | grep -q 'tasks/main.yml:99'
}

test_pr_review_body_changes_requested() {
  pr_payload | jq -r .body | grep -q '^\*\*Changes requested\*\*'
}

# The line follows the severities, so a verdict that disagrees with the findings cannot show it.
test_pr_review_no_changes_requested_without_blocker_or_major() {
  local r body
  r=$(mktemp)
  jq '.findings |= map(select(.severity != "major"))' "$(structured)" > "$r"
  assert_eq request_changes "$(jq -r .verdict "$r")"
  body=$(build_pr_review_payload "$r" abc123 "$(fixture sample.diff)" opus | jq -r .body)
  assert_exit 1 grep -q 'Changes requested' <<<"$body"
}

test_pr_review_changes_requested_on_blocker() {
  local r
  r=$(mktemp)
  jq '.verdict = "comment" | .findings = [{path: "a.yml", line: null, severity: "blocker", body: "x"}]' "$(structured)" > "$r"
  build_pr_review_payload "$r" abc123 "$(fixture sample.diff)" opus | jq -r .body | grep -q '^\*\*Changes requested\*\*'
}

test_issue_payload_title_and_label() {
  assert_eq 'AI audit 2026-11-01 (opus) 7' "$(build_issue_payload "$(structured)" 2026-11-01 opus 7 | jq -r '[.title, (.labels[0]|tostring)]|join(" ")')"
}

test_issue_payload_severity_order() {
  assert_eq $'### major\n### minor\n### nit' "$(build_issue_payload "$(structured)" 2026-11-01 opus 7 | jq -r .body | grep '^### ')"
}
