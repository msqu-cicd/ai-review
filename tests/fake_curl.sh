#!/usr/bin/env bash
# Stand-in for curl in tests: serves the URL's path below /repos/OWNER/REPO/ from
# $FAKE_API_DIR into the file given with -o; "/", "?", "&" and "=" become "_" and ".json" is
# appended (pulls/7/reviews?limit=50&page=1 -> pulls_7_reviews_limit_50_page_1.json). A missing
# file or FAKE_API_FAIL=1 exits 22, like curl -f on an HTTP error.
set -euo pipefail
out="" url=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -H | --retry | --max-time) shift 2 ;;
    *) url=$1; shift ;;
  esac
done
[[ -z ${FAKE_API_FAIL:-} ]] || exit 22
name=$(tr '/?&=' '____' <<<"${url#*/repos/*/*/}").json
[[ -f $FAKE_API_DIR/$name ]] || exit 22
cp "$FAKE_API_DIR/$name" "$out"
