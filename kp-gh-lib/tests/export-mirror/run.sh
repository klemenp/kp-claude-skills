#!/usr/bin/env bash
# Drives .github/scripts/export-mirror.sh between a temporary source repository and a
# temporary mirror clone, against a temp denylist of invented terms: a clean snapshot,
# a no-change run, an edit plus a deletion, a term in a file and in a path, a missing
# denylist, a mirror identity that is not a noreply address, a dirty mirror, a stale
# exclude entry, an exclude entry that is absolute or has a `..` segment, and that
# nothing is ever pushed to the mirror's `origin`. Then the `tree` mode of
# .githooks/check-denylist.sh directly, including a line with a NUL byte, a line with
# invalid UTF-8 and a symlink. $HOME is an empty temp directory,
# so the operator's own denylist is never read. Offline — local git only — so this runs
# in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home"
export HOME="$work/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export KP_SKILLS_DENYLIST="$work/denylist"
noreply='1+fixture@users.noreply.github.com'
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# The source: a few files, an exclude list naming one of them, and the two real scripts.
source_repo="$work/source"
git init -q -b main "$source_repo"
mkdir -p "$source_repo/.github/scripts" "$source_repo/.githooks" "$source_repo/docs"
cp "$repo_root/.github/scripts/export-mirror.sh" "$source_repo/.github/scripts/"
cp "$repo_root/.githooks/check-denylist.sh" "$source_repo/.githooks/"
printf 'A readme\n' >"$source_repo/README.md"
printf 'kept\n' >"$source_repo/docs/guide.md"
printf 'going away\n' >"$source_repo/docs/old.md"
printf 'private board id\n' >"$source_repo/private.json"
printf '# not for the mirror\nprivate.json\n' >"$source_repo/.github/mirror-exclude"
git -C "$source_repo" add -A
git -C "$source_repo" commit -q -m "Start"
export KP_EXPORT_SOURCE="$source_repo"
script="$source_repo/.github/scripts/export-mirror.sh"

# The mirror clone, with a bare repository as its origin that must stay empty.
origin="$work/origin.git"
git init -q --bare "$origin"
mirror="$work/mirror"
git init -q -b main "$mirror"
git -C "$mirror" remote add origin "$origin"
git -C "$mirror" config user.name "Fixture Author"
git -C "$mirror" config user.email "$noreply"

printf 'forbiddenco\n' >"$KP_SKILLS_DENYLIST"

# run: exports HEAD of the source into the mirror, leaving stdout, stderr and
# the exit status in $out, $err and $status.
run() {
  out=$("$script" "$mirror" --ref HEAD 2>"$work/stderr")
  status=$?
  err=$(cat "$work/stderr")
  echo "   export-mirror.sh -> exit $status${out:+: $out}${err:+ | stderr: $err}"
}

commits() {
  git -C "$mirror" rev-list --count HEAD 2>/dev/null || echo 0
}

source_commit() {
  git -C "$source_repo" add -A
  git -C "$source_repo" commit -q -m "$1"
}

# refused <label>: the last run exited 1 and added no commit to the mirror.
refused() {
  if [ "$status" -eq 1 ] && [ "$(commits)" -eq "$before" ] \
    && [ -z "$(git -C "$mirror" status --porcelain)" ]; then
    check "$1" ok
  else
    check "$1" "MISMATCH (exit $status, commits $(commits), want exit 1 and $before)"
  fi
}

# 1. A clean snapshot.
run
short=$(git -C "$source_repo" rev-parse --short HEAD)
day=$(git -C "$source_repo" show -s --format=%cs HEAD)
expected_files=$'.githooks/check-denylist.sh\n.github/mirror-exclude\n.github/scripts/export-mirror.sh\nREADME.md\ndocs/guide.md\ndocs/old.md'
if [ "$status" -eq 0 ] && [ "$(commits)" -eq 1 ] \
  && [ "$(git -C "$mirror" ls-files | LC_ALL=C sort)" = "$expected_files" ] \
  && [ "$(git -C "$mirror" log -1 --format=%s)" = "Snapshot of $short ($day)" ] \
  && [ "$(git -C "$mirror" log -1 --format=%ae)" = "$noreply" ] \
  && [[ $out == *"Not pushed."* ]]; then
  check "clean snapshot" ok
else
  check "clean snapshot" MISMATCH
fi

# 2. Nothing changed.
run
if [ "$status" -eq 0 ] && [ "$(commits)" -eq 1 ] && [[ $out == *"already matches $short"* ]]; then
  check "no change, no commit" ok
else
  check "no change, no commit" MISMATCH
fi

# 3. An edit and a deletion upstream.
printf 'kept, edited\n' >"$source_repo/docs/guide.md"
git -C "$source_repo" rm -q docs/old.md
source_commit "Edit and delete"
run
if [ "$status" -eq 0 ] && [ "$(commits)" -eq 2 ] && [ ! -e "$mirror/docs/old.md" ] \
  && [ "$(cat "$mirror/docs/guide.md")" = "kept, edited" ]; then
  check "edit and deletion carried over" ok
else
  check "edit and deletion carried over" MISMATCH
fi

# 4. A denylisted term in a file.
before=$(commits)
printf 'line one\nmade for ForbiddenCo\n' >"$source_repo/docs/client.md"
source_commit "Add a client note"
run
if [[ $err == *"docs/client.md:2: matches denylist line 1"* ]] && ! grep -qi forbiddenco <<<"$err$out"; then
  refused "term in a file"
else
  check "term in a file" "MISMATCH (stderr does not name docs/client.md:2, or shows the term)"
fi
git -C "$source_repo" rm -q docs/client.md
source_commit "Remove the client note"

# 5. A denylisted term in a path.
printf 'harmless\n' >"$source_repo/docs/forbiddenco-plan.md"
source_commit "Add a file with a telling name"
run
if [[ $err == *"docs/forbiddenco-plan.md: matches denylist line 1"* ]]; then
  refused "term in a path"
else
  check "term in a path" "MISMATCH (stderr does not name docs/forbiddenco-plan.md)"
fi
git -C "$source_repo" rm -q docs/forbiddenco-plan.md
source_commit "Remove it"

# 6. No denylist.
mv "$KP_SKILLS_DENYLIST" "$work/denylist.away"
run
refused "missing denylist"
mv "$work/denylist.away" "$KP_SKILLS_DENYLIST"

# 7. A mirror identity that would publish a real address.
git -C "$mirror" config user.email someone@example.invalid
run
refused "mirror email is not a noreply address"
git -C "$mirror" config user.email "$noreply"

# 8. A mirror with a stray file.
printf 'stray\n' >"$mirror/stray.txt"
run
if [ "$status" -eq 1 ] && [ "$(commits)" -eq "$before" ] && [ -e "$mirror/stray.txt" ]; then
  check "dirty mirror" ok
else
  check "dirty mirror" MISMATCH
fi
rm "$mirror/stray.txt"

# 9. An exclude entry that no longer exists.
printf 'gone.json\n' >>"$source_repo/.github/mirror-exclude"
source_commit "Exclude a path that is not there"
run
refused "stale exclude entry"

# 10. An exclude entry that could reach outside the export: absolute, or with `..`.
for entry in /README.md docs/../README.md; do
  printf 'private.json\n%s\n' "$entry" >"$source_repo/.github/mirror-exclude"
  source_commit "Exclude $entry"
  run
  if [[ $err == *"names $entry, which is absolute or contains .."* ]]; then
    refused "unsafe exclude entry $entry"
  else
    check "unsafe exclude entry $entry" "MISMATCH (stderr: $err)"
  fi
done

# 11. Nothing was ever pushed.
if [ -z "$(git -C "$origin" for-each-ref)" ]; then
  check "origin still empty" ok
else
  check "origin still empty" MISMATCH
fi

# 12. The tree mode on its own.
checker="$repo_root/.githooks/check-denylist.sh"
tree="$work/tree"
mkdir -p "$tree/sub" "$tree/.git"
printf 'fine\n' >"$tree/sub/a.txt"
printf 'forbiddenco in git internals\n' >"$tree/.git/config"
"$checker" tree "$tree" 2>"$work/stderr"
clean_status=$?
printf 'fine\nstill fine\nFORBIDDENCO here' >"$tree/sub/b.txt"
"$checker" tree "$tree" 2>"$work/stderr"
match_status=$?
err=$(cat "$work/stderr")
if [ "$clean_status" -eq 0 ] && [ "$match_status" -eq 1 ] \
  && [[ $err == *"sub/b.txt:3: matches denylist line 1"* ]] && [[ $err != *".git/config"* ]] \
  && [[ $err == *"Tree rejected by the denylist"* ]]; then
  check "tree mode" ok
else
  check "tree mode" "MISMATCH (clean $clean_status, match $match_status, stderr: $err)"
fi

# 13. A NUL byte does not hide the rest of its line from the tree mode.
rm "$tree/sub/b.txt"
printf 'x\0forbiddenco\n' >"$tree/sub/c.bin"
"$checker" tree "$tree" 2>"$work/stderr"
nul_status=$?
err=$(cat "$work/stderr")
if [ "$nul_status" -eq 1 ] && [[ $err == *"sub/c.bin:1: matches denylist line 1"* ]]; then
  check "NUL byte in tree mode" ok
else
  check "NUL byte in tree mode" "MISMATCH (exit $nul_status, stderr: $err)"
fi

# 14. A line with invalid UTF-8 is still searched (BSD grep in a UTF-8 locale skips it).
rm "$tree/sub/c.bin"
printf '\xff\xfe forbiddenco\n' >"$tree/sub/bad-utf8.txt"
"$checker" tree "$tree" 2>"$work/stderr"
utf8_status=$?
err=$(cat "$work/stderr")
if [ "$utf8_status" -eq 1 ] && [[ $err == *"sub/bad-utf8.txt:1: matches denylist line 1"* ]]; then
  check "invalid UTF-8 in tree mode" ok
else
  check "invalid UTF-8 in tree mode" "MISMATCH (exit $utf8_status, stderr: $err)"
fi

# 15. A symlink: its path and its target text are checked, and a dangling one is fine.
rm "$tree/sub/bad-utf8.txt"
ln -s ../missing-forbiddenco.txt "$tree/sub/link"
ln -s a.txt "$tree/sub/forbiddenco-link"
"$checker" tree "$tree" 2>"$work/stderr"
link_status=$?
err=$(cat "$work/stderr")
if [ "$link_status" -eq 1 ] && [[ $err == *"sub/link:1: matches denylist line 1"* ]] \
  && [[ $err == *"sub/forbiddenco-link: matches denylist line 1"* ]]; then
  check "symlink in tree mode" ok
else
  check "symlink in tree mode" "MISMATCH (exit $link_status, stderr: $err)"
fi

if [ "$failures" -eq 0 ]; then
  echo "all export-mirror checks passed"
else
  echo "$failures export-mirror check(s) failed"
  exit 1
fi
