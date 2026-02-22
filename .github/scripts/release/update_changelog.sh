#!/usr/bin/env bash
set -euo pipefail

change_log_file="${CHANGELOG_FILE:-CHANGELOG.md}"
max_releases="${MAX_RELEASES:-15}"

notes_file="$(mktemp)"
printf '%s\n' "${RELEASE_NOTES}" > "${notes_file}"
cp "${notes_file}" RELEASE_NOTES.md

if [[ ! -f "${change_log_file}" ]]; then
  {
    echo "# Changelog"
    echo
    cat "${notes_file}"
  } > "${change_log_file}"
  exit 0
fi

header_file="$(mktemp)"
old_releases_file="$(mktemp)"
trimmed_releases_file="$(mktemp)"
new_file="$(mktemp)"

awk '
  /^## \[[0-9]/ { exit }
  { print }
' "${change_log_file}" > "${header_file}"

awk '
  found || /^## \[[0-9]/ {
    if (/^## \[[0-9]/) found=1
    if (found) print
  }
' "${change_log_file}" > "${old_releases_file}"

awk -v max_old="$((max_releases - 1))" '
  BEGIN { sections = 0 }
  /^## \[[0-9]/ {
    sections++
    if (sections > max_old) exit
  }
  { print }
' "${old_releases_file}" > "${trimmed_releases_file}"

{
  cat "${header_file}"
  echo
  cat "${notes_file}"
  echo
  cat "${trimmed_releases_file}"
} > "${new_file}"

mv "${new_file}" "${change_log_file}"
