This repository is an Ansible role or playbook collection. Its conventions, in addition to the general rules:

- Development order and intent: `meta/main.yml` states what the role is for; `defaults/main.yml` holds every user-facing variable; `vars/main.yml` holds role-internal values and mappings; tasks implement, nothing more.
- Every module is called by its fully qualified collection name (`ansible.builtin.file`, not `file`).
- Modules are preferred over `ansible.builtin.shell` and `ansible.builtin.command`; a shell task needs a reason and `changed_when`/`creates`.
- Every `ansible.builtin.file`, `copy`, `template` and `unarchive` task sets `owner`, `group` and `mode`; `ansible.builtin.file` with `state: absent` needs none of them.
- Lists in `when`, `failed_when`, `notify` and similar keys are written vertically, one item per line.
- No Jinja expressions inside tasks or handlers when a mapping in `vars/main.yml` can select the value.
- Error handling uses `block`/`rescue`, never `failed_when: true` or `ignore_errors: true`.
- Colons, not equals signs, wherever the module accepts both.
- Variable names carry the role name as prefix (`xyz_` in role `xyz`), including registered variables; internal variables named `_xyz_*` or `__xyz_*` satisfy the rule.
- `tasks/assert.yml` and `meta/argument_specs.yml` must cover every variable in `defaults/main.yml`; a default without both is a finding.
- Templates start with `{{ ansible_managed | comment }}`.
- Extraction on the controller or on macOS must not assume GNU tar; portable temp-directory approaches that also work with BSD tar are expected there. Debian targets always have GNU tar.
- Downloads are verified with a checksum.
- The README documents every default and matches the current behaviour.
- Version pins carry a `# renovate:` marker so Renovate can bump them.

Environment facts and accepted decisions. Do not report these as problems beyond what each item allows; "once" means a single finding per review or audit:

- Servers run Debian 13 (trixie) only. Code or claims for RedHat, Ubuntu, Alpine or SysV init are dead code: report them once as a nit, never as a bug. Workstation roles (repositories oh-my-zsh, mac-os, keepassxc, visual-studio-code, workstation, desktop-config) legitimately target Arch Linux and macOS as well.
- Controller and CI run ansible-core 2.20: `retries` without `until` retries until the task succeeds. `min_ansible_version` and the other `meta/main.yml` fields are galaxy metadata only: once, as a nit.
- All repositories are private (Gitea plus private GitHub mirrors): license metadata mismatches and internal hostnames are nits.
- Plays escalate privileges at play level; a task without its own `become` is not a finding.
- Shared workflows referenced at `@main` (`CICD/*`) are an accepted risk: once, as a nit.
- A problem that only affects a platform the repository does not support is at most a nit and never makes the verdict `request_changes`.
