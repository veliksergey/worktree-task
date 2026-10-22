#!/usr/bin/env bash
# Git steps for the worktree-task skill. Each command prints KEY=value lines on stdout
# and explanations on stderr.
# Exit codes: 0 done, 2 usage error, 3 refused (nothing changed),
# 4 conflict (rolled back, nothing changed), 5 git error or other unexpected failure
# (state may need a look).
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: worktree.sh preflight
       worktree.sh create <slug> [<base-branch>]
       worktree.sh copy-local <task-folder>
       worktree.sh commit <message-file>
       worktree.sh rebase <base-branch>
       worktree.sh merge <task-branch> <base-branch>
       worktree.sh remove <task-folder> <task-branch> <base-branch>
       worktree.sh fingerprint
       worktree.sh hash <file>...
commit, rebase, fingerprint and hash run inside the task folder; the others in the
main folder.
EOF
  intended=yes
  exit 2
}

die() {
  local code="$1"
  shift
  printf 'worktree.sh: %s\n' "$*" >&2
  intended=yes
  exit "$code"
}

# Git for Windows fails on paths over 260 characters unless core.longpaths is on, even
# when it only checks whether a revision range is a file name. Other platforms ignore it.
git() { command git -c core.longpaths=true "$@"; }

# One temporary file per run, removed on exit. A failure that set -e stops on exits
# with that command's own code, which could read as 2, 3, or 4, so every exit that did
# not come through die or usage is reported as 5, the code for "take a look".
scratch="" intended=""
on_exit() {
  local rc=$?
  [ -z "$scratch" ] || rm -f -- "$scratch" || true
  if [ "$rc" -ne 0 ] && [ "$intended" != yes ]; then
    printf 'worktree.sh: unexpected failure (exit %s); state may need a look\n' "$rc" >&2
    rc=5
  fi
  exit "$rc"
}
trap on_exit EXIT
new_scratch() { scratch="$(mktemp)" || die 5 "cannot create a temporary file; nothing changed"; }

git_dir() { git -C "$1" rev-parse --path-format=absolute --git-dir; }
rebase_in_progress() {
  [ -e "$(git -C "$1" rev-parse --path-format=absolute --git-path rebase-merge)" ] \
    || [ -e "$(git -C "$1" rev-parse --path-format=absolute --git-path rebase-apply)" ]
}
common_dir() { git -C "$1" rev-parse --path-format=absolute --git-common-dir; }
# The full ref, not --short: with a tag of the same name, --short returns "heads/<name>".
branch_of() {
  local ref
  ref="$(git -C "$1" symbolic-ref --quiet HEAD)" || return 0
  printf '%s\n' "${ref#refs/heads/}"
}
has_branch() { git -C "$top" show-ref --verify --quiet "refs/heads/$1"; }
# Branch arguments are always resolved as refs/heads/<name>: a tag with the same name
# would otherwise win.
tip() { git -C "$top" rev-parse --verify "refs/heads/$1^{commit}"; }
# Prints $1 as lines, or nothing when it is empty: printf alone would print one empty line.
lines() { [ -z "$1" ] || printf '%s\n' "$1"; }
# True only when git can read the folder and it has no changes or untracked files.
is_clean() {
  local st
  st="$(git -C "$1" status --porcelain --untracked-files=all)" || return 1
  [ -z "$st" ]
}

# Sets $top to the main folder; refuses inside a linked worktree.
require_main() {
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || die 3 "not inside a git repository"
  if [ "$(git_dir "$top")" != "$(common_dir "$top")" ]; then
    die 3 "this is a linked worktree; run this from the repository's main folder"
  fi
}

# Sets $task_top to the top of folder $1, which must be a linked worktree of $top.
require_task_folder() {
  [ -d "$1" ] || die 3 "no such folder: $1"
  task_top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || die 3 "not a git worktree: $1"
  [ -z "$(git -C "$1" rev-parse --show-prefix)" ] || die 3 "not the top of a worktree: $1"
  [ "$(common_dir "$1")" = "$(common_dir "$top")" ] || die 3 "$1 belongs to another repository"
  [ "$(git_dir "$1")" != "$(common_dir "$1")" ] || die 3 "$1 is the main folder, not a task folder"
}

cmd_preflight() {
  [ $# -eq 0 ] || usage
  require_main
  local head dirty=no
  head="$(git -C "$top" rev-parse --verify --quiet HEAD)" || die 3 "the repository has no commits yet"
  local st
  st="$(git -C "$top" status --porcelain --untracked-files=no)" || die 5 "git status failed in $top"
  if [ -n "$st" ]; then dirty=yes; fi
  printf 'REPO_ROOT=%s\nREPO=%s\nBRANCH=%s\nHEAD_SHA=%s\nDIRTY=%s\n' \
    "$top" "$(basename "$top")" "$(branch_of "$top")" "$head" "$dirty"
}

cmd_create() {
  { [ $# -ge 1 ] && [ $# -le 2 ]; } || usage
  local slug="$1" base base_sha branch repo path
  case "$slug" in
    '' | -* | *- | *[!a-z0-9-]*) die 2 "slug must be lowercase letters, digits and inner hyphens: '$slug'" ;;
  esac
  [ "${#slug}" -le 40 ] || die 2 "slug is longer than 40 characters: '$slug'"
  require_main
  base="${2:-$(branch_of "$top")}"
  [ -n "$base" ] || die 3 "HEAD is detached; pass the base branch"
  has_branch "$base" || die 3 "base branch not found: $base"
  branch="task/$slug"
  if has_branch "$branch"; then die 3 "branch already exists: $branch"; fi
  repo="$(basename "$top")"
  path="$(dirname "$top")/$repo-$slug"
  # -L too: a dangling link fails -e, and git creates the branch before rejecting the path.
  if [ -e "$path" ] || [ -L "$path" ]; then die 3 "folder already exists: $path"; fi
  # --no-track: with branch.autoSetupMerge=inherit the branch would take the base's
  # upstream, and git branch -d would later check that instead of the local base.
  base_sha="$(tip "$base")" || die 5 "cannot resolve branch $base"
  git -C "$top" worktree add --quiet --no-track -b "$branch" "$path" "$base_sha" >&2 \
    || die 5 "git worktree add failed"
  printf 'WORKTREE=%s\nBRANCH=%s\nBASE=%s\nBASE_SHA=%s\nRUN_NAME=%s\n' \
    "$path" "$branch" "$base" "$base_sha" "$repo-$slug"
}

# Copies gitignored local files, such as .env.local, from the main folder: only the
# files that .worktreeinclude in the main folder names and that git ignores, so a
# tracked file is never duplicated. Without .worktreeinclude nothing is copied: a copy
# is readable by the reviewers, so the user lists what a task needs.
cmd_copy_local() {
  [ $# -eq 1 ] || usage
  require_main
  require_task_folder "$1"
  local rel parent count=0 copied_list tracked
  # Remembered per task folder, so that commit can refuse if a copied file stops being ignored.
  copied_list="$(git -C "$task_top" rev-parse --path-format=absolute --git-path worktree-task-copied)" \
    || die 5 "cannot locate the task folder's git directory; nothing copied"
  if [ ! -f "$top/.worktreeinclude" ]; then
    printf 'INCLUDE=none\nCOPIED_COUNT=0\n'
    return 0
  fi
  printf 'INCLUDE=.worktreeinclude\n'
  # The list is complete before anything is copied, so a failed listing copies nothing.
  new_scratch
  git -C "$top" ls-files -z --others --ignored --exclude-from="$top/.worktreeinclude" > "$scratch" \
    || die 5 "could not list the files .worktreeinclude names; nothing copied"
  while IFS= read -r -d '' rel; do
    # Read as a pattern, a name such as .env[x] would match a tracked .envx. With
    # --no-index, check-ignore takes the name as it is; ls-files says if git tracks it.
    git -C "$top" check-ignore -q --no-index -- "$rel" || continue
    tracked="$(git --literal-pathspecs -C "$top" ls-files -- "$rel")" \
      || die 5 "git ls-files failed for $rel; copying stopped"
    [ -z "$tracked" ] || continue
    { [ -f "$top/$rel" ] && [ ! -L "$top/$rel" ]; } || continue
    if [ -e "$task_top/$rel" ] || [ -L "$task_top/$rel" ]; then
      printf 'SKIPPED=%s\n' "$rel"
      continue
    fi
    # A link among the destination's parent folders would send the copy outside the task folder.
    parent="$(dirname "$rel")"
    while [ "$parent" != . ]; do
      if [ -L "$task_top/$parent" ]; then
        printf 'REFUSED=%s\n' "$rel"
        continue 2
      fi
      parent="$(dirname "$parent")"
    done
    # The task folder's own ignore rules can differ (another base, an uncommitted
    # .gitignore change): a local file it does not ignore would be committed.
    if ! git -C "$task_top" check-ignore -q --no-index -- "$rel"; then
      printf 'NOT_IGNORED=%s\n' "$rel"
      continue
    fi
    mkdir -p "$(dirname "$task_top/$rel")"
    cp -p -- "$top/$rel" "$task_top/$rel"
    # NUL-terminated: a file name can contain a newline.
    printf '%s\0' "$rel" >> "$copied_list"
    printf 'COPIED=%s\n' "$rel"
    count=$((count + 1))
  done < "$scratch"
  printf 'COPIED_COUNT=%s\n' "$count"
}

cmd_rebase() {
  [ $# -eq 1 ] || usage
  local base="$1" here branch mb base_sha before overlap base_files task_files conflicts abort_err=""
  here="$(git rev-parse --show-toplevel 2>/dev/null)" || die 3 "not inside a git repository"
  top="$here"
  if [ "$(git_dir "$here")" = "$(common_dir "$here")" ]; then
    die 3 "run rebase inside the task folder, not the main folder"
  fi
  has_branch "$base" || die 3 "base branch not found: $base"
  branch="$(branch_of "$here")"
  [ -n "$branch" ] || die 3 "the task folder is not on a branch"
  is_clean "$here" || die 3 "the task folder has uncommitted changes, or git cannot read it; nothing changed"
  # Resolve the base once: another task may advance the branch while this runs, and the
  # overlap check and the rebase must use the same commit.
  base_sha="$(tip "$base")" || die 5 "cannot resolve branch $base"
  mb="$(git -C "$here" merge-base "$base_sha" HEAD)" || die 5 "no merge base with $base"
  if [ "$mb" = "$base_sha" ]; then
    printf 'BASE_MOVED=no\nBASE_SHA=%s\n' "$base_sha"
    return 0
  fi
  # --no-renames lists both ends of a rename, so a file the base renamed and the task
  # edited still counts as changed on both sides.
  # Both lists must succeed: a failed listing would look like "no overlap".
  base_files="$(git -C "$here" diff --no-renames --name-only "$mb" "$base_sha")" \
    || die 5 "could not list the files changed on $base; nothing changed"
  task_files="$(git -C "$here" diff --no-renames --name-only "$mb" HEAD)" \
    || die 5 "could not list the files changed on the task branch; nothing changed"
  # Sorting and comparing are checked one by one: a process substitution's failure is
  # lost, and a lost failure would look like "no overlap" too.
  base_files="$(lines "$base_files" | LC_ALL=C sort)" \
    || die 5 "could not sort the files changed on $base; nothing changed"
  task_files="$(lines "$task_files" | LC_ALL=C sort)" \
    || die 5 "could not sort the files changed on the task branch; nothing changed"
  overlap="$(LC_ALL=C comm -12 <(lines "$base_files") <(lines "$task_files"))" \
    || die 5 "could not compare the two file lists; nothing changed"
  before="$(git -C "$here" rev-parse HEAD)"
  # rebase.updateRefs would also move other branches that point at the task's commits.
  if ! GIT_EDITOR=true git -C "$here" -c rebase.updateRefs=false rebase --quiet "$base_sha" >&2; then
    # Unmerged paths exist only when the rebase stopped on a conflict.
    conflicts="$(git -C "$here" diff --name-only --diff-filter=U)"
    if rebase_in_progress "$here"; then
      abort_err="$(git -C "$here" rebase --abort 2>&1)" || true
    fi
    # Rolled back means: no rebase state, same branch and commit, and a clean tree.
    if rebase_in_progress "$here" || [ "$(git -C "$here" rev-parse HEAD)" != "$before" ] \
      || [ "$(branch_of "$here")" != "$branch" ] || ! is_clean "$here"; then
      if [ -n "$abort_err" ]; then printf '%s\n' "$abort_err" >&2; fi
      die 5 "the rebase failed and was not rolled back cleanly; in $here run 'git rebase --abort', then check 'git status'"
    fi
    if [ -n "$conflicts" ]; then
      printf '%s\n' "$conflicts" | sed 's/^/CONFLICT=/'
      die 4 "rebase onto $base conflicts; it was aborted and the branch is unchanged"
    fi
    die 5 "rebase onto $base failed without a conflict (see git's message above); the branch is unchanged"
  fi
  printf 'BASE_MOVED=yes\nBASE_SHA=%s\n' "$base_sha"
  if [ -n "$overlap" ]; then printf '%s\n' "$overlap" | sed 's/^/OVERLAP=/'; fi
}

cmd_merge() {
  [ $# -eq 2 ] || usage
  local branch="$1" base="$2" current before target now anc=0
  require_main
  has_branch "$branch" || die 3 "branch not found: $branch"
  current="$(branch_of "$top")"
  [ "$current" = "$base" ] || die 3 "the main folder is on '$current', not '$base'; switch it to $base and retry"
  target="$(tip "$branch")" || die 5 "cannot resolve branch $branch"
  # One reading of the base for the check and for judging a failed merge below.
  before="$(git -C "$top" rev-parse HEAD)"
  if ! git -C "$top" merge-base --is-ancestor "$before" "$target"; then
    die 3 "$branch is not a fast-forward of $base; rebase it first"
  fi
  # By default git overwrites ignored files, stashes the user's uncommitted work under
  # merge.autoStash, and squashes under branch.<base>.mergeOptions; these flags prevent all three.
  if ! git -C "$top" merge --ff-only --no-overwrite-ignore --no-autostash --no-squash --quiet "$target" >&2; then
    now="$(git -C "$top" rev-parse HEAD)" || die 5 "the merge failed and HEAD cannot be read; inspect the main folder"
    # Another task can merge between the check above and this merge.
    git -C "$top" merge-base --is-ancestor "$now" "$target" || anc=$?
    [ "$anc" -ne 1 ] || die 3 "$branch is not a fast-forward of $base, which another merge moved meanwhile; rebase it first"
    [ "$now" != "$before" ] || die 3 "git refused the merge (see above); nothing changed"
    die 5 "the merge failed after moving $base; inspect the main folder"
  fi
  [ "$(git -C "$top" rev-parse HEAD)" = "$target" ] \
    || die 5 "the merge exited 0 but $base is not at $branch; inspect the main folder (git status)"
  printf 'MERGED_SHA=%s\n' "$target"
}

cmd_remove() {
  [ $# -eq 3 ] || usage
  local branch="$2" base="$3" link links=() kept=() submodules entry tag mode path dir dir_link p
  local last_dir=// keep=// found=// tab=$'\t' count=0
  # git worktree remove --force and other git commands follow junctions on Windows.
  local by_hand="to remove it by hand, first unlink every link in it (README: Removing a task folder by hand)"
  require_main
  require_task_folder "$1"
  # git branch -d checks the merge against the main folder's HEAD, so HEAD must be the base.
  [ "$(branch_of "$top")" = "$base" ] || die 3 "the main folder is not on $base; nothing removed"
  [ "$(branch_of "$task_top")" = "$branch" ] || die 3 "$task_top is not on $branch; nothing removed"
  if ! git -C "$top" merge-base --is-ancestor "$(tip "$branch")" "$(tip "$base")"; then
    die 3 "$branch is not merged into $base; nothing removed"
  fi
  is_clean "$task_top" \
    || die 3 "$task_top has uncommitted or untracked files, or git cannot read it; nothing removed"
  # git branch -d checks a tracked upstream instead of the local base.
  if git -C "$top" config --get "branch.$branch.merge" >/dev/null; then
    die 3 "$branch tracks an upstream, so git branch -d would check that instead; nothing removed"
  fi
  # Files inside a submodule are not tracked by this repository, and git refuses to
  # remove a worktree with submodules.
  submodules="$(git -C "$task_top" submodule status --recursive)" \
    || die 5 "git submodule status failed in $task_top; nothing removed"
  if printf '%s\n' "$submodules" | grep -q '^[^-]'; then
    die 3 "$task_top has populated submodules; nothing removed; $by_hand"
  fi
  # Git for Windows follows junctions when it deletes a folder, which would delete the
  # files they point to, so every link is removed first without being followed. The scan
  # must finish before anything is unlinked or removed.
  new_scratch
  if ! (cd "$task_top" && find . -type l -print0) > "$scratch"; then
    die 5 "could not list the links in $task_top; nothing removed"
  fi
  while IFS= read -r -d '' link; do links+=("${link#./}"); done < "$scratch"
  if [ "${#links[@]}" -gt 0 ]; then
    # One index listing for all links: a lookup per link took minutes with the thousands
    # of links package managers create. A failed listing must not count as "untracked".
    # -v tags each entry: "H" is plain, while assume-unchanged (lower case) and
    # skip-worktree ("S") hide the file from git status.
    git -C "$task_top" ls-files -s -v -z > "$scratch" || die 5 "git ls-files failed in $task_top; nothing removed"
    while IFS= read -r -d '' entry; do
      tag="${entry%% *}" mode="${entry#* }" path="${entry#*"$tab"}"
      mode="${mode%% *}"
      case "$path" in */*) dir="${path%/*}" ;; *) dir="" ;; esac
      # The outermost link among the entry's folders, found once per folder.
      if [ "$dir" != "$last_dir" ]; then
        last_dir="$dir" p="$dir" dir_link=""
        while [ -n "$p" ]; do
          if [ -L "$task_top/$p" ]; then dir_link="$p"; fi
          case "$p" in */*) p="${p%/*}" ;; *) p="" ;; esac
        done
      fi
      [ -z "$dir_link" ] || die 3 "tracked files behind the link $dir_link in $task_top; nothing removed; $by_hand"
      if [ -L "$task_top/$path" ]; then
        # A symbolic link git checked out: git deletes it without following it, and
        # unlinking it would leave the folder dirty.
        [ "$mode" = 120000 ] || die 3 "the tracked file $path in $task_top is a link; nothing removed; $by_hand"
        # Only then has the clean check above seen it: a junction swapped in under such
        # a mark would be kept and followed.
        [ "$tag" = H ] || die 3 "the tracked link $path in $task_top is marked assume-unchanged or skip-worktree, so git status cannot vouch for it; nothing removed"
        keep="$keep$path//"
        kept+=("$path")
      fi
    done < "$scratch"
  fi
  # Every other link, for batched rm calls. No path contains "//", so a kept name cannot
  # match part of another.
  for link in ${links[@]+"${links[@]}"}; do
    case "$keep" in *"//$link//"*) found="$found$link//"; continue ;; esac
    printf './%s\0' "$link"
    count=$((count + 1))
  done > "$scratch"
  # find names each link as it is spelled on disk. A kept link it did not name differs
  # in case or Unicode form there, and would be unlinked under that other spelling.
  for path in ${kept[@]+"${kept[@]}"}; do
    case "$found" in
      *"//$path//"*) ;;
      *) die 3 "the tracked link $path in $task_top is spelled differently on disk; rename it back to $path, then retry; nothing removed" ;;
    esac
  done
  if [ "$count" -gt 0 ]; then
    (cd "$task_top" && xargs -0 rm -f --) < "$scratch" \
      || die 5 "could not unlink every link in $task_top; nothing removed"
  fi
  git -C "$top" worktree remove "$task_top" >&2 \
    || die 5 "git worktree remove failed after unlinking $count link(s); the folder is still at $task_top"
  git -C "$top" branch -d "$branch" >&2 || die 5 "the folder was removed but deleting $branch failed"
  printf 'REMOVED=%s\nUNLINKED=%s\nDELETED_BRANCH=%s\n' "$task_top" "$count" "$branch"
}

# Untracked-file helpers for cmd_fingerprint, the same as codex-review-loop's
# fingerprint.sh. They read the repository root from fp_root.

# fp_record <field>...: the hash of the NUL-terminated fields, so no file name can make
# two different trees produce the same records.
fp_record() { printf '%s\0' "$@" | git hash-object --stdin; }

# A link is recorded by its destination, never followed: hash-object would read the
# target, and git on Windows lists a junction's contents as if it were a folder.
# readlink's output is kept whole, trailing newlines included.
fp_link_record() {
  local t
  t="$(readlink -- "$fp_root/$1" && printf x)" || return 1
  fp_record L "$1" "${t%x}"
}

# fp_outer_link <path>: the outermost link among the path and its parent folders, if any.
fp_outer_link() {
  local p="$1" link=""
  while :; do
    if [ -L "$fp_root/$p" ]; then link="$p"; fi
    case "$p" in */*) p="${p%/*}" ;; *) break ;; esac
  done
  printf '%s' "$link"
}

# Untracked files. A file reached through a link stands for that link instead: git on
# Windows walks into a junction, even one that replaces a tracked folder.
fp_untracked_files() {
  local last=""
  git -C "$fp_root" -c core.quotePath=false ls-files -z --others --exclude-standard \
    | while IFS= read -r -d '' f; do
        link="$(fp_outer_link "$f")"
        if [ -n "$link" ]; then
          # Files behind one link arrive together; the final sort -u removes any repeat.
          if [ "$link" != "$last" ]; then fp_link_record "$link" || exit 1; fi
          last="$link"
        else
          h="$(git -C "$fp_root" hash-object -- "$f")" || exit 1
          # The executable bit is part of what git commits; hash-object ignores it.
          mode=644; if [ -x "$fp_root/$f" ]; then mode=755; fi
          fp_record F "$f" "$mode" "$h" || exit 1
        fi
      done
}

# Links that replace a folder of tracked files: git on Windows reads through a junction
# as if it were the folder, so the files can look unchanged and no untracked path leads
# to it. Each folder is checked once; paths arrive sorted.
fp_tracked_links() {
  local last_dir="" last_link=""
  git -C "$fp_root" -c core.quotePath=false ls-files -z \
    | while IFS= read -r -d '' f; do
        case "$f" in */*) d="${f%/*}" ;; *) continue ;; esac
        if [ "$d" = "$last_dir" ]; then continue; fi
        last_dir="$d" p="$d" link=""
        while :; do
          if [ -L "$fp_root/$p" ]; then link="$p"; fi
          case "$p" in */*) p="${p%/*}" ;; *) break ;; esac
        done
        if [ -n "$link" ] && [ "$link" != "$last_link" ]; then
          fp_link_record "$link" || exit 1
          last_link="$link"
        fi
      done
}

# Reads NUL-terminated paths and writes back those git does not ignore: no matching
# pattern, or a negated one (!), which un-ignores. check-ignore exits 1 when nothing is
# ignored, which is not a failure.
fp_not_ignored() {
  { git -C "$fp_root" check-ignore -z --stdin --non-matching --verbose || [ $? -eq 1 ]; } \
    | while IFS= read -r -d '' src && IFS= read -r -d '' num && IFS= read -r -d '' pat \
        && IFS= read -r -d '' path; do
        case "$pat" in '' | '!'*) printf '%s\0' "$path" ;; esac
      done
}

# Untracked links, also those that lead to an empty folder: git lists no file behind
# them, but --directory lists them, and find looks inside untracked folders. Links in
# ignored folders are left out, like every ignored file.
fp_untracked_links() {
  git -C "$fp_root" -c core.quotePath=false ls-files -z --others --exclude-standard --directory \
    | while IFS= read -r -d '' e; do
        e="${e%/}"
        # An entry at or under a link stands for that link; its target is not searched.
        link="$(fp_outer_link "$e")"
        if [ -n "$link" ]; then
          fp_link_record "$link" || exit 1
        elif [ -d "$fp_root/$e" ]; then
          # "./" keeps a folder named like a find action, such as -delete, a folder name.
          (cd "$fp_root" && find "./$e" -type l -print0) \
            | while IFS= read -r -d '' l; do printf '%s\0' "${l#./}"; done \
            | fp_not_ignored \
            | while IFS= read -r -d '' l; do fp_link_record "$l" || exit 1; done || exit 1
        fi
      done
}

# Six lines: hashes of the status, unstaged diff, staged diff, and untracked file
# contents (links by where they point), then the HEAD commit and the branch. Equal
# output before and after a step means it changed nothing that git sees; ignored files
# are not covered.
cmd_fingerprint() {
  [ $# -eq 0 ] || usage
  local root status unstaged staged untracked head ref
  root="$(git rev-parse --show-toplevel)"
  fp_root="$root"
  head="$(git -C "$root" rev-parse --verify --quiet HEAD || echo none)"
  ref="$(git -C "$root" symbolic-ref --quiet HEAD || echo detached)"
  # Each hash is buffered, so a failing step exits before anything is printed.
  status="$(git -C "$root" status --porcelain --untracked-files=all | git hash-object --stdin)"
  # External diff and textconv drivers from the user's config could print nothing for
  # a real change; --binary --full-index records exact content.
  unstaged="$(git -C "$root" diff --no-ext-diff --no-textconv --binary --full-index | git hash-object --stdin)"
  staged="$(git -C "$root" diff --cached --no-ext-diff --no-textconv --binary --full-index | git hash-object --stdin)"
  untracked="$({ fp_untracked_files && fp_untracked_links && fp_tracked_links; } \
    | LC_ALL=C sort -u | git hash-object --stdin)"
  printf '%s\n' "$status" "$unstaged" "$staged" "$untracked" "$head" "$ref"
}

# Stages everything in the task folder and commits it with the message in <file>. Hooks
# run. HOOK_CHANGED=yes means a hook changed what was committed, so the commit is not
# exactly the reviewed tree.
cmd_commit() {
  [ $# -eq 1 ] || usage
  local msg="$1" here before staged committed changed=no copied_list rel tracked
  here="$(git rev-parse --show-toplevel 2>/dev/null)" || die 3 "not inside a git repository"
  top="$here"
  if [ "$(git_dir "$here")" = "$(common_dir "$here")" ]; then
    die 3 "run commit inside the task folder, not the main folder"
  fi
  { [ -f "$msg" ] && [ -s "$msg" ]; } || die 2 "commit message file is missing or empty: $msg"
  case "$msg" in /* | [A-Za-z]:*) ;; *) msg="$PWD/$msg" ;; esac
  # Local files that copy-local put here must still be ignored and untracked, or the
  # commit would contain them.
  copied_list="$(git -C "$here" rev-parse --path-format=absolute --git-path worktree-task-copied)" \
    || die 5 "cannot locate the task folder's git directory; nothing committed"
  if [ -f "$copied_list" ]; then
    while IFS= read -r -d '' rel; do
      { [ -e "$here/$rel" ] || [ -L "$here/$rel" ]; } || continue
      # Literal: as a pattern, a name such as .env[x] would match a tracked .envx.
      tracked="$(git --literal-pathspecs -C "$here" ls-files -- "$rel")" || die 5 "git ls-files failed; nothing committed"
      if [ -n "$tracked" ] || ! git -C "$here" check-ignore -q --no-index -- "$rel"; then
        die 3 "the copied local file $rel is no longer ignored, or is tracked; nothing committed"
      fi
    done < "$copied_list"
  fi
  before="$(git -C "$here" rev-parse HEAD)"
  git -C "$here" add -A || die 5 "git add failed"
  staged="$(git -C "$here" write-tree)" || die 5 "git write-tree failed"
  [ "$staged" != "$(git -C "$here" rev-parse "HEAD^{tree}")" ] || die 3 "nothing to commit"
  if ! git -C "$here" commit --quiet -F "$msg" >&2; then
    [ "$(git -C "$here" rev-parse HEAD)" = "$before" ] || die 5 "git commit failed after HEAD moved; inspect $here"
    die 3 "git refused the commit (a hook may have failed; see above); nothing was committed"
  fi
  committed="$(git -C "$here" rev-parse "HEAD^{tree}")"
  [ "$committed" = "$staged" ] || changed=yes
  printf 'COMMIT=%s\nTREE_STAGED=%s\nTREE_COMMITTED=%s\nHOOK_CHANGED=%s\n' \
    "$(git -C "$here" rev-parse HEAD)" "$staged" "$committed" "$changed"
}

# A file that does not exist prints HASH=missing: a deleted locked test is a change to
# report, not a failure to read. A file that exists but cannot be hashed still fails.
cmd_hash() {
  [ $# -ge 1 ] || usage
  local hashes="" file present=() i=0
  for file in "$@"; do
    if [ -e "$file" ]; then present+=("$file"); fi
  done
  if [ "${#present[@]}" -gt 0 ]; then
    hashes="$(git hash-object -- "${present[@]}")" || die 5 "git hash-object failed"
  fi
  for file in "$@"; do
    if [ -e "$file" ]; then
      i=$((i + 1))
      printf 'HASH=%s %s\n' "$(printf '%s\n' "$hashes" | sed -n "${i}p")" "$file"
    else
      printf 'HASH=missing %s\n' "$file"
    fi
  done
}

[ $# -ge 1 ] || usage
command="$1"
shift
case "$command" in
  preflight) cmd_preflight "$@" ;;
  create) cmd_create "$@" ;;
  copy-local) cmd_copy_local "$@" ;;
  commit) cmd_commit "$@" ;;
  rebase) cmd_rebase "$@" ;;
  merge) cmd_merge "$@" ;;
  remove) cmd_remove "$@" ;;
  fingerprint) cmd_fingerprint "$@" ;;
  hash) cmd_hash "$@" ;;
  *) usage ;;
esac
