local M = {}
local Preview = {}
Preview.__index = Preview
local window = require("pulse.ui.window")

local function filetype_for(path)
  local ft = vim.filetype.match({ filename = path })
  ft = (ft and ft ~= "") and ft or vim.fn.fnamemodify(path, ":e")
  return (ft and ft ~= "") and ft or "file"
end

local function resolve_path(path)
  if not path or path == "" then
    return nil
  end
  if vim.fn.filereadable(path) == 1 then
    return path
  end
  local abs = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(abs) == 1 then
    return abs
  end
  return nil
end

local function normalise_lines(lines)
  local out = {}
  for _, line in ipairs(lines or {}) do
    local parts = vim.split(tostring(line or ""), "\n", { plain = true, trimempty = false })
    for _, part in ipairs(parts) do
      out[#out + 1] = part
    end
  end
  return out
end

local function add_query_matches(highlights, lines, query)
  local q = (query or ""):lower()
  if q == "" then
    return
  end
  for row, text in ipairs(lines) do
    local lower, from = (text or ""):lower(), 1
    while true do
      local idx = lower:find(q, from, true)
      if not idx then break end
      highlights[#highlights + 1] = { group = "Search", row = row - 1, start_col = idx - 1, end_col = idx - 1 + #q }
      from = idx + 1
    end
  end
end

local function file_snippet(path, lnum, query, match_cols)
  local resolved = resolve_path(path)
  if not resolved then
    return { "File not found: " .. tostring(path) }, "text", {}, nil, 1
  end

  local lines = vim.fn.readfile(resolved)
  local line_no = math.max(lnum or 1, 1)
  local context = 6
  local start_l = math.max(line_no - context, 1)
  local end_l = math.min(#lines, line_no + context)
  local out = {}
  local highlights = {}
  local line_numbers = {}

  for i = start_l, end_l do
    out[#out + 1] = lines[i] or ""
    line_numbers[#line_numbers + 1] = i
  end

  add_query_matches(highlights, out, query)
  if type(match_cols) == "table" then
    local row = line_no - start_l
    for _, col in ipairs(match_cols) do
      if type(col) == "number" and col > 0 then
        highlights[#highlights + 1] = { group = "Search", row = row, start_col = col - 1, end_col = col }
      end
    end
  end

  return out, filetype_for(resolved), highlights, line_numbers, (line_no - start_l + 1)
end

local DIFF_ADD_HL = (vim.fn.hlexists("DiffAdded") == 1) and "DiffAdded" or "DiffAdd"
local DIFF_DEL_HL = (vim.fn.hlexists("DiffDelete") == 1) and "DiffDelete" or "DiffDelete"

local function git_patch_for(path)
  local diff = vim.fn.systemlist({ "git", "--no-pager", "diff", "--", path })
  if vim.v.shell_error == 0 and #diff > 0 then
    return diff
  end
  diff = vim.fn.systemlist({ "git", "--no-pager", "diff", "--cached", "--", path })
  if vim.v.shell_error == 0 and #diff > 0 then
    return diff
  end
  return nil
end

local function diff_highlights(lines)
  local out = {}
  for i, line in ipairs(lines or {}) do
    local row = i - 1
    if line:sub(1, 2) == "@@" or line:sub(1, 10) == "diff --git" or line:sub(1, 5) == "index" then
      out[#out + 1] = { group = "DiffChange", row = row, start_col = 0, end_col = -1 }
    elseif line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
      out[#out + 1] = { group = DIFF_ADD_HL, row = row, start_col = 0, end_col = -1 }
    elseif line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
      out[#out + 1] = { group = DIFF_DEL_HL, row = row, start_col = 0, end_col = -1 }
    end
  end
  return out
end

function M.for_item(item)
  if not item then
    return { "No selection" }, "text", {}, nil, 1
  end

  if item.kind == "header" then
    return { item.label or "" }, "text", {}, nil, 1
  end

  if item.kind == "git_status" then
    local path = item.path or item.filename
    local diff = git_patch_for(path)
    if not diff or #diff == 0 then
      diff = { "No git diff for " .. tostring(path) }
    end
    return diff, "diff", diff_highlights(diff), nil, 1
  end

  if item.kind == "live_grep" or item.kind == "fuzzy_search" then
    return file_snippet(item.path or item.filename, item.lnum, item.query, item.match_cols)
  end

  if item.kind == "diagnostic" then
    local out = {
      string.format("[%s] %s", item.severity_name or "INFO", item.source or "diagnostic"),
      string.format("%s:%d:%d", item.filename or "", item.lnum or 1, item.col or 1),
      "",
      item.message or "",
      "",
    }
    local snippet, ft = file_snippet(item.filename, item.lnum)
    vim.list_extend(out, snippet)
    return out, ft, {}, nil, 1
  end

  if item.kind == "file" or item.kind == "symbol" or item.kind == "workspace_symbol" then
    return file_snippet(item.path or item.filename, item.lnum)
  end

  if item.kind == "command" then
    return {
      "Command",
      "",
      ":" .. tostring(item.command),
      "",
      "Press <CR> to execute selected command.",
      "Typing after ':' and pressing <CR> executes typed command.",
    }, "text", {}, nil, 1
  end

  return { vim.inspect(item) }, "lua", {}, nil, 1
end

function Preview.new(opts)
  local self = setmetatable({}, Preview)
  self.buf = assert(opts.buf, "preview requires a buffer")
  self.win = assert(opts.win, "preview requires a window")
  self.ns = vim.api.nvim_create_namespace("pulse_ui_preview")
  self.active_filetype = "text"

  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].modifiable = false
  vim.bo[self.buf].filetype = "text"

  window.configure_content_window(self.win)
  return self
end

function Preview:set_target(buf, win)
  self.buf = buf
  self.win = win
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    window.configure_content_window(self.win)
  end
end

function Preview:set(lines, filetype, highlights, line_numbers, focus_row)
  if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
    return
  end
  local safe_lines = normalise_lines(lines)
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, safe_lines)
  vim.bo[self.buf].modifiable = false

  local target_filetype = filetype or "text"
  vim.bo[self.buf].filetype = target_filetype
  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)

  if target_filetype ~= self.active_filetype then
    self.active_filetype = target_filetype
    if target_filetype ~= "" and target_filetype ~= "text" then
      pcall(vim.treesitter.start, self.buf, target_filetype)
    end
  end

  if line_numbers and #line_numbers > 0 then
    local max_line = 0
    for _, n in ipairs(line_numbers) do
      if type(n) == "number" and n > max_line then
        max_line = n
      end
    end
    local width = math.max(#tostring(max_line), 1)
    for row, n in ipairs(line_numbers) do
      if type(n) == "number" then
        local text = string.format("%" .. width .. "d ", n)
        vim.api.nvim_buf_set_extmark(self.buf, self.ns, row - 1, 0, {
          virt_text = { { text, "LineNr" } },
          virt_text_pos = "inline",
        })
      end
    end
  end

  for _, hl in ipairs(highlights or {}) do
    pcall(vim.api.nvim_buf_add_highlight, self.buf, self.ns, hl.group, hl.row, hl.start_col, hl.end_col)
  end

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    window.configure_content_window(self.win)
    pcall(vim.api.nvim_win_set_cursor, self.win, { math.max(focus_row or 1, 1), 0 })
    pcall(vim.api.nvim_win_call, self.win, function()
      vim.cmd("normal! zz")
    end)
  end
end

M.new = function(opts)
  return Preview.new(opts)
end

return M
