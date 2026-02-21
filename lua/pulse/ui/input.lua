local M = {}
local Input = {}
Input.__index = Input

local function cursor_to_eol(win, buf)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local line = (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
  pcall(vim.api.nvim_win_set_cursor, win, { 1, #line })
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

  vim.bo[self.buf].buftype = "prompt"
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].filetype = "pulseinput"

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
  local function call(fn)
    if fn then
      fn()
    end
  end

  map("<CR>", function()
    if self.on_submit then
      self.on_submit(self:get_value())
    end
  end)
  map("<Esc>", function()
    call(self.on_escape)
  end)
  map("<Down>", function()
    call(self.on_down)
  end)
  map("<ScrollWheelDown>", function()
    call(self.on_down)
  end)
  map("<C-n>", function()
    call(self.on_down)
  end)
  map("<Up>", function()
    call(self.on_up)
  end)
  map("<ScrollWheelUp>", function()
    call(self.on_up)
  end)
  map("<C-p>", function()
    call(self.on_up)
  end)
  map("<Tab>", function()
    call(self.on_tab)
  end)

  return self
end

function Input:set_prompt(prompt)
  self.prompt = prompt or ""
  vim.fn.prompt_setprompt(self.buf, self.prompt)
end

function Input:get_value()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, 1, false)
  return lines[1] or ""
end

function Input:set_value(value)
  local text = tostring(value or "")
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { text })
  cursor_to_eol(self.win, self.buf)
end

function Input:focus(insert_mode)
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_set_current_win(self.win)
    if insert_mode ~= false then
      cursor_to_eol(self.win, self.buf)
      vim.cmd("startinsert!")
    end
  end
end

M.new = function(opts)
  return Input.new(opts)
end

return M
