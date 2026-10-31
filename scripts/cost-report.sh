#!/usr/bin/env bash
# Sum the cost estimates the AI review leaves in its posts: what the runs would have cost at API
# list prices (Claude Code's total_cost_usd), to compare with the subscription. Read-only.
#
# Usage: cost-report.sh [--since YYYY-MM-DD] [ORG...]
#   ORG      organisations to scan (default: Ansible Infrastructure DevOps CICD)
#   --since  only runs from that day on (UTC); issues and pull requests not updated since then are
#            not read at all
# Reads every repository of the orgs, their pull requests and issues, the reviews of each pull
# request and the issue comments, in pages of 50 via `tea api --login git` (GET only). A record is
# the hidden "<!-- ai-review-cost: {...} -->" line post.sh puts at the end of a review, an audit
# issue or a failure notice, counted only when BOT_LOGIN posted it; the same record twice counts
# once. Prints runs, cost and tokens per month, model and mode, and the grand total.
# Env: BOT_LOGIN (gitea-actions, the user the job token posts as), TEA_BIN (tea).
# Exit 1 when an API call failed (each one is named on stderr; the totals miss that part), 2 on bad
# arguments.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

usage() { echo "usage: cost-report.sh [--since YYYY-MM-DD] [ORG...]" >&2; exit 2; }
since="" orgs=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --since) [[ $# -ge 2 ]] || usage; since=$2; shift 2 ;;
    -*) usage ;;
    *) orgs+=("$1"); shift ;;
  esac
done
[[ ${#orgs[@]} -gt 0 ]] || orgs=(Ansible Infrastructure DevOps CICD)
[[ -z $since || $since =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]] || usage
for org in "${orgs[@]}"; do
  [[ $org =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
done
BOT_LOGIN=${BOT_LOGIN:-gitea-actions}
TEA_BIN=${TEA_BIN:-tea}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# get PATH FILE [TYPE]: GET PATH into FILE; non-zero when the call fails or the body's JSON type is
# not TYPE (array). `tea api` exits 0 on an HTTP error and prints Gitea's error object.
get() {
  "$TEA_BIN" api --login git "$1" > "$2" 2> /dev/null \
    && jq -e --arg t "${3:-array}" 'type == $t' "$2" > /dev/null 2>&1
}

# pages PATH FILE: every item of a paged list into FILE as one array; a page with fewer than 50
# items is the last. Non-zero when a page fails.
pages() {
  local sep='?' page
  [[ $1 != *\?* ]] || sep='&'
  echo '[]' > "$2"
  for ((page = 1; page <= 200; page++)); do
    get "$1${sep}limit=50&page=$page" "$work/page.json" || return 1
    jq -s 'add' "$2" "$work/page.json" > "$work/acc.next" && mv "$work/acc.next" "$2"
    [[ $(jq length "$work/page.json") -ge 50 ]] || break
  done
}

failed=0
warn() { echo "cost-report.sh: $1" >&2; failed=1; }

# collect PATH WHAT: append the records in the list at PATH to records.jsonl.
collect() {
  if pages "$1" "$work/list.json"; then
    cost_records "$work/list.json" "$BOT_LOGIN" >> "$work/records.jsonl"
  else
    warn "could not read $2 ($1)"
  fi
}

# Pages of 50 need the server to hand out 50 items per page; fewer would end every list early.
get settings/api "$work/settings.json" object || { echo "cost-report.sh: cannot read settings/api, is \`tea login\` git set up?" >&2; exit 1; }
[[ $(jq '.max_response_items // 0' "$work/settings.json") -ge 50 ]] \
  || { echo "cost-report.sh: the server returns fewer than 50 items per page" >&2; exit 1; }

# Posting a review or comment updates the issue's updated_at, so "since" never hides a record.
updated=""
[[ -z $since ]] || updated="since=${since}T00:00:00Z"
: > "$work/records.jsonl"
for org in "${orgs[@]}"; do
  pages "orgs/$org/repos" "$work/repos.json" || { warn "could not list the repositories of $org"; continue; }
  while IFS=$'\t' read -r repo issues pulls; do
    if [[ $pulls == true ]]; then
      if pages "repos/$repo/issues?state=all&type=pulls${updated:+&$updated}" "$work/pulls.json"; then
        while read -r n; do
          collect "repos/$repo/pulls/$n/reviews" "the reviews of $repo#$n"
        done < <(jq -r '.[].number' "$work/pulls.json")
      else
        warn "could not list the pull requests of $repo"
      fi
    fi
    [[ $issues != true ]] || collect "repos/$repo/issues?state=all&type=issues${updated:+&$updated}" "the issues of $repo"
    if [[ $issues == true || $pulls == true ]]; then
      collect "repos/$repo/issues/comments${updated:+?$updated}" "the comments of $repo"
    fi
  done < <(jq -r '.[] | [.full_name, (.has_issues // false), (.has_pull_requests // false)] | @tsv' "$work/repos.json")
done

echo "AI review cost estimate: Claude Code's total_cost_usd at API list prices, not what the subscription charges."
echo "Orgs: ${orgs[*]}${since:+; runs since $since}"
echo
jq -s -r --arg since "$since" '
  unique | map(select($since == "" or (.timestamp // "") >= $since)) as $runs
  | def n: if type == "number" then . else 0 end;
    def totals: {runs: length, cost: (map(.cost | n) | add // 0), input: (map(.input | n) | add // 0),
                 output: (map(.output | n) | add // 0), cache_read: (map(.cache_read | n) | add // 0),
                 cache_write: (map(.cache_write | n) | add // 0)};
    def rows($group): group_by(.key)[] | (.[0].key | tostring) as $k | totals
      | [$group, $k, .runs, .cost, .input, .output, .cache_read, .cache_write] | @tsv;
    # what one run (or one model in a run) adds to a row
    def entry($key): {key: $key, cost: .total_cost_usd, input: .input_tokens, output: .output_tokens,
                      cache_read: .cache_read_input_tokens, cache_write: .cache_creation_input_tokens};
    (["group", "key", "runs", "cost_usd", "input", "output", "cache_read", "cache_write"] | @tsv),
    ($runs | map(entry((.timestamp // "unknown") | tostring | .[0:7])) | rows("month")),
    ($runs | map(if (.models | type) == "object" and (.models | length) > 0
                 then .models | to_entries[] | .key as $k | .value | .total_cost_usd = .cost_usd | entry($k)
                 else entry(.model // "unknown") end) | rows("model")),
    ($runs | map(entry(.mode // "unknown")) | rows("mode")),
    ($runs | map(entry("all")) | rows("total")),
    (if ($runs | length) == 0 then "#No cost records found." else empty end),
    (($runs | map(select((.total_cost_usd | type) != "number")) | length) as $none
     | if $none > 0 then "#Runs without a cost estimate: \($none) (counted in runs, not in cost)." else empty end)
' "$work/records.jsonl" | LC_ALL=C awk -F'\t' '
  /^#/ { notes = notes "\n" substr($0, 2); next }
  NR == 1 { printf "%-6s %-28s %5s %10s %12s %10s %12s %12s\n", $1, $2, $3, $4, $5, $6, $7, $8; next }
  { printf "%-6s %-28s %5d %10.2f %12.0f %10.0f %12.0f %12.0f\n", $1, $2, $3, $4, $5, $6, $7, $8 }
  END { if (notes != "") print notes }
'
[[ $failed -eq 0 ]] || echo "cost-report.sh: some API calls failed, the totals are incomplete" >&2
exit $failed
