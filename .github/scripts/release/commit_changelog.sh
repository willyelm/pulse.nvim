#!/usr/bin/env bash
set -euo pipefail

git config user.name "${GIT_USER_NAME:-github-actions[bot]}"
git config user.email "${GIT_USER_EMAIL:-github-actions[bot]@users.noreply.github.com}"

if git diff --quiet -- CHANGELOG.md; then
  exit 0
fi

git add CHANGELOG.md
git commit -m "chore(changelog): update for ${NEW_TAG} [skip ci]"
git push origin "HEAD:${GITHUB_REF_NAME}"
