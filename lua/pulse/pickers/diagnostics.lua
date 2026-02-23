local M = {}
local util = require("pulse.util")

local severity_name = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

function M.seed(ctx)
  local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
  return { current_bufnr = bufnr }
end

function M.items(state, query)
  local match = util.make_matcher(query or "", { ignore_case = true, plain = true })
  local current_bufnr = state.current_bufnr or vim.api.nvim_get_current_buf()
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(nil)) do
    local name = severity_name[d.severity] or "INFO"
    local bufnr = d.bufnr or current_bufnr
    local filename = vim.api.nvim_buf_get_name(bufnr)
    local msg = tostring(d.message or ""):gsub("\n.*$", "")
    local item = {
      kind = "diagnostic",
      bufnr = bufnr,
      in_current = bufnr == current_bufnr,
      filename = filename,
      lnum = (d.lnum or 0) + 1,
      col = (d.col or 0) + 1,
      message = msg,
      source = d.source or "",
      severity = d.severity,
      severity_name = name,
    }
    local hay = table.concat({ msg, name, item.source, filename }, " ")
    if match(hay) then
      out[#out + 1] = item
    end
  end

  table.sort(out, function(a, b)
    if a.in_current ~= b.in_current then
      return a.in_current
    end
    if a.severity == b.severity then
      if a.filename == b.filename then
        if a.lnum == b.lnum then
          return a.col < b.col
        end
        return a.lnum < b.lnum
      end
      return (a.filename or "") < (b.filename or "")
    end
    return (a.severity or 99) < (b.severity or 99)
  end)

  return out
end

return M
