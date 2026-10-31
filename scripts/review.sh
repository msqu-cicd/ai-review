#!/usr/bin/env bash
# Run one Claude Code review.
#
# Usage: review.sh MODE MODEL REPO_DIR OUT_DIR
#   MODE   pr | comment (diff of BASE_SHA..HEAD_SHA on stdin) | audit (whole checkout, no stdin)
#   MODEL  opus | sonnet
# Env: BASE_SHA, HEAD_SHA (PR modes), BASE_REF, GITHUB_REPOSITORY, EXCLUDE_PATHS (csv globs),
#      MAX_DIFF_LINES (4000), AI_REVIEW_DIR (this repo; default: parent of scripts/),
#      CLAUDE_BIN (claude). Writes OUT_DIR/{system.md,raw.diff,pr.diff,files.txt,claude.json,review.json}.
# Exit 1 when Claude fails or returns no valid structured output; OUT_DIR/review.json is the result.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

usage() { echo "usage: review.sh pr|comment|audit opus|sonnet REPO_DIR OUT_DIR" >&2; exit 2; }
[[ $# -eq 4 ]] || usage
mode=$1 model=$2 repo_dir=$3 out=$4
case $mode in pr | comment | audit) ;; *) usage ;; esac
case $model in opus | sonnet) ;; *) echo "review.sh: unsupported model $model" >&2; exit 2 ;; esac
[[ -d $repo_dir ]] || { echo "review.sh: $repo_dir is not a directory" >&2; exit 2; }
# claude runs inside REPO_DIR, so every other path must be absolute.
mkdir -p "$out"
out=$(cd "$out" && pwd)
repo_dir=$(cd "$repo_dir" && pwd)

AI_REVIEW_DIR=${AI_REVIEW_DIR:-$(dirname "$here")}
AI_REVIEW_DIR=$(cd "$AI_REVIEW_DIR" && pwd)
CLAUDE_BIN=${CLAUDE_BIN:-claude}
MAX_DIFF_LINES=${MAX_DIFF_LINES:-4000}
EXCLUDE_PATHS=${EXCLUDE_PATHS:-}
repo_name=${GITHUB_REPOSITORY:-$(basename "$repo_dir")}

# System prompt: mode prompt plus the Ansible convention list when the checkout is Ansible.
if [[ $mode == audit ]]; then
  cat "$AI_REVIEW_DIR/prompts/repo-audit.md" > "$out/system.md"
else
  cat "$AI_REVIEW_DIR/prompts/pr-review.md" > "$out/system.md"
fi
if [[ -f $repo_dir/meta/main.yml || -f $repo_dir/ansible.cfg ]]; then
  { printf '\n'; cat "$AI_REVIEW_DIR/prompts/ansible-role.md"; } >> "$out/system.md"
fi

stdin_file=/dev/null
if [[ $mode == audit ]]; then
  task="Audit this repository as a whole. Repository: $repo_name."
else
  : "${BASE_SHA:?BASE_SHA is required in $mode mode}" "${HEAD_SHA:?HEAD_SHA is required in $mode mode}"
  git -C "$repo_dir" fetch -q origin "$BASE_SHA" "$HEAD_SHA" 2>/dev/null || true
  for sha in "$BASE_SHA" "$HEAD_SHA"; do
    git -C "$repo_dir" cat-file -e "$sha^{commit}" 2>/dev/null \
      || { echo "review.sh: commit $sha is not available in $repo_dir" >&2; exit 1; }
  done
  # Three dots: changes since the merge base, so commits that landed on the base branch after
  # the PR branched never show up as phantom reversals.
  git -C "$repo_dir" diff "$BASE_SHA...$HEAD_SHA" > "$out/raw.diff"
  filter_diff "$out/raw.diff" "$EXCLUDE_PATHS" > "$out/pr.diff"
  task="Review the pull request diff given on stdin. Repository: $repo_name, base branch: ${BASE_REF:-unknown}."
  if diff_too_large "$out/pr.diff" "$MAX_DIFF_LINES"; then
    diff_file_list "$out/pr.diff" > "$out/files.txt"
    stdin_file="$out/files.txt"
    task="Review the pull request. Only the list of changed files is available on stdin because the diff is too large; review the changes from the checkout. Repository: $repo_name, base branch: ${BASE_REF:-unknown}."
    echo "review.sh: filtered diff has $(wc -l < "$out/pr.diff") lines (> $MAX_DIFF_LINES), sending the file list"
  else
    stdin_file="$out/pr.diff"
    echo "review.sh: filtered diff has $(wc -l < "$out/pr.diff") lines"
  fi
fi

rc=0
(
  cd "$repo_dir"
  "$CLAUDE_BIN" --restricted --tools "Read,Grep,Glob" --permission-mode dontAsk \
    --model "$model" --max-turns 40 --output-format json \
    --json-schema "$(cat "$AI_REVIEW_DIR/schema/review.json")" \
    --append-system-prompt-file "$out/system.md" \
    -p "$task" < "$stdin_file" > "$out/claude.json"
) || rc=$?

if [[ -s $out/claude.json ]]; then
  jq '{models: ((.modelUsage // {}) | keys), turns: .num_turns, duration_ms, is_error,
       usage: ((.usage // {}) | {input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens})}' \
    "$out/claude.json" 2>/dev/null || echo "review.sh: claude.json is not JSON" >&2
fi
if [[ $rc -ne 0 ]]; then
  echo "review.sh: claude exited $rc" >&2
  exit 1
fi

validate_claude_output "$out/claude.json" > "$out/review.json"
echo "review.sh: review.json written ($(jq '.findings | length' "$out/review.json") findings, verdict $(jq -r .verdict "$out/review.json"))"
