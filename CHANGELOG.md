# Changelog

## [Unreleased]

### Changed

- add per-picker config support with initial `files` options
- add `files.open_on_directory` to open Pulse files for `nvim .`





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

## [0.6.3] - 2026-03-24

### Changed

- fix: corrected line counter in git panel

## [0.6.2] - 2026-03-24

### Changed

- fix: support fullscreen with shift+enter
- fix: improve performance and add virtualized items
- fix: improve ignored path scanning
- fix: delete input on command execution

