#!/usr/bin/env bash
# Make one snapshot commit of this repository in a local clone of its public mirror.
# This repository is private and stays the working repository; the mirror is a separate,
# read-only repository that only ever receives these snapshots.
#
# Usage: export-mirror.sh <mirror-clone> [--ref <commit-ish>]
#
# <mirror-clone> is the working tree of a local clone of the mirror. --ref defaults to
# origin/main. The source is the repository this script lives in, or $KP_EXPORT_SOURCE.
#
# The tree at <ref> is exported, the paths listed in .github/mirror-exclude (as it reads
# at <ref>: one path per line, `#` comments and blank lines ignored; a listed path that
# does not exist, is absolute or has a `..` segment is an error) are removed, and the
# result is checked against the denylist with .githooks/check-denylist.sh. A match stops
# the export: nothing is rewritten here, the fix belongs in this repository. Otherwise
# the mirror clone's tracked content is replaced by the result and committed as
# `Snapshot of <short sha> (<date>)` with the mirror clone's own identity.
#
# It makes no network call. It never fetches, never pushes and never changes a
# repository's visibility: pushing the snapshot is the operator's own step.
#
# Refused, changing nothing: a missing or empty denylist ($KP_SKILLS_DENYLIST, else
# ~/.config/kp-skills/denylist) — an export with nothing to check against is not allowed;
# a mirror clone that is not a git working tree, is the source itself, or is not clean; a
# mirror `user.email` that is not a GitHub noreply address; a <ref> that does not resolve.
#
# Exit: 0 committed, or the mirror already matches · 1 refused, or a denylist match ·
# 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: export-mirror.sh <mirror-clone> [--ref <commit-ish>]" >&2
  exit 2
}

refuse() {
  echo "export-mirror.sh: $1" >&2
  exit 1
}

mirror=""
ref="origin/main"
while [ $# -gt 0 ]; do
  case "$1" in
    --ref)
      [ $# -ge 2 ] || usage
      ref="$2"
      shift 2
      ;;
    -*) usage ;;
    *)
      [ -z "$mirror" ] || usage
      mirror="$1"
      shift
      ;;
  esac
done
[ -n "$mirror" ] || usage

source_repo="${KP_EXPORT_SOURCE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
check_denylist="$source_repo/.githooks/check-denylist.sh"
denylist="${KP_SKILLS_DENYLIST:-$HOME/.config/kp-skills/denylist}"
NOREPLY_SUFFIX="@users.noreply.github.com"

[ -s "$denylist" ] || refuse "no denylist at $denylist; an export is never made unchecked"

mirror_top=$(git -C "$mirror" rev-parse --show-toplevel 2>/dev/null) \
  || refuse "$mirror is not a git working tree"
source_top=$(git -C "$source_repo" rev-parse --show-toplevel)
[ "$mirror_top" != "$source_top" ] || refuse "the mirror clone is the source repository itself"
[ -z "$(git -C "$mirror_top" status --porcelain)" ] \
  || refuse "$mirror has uncommitted or untracked files"
mirror_email=$(git -C "$mirror_top" config user.email || true)
case "$mirror_email" in
  *"$NOREPLY_SUFFIX") ;;
  *) refuse "the mirror clone's user.email must end in $NOREPLY_SUFFIX" ;;
esac
commit=$(git -C "$source_repo" rev-parse --verify --quiet "$ref^{commit}") \
  || refuse "$ref does not resolve to a commit in $source_repo"
short_sha=$(git -C "$source_repo" rev-parse --short "$commit")
commit_date=$(git -C "$source_repo" show -s --format=%cs "$commit")

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tree="$work/tree"
mkdir "$tree"
git -C "$source_repo" archive "$commit" | tar -x -C "$tree"

exclude_list="$tree/.github/mirror-exclude"
if [ -f "$exclude_list" ]; then
  while IFS= read -r path || [ -n "$path" ]; do
    case "$path" in '' | '#'*) continue ;; esac
    case "/$path/" in
      //* | */../*) refuse ".github/mirror-exclude names $path, which is absolute or contains .." ;;
    esac
    [ -e "$tree/$path" ] \
      || refuse ".github/mirror-exclude names $path, which does not exist at $short_sha"
    rm -r "${tree:?}/$path"
  done <"$exclude_list"
fi

"$check_denylist" tree "$tree" || exit 1
message="$work/message"
echo "Snapshot of $short_sha ($commit_date)" >"$message"
"$check_denylist" message "$message" || exit 1

# Replace the mirror's tracked content, so a file deleted upstream disappears there too.
if [ -n "$(git -C "$mirror_top" ls-files)" ]; then
  git -C "$mirror_top" rm -r -q .
fi
cp -R "$tree/." "$mirror_top/"
git -C "$mirror_top" add -A

if git -C "$mirror_top" rev-parse --verify --quiet HEAD >/dev/null \
  && git -C "$mirror_top" diff --cached --quiet; then
  echo "export-mirror.sh: mirror already matches $short_sha"
  exit 0
fi

# The identity must be the mirror clone's configured noreply one, so identity variables
# from the environment, which git would prefer, are dropped.
env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
  git -C "$mirror_top" commit -q -F "$message"
file_count=$(git -C "$mirror_top" ls-files | wc -l | tr -d ' ')
echo "export-mirror.sh: committed $(git -C "$mirror_top" rev-parse --short HEAD) in $mirror: snapshot of $short_sha, $file_count files"
echo "Not pushed. Review with: git -C $mirror show --stat"
