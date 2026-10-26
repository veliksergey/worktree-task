# worktree-task for Claude Code

Give Claude Code a task and it works on it in a separate folder and branch beside your
project. It writes tests first when they help, reviews its own change with a
fresh-context reviewer, adds a Codex review when you have it, and after your OK commits
the change and fast-forwards your base branch. The report lands in the terminal you
started from.

Because every task has its own folder, branch, and Claude session, you can run several
at once: one terminal per task, all opened in the same project.

```text
/worktree-task:start "Add CSV export to the contacts table"
```

## How it works

```text
main folder (your project, on dev)            ../<repo>-<slug> (task folder, on task/<slug>)
──────────────────────────────────            ──────────────────────────────────────────────
/worktree-task:start "<task>"
  read the request, ask open questions
  create folder + branch from dev   ───────▶  copy the files .worktreeinclude lists, install dependencies
                                              baseline checks
                                              task file: request, acceptance criteria
                                              tests first: interface → tests → must fail → lock
                                              implement until the checks pass
                                              Claude review (fresh context, read-only), up to 3 rounds
                                              Codex review (if installed), up to 3 rounds
                                              merge gate → your OK → one commit
                                              rebase onto the latest dev
  fast-forward dev  ◀───────────────────────  (re-check and re-review if dev changed the same files)
  remove folder + branch, print the report
```

1. **Request.** Claude reads your task, or one item of a file with `--from`, and asks
   about anything that would change the result before it creates anything.
2. **Folder and branch.** A git worktree at `../<repo>-<slug>` on the new branch
   `task/<slug>`, started from your base branch. Gitignored local files are copied
   in only when a `.worktreeinclude` lists them, and dependencies are installed.
3. **Task file.** Your words verbatim, numbered acceptance criteria, out of scope,
   decisions, and a handoff. The reviewers judge the change against it.
4. **Tests first,** when they help (see below).
5. **Implementation,** until the repository's documented checks pass.
6. **Claude review.** A separate reviewer agent with no memory of writing the code and
   no edit tools reviews the change. Its rubric covers whether the code does what was
   asked, security, logic bugs, error handling, performance, observability, tests,
   contracts and data integrity, and maintainability. The working session verifies each
   finding, fixes P0-P2 with a regression test, and lists P3 for you.
7. **Codex review,** when the [codex-review-loop](https://github.com/veliksergey/codex-review-loop)
   plugin is installed and the Codex CLI is signed in. It runs that plugin's loop with
   extra focus on performance and observability.
8. **Merge gate and checkpoint.** If the checks pass and the last round of each review
   reported no P0-P2 finding, Claude shows you the report and the diff summary and
   waits for **ok**.
9. **Commit, rebase, merge, clean up.** One commit in your repository's message style,
   a rebase onto the latest base, a fast-forward merge into the base in your main
   folder, then the task folder and branch are removed. **Nothing is ever pushed.**
10. **Report.** What was asked, each criterion's result, how the solution works, files
    and tests, checks, review rounds, items for your decision, risks, how to try it,
    and the commit.

## What you need

| Requirement | Notes |
|---|---|
| Claude Code | https://code.claude.com/docs/en/setup |
| git 2.31 or newer | The project must be a git repository with at least one commit. |
| bash | Built in on macOS and Linux. On Windows, Git for Windows provides it, and Claude Code uses it for its Bash tool. |
| Optional: Codex review | The [codex-review-loop](https://github.com/veliksergey/codex-review-loop) plugin, the Codex CLI, and `codex login`. Without them, the Claude review runs alone. |

## Install

```text
/plugin marketplace add veliksergey/worktree-task
/plugin install worktree-task@worktree-task
/reload-plugins
```

Update later with `claude plugin update worktree-task@worktree-task`, then restart
Claude Code.

## Use

Open a terminal in your project's main folder, start Claude Code, and run:

```text
/worktree-task:start "<task>" [options]
```

Claude Code asks you to confirm when the session moves into the task folder, because
the move also loads that folder's project settings. Approve it: the Codex review works
only from inside that folder.

In a non-interactive run (`claude -p`), nobody can approve the move, and permission
rules such as `--allowedTools EnterWorktree` do not cover it. The task then stops before
writing any code, so run tasks in interactive terminals.

| Option | Meaning | Default |
|---|---|---|
| `--from <file>` | Read the task from a file in the main folder. With a task text such as `"F13"`, only that item of the file is the task. | none |
| `--base <branch>` | Branch to start from and merge into. | the main folder's current branch |
| `--name <slug>` | Folder and branch suffix (`a-z`, `0-9`, `-`, up to 40 characters). | derived from the task |
| `--codex auto\|on\|off` | Codex review after the Claude review. `on` stops if Codex is unavailable. | `auto` |
| `--tests-first auto\|on\|off` | Write and lock tests before the implementation. | `auto` |
| `--rounds N` | Maximum rounds per review stage. | 3 |
| `--auto` | Commit and merge without waiting for your OK, when the merge gate passes. | off |

Examples:

```text
/worktree-task:start "Add CSV export to the contacts table"
/worktree-task:start "F13" --from docs/code-review.md
/worktree-task:start "Fix the date helper for invalid dates" --base main --auto
/worktree-task:start "Rename the settings page" --codex off --tests-first off
```

### Several tasks at once

Open one terminal per task, each in the project's main folder, and start one task in
each. Each task gets its own folder, branch, Claude session, and Codex session. Each
terminal stays with its task, so you can answer its questions there. The tasks merge one
after another. When one finds that another has merged first, it rebases onto the new
base, reruns the checks, and reviews again if both changed the same files.

Two or three tasks at a time is a practical limit. You read every report, and each task
uses your Claude and Codex allowances.

### Tests first

With `--tests-first auto`, tests come first for bug fixes and for tasks whose
acceptance criteria describe behavior a test can check. Documentation, configuration,
UI styling, and exploratory work skip it.

1. Claude writes only the interface: types, signatures, and stubs that throw
   "not implemented".
2. A separate `test-author` agent writes tests from the task file and that interface,
   at least one per criterion plus edge cases. There is no implementation yet for the
   tests to copy, so they check what you asked for.
3. The new tests must fail for the right reason. A bug fix's test must reproduce the
   bug.
4. The tests are locked by hash. Changing a locked test later needs a recorded reason,
   and both reviewers check every such change.

Tests written after the code tend to confirm what the code does, bugs included. Agents
also sometimes edit a failing test instead of fixing the code. Writing the tests first
and locking them guards against both.

### Local files the task folder needs

A worktree contains only tracked files, so the task folder starts without your
gitignored local files, such as `.env.local`. Copying them is opt-in: nothing is copied
unless a `.worktreeinclude` file in the project root lists them, one pattern per line in
`.gitignore` syntax. Only files that match it and that git ignores are copied. This is
the same convention Claude Code uses for its own worktrees.

```text
.env.local
```

Opt in only when the project's documented checks need those values, for example a
build that validates its environment or tests that need a database. A copied file is
readable by everything that works in the task folder: the implementing session, the
Claude reviewer and test author, and Codex when it reviews. Their instructions say
never to print such contents, but the values can still reach a reviewer's transcript.
Lint, typecheck, and most unit tests run without them.

The report lists copied files by name, never their contents. A file the task folder's
own `.gitignore` does not cover is not copied, because it would be committed. That
happens with an older `--base`, or a `.gitignore` change you have not committed yet. The
commit step also refuses if a copied file has stopped being ignored.

### Where things are

| What | Where |
|---|---|
| Task folder | `../<repo>-<slug>`, removed after the merge |
| Task branch | `task/<slug>`, deleted after the merge |
| Report, state, review rounds | `~/.claude/worktree-tasks/<repo>-<slug>/<run>/`, one folder per run, named by its start time |
| Task file | `~/.claude/codex-reviews/<repo>-<slug>/task.md` with Codex, where codex-loop reads it; otherwise in the folder above |

## When a task stops

A task stops instead of committing when:
- a check fails;
- a review stage ends with an open P0-P2 finding;
- the Codex review fails, for example at a usage limit;
- a reviewer changed files;
- the rebase conflicts;
- the merge is refused.

The folder and branch are kept. The report says why the task stopped. Describe the
change or decision in the same session and reply **continue**. If the terminal was
closed, `claude --resume` reopens the session, and `state.md` in the newest
`~/.claude/worktree-tasks/<repo>-<slug>/<run>/` folder records where the task stood.

When the merge gate stopped the task, the report says which reply fits:
- **accept**: Claude rejected every open finding with evidence, and you agree. Your
  reply is recorded in the task file. Nothing accepts a rejection for you, not even
  `--auto`.
- **continue**: runs one more review round when the last round's fixes have not been
  reviewed yet, or runs the Codex review again after it failed. To skip Codex instead,
  say so.

### Removing a task folder by hand

To abandon a task, or when the cleanup refused to remove a folder, remove it yourself.
Run these commands from the main folder, in bash (Git Bash on Windows). Unlink every link
first: on Windows, `git worktree remove --force` follows junctions, such as those in a
pnpm `node_modules`, and deletes the files they point to. The `&&` stops at the first
step that fails, so nothing is removed while a link remains.

```bash
find "../<repo>-<slug>" -type l -exec rm -f -- {} + &&
  git worktree remove --force "../<repo>-<slug>" &&
  git branch -D "task/<slug>"   # only to discard the task's commits too
```

`--force` discards the folder's uncommitted work, and `-D` discards the branch's commits.

## Safety

- **Nothing is pushed.** The merge is fast-forward only, into the base branch, in your
  main folder. It waits for your OK unless you pass `--auto`.
- **One commit per task.** If a check or review after the commit needs a fix, for
  example after a hook reformatted the commit or after the rebase, the task stops and
  asks before making a second commit, even with `--auto`.
- **The commit is what was reviewed.** If a commit hook changes the content, for
  example by reformatting it, the change goes through the checks and reviews again
  before the merge.
- **Your work in the main folder is safe.** The task never edits the main folder. The
  merge refuses, and the task stops and tells you, when the merge would:
  - overwrite your uncommitted changes;
  - overwrite a gitignored local file;
  - stash your work under `merge.autoStash`.
- **Local files are copied only when you list them.** Without a `.worktreeinclude`,
  no gitignored file leaves your main folder, so no secret reaches a reviewer. A
  copied file is never committed: the commit step refuses if it has stopped being
  ignored.
- **Read-only reviewers.** The Claude reviewer has no edit tools, and a fingerprint of
  the folder before and after each review proves it changed nothing. codex-review-loop
  runs Codex in a read-only sandbox.
- **Safe cleanup on Windows.** `git worktree remove` follows junctions on Windows, the
  links package managers such as pnpm create in `node_modules`, and deletes the files
  they point to. The cleanup unlinks every link first, and the test suite checks that a
  file outside the folder survives. Tracked symbolic links, such as `CLAUDE.md` linked
  to `AGENTS.md`, stay: git made them and deletes them without following them.
- **Rejected findings need you.** A finding Claude rejected with evidence still blocks
  the merge until you reply **accept**.
- **Only you can start it.** The skill sets `disable-model-invocation`, so Claude never
  starts it on its own.

### If your global rules forbid commits

If your `CLAUDE.md` or `AGENTS.md` says never to commit or merge without explicit
permission, your OK at the checkpoint is that permission. Using `--auto` skips the
checkpoint. If Claude then still stops to ask, add this line to `~/.claude/CLAUDE.md`:

```text
- Invoking /worktree-task:start authorizes one commit on its task branch and a fast-forward merge into the base branch; never a push.
```

## Limits

- A terminal is busy until its task finishes.
- The main folder must be on the base branch when the task merges.
- An editor or dev server that holds files open in the task folder can block the
  cleanup. The task folder is then kept, and the report says how to remove it.
- Each task installs its own dependencies. With pnpm this is fast, because packages are
  linked from its shared store.
- Developed on Windows 11 with Git for Windows. The git steps are tested in GitHub
  Actions on every push: on Ubuntu, on macOS under its built-in bash 3.2, and on
  Windows under Git for Windows. A whole task, with the Claude session and the
  reviewers, has so far been run only on Windows.

## License

MIT
