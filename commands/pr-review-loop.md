---
description: Loop through GitHub PRs that need your review (new, or with new commits since your last review) — for each, pull PR description/discussion from gh, ask the user only for the ticket title/description, check out the branch, and run /review-quick
---

## Role

You are triaging the user's GitHub PR review queue in the current repository. For every open PR that genuinely needs the user's attention — either they've never reviewed it, or it has new commits since their last review — you assemble that PR's review context (PR description and discussion from `gh`, ticket title/description from the user), check out the branch locally, and run the `/review-quick` skill against it with that context passed inline.

This command only works from inside a git repo with `gh` authenticated against the relevant GitHub remote.

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
gh pr view <number> --json body,comments,reviews
```

- `body` → PR description
- `comments[].body` and `reviews[].body` → prior discussion on this PR (skip empty review bodies from plain approvals/rejections with no comment)

### 2d. Ask the user for the ticket's title and description only

The only thing not visible to `gh` is the Jira-side ask — what the ticket actually wants. Ask for just that, nothing more — but restate the PR number and URL (from 2a) right above the ask, so the user has it at hand to pull up the ticket without scrolling back:

```
#<number> — <url>

Title:
Description:
```

Wait for the reply — do not fabricate or infer it.

### 2e. Hand the assembled context to the review — skip `ticket.md` entirely

Do **not** read or write `ticket.md` for this loop. It may hold unrelated context (the user's own in-progress ticket, used by a standalone `/review` or another command in their setup) — overwriting it every loop iteration would clobber that.

Instead, pass the assembled context (ticket Title/Description from 2d, PR description/discussion from 2c) straight into the `/review-quick` invocation in step 2g, as inline context in the same turn — no file round-trip.

### 2f. Check out the branch

Before switching branches, run `git status`. If the working tree has uncommitted changes, **stop the entire loop and tell the user** — do not stash, commit, or discard anything on their behalf. Let them clean up and re-run the command.

Record the branch you started on if this is the first PR in the loop, so it can be restored at the end.

```
gh pr checkout <number>
git pull --ff-only
```

`gh pr checkout` reuses a local branch from a prior loop run if one exists, which can leave it behind the PR's actual head — the explicit `git pull` guarantees the review runs against the latest commits. Use `--ff-only`: if it fails (local branch diverged from remote), stop and surface that to the user rather than merging or rebasing on their behalf.

### 2g. Run the review

Invoke the `review-quick` skill (equivalent to running `/review-quick`) against the now-checked-out branch, passing the context assembled in 2e inline instead of pointing it at `ticket.md`. It pulls CI status from the PR itself rather than re-running lint/tests locally, and prints findings pre-formatted as paste-ready GitHub PR comments.

Display the findings directly in the conversation. Do **not** post the review to GitHub (no `gh pr review`, `gh pr comment`, or similar) — this command is display-only by design, and `/review-quick` is display-only by its own constraints too.

`/review-quick` remembers past passes on the same PR (`~/.claude/pr-review-memory/`) — findings you saw before and chose not to comment on won't be re-flagged unless they've gotten worse, and it will ask you which findings you're posting this pass before handing control back here. Let that question resolve before moving to 2h.

### 2h. Pause before continuing

After showing the findings, stop and ask the user whether to proceed to the next PR in the queue, skip it, or stop the loop entirely. Do not auto-advance.

---

## Step 3 — Wrap up

When the loop ends (list exhausted or user stops early):

- Check out the branch the user started on (recorded in 2f).
- Summarize which PRs were reviewed, which were skipped, and which remain in the queue for next time.

---

## Constraints

- Never run `gh pr review`, `gh pr comment`, `git push`, `git commit`, or `gh pr create` as part of this loop.
- Never stash, commit, or discard uncommitted work when switching branches — if the working tree is dirty, stop and tell the user.
- Never invent ticket content the user hasn't provided.
- Never skip the pause in 2h, even if the user seems eager to move fast — confirm each time.
- Never edit `${CLAUDE_PLUGIN_ROOT}/scripts/pr-needs-review.sh`'s output by hand-reasoning through `gh`/`jq` instead — if the script errors or seems wrong, fix the script, don't route around it token-by-token.
