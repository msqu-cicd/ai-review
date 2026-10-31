#!/usr/bin/env bash
# Post review results to Gitea.
#
# Usage: post.sh review PR_NUMBER PAYLOAD_FILE    POST pulls/PR/reviews; on HTTP 4xx falls back
#                                               to a summary comment built from the payload
#        post.sh comment PR_NUMBER TEXT_FILE     POST issues/PR/comments with the file as body
#        post.sh issue PAYLOAD_FILE              POST issues
#        post.sh label-id NAME COLOR             print the label id, creating the label if needed
# Env: GITEA_TOKEN, GITHUB_API_URL, GITHUB_REPOSITORY; AI_REVIEW_DRY_RUN prints "METHOD URL" and
# the payload instead of calling the API. COST_FILE (optional): review.sh's cost.json; when it holds
# a record, the review, comment or issue body ends with it as one hidden line,
# "<!-- ai-review-cost: {...} -->", which Gitea does not render.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

usage() { echo "usage: post.sh review PR PAYLOAD | comment PR TEXT_FILE | issue PAYLOAD | label-id NAME COLOR" >&2; exit 2; }
kind=${1:-}
case $kind in
  review | comment) [[ $# -eq 3 ]] || usage ;;
  issue) [[ $# -eq 2 ]] || usage ;;
  label-id) [[ $# -eq 3 ]] || usage ;;
  *) usage ;;
esac
: "${GITEA_TOKEN:?GITEA_TOKEN is required}" "${GITHUB_API_URL:?GITHUB_API_URL is required}" "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
base="$GITHUB_API_URL/repos/$GITHUB_REPOSITORY"

resp=$(mktemp)
posted=$(mktemp)
trap 'rm -f "$resp" "$posted"' EXIT
http_code=000
cost_line=$(cost_comment "${COST_FILE:-}")

# with_cost PAYLOAD_FILE: copy the payload to $posted, with the cost line appended to its body.
with_cost() {
  if [[ -n $cost_line ]]; then
    jq --arg c "$cost_line" '.body += "\n\n" + $c' "$1" > "$posted"
  else
    cp "$1" "$posted"
  fi
}

# api METHOD URL [PAYLOAD_FILE]: call the Gitea API; the body lands in $resp, the status in
# $http_code. In dry-run mode prints the request instead and pretends 200.
api() {
  local method=$1 url=$2 payload=${3:-}
  if [[ -n ${AI_REVIEW_DRY_RUN:-} ]]; then
    echo "$method $url"
    [[ -n $payload ]] && cat "$payload" && echo
    : > "$resp"
    http_code=200
    return 0
  fi
  local args=(-sS --retry 2 -o "$resp" -w '%{http_code}' -X "$method"
    -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json")
  [[ -n $payload ]] && args+=(--data "@$payload")
  http_code=$(curl "${args[@]}" "$url") || http_code=000
}

ok() { [[ $http_code == 2* ]]; }

fail_with_body() {
  echo "post.sh: $1 failed with HTTP $http_code: $(head -c 300 "$resp")" >&2
  exit 1
}

case $kind in
  review)
    pr=$2 payload=$3
    with_cost "$payload"
    api POST "$base/pulls/$pr/reviews" "$posted"
    if ok; then
      echo "post.sh: review posted on PR $pr"
    elif [[ $http_code == 4* ]]; then
      echo "post.sh: review rejected with HTTP $http_code, falling back to a summary comment" >&2
      text=$(mktemp)
      jq -r '.body + (if (.comments | length) > 0
                      then "\n\n### Inline findings\n" + (.comments | map("- " + .path + ":" + (.new_position | tostring) + " " + .body) | join("\n"))
                      else "" end)' "$payload" > "$text"
      [[ -z $cost_line ]] || printf '\n%s\n' "$cost_line" >> "$text"
      comment_payload=$(mktemp)
      build_comment_payload "$(cat "$text")" > "$comment_payload"
      api POST "$base/issues/$pr/comments" "$comment_payload"
      rm -f "$text" "$comment_payload"
      ok || fail_with_body "fallback comment"
      echo "fallback: summary comment"
    else
      fail_with_body "review"
    fi
    ;;
  comment)
    pr=$2 text_file=$3
    comment_payload=$(mktemp)
    body=$(cat "$text_file")
    [[ -z $cost_line ]] || body+=$'\n\n'$cost_line
    build_comment_payload "$body" > "$comment_payload"
    api POST "$base/issues/$pr/comments" "$comment_payload"
    rm -f "$comment_payload"
    ok || fail_with_body "comment"
    echo "post.sh: comment posted on PR $pr"
    ;;
  issue)
    payload=$2
    with_cost "$payload"
    api POST "$base/issues" "$posted"
    ok || fail_with_body "issue"
    [[ -n ${AI_REVIEW_DRY_RUN:-} ]] || echo "post.sh: issue created: $(jq -r '.html_url // .number' "$resp")"
    ;;
  label-id)
    name=$2 color=$3
    api GET "$base/labels?limit=100"
    ok || fail_with_body "label list"
    id=$(jq -r --arg n "$name" '[.[] | select(.name == $n) | .id] | first // empty' "$resp" 2>/dev/null || true)
    if [[ -z $id ]]; then
      label_payload=$(mktemp)
      jq -n --arg n "$name" --arg c "#$color" '{name: $n, color: $c, description: "Created by the AI review workflow"}' > "$label_payload"
      api POST "$base/labels" "$label_payload"
      rm -f "$label_payload"
      ok || fail_with_body "label create"
      id=$(jq -r '.id // empty' "$resp" 2>/dev/null || true)
    fi
    [[ -n $id ]] || { [[ -n ${AI_REVIEW_DRY_RUN:-} ]] && id=0; }
    printf '%s\n' "$id"
    ;;
esac
