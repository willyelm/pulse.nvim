local M = {}
local Layout = {}
Layout.__index = Layout

function Layout.new(box)
  return setmetatable({
    box = box,
    sections = {},
    state = { body = nil, preview = nil, width = nil },
  }, Layout)
end

local function set_divider(buf, width)
  local line = string.rep("─", width)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.bo[buf].modifiable = false
end

function Layout:upsert(name, opts)
  local current = self.sections[name]
  if current and current.buf and vim.api.nvim_buf_is_valid(current.buf) then
    opts.buf = current.buf
  end
  self.sections[name] = self.box:create_section(name, opts)
  return self.sections[name]
end

function Layout:apply(body_height, preview_height, refs)
  local width = vim.api.nvim_win_get_width(self.box.win)
  if
    self.sections.input
    and self.state.body == body_height
    and self.state.preview == preview_height
    and self.state.width == width
  then
    return
  end

  self.box:update({ height = body_height + preview_height + 3 })
  width = vim.api.nvim_win_get_width(self.box.win)

  local function place(name, row, height, focusable, winhl)
    self:upsert(name, {
      row = row,
      col = 0,
      width = width,
      height = height,
      focusable = focusable,
      enter = false,
      winhl = winhl,
    })
  end

  place("input", 0, 1, true, "Normal:NormalFloat")
  place("divider", 1, 1, false, "Normal:FloatBorder")
  set_divider(self.sections.divider.buf, width)

  place("list", 2, body_height, true, "Normal:NormalFloat,CursorLine:CursorLine")
  place("body_divider", 2 + body_height, 1, false, "Normal:FloatBorder")
  set_divider(self.sections.body_divider.buf, width)
  place("preview", 3 + body_height, preview_height, true, "Normal:NormalFloat")

  if refs.list then
    refs.list.win = self.sections.list.win
  end
  if refs.preview then
    refs.preview.win = self.sections.preview.win
  end
  if refs.input then
    refs.input.win = self.sections.input.win
  end

  self.state.body = body_height
  self.state.preview = preview_height
  self.state.width = width
end

M.new = function(box)
  return Layout.new(box)
end

return M
