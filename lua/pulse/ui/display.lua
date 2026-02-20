local M = {}

--- Create a two-column entry displayer.
--- @param opts table Optional: { separator = " " }
--- @return function displayer(items, width) -> text, highlights
function M.create(opts)
  local sep = (opts and opts.separator) or " "
  local right_width = 22

  return function(items, width)
    width = width or 80
    local left_width = math.max(1, width - right_width - #sep)

    local left_item = items[1] or {}
    local right_item = items[2] or {}

    local left_text = tostring(left_item[1] or "")
    local right_text = tostring(right_item[1] or "")
    local left_hl = left_item[2]
    local right_hl = right_item[2]

    -- Truncate left column if wider than available display cells
    local left_dw = vim.fn.strdisplaywidth(left_text)
    if left_dw > left_width then
      local truncated = vim.fn.strcharpart(left_text, 0, left_width - 1)
      if truncated == left_text then
        truncated = vim.fn.strcharpart(left_text, 0, vim.fn.strchars(left_text) - 1)
      end
      left_text = truncated .. "\xe2\x80\xa6"
      left_dw = vim.fn.strdisplaywidth(left_text)
    end

    -- Pad left to fill left_width display cells
    local left_padded = left_text .. string.rep(" ", math.max(0, left_width - left_dw))

    -- Right-justify right text in right_width display cells
    local right_dw = vim.fn.strdisplaywidth(right_text)
    local right_padded = string.rep(" ", math.max(0, right_width - right_dw)) .. right_text

    local text = left_padded .. sep .. right_padded

    -- Build highlight specs using byte offsets: { hl_group, 0, col_start, col_end }
    local highlights = {}
    local left_bytes = #left_padded
    local sep_bytes = #sep

    if left_hl then
      highlights[#highlights + 1] = { left_hl, 0, 0, left_bytes }
    end
    local right_start = left_bytes + sep_bytes
    if right_hl then
      highlights[#highlights + 1] = { right_hl, 0, right_start, right_start + #right_padded }
    end

    return text, highlights
  end
end

return M
