#!/usr/bin/env python3
"""How the owner's infrastructure repository uses an Ansible role, as Markdown for the reviewer.

usage: infra-digest.py ROLE_DIR INFRA_DIR [ROLE_NAME] > infra.md

Names, file locations and value types only, never values: the infrastructure repository holds
plaintext secrets. Sections:
- which infra playbooks apply the role, under which when: clauses, on which inventories;
- for every variable the role defines (defaults/main.yml, meta/argument_specs.yml): where infra
  sets it and the type of each value;
- variables infra sets with the role's prefix that the role does not define (a rename or a typo
  leaves the old name set in infra);
- variables the role reads but does not define that infra sets (shared variables).
Output is capped at MAX_BYTES. Exit 0 with no output when the role is not used by infra.
"""
import os
import re
import sys

import yaml

MAX_BYTES = 12000
# As in the infra Makefile: server playbooks run per server inventory, the workstation playbooks on
# workstations.yml, github.yml on localhost.yml.
SERVER_EXCLUDE = {"workstations.yml", "localhost.yml"}
VAR_NAME = re.compile(r"\b[a-zA-Z_][a-zA-Z0-9_]*\b")


class TagLoader(yaml.SafeLoader):
    """Reads !vault, !unsafe and other custom tags; keeps the tag name, drops the content."""


def _tagged(loader, suffix, node):
    return Tagged(suffix)


class Tagged:
    def __init__(self, tag):
        self.tag = tag


TagLoader.add_multi_constructor("!", _tagged)


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return None
    if text.startswith("$ANSIBLE_VAULT"):
        return Tagged("vault-file")
    try:
        return yaml.load(text, Loader=TagLoader)
    except yaml.YAMLError:
        return None


def type_of(value):
    if isinstance(value, Tagged):
        return "vault-encrypted" if value.tag in ("vault", "vault-file") else f"!{value.tag}"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    if value is None:
        return "null"
    if isinstance(value, str):
        return "template" if "{{" in value or "{%" in value else "str"
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "dict"
    return type(value).__name__


def rel(path, base):
    return os.path.relpath(path, base)


# --- where infra sets variables -------------------------------------------------------------

def var_files(infra_dir):
    """(file, mapping of variables) for group_vars, host_vars and the vars inside inventories."""
    for sub in ("group_vars", "host_vars"):
        for root, _, files in os.walk(os.path.join(infra_dir, sub)):
            for fname in sorted(files):
                if fname.endswith((".yml", ".yaml")) or "." not in fname:
                    path = os.path.join(root, fname)
                    data = load(path)
                    if isinstance(data, dict):
                        yield rel(path, infra_dir), "", data
    inv_dir = os.path.join(infra_dir, "inventories")
    if os.path.isdir(inv_dir):
        for fname in sorted(os.listdir(inv_dir)):
            data = load(os.path.join(inv_dir, fname)) if fname.endswith((".yml", ".yaml")) else None
            if isinstance(data, dict):
                yield from inventory_vars(f"inventories/{fname}", data, "")


def inventory_vars(fname, node, where):
    """Walk an inventory: vars of groups and hosts, labelled with the group or host."""
    if not isinstance(node, dict):
        return
    for group, body in node.items():
        if not isinstance(body, dict):
            continue
        label = f"{where}{group}"
        if isinstance(body.get("vars"), dict):
            yield fname, f"group {group}", body["vars"]
        for host, hvars in (body.get("hosts") or {}).items():
            if isinstance(hvars, dict):
                yield fname, f"host {host}", hvars
        yield from inventory_vars(fname, body.get("children") or {}, label + "/")


def infra_settings(infra_dir):
    """name -> list of (file, scope, type)."""
    found = {}
    for fname, scope, data in var_files(infra_dir):
        for name, value in data.items():
            if isinstance(name, str):
                found.setdefault(name, []).append((fname, scope, type_of(value)))
    return found


# --- which playbooks apply the role ---------------------------------------------------------

def as_list(when):
    if when is None:
        return []
    return when if isinstance(when, list) else [when]


def walk_tasks(tasks, inherited=()):
    for task in tasks or []:
        if not isinstance(task, dict):
            continue
        when = [*inherited, *as_list(task.get("when"))]
        if any(k in task for k in ("block", "rescue", "always")):
            for key in ("block", "rescue", "always"):
                yield from walk_tasks(task.get(key), when)
        else:
            yield task, when


def applications(infra_dir, name):
    """(playbook, when clauses) for every play entry that applies the role."""
    entries = []
    for fname in sorted(os.listdir(infra_dir)):
        if not fname.endswith((".yml", ".yaml")):
            continue
        plays = load(os.path.join(infra_dir, fname))
        if not isinstance(plays, list):
            continue
        for play in plays:
            if not isinstance(play, dict) or "hosts" not in play:
                continue
            for item in play.get("roles") or []:
                rname = (item.get("role") or item.get("name")) if isinstance(item, dict) else item
                if rname == name:
                    entries.append((fname, as_list(item.get("when") if isinstance(item, dict) else None)))
            for section in ("pre_tasks", "tasks", "post_tasks"):
                for task, when in walk_tasks(play.get(section)):
                    for key in ("ansible.builtin.include_role", "ansible.builtin.import_role", "include_role", "import_role"):
                        args = task.get(key)
                        if isinstance(args, dict) and args.get("name") == name:
                            entries.append((fname, when))
    return entries


def inventories_for(infra_dir, playbook):
    inv_dir = os.path.join(infra_dir, "inventories")
    names = sorted(f for f in os.listdir(inv_dir) if f.endswith((".yml", ".yaml"))) if os.path.isdir(inv_dir) else []
    if playbook.startswith("workstation"):
        return [n for n in names if n == "workstations.yml"]
    if playbook == "github.yml":
        return [n for n in names if n == "localhost.yml"]
    return [n for n in names if n not in SERVER_EXCLUDE]


# --- the role -------------------------------------------------------------------------------

def role_name(role_dir, fallback):
    meta = load(os.path.join(role_dir, "meta", "main.yml"))
    info = meta.get("galaxy_info") if isinstance(meta, dict) else None
    if isinstance(info, dict) and info.get("role_name"):
        return info["role_name"]
    return fallback.replace("-", "_")


def role_variables(role_dir):
    names = set()
    for sub in ("defaults", "vars"):
        data = load(os.path.join(role_dir, sub, "main.yml"))
        if isinstance(data, dict):
            names.update(k for k in data if isinstance(k, str))
    spec = load(os.path.join(role_dir, "meta", "argument_specs.yml"))
    if isinstance(spec, dict):
        for entry in (spec.get("argument_specs") or {}).values():
            if isinstance(entry, dict):
                names.update((entry.get("options") or {}).keys())
    return names


def role_words(role_dir):
    """Identifiers that appear anywhere in the role's tasks, handlers, templates, defaults and vars."""
    words = set()
    for sub in ("tasks", "handlers", "templates", "defaults", "vars", "meta"):
        for root, _, files in os.walk(os.path.join(role_dir, sub)):
            for fname in files:
                try:
                    with open(os.path.join(root, fname), encoding="utf-8", errors="replace") as fh:
                        words.update(VAR_NAME.findall(fh.read()))
                except OSError:
                    pass
    return words


def settings_lines(name, settings, limit=8):
    rows = settings.get(name, [])
    out = [f"{f}{' (' + s + ')' if s else ''}: {t}" for f, s, t in rows[:limit]]
    if len(rows) > limit:
        out.append(f"... {len(rows) - limit} more")
    return "; ".join(out)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    role_dir, infra_dir = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    name = role_name(role_dir, sys.argv[3] if len(sys.argv) > 3 else os.path.basename(role_dir))
    apps = applications(infra_dir, name)
    settings = infra_settings(infra_dir)
    defined = role_variables(role_dir)
    prefix = name + "_"
    lines = [f"Generated from the infrastructure repository's main branch for role `{name}`: names, file locations and value types only (`template` = a Jinja expression; values are never shown).", ""]

    lines.append("### Where infra applies the role")
    if apps:
        for playbook, clauses in apps:
            cond = " and ".join(str(c) for c in clauses) or "always"
            lines.append(f"- `{playbook}` when `{cond}`, inventories: {', '.join(inventories_for(infra_dir, playbook)) or 'none'}")
            for clause in clauses:
                for gate in sorted(set(VAR_NAME.findall(str(clause))) & set(settings)):
                    lines.append(f"  - `{gate}` set in: {settings_lines(gate, settings)}")
    else:
        lines.append("- No infra playbook applies this role.")

    lines.append("")
    lines.append("### Role variables that infra sets")
    hits = sorted(n for n in defined if n in settings)
    if hits:
        lines += [f"- `{n}`: {settings_lines(n, settings)}" for n in hits]
    else:
        lines.append("- None: infra keeps every default.")

    unknown = sorted(n for n in settings if n.startswith(prefix) and n not in defined)
    lines.append("")
    lines.append(f"### Variables infra sets with the prefix `{prefix}` that the role does not define")
    if unknown:
        lines += [f"- `{n}`: {settings_lines(n, settings)}" for n in unknown]
    else:
        lines.append("- None.")

    shared = sorted(n for n in (role_words(role_dir) & set(settings)) - defined
                    if not n.startswith(("ansible_", "item", "inventory_")) and len(n) > 3)
    lines.append("")
    lines.append("### Variables the role reads without defining them, set by infra")
    if shared:
        lines += [f"- `{n}`: {settings_lines(n, settings, 4)}" for n in shared]
    else:
        lines.append("- None.")

    text = "\n".join(lines) + "\n"
    if len(text.encode()) > MAX_BYTES:
        text = text.encode()[:MAX_BYTES].decode(errors="ignore") + "\n\n[cut: digest longer than %d bytes]\n" % MAX_BYTES
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
