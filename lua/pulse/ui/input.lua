local M = {}
M.__index = M

local window = require("pulse.ui.window")
local mode = require("pulse.mode")
local MODE_HL = "PulseModePrefix"

local function configure_window(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  window.configure_content_window(win)
  vim.wo[win].colorcolumn = ""
  vim.wo[win].cursorcolumn = false
  vim.wo[win].cursorline = false
  vim.wo[win].list = false
  vim.wo[win].spell = false
  vim.wo[win].winbar = ""
end

local function cursor_to_eol(win, buf)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local line = (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
  pcall(vim.api.nvim_win_set_cursor, win, { 1, #line })
end

local function normalise_chunks(spec, default_hl)
  local t = type(spec)
  if t == "string" then
    return { { spec, default_hl } }
  end
  if t ~= "table" then
    return nil
  end
  if spec.text then
    return { { tostring(spec.text), spec.hl or default_hl } }
  end
  return nil
end

local function strip_prompt_prefix(line, prompt)
  prompt = prompt or ""
  if prompt ~= "" and line:sub(1, #prompt) == prompt then
    return line:sub(#prompt + 1)
  end
  return line
end

local function current_raw_value(buf, prompt)
  local line = (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
  return strip_prompt_prefix(line, prompt)
end

local function write_value(buf, prompt, value)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { (prompt or "") .. tostring(value or "") })
  vim.bo[buf].modified = false
end

function M.new(opts)
  local self = setmetatable({}, M)
  self.buf = assert(opts.buf, "input requires a buffer")
  self.win = assert(opts.win, "input requires a window")
  self.prompt = opts.prompt or ""
  self.on_change = opts.on_change
  self.on_submit = opts.on_submit
  self.on_escape = opts.on_escape
  self.on_down = opts.on_down
  self.on_up = opts.on_up
  self.on_tab = opts.on_tab
  self.on_left = opts.on_left
  self.on_right = opts.on_right
  self.augroup = vim.api.nvim_create_augroup("PulseUIInput" .. tostring(self.buf), { clear = true })
  self.ns = vim.api.nvim_create_namespace("pulse_ui_input")
  self.addons = {}
  pcall(vim.api.nvim_set_hl, 0, MODE_HL, { bold = true, default = true })

  window.configure_isolated_buffer(self.buf, { buftype = "prompt", modifiable = true, bufhidden = "hide" })
  vim.fn.prompt_setprompt(self.buf, self.prompt)

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group = self.augroup,
    buffer = self.buf,
    callback = function()
      if self._mute_change then
        return
      end
      if self.on_change then
        self.on_change(self:get_value())
      end
      vim.bo[self.buf].modified = false
    end,
  })

  local map_opts = { buffer = self.buf, noremap = true, silent = true }
  local function map(lhs, cb) vim.keymap.set({ "i", "n" }, lhs, cb, map_opts) end
  local function call(fn, ...) if fn then fn(...) end end
  local function map_expr(lhs, fallback, cb)
    vim.keymap.set({ "i", "n" }, lhs, function()
      if cb and cb() then
        return ""
      end
      return fallback
    end, vim.tbl_extend("force", map_opts, { expr = true }))
  end

  local keymaps = {
    { "<CR>", function() call(self.on_submit, self:get_value()) end },
    { "<Esc>", function() call(self.on_escape) end },
    { "<Tab>", function() call(self.on_tab) end },
    { { "<Down>", "<C-n>" }, function() call(self.on_down) end },
    { { "<Up>", "<C-p>" }, function() call(self.on_up) end },
  }
  for _, km in ipairs(keymaps) do
    local keys, fn = km[1], km[2]
    if type(keys) == "string" then keys = { keys } end
    for _, lhs in ipairs(keys) do map(lhs, fn) end
  end

  map_expr("<Left>", "<Left>", function() return self.on_left and self.on_left() end)
  map_expr("<Right>", "<Right>", function() return self.on_right and self.on_right() end)

  configure_window(self.win)
  return self
end

function M:set_win(win)
  self.win = win
  vim.fn.prompt_setprompt(self.buf, self.prompt)
  configure_window(self.win)
  self:set_addons(self.addons)
end

function M:set_prompt(prompt)
  prompt = prompt or ""
  local value = current_raw_value(self.buf, self.prompt)
  self._mute_change = true
  self.prompt = prompt
  vim.fn.prompt_setprompt(self.buf, self.prompt)
  if vim.api.nvim_buf_is_valid(self.buf) then
    write_value(self.buf, self.prompt, value)
    cursor_to_eol(self.win, self.buf)
  end
  self._mute_change = false
end

function M:get_value()
  return current_raw_value(self.buf, self.prompt)
end

function M:set_value(value)
  write_value(self.buf, self.prompt, value)
  cursor_to_eol(self.win, self.buf)
  self:set_addons(self.addons)
end

function M:focus(insert_mode)
  if not (self.win and vim.api.nvim_win_is_valid(self.win)) then
    return
  end
  configure_window(self.win)
  vim.api.nvim_set_current_win(self.win)
  self:set_addons(self.addons)
  if insert_mode ~= false then
    cursor_to_eol(self.win, self.buf)
    vim.cmd("startinsert!")
  end
end

function M:set_addons(addons)
  self.addons = addons or {}
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)

  local first = self:get_value():sub(1, 1)
  local by_start = mode.by_start()
  if by_start[first] then
    pcall(vim.api.nvim_buf_set_extmark, self.buf, self.ns, 0, 0, {
      end_row = 0,
      end_col = 1,
      hl_group = MODE_HL,
    })
  end

  local right = normalise_chunks(self.addons.right, "LineNr")
  if right then
    vim.api.nvim_buf_set_extmark(self.buf, self.ns, 0, 0, {
      virt_text = right,
      virt_text_pos = "right_align",
      hl_mode = "combine",
    })
  end

  local ghost = normalise_chunks(self.addons.ghost, "LineNr")
  if ghost then
    local line = (vim.api.nvim_buf_get_lines(self.buf, 0, 1, false)[1] or "")
    vim.api.nvim_buf_set_extmark(self.buf, self.ns, 0, #line, {
      virt_text = ghost,
      virt_text_pos = "inline",
      hl_mode = "replace",
    })
  end
end

return M
