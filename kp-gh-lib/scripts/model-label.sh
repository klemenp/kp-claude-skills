#!/usr/bin/env bash
# Split a model tier into a model and a reasoning effort.
#
# Usage:
#   model-label.sh <tier>
#
# <tier> is what follows `model:` in a label (a leading `model:` is accepted and
# dropped), or a plain model alias or full model name. When it ends in -low, -medium,
# -high, -xhigh or -max, that suffix (without the hyphen) is the effort and the rest is
# the model; otherwise the whole value is the model and the effort is empty. Suffixes
# match lower case only, and no model alias or full model name ends in one of them.
#
# Prints exactly one line:
#   model=<model> effort=<effort>
# e.g. `opus-high` → `model=opus effort=high`, `claude-opus-5-5` → `model=claude-opus-5-5 effort=`.
#
# Exit: 0 printed · 2 bad arguments (none, more than one, empty, or an empty model part).
set -euo pipefail

EFFORT_LEVELS=(low medium high xhigh max)

usage() {
  echo "usage: model-label.sh <tier>   (e.g. opus, opus-high, model:sonnet-low)" >&2
  exit 2
}

[ $# -eq 1 ] || usage
tier=${1#model:}

model=$tier
effort=
for level in "${EFFORT_LEVELS[@]}"; do
  case "$tier" in
    *-"$level")
      model=${tier%-"$level"}
      effort=$level
      break
      ;;
  esac
done

[ -n "$model" ] || usage
printf 'model=%s effort=%s\n' "$model" "$effort"
