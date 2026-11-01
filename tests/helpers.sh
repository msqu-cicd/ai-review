# shellcheck shell=bash
# Assertion helpers for the shell tests. Sourced by tests/run.sh before each test file.
# Every assert returns 1 on failure and prints the mismatch to stderr; tests run under
# `set -e`, so a failing assert ends the test function.

assert_eq() {
  local expected=$1 actual=$2 msg=${3:-}
  if [[ "$expected" == "$actual" ]]; then
    return 0
  fi
  printf 'assert_eq failed%s\n  expected: %s\n  actual:   %s\n' \
    "${msg:+ ($msg)}" "$expected" "$actual" >&2
  return 1
}

# Compare two JSON documents ignoring key order and whitespace.
assert_json_eq() {
  local expected actual
  expected=$(jq -S . <<<"$1") || { echo "assert_json_eq: expected value is not JSON" >&2; return 1; }
  actual=$(jq -S . <<<"$2") || { echo "assert_json_eq: actual value is not JSON" >&2; return 1; }
  assert_eq "$expected" "$actual" "${3:-}"
}

# assert_contains HAYSTACK NEEDLE: HAYSTACK must contain NEEDLE literally.
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then
    return 0
  fi
  printf 'assert_contains failed\n  missing: %s\n  in:\n%s\n' "$2" "$1" >&2
  return 1
}

# assert_exit CODE CMD [ARGS...]: the command must exit with CODE. Output is discarded.
assert_exit() {
  local code=$1 rc=0
  shift
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$code" "$rc" "exit code of: $*"
}

# fixture NAME: absolute path of tests/fixtures/NAME.
fixture() {
  printf '%s\n' "$TESTS_DIR/fixtures/$1"
}
