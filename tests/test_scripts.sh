# shellcheck shell=bash
# Tests for scripts/review.sh and scripts/post.sh. No network and no real claude:
# post.sh runs in dry-run mode, review.sh gets tests/fake_claude.sh as CLAUDE_BIN.

post_dry() { # KIND ARGS... -> dry-run output of post.sh
  AI_REVIEW_DRY_RUN=1 GITEA_TOKEN=x GITHUB_API_URL=https://git.example/api/v1 GITHUB_REPOSITORY=o/r \
    scripts/post.sh "$@"
}

review_fake() { # CLAUDE_FIXTURE MODE REPO_DIR OUT_DIR [ARGS_FILE] -> runs review.sh with the fake claude
  local fixture=$1 mode=$2 repo=$3 out=$4 args=${5:-}
  CLAUDE_BIN="$REPO_ROOT/tests/fake_claude.sh" FAKE_CLAUDE_OUTPUT="$(fixture "$fixture")" \
    FAKE_CLAUDE_ARGS_FILE="$args" BASE_SHA=HEAD~1 HEAD_SHA=HEAD AI_REVIEW_DIR="$REPO_ROOT" \
    GITLEAKS_BIN="${GITLEAKS_BIN-/bin/true}" \
    scripts/review.sh "$mode" opus "$repo" "$out"
}

two_commit_repo() { # -> path of a temporary git repo with two commits (CI checkouts are shallow)
  local r
  r=$(mktemp -d)
  git -C "$r" init -q
  echo "a: 1" > "$r/vars.yml"
  git -C "$r" add -A
  git -C "$r" -c user.name=t -c user.email=t@t commit -qm first
  echo "a: 2" > "$r/vars.yml"
  git -C "$r" add -A
  git -C "$r" -c user.name=t -c user.email=t@t commit -qm second
  printf '%s' "$r"
}

# grep -q would close the pipe before post.sh finishes printing the payload, so capture first.
test_post_review_dry_run_url() {
  local out
  out=$(post_dry review 6 "$(fixture review_payload.json)")
  grep -q '^POST https://git.example/api/v1/repos/o/r/pulls/6/reviews$' <<<"$out"
}

test_post_comment_dry_run_url() {
  local t out
  t=$(mktemp)
  echo hi > "$t"
  out=$(post_dry comment 6 "$t")
  grep -q '/issues/6/comments$' <<<"$out"
}

test_post_issue_dry_run_url() {
  local out
  out=$(post_dry issue "$(fixture issue_payload.json)")
  grep -q '/repos/o/r/issues$' <<<"$out"
}

test_post_unknown_kind_fails() {
  assert_exit 2 scripts/post.sh bogus
}

test_review_fails_on_is_error() {
  local d
  d=$(mktemp -d)
  assert_exit 1 review_fake claude_is_error.json pr "$(two_commit_repo)" "$d"
}

test_review_writes_review_json() {
  local d
  d=$(mktemp -d)
  review_fake claude_ok.json pr "$(two_commit_repo)" "$d" > /dev/null
  assert_eq request_changes "$(jq -r .verdict "$d/review.json")"
}

test_review_diff_excludes_base_only_changes() { # merge-base diff: commits on main after branching are not PR changes
  local r d
  r=$(two_commit_repo)
  d=$(mktemp -d)
  git -C "$r" checkout -q -b feature
  echo "f: 1" > "$r/feature.yml"
  git -C "$r" add -A
  git -C "$r" -c user.name=t -c user.email=t@t commit -qm feature
  git -C "$r" checkout -q -
  echo "m: 1" > "$r/on_main.yml"
  git -C "$r" add -A
  git -C "$r" -c user.name=t -c user.email=t@t commit -qm "on main"
  CLAUDE_BIN="$REPO_ROOT/tests/fake_claude.sh" FAKE_CLAUDE_OUTPUT="$(fixture claude_ok.json)" \
    BASE_SHA=$(git -C "$r" rev-parse HEAD) HEAD_SHA=$(git -C "$r" rev-parse feature) AI_REVIEW_DIR="$REPO_ROOT" \
    GITLEAKS_BIN=/bin/true \
    scripts/review.sh pr opus "$r" "$d" > /dev/null
  grep -q 'feature.yml' "$d/raw.diff"
  ! grep -q 'on_main.yml' "$d/raw.diff"
}

test_review_skips_when_the_diff_scan_hits() { # the model is never called
  local r d
  r=$(two_commit_repo)
  d=$(mktemp -d)
  GITLEAKS_BIN=/bin/false assert_exit 1 review_fake claude_ok.json pr "$r" "$d" "$d/args"
  grep -q 'AI review skipped: secret-like content' "$d/skip-reason.txt"
  [[ ! -e "$d/args" && ! -e "$d/review.json" ]]
}

test_review_skips_on_a_secret_in_a_deleted_file() { # the head tree is clean, only the diff shows it
  [[ -n "${GITLEAKS_TEST:-}" ]] || return 0
  local r d
  r=$(mktemp -d)
  d=$(mktemp -d)
  git -C "$r" init -q
  grep '^+[^+]' "$(fixture leaky.diff)" | cut -c2- > "$r/tokens.yml"
  git -C "$r" add -A
  git -C "$r" -c user.name=t -c user.email=t@t commit -qm first
  git -C "$r" rm -q tokens.yml
  git -C "$r" -c user.name=t -c user.email=t@t commit -qm second
  GITLEAKS_BIN='' assert_exit 1 review_fake claude_ok.json pr "$r" "$d" "$d/args"
  grep -q 'AI review skipped: secret-like content' "$d/skip-reason.txt"
  [[ ! -e "$d/args" ]]
}

test_review_accepts_relative_out_dir() { # the workflow passes "repo" and "out" relative to the workspace
  local r w
  r=$(two_commit_repo)
  w=$(mktemp -d)
  (
    cd "$w" || exit 1
    CLAUDE_BIN="$REPO_ROOT/tests/fake_claude.sh" FAKE_CLAUDE_OUTPUT="$(fixture claude_ok.json)" \
      BASE_SHA=HEAD~1 HEAD_SHA=HEAD AI_REVIEW_DIR="$REPO_ROOT" GITLEAKS_BIN=/bin/true \
      "$REPO_ROOT/scripts/review.sh" pr opus "$r" out > /dev/null
  )
  [[ -s "$w/out/review.json" ]]
}

test_review_uses_ansible_prompt() {
  local d r
  d=$(mktemp -d)
  r=$(mktemp -d)
  git -C "$r" init -q
  mkdir "$r/meta"
  : > "$r/meta/main.yml"
  git -C "$r" add -A
  git -C "$r" -c user.name=t -c user.email=t@t commit -qm init
  review_fake claude_ok.json audit "$r" "$d" > /dev/null
  grep -q 'argument_specs' "$d/system.md"
}

test_review_passes_restricted_flags() {
  local d args
  d=$(mktemp -d)
  args=$(mktemp)
  review_fake claude_ok.json pr "$(two_commit_repo)" "$d" "$args" > /dev/null
  local joined
  joined=$(tr '\n' ' ' < "$args")
  [[ $joined == *"--restricted "* ]]
  [[ $joined == *"--tools Read,Grep,Glob "* ]]
  [[ $joined == *"--permission-mode dontAsk "* ]]
  [[ $joined == *"--max-turns 40 "* ]]
  [[ $joined == *"--model opus "* ]]
}
