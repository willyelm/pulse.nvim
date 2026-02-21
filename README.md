# pulse.nvim

Smart panel for files, commands, symbols, grep, and git status using Pulse's built-in floating UI.

## Requirements

- Neovim >= 0.10
- `nvim-tree/nvim-web-devicons` (recommended for icons)

## Behavior

- (empty) -> files mode.
- `:` -> command history + all available commands when empty; when typing, only available commands are shown.
- `~` -> git changed files (`git status --porcelain`) with in-panel diff preview.
- `!` -> workspace diagnostics (errors, warnings, info, hints), with current buffer diagnostics shown first.
- `@` -> current buffer symbols (Treesitter immediate + LSP async), filtered as you type.
- `#` -> workspace symbols for project (LSP async), filtered as you type.
- `$` -> live grep in project files (`rg --vimgrep`) with in-panel preview.
- `?` -> fuzzy search

## Commands API

- `:Pulse` -> open empty (files mode)
- `:Pulse commands` -> open with `:`
- `:Pulse git_status` -> open with `~`
- `:Pulse diagnostics` -> open with `!`
- `:Pulse symbols` -> open with `@`
- `:Pulse workspace_symbols` -> open with `#`
- `:Pulse live_grep` -> open with `$`
- `:Pulse fuzzy_search` -> open with `?`

Aliases also supported: `symbol`, `workspace_symbol`, `files`, `smart`.

## Install (lazy.nvim)

```lua
{
  "willyelm/pulse.nvim",
  dependencies = {
    "nvim-tree/nvim-web-devicons",
  },
  opts = {
    cmdline = false,
  },
  keys = {
    { "<leader>p", "<cmd>Pulse<cr>", desc = "Pulse" },
    { "<leader>p:", "<cmd>Pulse commands<cr>", desc = "Pulse Commands" },
    { "<leader>p@", "<cmd>Pulse symbols<cr>", desc = "Pulse Symbols" },
    { "<leader>p#", "<cmd>Pulse workspace_symbols<cr>", desc = "Pulse Workspace Symbols" },
    { "<leader>p$", "<cmd>Pulse live_grep<cr>", desc = "Pulse Live Grep" },
    { "<leader>p~", "<cmd>Pulse git_status<cr>", desc = "Pulse Git Status" },
    { "<leader>p!", "<cmd>Pulse diagnostics<cr>", desc = "Pulse Diagnostics" },
  },
}
```

## Default config

```lua
require("pulse").setup({
  cmdline = false, -- when true, maps ':' in normal mode to open Pulse with ':' prefilled
  ui = {
    initial_mode = "insert",
    prompt_prefix = "",
    selection_caret = " ",
    entry_prefix = " ",
    sorting_strategy = "ascending",
    layout_config = {
      width = 0.50,
      height = 0.45,
      prompt_position = "top",
      anchor = "N",
    },
    border = true,
  },
})
```

`telescope` config key is still accepted for backward compatibility and maps to `ui`.
