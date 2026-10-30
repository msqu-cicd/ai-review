# shellcheck shell=bash
# Pure functions for the AI review workflow. Sourced by the scripts and the tests,
# never executed. Callers set their own `set -euo pipefail`; this file only defines
# functions. Needs bash 4+ and jq.

# _csv_contains CSV VALUE: exit 0 when VALUE is one of the comma-separated items.
_csv_contains() {
  local IFS=, item
  for item in $1; do
    [[ $item == "$2" ]] && return 0
  done
  return 1
}

# parse_review_command BODY: parse a "/review" comment. Prints "MODE MODEL" where MODE
# is comment|audit and MODEL is opus|sonnet (defaults: comment opus). Only the first
# line counts; exit 1 when it is not a /review command or names an unknown word.
parse_review_command() {
  local first mode=comment model=opus word
  local re='^/review(( +(opus|sonnet|audit))*) *$'
  first=${1%%$'\n'*}
  [[ $first =~ $re ]] || return 1
  for word in ${BASH_REMATCH[1]}; do
    case $word in
      opus | sonnet) model=$word ;;
      audit) mode=audit ;;
    esac
  done
  printf '%s %s\n' "$mode" "$model"
}

# gate_decide EVENT_NAME EVENT_JSON_FILE SKIP_AUTHORS_CSV REPO_FULL_NAME: decide whether
# and how a workflow event runs a review. Prints one JSON object:
#   {"run": bool, "reason": str, "mode": "pr|comment|audit|", "model": "opus|sonnet|", "pr_number": int|null}
gate_decide() {
  local event=$1 file=$2 skip_csv=$3 repo=$4
  local run=false reason="" mode="" model="" pr_number=null
  case $event in
    pull_request)
      local login draft head_repo
      login=$(jq -r '.pull_request.user.login // ""' "$file")
      draft=$(jq -r '.pull_request.draft // false' "$file")
      head_repo=$(jq -r '.pull_request.head.repo.full_name // ""' "$file")
      pr_number=$(jq -r '.pull_request.number // .number // "null"' "$file")
      if _csv_contains "$skip_csv" "$login"; then
        reason="author $login is skipped"
      elif [[ $draft == true ]]; then
        reason="draft pull request"
      elif [[ $head_repo != "$repo" ]]; then
        reason="head repository $head_repo differs from $repo"
      else
        run=true mode=pr model=opus
      fi
      ;;
    issue_comment)
      local is_pr body cmd
      is_pr=$(jq -r 'if (.issue.pull_request != null) or (.is_pull == true) then "true" else "false" end' "$file")
      if [[ $is_pr != true ]]; then
        reason="not a pull request"
      else
        pr_number=$(jq -r '.issue.number // "null"' "$file")
        body=$(jq -r '.comment.body // ""' "$file")
        if cmd=$(parse_review_command "$body"); then
          run=true mode=${cmd% *} model=${cmd#* }
        else
          reason="not a /review command"
        fi
      fi
      ;;
    workflow_dispatch)
      mode=$(jq -r 'if (.inputs.mode // "") == "" then "audit" else .inputs.mode end' "$file")
      model=$(jq -r 'if (.inputs.model // "") == "" then "opus" else .inputs.model end' "$file")
      if [[ $model != opus && $model != sonnet ]]; then
        reason="unsupported model $model"
        mode="" model=""
      elif [[ $mode != pr && $mode != comment && $mode != audit ]]; then
        reason="unsupported mode $mode"
        mode="" model=""
      else
        run=true
      fi
      ;;
    *)
      reason="unsupported event $event"
      ;;
  esac
  jq -n --argjson run "$run" --arg reason "$reason" --arg mode "$mode" --arg model "$model" \
    --argjson pr_number "$pr_number" \
    '{run: $run, reason: $reason, mode: $mode, model: $model, pr_number: $pr_number}'
}
