local M = {}
local Preview = {}
Preview.__index = Preview

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

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.wo[self.win].number = false
    vim.wo[self.win].relativenumber = false
    vim.wo[self.win].signcolumn = "no"
    vim.wo[self.win].foldcolumn = "0"
    vim.wo[self.win].statuscolumn = ""
    vim.wo[self.win].wrap = false
  end

  return self
end

function Preview:set(lines, filetype, highlights, line_numbers, focus_row)
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines or {})
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
    pcall(vim.api.nvim_win_set_cursor, self.win, { math.max(focus_row or 1, 1), 0 })
  end
end

M.new = function(opts)
  return Preview.new(opts)
end

return M
