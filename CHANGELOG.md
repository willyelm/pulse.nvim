# Changelog

## [Unreleased]

### Changed

- add per-picker config support with initial `files` options
- add `files.open_on_directory` to open Pulse files for `nvim .`

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

## [0.6.1] - 2026-03-23

### Changed

- fix: improve cold start git status in files navigator

## [0.6.0] - 2026-03-23

### New

- show ignored files in tree and in isolated scope views
- add actions menu with keys info
- add actions menu footer
- support navigating history commit file tree and status
- add git project and file history
- support file actions to add, delete, copy, cut and paste

### Changed

- fix: remove old states and flags
- fix: remove highlight flags in files
- fix: use jump to open in location
- fix: remove modes and use navigator panels instead
- fix: reduce highlight groups in favor of vim defaults
- fix: improve buffer scope refresh
- fix: buffer refresh and cache
- fix: remove special highlight from commands and git items
- fix: remove custom git diff summaries
- fix: remove apply effect fn and use scope based methods
- fix: improve navigators terminology removing surfaces, hooks
- fix: remove file name from location in fuzzy search
- chore: reorg git and files with consitent structure
- chore: reorg git navigator
- fix: remove initial_mode config
- chore: remove old recent state
- fix: preserve insert mode on quick navigations

## [0.5.1] - 2026-03-21

### Changed

- fix: improved panel switching and input cursor

## [0.5.0] - 2026-03-21

### New

- enhanced panel based navigation system
- add scope based indicator for symbols, fuzzy_search and files
- support git status in file view

### Changed

- fix: recover files tree state on toggle
- fix: use file preview on <Tab>
- fix: correct scroll refresh when updating list
- fix: use correct colors for git signs
- fix: add new files in git status diff view
- fix: use navigation and context terminology

## [0.4.0] - 2026-03-21

### New

- enable use file picker as file tree directory
- add file picker panels, all, open and recent using tree for files and folders
- enable multiple picker panels with arrow based navigation

### Changed

- fix: stop insert on file open
- chore: remove old preview templates
- fix: remove command preview content
- fix: retain session state instead of recreate on each toggle
