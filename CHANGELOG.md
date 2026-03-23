# Changelog

## [Unreleased]

### Changed

- add per-picker config support with initial `files` options
- add `files.open_on_directory` to open Pulse files for `nvim .`





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

## [0.3.0] - 2026-03-20

### New

- separate picker loader with picker api

### Changed

- fix: preserve latest prompt and itemselection

## [0.2.2] - 2026-03-18

### Changed

- fix: use picker drive execute commands

## [0.2.1] - 2026-03-18

### Changed

- fix: improve workspace_symbols tree and correctness
- fix: use actual editor buffer for code_actions

## [0.2.0] - 2026-03-17

### New

- add code_actions picker with > prefix

### Changed

- fix: improve code_actions hints and enhance overall performance

## [0.1.12] - 2026-02-24

### Changed

- chore: add neovim badge

## [0.1.11] - 2026-02-24

### Changed

- chore: use gif for showcase

## [0.1.10] - 2026-02-24

### Changed

- chore: try md markdup for video ref

## [0.1.9] - 2026-02-24

### Changed

- chore: use webm for preview image in readme

## [0.1.8] - 2026-02-24

### Changed

- chore: update changelog

## [0.1.7] - 2026-02-23

### Changed

- fix: use correct icon colors

## [0.1.6] - 2026-02-23

### Changed

- chore: fix relesae action

## [0.1.3] - 2026-02-22

### Changed

- chore: separate release jobs
- fix: hide previews for files and command pickers

