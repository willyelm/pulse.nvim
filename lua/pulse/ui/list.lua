local M = {}
local List = {}
List.__index = List

local function clamp(value, min_value, max_value)
  return math.min(math.max(value, min_value), max_value)
end

function List.new(opts)
  local self = setmetatable({}, List)
  self.buf = assert(opts.buf, "list requires a buffer")
  self.win = assert(opts.win, "list requires a window")
  self.max_visible = opts.max_visible or 15
  self.min_visible = opts.min_visible or 3
  self.render_item = assert(opts.render_item, "list requires render_item callback")
  self.items = {}
  self.selected = 1
  self.offset = 1
  self.visible_count = self.min_visible

  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].modifiable = false
  vim.bo[self.buf].filetype = "pulselist"

  return self
end

function List:_normalise_selection()
  if #self.items == 0 then
    self.selected = 1
    self.offset = 1
    return
  end

  self.selected = clamp(self.selected, 1, #self.items)
  local max_offset = math.max(#self.items - self.visible_count + 1, 1)
  self.offset = clamp(self.offset, 1, max_offset)

  if self.selected < self.offset then
    self.offset = self.selected
  end
  if self.selected > self.offset + self.visible_count - 1 then
    self.offset = self.selected - self.visible_count + 1
  end
end

function List:_visible_lines(width)
  local lines = {}
  local highlights = {}
  local content_width = width

  for row = 1, self.visible_count do
    local index = self.offset + row - 1
    local item = self.items[index]
    local text, hl = "", nil
    if item then
      text, hl = self.render_item(item)
      text = tostring(text or "")
    end

    if #text > content_width then
      text = text:sub(1, math.max(content_width - 1, 1))
    end
    local padded = text .. string.rep(" ", math.max(content_width - #text, 0))

    lines[#lines + 1] = padded
    if hl and item then
      highlights[#highlights + 1] = {
        group = hl,
        row = row - 1,
        start_col = 0,
        end_col = math.min(#text, content_width),
      }
    end
    if item and index == self.selected then
      highlights[#highlights + 1] = {
        group = "CursorLine",
        row = row - 1,
        start_col = 0,
        end_col = -1,
      }
    end
  end

  return lines, highlights
end

function List:render(width)
  width = width or (self.win and vim.api.nvim_win_get_width(self.win)) or 20
  self:_normalise_selection()

  local lines, highlights = self:_visible_lines(width)
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false

  local ns = vim.api.nvim_create_namespace("pulse_ui_list")
  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  for _, item in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, self.buf, ns, item.group, item.row, item.start_col, item.end_col)
  end
end

function List:set_items(items)
  self.items = items or {}
  local count = #self.items
  self.visible_count = clamp(count, self.min_visible, self.max_visible)
  if count == 0 then
    self.visible_count = self.min_visible
  end
  self:_normalise_selection()
end

function List:set_selected(index)
  self.selected = index or 1
  self:_normalise_selection()
end

function List:selected_item()
  return self.items[self.selected]
end

function List:move(delta, skip)
  if #self.items == 0 then
    return
  end

  local guard = 0
  repeat
    self.selected = clamp(self.selected + delta, 1, #self.items)
    guard = guard + 1
    local item = self.items[self.selected]
    if not skip or not skip(item) then
      break
    end
    if (self.selected == 1 and delta < 0) or (self.selected == #self.items and delta > 0) then
      break
    end
  until guard > #self.items

  self:_normalise_selection()
end

M.new = function(opts)
  return List.new(opts)
end

return M
