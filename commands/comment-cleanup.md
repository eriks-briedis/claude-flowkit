---
description: Review comments in uncommitted git changes and remove or shorten ones that don't earn their keep
---

## Role

You are a senior engineer auditing comments in the current uncommitted diff. Your job is to remove noise and tighten signal — not to add commentary or rewrite code.

---

## Scope

Only comments in **uncommitted changes** (staged + unstaged + untracked) in the current worktree. Do not touch comments that aren't part of the diff.

In-scope comment forms:
- Single-line: `//`, `#`, `--`
- Block: `/* ... */`, `""" ... """`, `<!-- ... -->`
- Doc comments: JSDoc/TSDoc (`/** */`), Python docstrings, etc.

Out of scope:
- License headers
- Generated-file banners (`// AUTO-GENERATED`, etc.)
- `eslint-disable` / `prettier-ignore` / `@ts-expect-error` and other tool directives
- Commented-out code → flag separately; do not silently delete (might be intentional WIP)

---

## Decision rubric

For each comment in the diff, classify into exactly one bucket:

### DELETE if any of these are true
- Restates the code (e.g. `// increment counter` above `counter++`)
- The identifier names already say what it says (e.g. `// get user by id` above `getUserById`)
- Says WHAT, not WHY, and the WHAT is obvious from reading the line
- Refers to the current task, ticket, PR, or author (`// added for ABC-2299`, `// per teammate's request`) — that belongs in the commit/PR, not the code
- Stale: references removed code, old behavior, or a TODO already done
- Decorative section banners with no information (`// ============ HELPERS ============`) unless the file convention clearly uses them

### SHORTEN if
- The WHY is real but buried in prose
- It's a multi-sentence explanation where one phrase carries the load
- Target: one line, ideally under ~100 chars. Two lines max if a constraint genuinely needs them.

### KEEP AS-IS if
- Explains a non-obvious WHY: a hidden constraint, subtle invariant, workaround for a specific bug, surprising behavior, link to an issue/spec
- Warns about a footgun a future reader would hit
- Already short and load-bearing

When in doubt between DELETE and SHORTEN: prefer DELETE. Between SHORTEN and KEEP: prefer KEEP if the shortening would lose the "why."

---

## Procedure

1. **Snapshot the diff.** Run in parallel:
   - `git status --short`
   - `git diff` (unstaged)
   - `git diff --cached` (staged)
   - For untracked files in the status output, read each one (they have no diff baseline — the whole file is "new").

2. **Extract added/modified comments only.** Ignore comments that appear in the diff solely as context lines (unchanged). You're auditing what the user is *introducing or touching*, not the whole file.

3. **Classify each.** For every in-scope comment, assign DELETE / SHORTEN / KEEP using the rubric above. Note the file:line and a one-phrase reason.

4. **Present the plan before editing.** Output a compact table:

   ```
   path/to/file.ts:42  DELETE   restates code ("// loop over users")
   path/to/file.ts:88  SHORTEN  three sentences, one carries the why
   other/file.py:10    KEEP     explains DST workaround
   ```

   Group by file. If there's nothing to change, say so and stop.

5. **Apply changes** with the Edit tool. For SHORTEN, write the replacement comment in the same style as the original (`//` vs `/* */` vs docstring).

6. **Final report.** One short paragraph:
   - Counts: deleted N, shortened M, kept K
   - Any commented-out code blocks you flagged but did not touch
   - Anything you were unsure about — leave it for the user to judge

---

## Hard rules

- **Do not commit, stage, or push.** Leave the working tree dirty.
- **Do not edit code**, only comments. If a comment can only be fixed by renaming a variable, flag it — don't rename.
- **Do not add new comments** that weren't already there. This skill subtracts; it doesn't generate.
- **Do not touch comments outside the diff**, even if they're bad. Scope is uncommitted changes only.
- **Do not delete tool directives** (`eslint-disable`, `@ts-expect-error`, `prettier-ignore`, `noqa`, etc.) even if they look comment-like.
- **Do not delete TODOs unless the work is provably done** in the same diff. When unsure, KEEP.
- If a "comment" is actually a docstring that documents a public API, default to KEEP unless it's obviously wrong or restating the signature.

---

## Examples

DELETE:
```ts
// increment the counter
counter++;
```

DELETE (says what, not why):
```ts
// fetch the user
const user = await getUser(id);
```

SHORTEN — before:
```ts
// We need to use setTimeout here with a delay of 0 because Angular's change
// detection runs synchronously and if we update this value in the same tick
// it causes ExpressionChangedAfterItHasBeenCheckedError to be thrown.
setTimeout(() => this.value = next, 0);
```

SHORTEN — after:
```ts
// defer to next tick — same-tick update triggers ExpressionChangedAfterItHasBeenCheckedError
setTimeout(() => this.value = next, 0);
```

KEEP:
```ts
// Stripe webhook retries on any non-2xx, so we must ack before processing.
res.status(200).end();
```
