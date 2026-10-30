#!/usr/bin/env bash
# Stand-in for the claude binary in tests: drains stdin, records its arguments in
# $FAKE_CLAUDE_ARGS_FILE (one per line) when set, and prints $FAKE_CLAUDE_OUTPUT.
set -euo pipefail
[[ -t 0 ]] || cat > /dev/null
if [[ -n ${FAKE_CLAUDE_ARGS_FILE:-} ]]; then
  printf '%s\n' "$@" > "$FAKE_CLAUDE_ARGS_FILE"
fi
cat "$FAKE_CLAUDE_OUTPUT"
