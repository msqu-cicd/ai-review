# shellcheck shell=bash
# Pure functions for the AI review workflow. Sourced by the scripts and the tests,
# never executed. Callers set their own `set -euo pipefail`; this file only defines
# functions. Needs bash 4+ and jq.

# _csv_items CSV: split a comma-separated list into the array `items` without pathname
# expansion (an unquoted `$csv` under IFS=, would glob each word against the cwd).
_csv_items() {
  IFS=, read -ra items <<<"$1"
}

# _csv_contains CSV VALUE: exit 0 when VALUE is one of the comma-separated items.
_csv_contains() {
  local items item
  _csv_items "$1"
  for item in "${items[@]}"; do
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
  first=${first%$'\r'} # web forms submit CRLF
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
# 1 when the file is a vault on the new side (the "$ANSIBLE_VAULT;" header is an added or a
# context line: new or re-encrypted vault), 2 when the header was only removed (vault turned
# into plaintext or deleted: the plaintext must not reach the model, the reviewer must hear
# about it), 0 otherwise.
_diff_sections() {
  awk '
    function flush() { if (n) print n "\t" path "\t" (vnew ? 1 : (vrem ? 2 : 0)) }
    /^diff --git / { flush(); n++; path = $0; sub(/^diff --git a\/.* b\//, "", path); vnew = 0; vrem = 0; next }
    /^[ +]\$ANSIBLE_VAULT;/ { vnew = 1 }
    /^-\$ANSIBLE_VAULT;/ { vrem = 1 }
    END { flush() }
  ' "$1"
}

# _is_lockfile PATH: dependency lockfiles are never worth a review.
_is_lockfile() {
  case ${1##*/} in
    *.lock | package-lock.json | go.sum) return 0 ;;
  esac
  return 1
}

# _glob_matches PATH GLOBS_CSV: exit 0 when PATH matches one of the comma-separated globs
# (bash pattern matching; `*` and `**` both cross `/` here) or lies below a directory one of
# them names. Must drop at least what secret-scan.sh deletes from the checkout, so `./` and a
# trailing `/` are stripped and `**/` also matches zero directories, as in globstar expansion
# (`@(...)` works inside [[ ]] without extglob since bash 4.1).
_glob_matches() {
  local items glob
  _csv_items "$2"
  for glob in "${items[@]}"; do
    glob=${glob#./}
    glob=${glob%/}
    [[ -z $glob ]] && continue
    glob=${glob//'**/'/'@(*/|)'}
    # shellcheck disable=SC2053
    [[ $1 == $glob || $1 == $glob/* ]] && return 0
  done
  return 1
}

# _drop_reason PATH VAULT GLOBS_CSV: print why a diff section is kept from the model
# (vault, vault-removed, lockfile, excluded); exit 1 when it is sent.
_drop_reason() {
  if [[ $2 == 1 ]]; then echo vault
  elif [[ $2 == 2 ]]; then echo vault-removed
  elif _is_lockfile "$1"; then echo lockfile
  elif _glob_matches "$1" "$3"; then echo excluded
  else return 1
  fi
}

# filter_diff DIFF_FILE EXCLUDE_GLOBS_CSV: print the diff without excluded paths, lockfiles
# and vault files (including vaults turned into plaintext). Deleted, renamed and binary
# sections pass through. Exit 0.
filter_diff() {
  local file=$1 globs=$2 drop=" " idx path vault
  while IFS=$'\t' read -r idx path vault; do
    _drop_reason "$path" "$vault" "$globs" > /dev/null && drop+="$idx "
  done < <(_diff_sections "$file")
  awk -v drop="$drop" '
    /^diff --git / { n++; keep = index(drop, " " n " ") == 0 }
    keep { print }
  ' "$file"
}

# filter_diff_dropped DIFF_FILE EXCLUDE_GLOBS_CSV: "PATH<TAB>REASON" for every section
# filter_diff removes, so the reviewer can be told that they changed without seeing them.
filter_diff_dropped() {
  local file=$1 globs=$2 idx path vault reason
  while IFS=$'\t' read -r idx path vault; do
    reason=$(_drop_reason "$path" "$vault" "$globs") && printf '%s\t%s\n' "$path" "$reason"
  done < <(_diff_sections "$file")
  return 0
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
# inline comments, the rest are listed in the body. The "Changes requested" line follows the
# severities, not the model's verdict: it shows exactly when a blocker or major finding exists.
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
               + (if any($r.findings[]; .severity | IN("blocker", "major")) then "**Changes requested**\n\n" else "" end)
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
  local review=$1 date=$2 model=$3 label_id=$4
  # jq 1.6 rejects $label (keyword), hence $label_id.
  jq --arg date "$date" --arg model "$model" --argjson label_id "$label_id" '
    . as $r
    | {
        title: ("AI audit " + $date + " (" + $model + ")"),
        labels: [$label_id],
        body: ($r.summary + "\n"
               + ([ ("blocker", "major", "minor", "nit") as $s
                    | ($r.findings | map(select(.severity == $s)))
                    | select(length > 0)
                    | "\n### " + $s + "\n" + (map("- " + '"$_jq_finding_ref"' + " " + .body) | join("\n"))
                  ] | join("\n")))
      }
  ' "$review"
}

# --- pull request history ------------------------------------------------------------

# render_history REVIEWS_JSON INLINE_JSON COMMENTS_JSON MAINTAINERS_JSON BOT_LOGIN PR_AUTHOR
# MAX_BYTES: the earlier discussion on a pull request as Markdown, oldest first, from the Gitea
# lists of reviews, their inline comments and the issue comments. Every person is marked
# [maintainer] when the login is in the MAINTAINERS_JSON array and is not PR_AUTHOR, otherwise
# [not a maintainer] or [PR author, not a maintainer]. AI reviews are what BOT_LOGIN posted under the
# "## AI review" heading (as a review or, after a fallback, as a comment); its other comments
# (failure notices), bare /review commands, and pending or dismissed reviews are left out.
# Replies under an inline comment stay with it. Bodies are quoted; every other API field (path,
# login, time, commit) goes through `field`, so none can open a line of its own. An entry is cut
# at MAX_BYTES/4 characters, and the oldest entries are dropped, with a one-line note, until the
# rest fits into MAX_BYTES (the newest one always stays). Prints nothing when there is no
# discussion.
render_history() {
  jq -n -r --slurpfile reviews "$1" --slurpfile inline "$2" --slurpfile comments "$3" \
    --slurpfile maintainers "$4" --arg bot "$5" --arg author "$6" --argjson max "$7" '
    def quote: split("\r") | join("") | split("\n") | map("> " + .) | join("\n");
    def cut($n): if length > $n then .[:$n] + "\n[cut: longer than \($n) characters]" else . end;
    # a non-body field on one line: control characters and line/paragraph separators become "?",
    # backticks are dropped, the rest goes inside backticks
    def field: tostring | explode
      | map(if . < 32 or . == 127 or . == 8232 or . == 8233 then 63 elif . == 96 then empty else . end)
      | implode | "`" + . + "`";
    def who: .user.login // "ghost";
    def by_ai: who == $bot and ((.body // "") | startswith("## AI review"));
    # the author of a human entry with the role that decides whether an answer counts
    def person: who as $w
      | ($w | field) + " "
        + (if ($w | ascii_downcase) == ($author | ascii_downcase) then "[PR author, not a maintainer]"
           elif any(($maintainers[0] // [])[]; . == $w) then "[maintainer]"
           else "[not a maintainer]" end);
    def where: (.path // "" | tostring) + (if (.position // 0) > 0 then ":" + (.position | tostring)
                        elif (.original_position // 0) > 0 then " (old line " + (.original_position | tostring) + ")"
                        else "" end);
    # one thread: the inline comments on the same line, oldest first
    def thread:
      (map(.resolver.login // empty) | first) as $resolver
      | "On " + (.[0] | where | field) + (if $resolver then " (resolved by " + ($resolver | field) + ")" else "" end) + ":\n"
        + (map((if who == $bot then "" else person + ", " + (.created_at | field) + ":\n" end) + ((.body // "") | quote))
           | join("\n"));
    ($inline[0] // []) as $inline
    | def threads($id):
        [$inline[] | select(.pull_request_review_id == $id)] | sort_by(.id)
        | group_by([.path, (.position // 0), (.original_position // 0)]) | sort_by(.[0].id)
        | map(thread) | join("\n\n");
      [ ($reviews[0] // [])[]
        | select(.state != "PENDING" and .state != "REQUEST_REVIEW" and (.dismissed | not))
        | (.body // "") as $body
        | threads(.id) as $threads
        | if by_ai then
            {t: .submitted_at,
             text: ("### Earlier AI review of commit " + ((.commit_id // "") | tostring | .[:7] | field) + ", " + (.submitted_at | field)
                    + "\n\n" + ($body | quote)
                    + (if $threads != "" then "\n\nInline comments:\n\n" + $threads else "" end))}
          elif who == $bot or ($body == "" and $threads == "") then empty
          else
            {t: .submitted_at,
             text: ("### Review by " + person
                    + (if .state == "APPROVED" then " (approved)"
                       elif .state == "REQUEST_CHANGES" then " (changes requested)" else "" end)
                    + ", " + (.submitted_at | field)
                    + (if $body != "" then "\n\n" + ($body | quote) else "" end)
                    + (if $threads != "" then "\n\n" + $threads else "" end))}
          end ]
      + [ ($comments[0] // [])[]
          | (.body // "") as $body
          | if by_ai then
              {t: .created_at, text: ("### Earlier AI review, posted as a comment, " + (.created_at | field) + "\n\n" + ($body | quote))}
            elif who == $bot or $body == "" or ($body | test("\\A\\s*/review( +(opus|sonnet|audit))*\\s*\\z")) then empty
            else
              {t: .created_at, text: ("### Comment by " + person + ", " + (.created_at | field) + "\n\n" + ($body | quote))}
            end ]
    | sort_by(.t) | map(.text | cut($max / 4 | floor)) as $all
    | (reduce ($all | reverse | .[]) as $e ({kept: [], bytes: 0, full: false};
        if .full then .
        elif (.kept | length) > 0 and .bytes + ($e | utf8bytelength) + 2 > $max then .full = true
        else .kept = [$e] + .kept | .bytes += ($e | utf8bytelength) + 2 end)).kept as $kept
    | (($all | length) - ($kept | length)) as $omitted
    | if ($kept | length) == 0 then empty
      else (if $omitted > 0 then "(" + ($omitted | tostring) + " older entries left out to keep this short.)\n\n" else "" end)
           + ($kept | join("\n\n"))
      end
  '
}
