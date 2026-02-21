local M = {}
local Box = {}
Box.__index = Box

local function clamp(value, min_value, max_value)
  return math.min(math.max(value, min_value), max_value)
end

local function resolve_size(value, total, min_value)
  if type(value) == "number" and value > 0 and value < 1 then
    return clamp(math.floor(total * value), min_value, total)
  end
  if type(value) == "number" then
    return clamp(math.floor(value), min_value, total)
  end
  return min_value
end

local function resolve_position(value, total, size)
  if type(value) == "number" and value >= 0 and value < 1 then
    return math.floor((total - size) * value)
  end
  if type(value) == "number" then
    return math.max(math.floor(value), 0)
  end
  return math.floor((total - size) / 2)
end

local function config_for_existing_window(cfg)
  local copy = vim.deepcopy(cfg)
  copy.noautocmd = nil
  return copy
end

function Box.new(opts)
  local self = setmetatable({}, Box)
  self.opts = vim.tbl_deep_extend("force", {
    width = 0.7,
    height = 0.6,
    row = nil,
    col = nil,
    border = "rounded",
    title = nil,
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

function Box:_resolve_main_config(overrides)
  local cfg = vim.tbl_deep_extend("force", self.opts, overrides or {})
  local total_columns = vim.o.columns
  local total_lines = vim.o.lines - vim.o.cmdheight

  local width = resolve_size(cfg.width, total_columns, 20)
  local height = resolve_size(cfg.height, total_lines, 6)
  local row = resolve_position(cfg.row, total_lines, height)
  local col = resolve_position(cfg.col, total_columns, width)

  return {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = cfg.style,
    border = cfg.border,
    title = cfg.title,
    focusable = cfg.focusable,
    noautocmd = cfg.noautocmd,
    zindex = cfg.zindex,
  }
end

function Box:mount(overrides)
  local cfg = self:_resolve_main_config(overrides)
  if self:is_valid() then
    vim.api.nvim_win_set_config(self.win, config_for_existing_window(cfg))
    return self.win, self.buf, nil
  end

  local ok, win_or_err = pcall(vim.api.nvim_open_win, self.buf, true, cfg)
  if not ok then
    return nil, self.buf, tostring(win_or_err)
  end
  self.win = win_or_err
  if self.opts.winhl and self.opts.winhl ~= "" then
    vim.api.nvim_set_option_value("winhl", self.opts.winhl, { win = self.win })
  end

  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].modifiable = true

  return self.win, self.buf, nil
end

function Box:update(opts)
  if not self:is_valid() then
    return
  end

  self.opts = vim.tbl_deep_extend("force", self.opts, opts or {})
  local cfg = self:_resolve_main_config()
  vim.api.nvim_win_set_config(self.win, config_for_existing_window(cfg))
end

function Box:create_section(name, opts)
  if not self:is_valid() then
    return nil
  end

  local section_opts = vim.tbl_deep_extend("force", {
    row = 0,
    col = 0,
    width = 20,
    height = 1,
    border = "none",
    style = "minimal",
    focusable = false,
    noautocmd = true,
    zindex = (self.opts.zindex or 50) + 1,
    winhl = "Normal:NormalFloat,FloatBorder:FloatBorder",
    enter = false,
    buf = nil,
  }, opts or {})

  local existing = self.sections[name]
  local buf = section_opts.buf
  if existing and existing.buf and vim.api.nvim_buf_is_valid(existing.buf) then
    buf = existing.buf
  end
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
  end

  local cfg = {
    relative = "win",
    win = self.win,
    row = section_opts.row,
    col = section_opts.col,
    width = section_opts.width,
    height = section_opts.height,
    style = section_opts.style,
    border = section_opts.border,
    focusable = section_opts.focusable,
    noautocmd = section_opts.noautocmd,
    zindex = section_opts.zindex,
  }

  local win = existing and existing.win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, config_for_existing_window(cfg))
  else
    win = vim.api.nvim_open_win(buf, section_opts.enter, cfg)
  end

  if section_opts.winhl and section_opts.winhl ~= "" then
    vim.api.nvim_set_option_value("winhl", section_opts.winhl, { win = win })
  end

  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local section = { win = win, buf = buf, opts = section_opts }
  self.sections[name] = section
  return section
end

function Box:section(name)
  return self.sections[name]
end

function Box:close_section(name)
  local section = self.sections[name]
  if not section then
    return
  end
  if section.win and vim.api.nvim_win_is_valid(section.win) then
    pcall(vim.api.nvim_win_close, section.win, true)
  end
  self.sections[name] = nil
end

function Box:unmount()
  for name in pairs(self.sections) do
    self:close_section(name)
  end
  if self:is_valid() then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.win = nil
end

M.new = function(opts)
  return Box.new(opts)
end

return M
