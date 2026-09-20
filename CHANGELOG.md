# Changelog

## [Unreleased]

### Changed

- add per-picker config support with initial `files` options
- add `files.open_on_directory` to open Pulse files for `nvim .`







## [0.12.0] - 2026-09-20

### New

- list every buffer in the Buffers panel, most recently used first

## [0.11.0] - 2026-09-19

### New

- show git's error when history or status fails to load
- show the full message and timestamp in the commit preview
- show target path in add prompt

### Changed

- fix(ui): render diffs correctly around appended, inserted and deleted lines
- fix(git): follow the panel's project directory instead of nvim's cwd
- perf(git): skip the vim.fn call when stamping absolute paths
- fix(git): restore filetype detection for commit file diffs
- fix(git): keep git's stderr out of parsed output and time out stuck calls
- refactor(git): remove dead fields and a duplicate cache assignment
- refactor(display): share the addition and deletion highlights
- refactor(files): share the open and preview labels
- refactor(git): classify the enter action once
- refactor(navigators): share the jump and preview actions
- fix(git): name the revert action after git and handle new files and renames
- fix(files): read git status from the repo root so subdirectories and worktrees work
- perf(git): skip the numstat on idle polls when nothing changed
- fix(git): report restore failures
- fix(git): detect diff preview filetype from the file name
- refactor(git): move the diff blob reader next to its only user
- fix(git): use absolute paths for status rows so open and preview work from subdirectories
- fix(git): run git from the repo root so any cwd works
- fix: format API doc
- refactor(git): rename Git Status panel to Git
- fix(git): keep status and history in sync with git
- fix(git): keep diff preview current and accurate

## [0.10.1] - 2026-07-04

### Changed

- fix(files): match file paths when searching and add tree_view flag

## [0.10.0] - 2026-07-04

### New

- switch to rg --json for regecp match highlights and parsing (#3)

### Changed

- fix: improve internals of prompt mode
- fix: correct highlight matches and share preview guards
- refactor(git): improve status highlight, run numstat concurrently and share notify

## [0.9.0] - 2026-07-04

### New

- improve commit prompt mode

## [0.8.0] - 2026-07-04

### New

- add git stage/unstage and commit actions
- add prompt mode for panel actions

## [0.7.8] - 2026-07-03

### Changed

- fix: rename files_open to buffers and improve file preview for binary/big
  files

## [0.7.7] - 2026-05-25

### Changed

- fix(git): remove item from list when restore

## [0.7.6] - 2026-05-24

### Changed

- fix: improve workspace label layout

## [0.7.5] - 2026-05-24

### Changed

- fix: reorder restore action in git
- docs: add vim pack usage

## [0.7.4] - 2026-05-24

### Changed

- refactor: rename action ctx scope fields to context
- refactor: rename scope to context and context to panel_view

## [0.7.3] - 2026-03-30

### Changed

- chore: move motivation section inside "What" title

## [0.7.2] - 2026-03-26

### Changed

- chore: fix broken link in readme

## [0.7.1] - 2026-03-26

### Changed

- chore: update docs and new demo gif

## [0.7.0] - 2026-03-24

### New

- enable showing workspace dir as config

### Changed

- fix: add space between scope and input text
- fix(git): enable folder toggle on first expand
- fix: compact single file paths
- fix: refresh git panels on project status changes
- fix: remove file name highlight
- fix: move ui logic to ui module
- fix: respec filter config on search
- fix: merge symbols workspace into a single navigator
- fix: remove flickering preview on panel load

