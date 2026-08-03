# flowkit

A shared collection of Claude Code commands and skills built to help engineering teams get more out of AI-assisted development. It isn't tied to any single workflow — today it covers turning underspecified tasks into a scoped implementation plan before code gets touched, reviewing your own work before you open a PR, both sides of pull request review (triaging and reviewing other people's PRs, then working through the feedback left on your own), and keeping comments and diffs clean before merge. New commands and skills get added as the team finds more places AI assistance pays off.

Packaged as a plugin so a team can install and update these as a single unit, instead of copying files into `~/.claude/commands` by hand.

## What's included today

**Commands** (`commands/`)

| Command | Purpose |
|---|---|
| `/pr-review-loop` | Finds every open PR that needs your attention — never reviewed, or with new commits/comments since your last review — and loops through them one at a time: pulls the PR description plus every inline review thread and comment from `gh`, checks out the branch, sizes up the diff, then asks you for the ticket's title/description and which depth to review at. Runs `/review-quick` by default, or the full multi-agent `/review` when the PR earns it. Pass `full` (`/pr-review-loop full`) to default every PR to the deep pass. |
| `/review-quick` | Fast single-pass review of an open PR against ticket context. Pulls CI status from the PR instead of re-running lint/tests locally, and prints findings pre-formatted as copy/paste-ready GitHub PR comments — it never posts anything itself. Reads the PR's existing inline threads first, so anything a colleague (or you, last round) already commented on lands in an "Already raised on this PR" section instead of the paste list. Remembers past passes per PR so a finding you saw and chose not to comment on isn't re-flagged unless it's gotten worse. |
| `/review-pr` | Thorough multi-agent review of an open PR — up to six parallel agents (bugs, regressions, quality, risk, test coverage, and ticket/discussion alignment), scaled down when a diff doesn't warrant all of them. The alignment agent judges the diff against the PR's inline review threads as well as the ticket: unresolved threads the head doesn't answer, resolved ones whose fix isn't visible in the code, and outdated ones whose point still stands. Takes ticket context inline from `/pr-review-loop` or falls back to `ticket.md`, and reads lint/test/build results from the PR's CI rather than running them locally. Slower and more expensive than `/review-quick` — use it for anything genuinely high-risk or unusually large, not for triaging a queue. |
| `/review-and-fix` | `/review`, then act on it. Runs the full pre-PR review, triages every finding into fix / ask / skip / verify (High-risk and failing checks always get fixed; Low-risk nits in untouched files don't, because widening the diff costs the next reviewer more than it's worth), confirms the split with you, specs the whole batch through `preflight-spec`, implements, and re-runs the checks. Edits code; never commits, pushes, or opens a PR. |
| `/review` | Pre-PR review of **your own** work, before anyone else sees it. Reviews branch commits *plus* staged, unstaged, and untracked changes against `ticket.md` (it asks for the ticket if there's no file). No PR means no CI, so it runs the repo's lint, tests, and build itself, once, then fans out the same multi-agent pass. Also greps for the debris you don't want a reviewer finding: stray `console.log`, focused tests, new `TODO`s, hardcoded keys, localhost URLs. Ends on a Ready / Fix first / Needs a decision verdict. Reports only — it doesn't edit unless you ask. |
| `/address-pr-comments` | The other side of a review: on your own feature branch, pulls every *unresolved* comment thread on the PR, runs `preflight-spec` over the whole batch to research and scope the work, implements it, then verifies thread-by-thread that each point is actually addressed. Prints copy-paste-ready replies, including an explicit "no reply needed" where that's the right call. Built to be re-run as review rounds go by: it remembers what it already addressed, so a follow-up review surfaces only genuinely new comments and reviewer pushback on earlier fixes. Never posts, commits, or pushes. |
| `/comment-cleanup` | Reviews comments in your *uncommitted* diff and deletes/shortens ones that don't earn their keep. Never touches code, never adds new comments. |
| `/review-best-practices` | Structured code-quality review (DRY, separation of concerns, naming, complexity, plus an Angular-specific dimension when the repo looks like Angular) against the current branch vs. its base. |

**Skills** (`skills/`)

| Skill | Purpose |
|---|---|
| `preflight-spec` | Auto-loads for vague/underspecified coding tasks. Turns the ask into a short goal/non-goals/acceptance-criteria/verification spec and gets confirmation before editing production code. Both editing commands (`/review-and-fix`, `/address-pr-comments`) route their whole batch of work through it as a single spec rather than one per item, since fixes tend to overlap. |
| `humanize` | Rewrites user-facing prose so it reads like a person wrote it: no em dashes, no AI stock phrasing, varied sentence rhythm, every fact and number preserved. Invoke it directly on any text, or let the review commands call it, since they now run every PR comment and reply through it before printing. |

**Scripts** (`scripts/`)

- `pr-needs-review.sh` — deterministic backing script for `/pr-review-loop`'s "which PRs need me" step. Run from inside a `gh`-authenticated repo; outputs JSON. Kept as a plain script (not re-derived by the model each run) because the filtering logic here is pure timestamp/state comparison, not judgment.
- `pr-comment-threads.sh` — same idea for `/address-pr-comments`: fetches the unresolved comment threads, review summaries, and PR comments on the current branch's PR, excluding resolved threads and your own comments, and outputs JSON with a stable id per item. Uses GraphQL `pullRequest.reviewThreads` because thread *resolution state* isn't available from `gh pr view --json comments` or the REST comments endpoint — which is precisely why it's a script and not something the model reassembles each run.
- `pr-review-threads.sh` — the reviewer-side counterpart, used by `/pr-review-loop`, `/review-pr`, and `/review-quick`. Takes an optional PR number (defaults to the current branch's PR) and returns the description, every inline review thread, the review summaries, and the PR conversation. The filtering is deliberately the inverse of `pr-comment-threads.sh`: that one answers "what do I still have to act on" and so drops resolved threads and your own comments, while this one answers "what has already been said here" and drops nothing — a thread you opened last round and a thread the author already resolved are both things you need before writing the same comment twice. Every thread comes back flagged with `is_resolved`, `is_outdated`, and `authored_by_me`. Worth knowing why this can't be `gh pr view --json body,comments,reviews`: those `reviews[]` nodes carry only the *summary* body a reviewer typed above their line comments, and the line comments themselves are absent at any depth. On `cli/cli#9000` that fetch returns 3 review bodies and none of the 2 inline comments, without erroring.

## Generated comment style

`/review-pr`, `/review-quick`, `/review-best-practices`, and `/address-pr-comments` all produce text that gets pasted into GitHub, so they share two output rules:

- **Code tokens are backticked.** Identifiers, file paths, flags, types, and literal values go in backticks so GitHub renders them as code. A bare `some_name` in prose loses its underscores to markdown emphasis.
- **Every comment body goes through the `humanize` skill before printing.** Phrasing only; paths, line numbers, severities, and code are untouched.

`/review` is deliberately outside this. Nothing it prints is going on a PR — it's your own work, read by you — so it skips the `humanize` pass and the comment formatting entirely and just says what's wrong and what to do about it.

## Requirements

- `gh` CLI, authenticated against the target repo's GitHub remote (`gh auth status`)
- `git`, `jq`
- Run from inside the target git repository — these commands operate on "the current repo/branch," they don't take a repo argument
- `/address-pr-comments` additionally needs an open PR for the branch you're on, since it resolves the PR from the current branch rather than taking a number
- `/review-pr` and `/review-quick` need an open PR too — they read CI results and discussion from it. `/review` is the one command with no `gh` requirement at all: it works on a local branch, or on nothing but uncommitted changes

## Notes on state

- Two different things stop a review from repeating itself, and they aren't interchangeable. The **inline threads** on the PR are public and live — a finding matching one gets routed to "Already raised on this PR" rather than into the paste list, in both review commands, because a second copy of an existing comment doesn't make the point twice. The **review memory** below is private and per-machine: it only records what *you* decided about a finding. Neither is ever written on the other's behalf, and a resolved thread disappearing from the fetch is the correct way for that state to expire.
- `/review-quick`'s per-PR memory lives at `~/.claude/pr-review-memory/<owner>__<repo>/<pr-number>.json` on each user's own machine — this is personal reviewer state (what you chose to comment on vs. skip), not something the plugin ships or syncs. Nothing to configure. `/review-pr` reads the same file but never writes it and never suppresses on it: a full pass re-surfaces findings a quick pass dismissed, marked as previously seen, because looking again is the whole point of the deeper pass. `/review` has no memory at all — there's no PR to key it to.
- Where lint/tests/build come from is the main split between the PR commands and the pre-PR one. `/review-pr` and `/review-quick` read them off the PR's CI checks and never run them locally. `/review` runs them itself, once, before any agent spawns, because nothing has been pushed and CI has never seen this code.
- `ticket.md` is read by `/review` (it's your own ticket, that's the normal case) and, as a fallback, by `/review-pr`. Neither ever writes it. Inside `/pr-review-loop` it isn't touched at all: the ticket title/description is asked for per PR and passed inline, so a loop run can't overwrite a `ticket.md` holding your own in-progress work.
- `/address-pr-comments` keeps its own per-PR memory at `~/.claude/pr-comment-memory/<owner>__<repo>/<pr-number>.json` — deliberately a separate namespace, because it's author-side state (feedback you received and what you did about it) rather than reviewer-side state. Entries are keyed by GitHub's stable thread node id, so they survive threads being resolved and renumbered between review rounds.
- None of these commands push, commit, or post to GitHub on your behalf. `/pr-review-loop`, `/review-quick`, and `/review-pr` are explicitly display-only by design — you copy the comments they generate into GitHub yourself. `/review` reports and stops too; it offers to apply its own fixes at the end and waits for you to say yes. `/review-and-fix` and `/address-pr-comments` are the two commands that edit code: one acting on its own review, the other on your reviewers' comments. Both stop at the working tree — reviewing, committing, pushing, and replying stay with you.

## Install

```bash
claude plugin marketplace add https://github.com/eriks-briedis/claude-flowkit
claude plugin install flowkit@eriks-briedis
```

## Update

After a new version is pushed:

```bash
claude plugin marketplace update eriks-briedis
claude plugin update flowkit@eriks-briedis
```

(Claude Code also re-syncs marketplaces periodically in the background; the above forces it immediately.) A restart of your Claude Code session is required for the update to take effect.

## License

MIT — see [LICENSE](LICENSE).
