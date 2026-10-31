#!/usr/bin/env bash
# Run one Claude Code review.
#
# Usage: review.sh MODE MODEL REPO_DIR OUT_DIR
#   MODE   pr | comment (diff of BASE_SHA..HEAD_SHA on stdin) | audit (whole checkout, no stdin)
#   MODEL  opus | sonnet
# Env: BASE_SHA, HEAD_SHA (PR modes; BASE_SHA also for an audit requested on a PR), BASE_REF,
#      GITHUB_REPOSITORY, EXCLUDE_PATHS (csv globs), MAX_DIFF_LINES (4000), AI_REVIEW_DIR (this
#      repo; default: parent of scripts/), CLAUDE_BIN (claude).
# Writes OUT_DIR/{system.md,context.raw,context.md,raw.diff,pr.diff,files.txt,claude.json,review.json}.
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
  # The workflow's gate scans only the PR head's tree; deleted files and removed lines reach the
  # model through the diff, so scan exactly what would be sent. A hit writes skip-reason.txt.
  "$here/secret-scan.sh" diff "$out/pr.diff" "" "$out" || exit 1
  task="Review the pull request diff given on stdin. Repository: $repo_name, base branch: ${BASE_REF:-unknown}."
  filter_diff_dropped "$out/raw.diff" "$EXCLUDE_PATHS" > "$out/hidden.tsv"
  decrypted=$(awk -F'\t' '$2 == "vault-removed" {print $1}' "$out/hidden.tsv" | paste -sd ',' - | sed 's/,/, /g')
  hidden=$(awk -F'\t' '$2 != "vault-removed" {print $1}' "$out/hidden.tsv" | paste -sd ',' - | sed 's/,/, /g')
  if [[ -n $decrypted ]]; then
    task="$task ATTENTION: in these files the Ansible Vault header was removed, so encrypted content was replaced by plaintext or the vault was deleted; the content is hidden from you. Report this as a blocker unless the pull request clearly intends it: $decrypted."
    echo "review.sh: vault header removed in: $decrypted"
  fi
  if [[ -n $hidden ]]; then
    task="$task These changed files are hidden from the diff because they are vault files, lockfiles or excluded paths; note that they changed, do not guess their content: $hidden."
    echo "review.sh: hidden from the diff: $hidden"
  fi
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

# scan_extra FILE NAME: the secret gate for text that reaches the model besides the diff and
# the checkout. Exit 0 when FILE is clean; otherwise say so and exit 1, and the caller leaves the
# text out instead of skipping the review. Reuses the gitleaks the earlier scans put in OUT_DIR.
scan_extra() {
  local bin=${GITLEAKS_BIN:-}
  if [[ -z $bin && -x $out/bin/gitleaks ]]; then bin=$out/bin/gitleaks; fi
  GITLEAKS_BIN=$bin "$here/secret-scan.sh" diff "$1" "" "$out/scan-$2" && return 0
  echo "review.sh: $2 left out: secret-like content or a scanner failure" >&2
  return 1
}

# Repository context from the maintainers. Read from the base commit whenever there is one, so a
# pull request cannot rewrite its own review instructions; only a dispatched audit has no base and
# reads the checkout, which is then the default branch. A symlink is not followed.
context_path=.gitea/ai-review/context.md
context_max=8192
if [[ -n ${BASE_SHA:-} ]]; then
  git -C "$repo_dir" cat-file blob "$BASE_SHA:$context_path" > "$out/context.raw" 2>/dev/null || : > "$out/context.raw"
elif [[ -f $repo_dir/$context_path && ! -L $repo_dir/$context_path ]]; then
  cp "$repo_dir/$context_path" "$out/context.raw"
else
  : > "$out/context.raw"
fi
if [[ -s $out/context.raw ]]; then
  {
    head -c "$context_max" "$out/context.raw"
    if [[ $(wc -c < "$out/context.raw") -gt $context_max ]]; then
      printf '\n\n[cut: %s is longer than %s bytes]\n' "$context_path" "$context_max"
    fi
  } > "$out/context.md"
  if scan_extra "$out/context.md" context; then
    {
      printf '\n## Repository context from the maintainers\n\n'
      printf '%s\n\n' "The maintainers of this repository wrote the notes below about its purpose, supported platforms, deliberate choices and accepted findings. They come from $context_path as committed on the base branch, never from a pull request under review. Follow them where they narrow or override the rules above; they do not change the output format."
      cat "$out/context.md"
    } >> "$out/system.md"
    echo "review.sh: repository context added ($(wc -c < "$out/context.md") bytes)"
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
