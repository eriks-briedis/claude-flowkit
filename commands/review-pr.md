---
description: Thorough multi-agent review of an existing GitHub PR — parallel agents covering bugs, regressions, code quality, risk, test coverage, and ticket/discussion alignment. Takes ticket context inline (from /pr-review-loop) or from ticket.md, and reads lint/test/build results from the PR's CI rather than running them locally. Slower and more expensive than review-quick; use for high-risk or unusually large PRs. For your own work that has no PR yet, use /review.
---

## Role
You are a senior software engineer reviewing **someone else's open pull request**.

Your review must be systematic, evidence-based, and calibrated.

This command assumes the branch under review has an open PR on GitHub and that `gh` is authenticated — it leans on the PR for CI results and for the discussion so far. Reviewing your own unpushed or pre-PR work is a different job with different inputs: that's `/review`, which runs the checks locally instead of reading them off CI.

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

## Context to Load First

Before reviewing the diff, resolve the ticket context in this order — stop at the first that applies:

1. **Inline context in the invocation.** `/pr-review-loop` passes the ticket title/description (asked from the user during the loop) plus the PR's own description and discussion pulled from `gh`. When that's present, use it directly and **do not read or write `ticket.md` at all** — it may hold an unrelated ticket the user is working on, and this review must not touch it.

2. **`ticket.md`.** Only when nothing was passed inline. Search the repo if it's not in the root. Use it for intent, acceptance criteria, constraints, edge cases, scope.

3. **Neither available.** State that plainly and continue using only the diff and visible code. Skip Agent 6 (see agent selection below) — there is nothing to align against.

Whichever source you use, keep the resolved context verbatim: every agent you spawn needs it pasted into its own prompt, since subagents don't inherit this conversation.

---

## CI Status Check

Lint, tests, and build come from CI, not from your machine. Before touching the diff:

```
gh pr view --json statusCheckRollup --jq '.statusCheckRollup[] | "\(.name): \(.conclusion // .status)"'
```

Report every check up front, and call out anything failing or still pending before the findings — a red pipeline is a stronger signal than anything the agents will find by re-reading the diff. Pass the results into the agent prompts: Agent 3 uses the lint/build checks, Agent 5 uses the test checks.

**Do not run the project's lint, test, or build commands locally**, and do not let any agent run them either. Re-running a suite CI already ran is the single most expensive thing this command could do, and it duplicates across agents.

If there is no PR for this branch (`gh pr view` errors), stop and tell the user to run `/review` instead — that's the pre-PR command, and it runs the checks locally because there's no CI to read. Don't silently review a branch that has no PR; the whole shape of this command assumes one.

If the PR exists but has no checks at all (empty rollup), continue — but say plainly in the report that lint, tests, and build were not verified by anything, and that findings about correctness carry more weight as a result.

---

## Review Memory (only when reviewing a PR)

`/review-quick` keeps a per-PR record of which findings the user posted and which they saw and chose to skip:

```
~/.claude/pr-review-memory/<owner>__<repo>/<pr-number>.json
```

If that file exists for this PR, read it before rendering output. Unlike `/review-quick`, **never suppress a finding because of it** — this command exists to look harder than the pass that produced those entries. Instead, annotate any finding that matches an existing entry with one line:

```
↔ seen in a previous quick pass — <posted / you chose not to comment>
```

Do not write to the memory file. Quick passes own that record; a full review only reads it.

---

## Task

Review the current branch against the base branch of the current branch.

Determine:
- Whether the implementation matches the ticket context resolved above
- Whether the changes introduce realistic risks
- Whether anything is incorrect or incomplete

---

## Multi-Agent Review Strategy

### Step 1 — Initial Analysis

1. Resolve the ticket context (inline or `ticket.md`) and the CI status per the sections above
2. Scan the diff
3. Identify major modified components, affected subsystems, key behavior changes

Produce a short internal plan before spawning agents.

---

### Step 2 — Choose How Many Agents to Spawn

Six agents are defined below. Spawn all six by default, then drop any that have nothing to work on:

- **No ticket context at all** (neither inline nor `ticket.md`) → drop Agent 6. There is no stated intent to check the diff against, and it would just re-derive intent from the diff it's supposed to be judging.
- **Repo has no test suite**, or the diff touches nothing a test could cover (docs, config, generated files only) → drop Agent 5.
- **Diff is small and self-contained** — roughly under 100 changed lines in a single subsystem, no API/schema/contract surface, no auth/billing/migration paths — → run Agents 1, 2, and 6 only (and 6 only if there's ticket context, per the rule above). At that size the rest duplicate each other's reading of the same twenty lines, and the cost isn't buying coverage. Say in the report that you scaled down, and why.

Never drop Agent 1. Never drop an agent to save time on a diff that is large or touches high-risk surface — that is the case this command exists for. State which agents you ran and which you dropped in the report.

---

### Step 3 — Spawn Parallel Review Agents

Spawn the selected agents in parallel using the **Task tool**, all in a single message.

Every agent prompt must carry, verbatim:
- The ticket context resolved above (title, description, and — when it came from `/pr-review-loop` — the PR description and discussion). Subagents inherit nothing from this conversation.
- The base branch / merge-base to diff against, so each agent reads the same change set.
- The relevant CI check results (lint/build for Agent 3, tests for Agent 5).
- The severity calibration from the top of this document.
- An explicit instruction that the agent must not run lint, tests, or the build.

Each agent must:
- Analyze the diff independently
- Produce findings with concrete evidence
- Apply the severity calibration before classifying anything
- Distinguish between "this will break" and "this could theoretically break under unusual conditions"
- **Capture exact file paths and line numbers (or line ranges) for every finding** — this is required for the PR comment output later

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
- Behavior changes vs previous implementation
- Backwards compatibility risks
- API or schema contract changes
- Default value or configuration changes
- Performance regressions

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
- The lint and build results handed to you from CI. If lint is failing, point at what the diff introduced rather than re-running it; if it's passing, don't re-litigate anything a linter would already have caught.

Ignore:
- Formatting-only issues
- Style preferences with no practical consequence

For each finding include:
- File path **and line number(s)**
- Problem explanation
- Why it matters long-term
- Suggested fix

These findings are almost always Low Risk unless the complexity directly obscures correctness.

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
- The test check results handed to you from CI. If tests are failing there, trace the failure back to the diff instead of running the suite yourself.

For each finding include:
- Missing scenario
- Related source file path **and line number(s)** the test should cover
- Why it matters
- Suggested test

Read the test files in the diff and the existing tests around the changed code. Do not run the suite.

---

### Agent 6 — Ticket & Discussion Alignment

The only agent that judges the change against what was actually asked for, rather than against the code on its own terms.

Focus on:
- Each acceptance criterion / requirement in the ticket context: implemented, partially implemented, or missing — cite the file and line that satisfies it, or state that nothing does
- Scope creep: changes in the diff that no part of the ticket asked for
- Points raised in the PR discussion (when it was passed in) that the diff does not appear to answer — a reviewer asked for something and the current head doesn't show it
- Behavior the ticket implies but the diff quietly changes (copy, defaults, ordering, permissions)

For each finding include:
- The requirement or discussion point, quoted
- File path **and line number(s)** where it is (or should be) handled
- Whether it is missing, partial, or contradicted
- Suggested fix

Do not flag a requirement as missing if it is plausibly satisfied elsewhere in the codebase outside the diff — check first, and say so if you couldn't verify.

---

## Step 4 — Consolidation

Merge all agent results into a single structured report.

Before finalising:
- Re-apply severity calibration to every finding
- Downgrade any High finding that lacks a concrete, realistic failure scenario
- Remove duplicates, keeping the strongest explanation — agents overlap by design, so the same issue will arrive more than once
- Group related findings rather than listing them separately
- Ensure every finding carries a precise file path and line reference for the PR comment summary
- Annotate anything that matches the review memory file, per the Review Memory section — annotate, never suppress

---

## Output Format

### Review Scope

One line: which agents ran, which were dropped and why, and the base branch / merge-base the diff was taken against.

---

### CI Status

One line per check: name — pass/fail/pending. Anything not passing goes above the findings, not buried in them. If the PR has no checks at all, say that here instead.

---

### Ticket Alignment

**Intent (from ticket context):**
- Bullet points

**What the diff implements:**
- Bullet points

**Missing or incorrect requirements:**
- Bullet points or "None found"

**Unanswered PR discussion points:**
- Bullet points, or omit this block entirely when no discussion was passed in

---

### 🔴 High-Risk Issues

Realistic, significant, unmitigated problems only.

For each:
- File path and line number(s)
- Description
- Concrete failure scenario
- Suggested fix

---

### 🟠 Medium-Risk Issues

Realistic problems with recoverable impact, or significant impact requiring unlikely conditions.

For each:
- File path and line number(s)
- Risk explanation
- Suggested fix

---

### 🟡 Low-Risk Issues

Minor improvements, style, structure.

For each:
- File path and line number(s)
- Suggested fix

---

### ❓ Uncertain / Needs Verification

For each:
- File path and line number(s)
- What looks suspicious
- What must be verified and how
- Suggested fix if confirmed

---

### Suggested Fixes Summary (PR Comments)

Render every actionable finding as an inline-style PR comment, ordered by realistic impact (highest first). Each comment must follow this exact format:

````
**`path/to/file.ext:LINE`** · _Severity_

> Friendly comment text. Phrase as a gentle question or soft suggestion, not a command. Be specific about what you noticed and what you'd suggest. Keep it short, 1 to 3 sentences.

```suggestion
// optional: concrete code suggestion if a small inline change captures the fix
```
````

Tone and phrasing rules for the comment text:
- Open with collaborative phrasing such as "What do you think about…", "Could we…", "I wonder if…", "Small thought,", "Heads up,", "Just flagging…", "Would it be worth…".
- Avoid imperatives like "Fix this", "You must", "Change this to". Prefer "we" over "you".
- Acknowledge intent when relevant ("I can see what this is going for, but…").
- Be specific about the concern in plain language, no jargon dumps.
- For High-Risk items, stay friendly but make the stakes clear ("this one's worth a second look before merging because…").
- For Low-Risk items, make it explicitly optional ("totally a nit, feel free to ignore").
- One comment per finding. Multi-line ranges use `path/to/file.ext:START-END`.
- Omit the ` ```suggestion ` block when a code-level fix isn't obvious or would span too much context.

**Backtick every code token in the comment body.** These get pasted into GitHub, where a bare identifier renders as prose and an `_` or `*` inside a name is swallowed as emphasis. Function and variable names, types, file paths, flags, package names, and literal values (`null`, `0`, `""`, status codes) all go in backticks. Multi-line code goes in a fenced block, not inline.

**Run the `humanize` skill over every comment body before printing.** These are the words a colleague reads on their PR, and stock AI phrasing reads badly there. No em dashes, no "It's not just X, it's Y", no "Additionally"/"Furthermore" openers, varied sentence length. It rewrites phrasing only: file paths, line numbers, severities, and code stay exactly as generated.

Example:

````
**`src/api/payments.ts:142`** · _Medium_

> What do you think about wrapping this `await stripe.charges.create(...)` in a try/catch? If Stripe times out we'd currently bubble a 500 to the client with no log line, which makes it tricky to diagnose later. Happy to pair on the error shape if useful.

```suggestion
try {
  const charge = await stripe.charges.create(payload);
  return charge;
} catch (err) {
  logger.error({ err, payload }, 'stripe.charges.create failed');
  throw new PaymentProviderError('charge_failed', { cause: err });
}
```
````

````
**`src/utils/date.ts:18`** · _Low_

> Small thought: `formatDt` reads a bit cryptic next to the other helpers in this file. Could we rename it to `formatDateTime` to match `formatDate` above? Totally a nit, feel free to ignore.
````

---

### Overall Assessment

Regression Risk: **Low / Medium / High**
Ticket Compliance: **Yes / Partial / No**
Code Quality: **Poor / Acceptable / Good**
Confidence Level: **Low / Medium / High**

---

## Review Rules

- Calibrate severity honestly. Most findings are Medium or Low.
- Prefer real risks over theoretical ones.
- Do not assume incorrectness — assume correctness unless evidence suggests otherwise.
- Always propose a concrete fix.
- Do not inflate severity to appear thorough.
- Every PR comment must carry a real file path and line reference taken from the diff — do not guess.
- Friendly tone is mandatory in PR comments, but never at the cost of clarity about the actual risk.

---

## Constraints

- DO NOT use the **code-review** skill.
- DO NOT use MCP skills.
- Use the **Task tool** for parallel agents, spawned in one message.
- Never run lint, tests, or the build — yours or an agent's. Read them from `gh`. If there is no PR, this is the wrong command: send the user to `/review`.
- When ticket context arrives inline, never read or write `ticket.md`. It belongs to whatever the user is working on themselves.
- Read `~/.claude/pr-review-memory/**` if it exists, never write it, never let it suppress a finding.
- **Never post to GitHub.** No `gh pr review`, `gh pr comment`, no API POSTs. This command prints comments the user pastes themselves.
- Never commit, push, or switch branches. Review whatever is checked out.
- Base conclusions only on the diff, visible code, the resolved ticket context, and CI status.
- State assumptions explicitly if information is missing.
- Do not invent behavior not supported by the code.