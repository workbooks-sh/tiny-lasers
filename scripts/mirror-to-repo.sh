#!/usr/bin/env bash
# Mirror tiny-lasers/ from the workbooks monorepo (source of truth) to the standalone
# repo https://github.com/workbooks-sh/tiny-lasers.git.
#
# Why not `git subtree push`? The monorepo has ~3544 commits and an 8.3 GB history;
# `git subtree split` re-walks ALL of it every invocation (minutes). `git filter-repo
# --subdirectory-filter` extracts only the 27 tiny-lasers commits in ~10s, with
# deterministic SHAs (re-runs fast-forward; no force needed unless monorepo history
# is rewritten). The standalone repo is a one-way published mirror — make changes in
# the monorepo, then run this.
set -euo pipefail

REMOTE="https://github.com/workbooks-sh/tiny-lasers.git"
MONO="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v git-filter-repo >/dev/null 2>&1 || { echo "git-filter-repo not installed (brew install git-filter-repo)"; exit 1; }

git clone --no-hardlinks --quiet "$MONO" "$TMP/x"
cd "$TMP/x"
git filter-repo --subdirectory-filter tiny-lasers --force >/dev/null
git remote add origin "$REMOTE"
git branch -M main
git push origin main "$@"
echo "mirrored tiny-lasers/ -> $REMOTE (main @ $(git rev-parse --short HEAD))"
