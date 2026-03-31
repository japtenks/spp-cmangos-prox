#!/usr/bin/env bash
# rebase_playerbots_fork.sh
#
# BACKUP USE ONLY — the build chain no longer uses this fork.
# Launcher.sh clones from cmangos/playerbots (upstream) directly and applies
# patches from spp-cmangos-prox/patches/playerbots/ at build time.
#
# This script keeps japtenks/playerbots in sync as a human-readable reference
# and fallback. Run it if you want the fork to reflect current upstream + patches,
# e.g. for code review or if the patch approach ever needs to be swapped back.
#
# Remotes expected in C:\git\playerbots:
#   origin   -> https://github.com/japtenks/playerbots.git  (our fork, backup)
#   upstream -> https://github.com/cmangos/playerbots.git   (ike3 source)
#
# Our patches (as of 2026-03-30):
#   1. PlayerbotAI.cpp     — load DB strategy overrides for all bots (guild flavor)
#   2. DropQuestAction.cpp — only block alts from CleanQuestLog, not random bots

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../playerbots" 2>/dev/null && pwd)"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "ERROR: Could not find playerbots repo at: $REPO_DIR"
  echo "Adjust REPO_DIR at the top of this script if your layout differs."
  exit 1
fi

cd "$REPO_DIR"

echo "==> Fetching upstream (cmangos/playerbots)..."
git fetch upstream

BEFORE=$(git rev-parse --short HEAD)
UPSTREAM_HEAD=$(git rev-parse --short upstream/master)

if git merge-base --is-ancestor upstream/master HEAD; then
  echo "Already up to date with upstream ($UPSTREAM_HEAD). Nothing to do."
  exit 0
fi

echo "==> Rebasing master onto upstream/master..."
git rebase upstream/master

AFTER=$(git rev-parse --short HEAD)

echo "==> Pushing to origin (japtenks/playerbots)..."
git push --force-with-lease origin master

echo ""
echo "Done."
echo "  Before : $BEFORE"
echo "  After  : $AFTER"
echo "  Upstream: $UPSTREAM_HEAD"
echo ""
echo "Fork updated. The build chain uses patch files — no server action needed."
echo "To update patch files themselves: regenerate from fork commits with git format-patch."
