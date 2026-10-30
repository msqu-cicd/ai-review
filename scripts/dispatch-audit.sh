#!/usr/bin/env bash
# Dispatch whole-repository audits in batches from the workstation and wait for each batch.
#
# Usage: dispatch-audit.sh REPO_LIST_FILE [--batch N] [--pause SECONDS] [--model opus|sonnet]
#                          [--ref REF] [--dry-run]
#   REPO_LIST_FILE  one "Owner/name" per line, "#" comments and blank lines ignored
#   --batch         repos per batch (default 5, within the combined runner capacity of 10)
#   --pause         seconds between batches (default 1200), time for the subscription window
#   --model         opus (default) or sonnet
#   --ref           ref to dispatch on (default: each repo's default branch)
#   --dry-run       print the batches and exit
# Each repo needs the caller workflow (.gitea/workflows/ai-review.yml) on the dispatched ref.
# Uses `tea api --login git`. Exit 1 when any run did not conclude with success.
set -euo pipefail

usage() {
  echo "usage: dispatch-audit.sh REPO_LIST_FILE [--batch N] [--pause SECONDS] [--model opus|sonnet] [--ref REF] [--dry-run]" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
list=$1
shift
batch=5 pause=1200 model=opus ref="" dry=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --batch) batch=$2; shift 2 ;;
    --pause) pause=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --ref) ref=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) usage ;;
  esac
done
case $model in opus | sonnet) ;; *) echo "dispatch-audit.sh: unsupported model $model" >&2; exit 2 ;; esac
[[ -f $list ]] || usage
[[ $batch =~ ^[0-9]+$ && $batch -gt 0 ]] || usage

mapfile -t repos < <(sed -e 's/[[:space:]]*#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$list" | grep -v '^$')
[[ ${#repos[@]} -gt 0 ]] || { echo "dispatch-audit.sh: no repositories in $list" >&2; exit 2; }

api() { tea api --login git "$@"; }

# run_state REPO SINCE_EPOCH: "none", "queued|in_progress|...", or "completed <conclusion>"
run_state() {
  api "repos/$1/actions/runs?limit=5" | jq -r --argjson s "$2" '
    [ .workflow_runs[]
      | select((.path | startswith("ai-review.yml")) and .event == "workflow_dispatch")
      | select((((.run_started_at // .created_at // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+"; "") | fromdateiso8601)) >= $s - 60)
    ] | first
    | if . == null then "none"
      elif .status == "completed" then "completed " + (.conclusion // "unknown")
      else .status end'
}

failed=0
n=0
for ((i = 0; i < ${#repos[@]}; i += batch)); do
  n=$((n + 1))
  chunk=("${repos[@]:i:batch}")
  echo "batch $n: ${chunk[*]}"
  [[ -n $dry ]] && continue

  declare -A since=()
  for repo in "${chunk[@]}"; do
    r=$ref
    [[ -n $r ]] || r=$(api "repos/$repo" | jq -r .default_branch)
    since[$repo]=$(date -u +%s)
    if api -X POST "repos/$repo/actions/workflows/ai-review.yml/dispatches" \
         -d "{\"ref\":\"$r\",\"inputs\":{\"mode\":\"audit\",\"model\":\"$model\"}}" > /dev/null; then
      echo "  dispatched $repo ($r)"
    else
      echo "  dispatch FAILED $repo" >&2
      failed=1
      unset 'since[$repo]'
    fi
  done

  pending=("${!since[@]}")
  while [[ ${#pending[@]} -gt 0 ]]; do
    sleep 30
    still=()
    for repo in "${pending[@]}"; do
      state=$(run_state "$repo" "${since[$repo]}" 2>/dev/null || echo none)
      case $state in
        completed*)
          conclusion=${state#completed }
          echo "  $repo: $conclusion"
          [[ $conclusion == success ]] || failed=1
          ;;
        *) still+=("$repo") ;;
      esac
    done
    pending=("${still[@]+"${still[@]}"}")
  done
  unset since

  if ((i + batch < ${#repos[@]})); then
    echo "pausing ${pause}s before the next batch"
    sleep "$pause"
  fi
done
exit $failed
