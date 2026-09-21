#!/bin/sh
# changed-go-dirs.sh — list directories containing changed .go files.
#
# Change set = staged + unstaged + untracked files, plus commits on this
# branch since merge-base with origin/main (so amending a branch that
# already touched Go code still checks those packages).
#
# Output:
#   nothing        → no Go changes, callers should skip
#   ALL            → fallback: run full-repo checks (go.mod/go.sum/sqlc
#                    inputs changed, or merge-base unavailable)
#   otherwise      → one directory per line
#
# Escape hatch: MEMOH_FULL_CHECKS=1 forces ALL.

set -e

root=$(git rev-parse --show-toplevel)
cd "$root"

if [ "${MEMOH_FULL_CHECKS:-}" = "1" ]; then
  echo ALL
  exit 0
fi

base=$(git merge-base HEAD origin/main 2>/dev/null || true)

# go.mod/go.sum 影响所有包的解析；db/postgres 的 SQL 经 sqlc 生成 Go 代码，
# 这两类变化无法按目录归因，直接回退全量。
broad=$({
  git diff --name-only HEAD -- go.mod go.sum db/postgres 2>/dev/null
  git diff --name-only --cached -- go.mod go.sum db/postgres 2>/dev/null
  [ -n "$base" ] && git diff --name-only "$base"...HEAD -- go.mod go.sum db/postgres 2>/dev/null
} | sort -u)

if [ -n "$broad" ]; then
  echo ALL
  exit 0
fi

changed=$({
  git diff --name-only --diff-filter=ACMR HEAD -- '*.go' 2>/dev/null
  git diff --name-only --cached --diff-filter=ACMR -- '*.go' 2>/dev/null
  git ls-files --others --exclude-standard -- '*.go' 2>/dev/null
  [ -n "$base" ] && git diff --name-only --diff-filter=ACMR "$base"...HEAD -- '*.go' 2>/dev/null
} | sort -u)

if [ -z "$changed" ]; then
  exit 0
fi

echo "$changed" | xargs -n1 dirname | sort -u
