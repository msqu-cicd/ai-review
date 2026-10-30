# shellcheck shell=bash
# Tests for scripts/dispatch-audit.sh (dry-run only; the real runs talk to Gitea via tea).

test_dispatch_dry_run_batches() {
  local l
  l=$(mktemp)
  printf 'Ansible/a\nAnsible/b\n# skip\nAnsible/c\n' > "$l"
  assert_eq $'batch 1: Ansible/a Ansible/b\nbatch 2: Ansible/c' "$(scripts/dispatch-audit.sh "$l" --batch 2 --dry-run)"
}

test_dispatch_rejects_bad_model() {
  local l
  l=$(mktemp)
  printf 'Ansible/a\n' > "$l"
  assert_exit 2 scripts/dispatch-audit.sh "$l" --model haiku --dry-run
}
