# ai-review

Claude Code reviews pull requests on git.msqu.de. A reusable Gitea Actions workflow in this
repository runs one `claude -p` call per pull request (or per whole-repository audit) on the
owner's Claude subscription and posts the result as a Gitea PR review or issue. Each target
repository carries a short caller workflow; everything else lives here.

Design: [docs/superpowers/specs/2026-10-30-gitea-ai-review-design.md](docs/superpowers/specs/2026-10-30-gitea-ai-review-design.md).
Plan: [docs/superpowers/plans/2026-10-30-gitea-ai-review.md](docs/superpowers/plans/2026-10-30-gitea-ai-review.md).

## Caller

Each repository carries `.gitea/workflows/ai-review.yml`, a copy of
[examples/caller-ai-review.yml](examples/caller-ai-review.yml). It reviews pull requests when they
are opened or reopened, re-reviews on a `/review` comment, and audits the whole repository on
`workflow_dispatch`. Pushes to an open PR do not trigger a review; ask for one with a comment.

### `/review` comments

Only the first line counts and the commenter needs write access to the repository.

| Comment | Effect |
| --- | --- |
| `/review` | review the PR again with Opus |
| `/review sonnet` | review with Sonnet |
| `/review audit` | audit the whole repository at the PR head into an issue |
| `/review sonnet audit` | the same with Sonnet |

### Inputs of the reusable workflow

| Input | Default | Meaning |
| --- | --- | --- |
| `mode` | derived from the event | `pr`, `comment` or `audit` |
| `model` | `opus` | `opus` or `sonnet` |
| `skip_authors` | `renovate,gitea-actions` | PR authors whose PRs are not reviewed |
| `exclude_paths` | empty | comma-separated globs deleted from the checkout and dropped from the diff before anything is sent; a directory covers everything below it |
| `max_diff_lines` | `4000` | above this the model gets the list of changed files instead of the diff |
| `ai_review_ref` | `main` | ref of this repository to run |

The secret `CLAUDE_CODE_OAUTH_TOKEN` must be passed by the caller (an org secret, see below).

### What a run does

1. Gate: skips bot authors, drafts, PRs from other repositories, comments without `/review`, and
   commenters without write access.
2. Checks out the PR head, installs the pinned Claude Code, deletes `exclude_paths` and runs
   gitleaks over the tree. Any hit ends the run with a short PR comment and no model call.
   In PR mode `review.sh` also scans the filtered diff it would send (deleted files and removed
   lines are not in the tree), with the same outcome on a hit.
   gitleaks always uses `scripts/gitleaks.toml` (its built-in rules) and ignores `gitleaks:allow`
   comments; the checkout's `.gitleaksignore` is deleted first. Nothing in the PR head can switch
   the gate off; to keep files away from the model, list them in `exclude_paths`.
3. One `claude -p` in restricted mode with read-only tools over the diff (or the checkout for
   audits), structured JSON output. The system prompt is the mode prompt plus, for Ansible
   repositories, `prompts/ansible-role.md` (conventions plus environment facts and accepted
   decisions: Debian 13 servers, ansible-core 2.20, private repositories, play-level `become`).
4. Posts a PR review with inline comments (never an approval or a formal rejection), or an issue
   labelled `ai-audit` for audits. The review body starts with **Changes requested** exactly when
   at least one finding is a blocker or major; the prompts keep problems that only affect an
   unsupported platform at nit. A failed run leaves one comment pointing at the run log.

## Tests

```bash
tests/run.sh
```

Needs bash and jq. `GITLEAKS_TEST=1 tests/run.sh` also runs the tests that download gitleaks.

## Token lifecycle

The workflow authenticates with a long-lived Claude Code OAuth token, created by the subscription
owner with:

```bash
claude setup-token
```

The token prints once and is saved nowhere. It is valid for one year and can only make model
requests. Store it as the Actions secret `CLAUDE_CODE_OAUTH_TOKEN` on each org that runs reviews
(`Ansible`, `Infrastructure`, `DevOps`): write `{"data": "<token>"}` to a file with mode 600, then

```bash
tea api --login git -X PUT orgs/<org>/actions/secrets/CLAUDE_CODE_OAUTH_TOKEN -d @secret.json
```

and delete the file. Never paste the token into a terminal that is being logged or into a chat.
Renewal is due one year after minting; put the date in the calendar when you set the secret.

Current token: minted 2026-10-30, set on the orgs `Ansible`, `Infrastructure` and `DevOps` the same
day, expires 2027-10-30. Repo-level copies are not used.
