#!/usr/bin/env bash
set -euo pipefail

latest_tag="$(git tag --list 'v*' --sort=-v:refname | head -n1 || true)"

if [[ -z "${latest_tag}" ]]; then
  create="true"
  bump="minor"
  new_tag="v0.1.0"
  notes_range="HEAD"
else
  range="${latest_tag}..HEAD"
  commit_subjects="$(git log "${range}" --no-merges --format='%s' | grep -Ev '^chore\(changelog\):' || true)"

  if [[ -z "${commit_subjects}" ]]; then
    create="false"
  else
    create="true"
  fi

  commits="$(git log "${range}" --format='%s%n%b' | grep -Ev '^chore\(changelog\):' || true)"
  bump="patch"

  if grep -Eq '^[a-zA-Z]+(\([^)]+\))?!:' <<< "${commits}" || grep -Eq 'BREAKING CHANGE:' <<< "${commits}"; then
    bump="major"
  elif grep -Eq '^feat(\([^)]+\))?:' <<< "${commits}"; then
    bump="minor"
  fi

  current="${latest_tag#v}"
  IFS='.' read -r major minor patch <<< "${current}"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"

  case "${bump}" in
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    patch)
      patch=$((patch + 1))
      ;;
  esac

  new_tag="v${major}.${minor}.${patch}"
  notes_range="${range}"
fi

echo "create=${create}" >> "${GITHUB_OUTPUT}"
echo "latest_tag=${latest_tag}" >> "${GITHUB_OUTPUT}"
echo "bump=${bump:-}" >> "${GITHUB_OUTPUT}"
echo "new_tag=${new_tag:-}" >> "${GITHUB_OUTPUT}"

if [[ "${create}" != "true" ]]; then
  exit 0
fi

new_items="$(
  git log --no-merges --format='%s' "${notes_range}" \
    | grep -Ev '^chore\(changelog\):' \
    | grep -E '^feat(\([^)]+\))?:' \
    | sed -E 's/^feat(\([^)]+\))?:[[:space:]]*//' || true
)"

changed_items="$(
  git log --no-merges --format='%s' "${notes_range}" \
    | grep -Ev '^chore\(changelog\):' \
    | grep -Ev '^feat(\([^)]+\))?:' || true
)"

{
  echo "release_notes<<EOF"
  echo "## [${new_tag#v}] - $(date +%F)"
  if [[ -n "${new_items}" ]]; then
    echo
    echo "### New"
    echo
    printf '%s\n' "${new_items}" | sed -E 's/^/- /'
  fi
  if [[ -n "${changed_items}" ]]; then
    echo
    echo "### Changed"
    echo
    printf '%s\n' "${changed_items}" | sed -E 's/^/- /'
  fi
  echo "EOF"
} >> "${GITHUB_OUTPUT}"
