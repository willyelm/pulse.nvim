local M = {}

function M.title()
  return "Live Grep"
end

local function ci(h, n)
  if n == "" then
    return true
  end
  return string.find(string.lower(h or ""), string.lower(n), 1, true) ~= nil
end

function M.seed()
  return {}
end

function M.items(_, query)
  local q = vim.trim(query or "")
  if q == "" then
    return {}
  end

  local out = {}
  local lines = vim.fn.systemlist({ "rg", "--vimgrep", "--hidden", "-g", "!.git", q })
  if vim.v.shell_error ~= 0 and #lines == 0 then
    return out
  end

  for _, line in ipairs(lines) do
    local path, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    if path and lnum and col then
      out[#out + 1] = {
        kind = "live_grep",
        path = path,
        filename = path,
        lnum = tonumber(lnum),
        col = tonumber(col),
        text = text or "",
        query = q,
      }
    end
  end

  if #out == 0 then
    -- Fallback fuzzy filter against files when rg has no direct hit formatting.
    local files = vim.fn.systemlist({ "rg", "--files", "--hidden", "-g", "!.git" })
    for _, path in ipairs(files) do
      if ci(path, q) then
        out[#out + 1] = {
          kind = "live_grep",
          path = path,
          filename = path,
          lnum = 1,
          col = 1,
          text = "",
          query = q,
        }
      end
    end
  end

  return out
end

return M
