#!/usr/bin/env bash
# Decide whether this workflow event runs a review and collect what the later steps need.
#
# Usage: gate.sh EVENT_NAME EVENT_JSON_FILE SKIP_AUTHORS_CSV REPO MODE_OVERRIDE MODEL_OVERRIDE
# Env: GITEA_TOKEN, GITHUB_API_URL (API calls), GITHUB_SHA (audit head), GITHUB_OUTPUT (where
#      the outputs go; stdout when unset), AI_REVIEW_DRY_RUN (no API calls, shas from the event).
# Outputs: run, reason, mode, model, pr_number, base_sha, head_sha, base_ref.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

[[ $# -eq 6 ]] || { echo "usage: gate.sh EVENT EVENT_JSON SKIP_AUTHORS REPO MODE_OVERRIDE MODEL_OVERRIDE" >&2; exit 2; }
event=$1 file=$2 skip=$3 repo=$4 mode_override=$5 model_override=$6

decision=$(gate_decide "$event" "$file" "$skip" "$repo")
run=$(jq -r .run <<<"$decision")
reason=$(jq -r .reason <<<"$decision")
mode=$(jq -r .mode <<<"$decision")
model=$(jq -r .model <<<"$decision")
pr=$(jq -r '.pr_number // ""' <<<"$decision")
base_sha="" head_sha="" base_ref=""

gitea_get() { # PATH under repos/REPO/
  curl -fsS --retry 2 -H "Authorization: token ${GITEA_TOKEN:?GITEA_TOKEN is required}" \
    "${GITHUB_API_URL:?GITHUB_API_URL is required}/repos/$repo/$1"
}

deny() { run=false; reason=$1; }

if [[ $run == true ]]; then
  [[ -n $mode_override ]] && mode=$mode_override
  [[ -n $model_override ]] && model=$model_override
  case $model in opus | sonnet) ;; *) deny "unsupported model $model" ;; esac
  case $mode in pr | comment | audit) ;; *) deny "unsupported mode $mode" ;; esac
fi

if [[ $run == true ]]; then
  if [[ $event == pull_request ]]; then
    base_sha=$(jq -r '.pull_request.base.sha // ""' "$file")
    head_sha=$(jq -r '.pull_request.head.sha // ""' "$file")
    base_ref=$(jq -r '.pull_request.base.ref // ""' "$file")
  elif [[ $event == issue_comment ]]; then
    user=$(jq -r '.comment.user.login // ""' "$file")
    if [[ -z ${AI_REVIEW_DRY_RUN:-} ]]; then
      perm=$(gitea_get "collaborators/$user/permission" | jq -r '.permission // ""' || true)
      case $perm in
        write | admin | owner) ;;
        *) deny "commenter $user lacks write access (${perm:-unknown})" ;;
      esac
      if [[ $run == true ]]; then
        prjson=$(gitea_get "pulls/$pr")
        head_repo=$(jq -r '.head.repo.full_name // ""' <<<"$prjson")
        if [[ $head_repo != "$repo" ]]; then
          deny "head repository $head_repo differs from $repo"
        else
          base_sha=$(jq -r '.base.sha // ""' <<<"$prjson")
          head_sha=$(jq -r '.head.sha // ""' <<<"$prjson")
          base_ref=$(jq -r '.base.ref // ""' <<<"$prjson")
        fi
      fi
    fi
  else # workflow_dispatch
    head_sha=${GITHUB_SHA:-}
    [[ $mode == audit ]] || deny "$mode mode needs a pull request event"
  fi
fi

if [[ $run == true && $mode != audit && ( -z $base_sha || -z $head_sha ) && -z ${AI_REVIEW_DRY_RUN:-} ]]; then
  deny "could not determine base and head commits"
fi

{
  echo "run=$run"
  echo "reason=$reason"
  echo "mode=$mode"
  echo "model=$model"
  echo "pr_number=$pr"
  echo "base_sha=$base_sha"
  echo "head_sha=$head_sha"
  echo "base_ref=$base_ref"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "gate: run=$run mode=$mode model=$model pr=${pr:-none}${reason:+ reason=$reason}"
