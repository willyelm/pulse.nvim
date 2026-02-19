# pulse.nvim

Telescope-powered smart panel for files, commands, and symbols.

## Requirements

- Neovim >= 0.10
- `nvim-telescope/telescope.nvim`
- `nvim-tree/nvim-web-devicons` (recommended for icons)

## Behavior

- One panel only: opening Pulse closes any previous Pulse/Telescope panel first.
- Starts in Insert mode.
- No default `>` marker characters.
- Top prompt title shows mode help: `: commands | # workspace | @ symbols`.

Prefixes:
- `:` -> command history + all available commands, filtered as you type.
- `#` -> workspace symbols for project, filtered as you type.
- `@` -> current buffer symbols, filtered as you type.
- empty -> files mode.

Files mode:
- Empty prompt shows opened buffers first, then recent files.
- Typing filters file results.

## Commands

- `:Pulse` (smart mode)
- `:Pulse files`
- `:Pulse symbol` (opens with `@` prefilled)
- `:Pulse workspace_symbol` (opens with `#` prefilled)
- `:Pulse commands` (opens with `:` prefilled)

## Default config

```lua
require("pulse").setup({
  cmdline = false, -- when true, maps ':' in normal mode to open Pulse with ':' prefilled
  keymaps = {
    open = "<leader>p",
    commands = "<leader>p:",
    workspace_symbol = "<leader>p#",
    symbol = "<leader>p@",
  },
  telescope = {
    initial_mode = "insert",
    prompt_prefix = "",
    selection_caret = " ",
    entry_prefix = " ",
    layout_strategy = "vertical",
    sorting_strategy = "ascending",
    layout_config = {
      anchor = "N",
      prompt_position = "top",
      height = 0.40,
      width = 0.70,
      preview_height = 0.45,
    },
  },
})
```

## Install (lazy.nvim)

```lua
{
  "willyelm/pulse.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "nvim-tree/nvim-web-devicons",
  },
  opts = {},
}
```
