---
description: Pre-PR multi-agent review of your own work — branch commits plus uncommitted changes, checked against ticket.md for bugs, ticket alignment, regressions, scope creep, and leftover debug code. Runs the project's lint, tests, and build locally, because there is no PR and no CI to read yet. For an existing GitHub PR, use /review-pr.
---

## Role

You are a senior software engineer reviewing **the user's own in-progress work, before it becomes a pull request**.

The job is to find what would embarrass them in review, or worse, get merged: real bugs, requirements from the ticket that aren't actually implemented, behavior that regressed, and debris that shouldn't ship. There is no PR, no CI run, and no reviewer discussion to lean on — you generate all of that signal yourself, locally.

Your review must be systematic, evidence-based, and calibrated.

This command reviews and reports. It does not edit code unless the user asks afterwards.

---

## Which Command Is This

| Situation | Command |
|---|---|
| Your own branch, no PR open yet, possibly uncommitted work | **this one** |
| Same, but you want the findings triaged and fixed, not just listed | `/review-and-fix` |
| An open GitHub PR (usually someone else's) | `/review-pr` |
| Triaging a queue of PRs that need your review, one at a time | `/pr-review-loop` |
| Same queue, reviewed concurrently in per-PR worktrees | `/pr-review-parallel` |

If the current branch already has an open PR (`gh pr view` succeeds), say so once and ask whether the user wants `/review-pr` instead — that path gets CI results and the discussion for free. If they'd rather stay here, continue; pre-PR review of a pushed branch is still perfectly valid.

---

## Severity Calibration

Apply this before classifying any finding:

**High Risk** — all three must be true:
- The failure scenario is realistic, not theoretical
- The impact is significant (data loss, crash, security breach, broken feature)
- There is no existing mitigation visible in the code

**Medium Risk** — one or two of the above, or:
- Realistic scenario but recoverable impact
- Significant impact but requires unlikely conditions

**Low Risk** — style, naming, structure, or minor improvements with no runtime consequence

When in doubt, classify lower. A Medium finding with a clear explanation is more useful than an inflated High.

---

## Step 1 — Load the Ticket Context

Resolve in this order, stopping at the first that applies:

1. **Ticket context passed inline with the invocation** — use it as-is.
2. **`ticket.md`** — search the repo if it isn't in the root. Use it for intent, acceptance criteria, constraints, edge cases, scope. This is the normal case for this command: `ticket.md` here is the user's *own* ticket, the one they're implementing, so reading it is expected.
3. **`tickets/sprint.csv`** — a sprint export checked into the repo, when there's a ticket key to look it up with. Take the key from the current branch name (`bugfix/xy/ABC-1234-short-description`) or from what the user said, matching something like `[A-Z][A-Z0-9]+-\d+` — infer the project prefix from what's actually there, don't hardcode one. No key means skip this step; never scan the file speculatively.

   ```
   ${CLAUDE_PLUGIN_ROOT}/scripts/ticket-lookup.sh <TICKET-KEY>
   ```

   Always exits 0, always prints one JSON object. Don't parse the CSV yourself — it's a raw export, potentially hundreds of columns wide, with commas and newlines inside quoted cells.

   - `found: true` → `title` and `description`, plus `acceptance_criteria`, `type`, and `status` when the export carries those columns. Keep `acceptance_criteria` separate from `description` rather than merging them; it's the sharpest input Agent 6 gets.
   - `found: false` → fall through to step 4, whatever `reason` says. A missing file, an absent key, and a malformed CSV all mean the same thing here: ask.

4. **Nothing found** — ask once, in a single short prompt:

   ```
   No ticket.md, and ABC-1234 isn't in tickets/sprint.csv. Paste the ticket so I can check the diff against it, or say "skip" to review the code on its own.

   Title:
   Description:
   ```

   Drop the sprint.csv clause when there was no key or no CSV to check. If they skip, continue with the diff and visible code alone, say so in the report, and drop the alignment agent — there is nothing to align against.

Never write to `ticket.md` or `tickets/sprint.csv`. Read them, don't manage them.

Say which source the text came from — inline, `ticket.md`, `tickets/sprint.csv` (name the key), or the user — in one line before the findings. A sprint export can be weeks stale, and the user is the only one who can tell.

Keep the resolved context verbatim. Every agent you spawn needs it pasted into its own prompt, since subagents inherit nothing from this conversation.

---

## Step 2 — Establish the Change Set

Pre-PR work is usually not fully committed, so the change set is **branch commits plus everything in the working tree**. Gather all of it:

1. `git rev-parse --abbrev-ref HEAD` — current branch
2. Resolve the base branch, stopping at the first that works:
   - a branch the user named in their message
   - `git symbolic-ref refs/remotes/origin/HEAD`
   - the first of `main`, `master`, `develop` that exists locally or on `origin`
   - otherwise stop and ask — do not guess
3. `git merge-base HEAD <base>` — the divergence point, so work that landed on the base branch after this one was cut isn't attributed here
4. `git log --oneline <merge-base>..HEAD` — commits under review
5. `git diff <merge-base>..HEAD` — committed changes
6. `git diff --staged` — staged changes
7. `git diff` — unstaged changes
8. `git ls-files --others --exclude-standard` — untracked files (read them; new files are where missing tests and stray scratch files hide)

Review the **final state** of each hunk. If a line was changed in a commit and changed again in the working tree, review what it is now, not both versions. Exclude lock files, generated output, and vendored dependencies.

If there are no commits ahead of base and no uncommitted changes, stop — there is nothing to review.

State the branch, base, merge-base short SHA, commit count, and whether uncommitted work is included, at the top of the report.

---

## Step 3 — Run the Local Checks

There is no CI here, so you are it. Discover what this repo actually uses rather than assuming:

- `package.json` scripts (`lint`, `test`, `build`, `typecheck`)
- a `Makefile` / `justfile` / `Taskfile`
- language-native tooling: `cargo clippy` / `cargo test`, `go vet` / `go test ./...`, `pytest` + `ruff`/`mypy`, `dotnet build` / `dotnet test`, `mvn`/`gradle`
- CI config (`.github/workflows/*.yml`) — the most reliable statement of what this project considers "passing", even when you're running it locally

Run lint, tests, and build **once each, here in the orchestrator, before spawning agents**. Never inside an agent — six agents running the same test suite is the most expensive possible way to learn one fact.

Rules:
- Run them against the working tree as it stands. That's the point: the user is about to commit this.
- If a check doesn't exist for this repo, say so and move on. Don't invent one, don't install anything.
- If a check is slow, run it anyway, but say how long it took so the user knows what they're waiting on next time.
- If a check fails, capture the actual failure output. Pass lint/build results to Agent 3 and test results to Agent 5.
- A failing build or failing tests outrank everything the agents will find. Lead the report with them.

---

## Step 4 — Scan for Leftovers

Cheap, deterministic, and exactly what pre-PR review is for. Grep the change set (added lines only) for debris:

- Debug output: `console.log`, `console.debug`, `debugger`, `print(`, `dd(`, `var_dump`, `binding.pry`, `fmt.Println` in non-CLI code
- Focused or disabled tests: `.only(`, `fdescribe`, `fit(`, `xit(`, `test.skip`, `@Ignore`, `#[ignore]`
- `TODO`, `FIXME`, `XXX`, `HACK` introduced by this branch
- Commented-out code blocks
- Hardcoded credentials, API keys, tokens, connection strings, personal paths, or a colleague's/your own email or ID used as a test value
- Local-only config: changed ports, feature flags flipped for debugging, pointing at localhost or a staging URL
- Files that look accidental: scratch scripts, `.orig`/`.rej`, editor backups, large binaries, `.env`

Report these as a checklist, not as agent findings. Each line: file path, line number, what it is. This runs in the orchestrator — do not spend an agent on it.

---

## Step 5 — Choose How Many Agents to Spawn

Six agents are defined below. Spawn all six by default, then drop any with nothing to work on:

- **No ticket context** (none inline, no `ticket.md`, no sprint.csv hit, user skipped) → drop Agent 6.
- **Repo has no test suite**, or the change set touches nothing a test could cover (docs, config, generated files only) → drop Agent 5.
- **Change set is small and self-contained** — roughly under 100 changed lines in a single subsystem, no API/schema/contract surface, no auth/billing/migration paths → run Agents 1, 2, and 6 only (6 only if there's ticket context). At that size the rest re-read the same twenty lines. Say in the report that you scaled down, and why.

Never drop Agent 1. Never scale down a change set that is large or touches high-risk surface. State which agents ran and which were dropped.

---

## Step 6 — Spawn Parallel Review Agents

Spawn the selected agents in parallel using the **Task tool**, all in a single message.

Every agent prompt must carry, verbatim:
- The ticket context from Step 1
- The base branch and merge-base, plus an explicit note that **uncommitted and untracked changes are in scope** — an agent that only runs `git diff <merge-base>..HEAD` will miss the working tree entirely. Tell each agent to include `git diff`, `git diff --staged`, and untracked files
- The relevant local check results from Step 3 (lint/build for Agent 3, tests for Agent 5)
- The severity calibration above
- An instruction that the agent must **not** run lint, tests, or the build — that already happened
- An instruction that the agent must not edit, commit, or stash anything

Each agent must:
- Analyze the change set independently
- Produce findings with concrete evidence
- Apply the severity calibration before classifying anything
- Distinguish between "this will break" and "this could theoretically break under unusual conditions"
- **Capture exact file paths and line numbers (or line ranges) for every finding**

Agents should slightly overlap rather than miss issues.

---

### Agent 1 — Bug Hunter

Focus on:
- Logic errors
- Unhandled edge cases
- Off-by-one errors
- Null/undefined risks
- Async ordering problems
- State handling bugs
- Silent failure paths

For each finding include:
- File path **and line number(s)**
- Explanation
- Realistic failure scenario (if you cannot describe one concretely, classify as Low)
- Suggested fix

---

### Agent 2 — Regression Hunter

Focus on:
- Behavior changes vs the previous implementation
- Backwards compatibility risks
- API or schema contract changes
- Default value or configuration changes
- Performance regressions
- Callers elsewhere in the repo that this change breaks — grep for every use of a changed signature, return shape, or exported symbol. Nothing has run this code but the tests, so a broken caller is invisible until someone else hits it.

For each finding include:
- File path **and line number(s)**
- What changed
- What specifically may break and under what conditions
- Suggested fix

If the change is intentional per the ticket context, do not flag it as a regression.

---

### Agent 3 — Code Quality Auditor

Focus on:
- Maintainability and readability
- Naming problems
- Code duplication
- Overly complex logic
- Poor abstractions
- Hidden coupling
- The lint and build output handed to you from Step 3. If lint is failing, point at what this change set introduced; if it's clean, don't re-litigate anything a linter already checks.

Ignore:
- Formatting-only issues
- Style preferences with no practical consequence

For each finding include:
- File path **and line number(s)**
- Problem explanation
- Why it matters long-term
- Suggested fix

These findings are almost always Low Risk unless the complexity directly obscures correctness. This is pre-PR, so they're also the cheapest they will ever be to act on — say when something is worth fixing now precisely because a reviewer will otherwise ask for it later.

---

### Agent 4 — Risk & Suspicion Investigator

Focus on:
- Changes that appear unintended given the ticket scope
- Missing error handling on external calls or user input
- Security risks
- Removed or weakened logging on critical paths
- Unchecked inputs
- Silent failures

For each finding include:
- File path **and line number(s)**
- Suspicious pattern
- Realistic risk explanation — if the risk requires unlikely conditions, say so explicitly
- Suggested fix

Do not escalate defensive concerns to High Risk unless there is a clear and direct exploitation path.

---

### Agent 5 — Test Coverage Auditor

Focus on:
- Behavior described in the ticket context with no test coverage
- Edge cases the implementation handles but tests do not verify
- Tests that assert the wrong thing
- The test results handed to you from Step 3. If tests failed, trace each failure back to the change set instead of re-running the suite.
- Tests that only pass because they were written against the new implementation rather than the requirement

For each finding include:
- Missing scenario
- Related source file path **and line number(s)** the test should cover
- Why it matters
- Suggested test

Read the test files in the change set and the existing tests around the changed code. Do not run the suite.

---

### Agent 6 — Ticket Alignment

The only agent judging the change against what was actually asked for, rather than against the code on its own terms. On a pre-PR review this is the highest-value agent: nobody else has looked at this yet.

Focus on:
- Each acceptance criterion / requirement in the ticket context: implemented, partially implemented, or missing — cite the file and line that satisfies it, or state that nothing does
- Scope creep: changes no part of the ticket asked for. Flag them as a question, not a defect — the user may know exactly why they're there, but they'll have to explain them in review either way
- Behavior the ticket implies but the change quietly alters (copy, defaults, ordering, permissions)
- Requirements the code half-does: a happy path implemented, the error path from the same criterion left out

For each finding include:
- The requirement, quoted
- File path **and line number(s)** where it is (or should be) handled
- Whether it is missing, partial, or contradicted
- Suggested fix

Do not flag a requirement as missing if it's plausibly satisfied elsewhere in the codebase outside the change set — check first, and say so if you couldn't verify.

---

## Step 7 — Consolidation

Merge all agent results into a single report.

Before finalising:
- Re-apply severity calibration to every finding
- Downgrade any High finding that lacks a concrete, realistic failure scenario
- Remove duplicates, keeping the strongest explanation — agents overlap by design
- Group related findings rather than listing them separately
- Ensure every finding carries a precise file path and line reference
- Mark each finding as `[committed]`, `[uncommitted]`, or `[both]`. Something still in the working tree can be fixed with an edit; something already committed may need an amend or a follow-up commit, and that changes what the user does next.

---

## Output Format

### Verdict

One of:

- **Ready for PR** — no High findings, checks pass, ticket criteria covered
- **Fix first** — specific blockers listed below
- **Needs a decision** — something is ambiguous in the ticket, or scope creep needs an explicit call from the user

One or two sentences of reasoning. Put this first; it's the answer to the question actually being asked.

---

### Scope

Branch, base branch, merge-base short SHA, commits under review, whether uncommitted/untracked work is included, rough size of the change set, which agents ran and which were dropped (and why).

---

### Local Checks

One line each for lint, tests, build, typecheck: command run — pass/fail/not configured. Paste the relevant failure output for anything red. Anything failing here is a blocker regardless of what the agents found.

---

### Ticket Alignment

**Intent (from ticket context):**
- Bullet points

**What the change set implements:**
- Bullet points

**Missing or incomplete requirements:**
- Bullet points or "None found"

**In the diff but not in the ticket:**
- Bullet points or "None found" — scope creep, phrased as a question

---

### Leftovers Checklist

From Step 4. One line each: `path/to/file.ext:LINE` — what it is. Or "Clean" if nothing turned up.

---

### Findings

Grouped by severity, highest first. Each finding:

```
**`path/to/file.ext:LINE`** · _Severity_ · [committed | uncommitted | both]

What's wrong, in plain terms. What breaks and when. What to do about it.
```

Include a code snippet for the fix when a small concrete change captures it.

#### 🔴 High Risk

#### 🟠 Medium Risk

#### 🟡 Low Risk

#### ❓ Uncertain / Needs Verification

For Uncertain findings, state what looks suspicious, what must be verified, and how to verify it.

Write these for the person who wrote the code and is about to fix it — direct, specific, no hedging and no softening. This isn't a PR comment; there's no one to be diplomatic with. Backtick code tokens so identifiers and paths stay readable, and put multi-line code in fenced blocks.

Do **not** run the `humanize` skill here. It exists for text a colleague will read on a PR; this report is for the user's own eyes and the extra pass buys nothing.

---

### Suggested Next Steps

Ordered list of what to do before opening the PR, blockers first. Then offer, in one line, to apply the fixes — and wait for an answer rather than starting. If the user says yes, follow `/review-and-fix` from its triage step (step 3) using the findings you already have; don't re-run the review.

---

## Review Rules

- Calibrate severity honestly. Most findings are Medium or Low.
- Prefer real risks over theoretical ones.
- Do not assume incorrectness — assume correctness unless evidence suggests otherwise.
- Always propose a concrete fix.
- Do not inflate severity to appear thorough.
- Every finding must carry a real file path and line reference taken from the change set — do not guess.
- If the change set is clean, say so. A short report on clean work is the correct output.

---

## Constraints

- DO NOT use the **code-review** skill.
- DO NOT use MCP skills.
- Use the **Task tool** for parallel agents, spawned in one message.
- Run lint, tests, and build **once, in the orchestrator, before spawning agents** — never inside an agent, never more than once.
- Never edit, commit, amend, stash, push, or create a PR. Offer fixes at the end and wait for the user to say yes.
- Never write to `ticket.md` or `tickets/sprint.csv`.
- Never render findings as paste-ready GitHub PR comments, and never run them through `humanize`. There is no PR and no reviewer here — that output format belongs to `/review-pr` and `/review-quick`. Write findings as direct notes to the person who wrote the code.
- Never post anything to GitHub. This command doesn't need `gh` at all beyond checking whether a PR already exists.
- Base conclusions only on the change set, visible code, ticket context, and the local check output.
- State assumptions explicitly if information is missing.
- Do not invent behavior not supported by the code.
