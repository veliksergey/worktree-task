# Changelog

Changes to the worktree-task plugin, newest first. Claude Code updates an installed
copy only when the version in `plugins/worktree-task/.claude-plugin/plugin.json`
changes. Documentation changes that need no update are listed at the end.

## 0.3.0 — 2026-10-22

- **Copying local files is opt-in.** The task folder receives gitignored files such as
  `.env.local` only when a `.worktreeinclude` in the project root lists them. The old
  fallback that copied every root `.env*` file is gone: a copied file is readable by
  the reviewers, Codex included, so you decide per repository. `copy-local` prints
  `INCLUDE=none` or `INCLUDE=.worktreeinclude` first. Projects whose checks need the
  values add one line, for example `.env.local`; the README's "Local files the task
  folder needs" explains the trade-off.
- **Second commit after a hook change:** when a commit hook changed the content and the
  review after it needs a code change, the task now stops and asks for the second
  commit, as it already did after the rebase. Before, it fixed on the spot, and the
  rebase then refused the uncommitted fix.
- **Rebase:** a failed sort or comparison of the changed-file lists now exits 5 before
  the rebase, instead of reading as "no overlap" and skipping the review of files both
  sides changed.

## 0.2.0 — 2026-10-21

- **Accepting rejected findings:** when the merge gate fails only because Claude
  rejected the last round's findings with evidence, the stop lists them. Reply
  **accept** to let the gate pass; your reply is recorded in the task file. `--auto`
  never accepts. **continue** runs one more round when the last fixes were not
  reviewed, or runs a failed Codex review again.
- **Codex verdict:** taken only from the codex-loop run the task started, never from an
  earlier run's files. A Codex review that stopped on an error is not clean. You can
  skip it then by saying so, and your words are recorded.
- **Cleanup:**
  - tracked symbolic links, such as `CLAUDE.md` linked to `AGENTS.md`, no longer block
    it on macOS, Linux, or Windows with `core.symlinks=true`. They stay for git, which
    deletes them without following them;
  - it lists tracked files once and unlinks in batches, instead of two processes per
    link, which took minutes with thousands of package-manager links;
  - a failed unlink now exits 5 before anything is removed;
  - a tracked link marked assume-unchanged or skip-worktree is refused, because git
    status cannot see a junction swapped in under such a mark;
  - a tracked link spelled differently on disk, for example after a case-only rename,
    is refused before anything is unlinked, instead of failing halfway with exit 5;
  - its refusals say to unlink every link before you remove a folder yourself. The
    README's new "Removing a task folder by hand" gives the commands.
- **Merge:** a base that another task moved during the merge is now "not a
  fast-forward" (exit 3), which the task retries, instead of exit 5. The task also
  retries once when git reports `index.lock`.
- **Locked tests:** `hash` prints `HASH=missing` for a deleted file instead of failing,
  and a deleted locked test counts as a changed one.
- **Run folders:** each run has its own folder,
  `~/.claude/worktree-tasks/<repo>-<slug>/<run>/`. With Codex, a task stops before it
  creates anything if a repository with the same folder name runs a task of that name.
- **Resuming:** the task confirms it is in the right folder before it continues.
- **Rebase:** dependencies are reinstalled when the base changed a lockfile or a
  dependency manifest.
- **File names:** `copy-local` and `commit` read them literally. A local `.env[x]` no
  longer matches a tracked `.envx`, which made `copy-local` skip it and `commit` refuse.
- **Exit codes:** any unexpected failure exits 5 with a message, never another code.
- **Plugin:** a homepage, a repository link, and an icon.

## 0.1.0 — 2026-10-21

- First version. The `/worktree-task:start` skill takes one task through these steps:
  - its own worktree folder and branch;
  - tests first when they help, written by a separate agent and locked;
  - implementation;
  - a fresh-context Claude review, then a Codex review when codex-review-loop is
    installed;
  - after your OK, one commit, a rebase, and a fast-forward merge into the base branch;
  - cleanup and a report in the terminal.
- `worktree.sh` performs every git step and is covered by `tests/worktree.test.sh`.
  - **Junctions:** on Windows, cleanup unlinks junctions before removing a folder,
    because `git worktree remove` would follow them and delete the files they point to.
  - **Long paths:** every git call allows long paths, because a rebase failed under a
    195-character folder path on Windows.
  - **Exit codes:** a rebase reports a conflict (exit 4, with the conflicting files) only
    when there is one. Any other failure is exit 5. So is an abort that leaves rebase
    state behind.
  - **Merge:** it never overwrites gitignored local files in the main folder and never
    autostashes uncommitted work.
  - **Cleanup:** it stops before unlinking or removing anything if the scan for links
    fails.
  - **Commits:** they go through `worktree.sh commit`, which reports when a hook changed
    the committed content.
  - **Fingerprint:** it includes the HEAD commit and branch, so a reviewer that moves HEAD
    is caught.
  - **Copying local files:** never writes through a link in the task folder, and copies
    nothing if the file listing fails. A local file the task folder would not ignore is
    not copied (`NOT_IGNORED`). `commit` refuses when a copied file has stopped being
    ignored, so a secret can't end up in a commit.
  - **Create:** refuses a dangling link at the folder path, and creates no branch.
  - **Rebase:** rebases onto the base commit it checked, even if another task merges
    meanwhile, and never moves other branches (`rebase.updateRefs`).
  - **Branches and cleanup:** task branches never inherit an upstream. Cleanup refuses,
    before removing anything, a branch with an upstream, a folder with populated
    submodules, or a folder git cannot read.
  - **Branch names:** always resolved as branches, so a tag with the same name is
    ignored, including for the branch checked out in the main folder.
  - **Fingerprint:** records untracked links by their destination and never follows
    them, including:
    - links to empty folders;
    - links inside new untracked folders;
    - a junction that replaces a tracked folder;
    - names with spaces, which can't make two trees look alike.

    Links in ignored folders stay uncovered, unless a `!` rule un-ignores them. It
    ignores external diff and textconv drivers from your git config, so a real edit
    is always seen, and it includes each untracked file's executable bit. This
    matches codex-review-loop 0.2.4.
  - **Overlap check:** a failed listing stops the rebase.
  - **Overlap check:** counts a file the base renamed and the task edited.
  - **Merge:** is a real fast-forward even under `branch.<base>.mergeOptions=--squash`,
    and checks that the base actually moved.
- **Locked tests:** their status is recomputed before every review round. A locked test
  changed during the Codex review gets one more Claude review.
- **Rebase failures:** every failed rebase stops the task before the merge.
- **Review gate:** it applies again after every post-rebase or hook change. A second
  commit always needs your explicit OK.
- **Folder move:** the task stops if the session cannot move into the task folder.

## Documentation only

- 2026-10-26: the README no longer says macOS and Linux are untested. The shell tests
  now run in GitHub Actions on every push, on Ubuntu, on macOS under its built-in
  bash 3.2, and on Windows under Git Bash, and all three pass. AGENTS.md lists the
  workflow among the checks. Nothing under `plugins/` changed.
