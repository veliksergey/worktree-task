# Task: <repository>, <slug>, <yyyy-mm-dd hh:mm>

<!--
Written by Claude before any code, and kept up to date until the task ends. The
reviewers judge the change against it, so it says what the user asked for, not what
was built. The sections match the codex-review-loop task file, so its codex-loop
skill reads this file as it is. Never put secrets in this file.
-->

## Request (verbatim)
<the user's words, copied exactly; with --from, also the quoted section of the source
file and its path; add later clarifications from the user as dated quotes>

## Acceptance criteria
1. <one observable, testable behavior per line>
2. <...>

## Out of scope
<what the request does not ask for, or "none stated">

## Decisions during implementation
- Base: <branch> at <short sha>. Review: Claude, then Codex | Claude only (<reason>).
- Tests first: on | off — <reason>.
- <decision> — <reason>. Appended as each decision is made, including during review
  rounds. A change to a locked test is recorded here before it is made.

## Handoff
Files: <changed files, repository-relative>
Tests: <test file>: <what each test proves, by criterion number where possible>
Assumptions: <what was assumed and how it was checked>
Checks: <command>: pass | fail | not run (<reason>), one per documented check
Risks: <known risks, or "none known">
