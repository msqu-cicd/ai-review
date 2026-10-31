#!/usr/bin/env bash
# Stand-in for tea in tests: answers `tea api --login git ENDPOINT` from $FAKE_API_DIR; "/", "?",
# "&", "=" and ":" become "_" and ".json" is appended (orgs/Ansible/repos?limit=50&page=1 ->
# orgs_Ansible_repos_limit_50_page_1.json). Appends each endpoint to $FAKE_TEA_LOG when set. A
# missing file prints a Gitea error object and exits 0, like tea api on an HTTP error. Anything
# but a GET exits 3.
set -euo pipefail
[[ ${1:-} == api ]] || exit 2
shift
endpoint=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --login) shift 2 ;;
    -X | --method) [[ $2 == GET ]] || exit 3; shift 2 ;;
    -d | --data | -f | --field | -F | --Field) exit 3 ;;
    *) endpoint=$1; shift ;;
  esac
done
[[ -z ${FAKE_TEA_LOG:-} ]] || printf '%s\n' "$endpoint" >> "$FAKE_TEA_LOG"
name=$(tr '/?&=:' '_____' <<<"$endpoint").json
if [[ -f $FAKE_API_DIR/$name ]]; then
  cat "$FAKE_API_DIR/$name"
else
  echo '{"errors": null, "message": "The target could not be found."}'
fi
