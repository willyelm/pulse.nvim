local M = {}

M.mode = {
	name = "git_status",
	start = "~",
	icon = "󰊢",
	placeholder = "Search Git Status",
}

M.preview = function(item)
	return item and item.added + item.removed > 0
end

M.on_tab = false

local function normalize_status_path(path)
  if not path or path == "" then return "" end
  if path:find(" -> ", 1, true) then
    local _, newp = path:match("^(.-) %-%> (.+)$")
    return newp or path
  end
  return path
end
local function build_numstat_map()
  local map = {}
  local function absorb(lines)
    for _, line in ipairs(lines or {}) do
      local added, removed, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
      if path and path ~= "" then
        local a = tonumber(added) or 0
        local r = tonumber(removed) or 0
        path = normalize_status_path(path)
        local row = map[path] or { added = 0, removed = 0 }
        row.added = row.added + a
        row.removed = row.removed + r
        map[path] = row
      end
    end
  end
  absorb(vim.fn.systemlist({ "git", "diff", "--numstat" }))
  absorb(vim.fn.systemlist({ "git", "diff", "--cached", "--numstat" }))
  return map
end
function M.init(ctx)
	-- Define highlight groups for git stats
	pcall(vim.api.nvim_set_hl, 0, "PulseAdd", { link = "Added", default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseDelete", { link = "Removed", default = true })
	return { files = {}, all_files = {} }
end

function M.items(state, query)
  local pulse = require("pulse")
  local q = vim.trim(query or "")
  local match = pulse.make_matcher(q, { ignore_case = true, plain = true })
  state.files = {}
  state.all_files = {}
  local zero = { added = 0, removed = 0 }

  local lines = vim.fn.systemlist({ "git", "status", "--porcelain=v1" })
  if vim.v.shell_error ~= 0 then
    return {}
  end
  local stats = build_numstat_map()
  for _, line in ipairs(lines) do
    local code = line:sub(1, 2)
    local rest = vim.trim(line:sub(4))
    if rest ~= "" then
      local path = normalize_status_path(rest)
      local stat = stats[path] or zero
      local item = {
        kind = "git_status",
        code = vim.trim(code),
        path = path,
        filename = path,
        added = stat.added,
        removed = stat.removed,
      }
      local display = {}
      if item.added > 0 then display[#display + 1] = "+" .. item.added end
      if item.removed > 0 then display[#display + 1] = "-" .. item.removed end
      if item.code ~= "" then display[#display + 1] = item.code end
      item.display_right = table.concat(display, " ")
      state.all_files[#state.all_files + 1] = item
      if match(item.path .. " " .. item.code) then
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
