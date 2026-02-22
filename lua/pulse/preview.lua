local M = {}
local Preview = {}
Preview.__index = Preview

local window = require("pulse.ui.window")
local diff_ui = require("pulse.ui.diff")

local function filetype_for(path)
  local ft = vim.filetype.match({ filename = path })
  if ft and ft ~= "" then return ft end
  ft = vim.fn.fnamemodify(path or "", ":e")
  return (ft ~= "" and ft) or "file"
end

local function resolve_path(path)
  if not path or path == "" then return nil end
  if vim.fn.filereadable(path) == 1 then return path end
  local abs = vim.fn.fnamemodify(path, ":p")
  return (vim.fn.filereadable(abs) == 1) and abs or nil
end

local function normalise_lines(lines)
  local out = {}
  for _, line in ipairs(lines or {}) do
    for _, part in ipairs(vim.split(tostring(line or ""), "\n", { plain = true, trimempty = false })) do
      out[#out + 1] = part
    end
  end
  return out
end

local function add_query_matches(highlights, lines, query)
  local q = (query or ""):lower()
  if q == "" then return end
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
  local file_lines = vim.fn.readfile(resolved)
  local line_no = math.max(lnum or 1, 1)
  local start_l, end_l = math.max(line_no - 6, 1), math.min(#file_lines, line_no + 6)
  local lines, highlights, numbers = {}, {}, {}
  for i = start_l, end_l do
    lines[#lines + 1] = file_lines[i] or ""
    numbers[#numbers + 1] = i
  end
  add_query_matches(highlights, lines, query)
  if type(match_cols) == "table" then
    local row = line_no - start_l
    for _, col in ipairs(match_cols) do
      if type(col) == "number" and col > 0 then
        highlights[#highlights + 1] = { group = "Search", row = row, start_col = col - 1, end_col = col }
      end
    end
  end
  return lines, filetype_for(resolved), highlights, numbers, (line_no - start_l + 1)
end

local function read_head_file(path)
  local rel = vim.fn.fnamemodify(path or "", ":.")
  if rel == "" then return {} end
  local lines = vim.fn.systemlist({ "git", "--no-pager", "show", "HEAD:" .. rel })
  return (vim.v.shell_error == 0) and lines or {}
end

local function read_worktree_file(path)
  local resolved = resolve_path(path)
  return resolved and vim.fn.readfile(resolved) or {}
end

local function git_patch_for(path)
  local diff = vim.fn.systemlist({ "git", "--no-pager", "diff", "--", path })
  if vim.v.shell_error == 0 and #diff > 0 then return diff end
  diff = vim.fn.systemlist({ "git", "--no-pager", "diff", "--cached", "--", path })
  if vim.v.shell_error == 0 and #diff > 0 then return diff end
  return { "No git diff for " .. tostring(path) }
end

function M.for_item(item)
  if not item then return { "No selection" }, "text", {}, nil, 1 end
  if item.kind == "header" then return { item.label or "" }, "text", {}, nil, 1 end

  if item.kind == "git_status" then
    local path = item.path or item.filename
    local old_lines, new_lines = read_head_file(path), read_worktree_file(path)
    if #old_lines == 0 and #new_lines == 0 then
      return git_patch_for(path), "text", {}, nil, 1
    end
    local lines, highlights, focus_row = diff_ui.from_lines(old_lines, new_lines, { context = 3 })
    return lines, filetype_for(path), highlights, nil, focus_row
  end

  if item.kind == "live_grep" or item.kind == "fuzzy_search" then
    return file_snippet(item.path or item.filename, item.lnum, item.query, item.match_cols)
  end

  if item.kind == "diagnostic" then
    local out = {
      string.format("[%s] %s", item.severity_name or "INFO", item.source or "diagnostic"),
      string.format("%s:%d:%d", item.filename or "", item.lnum or 1, item.col or 1),
      "", item.message or "", "",
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
      "Command", "", ":" .. tostring(item.command), "",
      "<Tab> fills input with the selected command.",
      "<CR> executes selected command after navigation,",
      "otherwise executes typed input.",
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
  vim.bo[self.buf].buftype, vim.bo[self.buf].bufhidden, vim.bo[self.buf].swapfile = "nofile", "wipe", false
  vim.bo[self.buf].modifiable, vim.bo[self.buf].filetype = false, "text"
  window.configure_content_window(self.win)
  return self
end

function Preview:set_target(buf, win)
  self.buf, self.win = buf, win
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    window.configure_content_window(self.win)
  end
end

function Preview:set(lines, filetype, highlights, line_numbers, focus_row)
  if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then return end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, normalise_lines(lines))
  vim.bo[self.buf].modifiable = false

  local ft = filetype or "text"
  vim.bo[self.buf].filetype = ft
  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
  if ft ~= self.active_filetype then
    self.active_filetype = ft
    if ft ~= "" and ft ~= "text" then pcall(vim.treesitter.start, self.buf, ft) end
  end

  if line_numbers and #line_numbers > 0 then
    local max_line = 0
    for _, n in ipairs(line_numbers) do
      if type(n) == "number" and n > max_line then max_line = n end
    end
    local w = math.max(#tostring(max_line), 1)
    for row, n in ipairs(line_numbers) do
      if type(n) == "number" then
        vim.api.nvim_buf_set_extmark(self.buf, self.ns, row - 1, 0, {
          virt_text = { { string.format("%" .. w .. "d ", n), "LineNr" } },
          virt_text_pos = "inline",
        })
      end
    end
  end

  for _, hl in ipairs(highlights or {}) do
    if type(hl.priority) == "number" and type(hl.end_col) == "number" and hl.end_col >= 0 then
      pcall(vim.api.nvim_buf_set_extmark, self.buf, self.ns, hl.row, hl.start_col, {
        end_row = hl.row,
        end_col = hl.end_col,
        hl_group = hl.group,
        hl_mode = hl.hl_mode or "replace",
        priority = hl.priority,
      })
    else
      pcall(vim.api.nvim_buf_add_highlight, self.buf, self.ns, hl.group, hl.row, hl.start_col, hl.end_col)
    end
  end

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    window.configure_content_window(self.win)
    pcall(vim.api.nvim_win_set_cursor, self.win, { math.max(focus_row or 1, 1), 0 })
    pcall(vim.api.nvim_win_call, self.win, function() vim.cmd("normal! zz") end)
  end
end

M.new = function(opts) return Preview.new(opts) end

return M
