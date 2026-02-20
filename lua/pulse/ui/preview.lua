--- Preview content generator (no window management).
--- Window creation and rendering is handled by window.lua.
local M = {}

local LINES = 5  -- max lines shown, match centered at line 3

local function resolve_path(path)
  if not path or path == "" then return nil end
  if vim.fn.filereadable(path) == 1 then return path end
  local abs = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(abs) == 1 then return abs end
  return nil
end

local function filetype_for(path)
  local ft = vim.filetype.match({ filename = path })
  ft = (ft and ft ~= "") and ft or vim.fn.fnamemodify(path, ":e")
  return (ft and ft ~= "") and ft or "text"
end

--- Compute preview content for the given entry value.
--- Returns nil when no preview is available for this kind.
--- @param item table   Entry value (kind, path/filename, lnum, col)
--- @param query string  Search term used for match highlighting
--- @return table|nil {
---   lines: string[],   up to LINES strings
---   ft: string,
---   match_row: integer,       0-indexed row in lines[] where the match sits
---   hl_col_start: integer|nil, byte offset of match start
---   hl_col_end:   integer|nil, byte offset of match end (exclusive)
--- }
function M.content_for(item, query)
  if not item then return nil end
  local kind = item.kind

  -- ── git diff ──────────────────────────────────────────────────────────────
  if kind == "git_status" then
    local path = item.path or item.filename
    local diff = vim.fn.systemlist({ "git", "--no-pager", "diff", "--", path })
    if vim.v.shell_error ~= 0 or #diff == 0 then
      return { lines = { "No diff for " .. tostring(path) }, ft = "text", match_row = 0 }
    end
    local out = {}
    for i = 1, math.min(LINES, #diff) do
      out[i] = diff[i]
    end
    return { lines = out, ft = "diff", match_row = 0 }
  end

  -- ── live grep context ─────────────────────────────────────────────────────
  if kind ~= "live_grep" then return nil end

  local path = resolve_path(item.path or item.filename)
  if not path then
    return { lines = { "File not found: " .. tostring(item.path or item.filename) }, ft = "text", match_row = 0 }
  end

  local function read_context(path, lnum)
    local half = math.floor(LINES / 2)
    local start_line = math.max(1, lnum - half)
    local end_line = start_line + LINES - 1

    local chunk = vim.fn.readfile(path, "", start_line, end_line)
    if #chunk < LINES and start_line > 1 then
      start_line = math.max(1, start_line - (LINES - #chunk))
      end_line = start_line + LINES - 1
      chunk = vim.fn.readfile(path, "", start_line, end_line)
    end

    return chunk, start_line
  end

  local lnum = math.max(item.lnum or 1, 1)
  local out, start_l = read_context(path, lnum)
  if #out == 0 then
    return nil
  end

  local match_row = lnum - start_l  -- 0-indexed

  -- Byte offsets for the query match on the match line
  local hl_start, hl_end
  local q = query or ""
  if q ~= "" then
    local text = out[match_row + 1] or ""
    local from = text:lower():find(q:lower(), 1, true)
    if from then
      hl_start = from - 1
      hl_end   = from - 1 + #q
    end
  end

  return {
    lines         = out,
    ft            = filetype_for(path),
    match_row     = match_row,
    hl_col_start  = hl_start,
    hl_col_end    = hl_end,
  }
end

return M
