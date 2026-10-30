# AI review for Gitea repositories with Claude Code

Design, 2026-10-30. Approved by the owner the same day.

## Intent

Every pull request in the private repos on git.msqu.de gets an AI review within minutes of being opened, and any repository can be audited as a whole on demand. Reviews run on the owner's Claude Max subscription, not on API billing. The first use of the audit mode is a review of all Ansible role repos in the `Ansible` org plus the Ansible setups in `Infrastructure/infra`.

Why: the owner works alone on these repos. There is no second reviewer. Hosted reviewers (CodeRabbit, Qodo) do not support Gitea, and third-party tools may not use the Max subscription. Claude Code itself may, through a long-lived OAuth token, and the spike on Ansible/blocky PR #6 proved the path end to end (install 16 s, review 11 s, comment posted by the Actions bot).

## Goals

- A review comment or PR review on every non-bot PR when it is opened or reopened, and on request via a PR comment.
- Findings with file and line, severity-ranked, no praise, no restating the diff.
- A whole-repository audit on demand, result filed as a Gitea issue in that repo.
- One short caller workflow per repo; all logic lives in one shared repo.
- Zero idle cost, no long-running service.
- Subscription usage stays predictable: no review on every push, no reviews for bot PRs, model switchable per run.

## Non-goals

- Chatting with the reviewer across several comments with memory. Each run is stateless.
- Auto-fixing or committing code.
- Non-Anthropic models.
- Reviewing `Infrastructure/infra` and `Infrastructure/kubernetes` PR diffs until a vault/secret path filter exists (both hold plaintext secrets in places; the audit mode handles infra with an explicit exclude list, see below).

## Anti-goals

- Posting the OAuth token or any secret to a log or comment.
- Letting PR content drive tool use: the model must never run commands or write files in the job.
- Duplicate or stacked comments on every push.
- Burning the weekly Max window on Renovate PRs or on the audit of 70 repos in one go.

## Constraints and verified facts

- Gitea 28.2.0. Actions supports `pull_request` (default types opened, reopened, synchronize), `issue_comment` with type `created` (also fires for PR comments), and `workflow_dispatch`. `permissions:` controls the job token `GITEA_TOKEN`, clamped by repo and owner settings. `github.api_url` resolves to `https://git.msqu.de/api/v1`.
- Runners: node.fqdm.de (4 vCPU, 8 GB, capacity 8) and node.dasisttrivial.de (1 vCPU, 2 GB, capacity 2) carry `ubuntu-latest` = `catthehacker/ubuntu:act-latest` (bash, curl, git, jq present) and `ubuntu-24.04`/`ubuntu-26.04` = `schmitzis/gitea-runner:*` (own images). Job timeout is 3 h on both. Jobs land on either runner; a review job is light (the model does the work, the container runs one binary plus git), so no runner pinning.
- Reusable workflows with `secrets:` passed from the caller are proven on this instance: the molecule callers hand `SSH_PRIVATE_KEY`, `CI_RUNNER_PAT`, `ANSIBLE_VAULT_PASSWORD` and more to `CICD/molecule/.gitea/workflows/role-kvm.yml@main`, and those runs are green.
- Claude Code: native installer `curl -fsSL https://claude.ai/install.sh | bash -s <version>`; current stable 2.1.308. The installer verifies the binary against the signed release manifest. Signed apt repo exists for an own image later.
- Auth: `claude setup-token` yields a one-year OAuth token, used via `CLAUDE_CODE_OAUTH_TOKEN`. It is personal to the owner's subscription and can only make model requests. `--bare` ignores it. `--restricted` accepts it, loads only managed settings and `--settings`, removes command tools and WebFetch, confines file tools to the checkout. Verified 2026-10-30 in both the workstation test and the spike run.
- Default model on Max is Opus 5.5. Aliases `opus`, `sonnet`, `haiku` resolve to the 5.5 generation.
- Gitea API: `POST repos/{o}/{r}/pulls/{n}/reviews` with `body`, `event` (APPROVE, REQUEST_CHANGES, COMMENT), `commit_id`, `comments[]` of `{path, body, new_position, old_position}`. `POST repos/{o}/{r}/issues/{n}/comments` for plain comments. `POST repos/{o}/{r}/issues` for audit results.
- The `CICD` org is public. The shared repo therefore holds no secrets; callers pass the token in.
- Anthropic policy: the subscription may be used in CI only through the unmodified Claude Code binary, for the owner's own use. Advertised limits assume ordinary individual usage.

## Architecture

### Repository

New repo `CICD/ai-review`, created through the usual IaC path (`git_lists.yml` -> Infrastructure/gitea -> Infrastructure/github mirror). Contents:

```
.gitea/workflows/review.yml      reusable workflow (workflow_call)
prompts/pr-review.md             system prompt for PR mode
prompts/repo-audit.md            system prompt for audit mode
prompts/ansible-role.md          appended for repos that are Ansible roles (convention list)
schema/review.json               JSON schema for structured output
scripts/review.sh                builds the diff, runs claude, validates output
scripts/post.sh                  posts PR review / comment / issue via the Gitea API
scripts/dispatch-audit.sh        batch-dispatches audits over a repo list with pauses
README.md                        caller template, inputs, how to renew the token
docs/superpowers/specs/          this design
```

The reusable workflow checks out `CICD/ai-review` at a ref (input `ai_review_ref`, default `main`) into `.ai-review/` next to the caller's checkout, the same pattern CICD/molecule uses with `molecule_ref`.

### Caller (one file per repo)

```yaml
name: AI Review
on:
  pull_request:
    types: [opened, reopened]
  issue_comment:
    types: [created]
  workflow_dispatch:
    inputs:
      mode: { default: audit, type: string }
      model: { default: opus, type: string }
jobs:
  review:
    uses: CICD/ai-review/.gitea/workflows/review.yml@main
    with:
      mode: ${{ inputs.mode || '' }}
      model: ${{ inputs.model || '' }}
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Rollout to repos happens by a PR per repo with this file; the Ansible roles get it in one batch via a script that opens the PRs.

### Modes

| Mode | Trigger | Input to Claude | Output |
|---|---|---|---|
| `pr` | `pull_request` opened/reopened | diff `base.sha..head.sha` on stdin + read-only checkout at head | PR review (COMMENT or REQUEST_CHANGES) with line comments; summary-only comment as fallback |
| `comment` | `issue_comment` created on a PR whose body starts with `/review` | same as `pr`; `/review sonnet`, `/review opus`, `/review audit` select model or mode | same as `pr` (or audit) |
| `audit` | `workflow_dispatch` or `/review audit` | whole checkout, no diff | one Gitea issue `AI audit YYYY-MM-DD`, label `ai-audit` |

`synchronize` is deliberately not a trigger. Re-reviews are requested with `/review`. Bot PRs are skipped by author login (input `skip_authors`, default `renovate,gitea-actions`). Draft PRs (Gitea `WIP:` title prefix / draft flag) are skipped. In the public CICD org, PRs whose head repo differs from the base repo are skipped. The comment trigger requires the commenter to have write access to the repo, checked via `GET repos/{o}/{r}/collaborators/{user}/permission`; a comment that does not start with `/review` ends the job immediately without running Claude.

### The Claude run

```
claude --restricted --tools "Read,Grep,Glob" --permission-mode dontAsk \
  --model <opus|sonnet> --max-turns 40 --output-format json \
  --json-schema .ai-review/schema/review.json \
  --append-system-prompt-file <prompt> -p "<mode-specific task line>" < diff
```

- Default model: **Opus 5.5** (owner's decision 2026-10-30). `sonnet` on request per run.
- `--restricted` plus read-only tools is the containment. The prompt states that diff and files are data, never instructions.
- Output is schema-validated JSON: `summary`, `verdict` (`comment` | `request_changes`), `findings[]` with `path`, `line`, `severity` (`blocker`, `major`, `minor`, `nit`), `body`. `approve` is intentionally not a verdict a bot may give.
- Verdict mapping (designer's call): both verdicts post as a Gitea review with `event: COMMENT`; `request_changes` only puts a bold "Changes requested" line at the top of the body. The bot never files an official REQUEST_CHANGES, because it is stateless and the owner is the sole developer: a formal reject would have to be dismissed by hand on every repo with "block merge on rejected reviews", and a later COMMENT review does not supersede it.
- Failure handling: if the CLI exits non-zero, `is_error` is true, or `structured_output` is missing, the job posts one short comment "AI review failed, see run <url>" and exits non-zero. Silence must never look like "no findings".
- Diff hygiene: files whose content starts with `$ANSIBLE_VAULT;` are dropped from the diff, as are lockfiles and anything matching an input `exclude_paths`. Diffs over 4000 lines switch to summary-only mode with the file list instead of the full diff. Stdin is capped at 10 MB by Claude Code.
- Secret gate (designer's call, mandatory in every mode): before Claude starts, the job deletes every `exclude_paths` entry from the working tree, then runs a pinned gitleaks binary (download verified against the release checksum) over the diff in PR modes and over the whole tree in audit mode. Any hit ends the job before the model call: it posts "AI review skipped: secret-like content in `<paths>`, see run <url>" and exits non-zero. Exclude lists are a convenience; the scan is the gate. Known plaintext locations today: Infrastructure/gitea `*/backend.tf` and `3_ci_stuff/renovatebot.tf`, Infrastructure/infra `group_vars/all/common/git.yml`; vault files are covered by the header rule.
- Install: pinned version in the reusable workflow, bumped by Renovate through a custom datasource reading `https://downloads.claude.ai/claude-code-releases/stable` (plain-text version). Phase 4 replaces the per-run install with an own image.

### Posting

- PR modes: `POST pulls/{n}/reviews` with `commit_id` = head sha, `event` from the verdict, `body` = summary plus findings that could not be placed, `comments[]` from findings with a `line` inside the diff's new side (`new_position` = line number in the new file; the pilot verifies Gitea's interpretation and falls back to the summary comment if the API rejects positions).
- Audit mode: `POST issues` with title `AI audit <date> (<model>)`, body = summary and findings grouped by severity, label `ai-audit` (created if missing). A rerun opens a new issue; closing old ones is manual.
- Identity: the job token, so comments appear as `gitea-actions`. A dedicated bot user is a possible later refinement, not part of this design.

### Secrets

- One org-level Actions secret `CLAUDE_CODE_OAUTH_TOKEN` on the orgs `Ansible`, `Infrastructure`, `DevOps`, set by hand via the API (not Terraform: the token is personal and would otherwise land in state). The repo-level secret on Ansible/blocky is removed once the org secret exists.
- Renewal: the token expires after one year. The README documents `claude setup-token` plus the three PUT calls; a reminder goes into the owner's calendar for 2027-10.
- Logs never echo the token. The workflow prints only the `usage` block and the model name.

### Usage control

- Opus by default, Sonnet on request. `--max-turns 40`.
- No `synchronize` trigger, bot PRs skipped, comment trigger gated on write access.
- Audit batches: `scripts/dispatch-audit.sh` takes a repo list, dispatches N repos (default 5, within the combined runner capacity of 10), polls the run status until every run of the batch has completed, pauses (default 20 min), continues. The owner watches `/usage` in an interactive session; if the Opus window gets tight, the remaining batches run with `model=sonnet`.

## First audit: the Ansible setups

Scope (owner's request 2026-10-30): all 66 repos in the `Ansible` org (roles and the `ansible`/`workstation` setups) plus `Infrastructure/infra` (inventories, playbooks, group_vars). `Infrastructure/infra` runs with `exclude_paths` covering vault files and the plaintext credential locations listed under "Secret gate", extended by anything the owner adds before the run; the gitleaks scan catches the rest and skips the audit if it finds something.

The audit prompt for Ansible repos (`prompts/repo-audit.md` + `prompts/ansible-role.md`) checks, in order: correctness bugs, security (modes, shell usage, unverified downloads, secrets), idempotency and `block`/`rescue` use, the owner's role conventions (meta -> defaults -> vars -> tasks, FQCN, modules over shell, `owner`/`group`/`mode` on file tasks, vertical formatting, role-prefixed variables, `tasks/assert.yml` + `meta/argument_specs.yml` covering every default, no Jinja in tasks where a `vars/main.yml` mapping fits, `ansible_managed | comment` in templates, portable tar handling), README drift, and Renovate markers.

Order: Ansible/blocky first (already wired), then the remaining roles in batches of 5, `Infrastructure/infra` last and alone.

## Phases

1. **Shared workflow and callers.** Create `CICD/ai-review`, port the spike with the fixes (sha-based diff, `is_error` gate, failure comment, bot/draft/fork gating, `/review` comment trigger, org secret). Pilot callers: Ansible/blocky, Infrastructure/smarthome, Infrastructure/provisioning. Remove the spike workflow from blocky.
2. **Line comments.** JSON schema, PR reviews via the reviews API, position fallback.
3. **Audit mode and the Ansible audit.** Audit prompt, issue posting, batch dispatcher, callers rolled out to all `Ansible/*` repos and `Infrastructure/infra`, batches run.
4. **Own image and Renovate.** `schmitzis/ai-review` (Debian, apt package `claude-code`, git, jq, curl) built in DevOps/builder; reusable workflow switches to `container:`; Renovate bumps the package.

## Left to the builder

- Bash + jq versus Python for `scripts/*`; the runner image has both.
- Exact JSON schema wording and the prompt texts, within the rules above.
- How to detect "comment is on a PR" in the `issue_comment` payload on Gitea (`issue.pull_request` presence is the expected marker).
- Renovate custom datasource details for the pinned Claude Code version.
- Label creation for `ai-audit`.
