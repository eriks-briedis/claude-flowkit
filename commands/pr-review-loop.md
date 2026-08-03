---
description: Loop through GitHub PRs that need your review (new, or with new commits since your last review) — for each, pull the PR description plus every inline review thread and comment from gh, ask the user only for the ticket title/description, check out the branch, and run /review-quick or the full multi-agent /review-pr
argument-hint: "[quick|full] (default: quick, with a per-PR recommendation)"
---

## Role

You are triaging the user's GitHub PR review queue in the current repository. For every open PR that genuinely needs the user's attention — either they've never reviewed it, or it has new commits since their last review — you assemble that PR's review context (PR description and discussion from `gh`, ticket title/description from the user), check out the branch locally, and run a review against it with that context passed inline.

Two review depths are available per PR:

| Depth | Command | What it is |
|---|---|---|
| **quick** (default) | `/review-quick` | Single pass, no subagents. Fast enough to triage a queue. Remembers per-PR what you already chose not to comment on. |
| **full** | `/review-pr` | Multi-agent pass — bugs, regressions, quality, risk, test coverage, ticket/discussion alignment. Slower and more expensive. For high-risk or unusually large PRs. |

Both take the ticket context inline and both read lint/test/build results from the PR's CI instead of running anything locally. Neither writes `ticket.md`, and neither posts to GitHub.

This command only works from inside a git repo with `gh` authenticated against the relevant GitHub remote.

---

## Invocation

`$ARGUMENTS` sets the *default* depth for the whole run:

- *(empty)* or `quick` → default to quick, and recommend full per-PR when the sizing check in 2e says so
- `full` → default to full for every PR

The default is never binding: step 2f always confirms the depth with the user for the PR at hand, and they can override either way.

---

## Step 1 — Build the "needs review" list

Run the deterministic helper script instead of reasoning through `gh`/`jq` calls by hand — it encodes the exact same rules (review-requested-or-already-reviewed-by-me, minus own PRs, minus drafts, minus PRs with nothing new since your last review) and just hands back the answer:

```
${CLAUDE_PLUGIN_ROOT}/scripts/pr-needs-review.sh
```

It outputs a JSON array, newest PR first, of `{number, title, url, headRefName, status}` where `status` is `"new"` (never reviewed by you) or `"updated"` (commits landed after your last review). If the script fails (e.g. `gh` not authenticated, not in a repo with a GitHub remote), show the error and stop.

Present the resulting list to the user before looping, e.g.:

```
#839  [new commits since your review]  ABC-2806 fix default selection on load
#838  [never reviewed]                 ABC-2844: Remove chevron from secondary button
...
```

Say which default depth the run is using (`quick` unless `$ARGUMENTS` says `full`) when you present the list.

If the array is empty, say so and stop — there is nothing to loop over.

---

## Step 2 — Loop through the list, one PR at a time

For each PR, in order:

### 2a. Announce the PR

State the PR number, title, URL, and why it's in the queue (new / updated).

### 2b. Resolve the Jira ticket

Extract a Jira-style ticket key from the PR title using a pattern like `[A-Z][A-Z0-9]+-\d+` (e.g. `ABC-1234`) — don't hardcode a specific project prefix, infer it from what's actually in the title. If none is found there, check `headRefName` (branch names often carry it, e.g. `bugfix/xy/ABC-1234-short-description`). If the team doesn't use Jira-style keys at all, or still nothing is found, ask the user for the ticket reference directly — do not guess.

### 2c. Fetch PR description and discussion from GitHub

`gh` already has this — don't ask the user for it:

```
${CLAUDE_PLUGIN_ROOT}/scripts/pr-review-threads.sh <number>
```

It returns one JSON object:

- `description` → the PR body
- `inline_threads[]` → every line-level review thread, each with `path`, `line`, `is_resolved`, `is_outdated`, `authored_by_me`, the `diff_hunk` it was anchored to, and the full reply chain. Nothing is filtered out — resolved threads, outdated threads, and threads you opened yourself all come back, flagged.
- `review_bodies[]` → review summary text (empty approvals are already dropped)
- `pr_comments[]` → the PR conversation

**Do not substitute `gh pr view --json body,comments,reviews` for this.** That was the old fetch here and it silently returned nothing from the inline threads — `reviews[]` carries only the summary body a reviewer typed above their line comments, not the line comments themselves. Inline threads are where most of a review actually happens, so reviewing without them means re-raising points a colleague already made and missing the ones the author answered with "good catch, fixed in abc123."

If `truncated` has any `true` in it, say so when you present the findings — the PR has more discussion than one page and something may be missing.

### 2d. Check out the branch

Do this before asking the user anything, so the sizing check in 2e has a real diff to look at and the user is only interrupted once.

Before switching branches, run `git status`. If the working tree has uncommitted changes, **stop the entire loop and tell the user** — do not stash, commit, or discard anything on their behalf. Let them clean up and re-run the command.

Record the branch you started on if this is the first PR in the loop, so it can be restored at the end.

```
gh pr checkout <number>
git pull --ff-only
```

`gh pr checkout` reuses a local branch from a prior loop run if one exists, which can leave it behind the PR's actual head — the explicit `git pull` guarantees the review runs against the latest commits. Use `--ff-only`: if it fails (local branch diverged from remote), stop and surface that to the user rather than merging or rebasing on their behalf.

### 2e. Size up the PR and pick a recommended depth

Start from the `$ARGUMENTS` default, then check whether this particular PR argues for full:

```
git diff --stat $(git merge-base HEAD origin/<base_ref from 2c>)..HEAD
```

Take the base from the PR itself — 2c already returned it as `base_ref` — rather than assuming `main`. Plenty of PRs target a release or feature branch.

Recommend **full** when any of these hold:

- Roughly 400+ changed lines, or 20+ changed files
- The diff touches high-risk surface: auth/permissions, billing/payments, database migrations, cryptography, public API contracts, or anything that handles user-supplied input at a trust boundary
- CI is red on the PR (`gh pr view --json statusCheckRollup`) — a failing pipeline plus a large diff is worth the deeper pass
- The PR is back for re-review (`status: "updated"`) and the new commits are themselves substantial, not a one-line fix
- The PR carries a lot of open inline discussion — say 5+ unresolved threads in `inline_threads` from 2c, or unresolved threads on the high-risk surface above. Checking a head against a pile of open requests is Agent 6's job and quick mode does it in a single pass.

Otherwise recommend **quick**. Small, single-subsystem PRs are exactly what quick mode is for, and spending six agents on a 30-line diff buys nothing.

State the recommendation in one line with the reason, e.g. `→ suggesting full: 640 changed lines across 23 files, touches src/auth/`.

### 2f. Ask the user for the ticket title/description and confirm the depth

The only thing not visible to `gh` is the Jira-side ask — what the ticket actually wants. Ask for just that plus the depth confirmation, in one message, nothing more. Restate the PR number and URL (from 2a) right above the ask so the user can pull the ticket up without scrolling back:

```
#<number> — <url>
<one-line size/risk summary from 2e>

Title:
Description:

Review depth: [quick] / full   ← suggesting <quick|full> because <reason>
```

Wait for the reply — do not fabricate or infer the ticket content, and do not pick the depth for them when they've answered with only the ticket text. If they give the ticket and say nothing about depth, take the recommendation and say which one you're running.

### 2g. Hand the assembled context to the review — skip `ticket.md` entirely

Do **not** read or write `ticket.md` for this loop. It may hold unrelated context (the user's own in-progress ticket) — overwriting it every loop iteration would clobber that. Both review commands accept the context inline for exactly this reason.

Pass the assembled context straight into the review invocation in 2h, inline in the same turn — no file round-trip:

- ticket Title/Description from 2f
- `description`, `review_bodies`, and `pr_comments` from 2c
- **`inline_threads` from 2c, verbatim** — each one with its `path`, `line`, resolved/outdated flags, and comment bodies. Don't summarise them down to a sentence: the review needs the actual words on the actual lines to tell "this was already raised" from "this is new." Both review commands know to skip their own fetch when this arrives inline, so dropping it here means it never gets read at all.

### 2h. Run the review at the chosen depth

**quick** → invoke the `review-quick` skill (equivalent to `/review-quick`) against the checked-out branch with the 2g context inline.

**full** → invoke the `review-pr` skill (equivalent to `/review-pr`) the same way. It fans out to parallel agents, including one that checks the diff against the ticket's acceptance criteria and any unanswered points in the PR discussion, so pass the whole of 2c — inline threads included — along with the ticket text.

Either way:

- The review reads lint/test/build results from the PR's CI. Neither command runs the project's lint, test, or build locally, and you must not run them here on their behalf.
- Both commands split their output: findings worth a new comment, and an **Already raised on this PR** section for findings an existing inline thread covers. On a PR back for re-review, expect the second section to carry real weight — that's the point of pulling the threads.
- Display the findings directly in the conversation. Do **not** post to GitHub (no `gh pr review`, `gh pr comment`, or similar) — this loop is display-only by design, and both review commands are display-only by their own constraints.

Depth-specific handoff:

- `/review-quick` remembers past passes on the same PR (`~/.claude/pr-review-memory/`) — findings you saw before and chose not to comment on won't be re-flagged unless they've gotten worse, and it asks which findings you're posting this pass before handing control back. Let that question resolve before moving to 2i.
- `/review-pr` reads that same memory but never suppresses on it; it annotates repeats instead, and doesn't write to it. So a full pass after a quick pass will re-surface things you already dismissed, marked as such. That's deliberate — the point of the deeper pass is to look again.

If the user asked for quick and the review itself comes back saying the diff is too large or too risky for a single pass, offer to re-run this PR at full depth before moving on. Don't re-run it silently.

### 2i. Pause before continuing

After showing the findings, stop and ask the user whether to proceed to the next PR in the queue, re-run this one at the other depth, skip ahead, or stop the loop entirely. Do not auto-advance.

---

## Step 3 — Wrap up

When the loop ends (list exhausted or user stops early):

- Check out the branch the user started on (recorded in 2d).
- Summarize which PRs were reviewed and at which depth, which were skipped, and which remain in the queue for next time.

---

## Constraints

- Never run `gh pr review`, `gh pr comment`, `git push`, `git commit`, or `gh pr create` as part of this loop. Replying to or resolving an existing inline thread counts as posting — the threads are pulled to read, never to answer.
- Never stash, commit, or discard uncommitted work when switching branches — if the working tree is dirty, stop and tell the user.
- Never invent ticket content the user hasn't provided.
- Never read or write `ticket.md` — ticket context is asked for in 2f and passed inline, every iteration.
- Never run the project's lint, test, or build commands. Lint/test/build status comes from the PR's CI, via the review command.
- Never skip the pause in 2i, even if the user seems eager to move fast — confirm each time.
- Never escalate a PR to full depth without asking, and never quietly downgrade a PR the user asked to review at full depth.
- Never replace either helper script (`pr-needs-review.sh`, `pr-review-threads.sh`) with hand-reasoned `gh`/`jq` calls — if one errors or seems wrong, fix the script, don't route around it token-by-token. For the threads script in particular, the obvious-looking `gh pr view --json body,comments,reviews` substitute drops every inline comment on the PR without erroring.
