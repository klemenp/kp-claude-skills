#!/usr/bin/env bash
# Reject a commit whose staged change or message, or an exported tree, matches the
# operator's private denylist.
# The list holds terms that must never reach this repository (it is published as a
# snapshot), and it lives outside the repo so the list itself is never committed.
#
# Usage: check-denylist.sh staged           the staged change: added lines and paths
#        check-denylist.sh message <file>   a commit message file
#        check-denylist.sh tree <dir>       every file under a directory
#
# Denylist: the file named by $KP_SKILLS_DENYLIST, else ~/.config/kp-skills/denylist.
# One extended regular expression per line, matched case-insensitively; blank lines and
# lines starting with `#` are ignored. A missing or empty file means nothing to check.
#
# staged:  every added line of the staged diff and every staged path that still exists
#          after the commit. Removed lines and deleted files are not checked, so a commit
#          that removes a term passes.
# message: every line that does not start with `#` (git drops those), up to the scissors
#          line a verbose commit puts above its diff.
# tree:    every line of every regular file under <dir>, the target of every symlink,
#          and every file path relative to it; a `.git` directory is skipped, a binary
#          file is searched as text, and so is a line that is not valid UTF-8.
#          `.github/scripts/export-mirror.sh` checks a snapshot with it.
#
# A match prints `<where>: matches denylist line <n>` on stderr, where <where> is
# `<path>:<new line number>`, `<path>` or `commit message line <n>`, and <n> is the
# physical line number in the denylist. The term and the matched text are never printed
# (a headless run's log may be shared); a path match prints the path, which it has to.
#
# Exit: 0 nothing matched, or no denylist · 1 a match · 2 bad arguments or an invalid
# regex in the denylist (named by its line number).
set -euo pipefail

usage() {
  echo "usage: check-denylist.sh staged | message <file> | tree <dir>" >&2
  exit 2
}

mode="${1:-}"
case "$mode" in
  staged) [ $# -eq 1 ] || usage ;;
  message | tree) [ $# -eq 2 ] || usage ;;
  *) usage ;;
esac

denylist="${KP_SKILLS_DENYLIST:-$HOME/.config/kp-skills/denylist}"
[ -s "$denylist" ] || exit 0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Line i of `texts` is checked; line i of `locations` says where it came from.
texts="$work/texts"
locations="$work/locations"
: >"$texts"
: >"$locations"

if [ "$mode" = staged ]; then
  git -c core.quotepath=off diff --cached --no-color --no-ext-diff -U0 \
    --src-prefix=a/ --dst-prefix=b/ |
    awk -v texts="$texts" -v locations="$locations" '
      # `+++ ` names the file only in a file header: an added line `++ …` shows as
      # `+++ …` inside a hunk.
      /^diff --git / { in_header = 1; next }
      in_header && /^\+\+\+ / { path = substr($0, 7); next }
      /^@@ / {
        in_header = 0
        split($3, added, ",")
        line = substr(added[1], 2) + 0
        next
      }
      /^\+/ {
        print substr($0, 2) >>texts
        print path ":" line >>locations
        line++
      }
    '
  git -c core.quotepath=off diff --cached --name-only --diff-filter=d |
    while IFS= read -r path; do
      printf '%s\n' "$path" >>"$texts"
      printf '%s\n' "$path" >>"$locations"
    done
elif [ "$mode" = tree ]; then
  tree_dir="$2"
  [ -d "$tree_dir" ] || { echo "check-denylist.sh: no such directory: $tree_dir" >&2; exit 2; }
  (cd "$tree_dir" && find . -name .git -prune -o \( -type f -o -type l \) -print) |
    sed 's|^\./||' | LC_ALL=C sort |
    while IFS= read -r path; do
      printf '%s\n' "$path" >>"$texts"
      printf '%s\n' "$path" >>"$locations"
      # `git archive` exports a symlink as a link, so its target text is its content.
      if [ -L "$tree_dir/$path" ]; then
        readlink "$tree_dir/$path" >>"$texts"
        printf '%s\n' "$path:1" >>"$locations"
        continue
      fi
      # awk numbers the lines and survives a last line with no newline. BSD awk ends a
      # record at a NUL byte and can fail on invalid UTF-8, so NULs become spaces first
      # and both run in the C locale: a binary file is still searched to its end.
      LC_ALL=C tr '\000' ' ' <"$tree_dir/$path" |
        LC_ALL=C awk -v path="$path" -v texts="$texts" -v locations="$locations" '
          { print >>texts; print path ":" NR >>locations }
        '
    done
else
  message_file="$2"
  [ -f "$message_file" ] || { echo "check-denylist.sh: no such file: $message_file" >&2; exit 2; }
  # A verbose commit appends its diff below the scissors line, which git drops.
  awk -v texts="$texts" -v locations="$locations" '
    /^# -+ >8 -+$/ { exit }
    !/^#/ {
      print >>texts
      print "commit message line " NR >>locations
    }
  ' "$message_file"
fi

# matching_lines <term>: grep's `<n>:<text>` for every line of `texts` the term matches.
# In tree mode the C locale is searched too and the two unioned: BSD grep in a UTF-8
# locale never matches a line holding invalid UTF-8, and the locale pass keeps the
# case-folding of non-ASCII terms.
matching_lines() {
  grep -a -n -i -E -e "$1" "$texts" || true
  if [ "$mode" = tree ]; then
    LC_ALL=C grep -a -n -i -E -e "$1" "$texts" || true
  fi
}

matched=0
denylist_line=0
while IFS= read -r term || [ -n "$term" ]; do
  denylist_line=$((denylist_line + 1))
  case "$term" in '' | '#'*) continue ;; esac
  status=0
  grep -E -e "$term" </dev/null >/dev/null 2>&1 || status=$?
  if [ "$status" -ge 2 ]; then
    echo "check-denylist.sh: invalid regular expression on line $denylist_line of $denylist" >&2
    exit 2
  fi
  while IFS=: read -r text_line _; do
    echo "$(sed -n "${text_line}p" "$locations"): matches denylist line $denylist_line" >&2
    matched=1
  done < <(matching_lines "$term" | cut -d: -f1 | sort -un)
done <"$denylist"

[ "$matched" -eq 1 ] || exit 0
if [ "$mode" = tree ]; then
  echo "Tree rejected by the denylist at $denylist." >&2
else
  echo "Commit rejected by the denylist at $denylist. Override only when you mean it: git commit --no-verify" >&2
fi
exit 1
