#!/usr/bin/env bash
# Print one `##` or `###` section of a markdown file — by default kp-gh-lib/NOTES.md —
# so a skill following a `§ *Name*` reference loads that section, not the whole file.
#
# Usage:
#   notes-section.sh [--file <path>] <heading>
#
# A heading line is a `## ` or `### ` line outside a fenced code block. A fence line's
# first non-space characters are three backticks or three tildes; a backtick block is
# closed only by a backtick fence line, a tilde block only by a tilde fence line.
# <heading> matches a heading line whose text (leading `#`s, the space and trailing
# whitespace removed) equals <heading>, or starts with <heading> followed by ` (` — so
# `Waiting in a headless session` matches `## Waiting in a headless session (family
# convention)`. Comparison is literal and case-sensitive.
#
# Prints the matched heading line and every line up to, not including, the next heading
# of the same or a higher level (a `# ` line ends any section; `####` lines are content).
#
# Exit: 0 one match printed · 1 no match, or more than one (stderr lists each matching
# heading line with its line number; stdout is empty) · 2 bad arguments or an
# unreadable file.
set -euo pipefail

usage() {
  echo "usage: notes-section.sh [--file <path>] <heading>" >&2
  exit 2
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file="$script_dir/../NOTES.md"
heading=
heading_given=false

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || usage
      file=$2
      shift 2
      ;;
    -*)
      usage
      ;;
    *)
      [ "$heading_given" = false ] || usage
      heading=$1
      heading_given=true
      shift
      ;;
  esac
done

[ "$heading_given" = true ] && [ -n "$heading" ] || usage
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
  echo "notes-section.sh: cannot read file: $file" >&2
  exit 2
fi

# The heading goes through ENVIRON, not -v, so awk applies no escape processing to it.
NOTES_HEADING="$heading" awk '
  function fence_char(line) {
    if (line ~ /^[ \t]*```/) return "`"
    if (line ~ /^[ \t]*~~~/) return "~"
    return ""
  }
  function heading_level(line) {
    if (substr(line, 1, 4) == "### ") return 3
    if (substr(line, 1, 3) == "## ") return 2
    if (substr(line, 1, 2) == "# ") return 1
    return 0
  }
  BEGIN { wanted = ENVIRON["NOTES_HEADING"]; open_fence = ""; matches = 0 }
  {
    lines[NR] = $0
    level[NR] = 0
    fence = fence_char($0)
    if (fence != "") {
      if (open_fence == "") open_fence = fence
      else if (open_fence == fence) open_fence = ""
      next
    }
    if (open_fence != "") next
    level[NR] = heading_level($0)
    if (level[NR] < 2) next
    text = $0
    sub(/^#+ /, "", text)
    sub(/[ \t]+$/, "", text)
    if (text == wanted || substr(text, 1, length(wanted) + 2) == wanted " (") {
      matches++
      match_line[matches] = NR
    }
  }
  END {
    if (matches == 0) {
      print "notes-section.sh: no heading matches: " wanted > "/dev/stderr"
      exit 1
    }
    if (matches > 1) {
      print "notes-section.sh: " matches " headings match: " wanted > "/dev/stderr"
      for (i = 1; i <= matches; i++) print match_line[i] ": " lines[match_line[i]] > "/dev/stderr"
      exit 1
    }
    start = match_line[1]
    print lines[start]
    for (n = start + 1; n <= NR; n++) {
      if (level[n] > 0 && level[n] <= level[start]) break
      print lines[n]
    }
  }
' "$file"
