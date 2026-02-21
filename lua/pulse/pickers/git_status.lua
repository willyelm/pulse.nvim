local M = {}
local util = require("pulse.util")
local ok_devicons, devicons = pcall(require, "nvim-web-devicons")

local function devicon_for(path)
  if not ok_devicons then
    return ""
  end
  local name = vim.fn.fnamemodify(path or "", ":t")
  local ext = vim.fn.fnamemodify(path or "", ":e")
  return devicons.get_icon(name, ext, { default = true }) or ""
end

local function normalize_status_path(path)
  if not path or path == "" then
    return ""
  end
  if path:find(" -> ", 1, true) then
    local _, newp = path:match("^(.-) %-%> (.+)$")
    return newp or path
  end
  return path
end

local function parse_status_line(line)
  local code = line:sub(1, 2)
  local rest = vim.trim(line:sub(4))
  if rest == "" then
    return nil
  end

  local path = normalize_status_path(rest)

  return {
    kind = "git_status",
    code = code,
    path = path,
    filename = path,
  }
end

local function parse_numstat_line(line)
  local added, removed, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
  if not (added and removed and path) then
    return nil
  end
  local a = tonumber(added) or 0
  local r = tonumber(removed) or 0
  return normalize_status_path(path), a, r
end

local function build_numstat_map()
  local map = {}
  local function absorb(lines)
    for _, line in ipairs(lines or {}) do
      local path, a, r = parse_numstat_line(line)
      if path and path ~= "" then
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

local function build_display(item)
  local name = vim.fn.fnamemodify(item.path or "", ":t")
  local code = vim.trim(item.code or "")
  local add_s = "+" .. tostring(item.added or 0)
  local del_s = "-" .. tostring(item.removed or 0)
  local left = string.format("%s %s", devicon_for(item.path), name)
  local right = string.format("%s %s %s", add_s, del_s, code)

  item.display_left = left
  item.display_right = right
end

function M.seed()
  return { files = {}, all_files = {} }
end

function M.items(state, query)
  local q = string.lower(vim.trim(query or ""))
  state.files = {}
  state.all_files = {}

  local lines = vim.fn.systemlist({ "git", "status", "--porcelain=v1" })
  if vim.v.shell_error ~= 0 then
    return {}
  end

  local stats = build_numstat_map()
  for _, line in ipairs(lines) do
    local item = parse_status_line(line)
    if item then
      local stat = stats[item.path] or { added = 0, removed = 0 }
      item.added = stat.added
      item.removed = stat.removed
      build_display(item)
      state.all_files[#state.all_files + 1] = item
      local hay = item.path .. " " .. item.code
      if util.contains_ci(hay, q) then
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
