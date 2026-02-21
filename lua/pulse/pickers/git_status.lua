local M = {}

local function ci(h, n)
  if n == "" then
    return true
  end
  return string.find(string.lower(h or ""), string.lower(n), 1, true) ~= nil
end

local function parse_status_line(line)
  local code = line:sub(1, 2)
  local rest = vim.trim(line:sub(4))
  if rest == "" then
    return nil
  end

  local path = rest
  if rest:find(" -> ", 1, true) then
    local _, newp = rest:match("^(.-) %-%> (.+)$")
    path = newp or rest
  end

  return {
    kind = "git_status",
    code = code,
    path = path,
    filename = path,
  }
end

function M.seed()
  return { files = {}, all_files = {} }
end

function M.items(state, query)
  local q = vim.trim(query or "")
  state.files = {}
  state.all_files = {}

  local lines = vim.fn.systemlist({ "git", "status", "--porcelain=v1" })
  if vim.v.shell_error ~= 0 then
    return {}
  end

  for _, line in ipairs(lines) do
    local item = parse_status_line(line)
    if item then
      state.all_files[#state.all_files + 1] = item
      local hay = item.path .. " " .. item.code
      if ci(hay, q) then
        state.files[#state.files + 1] = item
      end
    end
  end

  return state.files
end

function M.total_count(state)
  return #(state.all_files or {})
end

return M
