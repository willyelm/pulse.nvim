![NVIM](https://img.shields.io/badge/Neovim-57A143?style=flat-square&logo=neovim&logoColor=white)

# Pulse.nvim

One entry point. Total focus.

![Pulse](./images/pulse-showcase.gif)

## What is Pulse

A Fast one command-palette for Neovim. Pulse uses a prefix
approach to move quickly between picker modes:

| Prefix      | Mode                          |
| ----------- | ----------------------------- |
| (no prefix) | files                         |
| `:`         | commands                      |
| `~`         | git status                    |
| `!`         | diagnostics                   |
| `>`         | code actions (current buffer) |
| `@`         | symbols (current buffer)      |
| `#`         | workspace symbols             |
| `$`         | live grep                     |
| `?`         | fuzzy search (current buffer) |

## Requirements

- Neovim `>= 0.10`
- `ripgrep` (`rg`)
- `git` (for git status mode preview)
- `nvim-tree/nvim-web-devicons` (optional, recommended)

## Install (lazy.nvim)

```lua
{
  "willyelm/pulse.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  opts = {},
}
```

## Setup

```lua
require("pulse").setup({
  cmdline = false, -- set true to enable experimental ':' cmdline replacement
  initial_mode = "insert",
  position = "top",
  width = 0.50,
  height = 0.75,
  border = "rounded",
  pickers = {
    files = {
      icons = true,
      filters = { "^%.git$", "%.DS_Store$" },
      git = {
        enable = true,
        ignore = true,
      },
      open_on_directory = false,
    },
  },
})
```

**Default pickers** (all loaded if not specified):

- `files` - Project files
- `commands` - Vim commands
- `git_status` - Git changes
- `diagnostics` - LSP diagnostics
- `code_action` - Code actions (current buffer)
- `symbol` - Symbols (current buffer)
- `workspace_symbol` - Workspace symbols
- `live_grep` - Search with ripgrep
- `fuzzy_search` - Fuzzy search (current buffer)

To load a specific set only:

```lua
require("pulse").setup({
  pickers = { "files", "commands", "git_status" },
})
```

## Per Picker Config

Each picker can receive its own config directly through `pickers`:

```lua
require("pulse").setup({
  pickers = {
    files = {
      icons = false,
      filters = { "^%.git$", "%.DS_Store$" },
      git = {
        enable = true,
        ignore = false,
      },
    },
  },
})
```

You can also disable a default setting:

```lua
require("pulse").setup({
  pickers = {
    git_status = false,
    files = {
      icons = false,
    },
  },
})
```

Current `files` options:

- `icons`
- `filters`
- `git.enable`
- `git.ignore`
- `open_on_directory`

## Use Files As Default Tree

To open Pulse files instead of netrw for directory buffers like `nvim .`, set the netrw globals before setup and enable `open_on_directory` on the files picker:

```lua
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

require("pulse").setup({
  pickers = {
    files = {
      open_on_directory = true,
    },
  },
})
```

With `lazy.nvim`, that typically looks like:

```lua
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

{
  "willyelm/pulse.nvim",
  lazy = false,
  dependencies = {
    "nvim-tree/nvim-web-devicons",
  },
  opts = {
    cmdline = true,
    position = "top",
    height = 0.9,
    width = 0.7,
    pickers = {
      files = {
        open_on_directory = true,
      },
    },
  },
}
```

## Open Pulse

- `:Pulse`
- `:Pulse files`
- `:Pulse commands`
- `:Pulse git_status`
- `:Pulse diagnostics`
- `:Pulse code_actions`
- `:Pulse symbols`
- `:Pulse workspace_symbols`
- `:Pulse live_grep`
- `:Pulse fuzzy_search`

## Input + Navigation

- `<Down>/<C-n>`: next item (from input)
- `<Up>/<C-p>`: previous item (from input)
- `Esc`: close picker
- `<Tab>`:
  - files: open preview in source window (picker stays open)
  - symbols/workspace symbols: jump to location (picker stays open)
  - live grep/fuzzy search: open/jump to location (picker stays open)
  - diagnostics: jump to location (picker stays open)
  - commands: replace input with selected command
  - git status: no-op
- `<CR>`: submit/open and close picker
- selection wraps from last->first and first->last

In `commands` mode:

- No implicit first-item execution.
- `<CR>` executes the selected command only after explicit navigation.
- Otherwise `<CR>` executes the typed command.

## Optional Keymaps

```lua
vim.keymap.set("n", "<leader>p", "<cmd>Pulse<cr>", { desc = "Pulse" })
vim.keymap.set("n", "<leader>p", "<cmd>Pulse commands<cr>", { desc = "Pulse Commands" })
vim.keymap.set("n", "<leader>pg", "<cmd>Pulse git_status<cr>", { desc = "Pulse Git Status" })
vim.keymap.set("n", "<leader>pd", "<cmd>Pulse diagnostics<cr>", { desc = "Pulse Diagnostics" })
vim.keymap.set("n", "<leader>pc>", "<cmd>Pulse code_actions<cr>", { desc = "Pulse Code Actions" })
vim.keymap.set("n", "<leader>ps", "<cmd>Pulse symbols<cr>", { desc = "Pulse Symbols" })
vim.keymap.set("n", "<leader>pw", "<cmd>Pulse workspace_symbols<cr>", { desc = "Pulse Workspace Symbols" })
vim.keymap.set("n", "<leader>pl", "<cmd>Pulse live_grep<cr>", { desc = "Pulse Live Grep" })
vim.keymap.set("n", "<leader>pf", "<cmd>Pulse fuzzy_search<cr>", { desc = "Pulse Fuzzy Search" })
```

## Theming

Pulse uses existing highlight groups, with optional overrides:

- `PulseModePrefix`
- `PulseListMatch`
- `PulseAdd`
- `PulseDelete`
- `PulseDiffAdd`
- `PulseDiffDelete`
- `PulseDiffNAdd`
- `PulseDiffNDelete`

Example:

```lua
vim.api.nvim_set_hl(0, "PulseAdd", { link = "Added" })
vim.api.nvim_set_hl(0, "PulseDelete", { link = "Removed" })
vim.api.nvim_set_hl(0, "PulseDiffAdd", { link = "DiffAdd" })
vim.api.nvim_set_hl(0, "PulseDiffDelete", { link = "DiffDelete" })
```

## Contributing

[See CONTRIBUTING.md](./CONTRIBUTING.md)

## Changelog

[See CHANGELOG.md](./CHANGELOG.md)
