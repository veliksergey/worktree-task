#!/usr/bin/env bash
# Tests for plugins/worktree-task/skills/start/worktree.sh, in throwaway repositories.
# Run from anywhere: bash tests/worktree.test.sh
# WORKTREE_SH=<script> runs the same cases against another copy of the script.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wt_sh="${WORKTREE_SH:-$here/../plugins/worktree-task/skills/start/worktree.sh}"
fails=0

abort() { echo "setup failed: $1" >&2; exit 2; }
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
# check <name> <command...>: passes when the command succeeds.
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name (rc=$rc, out: $(printf '%s' "$out" | tr '\n' ' '), err: $(tr '\n' ' ' < "$tmp/stderr"))"; fi; }
# run_in <dir> <args...>: runs the script in <dir>; sets $out and $rc.
run_in() { local dir="$1"; shift; out="$(cd "$dir" && bash "$wt_sh" "$@" 2>"$tmp/stderr")"; rc=$?; }
# run_with <bin-dir> <dir> <args...>: like run_in, with stand-in commands from <bin-dir> first on PATH.
run_with() { local bin="$1" dir="$2"; shift 2; out="$(cd "$dir" && PATH="$bin:$PATH" bash "$wt_sh" "$@" 2>"$tmp/stderr")"; rc=$?; }
val() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -n 1; }
has_line() { printf '%s\n' "$out" | grep -qxF -- "$1"; }
sha() { git -C "$1" rev-parse "$2"; }
commit_file() { printf '%s\n' "$3" > "$1/$2" && git -C "$1" add -- "$2" && git -C "$1" commit -q -m "$4"; }
branch_exists() { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }
# make_link <link> <target>: a junction on Windows, a symbolic link elsewhere.
make_link() {
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) MSYS2_ARG_CONV_EXCL='*' cmd /c mklink /J "$(cygpath -w "$1")" "$(cygpath -w "$2")" > /dev/null ;;
    *) ln -s "$2" "$1" ;;
  esac
}
# make_symlink <target> <link>: a relative symbolic link; on Windows it needs Developer Mode.
make_symlink() { MSYS=winsymlinks:nativestrict ln -s "$1" "$2" 2>/dev/null && [ -L "$2" ]; }

# Every write below happens inside this folder, so stop before writing if it is missing.
tmp="$(mktemp -d)" || abort "cannot create a temporary folder"
{ [ -n "$tmp" ] && [ -d "$tmp" ]; } || abort "cannot create a temporary folder"
trap 'rm -rf -- "${tmp:?}"' EXIT
: > "$tmp/stderr" || abort "cannot write in $tmp"
# Keeps git from finding a repository above the temp folder or reading the user's config.
export GIT_CEILING_DIRECTORIES="$tmp"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
printf '[user]\n\tname = test\n\temail = test@example.invalid\n[init]\n\tdefaultBranch = main\n[core]\n\tautocrlf = false\n[commit]\n\tgpgsign = false\n' \
  > "$GIT_CONFIG_GLOBAL" || abort "git config"

# Stand-ins: a git whose "rebase --abort" restores HEAD but leaves rebase state behind
# and fails, and a find that fails.
real_git="$(command -v git)" || abort "git not found"
mkdir -p "$tmp/bin-noabort" "$tmp/bin-nofind" || abort "stand-in folders"
cat > "$tmp/bin-noabort/git" <<EOF || abort "git stand-in"
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = --abort ]; then
    "$real_git" "\$@"
    mkdir -p "\$("$real_git" rev-parse --path-format=absolute --git-path rebase-merge)"
    exit 42
  fi
done
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/bin-noabort/git" || abort "chmod git stand-in"
# A git whose ls-files fails, and a git that advances main (to $RACE_TO) just before a
# rebase starts, the way another task merging at that moment would.
mkdir -p "$tmp/bin-nolsfiles" "$tmp/bin-race" || abort "stand-in folders"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = ls-files ] && exit 42; done\nexec "%s" "$@"\n' "$real_git" \
  > "$tmp/bin-nolsfiles/git" && chmod +x "$tmp/bin-nolsfiles/git" || abort "ls-files stand-in"
cat > "$tmp/bin-race/git" <<EOF || abort "race stand-in"
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = --abort ] && exec "$real_git" "\$@"; done
for a in "\$@"; do
  if [ "\$a" = rebase ]; then "$real_git" update-ref refs/heads/main "\$RACE_TO" || exit 99; break; fi
done
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/bin-race/git" || abort "chmod race stand-in"
# A git whose rename-blind diff (the overlap listing) fails.
mkdir -p "$tmp/bin-nodiff" || abort "stand-in folder"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = --no-renames ] && exit 42; done\nexec "%s" "$@"\n' "$real_git" \
  > "$tmp/bin-nodiff/git" && chmod +x "$tmp/bin-nodiff/git" || abort "diff stand-in"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin-nofind/find" && chmod +x "$tmp/bin-nofind/find" || abort "find stand-in"
# A git and an rm that log each git ls-files call and each rm call given a link under
# node_modules/ to $tmp/calls.log, and an rm that fails on such links.
real_rm="$(command -v rm)" || abort "rm not found"
mkdir -p "$tmp/bin-count" "$tmp/bin-norm" || abort "stand-in folders"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = ls-files ] && echo ls-files >> "%s"; done\nexec "%s" "$@"\n' \
  "$tmp/calls.log" "$real_git" > "$tmp/bin-count/git" && chmod +x "$tmp/bin-count/git" || abort "counting git"
printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in *node_modules/*) echo rm >> "%s"; break ;; esac; done\nexec "%s" "$@"\n' \
  "$tmp/calls.log" "$real_rm" > "$tmp/bin-count/rm" && chmod +x "$tmp/bin-count/rm" || abort "counting rm"
printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in *node_modules/*) exit 1 ;; esac; done\nexec "%s" "$@"\n' \
  "$real_rm" > "$tmp/bin-norm/rm" && chmod +x "$tmp/bin-norm/rm" || abort "failing rm"
# A git that advances main (to $RACE_TO) just before a merge, the way another task
# merging at that moment would, and a cp that fails.
mkdir -p "$tmp/bin-mergerace" "$tmp/bin-nocp" || abort "stand-in folders"
cat > "$tmp/bin-mergerace/git" <<EOF || abort "merge race stand-in"
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = merge ]; then "$real_git" update-ref refs/heads/main "\$RACE_TO" || exit 99; break; fi
done
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/bin-mergerace/git" || abort "chmod merge race stand-in"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin-nocp/cp" && chmod +x "$tmp/bin-nocp/cp" || abort "cp stand-in"
# A git that advances main once, at the first merge-base call (the fast-forward check),
# and a sort that fails with status 2, the code sort uses for I/O errors.
mkdir -p "$tmp/bin-baserace" "$tmp/bin-sort2" || abort "stand-in folders"
cat > "$tmp/bin-baserace/git" <<EOF || abort "base race stand-in"
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = merge-base ] && [ ! -e "\$RACE_ONCE" ]; then
    : > "\$RACE_ONCE" && "$real_git" update-ref refs/heads/main "\$RACE_TO" || exit 99
    break
  fi
done
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/bin-baserace/git" || abort "chmod base race stand-in"
printf '#!/bin/sh\nexit 2\n' > "$tmp/bin-sort2/sort" && chmod +x "$tmp/bin-sort2/sort" || abort "sort stand-in"
# A comm that fails, for the overlap check.
mkdir -p "$tmp/bin-nocomm" || abort "stand-in folder"
printf '#!/bin/sh\nexit 2\n' > "$tmp/bin-nocomm/comm" && chmod +x "$tmp/bin-nocomm/comm" || abort "comm stand-in"

# manual_block <file> <marker>: the first ```bash block after the line holding <marker>,
# unindented: the manual removal commands the README and the skill give the user.
manual_block() {
  awk -v m="$2" 'index($0, m) { found = 1 } found && /^[[:space:]]*```bash/ { inb = 1; next }
    inb && /^[[:space:]]*```/ { exit } inb { sub(/^[[:space:]]+/, ""); print }' "$1"
}

# new_repo <case>: sets $repo to a fresh repository $tmp/<case>/app with one commit on main.
new_repo() {
  repo="$tmp/$1/app"
  mkdir -p "$repo/src" &&
    git -C "$repo" init -q . &&
    printf '.env*\n!.env.template\nnode_modules/\nconfig/local.json\n' > "$repo/.gitignore" &&
    echo 'API_URL=' > "$repo/.env.template" &&
    echo 'SECRET=do-not-print' > "$repo/.env.local" &&
    echo one > "$repo/src/a.txt" &&
    printf 'line1\nline2\nline3\nline4\nline5\n' > "$repo/b.txt" &&
    git -C "$repo" add . &&
    git -C "$repo" commit -q -m base || abort "repository $1"
}

# --- usage ---------------------------------------------------------------------------
mkdir -p "$tmp/nogit" || abort "mkdir nogit"
run_in "$tmp/nogit"
check "no command: usage error" [ "$rc" -eq 2 ]
run_in "$tmp/nogit" frobnicate
check "unknown command: usage error" [ "$rc" -eq 2 ]

# --- preflight -----------------------------------------------------------------------
new_repo preflight
run_in "$repo" preflight
check "preflight: main folder accepted" [ "$rc" -eq 0 ]
check "preflight: reports repo, branch and a clean tree" \
  eval '[ "$(val REPO)" = app ] && [ "$(val BRANCH)" = main ] && [ "$(val DIRTY)" = no ] && [ "$(val HEAD_SHA)" = "$(sha "$repo" HEAD)" ]'
echo changed >> "$repo/src/a.txt"
run_in "$repo" preflight
check "preflight: an edited tracked file is reported as dirty" [ "$(val DIRTY)" = yes ]
git -C "$repo" checkout -q -- src/a.txt
run_in "$tmp/nogit" preflight
check "preflight: outside git refused" [ "$rc" -eq 3 ]

# A tag with the name of the checked-out branch must not change the branch name.
git -C "$repo" tag main || abort "tag main"
run_in "$repo" preflight
check "preflight: a tag named like the current branch still reports the plain branch name" \
  eval '[ "$rc" -eq 0 ] && [ "$(val BRANCH)" = main ]'
run_in "$repo" create tagged
check "create: the default base works when a tag shares the branch name" eval '[ "$rc" -eq 0 ] && [ "$(val BASE)" = main ]'
commit_file "$tmp/preflight/app-tagged" t.txt t "tagged work" || abort "tagged commit"
run_in "$repo" merge task/tagged main
check "merge: accepted when a tag shares the base branch name" \
  eval '[ "$rc" -eq 0 ] && [ "$(sha "$repo" refs/heads/main)" = "$(sha "$repo" task/tagged)" ]'
git -C "$repo" tag -d main > /dev/null || abort "delete tag main"

# --- create --------------------------------------------------------------------------
new_repo create
main_sha="$(sha "$repo" main)"
run_in "$repo" create feat
check "create: exit 0" [ "$rc" -eq 0 ]
check "create: sibling folder <repo>-<slug> exists" [ -d "$tmp/create/app-feat" ]
check "create: branch task/<slug> starts at the base" [ "$(sha "$repo" task/feat)" = "$main_sha" ]
check "create: reports branch, base, base sha and run name" \
  eval '[ "$(val BRANCH)" = task/feat ] && [ "$(val BASE)" = main ] && [ "$(val BASE_SHA)" = "$main_sha" ] && [ "$(val RUN_NAME)" = app-feat ]'
check "create: the folder is checked out on the task branch" \
  [ "$(git -C "$tmp/create/app-feat" symbolic-ref --short HEAD)" = task/feat ]

run_in "$tmp/create/app-feat" create other
check "create: refused inside a task folder" [ "$rc" -eq 3 ]
run_in "$tmp/create/app-feat" preflight
check "preflight: refused inside a task folder" [ "$rc" -eq 3 ]

git -C "$repo" branch task/taken || abort "branch task/taken"
run_in "$repo" create taken
check "create: existing branch refused, no folder made" eval '[ "$rc" -eq 3 ] && [ ! -e "$tmp/create/app-taken" ]'

mkdir -p "$tmp/create/app-occupied" || abort "mkdir app-occupied"
run_in "$repo" create occupied
check "create: existing folder refused, no branch made" eval '[ "$rc" -eq 3 ] && ! branch_exists "$repo" task/occupied'

make_link "$tmp/create/app-dangling" "$tmp/create/no-such-folder" 2>/dev/null
if [ -L "$tmp/create/app-dangling" ]; then
  run_in "$repo" create dangling
  check "create: a dangling link at the folder path is refused, no branch made" \
    eval '[ "$rc" -eq 3 ] && [ -L "$tmp/create/app-dangling" ] && ! branch_exists "$repo" task/dangling'
  rm -f "$tmp/create/app-dangling"
fi

for bad in Bad_Slug -lead trail- 'a b' ''; do
  run_in "$repo" create "$bad"
  check "create: invalid slug '$bad' refused" [ "$rc" -eq 2 ]
done
run_in "$repo" create "$(printf 'a%.0s' $(seq 1 41))"
check "create: 41-character slug refused" [ "$rc" -eq 2 ]

run_in "$repo" create nobase nosuch
check "create: missing base branch refused, no folder made" eval '[ "$rc" -eq 3 ] && [ ! -e "$tmp/create/app-nobase" ]'

git -C "$repo" branch dev || abort "branch dev"
git -C "$repo" switch -q dev && commit_file "$repo" dev.txt dev "dev work" && git -C "$repo" switch -q main || abort "dev commit"
run_in "$repo" create fromdev dev
check "create: explicit base is used" eval '[ "$rc" -eq 0 ] && [ "$(sha "$repo" task/fromdev)" = "$(sha "$repo" refs/heads/dev)" ] && [ "$(val BASE)" = dev ]'
git -C "$repo" tag dev main || abort "tag dev"
run_in "$repo" create fromdevtag dev
check "create: a tag with the base's name is ignored; the branch tip is used" \
  eval '[ "$rc" -eq 0 ] && [ "$(sha "$repo" task/fromdevtag)" = "$(sha "$repo" refs/heads/dev)" ] && [ "$(val BASE_SHA)" = "$(sha "$repo" refs/heads/dev)" ] && [ "$(sha "$repo" refs/heads/dev)" != "$(sha "$repo" refs/tags/dev)" ]'
git -C "$repo" tag -d dev > /dev/null || abort "delete tag dev"

git -C "$repo" update-ref refs/remotes/origin/main main &&
  git -C "$repo" config branch.main.remote origin && git -C "$repo" config branch.main.merge refs/heads/main &&
  git -C "$repo" config branch.autoSetupMerge inherit || abort "upstream setup"
run_in "$repo" create inherits
check "create: the task branch never takes the base's upstream" \
  eval '[ "$rc" -eq 0 ] && ! git -C "$repo" config --get branch.task/inherits.merge >/dev/null'
git -C "$repo" config --unset branch.autoSetupMerge && git -C "$repo" config --unset branch.main.remote &&
  git -C "$repo" config --unset branch.main.merge || abort "upstream teardown"

git -C "$repo" checkout -q --detach || abort "detach"
run_in "$repo" create detached
check "create: detached HEAD without a base refused" eval '[ "$rc" -eq 3 ] && [ ! -e "$tmp/create/app-detached" ]'
git -C "$repo" switch -q main || abort "back to main"

# --- copy-local ----------------------------------------------------------------------
# Copying is opt-in: without .worktreeinclude in the main folder, nothing is copied.
new_repo copy
run_in "$repo" create feat
task="$tmp/copy/app-feat"
run_in "$repo" copy-local "$task"
check "copy-local: without .worktreeinclude nothing is copied, not even a root .env file" \
  eval '[ "$rc" -eq 0 ] && [ "$(val INCLUDE)" = none ] && [ "$(val COPIED_COUNT)" = 0 ] && ! printf "%s" "$out" | grep -q ^COPIED= && [ ! -e "$task/.env.local" ]'
printf '.env*\n' > "$repo/.worktreeinclude" || abort "worktreeinclude"
run_in "$repo" copy-local "$task"
check "copy-local: copies the gitignored root .env file that .worktreeinclude lists" \
  eval '[ "$rc" -eq 0 ] && [ "$(val INCLUDE)" = .worktreeinclude ] && has_line COPIED=.env.local && [ "$(cat "$task/.env.local")" = SECRET=do-not-print ]'
check "copy-local: skips the tracked .env.template and counts one file" \
  eval '! has_line COPIED=.env.template && [ "$(val COPIED_COUNT)" = 1 ]'
check "copy-local: never prints file contents" eval '! printf "%s" "$out" | grep -q do-not-print'
run_in "$repo" copy-local "$task"
check "copy-local: an existing file is skipped, not overwritten" \
  eval '[ "$rc" -eq 0 ] && has_line SKIPPED=.env.local && [ "$(val COPIED_COUNT)" = 0 ]'
run_in "$repo" copy-local "$repo"
check "copy-local: the main folder as target refused" [ "$rc" -eq 3 ]
run_in "$repo" copy-local "$tmp/nogit"
check "copy-local: a folder outside git refused" [ "$rc" -eq 3 ]

# An unexpected failure under set -e (here cp) exits 5, not the failing command's code.
new_repo copyfail
printf '.env.local\n' > "$repo/.worktreeinclude" || abort "worktreeinclude"
run_in "$repo" create feat
run_with "$tmp/bin-nocp" "$repo" copy-local "$tmp/copyfail/app-feat"
check "copy-local: an unexpected failure exits 5 with a message" \
  eval '[ "$rc" -eq 5 ] && grep -q "unexpected failure" "$tmp/stderr"'

# A base whose .gitignore does not cover the local file: copying it would expose it.
new_repo notignored
printf '.env.local\n' > "$repo/.worktreeinclude" || abort "worktreeinclude"
{ git -C "$repo" switch -q -c old && printf 'node_modules/\n' > "$repo/.gitignore" &&
  git -C "$repo" commit -qam "old ignore rules" && git -C "$repo" switch -q main; } || abort "old base"
run_in "$repo" create feat old
task="$tmp/notignored/app-feat"
run_in "$repo" copy-local "$task"
check "copy-local: a file the task folder would not ignore is reported NOT_IGNORED and not copied" \
  eval '[ "$rc" -eq 0 ] && has_line NOT_IGNORED=.env.local && [ ! -e "$task/.env.local" ] && [ -z "$(git -C "$task" status --porcelain)" ]'

new_repo include
mkdir -p "$repo/config" || abort "mkdir config"
echo '{"local":true}' > "$repo/config/local.json"
echo notes > "$repo/notes.txt"
printf 'config/local.json\nnotes.txt\n' > "$repo/.worktreeinclude"
run_in "$repo" create feat
task="$tmp/include/app-feat"
run_in "$repo" copy-local "$task"
check ".worktreeinclude: copies a listed gitignored file" eval 'has_line COPIED=config/local.json && [ -f "$task/config/local.json" ]'
check ".worktreeinclude: a listed file git does not ignore is not copied" eval '! has_line COPIED=notes.txt && [ ! -e "$task/notes.txt" ]'
check ".worktreeinclude: an unlisted .env file is not copied" eval '! has_line COPIED=.env.local && [ ! -e "$task/.env.local" ]'

run_in "$repo" create feat2
task2="$tmp/include/app-feat2"
run_with "$tmp/bin-nolsfiles" "$repo" copy-local "$task2"
check "copy-local: a failed listing exits 5 and copies nothing" \
  eval '[ "$rc" -eq 5 ] && ! printf "%s" "$out" | grep -q ^COPIED= && [ ! -e "$task2/config/local.json" ]'
mkdir -p "$tmp/include/elsewhere" || abort "mkdir elsewhere"
make_link "$task2/config" "$tmp/include/elsewhere" || abort "config link"
run_in "$repo" copy-local "$task2"
check "copy-local: a link among the destination's parent folders is refused" \
  eval '[ "$rc" -eq 0 ] && has_line REFUSED=config/local.json && [ ! -e "$tmp/include/elsewhere/local.json" ]'
rm -f "$task2/config" || abort "remove config link"
mkdir -p "$task2/config" && make_link "$task2/config/local.json" "$tmp/include/elsewhere/missing.json" 2>/dev/null
if [ -L "$task2/config/local.json" ]; then
  run_in "$repo" copy-local "$task2"
  check "copy-local: a link at the destination is skipped, not written through" \
    eval 'has_line SKIPPED=config/local.json && [ ! -e "$tmp/include/elsewhere/missing.json" ]'
fi

# --- rebase --------------------------------------------------------------------------
new_repo rebase
run_in "$repo" create feat
task="$tmp/rebase/app-feat"
commit_file "$task" feat.txt feat "task work" || abort "task commit"
run_in "$task" rebase main
check "rebase: base unchanged reports BASE_MOVED=no" eval '[ "$rc" -eq 0 ] && [ "$(val BASE_MOVED)" = no ]'

commit_file "$repo" other.txt other "main work" || abort "main commit"
git -C "$repo" config rebase.updateRefs true && git -C "$repo" branch keep-me task/feat || abort "updateRefs setup"
keep_before="$(sha "$repo" keep-me)"
run_in "$task" rebase main
check "rebase: moved base without shared files rebases cleanly" \
  eval '[ "$rc" -eq 0 ] && [ "$(val BASE_MOVED)" = yes ] && ! printf "%s" "$out" | grep -q ^OVERLAP= && git -C "$task" merge-base --is-ancestor main HEAD'
check "rebase: with rebase.updateRefs set, another branch at the task commit stays put" \
  [ "$(sha "$repo" keep-me)" = "$keep_before" ]
git -C "$repo" config --unset rebase.updateRefs && git -C "$repo" branch -q -D keep-me || abort "updateRefs teardown"

# Another task merges between the overlap check and the rebase.
commit_file "$repo" race1.txt r1 "main before the race" || abort "race base"
pinned="$(sha "$repo" main)"
git -C "$repo" switch -q -c race-tmp && commit_file "$repo" feat.txt "from the race" "race commit edits a task file" || abort "race commit"
race_to="$(sha "$repo" race-tmp)"
git -C "$repo" switch -q main && git -C "$repo" branch -q -D race-tmp || abort "race teardown"
out="$(cd "$task" && RACE_TO="$race_to" PATH="$tmp/bin-race:$PATH" bash "$wt_sh" rebase main 2>"$tmp/stderr")"; rc=$?
check "rebase: rebases onto the base commit it checked, even if the branch moves meanwhile" \
  eval '[ "$rc" -eq 0 ] && [ "$(val BASE_SHA)" = "$pinned" ] && git -C "$task" merge-base --is-ancestor "$pinned" HEAD && ! git -C "$task" merge-base --is-ancestor "$race_to" HEAD'
git -C "$repo" update-ref refs/heads/main "$pinned" || abort "undo race move"

commit_file "$repo" listing.txt l "main moves again" || abort "listing commit"
before="$(sha "$task" HEAD)"
run_with "$tmp/bin-nodiff" "$task" rebase main
check "rebase: a failed overlap listing exits 5 before rebasing" eval '[ "$rc" -eq 5 ] && [ "$(sha "$task" HEAD)" = "$before" ]'
# A failed sort or comparison of the two lists would also read as "no overlap".
run_with "$tmp/bin-sort2" "$task" rebase main
check "rebase: a failed sort of the changed-file lists exits 5 before rebasing" \
  eval '[ "$rc" -eq 5 ] && [ "$(sha "$task" HEAD)" = "$before" ] && ! printf "%s" "$out" | grep -q ^BASE_MOVED='
run_with "$tmp/bin-nocomm" "$task" rebase main
check "rebase: a failed comparison of the changed-file lists exits 5 before rebasing" \
  eval '[ "$rc" -eq 5 ] && [ "$(sha "$task" HEAD)" = "$before" ] && ! printf "%s" "$out" | grep -q ^BASE_MOVED='

printf 'task1\nline2\nline3\nline4\nline5\n' > "$task/b.txt" && git -C "$task" commit -qam "task edits line 1" || abort "task b.txt"
printf 'line1\nline2\nline3\nline4\nmain5\n' > "$repo/b.txt" && git -C "$repo" commit -qam "main edits line 5" || abort "main b.txt"
run_in "$task" rebase main
check "rebase: a file changed on both sides is reported as OVERLAP" \
  eval '[ "$rc" -eq 0 ] && has_line OVERLAP=b.txt && [ "$(sed -n 1p "$task/b.txt")" = task1 ] && [ "$(sed -n 5p "$task/b.txt")" = main5 ]'

commit_file "$task" src/a.txt task "task edits a" || abort "task a.txt"
commit_file "$repo" src/a.txt main "main edits a" || abort "main a.txt"
before="$(sha "$task" HEAD)"
run_in "$task" rebase main
check "rebase: a conflict exits 4 and names the file" eval '[ "$rc" -eq 4 ] && has_line CONFLICT=src/a.txt'
check "rebase: after a conflict the branch and tree are unchanged" \
  eval '[ "$(sha "$task" HEAD)" = "$before" ] && [ -z "$(git -C "$task" status --porcelain)" ] && [ ! -d "$(git -C "$task" rev-parse --path-format=absolute --git-path rebase-merge)" ]'

run_with "$tmp/bin-noabort" "$task" rebase main
check "rebase: an abort that restores HEAD but leaves rebase state exits 5, not a clean rollback" \
  eval '[ "$rc" -eq 5 ] && [ "$(sha "$task" HEAD)" = "$before" ] && [ -d "$(git -C "$task" rev-parse --path-format=absolute --git-path rebase-merge)" ]'
rm -rf "$(git -C "$task" rev-parse --path-format=absolute --git-path rebase-merge)" || abort "remove fake rebase state"
[ "$(sha "$task" HEAD)" = "$before" ] && [ -z "$(git -C "$task" status --porcelain)" ] || abort "state after the abort stand-in"

# A rebase that fails for another reason (here a refusing pre-rebase hook) is not a conflict.
hook="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-rebase"
mkdir -p "$(dirname "$hook")" && printf '#!/bin/sh\nexit 1\n' > "$hook" && chmod +x "$hook" || abort "pre-rebase hook"
git -C "$task" reset -q --hard HEAD~1 || abort "drop the conflicting task commit"
before="$(sha "$task" HEAD)"
run_in "$task" rebase main
check "rebase: a failure that is not a conflict exits 5, prints no CONFLICT, and keeps the branch" \
  eval '[ "$rc" -eq 5 ] && ! printf "%s" "$out" | grep -q ^CONFLICT= && [ "$(sha "$task" HEAD)" = "$before" ] && [ -z "$(git -C "$task" status --porcelain)" ]'
rm -f "$hook"

echo dirty >> "$task/feat.txt"
run_in "$task" rebase main
check "rebase: uncommitted changes refused" [ "$rc" -eq 3 ]
git -C "$task" checkout -q -- feat.txt
run_in "$repo" rebase main
check "rebase: refused in the main folder" [ "$rc" -eq 3 ]

# The base renames a file the task edits: git rebases it cleanly, but both sides changed it.
new_repo rename
run_in "$repo" create feat
task="$tmp/rename/app-feat"
printf 'one\ntask edit\n' > "$task/src/a.txt" && git -C "$task" commit -qam "task edits a" || abort "rename task commit"
git -C "$repo" mv src/a.txt src/moved.txt && git -C "$repo" commit -qm "main renames a" || abort "rename main commit"
run_in "$task" rebase main
check "rebase: a file renamed on the base and edited by the task is reported as OVERLAP" \
  eval '[ "$rc" -eq 0 ] && has_line OVERLAP=src/a.txt && [ "$(sed -n 2p "$task/src/moved.txt")" = "task edit" ]'

# --- long paths ----------------------------------------------------------------------
# On Windows, a task folder path near 200 characters made git rebase fail with
# "Filename too long". Setup uses core.longpaths explicitly; the script must not need it set.
lg() { git -c core.longpaths=true "$@"; }
# The failure needs a folder path of about 180-245 characters as git sees it: long
# enough that the folder plus a revision range passes 260, short enough for .git files.
win_tmp="$(cd "$tmp" && { pwd -W 2>/dev/null || pwd; })"
# 20 = "/longpath/" (10) + "/" between the two padding folders (1) + "/app-feat" (9)
pad=$((195 - ${#win_tmp} - 20))
[ "$pad" -ge 2 ] || pad=2
deep="$tmp/longpath/$(printf 'd%.0s' $(seq 1 $((pad / 2))))/$(printf 'e%.0s' $(seq 1 $((pad - pad / 2))))"
repo="$deep/app"
{ mkdir -p "$repo" && lg -C "$repo" init -q . && echo one > "$repo/a.txt" && lg -C "$repo" add a.txt &&
  lg -C "$repo" commit -q -m base; } || abort "long-path repository"
run_in "$repo" create feat
check "long path: create works" [ "$rc" -eq 0 ]
task="$deep/app-feat"
{ echo feat > "$task/feat.txt" && lg -C "$task" add feat.txt && lg -C "$task" commit -q -m "task work" &&
  echo other > "$repo/other.txt" && lg -C "$repo" add other.txt && lg -C "$repo" commit -q -m "main moved"; } || abort "long-path commits"
run_in "$task" rebase main
check "long path: rebase onto a moved base works" eval '[ "$rc" -eq 0 ] && [ "$(val BASE_MOVED)" = yes ]'
run_in "$repo" merge task/feat main
check "long path: merge works" [ "$rc" -eq 0 ]
run_in "$repo" remove "$task" task/feat main
check "long path: remove works" eval '[ "$rc" -eq 0 ] && [ ! -e "$task" ]'

# --- merge ---------------------------------------------------------------------------
new_repo merge
run_in "$repo" create feat
task="$tmp/merge/app-feat"
commit_file "$task" feat.txt feat "task work" || abort "task commit"
git -C "$repo" switch -q -c side || abort "side branch"
run_in "$repo" merge task/feat main
check "merge: refused when the main folder is on another branch" eval '[ "$rc" -eq 3 ] && [ "$(sha "$repo" main)" != "$(sha "$repo" task/feat)" ]'
git -C "$repo" switch -q main || abort "back to main"
run_in "$repo" merge task/feat main
check "merge: fast-forwards the base to the task branch" \
  eval '[ "$rc" -eq 0 ] && [ "$(sha "$repo" main)" = "$(sha "$repo" task/feat)" ] && [ "$(val MERGED_SHA)" = "$(sha "$repo" task/feat)" ]'

run_in "$repo" create feat2
commit_file "$tmp/merge/app-feat2" feat2.txt feat2 "task 2 work" || abort "task 2 commit"
commit_file "$repo" main2.txt main2 "main moved" || abort "main moved"
before="$(sha "$repo" main)"
run_in "$repo" merge task/feat2 main
check "merge: a non-fast-forward is refused and the base is unchanged" eval '[ "$rc" -eq 3 ] && [ "$(sha "$repo" main)" = "$before" ]'

run_in "$repo" create feat3
commit_file "$tmp/merge/app-feat3" src/a.txt task3 "task 3 edits a" || abort "task 3 commit"
echo "uncommitted in main" > "$repo/src/a.txt"
before="$(sha "$repo" main)"
run_in "$repo" merge task/feat3 main
check "merge: refused when it would overwrite uncommitted work in the main folder" \
  eval '[ "$rc" -eq 3 ] && [ "$(sha "$repo" main)" = "$before" ] && [ "$(cat "$repo/src/a.txt")" = "uncommitted in main" ]'
git -C "$repo" config merge.autoStash true || abort "merge.autoStash"
run_in "$repo" merge task/feat3 main
check "merge: with merge.autoStash set, still refused and the uncommitted work stays in place" \
  eval '[ "$rc" -eq 3 ] && [ "$(sha "$repo" main)" = "$before" ] && [ "$(cat "$repo/src/a.txt")" = "uncommitted in main" ] && [ -z "$(git -C "$repo" stash list)" ]'
git -C "$repo" config --unset merge.autoStash || abort "unset merge.autoStash"
git -C "$repo" checkout -q -- src/a.txt

# The task force-adds a file that stays ignored and exists as a local file in the main folder.
run_in "$repo" create feat4
task4="$tmp/merge/app-feat4"
{ mkdir -p "$task4/config" && echo '{"from":"task"}' > "$task4/config/local.json" &&
  git -C "$task4" add -f config/local.json && git -C "$task4" commit -q -m "track config"; } || abort "task 4 commit"
mkdir -p "$repo/config" && echo '{"local":"keep me"}' > "$repo/config/local.json" || abort "ignored local file"
before="$(sha "$repo" main)"
run_in "$repo" merge task/feat4 main
check "merge: refused when it would overwrite an ignored local file" \
  eval '[ "$rc" -eq 3 ] && [ "$(sha "$repo" main)" = "$before" ] && [ "$(cat "$repo/config/local.json")" = "{\"local\":\"keep me\"}" ]'
rm -f "$repo/config/local.json" || abort "remove ignored local file"

run_in "$repo" create feat5
commit_file "$tmp/merge/app-feat5" feat5.txt feat5 "task 5 work" || abort "task 5 commit"
git -C "$repo" config branch.main.mergeOptions --squash || abort "mergeOptions"
run_in "$repo" merge task/feat5 main
check "merge: with branch.main.mergeOptions=--squash, still a real fast-forward" \
  eval '[ "$rc" -eq 0 ] && [ "$(sha "$repo" main)" = "$(sha "$repo" task/feat5)" ] && [ -z "$(git -C "$repo" status --porcelain)" ]'
git -C "$repo" config --unset branch.main.mergeOptions || abort "unset mergeOptions"

# Another task merges between the fast-forward check and the merge.
run_in "$repo" create feat6
commit_file "$tmp/merge/app-feat6" feat6.txt feat6 "task 6 work" || abort "task 6 commit"
before="$(sha "$repo" main)"
{ git -C "$repo" switch -q -c race-tmp && commit_file "$repo" race6.txt r6 "race commit" &&
  race_to="$(sha "$repo" race-tmp)" && git -C "$repo" switch -q main && git -C "$repo" branch -q -D race-tmp; } \
  || abort "merge race commit"
out="$(cd "$repo" && RACE_TO="$race_to" PATH="$tmp/bin-mergerace:$PATH" bash "$wt_sh" merge task/feat6 main 2>"$tmp/stderr")"; rc=$?
check "merge: a base another task moved during the merge is reported as not a fast-forward" \
  eval '[ "$rc" -eq 3 ] && grep -q "not a fast-forward" "$tmp/stderr" && [ "$(sha "$repo" main)" = "$race_to" ]'
git -C "$repo" update-ref refs/heads/main "$before" || abort "undo merge race move"
# The same race one step earlier, while the fast-forward check runs.
rm -f "$tmp/race.once"
out="$(cd "$repo" && RACE_TO="$race_to" RACE_ONCE="$tmp/race.once" PATH="$tmp/bin-baserace:$PATH" bash "$wt_sh" merge task/feat6 main 2>"$tmp/stderr")"; rc=$?
check "merge: a base another task moved during the fast-forward check is reported as not a fast-forward" \
  eval '[ -e "$tmp/race.once" ] && [ "$rc" -eq 3 ] && grep -q "not a fast-forward" "$tmp/stderr" && [ "$(sha "$repo" main)" = "$race_to" ]'
git -C "$repo" update-ref refs/heads/main "$before" || abort "undo base race move"

# --- remove --------------------------------------------------------------------------
new_repo remove
run_in "$repo" create feat
task="$tmp/remove/app-feat"
commit_file "$task" feat.txt feat "task work" || abort "task commit"
run_in "$repo" create unmerged
commit_file "$tmp/remove/app-unmerged" u.txt u "unmerged work" || abort "unmerged commit"
run_in "$repo" merge task/feat main
[ "$rc" -eq 0 ] || abort "merge before remove"

run_in "$repo" remove "$repo" main main
check "remove: the main folder refused" eval '[ "$rc" -eq 3 ] && [ -d "$repo/.git" ]'
run_in "$repo" remove "$tmp/remove/app-unmerged" task/unmerged main
check "remove: an unmerged branch refused, folder kept" eval '[ "$rc" -eq 3 ] && [ -d "$tmp/remove/app-unmerged" ] && branch_exists "$repo" task/unmerged'
run_in "$repo" remove "$task" task/other main
check "remove: a folder on a different branch refused" eval '[ "$rc" -eq 3 ] && [ -d "$task" ]'
echo scratch > "$task/scratch.txt"
run_in "$repo" remove "$task" task/feat main
check "remove: untracked files refused, folder kept" eval '[ "$rc" -eq 3 ] && [ -f "$task/scratch.txt" ]'
rm -f "$task/scratch.txt"
git -C "$repo" switch -q -c elsewhere || abort "elsewhere branch"
run_in "$repo" remove "$task" task/feat main
check "remove: refused when the main folder is not on the base" eval '[ "$rc" -eq 3 ] && [ -d "$task" ]'
git -C "$repo" switch -q main || abort "back to main"
git -C "$repo" config branch.task/feat.remote . && git -C "$repo" config branch.task/feat.merge refs/heads/elsewhere || abort "set upstream"
run_in "$repo" remove "$task" task/feat main
check "remove: a task branch with an upstream is refused before anything is removed" \
  eval '[ "$rc" -eq 3 ] && [ -d "$task" ] && branch_exists "$repo" task/feat'
git -C "$repo" config --unset branch.task/feat.remote && git -C "$repo" config --unset branch.task/feat.merge || abort "unset upstream"
git -C "$repo" branch -q -D elsewhere || abort "delete elsewhere"

mkdir -p "$tmp/remove/outside" "$task/node_modules/.store/pkg" || abort "link folders"
echo keep > "$tmp/remove/outside/sentinel.txt"
echo inner > "$task/node_modules/.store/pkg/index.js"
{ make_link "$task/node_modules/outside-link" "$tmp/remove/outside" &&
  make_link "$task/node_modules/inside-link" "$task/node_modules/.store/pkg"; } || abort "links"
[ -L "$task/node_modules/outside-link" ] || abort "the link is not seen as a link"
run_with "$tmp/bin-nofind" "$repo" remove "$task" task/feat main
check "remove: a failing link scan stops before anything is unlinked or removed" \
  eval '[ "$rc" -eq 5 ] && [ -L "$task/node_modules/outside-link" ] && [ -d "$task" ] && branch_exists "$repo" task/feat'
run_with "$tmp/bin-nolsfiles" "$repo" remove "$task" task/feat main
check "remove: a failing tracked-file lookup stops before anything is unlinked" \
  eval '[ "$rc" -eq 5 ] && [ -L "$task/node_modules/outside-link" ] && [ -d "$task" ]'
idx="$(git -C "$task" rev-parse --path-format=absolute --git-path index)" && cp -p -- "$idx" "$tmp/index.bak" &&
  printf 'not an index' > "$idx" || abort "corrupt index"
run_in "$repo" remove "$task" task/feat main
check "remove: an unreadable index is refused before anything is unlinked" \
  eval '[ "$rc" -eq 3 ] && [ -L "$task/node_modules/outside-link" ] && [ -d "$task" ]'
cp -p -- "$tmp/index.bak" "$idx" || abort "restore index"
run_in "$repo" remove "$task" task/feat main
check "remove: removes the folder and the branch" eval '[ "$rc" -eq 0 ] && [ ! -e "$task" ] && ! branch_exists "$repo" task/feat'
check "remove: reports both links as unlinked" [ "$(val UNLINKED)" = 2 ]
check "remove: a file a link pointed to outside the folder survives" \
  eval '[ "$(cat "$tmp/remove/outside/sentinel.txt" 2>/dev/null)" = keep ]'

# Many links: one git ls-files and one rm, not one of each per link, which took minutes
# with the thousands of links package managers create.
new_repo manylinks
run_in "$repo" create feat
task="$tmp/manylinks/app-feat"
commit_file "$task" feat.txt feat "task work" || abort "manylinks commit"
run_in "$repo" merge task/feat main
[ "$rc" -eq 0 ] || abort "manylinks merge"
{ mkdir -p "$task/node_modules" "$tmp/manylinks/outside" && echo keep > "$tmp/manylinks/outside/sentinel.txt"; } \
  || abort "manylinks folders"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do make_link "$task/node_modules/l$i" "$tmp/manylinks/outside" || abort "link $i"; done
run_with "$tmp/bin-norm" "$repo" remove "$task" task/feat main
check "remove: a failed unlink exits 5 before the folder is removed, and the link targets survive" \
  eval '[ "$rc" -eq 5 ] && [ -d "$task" ] && branch_exists "$repo" task/feat && [ "$(cat "$tmp/manylinks/outside/sentinel.txt")" = keep ]'
: > "$tmp/calls.log" || abort "calls log"
run_with "$tmp/bin-count" "$repo" remove "$task" task/feat main
check "remove: twelve links take one git ls-files call and one rm call" \
  eval '[ "$rc" -eq 0 ] && [ "$(val UNLINKED)" = 12 ] && [ "$(grep -c ls-files "$tmp/calls.log")" -eq 1 ] && [ "$(grep -c rm "$tmp/calls.log")" -eq 1 ] && [ ! -e "$task" ] && [ "$(cat "$tmp/manylinks/outside/sentinel.txt")" = keep ]'

# The manual removal commands in the README and the skill: if unlinking fails, nothing
# after it may run, or git worktree remove --force would follow the junction.
readme_steps="$(manual_block "$here/../README.md" "### Removing a task folder by hand")"
skill_steps="$(manual_block "$here/../plugins/worktree-task/skills/start/SKILL.md" "If the user wants to remove a folder that")"
{ [ -n "$readme_steps" ] && [ -n "$skill_steps" ]; } || abort "manual removal commands not found"
for doc in readme skill; do
  new_repo "manual-$doc"
  run_in "$repo" create feat
  task="$tmp/manual-$doc/app-feat"
  { commit_file "$task" feat.txt feat "abandoned work" && mkdir -p "$task/node_modules" "$tmp/manual-$doc/outside" &&
    echo keep > "$tmp/manual-$doc/outside/sentinel.txt" &&
    make_link "$task/node_modules/ext" "$tmp/manual-$doc/outside"; } || abort "manual-$doc setup"
  if [ "$doc" = readme ]; then
    steps="${readme_steps//"<repo>"/app}" steps="${steps//"<slug>"/feat}"
  else
    steps="${skill_steps//"<WORKTREE>"/$task}" steps="${steps//"<BRANCH>"/task/feat}"
  fi
  (cd "$repo" && PATH="$tmp/bin-norm:$PATH" bash -c "$steps") > /dev/null 2>&1
  check "manual removal ($doc): a failed unlink stops before the folder is removed" \
    eval '[ -d "$task" ] && [ -L "$task/node_modules/ext" ] && [ "$(cat "$tmp/manual-$doc/outside/sentinel.txt" 2>/dev/null)" = keep ]'
  (cd "$repo" && bash -c "$steps") > /dev/null 2>&1
  check "manual removal ($doc): removes the folder and the branch, and the link target survives" \
    eval '[ ! -e "$task" ] && ! branch_exists "$repo" task/feat && [ "$(cat "$tmp/manual-$doc/outside/sentinel.txt" 2>/dev/null)" = keep ]'
done

# A link where git tracks a folder: git sees through a junction, so the tree can look
# clean, but deleting the folder would follow it.
new_repo linkdir
run_in "$repo" create feat
task="$tmp/linkdir/app-feat"
commit_file "$task" feat.txt feat "task work" || abort "linkdir commit"
run_in "$repo" merge task/feat main
[ "$rc" -eq 0 ] || abort "linkdir merge"
{ mkdir -p "$tmp/linkdir/copy" && echo one > "$tmp/linkdir/copy/a.txt" && rm -rf -- "${task:?}/src" &&
  make_link "$task/src" "$tmp/linkdir/copy"; } || abort "link over src"
run_in "$repo" remove "$task" task/feat main
check "remove: a link where git tracks a folder is refused before anything is removed" \
  eval '[ "$rc" -eq 3 ] && [ -L "$task/src" ] && [ "$(cat "$tmp/linkdir/copy/a.txt")" = one ] && branch_exists "$repo" task/feat'
rm -f "$task/src" || abort "remove link over src"

# Tracked symbolic links, such as CLAUDE.md -> AGENTS.md: git made them and deletes them
# without following them, and unlinking one would leave the folder dirty.
new_repo tracklink
git -C "$repo" config core.symlinks true || abort "core.symlinks"
{ mkdir -p "$repo/docs" "$tmp/tracklink/outside" && echo agents > "$repo/AGENTS.md" && echo doc > "$repo/docs/d.txt" &&
  echo keep > "$tmp/tracklink/outside/sentinel.txt"; } || abort "tracklink files"
if (cd "$repo" && make_symlink AGENTS.md CLAUDE.md && make_symlink docs docs-link); then
  { git -C "$repo" add AGENTS.md CLAUDE.md docs docs-link && git -C "$repo" commit -q -m "tracked links"; } \
    || abort "tracklink commit"
  run_in "$repo" create feat
  task="$tmp/tracklink/app-feat"
  { [ -L "$task/CLAUDE.md" ] && [ -L "$task/docs-link" ]; } || abort "the task folder has no checked-out links"
  { commit_file "$task" feat.txt feat "task work" && mkdir -p "$task/node_modules" &&
    make_link "$task/node_modules/ext" "$tmp/tracklink/outside"; } || abort "tracklink task"
  run_in "$repo" merge task/feat main
  [ "$rc" -eq 0 ] || abort "tracklink merge"
  run_in "$repo" remove "$task" task/feat main
  check "remove: tracked symbolic links do not block the cleanup, and every target survives" \
    eval '[ "$rc" -eq 0 ] && [ ! -e "$task" ] && ! branch_exists "$repo" task/feat && [ "$(cat "$repo/AGENTS.md")" = agents ] && [ "$(cat "$repo/docs/d.txt")" = doc ] && [ "$(cat "$tmp/tracklink/outside/sentinel.txt")" = keep ]'
  check "remove: only the untracked link is unlinked" [ "$(val UNLINKED)" = 1 ]

  run_in "$repo" create swap
  task="$tmp/tracklink/app-swap"
  commit_file "$task" swap.txt swap "swap work" || abort "swap commit"
  run_in "$repo" merge task/swap main
  [ "$rc" -eq 0 ] || abort "swap merge"
  { rm -f "$task/docs-link" && make_link "$task/docs-link" "$tmp/tracklink/outside"; } || abort "swap the tracked link"
  run_in "$repo" remove "$task" task/swap main
  check "remove: a link swapped in for a tracked symbolic link is refused, and its target survives" \
    eval '[ "$rc" -eq 3 ] && [ -d "$task" ] && branch_exists "$repo" task/swap && [ "$(cat "$tmp/tracklink/outside/sentinel.txt")" = keep ]'
  rm -f "$task/docs-link" || abort "remove the swapped link"

  # assume-unchanged hides the swap from git status when the new target holds only
  # ignored files (.env* here), so the index mark itself must stop the cleanup.
  run_in "$repo" create masked
  task="$tmp/tracklink/app-masked"
  commit_file "$task" masked.txt masked "masked work" || abort "masked commit"
  run_in "$repo" merge task/masked main
  [ "$rc" -eq 0 ] || abort "masked merge"
  { mkdir -p "$tmp/tracklink/ignored-only" && echo keep > "$tmp/tracklink/ignored-only/.env.sentinel" &&
    git -C "$task" update-index --assume-unchanged docs-link && rm -f "$task/docs-link" &&
    make_link "$task/docs-link" "$tmp/tracklink/ignored-only"; } || abort "masked swap"
  [ -z "$(git -C "$task" status --porcelain --untracked-files=all)" ] || abort "the masked swap shows in git status"
  run_in "$repo" remove "$task" task/masked main
  check "remove: a tracked link marked assume-unchanged is refused, and its target survives" \
    eval '[ "$rc" -eq 3 ] && [ -d "$task" ] && branch_exists "$repo" task/masked && [ "$(cat "$tmp/tracklink/ignored-only/.env.sentinel" 2>/dev/null)" = keep ]'
  [ ! -d "$task" ] || { rm -f "$task/docs-link" && git -C "$task" update-index --no-assume-unchanged docs-link; } \
    || abort "unmask"

  # A case-only rename on disk: where the file system ignores case, git status stays
  # clean, but find reports the new spelling, which must not be unlinked.
  run_in "$repo" create spelled
  task="$tmp/tracklink/app-spelled"
  commit_file "$task" spelled.txt spelled "spelled work" || abort "spelled commit"
  run_in "$repo" merge task/spelled main
  [ "$rc" -eq 0 ] || abort "spelled merge"
  { rm -f "$task/CLAUDE.md" && (cd "$task" && make_symlink AGENTS.md claude.md); } || abort "respell CLAUDE.md"
  if [ -z "$(git -C "$task" status --porcelain --untracked-files=all)" ]; then
    run_in "$repo" remove "$task" task/spelled main
    check "remove: a tracked link spelled differently on disk is refused before anything is unlinked" \
      eval '[ "$rc" -eq 3 ] && [ -L "$task/claude.md" ] && [ -d "$task" ] && branch_exists "$repo" task/spelled && grep -q CLAUDE.md "$tmp/stderr"'
  else
    pass "remove: case-only rename case skipped, this file system is case-sensitive"
  fi
else
  pass "remove: tracked symbolic link cases skipped, this system cannot create symbolic links"
fi

# A populated submodule: its files are not tracked by the superproject, so they must not
# be unlinked, and git refuses to remove such a worktree anyway.
new_repo submodule
lib="$tmp/submodule/lib"
{ mkdir -p "$lib" && git -C "$lib" init -q . && echo lib > "$lib/lib.txt" && git -C "$lib" add lib.txt &&
  git -C "$lib" commit -q -m lib &&
  git -C "$repo" -c protocol.file.allow=always submodule --quiet add "$lib" vendor/lib &&
  git -C "$repo" commit -q -m "add submodule"; } || abort "submodule setup"
run_in "$repo" create feat
task="$tmp/submodule/app-feat"
git -C "$task" -c protocol.file.allow=always submodule --quiet update --init || abort "submodule init"
commit_file "$task" feat.txt feat "task work" && run_in "$repo" merge task/feat main || abort "submodule merge"
run_in "$repo" remove "$task" task/feat main
check "remove: populated submodules are refused before anything is removed" \
  eval '[ "$rc" -eq 3 ] && [ -f "$task/vendor/lib/lib.txt" ] && branch_exists "$repo" task/feat'

# --- fingerprint and hash ------------------------------------------------------------
new_repo fingerprint
run_in "$repo" create feat
task="$tmp/fingerprint/app-feat"
run_in "$task" fingerprint
check "fingerprint: four hashes, then the HEAD commit and the branch" \
  eval '[ "$rc" -eq 0 ] && [ "$(printf "%s\n" "$out" | sed -n 1,4p | grep -cE "^[0-9a-f]{40}([0-9a-f]{24})?$")" -eq 4 ] && [ "$(printf "%s\n" "$out" | sed -n 5p)" = "$(sha "$task" HEAD)" ] && [ "$(printf "%s\n" "$out" | sed -n 6p)" = refs/heads/task/feat ]'
fp_before="$out"
echo edit >> "$task/src/a.txt"
run_in "$task" fingerprint
check "fingerprint: an edit changes the unstaged-diff hash" [ "$(printf '%s\n' "$fp_before" | sed -n 2p)" != "$(printf '%s\n' "$out" | sed -n 2p)" ]
run_in "$task" hash src/a.txt b.txt
check "hash: one HASH line per file, matching git hash-object" \
  eval '[ "$rc" -eq 0 ] && has_line "HASH=$(git -C "$task" hash-object src/a.txt) src/a.txt" && has_line "HASH=$(git -C "$task" hash-object b.txt) b.txt"'
# A deleted locked test is a change to report, not a failure to read.
run_in "$task" hash src/a.txt no-such-test.txt b.txt
check "hash: a missing file prints HASH=missing, and the other files are still hashed" \
  eval '[ "$rc" -eq 0 ] && has_line "HASH=missing no-such-test.txt" && has_line "HASH=$(git -C "$task" hash-object src/a.txt) src/a.txt" && has_line "HASH=$(git -C "$task" hash-object b.txt) b.txt"'
run_in "$task" hash src
check "hash: a path that exists but cannot be hashed still exits 5" [ "$rc" -eq 5 ]
git -C "$task" checkout -q -- src/a.txt && commit_file "$task" fp.txt fp "second commit" || abort "fingerprint commit"
run_in "$task" fingerprint
fp_clean="$out"
git -C "$task" checkout -q --detach HEAD~1 || abort "detach"
run_in "$task" fingerprint
check "fingerprint: moving HEAD on a clean tree changes it" [ "$fp_clean" != "$out" ]
git -C "$task" switch -q task/feat || abort "back to task/feat"

# An external diff driver that prints nothing must not hide a second edit to a modified file.
printf '#!/bin/sh\nexit 0\n' > "$tmp/silent-diff.sh" && chmod +x "$tmp/silent-diff.sh" &&
  git -C "$task" config diff.external "$tmp/silent-diff.sh" || abort "external diff driver"
echo first >> "$task/b.txt"
run_in "$task" fingerprint
fp_ext1="$out"
echo second >> "$task/b.txt"
run_in "$task" fingerprint
check "fingerprint: an external diff driver cannot hide an edit to an already modified file" \
  eval '[ "$rc" -eq 0 ] && [ "$out" != "$fp_ext1" ]'
git -C "$task" config --unset diff.external && git -C "$task" checkout -q -- b.txt || abort "external diff teardown"

# Untracked links are recorded by their destination, not by what they point to.
mkdir -p "$tmp/fingerprint/target1" "$tmp/fingerprint/target2" || abort "link targets"
echo same > "$tmp/fingerprint/target1/f.txt" && echo same > "$tmp/fingerprint/target2/f.txt" || abort "link target files"
make_link "$task/lnk" "$tmp/fingerprint/target1" || abort "link 1"
run_in "$task" fingerprint
fp_link1="$out"
check "fingerprint: works with an untracked link to a folder" eval '[ "$rc" -eq 0 ] && [ -n "$fp_link1" ]'
rm -f "$task/lnk" && make_link "$task/lnk" "$tmp/fingerprint/target2" || abort "link 2"
run_in "$task" fingerprint
check "fingerprint: retargeting a link to identical contents changes it" eval '[ "$rc" -eq 0 ] && [ "$out" != "$fp_link1" ]'
rm -f "$task/lnk" && make_link "$task/lnk" "$tmp/fingerprint/no-such-folder" 2>/dev/null
if [ -L "$task/lnk" ]; then
  run_in "$task" fingerprint
  check "fingerprint: works with a dangling untracked link" [ "$rc" -eq 0 ]
fi
rm -f "$task/lnk"

# A failing step must leave no partial output that could compare as equal.
run_with "$tmp/bin-nolsfiles" "$task" fingerprint
check "fingerprint: a failing git step exits non-zero and prints nothing" eval '[ "$rc" -ne 0 ] && [ -z "$out" ]'
# A helper's own status 2, 3, or 4 must not pass for one of the script's exit codes.
run_with "$tmp/bin-sort2" "$task" fingerprint
check "fingerprint: a helper that fails with status 2 exits 5, not as a usage error" \
  eval '[ "$rc" -eq 5 ] && grep -q "unexpected failure" "$tmp/stderr" && [ -z "$out" ]'

# An executable-bit change to an untracked file changes what git would commit.
echo 'echo run' > "$task/run.sh" && chmod -x "$task/run.sh" || abort "untracked script"
run_in "$task" fingerprint
fp_full="$out"
chmod +x "$task/run.sh"
if [ -x "$task/run.sh" ]; then
  run_in "$task" fingerprint
  check "fingerprint: making an untracked file executable changes it" eval '[ "$rc" -eq 0 ] && [ "$out" != "$fp_full" ]'
else
  pass "fingerprint: executable-bit case skipped, this system has no executable bit to change"
fi
rm -f "$task/run.sh"

# The link cases below match codex-review-loop's fingerprint tests (0.2.4).
fp4() { printf '%s\n' "$out" | sed -n 4p; }
fpd="$tmp/fingerprint"
mkdir -p "$fpd/empty1" "$fpd/empty2" || abort "empty targets"

make_link "$task/elnk" "$fpd/empty1" || abort "empty link 1"
run_in "$task" fingerprint
fp_before="$(fp4)"
{ rm -f "$task/elnk" && make_link "$task/elnk" "$fpd/empty2"; } || abort "empty link 2"
run_in "$task" fingerprint
check "fingerprint: retargeting a link to an empty folder changes it" eval '[ "$rc" -eq 0 ] && [ "$(fp4)" != "$fp_before" ]'
rm -f "$task/elnk"

mkdir -p "$task/newdir" && make_link "$task/newdir/inner" "$fpd/empty1" || abort "inner empty link 1"
run_in "$task" fingerprint
fp_before="$(fp4)"
{ rm -f "$task/newdir/inner" && make_link "$task/newdir/inner" "$fpd/empty2"; } || abort "inner empty link 2"
run_in "$task" fingerprint
check "fingerprint: retargeting a link inside a new untracked folder changes it" eval '[ "$rc" -eq 0 ] && [ "$(fp4)" != "$fp_before" ]'
{ rm -f "$task/newdir/inner" && rmdir "$task/newdir"; } || abort "remove newdir"

# With records joined by spaces, a -> "b c d", "a b" -> "c d", "a b c" -> e looked the
# same after a -> "b c e".
if (cd "$task" && make_symlink "b c d" a && make_symlink "c d" "a b" && make_symlink e "a b c"); then
  run_in "$task" fingerprint
  fp_before="$(fp4)"
  (cd "$task" && rm -f a && make_symlink "b c e" a) || abort "retarget spaced link"
  run_in "$task" fingerprint
  check "fingerprint: links with spaces in names and targets cannot collide" eval '[ "$rc" -eq 0 ] && [ "$(fp4)" != "$fp_before" ]'
fi
(cd "$task" && rm -f a "a b" "a b c") || abort "remove spaced links"

mkdir -p "$task/-delete" && echo keep > "$task/-delete/keep.txt" || abort "folder named -delete"
run_in "$task" fingerprint
check "fingerprint: an untracked folder named -delete is not deleted" \
  eval '[ "$rc" -eq 0 ] && [ -f "$task/-delete/keep.txt" ] && [ -f "$task/b.txt" ] && [ -e "$task/.git" ]'
[ -e "$task/.git" ] || abort "the task folder was deleted; later cases cannot run"
rm -rf -- "${task:?}/-delete" || abort "remove -delete folder"

# A link that replaces a tracked folder: git walks through it on Windows.
{ mkdir -p "$task/vendor" && echo keep > "$task/vendor/keep.txt" && git -C "$task" add vendor/keep.txt &&
  git -C "$task" commit -q -m vendor; } || abort "tracked vendor folder"
for v in vendor1 vendor2; do
  { mkdir -p "$fpd/$v" && echo keep > "$fpd/$v/keep.txt" && echo new > "$fpd/$v/new.txt"; } || abort "vendor target $v"
done
{ rm -rf -- "${task:?}/vendor" && make_link "$task/vendor" "$fpd/vendor1"; } || abort "vendor link 1"
run_in "$task" fingerprint
fp_before="$(fp4)"
{ rm -f "$task/vendor" && make_link "$task/vendor" "$fpd/vendor2"; } || abort "vendor link 2"
run_in "$task" fingerprint
check "fingerprint: retargeting a link that replaces a tracked folder changes it" eval '[ "$rc" -eq 0 ] && [ "$(fp4)" != "$fp_before" ]'
{ rm -f "$task/vendor" && git -C "$task" checkout -q -- vendor/keep.txt; } || abort "restore vendor folder"

# The same with only tracked, unchanged files behind the link: no untracked path leads to it.
for v in vendor4 vendor5; do
  { mkdir -p "$fpd/$v" && echo keep > "$fpd/$v/keep.txt"; } || abort "tracked-only target $v"
done
{ rm -rf -- "${task:?}/vendor" && make_link "$task/vendor" "$fpd/vendor4"; } || abort "vendor link 4"
run_in "$task" fingerprint
fp_full="$out"
{ rm -f "$task/vendor" && make_link "$task/vendor" "$fpd/vendor5"; } || abort "vendor link 5"
run_in "$task" fingerprint
check "fingerprint: retargeting a link over tracked, unchanged files changes it" eval '[ "$rc" -eq 0 ] && [ "$out" != "$fp_full" ]'
{ rm -f "$task/vendor" && git -C "$task" checkout -q -- vendor/keep.txt; } || abort "restore vendor folder"

# Ignored links are not covered; a negated (!) rule un-ignores.
exclude="$(git -C "$task" rev-parse --path-format=absolute --git-path info/exclude)" || abort "exclude path"
printf 'node_modules/\n' >> "$exclude" || abort "exclude node_modules"
{ mkdir -p "$task/pkg/node_modules" "$fpd/mod1" "$fpd/mod2" && echo src > "$task/pkg/src.txt" &&
  echo one > "$fpd/mod1/i.js" && echo two > "$fpd/mod2/i.js"; } || abort "untracked pkg"
make_link "$task/pkg/node_modules/dep" "$fpd/mod1" || abort "ignored link 1"
run_in "$task" fingerprint
fp_full="$out"
{ rm -f "$task/pkg/node_modules/dep" && make_link "$task/pkg/node_modules/dep" "$fpd/mod2"; } || abort "ignored link 2"
run_in "$task" fingerprint
check "fingerprint: a link in an ignored folder of a new untracked folder is not covered" eval '[ "$rc" -eq 0 ] && [ "$out" = "$fp_full" ]'
{ rm -f "$task/pkg/node_modules/dep" && rm -rf -- "${task:?}/pkg"; } || abort "remove pkg"

printf 'pkg/*/\n!pkg/keep/\n' >> "$exclude" || abort "negated exclude"
{ mkdir -p "$task/pkg" && echo src > "$task/pkg/src.txt" && make_link "$task/pkg/keep" "$fpd/empty1"; } || abort "negated link 1"
run_in "$task" fingerprint
fp_before="$(fp4)"
{ rm -f "$task/pkg/keep" && make_link "$task/pkg/keep" "$fpd/empty2"; } || abort "negated link 2"
run_in "$task" fingerprint
check "fingerprint: retargeting a link un-ignored by a negated rule changes it" eval '[ "$rc" -eq 0 ] && [ "$(fp4)" != "$fp_before" ]'
{ rm -f "$task/pkg/keep" && rm -rf -- "${task:?}/pkg"; } || abort "remove negation pkg"

# Nothing behind a link is followed, so a link inside a linked folder's target is not covered.
{ mkdir -p "$fpd/vendor3/new" && echo keep > "$fpd/vendor3/keep.txt" && echo f > "$fpd/vendor3/new/file.txt" &&
  make_link "$fpd/vendor3/new/inner" "$fpd/empty1"; } || abort "nested vendor target"
{ rm -rf -- "${task:?}/vendor" && make_link "$task/vendor" "$fpd/vendor3"; } || abort "vendor link 3"
run_in "$task" fingerprint
fp_full="$out"
{ rm -f "$fpd/vendor3/new/inner" && make_link "$fpd/vendor3/new/inner" "$fpd/empty2"; } || abort "retarget inner link"
run_in "$task" fingerprint
check "fingerprint: a link inside a linked folder's target is not followed" eval '[ "$rc" -eq 0 ] && [ "$out" = "$fp_full" ]'
{ rm -f "$task/vendor" && git -C "$task" checkout -q -- vendor/keep.txt; } || abort "restore vendor folder"

# --- commit --------------------------------------------------------------------------
new_repo commit
run_in "$repo" create feat
task="$tmp/commit/app-feat"
printf 'Add the new file\n\nBody line.\n' > "$tmp/commit-msg.txt"
run_in "$repo" commit "$tmp/commit-msg.txt"
check "commit: refused in the main folder" [ "$rc" -eq 3 ]
run_in "$task" commit "$tmp/no-such-message.txt"
check "commit: a missing message file is a usage error" [ "$rc" -eq 2 ]
run_in "$task" commit "$tmp/commit-msg.txt"
check "commit: nothing to commit is refused" eval '[ "$rc" -eq 3 ] && [ "$(sha "$task" HEAD)" = "$(sha "$repo" main)" ]'
echo new > "$task/new.txt"
run_in "$task" commit "$tmp/commit-msg.txt"
check "commit: commits everything with the message and reports HOOK_CHANGED=no" \
  eval '[ "$rc" -eq 0 ] && [ "$(val COMMIT)" = "$(sha "$task" HEAD)" ] && [ "$(val HOOK_CHANGED)" = no ] && [ "$(git -C "$task" log -1 --format=%s)" = "Add the new file" ] && [ -z "$(git -C "$task" status --porcelain)" ]'
hook="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-commit"
mkdir -p "$(dirname "$hook")" && printf '#!/bin/sh\necho hooked >> hooked.txt\ngit add hooked.txt\n' > "$hook" && chmod +x "$hook" || abort "changing hook"
echo two > "$task/two.txt"
run_in "$task" commit "$tmp/commit-msg.txt"
check "commit: a hook that changes the content is reported as HOOK_CHANGED=yes" \
  eval '[ "$rc" -eq 0 ] && [ "$(val HOOK_CHANGED)" = yes ] && git -C "$task" cat-file -e HEAD:hooked.txt'
printf '#!/bin/sh\nexit 1\n' > "$hook" || abort "failing hook"
echo three > "$task/three.txt"
before="$(sha "$task" HEAD)"
run_in "$task" commit "$tmp/commit-msg.txt"
check "commit: a failing hook is refused and nothing is committed" eval '[ "$rc" -eq 3 ] && [ "$(sha "$task" HEAD)" = "$before" ]'
rm -f "$hook"

printf '.env.local\n' > "$repo/.worktreeinclude" || abort "worktreeinclude"
run_in "$repo" copy-local "$task"
has_line COPIED=.env.local || abort "copy .env.local into the commit task"
grep -v '^\.env\*$' "$task/.gitignore" > "$task/.gitignore.new" && mv "$task/.gitignore.new" "$task/.gitignore" || abort "expose .env.local"
before="$(sha "$task" HEAD)"
run_in "$task" commit "$tmp/commit-msg.txt"
check "commit: refused when a copied local file is no longer ignored, and it is not committed" \
  eval '[ "$rc" -eq 3 ] && [ "$(sha "$task" HEAD)" = "$before" ] && ! git -C "$task" cat-file -e HEAD:.env.local 2>/dev/null'

# The same for a copied file whose name contains a newline. Git Bash on Windows stores
# the newline as another character, so the case runs there too.
new_repo nlcopy
nl_name=".env.nl$(printf '\nx')"
if rm -f "$repo/.env.local" && : > "$repo/$nl_name" 2>/dev/null && [ -f "$repo/$nl_name" ]; then
  echo 'SECRET=nl' > "$repo/$nl_name"
  printf '.env*\n' > "$repo/.worktreeinclude" || abort "worktreeinclude"
  run_in "$repo" create feat
  task="$tmp/nlcopy/app-feat"
  run_in "$repo" copy-local "$task"
  grep -v '^\.env\*$' "$task/.gitignore" > "$task/.gitignore.new" && mv "$task/.gitignore.new" "$task/.gitignore" || abort "expose nl file"
  before="$(sha "$task" HEAD)"
  run_in "$task" commit "$tmp/commit-msg.txt"
  check "commit: refused when a copied file with a newline in its name is no longer ignored" \
    eval '[ "$rc" -eq 3 ] && [ "$(sha "$task" HEAD)" = "$before" ]'
else
  pass "commit: newline-name case skipped, this system cannot create such a file"
fi

# A copied file named with glob characters must not match another tracked file.
new_repo literal
{ echo tracked > "$repo/.envx" && git -C "$repo" add -f .envx && git -C "$repo" commit -q -m "track .envx" &&
  echo 'SECRET=bracket' > "$repo/.env[x]" && printf '.env*\n' > "$repo/.worktreeinclude"; } || abort "literal setup"
run_in "$repo" create feat
task="$tmp/literal/app-feat"
run_in "$repo" copy-local "$task"
check "copy-local: a local file named with glob characters is checked literally and copied" \
  eval '[ "$rc" -eq 0 ] && has_line "COPIED=.env[x]" && [ "$(cat "$task/.env[x]" 2>/dev/null)" = SECRET=bracket ]'
echo change > "$task/change.txt" || abort "literal change"
run_in "$task" commit "$tmp/commit-msg.txt"
check "commit: a copied file named with glob characters is checked literally, and is not committed" \
  eval '[ -f "$task/.env[x]" ] && [ "$rc" -eq 0 ] && git -C "$task" cat-file -e HEAD:change.txt && ! git -C "$task" cat-file -e "HEAD:.env[x]" 2>/dev/null'

# --- safety of this test -------------------------------------------------------------
# Run from inside another repository with no usable temp folder, this test must stop
# before writing anything.
victim="$tmp/victim"
mkdir -p "$victim" || abort "mkdir victim"
( cd "$victim" && git init -q . && echo original > keep.txt && git add keep.txt && git commit -q -m victim ) || abort "victim repository"
head_before="$(sha "$victim" HEAD)"
( cd "$victim" && TMPDIR="$tmp/missing" bash "$here/worktree.test.sh" ) > /dev/null 2>&1
rc=$?
check "no temp folder: stops without touching the current repository" \
  eval '[ "$rc" -ne 0 ] && [ "$(sha "$victim" HEAD)" = "$head_before" ] && [ -z "$(git -C "$victim" status --porcelain)" ] && [ -z "$(git -C "$victim" branch --list "task/*")" ]'

if [ "$fails" -eq 0 ]; then
  echo "all passed"
else
  echo "$fails failed"
  exit 1
fi
