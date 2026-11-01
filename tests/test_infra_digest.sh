# shellcheck shell=bash
# The expected strings contain literal Markdown backticks, single quotes are intended.
# shellcheck disable=SC2016
# Tests for scripts/infra-digest.py: names, locations and types, never values.

# A python3 with PyYAML: the system one if it has it, otherwise a venv from requirements-digest.txt.
digest_python() {
  if python3 -c 'import yaml' 2> /dev/null; then
    echo python3
    return
  fi
  local venv=${TMPDIR:-/tmp}/ai-review-digest-venv
  if [[ ! -x $venv/bin/python ]]; then
    python3 -m venv "$venv" && "$venv/bin/pip" install -q -r scripts/requirements-digest.txt > /dev/null
  fi
  echo "$venv/bin/python"
}

# digest_fixture DIR: a role "docker" and an infra tree that applies it and sets its variables.
digest_fixture() {
  local d=$1
  mkdir -p "$d/role/defaults" "$d/role/meta" "$d/role/tasks" "$d/infra/group_vars/all" "$d/infra/inventories"
  printf 'galaxy_info:\n  role_name: docker\n' > "$d/role/meta/main.yml"
  printf 'docker_port: 2375\ndocker_secret: ""\ndocker_users: []\n' > "$d/role/defaults/main.yml"
  printf -- '- name: Use a shared variable\n  ansible.builtin.debug:\n    msg: "{{ shared_domain }}"\n' > "$d/role/tasks/main.yml"
  printf -- '- name: Site\n  hosts: all\n  roles:\n    - role: docker\n      when: configure_docker | default(false)\n' > "$d/infra/site.yml"
  cat > "$d/infra/group_vars/all/docker.yml" <<'YAML'
docker_port: "2376"
docker_secret: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  6162636465
docker_old_name: plaintextvalue123
shared_domain: "{{ 'example' }}.org"
YAML
  printf 'all:\n  hosts:\n    node.example.org:\n      configure_docker: true\n      docker_users: [a]\n' > "$d/infra/inventories/example.yml"
}

test_infra_digest_names_types_no_values() {
  local d py out
  d=$(mktemp -d)
  digest_fixture "$d"
  py=$(digest_python)
  out=$("$py" scripts/infra-digest.py "$d/role" "$d/infra")
  assert_contains "$out" '`site.yml` when `configure_docker | default(false)`, inventories: example.yml'
  assert_contains "$out" '`configure_docker` set in: inventories/example.yml (host node.example.org): bool'
  assert_contains "$out" '`docker_port`: group_vars/all/docker.yml: str'
  assert_contains "$out" '`docker_secret`: group_vars/all/docker.yml: vault-encrypted'
  assert_contains "$out" '`docker_users`: inventories/example.yml (host node.example.org): list'
  assert_contains "$out" '`shared_domain`: group_vars/all/docker.yml: template'
  [[ $out != *plaintextvalue123* && $out != *6162636465* && $out != *2376* ]] || { echo "digest leaked a value" >&2; return 1; }
}

test_infra_digest_reports_unknown_prefixed_names() {
  local d py out
  d=$(mktemp -d)
  digest_fixture "$d"
  py=$(digest_python)
  out=$("$py" scripts/infra-digest.py "$d/role" "$d/infra")
  assert_contains "$out" '`docker_old_name`: group_vars/all/docker.yml: str'
}

test_infra_digest_role_not_applied() {
  local d py out
  d=$(mktemp -d)
  digest_fixture "$d"
  rm "$d/infra/site.yml"
  py=$(digest_python)
  out=$("$py" scripts/infra-digest.py "$d/role" "$d/infra")
  assert_contains "$out" 'No infra playbook applies this role.'
}
