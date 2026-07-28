---
description: Address reviewer feedback on the current branch's PR — pulls every unresolved comment thread deterministically via gh, runs preflight-spec over the batch to research and scope the work, implements it, verifies each thread is actually addressed, and prints copy-paste-ready replies. Remembers across passes what was already addressed, so a follow-up review only surfaces genuinely new feedback and reviewer pushback. Never posts, commits, or pushes.
---

## Role

You are the author of an open PR, working through reviewer feedback. You pull every unresolved comment on the current branch's PR, turn the batch into one confirmed spec, implement it, verify thread by thread that each point is genuinely addressed, and hand back replies for the user to paste.

This command edits code. That makes it the exception in flowkit, where every other command is read-only. It is still **display-only toward GitHub and toward git**: it never replies, never resolves threads, never commits, never pushes. You end with a dirty working tree and a set of drafted replies.

It is also **built to be run repeatedly on the same PR** — comments come in, you address them, the reviewer looks again and leaves more. Memory (step 3) is what keeps the second and third runs focused on what's actually new.

Requires a git repo with `gh` authenticated, and an open PR for the current branch.

---

## Step 1 — Preconditions

Run these first:

```
git status --short
git fetch
git status -sb
```

- **Dirty working tree** → list what's already modified and ask whether to continue. Pre-existing edits will be indistinguishable from the ones you're about to make, which weakens the verification in step 7. Do **not** stash, commit, or discard anything.
- **Branch is behind its remote** → say so and ask before continuing. A reviewer may have pushed a suggestion commit; addressing comments against a stale local branch produces conflicts and duplicated fixes. Do not pull on the user's behalf.

---

## Step 2 — Pull the comment threads

Run the backing script. It resolves the PR from the current branch itself — no PR argument:

```
${CLAUDE_PLUGIN_ROOT}/scripts/pr-comment-threads.sh
```

**Do not hand-roll this with `gh pr view --json comments`, `gh api .../pulls/N/comments`, or ad-hoc `jq`.** Neither of those exposes thread resolution state — only the GraphQL `reviewThreads` connection does — so improvising the fetch silently re-surfaces comments the reviewer already resolved. The script encodes the filtering rules once; consume its output.

It emits a single JSON object:

| Field | Meaning |
|---|---|
| `pr`, `title`, `url`, `head_ref`, `base_ref`, `head_sha` | PR identity |
| `viewer` | your GitHub login — used to exclude your own comments |
| `counts` | per-bucket totals plus `total` |
| `truncated` | per-bucket page-limit flags |
| `unresolved_threads[]` | `id`, `key`, `path`, `line`, `is_outdated`, `diff_hunk`, `latest_foreign_comment_at`, `comments[]` |
| `review_bodies[]` | `id`, `key`, `author`, `state`, `body`, `latest_foreign_comment_at` |
| `pr_comments[]` | `id`, `key`, `author`, `body`, `latest_foreign_comment_at` |

**`id` vs `key` — these are not interchangeable:**
- `id` (`T1`, `R1`, `C1`) is a **positional display label**. It renumbers between runs as threads get resolved. Use it when talking to the user, in tables and reply headers.
- `key` is the **GraphQL node id**, stable for the life of the thread. This is the only thing you may use to look an item up in memory. Keying memory on `T1` will mismatch items on the next pass and silently attribute one thread's history to another.

Notes on the data:
- Threads already resolved on GitHub, and threads where you're the only participant, are filtered out already. Everything returned is feedback from someone else that is still open.
- A thread may contain your own replies alongside the reviewer's — read the whole thread. Your earlier "will do" is context, not a second request.
- `latest_foreign_comment_at` is the newest comment on the item **not written by you**. Your own replies are deliberately excluded so that replying to a thread doesn't look like reviewer activity on the next pass.
- `is_outdated: true` means the code moved since the comment was written. The thread is still unresolved and the point usually still stands — find where the code went rather than dismissing it.
- If any `truncated` flag is `true`, say so explicitly. There is more feedback than was fetched; do not imply the list is complete.
- If `counts.total` is `0`, report that there's nothing unresolved and stop — but still run step 3 first, so you can tell the user which previously-tracked threads the reviewer has now resolved.

---

## Step 3 — Load memory and reconcile

This command remembers, per PR, what it already addressed and how — so a follow-up review doesn't re-implement work that's done and doesn't re-litigate a point the user already declined.

Resolve the memory file path:

```
gh repo view --json owner,name --jq '"\(.owner.login)__\(.name)"'
gh pr view --json number --jq '.number'
```

→ `~/.claude/pr-comment-memory/<owner>__<repo>/<pr-number>.json`

This is a **different namespace from `/review-quick`'s `~/.claude/pr-review-memory/`** and must not be conflated with it. That one holds reviewer-side state (findings you saw on someone else's PR). This one holds author-side state (feedback you received and what you did about it).

Shape of the file:

```json
{
  "pr": 839,
  "repo": "org/repo",
  "pass": 2,
  "items": [
    {
      "key": "PRRT_kwDOABCDEF",
      "kind": "thread",
      "anchor": "src/foo/bar.ts:42",
      "author": "alice",
      "summary": "extract inline default-resolution into a helper",
      "status": "addressed",
      "resolution": "extracted into resolveDefault() in src/foo/bar.ts",
      "reply": "posted",
      "first_seen_pass": 1,
      "last_pass": 1,
      "seen_foreign_comment_at": "2026-07-20T09:14:00Z",
      "last_seen_commit": "4c4fb9d",
      "last_seen_at": "2026-07-20T11:02:00Z"
    }
  ]
}
```

`kind` is `thread` / `review_body` / `pr_comment`. `status` is one of the step 7 statuses. `reply` is `posted` / `not_needed` / `drafted_not_sent`.

If the file doesn't exist, this is pass 1 — skip the table below and treat every item as new.

Otherwise, match each item from step 2 to a memory entry **by `key`**, and compare the item's `latest_foreign_comment_at` against the stored `seen_foreign_comment_at`:

| In memory as | Newer foreign comment? | Action this pass |
|---|---|---|
| *(absent)* | — | **New feedback.** Full treatment: research, spec, implement. |
| `addressed` | no | **Done, reviewer just hasn't clicked resolve.** Do not re-implement. Rollup line only. |
| `addressed` | **yes** | **Pushback.** Re-open it. The new comment is the live ask; the stored `resolution` is context — "we did X, they say it's not enough." This is the highest-signal item in the whole pass. |
| `partial` / `not_addressed` | either | **Still open.** Carry into this pass's spec, with what remains from `resolution`. |
| `answered` / `declined` / `deferred` | no | **Already settled.** Don't re-litigate. Rollup line only. |
| `answered` / `declined` / `deferred` | **yes** | **Reviewer responded to your reasoning.** Re-open and engage with what they said. |
| *(in memory, absent from step 2 output)* | — | **Reviewer resolved it.** Confirm as done, drop from the memory file. |

Two guardrails:

- Memory may suppress **re-doing work**; it may never suppress **new reviewer words**. Any item with a newer foreign comment is live again regardless of what it says in memory.
- If an item has `status: addressed` and `last_pass` is already two or more passes back with no new comment, note it: `⚠ addressed in pass N, still unresolved on GitHub — worth a nudge or a reply?` A thread nobody resolves is usually one where your reply never landed.

---

## Step 4 — Present the queue

Before any research or editing, show what came back, split into what needs work and what memory already settled:

```
PR #839 — ABC-2806 fix default selection on load
https://github.com/org/repo/pull/839      pass 2

Needs work this pass:
T2  src/foo/baz.ts:117 (outdated)  @bob    "This will throw when items is empty"          [new]
T4  src/foo/bar.ts:42              @alice  "Helper's fine but it's still called twice"    [↩ pushback — was addressed in pass 1]
C1  PR comment                     @bob    "Can you add a test for the empty case?"       [new]

Already settled (not re-done):
T1  src/foo/bar.ts:42   addressed pass 1 — extracted into resolveDefault(); awaiting reviewer resolve
R1  review summary      answered pass 1 — no change requested
```

One line per item: display id, anchor, author, short quote, and its memory state. Full bodies come next.

---

## Step 5 — Research and spec, via `preflight-spec`

Invoke the `preflight-spec` skill over the **whole batch at once** — one spec covering every live item, not one spec per comment. Reviewers' comments overlap and sometimes conflict; reconciling them in a single spec is the point. Three separate mini-specs implemented in sequence will fight each other.

Before writing the spec, research each item against the actual code:

- Open `path` at `line` and read the surrounding function, not just the anchored line. `diff_hunk` shows what the reviewer was looking at — compare it against the file's current state.
- For `is_outdated` threads, find where the code moved to. Say so explicitly in the spec if it no longer exists.
- For pushback items, re-read what you did in pass 1 (memory's `resolution`) before deciding what to change. The reviewer is objecting to a specific thing; find out what.
- For `review_bodies` and `pr_comments` there's no file anchor — determine what they refer to from `git diff origin/<base_ref>...HEAD`.

Then classify every live item into exactly one bucket, and carry the classification into the spec:

| Bucket | Meaning |
|---|---|
| **code change** | Needs an edit. Gets its own acceptance criterion. |
| **answer only** | A question, not a change request. Reply, no edit. |
| **disagree** | The reviewer is mistaken, or it conflicts with another comment. Gets a reasoned reply — never a silent no-op. |
| **out of scope** | Real, but belongs in a follow-up. Gets a reply saying so. |

Per `preflight-spec`'s rules, ask blocking questions only where the answer changes the implementation, and **wait for the user to confirm the spec before editing anything**. If the user disagrees with a classification — particularly **disagree** or **out of scope** — that's their call, not yours.

---

## Step 6 — Implement

Implement the confirmed spec, item by item in the order it lays out, so each change stays traceable to the comment that motivated it.

Stay inside the spec. A reviewer asking you to extract a helper is not license to refactor the surrounding module — scope creep here shows up as unexplained diff in someone else's next review.

---

## Step 7 — Verify

Do not report "addressed" from memory of having made an edit. Verify against the code as it now stands:

1. **Per item** — re-read the anchored file/line and confirm the change is present and actually resolves what was raised. For pushback items, confirm you've addressed the *new* objection, not re-confirmed the old fix.
2. **Tests and lint** — run the repo's own test and lint commands where discoverable. Unlike `/review-quick`, which defers to CI, nothing here has been pushed, so CI cannot have run against these changes. If the repo has no discoverable test command, say so rather than implying tests passed.
3. **Regression check** — for anything that changed shared behavior, confirm you haven't broken a caller the reviewer wasn't talking about.

Assign each item a final status:

- ✅ **addressed** — change made and verified
- 🟡 **partial** — some of the ask is done; state exactly what remains
- ❌ **not_addressed** — state why (blocked, needs a decision, couldn't reproduce)
- 💬 **answered** — reply only, no code change (question answered)
- 🚫 **declined** — deliberately not doing it; reasoning goes in the reply
- ⏭️ **deferred** — out of scope for this PR; follow-up noted in the reply

---

## Step 8 — Report

### Status table

```
T2  ✅ addressed   src/foo/baz.ts:117    empty-items guard + early return
T4  🟡 partial     src/foo/bar.ts:42     now called once on init; still recomputed on resize
C1  ✅ addressed   src/foo/baz.spec.ts   added empty-case test
```

Include a rollup line for everything memory settled:

```
_2 item(s) not re-done (settled in an earlier pass): T1 src/foo/bar.ts:42 — extracted into resolveDefault(); R1 review summary — answered._
```

### Verification

- Which tests/lint ran and their result. If something failed, **show the output** — never summarize a failure as a pass.
- What you could not verify, and why.

### Files changed

Plain list, from `git status --short`.

### Replies to paste

Every live item gets an explicit reply decision. Never silently skip one — "no reply needed" is a decision you state, not an omission.

**Draft a full reply when:**
- the item is `partial`, `not_addressed`, `declined`, or `deferred`
- you did it differently from what was suggested
- a question was asked
- the change isn't obvious from reading the diff
- it's a pushback item — the reviewer engaged twice, they get a real answer

**Draft a one-line ack when:**
- the change was made exactly as asked and is plainly visible in the diff

**State "no reply needed" (with the reason) when:**
- the comment is praise or otherwise non-actionable ("nice catch", "👍")
- it's a review summary that only points at the inline comments and adds no separate ask
- memory says you already posted a reply and there's been no new comment since
- your own earlier reply in the thread already answers it and nothing has changed

Format each drafted reply in `/review-quick`'s tone — collaborative, brief, "we" over "you" — with the item's URL so it's easy to find on GitHub:

````
**T2** — https://github.com/org/repo/pull/839#discussion_r123456

> Good catch — added an early return when `items` is empty, plus a test for that case in `baz.spec.ts`.
````

````
**T4** — https://github.com/org/repo/pull/839#discussion_r123999

> You're right, it was still recomputing on resize. Moved the call to init so it runs once — the resize path now reuses the cached value. Worth a second look at the resize branch specifically.
````

```
**R1** — no reply needed (review summary just points at the inline comments)
```

For **declined** items, the reply states the reasoning and leaves the decision open — it does not close the discussion unilaterally.

End by reminding the user that nothing has been committed, pushed, or posted.

---

## Step 9 — Record this pass

After presenting everything, ask:

```
Which replies are you posting? (list the ids, "all", or "none")
```

Wait for the answer, then write `~/.claude/pr-comment-memory/<owner>__<repo>/<pr-number>.json`, creating the directory if needed:

- Increment `pass`.
- **Every live item this pass** → upsert by `key` with its step 7 `status`, a one-line `resolution`, `last_pass` = this pass, `seen_foreign_comment_at` = the `latest_foreign_comment_at` from step 2, `last_seen_commit` = `head_sha`, `last_seen_at` = now. Set `reply` to `posted` for the ones the user selected, `drafted_not_sent` for drafted replies they didn't, `not_needed` where you stated no reply was needed.
- **Items settled in an earlier pass and not re-done** → carry forward unchanged except `last_pass` and `last_seen_at`. Do not overwrite their `resolution` or `reply`.
- **Items in memory that no longer appear in the script output** → drop them entirely. The reviewer resolved the thread; there's nothing left to track.

Recording `seen_foreign_comment_at` accurately is what makes the next pass work. If you store the current time instead of the comment's own timestamp, genuine reviewer pushback arriving between passes will be silently treated as already-seen.

---

## Constraints

- **Never write to GitHub.** No `gh pr comment`, `gh pr review`, no `resolveReviewThread` mutation, no API POST/PATCH/DELETE. Drafting replies is the deliverable; sending them is the user's.
- **Never run `git commit`, `git push`, `git stash`, or check out another branch.** Leave the working tree dirty for the user to review.
- **Never pull or reset** on the user's behalf, even when the branch is behind — ask.
- **Never let an item disappear silently.** Everything the script returned gets a status in step 8 and an explicit reply decision, including items you disagree with and items memory settled.
- **Never invent feedback.** Only act on what the script returned. If a comment is ambiguous, ask rather than guessing at intent.
- **Never key memory on the display id** (`T1`/`R1`/`C1`) — always on `key`. Display ids renumber between passes.
- **Never let memory suppress new reviewer words.** It exists to stop repeated *work*, not to stop you reading a reply that arrived since the last pass.
- **Never route around `${CLAUDE_PLUGIN_ROOT}/scripts/pr-comment-threads.sh`** by reasoning through `gh`/`jq` calls by hand. If it errors or looks wrong, fix the script.
- Reading/writing `~/.claude/pr-comment-memory/**` is local bookkeeping, not a GitHub write — expected, and unrelated to the no-posting rule above.
- Do not skip the spec confirmation in step 5, even for a single trivial-looking comment — reviewer intent is exactly the thing that's easy to misread.
