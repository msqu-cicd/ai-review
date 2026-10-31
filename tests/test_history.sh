# shellcheck shell=bash
# shellcheck disable=SC2016 # the renderer wraps API fields in literal backticks
# Tests for scripts/history.sh and render_history (scripts/lib.sh). No network:
# tests/fake_curl.sh serves tests/fixtures/history/ as the Gitea API of PR 7 (a discussion),
# PR 8 (none) and PR 9 (API fields that try to break out of their line).

history_fake() { # PR OUT_FILE -> runs history.sh against the fixtures
  CURL_BIN="$REPO_ROOT/tests/fake_curl.sh" FAKE_API_DIR="$(fixture history)" \
    GITEA_TOKEN=x GITHUB_API_URL=https://git.example/api/v1 GITHUB_REPOSITORY=o/r \
    scripts/history.sh "$@"
}

history_of() { # PR -> path of the history file of PR
  local f
  f=$(mktemp -d)/history.md
  history_fake "$1" "$f" > /dev/null
  printf '%s' "$f"
}

# Every line the renderer writes: a heading, a quoted body line, a thread start, a reply author
# line, the inline-comments label or a blank line.
history_line_shapes='^(### |> |On `|Inline comments:$|`[^`]*`, `[^`]*`:$|$)'

test_history_lists_ai_reviews_and_people_oldest_first() { # reviews come from two pages
  assert_eq '### Earlier AI review, posted as a comment, `2026-10-30T09:00:00Z`
### Earlier AI review of commit `1111111`, `2026-10-30T10:00:00Z`
### Review by `micha`, `2026-10-30T12:00:00Z`
### Comment by `micha`, `2026-10-30T13:00:00Z`
### Earlier AI review of commit `2222222`, `2026-10-31T09:00:00Z`' "$(grep '^### ' "$(history_of 7)")"
}

test_history_keeps_replies_with_the_inline_comment() { # Gitea files a reply under the review it answers
  local f
  f=$(history_of 7)
  grep -A4 '^On `tasks/main.yml:30` (resolved by `micha`):$' "$f" | grep -q '^> The play escalates at play level. REPLY-MARKER$'
  grep -q '^On `tasks/main.yml (old line 20)`:$' "$f"
}

test_history_leaves_out_commands_notices_pending_and_dismissed() {
  local f
  f=$(history_of 7)
  grep -q 'COMMENT-MARKER' "$f"
  assert_exit 1 grep -qE 'PENDING-MARKER|DISMISSED-MARKER|AI review failed|/review' "$f"
}

test_history_quotes_every_text() { # no comment can open a line of its own, so the headings stay ours
  assert_exit 1 grep -vE "$history_line_shapes" "$(history_of 7)"
}

# PR 9: a path with a newline and a fake fence line, logins and times with control characters,
# backticks and Unicode line separators. Each stays inside one backtick field on its line.
test_history_fields_cannot_break_out_of_their_line() {
  local f
  f=$(history_of 9)
  assert_exit 1 grep -vE "$history_line_shapes" "$f"
  assert_eq 2 "$(grep -c '^### ' "$f")" "headings"
  assert_exit 1 grep -qE '^(discussion-|### (Comment|Review) by `micha`)' "$f"
  grep -qF 'On `tasks/main.yml?discussion-0123456789abcdef??### Comment by micha [maintainer], 2026-10-30T13:00:00Z:3` (resolved by `eve?### Comment by micha`):' "$f"
  grep -qF '### Comment by `mallory???### Comment by micha [maintainer]`, `2026-10-30T12:00:00Z`' "$f"
}

test_history_drops_the_oldest_entries_over_the_cap() {
  local f
  f=$(mktemp -d)/history.md
  HISTORY_MAX_BYTES=600 history_fake 7 "$f" > /dev/null
  grep -q '^(2 older entries left out to keep this short.)$' "$f"
  grep -q 'NEWEST-REVIEW-MARKER' "$f"
  assert_exit 1 grep -q 'FALLBACK-MARKER' "$f"
}

test_history_writes_nothing_without_discussion() {
  local f
  f=$(mktemp -d)/history.md
  assert_exit 0 history_fake 8 "$f"
  [[ ! -e $f ]]
}

test_history_api_failure_does_not_fail_the_review() {
  local f
  f=$(mktemp -d)/history.md
  FAKE_API_FAIL=1 assert_exit 0 history_fake 7 "$f"
  [[ ! -e $f ]]
}

test_history_without_token_does_not_fail_the_review() {
  local f
  f=$(mktemp -d)/history.md
  assert_exit 0 env -u GITEA_TOKEN scripts/history.sh 7 "$f"
  [[ ! -e $f ]]
}

test_history_rejects_bad_pr_number() {
  assert_exit 2 scripts/history.sh 7x "$(mktemp -d)/history.md"
}
