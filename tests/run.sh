#!/usr/bin/env bash
# Test runner: every tests/test_*.sh is sourced in its own subshell together with
# tests/helpers.sh and scripts/lib.sh (when present); every function named test_* in
# that file runs once. A test passes when the function returns 0. Prints PASS/FAIL
# counts and exits 1 if anything failed. Run from anywhere; it cd's to the repo root.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
export TESTS_DIR="$PWD/tests"
export REPO_ROOT="$PWD"

command -v jq >/dev/null || { echo "tests/run.sh: jq is required" >&2; exit 2; }

pass=0
fail=0
out=$(mktemp)
trap 'rm -f "$out"' EXIT

load() {
  # shellcheck source=tests/helpers.sh
  source "$TESTS_DIR/helpers.sh"
  if [[ -f scripts/lib.sh ]]; then
    # shellcheck source=scripts/lib.sh
    source scripts/lib.sh
  fi
  # shellcheck disable=SC1090
  source "$1"
}

for file in tests/test_*.sh; do
  mapfile -t fns < <(bash -c "$(declare -f load); load '$file'; declare -F" | awk '$3 ~ /^test_/ {print $3}')
  for fn in "${fns[@]}"; do
    if ( set -e; load "$file"; "$fn" ) >"$out" 2>&1; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "FAIL ${file}::${fn}"
      sed 's/^/    /' "$out"
    fi
  done
done

echo "PASS $pass FAIL $fail"
[[ $fail -eq 0 ]]
