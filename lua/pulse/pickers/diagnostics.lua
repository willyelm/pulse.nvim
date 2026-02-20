local M = {}

function M.title()
  return "Diagnostics"
end

local function ci(h, n)
  if n == "" then
    return true
  end
  return string.find(string.lower(h or ""), string.lower(n), 1, true) ~= nil
end

local severity_name = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

function M.seed(ctx)
  local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
  return { bufnr = bufnr }
end

function M.items(state, query)
  local bufnr = state.bufnr or vim.api.nvim_get_current_buf()
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    local name = severity_name[d.severity] or "INFO"
    local filename = vim.api.nvim_buf_get_name(bufnr)
    local msg = tostring(d.message or ""):gsub("\n.*$", "")
    local item = {
      kind = "diagnostic",
      filename = filename,
      lnum = (d.lnum or 0) + 1,
      col = (d.col or 0) + 1,
      message = msg,
      source = d.source or "",
      severity = d.severity,
      severity_name = name,
    }
    local hay = table.concat({ msg, name, item.source, filename }, " ")
    if ci(hay, query or "") then
      out[#out + 1] = item
    end
  end

  table.sort(out, function(a, b)
    if a.severity == b.severity then
      if a.lnum == b.lnum then
        return a.col < b.col
      end
      return a.lnum < b.lnum
    end
    return (a.severity or 99) < (b.severity or 99)
  end)

  return out
end

return M
