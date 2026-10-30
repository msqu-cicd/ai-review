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

# --- diff helpers --------------------------------------------------------------------
# A unified diff is a sequence of sections, each starting with "diff --git a/X b/Y".
# The path of a section is its b/ side.

# _diff_sections DIFF_FILE: one line per section: "INDEX<TAB>PATH<TAB>VAULT" where VAULT is
# 1 when the section adds a line starting with "$ANSIBLE_VAULT;".
_diff_sections() {
  awk '
    /^diff --git / { if (n) print n "\t" path "\t" vault; n++; path = $0; sub(/^diff --git a\/.* b\//, "", path); vault = 0; next }
    /^\+\$ANSIBLE_VAULT;/ { vault = 1 }
    END { if (n) print n "\t" path "\t" vault }
  ' "$1"
}

# _is_lockfile PATH: dependency lockfiles are never worth a review.
_is_lockfile() {
  case ${1##*/} in
    *.lock | package-lock.json | go.sum) return 0 ;;
  esac
  return 1
}

# _glob_matches PATH GLOBS_CSV: exit 0 when PATH matches one of the comma-separated globs.
_glob_matches() {
  local IFS=, glob
  for glob in $2; do
    # shellcheck disable=SC2053
    [[ -n $glob && $1 == $glob ]] && return 0
  done
  return 1
}

# filter_diff DIFF_FILE EXCLUDE_GLOBS_CSV: print the diff without excluded paths,
# lockfiles and vault files. Deleted, renamed and binary sections pass through. Exit 0.
filter_diff() {
  local file=$1 globs=$2 drop=" " idx path vault
  while IFS=$'\t' read -r idx path vault; do
    if [[ $vault == 1 ]] || _is_lockfile "$path" || _glob_matches "$path" "$globs"; then
      drop+="$idx "
    fi
  done < <(_diff_sections "$file")
  awk -v drop="$drop" '
    /^diff --git / { n++; keep = index(drop, " " n " ") == 0 }
    keep { print }
  ' "$file"
}

# diff_too_large DIFF_FILE MAX_LINES: exit 0 when the diff has more than MAX_LINES lines.
diff_too_large() {
  [[ $(wc -l < "$1") -gt $2 ]]
}

# diff_file_list DIFF_FILE: one "PATH (+ADDED/-REMOVED)" line per section.
diff_file_list() {
  awk '
    function flush() { if (path != "") print path " (+" add "/-" del ")" }
    /^diff --git / { flush(); path = $0; sub(/^diff --git a\/.* b\//, "", path); add = 0; del = 0; next }
    /^\+\+\+ / || /^--- / { next }
    /^\+/ { add++ }
    /^-/ { del++ }
    END { flush() }
  ' "$1"
}

# diff_new_side_lines DIFF_FILE: "PATH<TAB>LINE" for every new-side line (context or added)
# covered by a hunk, computed from the "@@ -a,b +c,d @@" headers.
diff_new_side_lines() {
  awk '
    /^diff --git / { path = $0; sub(/^diff --git a\/.* b\//, "", path); inhunk = 0; next }
    /^@@ / { match($0, /\+[0-9]+/); line = substr($0, RSTART + 1, RLENGTH - 1) + 0; inhunk = 1; next }
    !inhunk { next }
    /^\+\+\+ / || /^--- / { next }
    /^\\/ { next }
    /^-/ { next }
    { print path "\t" line; line++ }
  ' "$1"
}

# --- Claude output and Gitea payloads ------------------------------------------------

# validate_claude_output CLAUDE_JSON_FILE: print .structured_output when the run succeeded
# and the output has the review shape (summary, verdict, findings[] with path, line,
# severity, body). Exit 1 with the reason on stderr otherwise.
validate_claude_output() {
  local file=$1
  if [[ $(jq -r '.is_error // false' "$file") == true ]]; then
    echo "validate_claude_output: Claude Code reported is_error=true: $(jq -r '.result // ""' "$file" | head -c 300)" >&2
    return 1
  fi
  if ! jq -e '
      .structured_output
      | type == "object"
        and (.summary | type == "string")
        and (.verdict | IN("comment", "request_changes"))
        and (.findings | type == "array")
        and all(.findings[];
              (.path | type == "string")
              and ((.line | type) == "number" or (.line | type) == "null")
              and (.severity | IN("blocker", "major", "minor", "nit"))
              and (.body | type == "string"))
    ' "$file" > /dev/null 2>&1; then
    echo "validate_claude_output: structured_output is missing or malformed" >&2
    return 1
  fi
  jq '.structured_output' "$file"
}

# build_comment_payload TEXT: Gitea issue comment body.
build_comment_payload() {
  jq -n --arg body "$1" '{body: $body}'
}

# _finding_ref: jq helper text, "path" or "path:line".
_jq_finding_ref='(.path + (if .line != null then ":" + (.line | tostring) else "" end))'

# build_pr_review_payload REVIEW_JSON_FILE HEAD_SHA DIFF_FILE MODEL: Gitea
# CreatePullReviewOptions with event COMMENT; findings on new-side diff lines become
# inline comments, the rest are listed in the body.
build_pr_review_payload() {
  local review=$1 sha=$2 diff=$3 model=$4 placeable
  placeable=$(diff_new_side_lines "$diff" | jq -R -s 'split("\n") | map(select(length > 0) | sub("\t"; ":"))')
  jq --arg sha "$sha" --arg model "$model" --argjson placeable "$placeable" '
    . as $r
    | ($r.findings | map(. + {key: (.path + ":" + ((.line // "") | tostring))})) as $all
    | ($all | map(select(.line != null and (.key | IN($placeable[]))))) as $placed
    | ($all | map(select(.line == null or ((.key | IN($placeable[])) | not)))) as $rest
    | {
        event: "COMMENT",
        commit_id: $sha,
        body: ("## AI review (" + $model + ")\n\n"
               + (if $r.verdict == "request_changes" then "**Changes requested**\n\n" else "" end)
               + $r.summary
               + (if ($rest | length) > 0
                  then "\n\n### Not placed in the diff\n"
                       + ($rest | map("- **" + .severity + "** " + '"$_jq_finding_ref"' + " " + .body) | join("\n"))
                  else "" end)),
        comments: ($placed | map({path: .path, new_position: .line, body: ("**" + .severity + "** " + .body)}))
      }
  ' "$review"
}

# build_issue_payload REVIEW_JSON_FILE DATE MODEL LABEL_ID: Gitea CreateIssueOption for
# an audit: findings grouped by severity, most severe first.
build_issue_payload() {
  local review=$1 date=$2 model=$3 label=$4
  jq --arg date "$date" --arg model "$model" --argjson label "$label" '
    . as $r
    | {
        title: ("AI audit " + $date + " (" + $model + ")"),
        labels: [$label],
        body: ($r.summary + "\n"
               + ([ ("blocker", "major", "minor", "nit") as $s
                    | ($r.findings | map(select(.severity == $s)))
                    | select(length > 0)
                    | "\n### " + $s + "\n" + (map("- " + '"$_jq_finding_ref"' + " " + .body) | join("\n"))
                  ] | join("\n")))
      }
  ' "$review"
}
