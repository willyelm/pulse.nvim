#!/usr/bin/env bash
set -euo pipefail

if git rev-parse "${NEW_TAG}" >/dev/null 2>&1; then
  echo "Tag ${NEW_TAG} already exists; skipping tag creation."
  exit 0
fi

git config user.name "${GIT_USER_NAME:-github-actions[bot]}"
git config user.email "${GIT_USER_EMAIL:-github-actions[bot]@users.noreply.github.com}"
git tag -a "${NEW_TAG}" -m "Release ${NEW_TAG}"
git push origin "${NEW_TAG}"
