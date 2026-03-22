# Pulse Navigator API

A navigator is a self-contained module that defines a data source, its panels, and how Pulse interacts with it.

## Navigator Module Interface

```lua
local M = {}

M.mode = {
  name = "my_navigator",     -- unique identifier (required)
  icon = "󰊲",
}

M.panels = {
  { start = "%", name = "my_navigator", label = "My Navigator", scopes = { "workspace" } },
}

M.context = false  -- or function(item) return boolean end

function M.init(ctx)
  -- ctx: { bufnr, win, cwd, scope, on_update }
  -- Return initial state object
  return { files = {} }
end

function M.items(state, query, panel_name)
  -- Return filtered items for display
  return {}
end

-- Optional hooks
function M.on_submit(ctx) end
function M.on_tab(ctx) end      -- or M.on_tab = false to disable
function M.on_active(ctx) end   -- called on selection change
function M.dispose(state) end   -- cleanup when closed
function M.actions(ctx) end     -- panel-local actions (optional)
function M.input_scope(state) end -- override displayed scope token (optional)

M.allow_empty_selection = false
M.total_count = function(state) return 0 end
M.scope_aware = false
M.scope_clears_to_files = false

return M
```

## Registration

```lua
require('pulse').setup({
  navigators = {
    "files",                               -- string (loads pulse.navigators.files)
    require("pulse.navigators.git"), -- or module object
  }
})
```

## Example: Simple Navigator

```lua
local M = {}

M.mode = {
  name = "my_grep",
  icon = "󰍉",
}

M.panels = {
  { start = "$", name = "my_grep", label = "Grep", scopes = { "workspace" } },
}

M.context = true

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
  surface = table | nil,  -- active panel surface
  close = function(),     -- close Pulse
  jump = function(item),  -- jump to item
  preview = function(item), -- preview item without leaving input
  scope = table | nil,    -- current workspace/folder/file scope
  set_scope = function(scope),
  clear_scope = function(),
  input = widget,         -- input reference
  refresh = function(),
}
```

Plus in `init()` only: `bufnr`, `win`, `cwd`, `scope`, `on_update()`.
