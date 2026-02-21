local M = {}
local Input = {}
Input.__index = Input

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
  vim.keymap.set({ "i", "n" }, "<CR>", function()
    if self.on_submit then
      self.on_submit(self:get_value())
    end
  end, map_opts)
  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    if self.on_escape then
      self.on_escape()
    end
  end, map_opts)
  vim.keymap.set({ "i", "n" }, "<Down>", function()
    if self.on_down then
      self.on_down()
    end
  end, map_opts)
  vim.keymap.set({ "i", "n" }, "<ScrollWheelDown>", function()
    if self.on_down then
      self.on_down()
    end
  end, map_opts)
  vim.keymap.set({ "i", "n" }, "<C-n>", function()
    if self.on_down then
      self.on_down()
    end
  end, map_opts)
  vim.keymap.set({ "i", "n" }, "<Up>", function()
    if self.on_up then
      self.on_up()
    end
  end, map_opts)
  vim.keymap.set({ "i", "n" }, "<ScrollWheelUp>", function()
    if self.on_up then
      self.on_up()
    end
  end, map_opts)
  vim.keymap.set({ "i", "n" }, "<C-p>", function()
    if self.on_up then
      self.on_up()
    end
  end, map_opts)
  vim.keymap.set({ "i", "n" }, "<Tab>", function()
    if self.on_tab then
      self.on_tab()
    end
  end, map_opts)

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
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { value or "" })
  vim.bo[self.buf].modifiable = true
end

function Input:focus(insert_mode)
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_set_current_win(self.win)
    if insert_mode ~= false then
      vim.cmd.startinsert()
    end
  end
end

M.new = function(opts)
  return Input.new(opts)
end

return M
