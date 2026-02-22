# Changelog

## [0.1.2] - 2026-02-22

### Changed

- chore: add changelog release

## [0.1.0] - 2026-02-22

### New

- Pulse command-palette picker with a single entry point and prefix-based mode switching.
- Mode prefixes for files, commands, git status, diagnostics, buffer symbols, workspace symbols, live grep, and fuzzy search.
- `:Pulse` command with optional direct mode open (for example `:Pulse files`, `:Pulse commands`).
- Configurable setup options for cmdline mode, initial mode, floating window position/size, and border style.
- Keyboard navigation and selection workflow (`<C-n>/<C-p>`, `<Down>/<Up>`, `<Tab>`, `<CR>`, `Esc`) with wrap-around list navigation.
- Mode-specific `<Tab>` behavior for previewing files, jumping to symbols/search/diagnostics results, and command input fill.
- Safe commands-mode submit behavior that executes selected commands only after explicit navigation.
- Optional keymap patterns for quick mode access from normal mode.
- Highlight groups for mode prefix, list matches, git add/delete states, and diff count styling with override support.
