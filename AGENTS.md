# AGENTS.md

Rules for AI coding agents and people changing this repository.

## What this repository is

A Claude Code plugin, published from this repository as its own marketplace. The
plugin runs one task in its own git worktree folder and branch, reviews it, and after
the user's OK commits it and fast-forwards the base branch. Users install it with
`/plugin marketplace add veliksergey/worktree-task`.

| Path | Contents |
|---|---|
| `.claude-plugin/marketplace.json` | Marketplace catalog with one entry, `worktree-task`. |
| `plugins/worktree-task/.claude-plugin/plugin.json` | Plugin manifest, including `version`. |
| `plugins/worktree-task/skills/start/` | The `start` skill, its task and report templates, and `worktree.sh`, which performs every git step. |
| `plugins/worktree-task/agents/` | The `reviewer` (read-only) and `test-author` agents. |
| `tests/` | Shell tests. Not shipped with the plugin. |
| `docs/reviews/decisions.md` | Rejected review findings and their evidence. |

## Commands

There is no build or lint. These are the checks:

| Check | Command | Passes when |
|---|---|---|
| Marketplace manifest | `claude plugin validate --strict .` | Exit 0 |
| Plugin manifest, skill, agents | `claude plugin validate --strict plugins/worktree-task` | Exit 0 |
| Plugin loads | `claude --plugin-dir ./plugins/worktree-task plugin details worktree-task` | Lists the `start` skill and the `reviewer` and `test-author` agents |
| Git steps | `bash tests/worktree.test.sh` | Exit 0, prints `all passed` |

## Release rule

Users receive a change only when the plugin's version changes. Every change under
`plugins/` raises `version` in `plugins/worktree-task/.claude-plugin/plugin.json`:
patch for wording and fixes, minor for new behavior. Set the version only there, never
also in `marketplace.json`. Add an entry for the new version at the top of
`CHANGELOG.md` in the same commit. List documentation-only changes under
"Documentation only".

## Invariants

- **No personal or company details.** No names of people or companies, email
  addresses, internal host or machine names, ticket numbers, private repository names,
  or absolute paths from a real computer. Examples use placeholders such as `<repo>`
  and `src/auth`. The one exception is the repository owner's GitHub account,
  `veliksergey`, in install commands and links to its repositories.
- **Portable shell.** `worktree.sh` and the tests must work in bash 3.2 on macOS, on
  Linux, and in Git Bash on Windows. Prefer git built-ins. No GNU-only flags.
- **Every git step goes through `worktree.sh`,** and each of its commands has tests.
  The skill orchestrates; it does not run `git worktree`, `git commit`, `git rebase`,
  `git merge`, or `git branch -d` itself.
- **Bundled files by variable.** The skill references its own files through
  `${CLAUDE_SKILL_DIR}`, never through an install path or `..`.
- **Safety guarantees stay:**
  - the skill is user-invoked only (`disable-model-invocation: true`);
  - nothing pushes;
  - the merge is fast-forward only and waits for the user's OK unless `--auto` is
    given;
  - the merge never overwrites ignored files, never autostashes, never squashes, and
    checks that the base moved to the task commit;
  - branch arguments are resolved as `refs/heads/<name>`, never as tags;
  - a git command that fails to read state is never taken as "clean" or "untracked";
  - one commit per invocation, and a second commit only with the user's explicit OK;
  - a commit whose content a hook changed is checked and reviewed again before it is
    merged;
  - the main folder is edited only by that merge;
  - reviewers are read-only and fingerprinted;
  - `remove` unlinks every untracked link before deleting. Tracked symbolic links stay,
    because git deletes them without following them. It refuses unmerged branches,
    dirty folders, the main folder, branches with an upstream, populated submodules,
    links that stand where git tracks files, tracked links marked assume-unchanged or
    skip-worktree, and tracked links spelled differently on disk. It stops if the link
    scan or the unlinking fails;
  - a review finding that was rejected passes the merge gate only with the user's
    explicit acceptance, never under `--auto`. A Codex stage that failed is never
    clean; the gate skips it only on the user's explicit, recorded word;
  - `copy-local` never writes through a link, and never copies a file the task folder
    would not ignore. `commit` refuses while a copied local file is unignored or
    tracked;
  - `rebase` pins the base commit and never moves other branches;
  - logs live outside the repository.
- **Compatible with codex-review-loop.** The task file keeps that plugin's sections,
  and it lives at `~/.claude/codex-reviews/<folder name>/task.md` when Codex runs.
  Neither plugin requires the other.
- **Facts are sourced.** A claim about Claude Code, git, or Codex behavior comes from
  official documentation or from an observed run. Mark anything else as unverified.

## Branches

`main` is the only branch so far. No branch policy yet.

## Review decisions

Rejected review findings and their evidence: `docs/reviews/decisions.md`.
