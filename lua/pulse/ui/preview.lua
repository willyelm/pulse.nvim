local M = {}
local Preview = {}
Preview.__index = Preview
local window = require("pulse.ui.window")

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

function Preview.new(opts)
  local self = setmetatable({}, Preview)
  self.buf = assert(opts.buf, "preview requires a buffer")
  self.win = assert(opts.win, "preview requires a window")
  self.ns = vim.api.nvim_create_namespace("pulse_ui_preview")

  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].modifiable = false
  vim.bo[self.buf].filetype = "text"

  window.configure_content_window(self.win)

  return self
end

function Preview:set(lines, filetype, highlights, line_numbers, focus_row)
  local safe_lines = normalise_lines(lines)
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, safe_lines)
  vim.bo[self.buf].modifiable = false

  vim.bo[self.buf].filetype = filetype or "text"
  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)

  if filetype and filetype ~= "" and filetype ~= "text" then
    pcall(vim.treesitter.start, self.buf, filetype)
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
  end
end

M.new = function(opts)
  return Preview.new(opts)
end

return M
