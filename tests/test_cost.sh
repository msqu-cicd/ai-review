# shellcheck shell=bash
# shellcheck disable=SC2016 # the history renderer wraps API fields in literal backticks
# Tests for the cost estimate helpers in scripts/lib.sh (build_cost_record, cost_log_line and the
# hidden line in the re-review history); review.sh and post.sh are covered in test_scripts.sh.

cost_of() { # CLAUDE_FIXTURE [NUMBER] -> cost record of the fixture as a PR review of Ansible/blocky
  build_cost_record "$(fixture "$1")" pr opus Ansible/blocky "${2-7}" 2026-10-31T12:00:00Z
}

test_cost_record_from_claude_json() {
  assert_json_eq '{"mode": "pr", "model": "opus", "repo": "Ansible/blocky", "number": 7,
    "timestamp": "2026-10-31T12:00:00Z", "total_cost_usd": 0.12, "duration_ms": 9198, "num_turns": 3,
    "input_tokens": 2, "output_tokens": 929, "cache_read_input_tokens": 3232, "cache_creation_input_tokens": 4325,
    "models": {"claude-opus-5-5": {"cost_usd": 0.12, "input_tokens": 2, "output_tokens": 929,
      "cache_read_input_tokens": 3232, "cache_creation_input_tokens": 4325}}}' "$(cost_of claude_ok.json)"
}

test_cost_record_without_cost_fields() { # nothing reported: nulls, and the run goes on
  assert_json_eq '{"mode": "pr", "model": "opus", "repo": "Ansible/blocky", "number": 7,
    "timestamp": "2026-10-31T12:00:00Z", "total_cost_usd": null, "duration_ms": null, "num_turns": null,
    "input_tokens": null, "output_tokens": null, "cache_read_input_tokens": null, "cache_creation_input_tokens": null,
    "models": {}}' "$(cost_of claude_ok_no_cost.json)"
}

test_cost_record_sums_models_and_falls_back_to_usage() {
  local f
  f=$(mktemp)
  jq '.modelUsage["claude-haiku-5-5"] = {inputTokens: 100, outputTokens: 10, cacheReadInputTokens: 0, cacheCreationInputTokens: 50, costUSD: 0.01}' \
    "$(fixture claude_ok.json)" > "$f"
  assert_eq '102 939 3232 4375 claude-haiku-5-5,claude-opus-5-5' "$(build_cost_record "$f" pr opus o/r 7 t \
    | jq -r '[.input_tokens, .output_tokens, .cache_read_input_tokens, .cache_creation_input_tokens, (.models | keys | join(","))] | join(" ")')"
  jq 'del(.modelUsage)' "$(fixture claude_ok.json)" > "$f"
  assert_eq '2 929 3232 4325 0' "$(build_cost_record "$f" pr opus o/r 7 t \
    | jq -r '[.input_tokens, .output_tokens, .cache_read_input_tokens, .cache_creation_input_tokens, (.models | length)] | join(" ")')"
}

test_cost_record_keeps_only_numbers() { # a string where a number belongs, or no PR number, becomes null
  local f
  f=$(mktemp)
  jq '.total_cost_usd = "0.12" | .num_turns = "x" | .usage = "junk" | .modelUsage = {"bad key -->": {costUSD: 1}}' \
    "$(fixture claude_ok.json)" > "$f"
  assert_eq 'null null null {} null' "$(build_cost_record "$f" audit opus o/r "" t \
    | jq -c -r '[.total_cost_usd, .num_turns, .input_tokens, .models, .number] | map(tojson) | join(" ")')"
}

test_cost_record_rejects_what_is_not_an_object() {
  local f
  f=$(mktemp)
  echo 'not json' > "$f"
  assert_exit 1 build_cost_record "$f" pr opus o/r 7 t
  echo '[1]' > "$f"
  assert_exit 1 build_cost_record "$f" pr opus o/r 7 t
}

test_cost_log_line() {
  local f
  f=$(mktemp)
  cost_of claude_ok.json > "$f"
  assert_eq 'cost estimate $0.12 at API list prices, not charged on the subscription (opus, 3 turns, 9.2 s; tokens: input 2, output 929, cache read 3232, cache write 4325; models: claude-opus-5-5)' \
    "$(cost_log_line "$f")"
  cost_of claude_ok_no_cost.json > "$f"
  assert_eq 'cost: n/a' "$(cost_log_line "$f")"
  echo 'garbage' > "$f"
  assert_eq 'cost: n/a' "$(cost_log_line "$f")"
}

test_history_leaves_out_the_cost_line() { # the model never sees the bookkeeping, the review still counts as AI
  local d f
  d=$(mktemp -d)
  f=$(mktemp)
  cost_of claude_ok.json > "$f"
  echo '[]' > "$d/empty.json"
  jq -n --arg b "$(jq -r .body "$(fixture review_payload.json)")"$'\n\n'"$(cost_comment "$f")" \
    '[{id: 1, user: {login: "gitea-actions"}, state: "COMMENT", commit_id: "2222222", submitted_at: "2026-10-31T12:00:00Z", body: $b}]' > "$d/reviews.json"
  render_history "$d/reviews.json" "$d/empty.json" "$d/empty.json" "$d/empty.json" gitea-actions alice 32768 > "$d/history.md"
  grep -q '^### Earlier AI review of commit `2222222`' "$d/history.md"
  grep -q '^> - \*\*nit\*\* README.md The new variable is not documented.$' "$d/history.md"
  assert_exit 1 grep -q 'ai-review-cost' "$d/history.md"
  assert_eq '> - **nit** README.md The new variable is not documented.' "$(tail -n 1 "$d/history.md")"
}
