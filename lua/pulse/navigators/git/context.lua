local diff_ui = require("pulse.ui.diff")
local context = require("pulse.context")
local util = require("pulse.navigators.git.util")

local M = {}
local CACHE = {}

local function read_head_file(path)
	local rel = vim.fn.fnamemodify(path or "", ":.")
	if rel == "" then
		return {}
	end
	return util.git_lines({ "git", "--no-pager", "show", "HEAD:" .. rel }) or {}
end

local function read_worktree_file(path)
	local resolved = (path and vim.fn.filereadable(path) == 1) and path or vim.fn.fnamemodify(path or "", ":p")
	return (vim.fn.filereadable(resolved) == 1) and vim.fn.readfile(resolved) or {}
end

local function git_patch_for(path)
	local diff = util.git_lines({ "git", "--no-pager", "diff", "--", path })
	if diff and #diff > 0 then
		return diff
	end
	diff = util.git_lines({ "git", "--no-pager", "diff", "--cached", "--", path })
	if diff and #diff > 0 then
		return diff
	end
	return { "No git diff for " .. tostring(path) }
end

local function read_commit_file(commit, path)
	if not (commit and path and path ~= "") then
		return {}
	end
	return util.git_lines({ "git", "--no-pager", "show", commit .. ":" .. path }) or {}
end

local function with_summary(lines, highlights, focus_row, added, removed)
	lines = vim.deepcopy(lines or {})
	highlights = vim.deepcopy(highlights or {})
	table.insert(lines, 1, util.diff_summary(added, removed))
	table.insert(lines, 2, "")
	for _, hl in ipairs(highlights) do
		hl.row = hl.row + 2
	end
	local summary = lines[1]
	local plus = summary:find("insertions%(%%+%)", 1)
	if plus then
		highlights[#highlights + 1] = { group = "PulseAdd", row = 0, start_col = 0, end_col = plus + 11, priority = 250 }
	end
	local minus = summary:find("deletions%(%%-%)", 1)
	if minus then
		local start_col = summary:sub(1, minus):match(".*(), ") or 0
		highlights[#highlights + 1] = { group = "PulseDelete", row = 0, start_col = start_col, end_col = #summary, priority = 250 }
	end
	return lines, highlights, (focus_row or 1) + 2
end

local function cached(key, producer)
	local value = CACHE[key]
	if value then
		return unpack(value)
	end
	value = { producer() }
	CACHE[key] = value
	return unpack(value)
end

function M.context_item(item)
	if item.kind == "git_commit" or item.kind == "git_commit_file" then
		if item.kind == "git_commit_file" or (item.history_kind == "file" and item.history_path) then
			local history_path = item.history_path or item.path
			return cached("file:" .. tostring(item.commit) .. ":" .. tostring(history_path), function()
				local old_lines = read_commit_file(item.parent or (item.commit .. "^"), history_path)
				local new_lines = read_commit_file(item.commit, history_path)
				local lines, highlights, focus_row = diff_ui.from_lines(old_lines, new_lines, { context = 3 })
				lines, highlights, focus_row = with_summary(lines, highlights, focus_row, item.added, item.removed)
				local _, filetype = context.file_snippet(history_path, 1)
				return lines, filetype, highlights, nil, focus_row
			end)
		end
		return cached("commit:" .. tostring(item.commit) .. ":" .. tostring(item.history_path or ""), function()
			local cmd = {
				"git",
				"--no-pager",
				"show",
				"--stat",
				"--format=format:%h  %as  %an <%ae>%n%n%s%n%b",
				item.commit,
			}
			if item.history_path then
				cmd[#cmd + 1] = "--"
				cmd[#cmd + 1] = item.history_path
			end
			local lines = util.git_lines(cmd)
			if not lines or #lines == 0 then
				lines = { "No git history for " .. tostring(item.commit or "") }
			end
			return lines, "git", {}, nil, 1
		end)
	end

	local path = item.path or item.filename
	return cached("status:" .. tostring(path) .. ":" .. tostring(item.code or ""), function()
		local old_lines, new_lines = read_head_file(path), read_worktree_file(path)
		if #old_lines == 0 and #new_lines == 0 then
			return git_patch_for(path), "text", {}, nil, 1
		end
		local lines, highlights, focus_row = diff_ui.from_lines(old_lines, new_lines, { context = 3 })
		lines, highlights, focus_row = with_summary(lines, highlights, focus_row, item.added, item.removed)
		local _, filetype = context.file_snippet(path, 1)
		return lines, filetype, highlights, nil, focus_row
	end)
end

return M
