local M = {}
local Box = {}
Box.__index = Box

local function clamp(v, lo, hi)
  return math.min(math.max(v, lo), hi)
end

local function resolve_size(v, total, minv)
  if type(v) ~= "number" then
    return minv
  end
  if v > 0 and v < 1 then
    return clamp(math.floor(total * v), minv, total)
  end
  return clamp(math.floor(v), minv, total)
end

local function resolve_pos(v, total, size)
  if type(v) == "number" and v >= 0 and v < 1 then
    return math.floor((total - size) * v)
  end
  if type(v) == "number" then
    return math.max(math.floor(v), 0)
  end
  return math.floor((total - size) / 2)
end

local function existing_cfg(cfg)
  local c = vim.deepcopy(cfg)
  c.noautocmd = nil
  return c
end

function Box.new(opts)
  local self = setmetatable({}, Box)
  self.opts = vim.tbl_deep_extend("force", {
    width = 0.7,
    height = 0.6,
    row = nil,
    col = nil,
    border = "rounded",
    style = "minimal",
    focusable = true,
    zindex = 50,
    winhl = "Normal:NormalFloat,FloatBorder:FloatBorder",
    noautocmd = true,
  }, opts or {})
  self.buf = self.opts.buf or vim.api.nvim_create_buf(false, true)
  self.win = nil
  self.sections = {}
  return self
end

function Box:is_valid()
  return self.win and vim.api.nvim_win_is_valid(self.win)
end

function Box:_cfg(overrides)
  local o = vim.tbl_deep_extend("force", self.opts, overrides or {})
  local cols, lines = vim.o.columns, (vim.o.lines - vim.o.cmdheight)
  local width = resolve_size(o.width, cols, 20)
  local height = resolve_size(o.height, lines, 6)
  return {
    relative = "editor",
    row = resolve_pos(o.row, lines, height),
    col = resolve_pos(o.col, cols, width),
    width = width,
    height = height,
    style = o.style,
    border = o.border,
    focusable = o.focusable,
    noautocmd = o.noautocmd,
    zindex = o.zindex,
  }
end

function Box:mount(overrides)
  local cfg = self:_cfg(overrides)
  if self:is_valid() then
    vim.api.nvim_win_set_config(self.win, existing_cfg(cfg))
    return self.win, self.buf, nil
  end
  local ok, win = pcall(vim.api.nvim_open_win, self.buf, true, cfg)
  if not ok then
    return nil, self.buf, tostring(win)
  end
  self.win = win
  if self.opts.winhl and self.opts.winhl ~= "" then
    vim.api.nvim_set_option_value("winhl", self.opts.winhl, { win = self.win })
  end
  vim.bo[self.buf].bufhidden, vim.bo[self.buf].swapfile, vim.bo[self.buf].modifiable = "wipe", false, true
  return self.win, self.buf, nil
end

function Box:update(opts)
  if not self:is_valid() then return end
  self.opts = vim.tbl_deep_extend("force", self.opts, opts or {})
  vim.api.nvim_win_set_config(self.win, existing_cfg(self:_cfg()))
end

function Box:create_section(name, opts)
  if not self:is_valid() then return nil end
  local o = vim.tbl_deep_extend("force", {
    row = 0, col = 0, width = 20, height = 1,
    border = "none", style = "minimal", focusable = false, noautocmd = true,
    zindex = (self.opts.zindex or 50) + 1, winhl = "Normal:NormalFloat,FloatBorder:FloatBorder",
    enter = false, buf = nil,
  }, opts or {})
  local ex = self.sections[name]
  local buf = (ex and ex.buf and vim.api.nvim_buf_is_valid(ex.buf)) and ex.buf or o.buf or vim.api.nvim_create_buf(false, true)
  local cfg = {
    relative = "win", win = self.win, row = o.row, col = o.col, width = o.width, height = o.height,
    style = o.style, border = o.border, focusable = o.focusable, noautocmd = o.noautocmd, zindex = o.zindex,
  }
  local win = ex and ex.win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, existing_cfg(cfg))
  else
    win = vim.api.nvim_open_win(buf, o.enter, cfg)
  end
  if o.winhl and o.winhl ~= "" then
    vim.api.nvim_set_option_value("winhl", o.winhl, { win = win })
  end
  vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "wipe", false
  local s = { win = win, buf = buf, opts = o }
  self.sections[name] = s
  return s
end

function Box:close_section(name)
  local s = self.sections[name]
  if s and s.win and vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end
  self.sections[name] = nil
end

function Box:unmount()
  for name in pairs(self.sections) do self:close_section(name) end
  if self:is_valid() then pcall(vim.api.nvim_win_close, self.win, true) end
  self.win = nil
end

M.new = function(opts) return Box.new(opts) end

return M
