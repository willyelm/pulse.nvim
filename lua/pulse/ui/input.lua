local M = {}
local Input = {}
Input.__index = Input

local window = require("pulse.ui.window")
local MODE_PREFIX = { [":"] = true, ["~"] = true, ["!"] = true, ["@"] = true, ["#"] = true, ["$"] = true, ["?"] = true }
local MODE_HL = "PulseModePrefix"

local function configure_window(win)
  window.configure_content_window(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
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
  if spec == nil then
    return nil
  end
  if type(spec) == "string" then
    return { { spec, default_hl } }
  end
  if type(spec) ~= "table" then
    return nil
  end
  if type(spec.chunks) == "table" then
    return spec.chunks
  end
  if spec.text then
    return { { tostring(spec.text), spec.hl or default_hl } }
  end
  return nil
end

function Input.new(opts)
  local self = setmetatable({}, Input)
  self.buf = assert(opts.buf, "input requires a buffer")
  self.win = assert(opts.win, "input requires a window")
  self.prompt = opts.prompt or ""
  self.on_change = opts.on_change
  self.on_submit = opts.on_submit
  self.on_escape = opts.on_escape
  self.on_down = opts.on_down
  self.on_up = opts.on_up
  self.on_tab = opts.on_tab
  self.augroup = vim.api.nvim_create_augroup("PulseUIInput" .. tostring(self.buf), { clear = true })
  self.ns = vim.api.nvim_create_namespace("pulse_ui_input")
  self.addons = {}
  pcall(vim.api.nvim_set_hl, 0, MODE_HL, { bold = true, default = true })

  vim.bo[self.buf].buftype = "prompt"
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].filetype = "pulseinput"
  vim.b[self.buf].gitsigns_disable = true
  vim.fn.prompt_setprompt(self.buf, self.prompt)

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group = self.augroup,
    buffer = self.buf,
    callback = function()
      if self.on_change then
        self.on_change(self:get_value())
      end
    end,
  })

  local map_opts = { buffer = self.buf, noremap = true, silent = true }
  local function map(lhs, cb)
    vim.keymap.set({ "i", "n" }, lhs, cb, map_opts)
  end
  local function call(fn, ...)
    if fn then
      fn(...)
    end
  end

  map("<CR>", function()
    call(self.on_submit, self:get_value())
  end)
  map("<Esc>", function()
    call(self.on_escape)
  end)
  map("<Tab>", function()
    call(self.on_tab)
  end)
  for _, lhs in ipairs({ "<Down>", "<C-n>" }) do
    map(lhs, function()
      call(self.on_down)
    end)
  end
  for _, lhs in ipairs({ "<Up>", "<C-p>" }) do
    map(lhs, function()
      call(self.on_up)
    end)
  end

  configure_window(self.win)
  return self
end

function Input:set_win(win)
  self.win = win
  configure_window(self.win)
  self:set_addons(self.addons)
end

function Input:set_prompt(prompt)
  self.prompt = prompt or ""
  vim.fn.prompt_setprompt(self.buf, self.prompt)
end

function Input:get_value()
  return (vim.api.nvim_buf_get_lines(self.buf, 0, 1, false)[1] or "")
end

function Input:set_value(value)
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { tostring(value or "") })
  cursor_to_eol(self.win, self.buf)
  self:set_addons(self.addons)
end

function Input:focus(insert_mode)
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

function Input:set_addons(addons)
  self.addons = addons or {}
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)

  local first = (vim.api.nvim_buf_get_lines(self.buf, 0, 1, false)[1] or ""):sub(1, 1)
  if MODE_PREFIX[first] then
    pcall(vim.api.nvim_buf_add_highlight, self.buf, self.ns, MODE_HL, 0, 0, 1)
  end

  local right = normalise_chunks(self.addons.right, "Comment")
  if right then
    vim.api.nvim_buf_set_extmark(self.buf, self.ns, 0, 0, {
      virt_text = right,
      virt_text_pos = "right_align",
      hl_mode = "combine",
    })
  end

  local left = normalise_chunks(self.addons.left, "Comment")
  if left then
    vim.api.nvim_buf_set_extmark(self.buf, self.ns, 0, 0, {
      virt_text = left,
      virt_text_win_col = 0,
      hl_mode = "combine",
    })
  end
end

M.new = function(opts)
  return Input.new(opts)
end

return M
