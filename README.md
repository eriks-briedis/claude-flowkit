# flowkit

A shared collection of Claude Code commands and skills built to help engineering teams get more out of AI-assisted development. It isn't tied to any single workflow — today it covers turning underspecified tasks into a scoped implementation plan before code gets touched, triaging and reviewing pull requests (fast single-pass or thorough multi-agent), and keeping comments and diffs clean before merge. New commands and skills get added as the team finds more places AI assistance pays off.

Packaged as a plugin so a team can install and update these as a single unit, instead of copying files into `~/.claude/commands` by hand.

## What's included today

**Commands** (`commands/`)

| Command | Purpose |
|---|---|
| `/pr-review-loop` | Finds every open PR that needs your attention — never reviewed, or with new commits/comments since your last review — and loops through them one at a time: pulls PR description/discussion from `gh`, asks you for the ticket's title/description, checks out the branch, and runs `/review-quick`. |
| `/review-quick` | Fast single-pass code review against ticket context. Pulls CI status from the PR instead of re-running lint/tests locally, and prints findings pre-formatted as copy/paste-ready GitHub PR comments — it never posts anything itself. Remembers past passes per PR so a finding you saw and chose not to comment on isn't re-flagged unless it's gotten worse. |
| `/review` | Thorough multi-agent code review (five parallel agents: bugs, regressions, quality, risk, test coverage) against `ticket.md`. Slower and more expensive than `/review-quick` — use it for anything genuinely high-risk or unusually large, not for triaging a queue. |
| `/address-pr-comments` | The other side of a review: on your own feature branch, pulls every *unresolved* comment thread on the PR, runs `preflight-spec` over the whole batch to research and scope the work, implements it, then verifies thread-by-thread that each point is actually addressed. Prints copy-paste-ready replies, including an explicit "no reply needed" where that's the right call. Built to be re-run as review rounds go by: it remembers what it already addressed, so a follow-up review surfaces only genuinely new comments and reviewer pushback on earlier fixes. Never posts, commits, or pushes. |
| `/comment-cleanup` | Reviews comments in your *uncommitted* diff and deletes/shortens ones that don't earn their keep. Never touches code, never adds new comments. |
| `/review-best-practices` | Structured code-quality review (DRY, separation of concerns, naming, complexity, plus an Angular-specific dimension when the repo looks like Angular) against the current branch vs. its base. |

**Skills** (`skills/`)

| Skill | Purpose |
|---|---|
| `preflight-spec` | Auto-loads for vague/underspecified coding tasks. Turns the ask into a short goal/non-goals/acceptance-criteria/verification spec and gets confirmation before editing production code. |

**Scripts** (`scripts/`)

- `pr-needs-review.sh` — deterministic backing script for `/pr-review-loop`'s "which PRs need me" step. Run from inside a `gh`-authenticated repo; outputs JSON. Kept as a plain script (not re-derived by the model each run) because the filtering logic here is pure timestamp/state comparison, not judgment.
- `pr-comment-threads.sh` — same idea for `/address-pr-comments`: fetches the unresolved comment threads, review summaries, and PR comments on the current branch's PR, excluding resolved threads and your own comments, and outputs JSON with a stable id per item. Uses GraphQL `pullRequest.reviewThreads` because thread *resolution state* isn't available from `gh pr view --json comments` or the REST comments endpoint — which is precisely why it's a script and not something the model reassembles each run.

## Requirements

- `gh` CLI, authenticated against the target repo's GitHub remote (`gh auth status`)
- `git`, `jq`
- Run from inside the target git repository — these commands operate on "the current repo/branch," they don't take a repo argument

## Notes on state

- `/review-quick`'s per-PR memory lives at `~/.claude/pr-review-memory/<owner>__<repo>/<pr-number>.json` on each user's own machine — this is personal reviewer state (what you chose to comment on vs. skip), not something the plugin ships or syncs. Nothing to configure.
- `/address-pr-comments` keeps its own per-PR memory at `~/.claude/pr-comment-memory/<owner>__<repo>/<pr-number>.json` — deliberately a separate namespace, because it's author-side state (feedback you received and what you did about it) rather than reviewer-side state. Entries are keyed by GitHub's stable thread node id, so they survive threads being resolved and renumbered between review rounds.
- None of these commands push, commit, or post to GitHub on your behalf. `/pr-review-loop` and `/review-quick` are explicitly display-only by design — you copy the comments they generate into GitHub yourself. `/address-pr-comments` is the only command that edits code, and it stops at a dirty working tree: reviewing, committing, pushing, and replying stay with you.

## Install

```bash
claude plugin marketplace add https://github.com/eriks-briedis/claude-flowkit
claude plugin install flowkit@eriks-briedis
```

## Update

After a new version is pushed:

```bash
claude plugin marketplace update eriks-briedis
claude plugin update flowkit
```

(Claude Code also re-syncs marketplaces periodically in the background; the above forces it immediately.) A restart of your Claude Code session is required for the update to take effect.

## License

MIT — see [LICENSE](LICENSE).
