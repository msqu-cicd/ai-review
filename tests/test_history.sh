# shellcheck shell=bash
# Tests for scripts/history.sh and render_history (scripts/lib.sh). No network:
# tests/fake_curl.sh serves tests/fixtures/history/ as the Gitea API of PR 7 (a discussion)
# and PR 8 (none).

history_fake() { # PR OUT_FILE -> runs history.sh against the fixtures
  CURL_BIN="$REPO_ROOT/tests/fake_curl.sh" FAKE_API_DIR="$(fixture history)" \
    GITEA_TOKEN=x GITHUB_API_URL=https://git.example/api/v1 GITHUB_REPOSITORY=o/r \
    scripts/history.sh "$@"
}

history_of_7() { # -> path of the history file of PR 7
  local f
  f=$(mktemp -d)/history.md
  history_fake 7 "$f" > /dev/null
  printf '%s' "$f"
}

test_history_lists_ai_reviews_and_people_oldest_first() { # reviews come from two pages
  assert_eq "### Earlier AI review, posted as a comment, 2026-10-30T09:00:00Z
### Earlier AI review of commit 1111111, 2026-10-30T10:00:00Z
### Review by micha, 2026-10-30T12:00:00Z
### Comment by micha, 2026-10-30T13:00:00Z
### Earlier AI review of commit 2222222, 2026-10-31T09:00:00Z" "$(grep '^### ' "$(history_of_7)")"
}

test_history_keeps_replies_with_the_inline_comment() { # Gitea files a reply under the review it answers
  local f
  f=$(history_of_7)
  grep -A4 '^On tasks/main.yml:30 (resolved by micha):$' "$f" | grep -q '^> The play escalates at play level. REPLY-MARKER$'
  grep -q '^On tasks/main.yml (old line 20):$' "$f"
}

test_history_leaves_out_commands_notices_pending_and_dismissed() {
  local f
  f=$(history_of_7)
  grep -q 'COMMENT-MARKER' "$f"
  assert_exit 1 grep -qE 'PENDING-MARKER|DISMISSED-MARKER|AI review failed|/review' "$f"
}

test_history_quotes_every_text() { # no comment can open a line of its own, so the headings stay ours
  assert_exit 1 grep -vE '^(### |> |On |Inline comments:$|micha, |$)' "$(history_of_7)"
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
