#!/bin/bash
# Worktrees for parallel sessions, see "Parallel work" in .claude/rules/nogps-workflow.md.
#   add <name> [base]  New branch feature/<name> from <base> (default origin/master) in <ws>/worktrees/<name>, where
#                      <ws> is the folder that holds the main checkout. Submodules come from the main checkout, with
#                      no network. Prints the path on stdout.
#   remove <path>      Remove a clean worktree. Its branch is deleted if it is merged or was never pushed, and all
#                      its commits are on a remote.
#   list               Worktrees and the size of their build dirs.
#   hook-create        Claude Code WorktreeCreate hook: JSON with "name" on stdin, the path on stdout.
#   hook-remove        Claude Code WorktreeRemove hook: JSON with "worktree_path" on stdin.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMON_DIR="$(git -C "$SELF" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON_DIR")"
WS="$(dirname "$MAIN")"
# Gitignored local inputs that every checkout needs.
LINKED=(credentials trip-logs)

die() { echo "nogps_worktree: $*" >&2; exit 1; }

json_field() {  # <field>: a string field of the JSON on stdin.
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1 | sed 's/\\\\/\\/g'
}

check_ccache() {
  command -v ccache >/dev/null || return 0
  local base hash dir
  dir=$(ccache --get-config cache_dir)
  case "$dir" in
    */Library/Caches/*)
      echo "nogps_worktree: macOS reclaims ~/Library/Caches on a full disk, so ccache loses its cache there:" >&2
      # Not ~/.ccache: that directory switches ccache to its legacy config file, which drops base_dir, hash_dir
      # and max_size set below.
      # The move is skipped when the cache dir is not there yet: ccache creates it at the first compilation.
      echo "  mkdir -p ~/.cache; [ -d \"$dir\" ] && mv \"$dir\" ~/.cache/ccache" >&2
      echo "  ccache --set-config cache_dir=\"\$HOME/.cache/ccache\"" >&2 ;;
  esac
  base=$(ccache --get-config base_dir)
  hash=$(ccache --get-config hash_dir)
  if [ "$base" != "$WS" ] || [ "$hash" != false ]; then
    echo "nogps_worktree: ccache misses in a new checkout until it is set up once:" >&2
    echo "  ccache --set-config base_dir=$WS && ccache --set-config hash_dir=false && ccache --set-config max_size=20G" >&2
  fi
}

# Clones the submodules of <dir> from the same repo in the main checkout, <src> its git dir: objects come through
# alternates, so there is no network and no copy. The clone's origin is then set back to the real URL.
init_submodules() {  # <dir> <src>
  local dir="$1" src="$2" key path name ref url local_url
  [ -f "$dir/.gitmodules" ] || return 0
  while read -r key path; do
    name=${key#submodule.}
    name=${name%.path}
    ref="$src/modules/$name"
    url=$(git config -f "$dir/.gitmodules" "submodule.$name.url")
    if [ -d "$ref" ]; then
      # init first: with the URL given by -c it would not write the submodule into the config. A file:// URL makes
      # the clone take objects through --reference instead of hardlinking packs that the main checkout may repack.
      git -C "$dir" submodule init -- "$path" >&2
      # On Windows git gives C:/... paths, which need file:///C:/...
      [[ "$ref" == /* ]] && local_url="file://$ref" || local_url="file:///$ref"
      git -C "$dir" -c protocol.file.allow=always -c "submodule.$name.url=$local_url" \
        submodule update --reference "$ref" -- "$path" >&2
      git -C "$dir/$path" remote set-url origin "$url"
      init_submodules "$dir/$path" "$ref"
    else
      echo "nogps_worktree: $path is not in the main checkout, cloning it from $url" >&2
      git -C "$dir" submodule update --init --recursive -- "$path" >&2
    fi
  done < <(git config -f "$dir/.gitmodules" --get-regexp '^submodule\..*\.path$')
}

add() {  # <name> [base]
  local name="${1:?name}" base="${2:-origin/master}"
  local wt="$WS/worktrees/$name"
  [ -e "$wt" ] && die "$wt already exists"
  git -C "$MAIN" worktree add --no-track -b "feature/$name" "$wt" "$base" >&2
  init_submodules "$wt" "$COMMON_DIR"
  local f
  for f in "${LINKED[@]}"; do
    [ -e "$MAIN/$f" ] && ln -s "$MAIN/$f" "$wt/$f"
  done
  check_ccache
  echo "$wt"
}

remove() {  # <path>
  local wt
  wt="$(cd "${1:?path}" && pwd -P)"
  [ "$wt" = "$MAIN" ] && die "$wt is the main checkout"
  git -C "$MAIN" worktree list --porcelain | grep -qxF "worktree $wt" || die "$wt is not a worktree of $MAIN"
  local dirty f
  # The links are not ignored in a branch older than the /trip-logs rule of .gitignore.
  dirty=$(git -C "$wt" status --porcelain --ignore-submodules=none -- . "${LINKED[@]/#/:!}")
  [ -n "$dirty" ] && die "$wt has uncommitted changes:"$'\n'"$dirty"
  local branch
  branch=$(git -C "$wt" branch --show-current)
  # The links go first: --force removes the ignored files too, and must not follow them.
  for f in "${LINKED[@]}"; do
    [ -L "$wt/$f" ] && rm "$wt/$f"
  done
  # git refuses to remove a worktree with submodules without --force; the status check above stands in for it.
  git -C "$MAIN" worktree remove --force "$wt"
  [ -n "$branch" ] || return 0
  if [ -n "$(git -C "$MAIN" rev-list "$branch" --not --remotes)" ]; then
    echo "nogps_worktree: kept $branch, it has commits that are on no remote" >&2
  elif git -C "$MAIN" merge-base --is-ancestor "$branch" origin/master ||
    ! git -C "$MAIN" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
    git -C "$MAIN" branch -D "$branch" >&2
  else
    echo "nogps_worktree: kept $branch, it is pushed and not merged" >&2
  fi
}

list() {
  local line wt d
  git -C "$MAIN" worktree list
  while read -r line; do
    wt=${line#worktree }
    for d in "$wt"/build-*/; do
      if [ -d "$d" ]; then du -sh "$d"; fi
    done
  done < <(git -C "$MAIN" worktree list --porcelain | grep '^worktree ')
}

case "${1:-}" in
  add) shift; add "$@" ;;
  remove) shift; remove "$@" ;;
  list) list ;;
  hook-create) add "$(json_field name)" ;;
  hook-remove) remove "$(json_field worktree_path)" ;;
  *) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
