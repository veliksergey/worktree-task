# Changelog

Changes to the worktree-task plugin, newest first. Claude Code updates an installed
copy only when the version in `plugins/worktree-task/.claude-plugin/plugin.json`
changes. Documentation changes that need no update are listed at the end.

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
