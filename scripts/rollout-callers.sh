#!/usr/bin/env bash
# Add the caller workflow to many repositories from the workstation.
#
# Usage: rollout-callers.sh REPO_LIST_FILE [--push-main] [--dry-run]
#   REPO_LIST_FILE  one "Owner/name" per line, "#" comments and blank lines ignored
#   --push-main     commit the caller straight to the default branch instead of opening a PR
#   --dry-run       only report which repositories would get the caller
# Default: branch ai-review-caller, commit "Add the AI review caller workflow", push, open the
# PR "Add AI review" via `tea api --login git`. Repositories that already carry
# .gitea/workflows/ai-review.yml on their default branch are skipped.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
caller="$(dirname "$here")/examples/caller-ai-review.yml"
ssh_base="ssh://git@git.msqu.de:22222"

usage() { echo "usage: rollout-callers.sh REPO_LIST_FILE [--push-main] [--dry-run]" >&2; exit 2; }
[[ $# -ge 1 ]] || usage
list=$1
shift
push_main="" dry=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --push-main) push_main=1; shift ;;
    --dry-run) dry=1; shift ;;
    *) usage ;;
  esac
done
[[ -f $list && -f $caller ]] || usage

mapfile -t repos < <(sed -e 's/[[:space:]]*#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$list" | grep -v '^$')

pr_body='Adds the caller for the shared AI review workflow (https://git.msqu.de/CICD/ai-review): Claude Code reviews pull requests when they are opened or reopened and on a `/review` comment, and audits the whole repository on workflow_dispatch. The org secret CLAUDE_CODE_OAUTH_TOKEN is already in place.'

for repo in "${repos[@]}"; do
  tmp=$(mktemp -d)
  if ! git clone -q "$ssh_base/$repo.git" "$tmp/src" 2> /dev/null; then
    echo "FAILED clone $repo" >&2
    rm -rf "$tmp"
    continue
  fi
  default=$(git -C "$tmp/src" symbolic-ref --short HEAD)
  if [[ -f $tmp/src/.gitea/workflows/ai-review.yml ]]; then
    echo "skip $repo (caller already on $default)"
    rm -rf "$tmp"
    continue
  fi
  if [[ -n $dry ]]; then
    echo "would add the caller to $repo (default branch $default)"
    rm -rf "$tmp"
    continue
  fi
  branch=$default
  if [[ -z $push_main ]]; then
    branch=ai-review-caller
    git -C "$tmp/src" checkout -q -b "$branch"
  fi
  mkdir -p "$tmp/src/.gitea/workflows"
  cp "$caller" "$tmp/src/.gitea/workflows/ai-review.yml"
  git -C "$tmp/src" add .gitea/workflows/ai-review.yml
  git -C "$tmp/src" commit -q -m "Add the AI review caller workflow"
  git -C "$tmp/src" push -q -u origin "$branch" 2> /dev/null
  if [[ -n $push_main ]]; then
    echo "done $repo: pushed to $default"
  else
    payload=$(jq -n --arg head "$branch" --arg base "$default" --arg body "$pr_body" \
      '{head: $head, base: $base, title: "Add AI review", body: $body}')
    url=$(tea api --login git -X POST "repos/$repo/pulls" -d "$payload" | jq -r '.html_url // "PR creation failed"')
    echo "done $repo: $url"
  fi
  rm -rf "$tmp"
done
