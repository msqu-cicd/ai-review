# shellcheck shell=bash
# shellcheck disable=SC2016 # the history renderer wraps API fields in literal backticks
# Tests for the cost estimate helpers in scripts/lib.sh (build_cost_record, cost_log_line,
# cost_comment, cost_records) and scripts/cost-report.sh; review.sh and post.sh are covered in
# test_scripts.sh. No network: the report
# runs against tests/fake_tea.sh, which serves tests/fixtures/cost/ as the Gitea API. There,
# Ansible/blocky holds records A (PR 7, 2026-10-30, opus with a side model, $0.50), B (re-review
# of PR 7 with sonnet, 2026-11-02, $0.20), C (audit issue, 2026-10-31, $1.25), D (failure notice
# on PR 8, 2026-10-31, no modelUsage, $0.30) and A again in a comment; Infrastructure/dns holds E
# (2026-10-29, no estimate). Records by other users, inside a line or broken never count.

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

test_cost_comment_cannot_be_closed_early() {
  local f line l
  f=$(mktemp)
  l=$(mktemp)
  echo '{"repo": "a--><script>x</script>", "total_cost_usd": 1}' > "$f"
  line=$(cost_comment "$f")
  assert_eq 1 "$(grep -o '>' <<<"$line" | wc -l | tr -d ' ')" "only the closing > of the comment"
  jq -n --arg b "$line" '[{user: {login: "gitea-actions"}, body: $b}]' > "$l"
  assert_json_eq "$(cat "$f")" "$(cost_records "$l" gitea-actions)"
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

report() { # API_DIR ARGS... -> cost-report.sh against API_DIR
  local dir=$1
  shift
  TEA_BIN="$REPO_ROOT/tests/fake_tea.sh" FAKE_API_DIR="$dir" scripts/cost-report.sh "$@"
}

rows() { # GROUP REPORT -> "KEY RUNS COST" per row of GROUP
  awk -v g="$1" '$1 == g { print $2, $3, $4 }' <<<"$2"
}

api_copy() { # -> a writable copy of tests/fixtures/cost
  local d
  d=$(mktemp -d)
  cp "$(fixture cost)"/*.json "$d"
  printf '%s' "$d"
}

test_cost_report_totals() { # fake_tea exits 3 on anything but a GET, so a clean run never wrote
  local out
  out=$(report "$(fixture cost)")
  assert_eq $'2026-10 4 2.05\n2026-11 1 0.20' "$(rows month "$out")"
  assert_eq $'claude-haiku-5-5 1 0.05\nclaude-opus-5-5 2 1.70\nclaude-sonnet-5-5 1 0.20\nopus 2 0.30' "$(rows model "$out")"
  assert_eq $'audit 1 1.25\ncomment 1 0.20\npr 3 0.80' "$(rows mode "$out")"
  assert_eq 'all 5 2.25 3800 850 12000 1600' "$(awk '$1 == "total" { print $2, $3, $4, $5, $6, $7, $8 }' <<<"$out")"
  grep -q '^Runs without a cost estimate: 1 (counted in runs, not in cost).$' <<<"$out"
  grep -q 'not what the subscription charges' <<<"$out"
}

test_cost_report_counts_only_the_bots_own_lines() { # mallory's $100, micha's $9.25, inline and broken records
  local d
  d=$(api_copy)
  jq 'map(select(.id != 2 and .id != 5))' "$d/repos_Ansible_blocky_pulls_7_reviews_limit_50_page_1.json" > "$d/x"
  mv "$d/x" "$d/repos_Ansible_blocky_pulls_7_reviews_limit_50_page_1.json"
  jq 'map(select(.id != 32))' "$d/repos_Ansible_blocky_issues_comments_limit_50_page_1.json" > "$d/x"
  mv "$d/x" "$d/repos_Ansible_blocky_issues_comments_limit_50_page_1.json"
  # left: C (audit), D (failure notice), E (no estimate)
  assert_eq 'all 3 1.55' "$(rows total "$(report "$d" Ansible Infrastructure)")"
}

test_cost_report_since() { # the API filter is passed on, and older records are dropped
  local d f out
  d=$(api_copy)
  for f in "$d"/repos_*_issues_*limit_50_page_1.json; do
    mv "$f" "${f/limit_50/since_2026-10-31T00_00_00Z_limit_50}"
  done
  out=$(report "$d" --since 2026-10-31)
  assert_eq $'2026-10 2 1.55\n2026-11 1 0.20' "$(rows month "$out")"
  assert_eq 'all 3 1.75' "$(rows total "$out")"
  grep -q '^Orgs: Ansible Infrastructure DevOps CICD; runs since 2026-10-31$' <<<"$out"
}

test_cost_report_reads_every_page() {
  local d
  d=$(api_copy)
  jq -n '[range(50) | {id: (100 + .), user: {login: "gitea-actions"}, body: "## AI review (opus)\n\nNo record."}]' \
    > "$d/repos_Ansible_blocky_pulls_8_reviews_limit_50_page_1.json"
  jq -n --arg b "<!-- ai-review-cost: {\"mode\":\"pr\",\"model\":\"opus\",\"timestamp\":\"2026-10-31T13:00:00Z\",\"total_cost_usd\":0.4} -->" \
    '[{id: 200, user: {login: "gitea-actions"}, body: $b}]' > "$d/repos_Ansible_blocky_pulls_8_reviews_limit_50_page_2.json"
  assert_eq 'all 6 2.65' "$(rows total "$(report "$d")")"
}

test_cost_report_api_failure_is_reported() { # tea api exits 0 on an HTTP error; the error object gives it away
  local d out rc=0
  d=$(api_copy)
  rm "$d/repos_Ansible_blocky_pulls_8_reviews_limit_50_page_1.json"
  out=$(report "$d" 2> "$d/err") || rc=$?
  assert_eq 1 "$rc"
  grep -q 'could not read the reviews of Ansible/blocky#8' "$d/err"
  assert_eq 'all 5 2.25' "$(rows total "$out")"
}

test_cost_report_without_records() {
  local out
  out=$(report "$(fixture cost)" DevOps)
  grep -q '^No cost records found.$' <<<"$out"
}

test_cost_report_rejects_bad_arguments() {
  assert_exit 2 report "$(fixture cost)" --since 2026-13-01
  assert_exit 2 report "$(fixture cost)" --since
  assert_exit 2 report "$(fixture cost)" --verbose
  assert_exit 2 report "$(fixture cost)" 'Ansible/blocky'
}
