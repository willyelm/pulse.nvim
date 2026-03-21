local M = {}
local diff_ui = require("pulse.ui.diff")
local context = require("pulse.context")

M.mode = {
	name = "git_status",
	start = "~",
	icon = "󰊢",
	placeholder = "Search Git Status",
}

M.context = function(item)
	return item and (item.code == "??" or item.added + item.removed > 0)
end

local function line_count(path)
	local resolved = (path and vim.fn.filereadable(path) == 1) and path or vim.fn.fnamemodify(path or "", ":p")
	if vim.fn.filereadable(resolved) ~= 1 then
		return 0
	end
	return #vim.fn.readfile(resolved)
end

local function read_head_file(path)
  local rel = vim.fn.fnamemodify(path or "", ":.")
  if rel == "" then
    return {}
  end
  local lines = vim.fn.systemlist({ "git", "--no-pager", "show", "HEAD:" .. rel })
  return (vim.v.shell_error == 0) and lines or {}
end

local function read_worktree_file(path)
  local r = (path and vim.fn.filereadable(path) == 1) and path or vim.fn.fnamemodify(path or "", ":p")
  return (vim.fn.filereadable(r) == 1) and vim.fn.readfile(r) or {}
end

local function git_patch_for(path)
  local diff = vim.fn.systemlist({ "git", "--no-pager", "diff", "--", path })
  if vim.v.shell_error == 0 and #diff > 0 then
    return diff
  end
  diff = vim.fn.systemlist({ "git", "--no-pager", "diff", "--cached", "--", path })
  if vim.v.shell_error == 0 and #diff > 0 then
    return diff
  end
  return { "No git diff for " .. tostring(path) }
end

function M.context_item(item)
  local path = item.path or item.filename
  local old_lines, new_lines = read_head_file(path), read_worktree_file(path)
  if #old_lines == 0 and #new_lines == 0 then
    return git_patch_for(path), "text", {}, nil, 1
  end
  local lines, highlights, focus_row = diff_ui.from_lines(old_lines, new_lines, { context = 3 })
  local _, filetype = context.file_snippet(path, 1)
  return lines, filetype, highlights, nil, focus_row
end

M.on_tab = false

local function normalize_status_path(path)
  if not path or path == "" then return "" end
  if path:find(" -> ", 1, true) then
    local _, newp = path:match("^(.-) %-%> (.+)$")
    return newp or path
  end
  if path:sub(-1) == "/" then
    return path:sub(1, -2)
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
	pcall(vim.api.nvim_set_hl, 0, "PulseChange", { link = "Changed", default = true })
	return { files = {}, all_files = {} }
end

function M.items(state, query)
  local pulse = require("pulse")
  local q = vim.trim(query or "")
  local match = pulse.make_matcher(q, { ignore_case = true, plain = true })
  state.files = {}
  state.all_files = {}
  local zero = { added = 0, removed = 0 }

  local lines = vim.fn.systemlist({ "git", "status", "--porcelain=v1", "--untracked-files=all" })
  if vim.v.shell_error ~= 0 then
    return {}
  end
  local stats = build_numstat_map()
  for _, line in ipairs(lines) do
    local code = line:sub(1, 2)
    local rest = vim.trim(line:sub(4))
    if rest ~= "" then
      local path = normalize_status_path(rest)
      if path == "" then
        goto continue
      end
      local stat = stats[path] or zero
      local code_trim = vim.trim(code)
      local added = stat.added
      if code_trim == "??" and added == 0 then
        added = line_count(path)
      end
      local item = {
        kind = "git_status",
        code = code_trim,
        path = path,
        filename = path,
        added = added,
        removed = stat.removed,
      }
      local display = {}
      if item.added > 0 then display[#display + 1] = "+" .. item.added end
      if item.removed > 0 then display[#display + 1] = "-" .. item.removed end
      local label = item.code
      if label then display[#display + 1] = label end
      item.display_right = table.concat(display, " ")
      state.all_files[#state.all_files + 1] = item
      if match(item.path .. " " .. item.code) then
        state.files[#state.files + 1] = item
      end
    end
    ::continue::
  end
  return state.files
end
function M.total_count(state)
  return #(state.all_files or {})
end
return M
