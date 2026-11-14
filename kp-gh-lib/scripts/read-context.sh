#!/usr/bin/env bash
# Print exactly the bounded context of a coding item (kp-gh-lib/NOTES.md § Coding item
# body): the item without its human-only fence, one goal frame per referenced spec repo,
# each `spec:` section, each `code:` file and each `decision:` resolution. Nothing else.
#
# Usage: read-context.sh [--code-root <dir>] <owner/repo> <issue-number>
#        read-context.sh [--code-root <dir>] --body-file <path> --repo <owner/repo>
#
# Every block is printed under `===== <kind>: <ref> (<bytes> B) =====`, in the order
# item, goal-frame, spec, code, decision, and the output ends with
# `===== total: <bytes> B, <n> blocks =====`. `code:` paths are read from --code-root
# (default: the current directory). Section line ranges come from spec-index.py; spec
# file content is cached beside its index, per commit.
#
# REST only; every gh call is bounded by a timeout. A filed item's comments are never
# fetched — only a `decision:` line reads comments, of the decision issue.
#
# Exit: 0 all resolved · 1 GitHub or fetch failure (nothing printed) · 2 bad arguments ·
#       3 something unresolved (unknown anchor, missing file, no goal frame, malformed
#         context line); the output is still printed and each problem goes to stderr.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: read-context.sh [--code-root <dir>] <owner/repo> <issue-number>
       read-context.sh [--code-root <dir>] --body-file <path> --repo <owner/repo>
EOF
  exit 2
}

code_root=.
body_file=
repo=
positional=()
while [ $# -gt 0 ]; do
  case $1 in
    --code-root) [ $# -ge 2 ] || usage; code_root=$2; shift 2 ;;
    --body-file) [ $# -ge 2 ] || usage; body_file=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) positional+=("$1"); shift ;;
  esac
done

if [ -n "$body_file" ]; then
  if [ ${#positional[@]} -ne 0 ] || [ -z "$repo" ]; then usage; fi
  [ -f "$body_file" ] || { echo "read-context.sh: no such body file: $body_file" >&2; exit 2; }
  issue=
else
  if [ ${#positional[@]} -ne 2 ] || [ -n "$repo" ]; then usage; fi
  repo=${positional[0]}
  issue=${positional[1]}
  [[ $issue =~ ^[0-9]+$ ]] || usage
fi
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[ -d "$code_root" ] || { echo "read-context.sh: no such code root: $code_root" >&2; exit 2; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Issue bodies never reach a shell: Python runs gh as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/read_context.py "$script_dir" "$repo" "$issue" "$body_file" "$code_root" </dev/null
