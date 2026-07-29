---
name: humanize
description: Rewrite user-facing text so it reads like a person wrote it, not a model. Use as a final pass over any prose a human will actually read: PR comments and replies, PR or ticket descriptions, commit messages, release notes, docs, summaries. Removes em dashes, AI stock phrasing, and uniform sentence rhythm while preserving every fact, number, name, and constraint exactly.
---

# Humanize

Rewrite AI-generated prose so it sounds like it came from a person, without changing what it says.

## When to use

Run this as the **last** step before text reaches a human: PR review comments, replies to reviewers, PR and ticket descriptions, commit messages, release notes, README and docs prose, status updates, summaries.

## When not to use

- **Code.** Never rewrite code, identifiers, or config.
- **Code comments.** Different job, different rules. That's `/comment-cleanup`.
- **Quoted material.** Someone else's words stay exactly as they were written.
- **Machine-read output.** JSON, logs, structured formats, anything parsed rather than read.

## Core rule

Meaning is fixed. Wording is free.

You may change rhythm, word choice, sentence boundaries, and flow. You may not add an idea, drop a caveat, soften a warning, sharpen a hedge, or introduce enthusiasm the original didn't have. If the input is uncertain about something, the output stays exactly that uncertain.

If the text already reads naturally, make light edits or none. Rewriting for the sake of rewriting is its own failure.

## Hard bans

### Em dashes

No `—`. Also no `–` standing in for one, and no spaced hyphen ` - ` smuggling one back in.

Recut the sentence instead. Usually one of these works:

- Split into two sentences.
- Use a comma.
- Use parentheses.
- Reorder so the aside isn't an aside.

Do not reflexively swap in a semicolon or a colon. Doing that to every former em dash is just a new tell.

### Stock vocabulary

Cut or replace: delve, leverage (as a verb), robust, seamless, streamline, comprehensive, holistic, myriad, plethora, pivotal, crucial, vital, elevate, empower, foster, harness, unlock, navigate (figurative), landscape, realm, testament, tapestry, underscore (figurative), cutting-edge, best-in-class, game-changer, boasts, aims to, seeks to, a wide range of.

### Stock phrases

- "It's not just X, it's Y" and every variant of that construction
- "not only ... but also"
- "In today's fast-paced world", "In the ever-evolving landscape of"
- "Let's dive in", "Let's explore", "dive deep into"
- "It's worth noting that", "It's important to note", "It's important to remember"
- "At the end of the day"
- "I hope this helps", "Feel free to reach out", "Let me know if you have any questions"
- "Great question", "Absolutely", "Certainly" as openers
- "In conclusion", "Overall" as a closing bow
- "Additionally", "Furthermore", "Moreover" starting a sentence. Use "and", "but", "so", or nothing
- "This ensures that", trailing "ensuring ..."
- Emoji in prose

### Structural tells

- **Rule of three everywhere.** "Fast, reliable, and scalable." Two is fine. Four is fine. Three every single time is a tell.
- **Uniform sentence length.** Model prose sits at 15–20 words per sentence for paragraphs on end. Vary it. A four-word sentence next to a twenty-five-word one is what human writing looks like.
- **Uniform paragraph length.** Same problem, one level up.
- **Parallel construction in consecutive sentences.** Break the symmetry.
- **Restating the question before answering it.**
- **Closing each section with a sentence that summarizes the section.** Let it just end.
- **Bolding for emphasis in every paragraph.**
- **Bulleting prose** that was never a list.
- **Hedge stacking.** "This may potentially sometimes cause..." Pick one hedge or none.

## What to do instead

- Use contractions where the register allows it.
- Prefer the concrete: a number, a file name, a specific behavior over an abstraction.
- Cut hedges. State it, or say you don't know.
- Plain connectives. "But" over "however". "So" over "therefore".
- Keep any idiosyncratic phrasing already in the text. That's the human part.
- Match the register of the destination. A PR comment stays short and collaborative; humanizing it doesn't mean making it chatty.

## Preserve verbatim

Copy these through untouched, character for character:

- Code blocks and inline code
- Identifiers, file paths, URLs, commands, flags
- Numbers, dates, versions, ticket keys
- Names of people, repos, products
- Anything inside a quote

Never "improve" a technical term because it reads awkwardly. `latest_foreign_comment_at` is not a phrasing problem.

## Inline code formatting

Anything that is code must be wrapped in backticks. This isn't decoration. The destination is usually GitHub markdown, where a bare identifier renders as ordinary prose and an underscore or asterisk inside a name gets eaten as emphasis. `do_the_thing` renders as intended; do_the_thing may not.

Backtick these:

- Function, method, class, type, and component names
- Variables, fields, config keys, environment variables
- File paths and `path/to/file.ts:42` references
- Commands, CLI flags, package names
- Literal values: `null`, `true`, `0`, `""`, status codes, enum members
- Error and exception names

Multi-line code goes in a fenced block with a language tag, not inline backticks.

Do not backtick ordinary English for emphasis. Backticks mean "this is a literal token", not "this word matters".

## Self-check before output

1. Search the output for `—` and `–`. Zero hits.
2. Every number, name, path, URL, and version in the input still appears in the output.
3. No claim in the output that wasn't in the input.
4. Read the first words of three consecutive sentences. If they're structurally identical, vary them.
5. Scan for the banned vocabulary and phrases above.
6. Longest and shortest sentence in any paragraph should differ noticeably.

## Output

Return only the rewritten text. No preamble, no explanation of what changed, no diff, unless the caller explicitly asked to see the changes.

## Examples

**Before**

> This PR introduces a comprehensive refactor of the authentication module — it not only improves readability but also ensures that future changes are easier to implement. Additionally, it streamlines the token refresh logic.

**After**

> Refactors the auth module. Mostly readability, but it also makes the token refresh path a lot easier to change later.

---

**Before**

> Great catch! I've added a null check to handle the edge case — this ensures the component won't crash when the items array is empty. Let me know if you have any questions!

**After**

> Good catch. Added a guard for the empty `items` case, so it won't crash there anymore.

---

**Before**

> The script leverages the GraphQL API to fetch comprehensive thread data — providing a robust, reliable, and maintainable foundation for the command's memory system.

**After**

> The script uses the GraphQL API because it's the only one that exposes thread resolution state. That's what the memory layer keys off.
