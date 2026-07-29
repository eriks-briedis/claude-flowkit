---
description: Run the pre-PR /review on your own work, triage which findings are actually worth acting on, then spec the batch through preflight-spec, implement it, and verify. Edits code. Never commits, pushes, or opens a PR.
---

## Role

You are the author of a change that isn't a PR yet. You run the full pre-PR review over your own work, decide which findings genuinely deserve a fix before this goes out, turn that set into one confirmed spec, implement it, and verify the result.

Two things make this different from `/review`:

- `/review` reports and stops. **This command edits code.** That makes it one of the two commands in flowkit that do (the other is `/address-pr-comments`, which is the same job driven by reviewer comments instead of a self-review).
- A review lists everything it found. A fix pass has to be selective. Acting on every Low-risk nit an agent surfaced turns a focused change into an unreviewable one, and the person who pays for that is whoever reviews the PR afterwards.

It is still display-only toward git and GitHub: no commit, no push, no PR. You end with a dirty working tree and a report.

---

## Step 1 — Preconditions

```
git status --short
git rev-parse --abbrev-ref HEAD
```

Capture the list of already-modified files **before** you change anything, and keep it. Step 6's report has to separate what the user had in progress from what this command touched, and after the edits land there's no way to reconstruct that.

Two cases worth stopping on:

- **Nothing to review at all** — no commits ahead of base, clean tree. Say so and stop.
- **The branch has an open PR already** (`gh pr view` succeeds). Say so and ask before continuing. Fixing findings that a reviewer hasn't seen is fine; doing it on a branch someone is mid-review on means their comments land on code that moved. `/address-pr-comments` is usually the better command at that point.

Do not stash, commit, or discard anything, in this step or any other.

---

## Step 2 — Run the review

Invoke the `review` skill (equivalent to running `/review`) and let it complete in full: change set, local lint/tests/build, leftovers scan, all its agents, consolidated findings.

Do not shortcut it. Do not substitute your own quick read of the diff for the multi-agent pass, and do not skip the local checks — the triage in step 3 is only as good as what's in front of it, and a failing test suite changes which findings matter.

Show the review's output to the user as it stands, before triaging. They asked for a review and a fix; they get to see the review.

Carry forward from it:
- Every finding with its severity, file/line, and `[committed] / [uncommitted] / [both]` tag
- The lint/test/build results, including failure output
- The leftovers checklist
- The ticket alignment section, especially missing requirements and flagged scope creep

---

## Step 3 — Triage

Now decide what's worth doing. Classify **every** finding into exactly one bucket. Nothing may be silently dropped — a finding you're not fixing gets said out loud, with a reason.

| Bucket | Meaning |
|---|---|
| **fix** | Going into the spec and getting implemented this pass |
| **ask** | Needs a decision from the user before it can be specced |
| **skip** | Deliberately not fixing now; reason stated |
| **verify** | An Uncertain finding — check whether it's real before it can be bucketed at all |

### What goes in **fix**

- **Every High-risk finding.** No exceptions. If the fix is large or architectural, it still goes in — but flag it in the spec as the thing that will dominate the change, so the user can choose to split it out.
- **Failing lint, tests, or build.** These aren't opinions. Fix the cause.
- **Medium-risk findings whose fix is contained** — a guard, an error path, a corrected condition, a missing await.
- **Missing ticket requirements.** The highest-value bucket in a pre-PR pass: the code doesn't do what it was supposed to do, and nobody has caught it yet. If the requirement is unambiguous, fix. If it isn't, it's an **ask**.
- **Leftovers**: debug output, focused/skipped tests, commented-out blocks, hardcoded credentials, localhost URLs, stray files. Mechanical, zero-risk, and exactly the stuff that gets a PR bounced.
- **Test coverage gaps for behavior this change introduced.**
- **Low-risk findings in code this branch already touches**, but only when the fix is mechanical — a rename, an extracted constant, a clarifying type. Batch them; don't spec them individually.

### What goes in **ask**

- A requirement in the ticket that's genuinely ambiguous, where two readings produce different code
- A High-risk fix that implies a design change (new abstraction, changed contract, migration)
- Scope creep the review flagged. It's the user's work and possibly deliberate — surface it, never revert it on your own initiative
- Anything where the fix conflicts with an existing test, and it isn't obvious which one is wrong

### What goes in **skip**

State the reason for each:

- **Low-risk findings in files this branch didn't otherwise touch.** Fixing them widens the diff for no benefit and buries the actual change.
- **Pre-existing issues the review surfaced that this branch didn't introduce.** Note them as a possible follow-up; don't fold them in.
- **Anything requiring a product or design decision** the ticket doesn't answer.
- **Refactors dressed as fixes.** "This module would be cleaner as X" is not a pre-PR fix.
- **A finding you assess as wrong.** Say why. A disagreement stated plainly is a fine outcome; a finding quietly ignored is not.

### What goes in **verify**

Uncertain findings get checked first — read the code, run the specific check the review suggested — and then move into `fix`, `skip`, or `ask` on the evidence. Never implement a fix for something you haven't confirmed is real.

### Present the triage

Before any spec or edit:

```
Fix (7)
  🔴 src/api/payments.ts:142    unhandled stripe timeout — 500 with no log line
  🟠 src/cart/totals.ts:88      discount applied before tax, ticket says after
  🟡 src/cart/totals.ts:12      `calcT` → `calcTotals` (file already touched)
  ✳  src/cart/totals.spec.ts    missing test: empty cart
  🧹 src/cart/index.ts:4        stray console.log

Ask (2)
  ❓ ticket criterion 3 — "retry on failure" doesn't say how many times or with what backoff
  ❓ src/utils/format.ts         reformatted whole file, unrelated to the ticket — intentional?

Skip (4)
  src/legacy/report.ts:210      pre-existing, untouched by this branch
  src/cart/totals.ts:150        suggested extraction; reads fine as-is, would widen the diff
  ...
```

Ask the user to confirm the split, and specifically to answer the **ask** items. Wait. Their answers change the spec, and re-implementing after the fact costs more than the pause.

---

## Step 4 — Spec the batch through `preflight-spec`

Invoke the `preflight-spec` skill over the **whole confirmed `fix` set at once** — one spec, not one per finding. Findings overlap: two of them often turn out to be the same underlying mistake, and a fix for one can invalidate another. Specced individually and implemented in sequence, they fight each other.

The spec must carry:
- One acceptance criterion per finding in the `fix` set, so nothing gets lost between spec and implementation
- The riskiest item identified explicitly, since it sets the risk level for the whole batch
- The mechanical Low-risk batch as a single criterion, not one per rename
- A verification target that's concrete: which tests must pass, which must be added, what to check by hand for anything a test can't reach

Per `preflight-spec`'s own rules, ask blocking questions only where the answer changes the implementation, and **wait for confirmation before editing**. The step 3 answers usually mean there's nothing left to ask.

If a finding turns out, during specification, to be much larger than the review implied, say so and offer to split it out rather than quietly expanding the batch.

---

## Step 5 — Implement

Implement the confirmed spec, criterion by criterion, in the order it lays out.

Rules that matter more here than in ordinary implementation work:

- **Stay inside the spec.** The temptation in a fix pass is to keep going once you're in the file. Anything not in the spec is a new finding for the next pass, not a free edit.
- **Never fix by weakening the check that caught it.** Don't delete or `skip` a failing test, don't loosen an assertion, don't wrap a failure in a catch that swallows it, don't silence a linter with an inline disable. If a test really is wrong, that's an **ask**, not a fix.
- **Fix the cause, not the symptom.** A null guard bolted onto a value that should never have been null leaves the real bug in place.
- **Keep fixes traceable.** Each edit should map to a criterion, which maps to a finding. That's what makes step 6's verification possible.
- Don't reformat, reorganize imports, or touch unrelated lines in a file you're editing.

---

## Step 6 — Verify

Never report a fix from the memory of having made it. Verify against the code as it now stands.

1. **Per finding** — re-read the file at the changed lines and confirm the fix is present and actually resolves what was raised.
2. **Re-run the checks** — the same lint, test, and build commands the review ran in its Step 3, so the before/after comparison is real. Show the results.
3. **Re-run the leftovers scan** over the current change set. Fixes introduce debug output as often as anything else does.
4. **Regression check** — for anything that changed shared behavior, grep the callers and confirm you haven't broken one nobody was talking about.

If a check that passed before now fails, that's yours: fix it. Cap remediation at **two attempts per failing check**, then stop and report the failure with its output. A third attempt at a check you don't understand is how a fix pass turns into an unreviewable mess.

Do not re-run the full multi-agent review here — it's expensive and it wasn't asked for. Offer it as a next step instead.

---

## Step 7 — Report

### Summary

One line: what was fixed, what's still open, whether the checks pass.

### Fixed

One line per finding: severity, `path/to/file.ext:LINE`, and what the fix actually was. Not what the review suggested — what you did.

### Still open

- **Asked, answered, and deferred by the user** — with their decision recorded
- **Skipped** — with the reason from step 3
- **Attempted and failed** — with the actual output, never summarized as a pass

### Verification

Lint, tests, build: command, before, after. Leftovers scan result. What you couldn't verify and why.

### Files changed

From `git status --short`, split into:
- **Changed by this pass**
- **Already modified before it started** (from step 1) — so the user knows which edits are theirs

### Next steps

Short list. Typically: review the diff, commit, and either open the PR or re-run `/review` for a clean pass. Say plainly that nothing has been committed or pushed.

---

## Constraints

- **Never commit, push, stash, amend, check out another branch, or open a PR.** The working tree is the deliverable.
- **Never post to GitHub.** This command doesn't need `gh` beyond checking whether a PR exists.
- **Never skip the triage confirmation in step 3 or the spec confirmation in step 4**, however small the finding set looks. Deciding what not to fix is the substance of this command; doing it silently is the failure mode.
- **Never fix a finding you haven't confirmed is real.** Uncertain findings get verified first.
- **Never fix by disabling the thing that detected the problem** — no deleted tests, no loosened assertions, no lint suppressions, no swallowed exceptions.
- **Never revert or "clean up" the user's own scope creep.** Flag it, ask, act on their answer.
- **Never let a finding vanish.** Everything the review produced ends up in step 7 as fixed, skipped-with-reason, open, or failed.
- Never edit files outside the change set and the confirmed `fix` set.
- Do not use the `code-review` skill or MCP skills.
- Do not re-run the full review at the end; offer it.
