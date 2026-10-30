# shellcheck shell=bash
# Tests for parse_review_command and gate_decide (scripts/lib.sh).

gate() { # EVENT FIXTURE [SKIP_AUTHORS] -> gate_decide output
  gate_decide "$1" "$(fixture "$2")" "${3:-renovate,gitea-actions}" Ansible/blocky
}

test_parse_plain_review() {
  assert_eq "comment opus" "$(parse_review_command '/review')"
}

test_parse_sonnet_audit() {
  assert_eq "audit sonnet" "$(parse_review_command '/review sonnet audit')"
}

test_parse_rejects_prose() {
  assert_exit 1 parse_review_command 'please /review this'
}

test_parse_rejects_other_model() {
  assert_exit 1 parse_review_command '/review haiku'
}

test_gate_pr_opened_runs() {
  assert_eq 'true pr opus 6' "$(gate pull_request event_pr_opened.json | jq -r '[.run,.mode,.model,.pr_number]|join(" ")')"
}

test_gate_pr_draft_skips() {
  assert_eq false "$(gate pull_request event_pr_draft.json renovate | jq -r .run)"
}

test_gate_pr_renovate_skips() {
  assert_eq false "$(gate pull_request event_pr_renovate.json | jq -r .run)"
}

test_gate_pr_fork_skips() {
  assert_eq false "$(gate pull_request event_pr_fork.json renovate | jq -r .run)"
}

test_gate_comment_review_runs() {
  assert_eq 'true comment opus 6' "$(gate issue_comment event_comment_review.json renovate | jq -r '[.run,.mode,.model,.pr_number]|join(" ")')"
}

test_gate_comment_sonnet_audit() {
  assert_eq 'audit sonnet' "$(gate issue_comment event_comment_review_sonnet_audit.json renovate | jq -r '[.mode,.model]|join(" ")')"
}

test_gate_comment_not_pr_skips() {
  assert_eq 'false not a pull request' "$(gate issue_comment event_comment_not_pr.json renovate | jq -r '[.run,.reason]|join(" ")')"
}

test_gate_comment_other_skips() {
  assert_eq false "$(gate issue_comment event_comment_other_text.json renovate | jq -r .run)"
}

test_gate_dispatch_audit() {
  assert_eq 'true audit opus null' "$(gate workflow_dispatch event_dispatch_audit.json renovate | jq -r '[.run,.mode,.model,(.pr_number|tostring)]|join(" ")')"
}

test_gate_unknown_event() {
  assert_eq false "$(gate push event_pr_opened.json renovate | jq -r .run)"
}

test_gate_dispatch_rejects_bad_model() {
  local f
  f=$(mktemp)
  jq '.inputs.model = "haiku"' "$(fixture event_dispatch_audit.json)" > "$f"
  assert_eq 'false unsupported model haiku' "$(gate_decide workflow_dispatch "$f" renovate Ansible/blocky | jq -r '[.run,.reason]|join(" ")')"
}
