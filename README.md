# ai-review

Claude Code reviews pull requests on git.msqu.de. A reusable Gitea Actions workflow in this
repository runs one `claude -p` call per pull request (or per whole-repository audit) on the
owner's Claude subscription and posts the result as a Gitea PR review or issue. Each target
repository carries a short caller workflow; everything else lives here.

Design: [docs/superpowers/specs/2026-10-30-gitea-ai-review-design.md](docs/superpowers/specs/2026-10-30-gitea-ai-review-design.md).
Plan: [docs/superpowers/plans/2026-10-30-gitea-ai-review.md](docs/superpowers/plans/2026-10-30-gitea-ai-review.md).

## Caller

The caller template and the input reference arrive with the reusable workflow (plan Task 8).

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
