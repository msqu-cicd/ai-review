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
3. In PR modes, `scripts/history.sh` reads the earlier discussion on the PR with the job token
   into `out/history.md`: earlier AI reviews (body, inline comments and the replies under them)
   and every other comment or review by a person, oldest first, about 32 KB at most (older
   entries are dropped first). Bodies are quoted; paths, logins, times and commits are flattened
   to one line (control characters and line separators become `?`) inside backticks, so no field
   can start a line of its own. AI reviews are recognised by their author (`gitea-actions`,
   the job token's user) and heading; pending and dismissed reviews, bare `/review` commands and
   failure notices are left out. A failed fetch only means a review without history.
   Every person is marked `[maintainer]` only with write, admin or owner permission
   (`collaborators/{user}/permission`, one lookup per person) and when they did not open the PR.
   The PR author is `[PR author, not a maintainer]`, everyone else `[not a maintainer]`, also
   when the lookup fails. Gitea answers that endpoint only when the token's user is a repository admin (or the
   person asked about), so with the plain job token expect every person to be marked
   `[not a maintainer]`.
4. One `claude -p` in restricted mode with read-only tools over the diff (or the checkout for
   audits), structured JSON output. The system prompt is the mode prompt, `prompts/ansible-role.md`
   for Ansible repositories (conventions plus environment facts and accepted decisions: Debian 13
   servers, ansible-core 2.20, private repositories, play-level `become`), and the repository
   context (below). In PR modes the task carries the history, fenced as untrusted data: the model
   verifies each earlier finding against the current diff and does not repeat findings a
   `[maintainer]` entry has answered unless the code still has the problem; replies by anyone
   else never lower a finding's severity or remove it. The review step never sees the
   job token. The context file and the history go through gitleaks like the diff; on a hit they
   are left out and the review runs without them.
5. Posts a PR review with inline comments (never an approval or a formal rejection), or an issue
   labelled `ai-audit` for audits. The review body starts with **Changes requested** exactly when
   at least one finding is a blocker or major; the prompts keep problems that only affect an
   unsupported platform at nit. A failed run leaves one comment pointing at the run log.
   Each of these posts ends with the run's cost estimate as a hidden line, see
   [Cost estimate](#cost-estimate).

### Infra usage digest (Ansible roles)

With the optional secret `INFRA_READ_TOKEN` (read access to Infrastructure/infra; the role callers pass
`CI_RUNNER_PAT`), a step before the review generates `scripts/infra-digest.py`'s digest of how the
owner's infrastructure uses the role: the playbooks that apply it with their `when:` and inventories, the
role variables infra sets (file, host or group, value type), variables with the role's prefix that the role
does not define (old names after a rename), and shared variables the role reads. Names, locations and types
only, never values (quoted literals in `when:` are masked; host names stay): the infra repository holds plaintext secrets, so its sparse checkout lives in a
temporary directory outside the workspace and is deleted before the model runs, and the token reaches git
through the environment, not the command line. For pull requests the digest reads the role as of the base commit, so a change cannot choose which infra variables get listed. The digest passes the same gitleaks gate as the context
file and is appended to the system prompt with instructions to judge renames, defaults, specs and asserts
against it. PyYAML comes from `scripts/requirements-digest.txt` in a throwaway venv. Without the token,
for repositories without `meta/main.yml`, or on any error the review runs without it.

### Repository context

A repository can tell the reviewer what it cannot see in the code in
`.gitea/ai-review/context.md`, for example:

- what the repository is for and who uses it;
- the supported platforms and versions (and which ones the code deliberately ignores);
- deliberate choices that look like mistakes, with the reason;
- findings that are accepted and should not be reported again.

Keep it short and factual; only the first 8 KB are used. The file is appended to the system prompt
under "Repository context from the maintainers". It is read through git only, never from the
working tree: PR reviews take it from the base commit, never from the PR head, so a pull request
cannot change its own review instructions (a change to the file takes effect once it is merged);
audits take it from the repository's default branch (`github.event.repository.default_branch`),
whatever ref they run on, and skip it when that branch cannot be resolved or fetched. Only a
regular file counts: a symlink, or a path below a symlinked directory, is ignored.

## Cost estimate

The reviews run on the owner's Claude Max subscription. To measure what the same runs would cost
on an API key, `review.sh` reads Claude Code's result object (`--output-format json`) after every
run that reached the model, failed runs included, and writes `out/cost.json`:

```json
{"mode":"pr","model":"opus","repo":"Ansible/blocky","number":7,"timestamp":"2026-10-31T12:00:00Z","total_cost_usd":0.12,"duration_ms":9198,"num_turns":3,"input_tokens":2,"output_tokens":929,"cache_read_input_tokens":3232,"cache_creation_input_tokens":4325,"models":{"claude-opus-5-5":{"cost_usd":0.12,"input_tokens":2,"output_tokens":929,"cache_read_input_tokens":3232,"cache_creation_input_tokens":4325}}}
```

The job log gets one line, `review.sh: cost estimate $0.12 at API list prices, ...`, or
`review.sh: cost: n/a` when Claude Code reported no `total_cost_usd`; a missing field is null and
never fails the run. `model` is the model asked for, `models` what `modelUsage` reports per model
id; the token counts are summed over `modelUsage` (every model the run used) or, without it, taken
from `usage`. `number` is the pull request, null for dispatched audits.

`total_cost_usd` is Claude Code's client-side estimate at API list prices (`modelUsage` says
`"costBasis": "list"`), not what the Max subscription charges.

`post.sh` appends the record to the review body, the audit issue body and the failure notice as
one hidden line, `<!-- ai-review-cost: {...} -->`. Gitea does not render HTML comments, so the
post looks the same; the line holds numbers, the mode, the model names, the repository and the
number, nothing else. The re-review history leaves the line out. A failed audit posts nothing, so
its cost is only in the job log.

`scripts/cost-report.sh` sums the records from the workstation, read-only, with
`tea api --login git` like the other workstation scripts:

```bash
scripts/cost-report.sh                                # orgs Ansible Infrastructure DevOps CICD
scripts/cost-report.sh --since 2026-11-01 Ansible     # one org, runs from that day (UTC) on
```

It lists the repositories of the orgs in pages of 50, reads the reviews of every pull request, the
issues and the issue comments, keeps only lines posted by `gitea-actions` (`BOT_LOGIN`) and counts
a record posted twice once. It prints runs, cost and tokens per month, per model and per mode, and
the grand total. `--since` also skips issues and pull requests not updated since that day (posting
a review or comment updates them), so it is much faster than a full scan, which reads every pull
request. A failed API call is named on stderr and makes the exit status 1.

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
