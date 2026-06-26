#!/usr/bin/env bash
#
# bootstrap-new-repo.sh — turn this folder into a brand-new git repository with
# clean history (no ABC-Durham-Hook lineage) and, optionally, create + push the
# remote on GitHub.
#
# USAGE (run on your Mac):
#   1. Copy this `GolfLaunchMonitor/` folder OUT of the ABC-Durham-Hook checkout
#      to its own location, e.g.:
#         cp -R ABC-Durham-Hook/GolfLaunchMonitor ~/Developer/GolfLaunchMonitor
#   2. cd ~/Developer/GolfLaunchMonitor
#   3. ./bootstrap-new-repo.sh [repo-name] [github-org-or-user] [--public]
#
# With no GitHub CLI it just creates the local repo + first commit and prints the
# remaining push commands.

set -euo pipefail

REPO_NAME="${1:-golf-launch-monitor}"
OWNER="${2:-}"
VISIBILITY="--private"
[[ "${3:-}" == "--public" ]] && VISIBILITY="--public"

# Refuse to run while nested inside another repo's working tree, which would make
# the parent repo swallow this one. Require a clean, standalone copy.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ ! -d .git ]]; then
  echo "✋ This folder is inside another git repository."
  echo "   Copy GolfLaunchMonitor/ out of the ABC-Durham-Hook checkout first, then re-run."
  exit 1
fi

echo "▶︎ Initializing fresh repository (clean history)…"
rm -rf .git
git init -b main >/dev/null
git add .
git commit -m "Initial commit: Golf Launch Monitor (SwingKinematicsEngine + macOS app)" >/dev/null
echo "✅ Local repo created with a single clean commit."

if command -v gh >/dev/null 2>&1 && [[ -n "$OWNER" ]]; then
  echo "▶︎ Creating remote ${OWNER}/${REPO_NAME} (${VISIBILITY#--}) and pushing…"
  gh repo create "${OWNER}/${REPO_NAME}" "$VISIBILITY" --source=. --remote=origin --push
  echo "✅ Pushed to https://github.com/${OWNER}/${REPO_NAME}"
else
  cat <<EOF

Next steps (no GitHub CLI / no owner given):
  # create an empty repo named '${REPO_NAME}' on github.com, then:
  git remote add origin git@github.com:<owner>/${REPO_NAME}.git
  git push -u origin main
EOF
fi
