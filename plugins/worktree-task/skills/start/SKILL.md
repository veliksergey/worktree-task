---
name: start
description: Run one task (a fix, a feature, any change) in its own git worktree folder and branch next to the project. The skill writes tests first when they help, runs a fresh-context Claude review, adds a Codex review when the codex-review-loop plugin is installed, then makes one commit and fast-forward merges it into the base branch after the user's OK. It ends with a report in the terminal. Run one task per terminal to work on several at once.
argument-hint: "\"<task>\" [--from <file>] [--base <branch>] [--name <slug>] [--codex auto|on|off] [--tests-first auto|on|off] [--rounds N] [--auto]"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_SKILL_DIR}/worktree.sh" *), Bash(git status *), Bash(git diff *), Bash(git log *), Bash(git rev-parse *), Bash(git merge-base *), Bash(codex login status), Bash(mkdir *), Bash(date *), Read, Write, Edit, Grep, Glob, EnterWorktree, ExitWorktree
---

# Worktree task

You take one task from request to merge in an isolated folder and branch beside the
user's project. The user keeps working, or runs other tasks, in other terminals, and
reads your report in this one.

By typing this command, the user authorizes the following for this task only:
- creating the folder `../<repo>-<slug>` and the branch `task/<slug>`;
- one commit on that branch;
- a fast-forward merge of that branch into the base branch, and then removal of the
  folder and branch.

The commit and the merge wait for the user's OK at the checkpoint (step 10), unless
`--auto` was given. A second commit is never covered by the invocation, not even with
`--auto`. It needs the user's explicit OK at the moment it is needed (step 12).
Nothing here authorizes a push, a force push, an amend, a reset, a merge of any other
branch, or a commit outside the task folder. Every commit, rebase, merge, and removal
goes through `worktree.sh`; never run those git commands directly.

Arguments received: `$ARGUMENTS`

## 1. Parse the arguments

| Argument | Meaning | Default |
|---|---|---|
| `"<task>"` | What to do, in the user's words. | required, unless `--from` gives it |
| `--from <file>` | Read the task from this file in the main folder, for example a review document. If the task text names one item of it, such as `F13`, that item is the task. | none |
| `--base <branch>` | Branch to start from and to merge into. | the main folder's current branch |
| `--name <slug>` | Folder and branch suffix: lowercase letters, digits, and inner hyphens, at most 40 characters. | derived from the task |
| `--codex auto\|on\|off` | Codex review after the Claude review. `auto` runs it when available, `on` requires it, `off` skips it. | `auto` |
| `--tests-first auto\|on\|off` | Write and lock tests before the implementation (step 5). | `auto` |
| `--rounds N` | Maximum rounds for each review stage. | 3 |
| `--auto` | Skip the checkpoint: commit and merge as soon as the merge gate passes. | off |

With neither a task text nor `--from`, ask the user what to do and stop until they answer.

The git steps run through the script `${CLAUDE_SKILL_DIR}/worktree.sh`, always as
`bash "${CLAUDE_SKILL_DIR}/worktree.sh" <command> ...`. It prints `KEY=value` lines on
stdout and its reasons on stderr. Exit codes: 0 done; 2 usage error; 3 refused, nothing
changed; 4 conflict, rolled back; 5 git error, state needs a look. On any non-zero
exit, quote its stderr to the user.

A fingerprint counts only when `worktree.sh fingerprint` exits 0 and prints exactly six
lines. Any other result stops the task (step 14): a failed fingerprint proves nothing,
and two failed ones would compare as equal. This applies to every fingerprint below,
including `REVIEWED_FP`.

## 2. Prepare in the main folder

Nothing is created in this step.

1. Run `worktree.sh preflight`. Keep `REPO_ROOT`, `REPO`, `BRANCH`, and `DIRTY`. Exit 3
   means this is not a git repository's main folder, for example a task folder. Tell
   the user and stop.
2. `BASE` is `--base` or `BRANCH`. If `BASE` is empty because HEAD is detached, ask for
   `--base`. If `DIRTY=yes`, tell the user two things:
   - the task starts from the last commit of `BASE`, so their uncommitted changes in
     the main folder are not part of it;
   - the merge at the end lands in this folder, and git refuses it if it would
     overwrite those changes.
3. Read the request now. Untracked files in the main folder, such as a new review
   document, do not exist in the task folder.
   - With `--from`, read the file. When the task text names one item of the file,
     quote that item's whole section verbatim; otherwise the whole file is the task.
   - Read the repository's `AGENTS.md` and `CLAUDE.md`. You need the documented install
     and check commands, test conventions, branch rules, and invariants.
4. Ask the user now if the request leaves a choice that changes the result: an open
   question in the source document, two plausible designs, or unclear scope. Ask
   before any folder exists. `--auto` does not skip this; it only skips the
   checkpoint.
5. Decide the Codex stage:
   - `--codex off`: no Codex.
   - Otherwise Codex is available when both are true: the skill
     `codex-review-loop:codex-loop` is in your list of available skills, and
     `codex login status` prints `Logged in`.
   - `--codex on` and Codex unavailable: tell the user why and stop.
   - `auto` and Codex unavailable: Claude review only. Say why.
6. `SLUG` is `--name`, or a short name derived from the task, such as
   `f13-live-list-counts` or `csv-export`.
7. If `AGENTS.md` forbids committing to or merging into `BASE`, for example "never
   commit to main", tell the user. Continue only if the user names another base.

## 3. Create the task folder and move into it

1. Run `worktree.sh create <SLUG> <BASE>`. Keep `WORKTREE`, `BRANCH` (now the task
   branch, `task/<SLUG>`), `BASE_SHA`, and `RUN_NAME`. Exit 3 because the folder or
   branch exists means another task uses that name: suggest `--name` and stop.
2. Run `worktree.sh copy-local <WORKTREE>`. It copies the gitignored local files the
   project needs, such as `.env.local`, listed by the repository's `.worktreeinclude`
   or, without that file, the root `.env*` files. Keep the `COPIED` names for the
   report. Never print or read their contents.
   - A `REFUSED` line names a file that was not copied, because a folder on its path
     inside the task folder is a link that could point outside. Tell the user.
   - A `NOT_IGNORED` line names a file that was not copied, because the task folder's
     own ignore rules do not cover it, so it would be committed. This usually means
     `--base` is older than the main folder's `.gitignore`, or a `.gitignore` change
     is uncommitted. Tell the user.
   - A non-zero exit stops the task.
3. Create the run folder `RUN_DIR="$HOME/.claude/worktree-tasks/<RUN_NAME>"`.
   `TASK_FILE` depends on the Codex stage:
   - With Codex: `$HOME/.claude/codex-reviews/<RUN_NAME>/task.md`. codex-loop reads its
     task file from `~/.claude/codex-reviews/<folder name>/task.md`, and the task
     folder's name is `<RUN_NAME>`.
   - Without Codex: `$RUN_DIR/task.md`.
4. Write `$RUN_DIR/state.md` with the values a resumed session needs: `REPO_ROOT`,
   `WORKTREE`, `BRANCH`, `BASE`, `BASE_SHA`, `TASK_FILE`, the review stages, the
   tests-first mode, `--auto`, and the current step. Update the step line at the start
   of every following step.
5. Use the `EnterWorktree` tool with `path` set to `WORKTREE`. Claude Code asks the
   user to confirm the move, because the move also loads that folder's project
   settings, and permission rules do not cover it. Tell the user it moves this session
   into the task folder.
   Confirm that `git rev-parse --show-toplevel` now prints the task folder. From here
   until step 12, every edit, check, and review happens in the task folder. Never edit
   files in `REPO_ROOT`.

   If the move is refused or cannot be confirmed, for example in a non-interactive
   session, stop (step 14) in every review mode. Working from the main folder would
   load the main folder's project settings instead of the task folder's. It would also
   point codex-loop at the wrong folder. The task resumes when the user approves the
   move.
6. Install dependencies with the install command documented in `AGENTS.md` or
   `CLAUDE.md`. Otherwise use the lockfile:

   | Lockfile | Command |
   |---|---|
   | `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
   | `package-lock.json` | `npm ci` |
   | `yarn.lock` | `yarn install --immutable` if `.yarnrc.yml` exists, else `yarn install --frozen-lockfile` |
   | `bun.lock` or `bun.lockb` | `bun install --frozen-lockfile` |

   No lockfile: skip. A failed install stops the task.
7. Run the documented checks once before changing anything, as a baseline: lint,
   typecheck, test, build, whichever exist. If any fails, the failure comes from
   `BASE`. Tell the user, and ask whether to continue: a failing check blocks the merge
   gate unless the task fixes it.

## 4. Write the task file

Write `TASK_FILE` from `${CLAUDE_SKILL_DIR}/task-template.md`:
- the request verbatim (with `--from`, the quoted section and the file's path);
- numbered acceptance criteria, one testable behavior each;
- out of scope;
- the first decisions: base and review stages.

Then decide tests first:
- `on` and `off` are used as given.
- `auto` is on for a bug fix, or when the criteria describe behavior a test can check.
- `auto` is off when the change is documentation-only, configuration-only, UI styling
  or layout, or exploratory work whose interface is not known yet.

Record the mode and the reason as a decision.

Print the acceptance criteria and the tests-first decision in the terminal, then
continue. The user's OK comes at the checkpoint, before the commit.

## 5. Tests first (when on)

1. Interface: for a new feature, write only what tests need to compile against. That
   means types, exported signatures, and stubs that throw `new Error("not implemented")`,
   with no logic. A bug fix skips this.
2. Take a snapshot of every changed file that is not a test, for example with
   `git status --porcelain --untracked-files=all` and `worktree.sh hash <files>`. A test
   file is named `*.test.*` or `*.spec.*`, or sits in a `__tests__/`, `tests/`, or
   `test/` folder, unless `AGENTS.md` defines the convention otherwise. Save the
   snapshot to `$RUN_DIR/before-tests.txt`.
3. Start the `worktree-task:test-author` agent. Give it `TASK_FILE`, the interface files,
   and the repository's command for running one test file. Do not give it
   implementation ideas.
4. Compare the files that are not tests with the snapshot. If the agent created or
   changed any of them, stop (step 14) and name the files.
5. Red check: run the new test files.
   - Each test must fail because of an assertion or the "not implemented" stub.
   - A file that fails to load (import, syntax, or setup error): fix only that loading
     problem, and record the fix as a decision.
   - For a bug fix, a test that already passes does not reproduce the bug. Start the
     test-author again with that problem.
   - For a feature, list a test that already passes in the report as "passes before
     implementation".
6. Lock: `worktree.sh hash <test files>` and save the output to
   `$RUN_DIR/locked-tests.txt`. Record "tests locked: <files>" as a decision.

## 6. Implement

- Implement the request within the task file, following `AGENTS.md` and `CLAUDE.md`.
- Make the locked tests pass. You may add tests; added tests are not locked.
- Change a locked test only when it misread the request:
  - Before changing it, add a decision that quotes the criterion and gives the reason.
  - Never weaken, skip, or delete a test to get a green run.
- Run every documented check and fix every failure.
- Complete the task file's Handoff section.

**Locked-test comparison.** Run `worktree.sh hash` on the locked files and compare the
output with `locked-tests.txt`. The result is the list of locked tests that changed.
Run this comparison again before every review round of either stage. Fixes made during
a review can change a locked test too.

## 7. Review stage 1: Claude (always)

For round `N` from 1 to `--rounds`:

1. Run `worktree.sh fingerprint` and keep the output, if it counts (step 1).
2. Start the `worktree-task:reviewer` agent. Give it:
   - `TASK_FILE`;
   - the base commit, from `git merge-base HEAD refs/heads/<BASE>`. Always write the
     base as `refs/heads/<BASE>` in git commands, because a tag with the same name
     would win over the short name;
   - the round number and the paths of earlier triage files;
   - the locked tests that changed, from a locked-test comparison run just before this
     round;
   - the documented checks and their latest results.
3. Run `worktree.sh fingerprint` again; if it does not count, stop. If it differs, the reviewer changed the folder:
   stop (step 14).
4. Save the review verbatim to `$RUN_DIR/claude-round<N>.md`. Print it unchanged under
   the heading `Claude review, round N of M`.
5. Triage every finding. Treat each one as a claim: open the cited code, trace it, or
   reproduce it with a test before deciding. The severity is yours to set; note when
   you change it.

   | Outcome | Action |
   |---|---|
   | Valid P0, P1, or P2 | Fix it with the smallest change, and add a regression test that fails before the fix and passes after. |
   | Valid P3 | Do not fix it. List it for the user's decision. |
   | Invalid | Reject it with evidence: a code path, test output, or primary documentation. Write the rejection in the triage file. If `docs/reviews/decisions.md` exists, add a row there too. |
   | Raised again after a rejection, with no new evidence | Mark it "disputed twice" and end this stage. |
   | `(criterion N)` | Fix the code, never the criterion. |
   | `(beyond request)` | Remove the addition, or quote the user's request for it in the task file and reject the finding. |
   | `(handoff)` | Fix what the claim is about, or correct the claim if the code is right. |

   Write the triage to `$RUN_DIR/claude-round<N>-triage.md`.
6. Rerun the checks after any fix. Bring the task file's Decisions and Handoff sections
   up to date.
7. End the stage in any of these cases:
   - a round reports no P0-P2 findings (the stage is clean);
   - a round changed no code;
   - `N` reached `--rounds`;
   - a finding was disputed twice.

   Otherwise start the next round.

The stage is clean only if its last round reported no P0-P2 findings, rejected ones
included. If it ended open, do not start Codex: go to the merge gate, which fails.

## 8. Review stage 2: Codex (when enabled)

1. Make sure the task file's Handoff section is complete.
2. Invoke the skill `codex-review-loop:codex-loop` with
   `--focus "<FOCUS>"`, and with `--rounds <N>` when `--rounds` was given. `<FOCUS>` is
   this text, followed by the locked-test part:

   `performance: unbounded queries or loops, N+1 queries, missing limits or pagination, payload size, repeated work on hot paths; observability: failures logged with context and an error reference, no silent failures, no secrets or personal data in logs`

   Codex's own rubric already covers security, correctness, tests, contracts, and
   maintainability. The locked-test part comes from a locked-test comparison run just
   before the invocation:
   - When locked tests changed: `; locked tests changed after locking: <file> (locked hash <hash>), ...; for each, verify that the task file's Decisions entry justifies the change and that the test still proves what it proved before; an unjustified or weakening change is P1`.
   - When tests were locked but none changed: `; locked tests (unchanged since locking): <files>`.
   - When tests first was off: no locked-test part.
3. Follow codex-loop completely. It shows each Codex review verbatim, triages, fixes,
   and writes its final report. Its rule "the loop never commits" holds: the commit is
   step 11 of this skill, after the loop has ended.
4. Find the last round's Codex file: the newest
   `$HOME/.claude/codex-reviews/<RUN_NAME>/*-round*-codex.md`. Count its `[P0]`, `[P1]`,
   and `[P2]` findings. The stage is clean when there are none.
5. Run the locked-test comparison again. If a locked test changed during the Codex
   stage, the Claude reviewer has not seen that change. Run one more Claude round
   (step 7), which must be clean, before the merge gate.

## 9. Merge gate

The gate passes only when all of these hold:

- the documented checks pass on the final tree (rerun them if anything changed since
  the last run);
- the Claude stage is clean;
- the Codex stage is clean, or Codex did not run, with the reason recorded;
- every locked test that changed has its decision recorded;
- no stop condition was hit.

If the gate fails, stop (step 14). If it passes, run `worktree.sh fingerprint` and keep
the output as `REVIEWED_FP`: the exact tree the reviews and checks approved.

## 10. Checkpoint (skipped with `--auto`)

Print:
- the report so far, following `${CLAUDE_SKILL_DIR}/report-template.md`;
- `git status --short --untracked-files=all`;
- `git diff --stat <BASE_SHA>`.

Then ask: "Reply **ok** to commit and merge into `<BASE>`, or tell me what to change."
Only an explicit approval counts, such as ok, yes, go, commit, or merge.

If the user asks for changes:
1. Make them and rerun the checks.
2. Run one more round of each review stage that ran.
3. Return to the merge gate.

## 11. Commit

1. Run `worktree.sh fingerprint`. It must equal `REVIEWED_FP`. If anything changed after
   the gate, go back to step 9: checks and one more round of each review stage first.
2. `git status --short --untracked-files=all`: every file must belong to this task. A
   stray file, such as a build output the repository does not ignore, must not be
   committed. Ask the user about it.
3. Read `git log -10 --format=%B` and write the message in the same style: subject
   length and mood, a body that says what changed and why. Follow this session's
   instructions for commit attribution. Save it to `$RUN_DIR/commit-message.txt`.
4. Run `worktree.sh commit "$RUN_DIR/commit-message.txt"`. It stages everything and
   commits with the repository's hooks; it never skips or amends.
   - Exit 3 "git refused the commit": a hook failed and nothing was committed. Fix the
     cause, then go back to step 9. The fix needs the checks and one more round of each
     review stage, like any other change.
   - `HOOK_CHANGED=yes`: a hook changed the committed content, for example by
     reformatting it. Show `git diff <TREE_STAGED> <TREE_COMMITTED> --stat`. Then run the
     checks and one more round of each review stage on the branch against `BASE` (pass
     `--base refs/heads/<BASE>` to codex-loop). Continue only if the merge gate passes again;
     otherwise stop (step 14).

## 12. Rebase, merge, clean up

1. In the task folder, run `worktree.sh rebase <BASE>`.
   - Exit 4: a conflict. The rebase was aborted and the commit is intact. Stop (step 14)
     and name the files from the `CONFLICT` lines.
   - Exit 5: the rebase failed for another reason, and git's message says why. Stop
     (step 14) and quote that message. Do not call it a conflict.
   - Any other non-zero exit, such as 3 for uncommitted changes in the task folder,
     also stops the task (step 14). Never merge after a failed rebase.
   - `BASE_MOVED=yes`: other work reached `BASE`, so rerun the checks. A failing check
     stops the task (step 14).
   - `OVERLAP` lines name files changed on both sides. Run the review stages again on
     the branch against `BASE`, following steps 7 and 8 (for codex-loop, pass
     `--base refs/heads/<BASE>`), then the merge gate.
   - If a check or review after the rebase needs a code change, stop (step 14) before
     changing anything. Name the finding, and say that the fix needs a second commit,
     which the invocation does not cover. Only after the user explicitly approves:
     1. make the fix;
     2. run the checks and the review stages until the merge gate passes;
     3. commit with `worktree.sh commit`, and handle its result exactly as in step 11.4
        (a hook refusal or `HOOK_CHANGED=yes` goes back through checks, reviews, and
        the gate);
     4. repeat this step from 1.
2. Use the `ExitWorktree` tool with `action: "keep"`. Confirm that
   `git rev-parse --show-toplevel` prints `REPO_ROOT`.
3. Run `worktree.sh merge <BRANCH> <BASE>`.
   - Exit 3 "not a fast-forward" means another task merged meanwhile. Enter the task
     folder again with `EnterWorktree` (`path`: `WORKTREE`) and repeat this step from
     1. If it happens a second time, stop.
   - Any other exit 3 means the main folder is on another branch, or the merge would
     overwrite the user's uncommitted work. Stop, and tell the user exactly what to do
     and to reply "continue" afterwards.
   - Exit 5, or any other non-zero exit: stop (step 14), quote the message, and keep
     the folder and the branch.
   - Go on to cleanup only after exit 0 with a `MERGED_SHA` line.
4. Run `worktree.sh remove <WORKTREE> <BRANCH> <BASE>`.
   - It unlinks symbolic links and junctions first: on Windows, deleting a folder
     through git follows junctions and would delete the files they point to.
   - If it fails, the folder is kept. Report why (often an editor or a dev server
     holding files open) and give the command to retry after closing them.
   - Never remove the folder any other way, and never use `--force`.
5. Never push.

## 13. Report

Fill `${CLAUDE_SKILL_DIR}/report-template.md`. Save it as `$RUN_DIR/report.md` and
print it in full.

"How it works" explains the solution in plain words for someone who will maintain
the code: the flow, the key decisions and why, and where the code lives. Do not paste
the diff. Copied local files appear by name only.

## 14. Stop

At any step that stops:

1. Write the report with the status `stopped at <step>: <reason>`. Save it and print it.
2. Keep the folder and the branch. Do not commit and do not clean up.
3. Stay in the task folder, unless the stop happened after step 12.2.
4. Tell the user how to continue: describe the change or decision in this session and
   reply "continue". The task resumes at the step that stopped.

After the terminal is closed, `claude --resume` reopens this session.
`$RUN_DIR/state.md` records where the task stood.

## Guardrails

- Edit only the task folder. The main folder changes only through the fast-forward
  merge.
- Never push, force push, amend, or reset. Commit, rebase, merge, and remove only
  through `worktree.sh`. Delete a branch or a folder only through `worktree.sh remove`,
  after a merge.
- One commit per invocation. A second commit needs the user's explicit OK when it is
  needed, even with `--auto`.
- Never weaken tests, types, validation, or lint rules to pass a gate.
- Reviewers are read-only. The fingerprint before and after each Claude review proves
  it, and codex-loop checks its own runs.
- Never print secrets. Copied local files appear by name only.
- When the repository's `AGENTS.md` conflicts with a step here, follow `AGENTS.md`,
  stop at that step, and say so.

## Examples

```text
/worktree-task:start "Add CSV export to the contacts table"
/worktree-task:start "F13" --from docs/code-review.md
/worktree-task:start "Fix the date helper for invalid dates" --base main --auto
/worktree-task:start "Rename the settings page" --codex off --tests-first off
```
