# Pulse Picker API

A picker is a self-contained module that defines a data source and how to interact with it.

## Picker Module Interface

```lua
local M = {}

M.mode = {
  name = "my_picker",        -- unique identifier (required)
  start = "%",               -- prefix char for routing ("" = default)
  icon = "󰊲",
  placeholder = "Search...",
}

M.preview = false  -- or function(item) return boolean end

function M.init(ctx)
  -- ctx: { bufnr, win, cwd, on_update }
  -- Return initial state object
  return { files = {} }
end

function M.items(state, query)
  -- Return filtered items for display
  return {}
end

-- Optional hooks
function M.on_submit(ctx) end   -- ctx: { item, query, close, jump, input, mode }
function M.on_tab(ctx) end      -- or M.on_tab = false to disable
function M.on_active(ctx) end   -- called on selection change
function M.dispose(state) end   -- cleanup when closed

M.allow_empty_selection = false
M.total_count = function(state) return 0 end

return M
```

## Registration

```lua
require('pulse').setup({
  pickers = {
    "files",                          -- string (loads pulse.pickers.files)
    require("pulse.pickers.git_status"),  -- or module object
  }
})
```

## Example: Simple Picker

```lua
local M = {}

M.mode = {
  name = "my_grep",
  start = "$",
  icon = "󰍉",
  placeholder = "Grep",
}

M.preview = true

function M.init(ctx)
  return { results = {} }
end

function M.items(state, query)
  if query == "" then return {} end
  local items = {}
  -- populate items from grep/query
  return items
end

function M.on_submit(ctx)
  if ctx.item then
    ctx.jump(ctx.item)
    ctx.close()
  end
end

return M
```

## Utilities

```lua
local pulse = require("pulse")

-- Create matcher for filtering
local matcher = pulse.make_matcher(query, { ignore_case = true, plain = true })
if matcher("haystack") then ... end

-- Get filetype for path
local ft = pulse.filetype_for("/path/to/file.lua")  -- returns "lua"
```

## Item Structure

Any table works. Common kinds recognized by display:

- `{ kind = "file", path = "..." }`
- `{ kind = "command", command = "...", execute = fn }`
- `{ kind = "symbol", symbol = "...", filename = "...", lnum = 42 }`
- `{ kind = "diagnostic", message = "...", lnum = 1, col = 1 }`
- `{ kind = "git_status", path = "...", added = 0, removed = 0 }`
- `{ kind = "header", label = "Section" }`

Custom items render with basic formatting.

## Hook Context

Passed to `on_submit()`, `on_tab()`, `on_active()`:

```lua
{
  item = item | nil,      -- selected item
  query = string,         -- user input (prefix stripped)
  close = function(),     -- close picker
  jump = function(item),  -- jump to item
  input = widget,         -- input reference
  mode = M.mode,          -- mode table
}
```

Plus in `init()` only: `bufnr`, `win`, `cwd`, `on_update()`.
