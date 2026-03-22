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
			local new_path = item.history_path or item.path
			local old_path = item.old_path or new_path
			return cached("file:" .. tostring(item.commit) .. ":" .. tostring(old_path) .. ":" .. tostring(new_path), function()
				local old_lines = read_commit_file(item.parent or (item.commit .. "^"), old_path)
				local new_lines = read_commit_file(item.commit, new_path)
				local lines, highlights, focus_row = diff_ui.from_lines(old_lines, new_lines, { context = 3 })
				local _, filetype = context.file_snippet(new_path, 1)
				return lines, filetype, highlights, nil, focus_row
			end)
		end
		return cached("commit:" .. tostring(item.commit) .. ":" .. tostring(item.history_path or ""), function()
			local info = util.git_lines({
				"git",
				"--no-pager",
				"show",
				"--stat",
				"--format=format:Commit: %h%nDate: %as%nAuthor: %an <%ae>",
				item.commit,
				"--",
				item.history_path or ".",
			}) or {}
			local lines = {}
			for _, line in ipairs(info) do
				if line:match("files? changed") then
					lines[#lines + 1] = ""
					lines[#lines + 1] = line
					break
				end
				if line ~= "" and not line:find(" | ", 1, true) then
					lines[#lines + 1] = line
				end
			end
			if #lines == 0 then
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
		local _, filetype = context.file_snippet(path, 1)
		return lines, filetype, highlights, nil, focus_row
	end)
end

return M
