---
description: Review several open PRs at once. Each PR gets its own git worktree, so nothing touches your working tree and a dirty repo is fine. The parent does every gh/git call up front, then fans review agents out across the worktrees, then walks you through the findings one PR at a time. Display-only — it never posts to GitHub.
argument-hint: "[quick|full] [PR numbers, e.g. 839 841 844] (default: the whole needs-review queue, at quick depth)"
---

## Role

You are reviewing several open pull requests concurrently in the current repository. `/pr-review-loop` does the same job serially, one checkout at a time; this command trades that for throughput by giving every PR its own git worktree and reviewing them in parallel.

Two properties follow from the worktrees and both matter:

- **Your working tree is never touched.** No `gh pr checkout`, no branch switching, no stash. A dirty tree is fine — this command has no reason to care what's in it.
- **PRs from forks work the same as PRs from branches**, because the worktree is built from `refs/pull/<n>/head` rather than a remote branch.

The cost is that the human-in-the-loop steps move. `/pr-review-loop` asks you about each PR as it reaches it. Subagents can't ask you anything, so here every question is batched into the parent before the fan-out, and every decision is collected after it.

---

## Which Command Is This

| Situation | Command |
|---|---|
| Several PRs to get through, and you'd rather not wait on each | **this one** |
| One PR at a time, with the size/depth conversation per PR | `/pr-review-loop` |
| A single open PR, fast pass | `/review-quick` |
| A single open PR, deep pass | `/review-pr` |
| Your own branch, no PR yet | `/review` |

Requires a git repo with `gh` authenticated against its GitHub remote.

---

## Invocation

`$ARGUMENTS` may carry a depth and/or explicit PR numbers, in any order:

- *(empty)* → the whole needs-review queue, at **quick** depth
- `full` → every selected PR gets the deep multi-agent pass
- `839 841 844` → just those PRs, skipping the queue scan
- `full 839 841` → both

Depth is a whole-run setting here, not per-PR. Mixing depths inside one fan-out makes the cost impossible to state up front, and stating it up front is the point of step 2.

---

## Step 0 — Claim a run id, then clear out what a previous run left behind

```
${CLAUDE_PLUGIN_ROOT}/scripts/pr-worktree.sh run-id
```

Returns `{ok, run}`. **Pass that `run` to every `pr-worktree.sh` call for the rest of this command** — `add`, `remove`, `prune`, all of them. It's what keeps two runs in one repository from tearing down each other's worktrees, and it works between two Claude Code sessions that share nothing else.

```
${CLAUDE_PLUGIN_ROOT}/scripts/pr-worktree.sh prune --run <id>
```

Drops stale worktree metadata, leftover directories, and refs with no worktree — the debris an interrupted run leaves. Safe when there is nothing to clean, and doubly scoped: only worktrees under flowkit's own root, and among those, never one a live run holds.

Read the result:

- `held[]` — worktrees another live run is using. Normal, not an error. Mention it in one line if non-empty, then carry on.
- `ref_sweep_deferred: true` — another run is mid-flight, so the orphaned-ref sweep was skipped to avoid pulling a ref out from under its `add`. Nothing to do.

If the call fails outright, you are not in a git repository, or `jq` is missing — stop and report that, rather than continuing into step 1.

---

## Step 1 — Build the list

With explicit PR numbers in `$ARGUMENTS`, use those and skip the scan — but still fetch each one's title and branch, since step 2 displays them and step 3b reads a ticket key out of them:

```
gh pr view <number> --json number,title,url,headRefName,state
```

Otherwise:

```
${CLAUDE_PLUGIN_ROOT}/scripts/pr-needs-review.sh
```

JSON array, newest first, of `{number, title, url, headRefName, status}` where `status` is `"new"` or `"updated"`. If it fails, show the error and stop. If it's empty, say so and stop.

---

## Step 2 — Confirm the batch and its cost

Show the list and what the run will spend, then wait:

```
5 PRs need review:

#839  [new commits since your review]  ABC-2806 fix default selection on load
#838  [never reviewed]                 ABC-2844 Remove chevron from secondary button
...

Depth: quick — 1 agent per PR, 5 agents total.
Review all 5, or pick a subset?
```

At `full` depth, say the real number: up to six agents per PR, so five PRs is thirty agent runs. Spell that out rather than burying it, and offer quick as the alternative. Nobody wants to discover the size of that bill afterwards.

Cap the fan-out at **6 agents in flight**. Beyond that, run in waves and say how many waves. If the selection would exceed roughly 18 agent runs, say so and ask them to narrow it or drop to quick before going ahead.

---

## Step 3 — Prepare every PR, in the parent, sequentially

**All network work happens here, before any agent starts** — every `gh` call and every `git fetch`. Not an optimization: concurrent fetches into one repository contend on the same ref locks, and agents that each call `gh` turn a rate limit into a partial failure you have to untangle mid-run. Agents still run local git against their own worktree (`git -C <path> log`, `diff`, `show`); what they never do is talk to the network.

Resolve once for the whole run:

```
gh repo view --json owner,name --jq '"\(.owner.login)__\(.name)"'
```

That's the `<owner>__<repo>` segment of the review-memory path, and it doesn't change per PR.

Then, for each selected PR **one at a time**:

**3a. Worktree.**

```
${CLAUDE_PLUGIN_ROOT}/scripts/pr-worktree.sh add <number> --run <id>
```

Returns `{ok, pr, path, ref, remote, run, base_ref, base_local_ref, head_sha, base_sha, merge_base, reused, state, is_cross_repository}`. Keep `path`, `merge_base`, `base_local_ref`, and `head_sha` — the agent needs all four.

`--run` locks the worktree to this run. Without it the worktree is unowned and any other run may reclaim it mid-review, which is the whole failure this guards against.

**Check `state`.** `gh pr view` succeeds on closed and merged PRs, and `refs/pull/<n>/head` outlives them, so `add` returns `ok: true` for a PR nobody can merge your comments into. Anything other than `OPEN` gets dropped from the run with a line saying so. This matters most on the explicit-numbers path, where no queue scan filtered them out.

If it exits non-zero, read `reason`:

- **Run-level** — `no_jq`, `not_a_repo`, `no_remote`, `no_gh`. Nothing about the next PR will be different. Stop the whole run and report once.
- **PR-level** — `gh_failed` on a PR number that doesn't exist, `fetch_failed` when the head ref is gone, `no_merge_base` on unrelated histories, `worktree_add_failed`, `checkout_failed`. **Drop that PR, tell the user which and why, and carry on with the rest.** One bad PR must not take down a batch.
- **`held_by_another_run`** — a different live run is reviewing this PR, or the user locked its worktree by hand. Drop the PR and say which run holds it. Don't pass `--force`: that takes the worktree out from under a review that's still reading it. If the user decides the other run is dead, `prune --force` is theirs to call.

**3b. Ticket.** Extract a `[A-Z][A-Z0-9]+-\d+` key from the title, then `headRefName`. Don't hardcode a project prefix. With a key:

```
${CLAUDE_PLUGIN_ROOT}/scripts/ticket-lookup.sh <TICKET-KEY>
```

`found: true` carries `title`, `description`, and where the export has them `acceptance_criteria`, `type`, `status`. Keep `acceptance_criteria` as its own field. `found: false` means step 4 asks the user.

**3c. PR discussion.**

```
${CLAUDE_PLUGIN_ROOT}/scripts/pr-review-threads.sh <number>
```

The number is required here, and in 3d below. This command works through a queue while sitting on whatever branch the user was already on, so the no-argument form — which resolves the PR from the current branch — would resolve the wrong PR or none at all.

Returns `description`, `inline_threads[]`, `review_bodies[]`, `pr_comments[]`. Note any `truncated: true` for the report.

**3d. CI.**

```
gh pr view <number> --json statusCheckRollup --jq '.statusCheckRollup[] | "\(.name): \(.conclusion // .status)"'
```

**3e. Review memory.** Read `~/.claude/pr-review-memory/<owner>__<repo>/<number>.json` if it exists. Read only — the write is step 7's, after the user has decided something.

**3f. Size.** Now that the worktree exists:

```
git -C <path> diff --stat <merge_base>..HEAD
```

At full depth this decides which review dimensions a PR actually earns, per `/review-pr`'s agent-selection rules. Step 2 could only quote an upper bound; restate the actual count in one line before spawning if the sizing brought it down.

---

## Step 4 — One batched ask for everything the lookup missed

Every PR whose ticket didn't resolve in 3b gets asked about here, in a **single message**, before the fan-out:

```
Couldn't resolve 2 of 4 tickets from tickets/sprint.csv:

#841  ABC-2851 — Title / Description?
#844  (no ticket key in title or branch) — ticket reference?

The other two resolved:
#839  ABC-2806 — fix default selection on load
#838  ABC-2844 — Remove chevron from secondary button
```

Echo back the ones that did resolve so a stale export or a branch carrying the wrong key gets caught now, while it's still cheap. If they say one is wrong, take what they give instead — never edit the CSV.

Wait for the reply. Reviewing against invented ticket text is worse than reviewing against none: proceed with no ticket context for any PR they skip, and say so in that PR's report.

---

## Step 5 — Fan out

Spawn agents with the Task tool, up to 6 in flight, all of one wave in a single message.

**Quick depth:** one agent per PR. Tell it to invoke the `review-quick` skill and follow it in full, **skipping that document's "Context to Load First" and "CI Status Check" sections** — everything they fetch is already in this prompt, and the fetches themselves are forbidden here. Its severity calibration, its three high-yield checks, its memory reconciliation, its thread reconciliation, and its finding format all come along with it. Invoking the skill is what makes this a reference rather than a partial copy that drifts.

**Full depth:** the review dimensions from `/review-pr` — bug hunter, regression hunter, quality auditor, risk, test coverage, ticket/discussion alignment — spawned as *separate, flat* agents, `<PR> × <dimension>`. Flat, not nested: one agent per PR that spawns its own six would put the concurrency cap out of the parent's reach, and nested fan-out is how a five-PR batch quietly becomes thirty simultaneous agents. Use the 3f sizing to drop the dimensions a small diff doesn't earn.

Every agent prompt carries, verbatim:

- **The worktree path from 3a, and an instruction to do all reading there** — `git -C <path> ...`, and file reads under `<path>`. An agent that reads the repo root reviews the wrong code and won't notice.
- **An instruction that the worktree is read-only**: never edit, stage, create, or delete files under `<path>`. Teardown in step 7 forces the removal, so anything written there is discarded without a prompt.
- **The PR number.** Every `gh`-shaped fact it needs is already in the prompt, but the number belongs in the report and in any file path it derives.
- `merge_base` and `base_local_ref` from 3a, so every agent on a PR diffs the identical change set.
- Ticket title/description, plus `acceptance_criteria`/`type`/`status` as separate fields, and where the text came from (`tickets/sprint.csv` and the key, or the user, or nothing).
- **Never read or write `ticket.md`, and never read `tickets/sprint.csv`.** Both resolve in the parent, in 3b and 4. This bullet is load-bearing, not boilerplate: when provenance is "nothing", `/review-quick` step 2 would otherwise send the agent looking for a `ticket.md` — and the nearest one is the *PR author's*, sitting in the worktree, or the user's own in-progress ticket further up. Where there is no ticket text, review against the diff and the PR discussion alone and say so.
- The PR description, `review_bodies`, `pr_comments`, and **`inline_threads` verbatim** — paths, lines, `is_resolved`, `is_outdated`, `authored_by_me`, and the full reply chains. Not summarized. An agent that doesn't have the actual words will spend its budget rediscovering a bug a colleague reported three days ago.
- The CI results from 3d, and an explicit instruction **not** to run lint, tests, or the build.
- The memory JSON from 3e, with instructions to reconcile against it but **never write to it** — the parent owns that write, because the parent owns the question it answers.
- An instruction to capture exact file paths and line numbers for every finding.

Agents must run **no `gh` commands and no `git fetch`.** Everything network-shaped was resolved in step 3. Say it in the prompt: it isn't inferable, and the documents an agent is following do tell it to run `gh` when a caller hasn't already supplied the answers.

**Return contract.** Each agent returns its findings as prose *and* as a machine-readable list, one entry per finding:

```json
{"id": "short-stable-slug", "file": "src/x.ts", "line": "88-92",
 "severity": "Medium", "summary": "one line",
 "disposition": "new|suppressed|escalated|still-open|already-raised",
 "times_seen": 2, "prior_status": "posted|not_posted|null"}
```

`times_seen` and `prior_status` are copied from the matched memory entry, or `1`/`null` when the finding is new. Without them step 7 writes every entry back as if it were the first sighting, and `/review-quick`'s "⚠ still open after N passes" nudge — which needs `times_seen ≥ 2` on a *posted* finding — can never fire again for any PR reviewed through this command. `still-open` is that case: matched, unchanged, previously posted, rendered anyway.

Step 7 writes the memory file from this. Prose alone can't be written back accurately, and asking the parent to re-derive line numbers by re-reading a diff it never opened is how findings drift.

---

## Step 6 — Present the results, one PR at a time

Fan-out is for latency, not for reading five reports at once. Present sequentially, in queue order, in `/review-quick`'s format: **Ticket Alignment**, **CI Status**, **Findings** grouped by severity with the suppressed-findings rollup, **Already raised on this PR**, **Overall Assessment**.

At full depth, consolidate that PR's agents first — merge duplicates that several dimensions found, reconcile severity disagreements toward the lower reading unless one agent has evidence the others lacked, and say which dimensions ran and which were dropped.

Every finding is rendered once, already formatted as a ready-to-paste GitHub comment, following **`/review-quick`'s "Output Format" section exactly** — its comment template, its tone rules, its backticking rule, and its `humanize` pass. Follow that section rather than a summary of it, so the two commands can't drift into producing differently-worded comments for the same finding. The `humanize` pass covers comment bodies only: **Already raised on this PR** is a set of notes to the user, not text anyone pastes, and is left alone.

After each PR's findings, ask:

```
Which of these are you posting as PR comments? (list them, say "all", or say "none")
```

Wait for it. Then move to the next PR. Nothing in "Already raised on this PR" is a candidate — there's nothing to paste.

Lead the whole section with a one-line roll-up: how many PRs reviewed, how many dropped in 3a and why, total findings by severity.

---

## Step 7 — Record decisions, then tear down

Per PR, write `~/.claude/pr-review-memory/<owner>__<repo>/<number>.json` from that PR's return contract and that PR's answer in step 6, using `/review-quick`'s rules:

- Top level carries `pr` and `repo`, as `/review-quick` writes them
- Rendered and selected → `status: "posted"`
- Rendered and not selected → `status: "not_posted"`
- Suppressed by reconciliation → carry the existing `status`, bump `times_seen` and `last_seen_commit`/`last_seen_at`
- Rendered *and* matched a prior entry (`escalated`, `still-open`) → carry `times_seen` forward and bump it too. Only a genuinely new finding starts at `1`
- In the prior file but not reproduced this pass → drop it
- Moved to "Already raised on this PR" → don't record it at all; the thread is the record

`last_seen_commit` is the `head_sha` from 3a, shortened. Create the directory first if needed.

Then:

```
${CLAUDE_PLUGIN_ROOT}/scripts/pr-worktree.sh remove --all --run <id>
${CLAUDE_PLUGIN_ROOT}/scripts/pr-worktree.sh prune --run <id>
```

`remove --all --run <id>` removes this run's worktrees and nothing else, and drops the run marker. `remove --all` only walks registered worktrees, so a PR whose `add` failed between the fetch and the checkout leaves a ref behind that only `prune` clears — running both makes teardown self-contained instead of leaning on the next run's step 0.

Check the exit status. **Exit 3 means partial**: some worktrees were skipped because another live run holds them, listed in `skipped[]`. That's the expected result when someone else is reviewing in the same repo, so report it as information rather than an error. Any other non-zero exit is a real failure and needs saying — a teardown you don't check is a teardown you can't confirm.

Tear down even when the run ends early or badly. A batch abandoned halfway is exactly the case that leaves debris, and step 0 of the next run shouldn't be the thing that discovers it. If the run dies before reaching this step, its marker goes stale on its own and the next run reclaims what it held.

Report which PRs were reviewed, which were dropped and why, which remain in the queue, and confirm the teardown. Mention that a single PR's worktree comes back in seconds via `pr-worktree.sh add <n>` if they want to dig into one — that's cheaper than keeping five worktrees on disk on the chance they might.

---

## Constraints

- **Never post to GitHub.** No `gh pr review`, `gh pr comment`, no API POSTs, no replying to or resolving an inline thread. Threads are pulled to read. This command prints comments the user pastes themselves.
- Never run `git commit`, `git push`, or `gh pr create`.
- Never run the project's lint, tests, or build. CI status comes from 3d.
- Never invent ticket content. It comes from `tickets/sprint.csv` in 3b or the user in 4, and nowhere else.
- Never read or write `ticket.md`. It may hold the user's own unrelated in-progress ticket, and this command reviews other people's work.
- Agents never call `gh`, never `git fetch`, and never write to the review-memory files. All three are the parent's, in steps 3 and 7.
- Never spawn review agents from inside a review agent. The fan-out is flat so the parent's cap actually caps something.
- Never exceed 6 agents in flight, and never start a wave the user hasn't seen a cost estimate for.
- Never let one PR's failure end the batch — drop it, report it, keep going.
- Never omit `--run <id>` from a `pr-worktree.sh` call. It is what stops a second run in the same repository from tearing down this one's worktrees mid-review, and the protection only holds if every call carries it.
- Never pass `--force` to `pr-worktree.sh`. It breaks a live run's lock, which is the exact thing the run id exists to prevent. `--force` is the user's call to make, not this command's.
- Never skip the per-PR question in step 6. Presenting five reports and asking once at the end loses the mapping between findings and decisions, and that mapping is what the memory file is.
- Never write inside a review worktree — not the agents, not the parent. Teardown removes them with `--force`, so anything left there is discarded silently.
- Never hand-roll the helper scripts. In particular `gh pr view --json body,comments,reviews` is not a substitute for `pr-review-threads.sh` — it silently returns zero inline comments, which are where most of a review lives.
- Never run `git worktree` directly, and never bare `git worktree prune`. That command is repo-global and deregisters any worktree whose directory is currently missing, including ones the user built for their own work on a drive that isn't mounted right now. `pr-worktree.sh` scopes every cleanup to its own root; going around it gives that guarantee up.
- Reading and writing `~/.claude/pr-review-memory/**` is local bookkeeping, unrelated to the no-posting rule.
