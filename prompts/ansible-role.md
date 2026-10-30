This repository is an Ansible role or playbook collection. Its conventions, in addition to the general rules:

- Development order and intent: `meta/main.yml` states what the role is for; `defaults/main.yml` holds every user-facing variable; `vars/main.yml` holds role-internal values and mappings; tasks implement, nothing more.
- Every module is called by its fully qualified collection name (`ansible.builtin.file`, not `file`).
- Modules are preferred over `ansible.builtin.shell` and `ansible.builtin.command`; a shell task needs a reason and `changed_when`/`creates`.
- Every `ansible.builtin.file`, `copy`, `template` and `unarchive` task sets `owner`, `group` and `mode`.
- Lists in `when`, `failed_when`, `notify` and similar keys are written vertically, one item per line.
- No Jinja expressions inside tasks or handlers when a mapping in `vars/main.yml` can select the value.
- Error handling uses `block`/`rescue`, never `failed_when: true` or `ignore_errors: true`.
- Colons, not equals signs, wherever the module accepts both.
- Variable names carry the role name as prefix (`xyz_` in role `xyz`), including registered variables.
- `tasks/assert.yml` and `meta/argument_specs.yml` must cover every variable in `defaults/main.yml`; a default without both is a finding.
- Templates start with `{{ ansible_managed | comment }}`.
- Install and extract tasks must not assume GNU tar; portable temp-directory approaches that also work with BSD tar are expected.
- Downloads are verified with a checksum.
- The README documents every default and matches the current behaviour.
- Version pins carry a `# renovate:` marker so Renovate can bump them.
