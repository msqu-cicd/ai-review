# shellcheck shell=bash
# Smoke tests for the test harness itself (tests/run.sh + tests/helpers.sh).

test_assert_eq_passes() {
  assert_eq foo foo
}

test_assert_json_eq_ignores_key_order() {
  assert_json_eq '{"a": 1, "b": [1, 2]}' '{"b": [1, 2], "a": 1}'
}
