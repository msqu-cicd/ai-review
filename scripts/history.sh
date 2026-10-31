#!/usr/bin/env bash
# Collect the earlier discussion on a pull request for a re-review: the AI reviews posted
# before (body, inline comments and the replies under them) and what people wrote, oldest
# first, each person marked as maintainer or not. Runs in its own workflow step because the
# review step has no Gitea token.
#
# Usage: history.sh PR_NUMBER OUT_FILE
# Env: GITEA_TOKEN, GITHUB_API_URL, GITHUB_REPOSITORY (as for post.sh); BOT_LOGIN (gitea-actions,
#      the user the job token posts as), HISTORY_MAX_BYTES (32768), CURL_BIN (curl).
# Writes OUT_FILE only when there is a discussion. Exit 0 also when the API fails (the review
# then runs without history), 2 on bad arguments.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

usage() { echo "usage: history.sh PR_NUMBER OUT_FILE" >&2; exit 2; }
[[ $# -eq 2 && $1 =~ ^[0-9]+$ ]] || usage
pr=$1 out_file=$2
BOT_LOGIN=${BOT_LOGIN:-gitea-actions}
HISTORY_MAX_BYTES=${HISTORY_MAX_BYTES:-32768}
CURL_BIN=${CURL_BIN:-curl}
[[ $HISTORY_MAX_BYTES =~ ^[0-9]+$ ]] || { echo "history.sh: HISTORY_MAX_BYTES must be a number" >&2; exit 2; }
mkdir -p "$(dirname "$out_file")"
rm -f "$out_file"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

skip() { echo "history.sh: $1; the review runs without history" >&2; exit 0; }

[[ -n ${GITEA_TOKEN:-} && -n ${GITHUB_API_URL:-} && -n ${GITHUB_REPOSITORY:-} ]] \
  || skip "GITEA_TOKEN, GITHUB_API_URL and GITHUB_REPOSITORY are required"
base="$GITHUB_API_URL/repos/$GITHUB_REPOSITORY"

# get PATH FILE [TYPE]: GET repos/REPO/PATH into FILE; non-zero on any failure, including a body
# whose JSON type is not TYPE (array).
get() {
  "$CURL_BIN" -fsS --retry 2 --max-time 30 -H "Authorization: token $GITEA_TOKEN" -o "$2" "$base/$1" \
    && jq -e --arg t "${3:-array}" 'type == $t' "$2" > /dev/null 2>&1
}

# append FILE: add the array in FILE to the array in $work/acc.json.
append() {
  jq -s 'add' "$work/acc.json" "$1" > "$work/acc.next" && mv "$work/acc.next" "$work/acc.json"
}

get "pulls/$pr" "$work/pr.json" object || skip "could not read PR $pr"
author=$(jq -r '.user.login // ""' "$work/pr.json")
[[ -n $author ]] || skip "PR $pr has no author"

# Reviews come in pages; read until an empty page, at most 20 pages of 50.
echo '[]' > "$work/acc.json"
for ((page = 1; page <= 20; page++)); do
  get "pulls/$pr/reviews?limit=50&page=$page" "$work/page.json" || skip "could not list the reviews of PR $pr"
  [[ $(jq length "$work/page.json") -gt 0 ]] || break
  append "$work/page.json"
done
mv "$work/acc.json" "$work/reviews.json"

# Inline comments are listed per review; Gitea files a reply under the review it answers.
echo '[]' > "$work/acc.json"
while read -r id; do
  get "pulls/$pr/reviews/$id/comments" "$work/page.json" || skip "could not read the inline comments of review $id"
  append "$work/page.json"
done < <(jq -r '.[] | select((.comments_count // 0) > 0) | .id' "$work/reviews.json")
mv "$work/acc.json" "$work/inline.json"

get "issues/$pr/comments" "$work/comments.json" || skip "could not list the comments of PR $pr"

# Maintainers: people with write access who did not open the PR; only their answers may settle
# a finding. One permission lookup per person. Gitea answers it only when the token's user is a
# repository admin (or the person asked about); any failure counts as "not a maintainer".
echo '[]' > "$work/maintainers.json"
while read -r login; do
  if [[ $login =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    && get "collaborators/$login/permission" "$work/perm.json" object \
    && jq -e '.permission | IN("write", "admin", "owner")' "$work/perm.json" > /dev/null 2>&1; then
    jq --arg l "$login" '. + [$l]' "$work/maintainers.json" > "$work/acc.next"
    mv "$work/acc.next" "$work/maintainers.json"
  else
    echo "history.sh: $login does not count as a maintainer (no write access or lookup failed)"
  fi
done < <(jq -rn --arg bot "$BOT_LOGIN" --arg author "$author" '
  [inputs | .[] | .user.login // empty] | unique | .[]
  | select(. != $bot and ascii_downcase != ($author | ascii_downcase))
' "$work/reviews.json" "$work/inline.json" "$work/comments.json")

render_history "$work/reviews.json" "$work/inline.json" "$work/comments.json" "$work/maintainers.json" \
  "$BOT_LOGIN" "$author" "$HISTORY_MAX_BYTES" > "$work/history.md" || skip "could not render the discussion"
if [[ -s $work/history.md ]]; then
  mv "$work/history.md" "$out_file"
  echo "history.sh: $(grep -c '^### ' "$out_file") entries, $(wc -c < "$out_file") bytes in $out_file"
else
  echo "history.sh: no earlier discussion on PR $pr"
fi
