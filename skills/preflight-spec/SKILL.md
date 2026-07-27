---
name: preflight-spec
description: Use when the user gives a vague or underspecified coding task. Produces a short goal/non-goals/acceptance-criteria/verification spec and gets confirmation before editing production code.
---

# Preflight Spec

Use this skill when the user gives a vague or underspecified coding task.

## Purpose

Turn the task into a short implementation spec and verification target before editing production code.

## Core rule

Do not start editing production code for non-trivial work until there is:
- a goal
- non-goals or scope boundaries
- acceptance criteria
- a verification target

## Workflow

1. Classify task type
2. Decide whether the task is trivial, medium-risk, or high-risk
3. Inspect relevant files if needed and allowed
4. Ask up to 3 blocking questions if implementation would otherwise be ambiguous
5. Produce a short spec
6. Define verification target
7. Wait for user confirmation before implementation unless the task is clearly trivial

## Task types

- bugfix
- feature
- refactor
- frontend/UI
- API change
- DB/migration
- investigation
- test/eval
- documentation

## Risk levels

### Trivial

Examples:
- copy change
- rename a label
- small documentation edit
- obvious one-line config change

Behavior:
- do not ask unnecessary questions
- provide a tiny checklist
- proceed if the user asked for implementation

### Medium-risk

Examples:
- contained bugfix
- small feature
- UI behavior change
- test addition
- localized refactor

Behavior:
- inspect relevant code first when useful
- ask up to 3 blocking questions
- write a short spec
- identify a test, repro, or manual check

### High-risk

Examples:
- database migration
- auth/permissions
- billing/payment
- destructive actions
- broad refactor
- public API contract change
- data loss risk

Behavior:
- do not implement until the spec is confirmed
- require explicit acceptance criteria
- require verification plan
- call out rollback or migration risk where relevant

## Spec format

Use this format:

```md
Task type:
Risk level:

Goal:

Non-goals:

Relevant files/modules inspected:

Acceptance criteria:

Verification target:

Risks / ambiguity:

Blocking questions:
```

## Verification target guidance

For bug fixes:
- reproduce the bug
- add or identify a regression test/repro
- confirm it fails before the fix
- implement
- run the same check again

For frontend/UI:
- use a browser repro, Playwright check, screenshot, DOM measurement, or manual acceptance check
- do not patch UI blind

For API changes:
- define request/response contract
- add or update contract tests
- verify error behavior and backward compatibility where needed

For DB/migration:
- inspect schema and migrations
- verify migration applies cleanly
- verify existing data shape is handled
- document operational risks

For refactors:
- identify behavior that must not change
- add characterization tests if coverage is weak
- do not combine broad refactors with feature changes unless explicitly approved

## Question rules

Ask questions only when the answer changes the implementation.

Ask at most 3 questions at once.

Prefer specific questions over generic ones.

Bad:

```txt
What exactly do you want?
Which files should I edit?
```

Good:

```txt
Should duplicate detection happen before or after normalization?
Should existing duplicates be cleaned up, or only new duplicates prevented?
Is this API change allowed to break existing clients?
```

If the answer is discoverable from the codebase, inspect first instead of asking.

## Stop conditions

Before implementation, stop and ask for confirmation when:

- acceptance criteria are unclear
- verification target is missing
- the task touches high-risk areas
- multiple reasonable implementations exist
- user intent conflicts with existing tests or architecture

## Final response after implementation

When implementation is complete, report:

- spec followed
- files changed
- verification performed
- before-fix failure observed, if applicable
- after-fix result
- remaining uncertainty