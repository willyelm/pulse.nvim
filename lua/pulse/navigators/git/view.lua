local diff_ui = require("pulse.ui.diff")
local view = require("pulse.panel_view")
local util = require("pulse.navigators.git.util")

local M = {}
local CACHE = {}

-- `git show` needs a path relative to the repo root, not an absolute one.
local function read_head_file(path)
	return view.read_git_blob_lines("HEAD", vim.fn.fnamemodify(path or "", ":."))
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

-- Shape a set of preview lines (real content or a placeholder) into the
-- 5-tuple view_item's callers expect.
local function as_view(lines, highlights, focus_row, filetype)
	return lines, filetype or "text", highlights or {}, nil, focus_row or 1
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

function M.view_item(item)
	if item.kind == "git_commit" or item.kind == "git_commit_file" then
		if item.kind == "git_commit_file" or (item.history_kind == "file" and item.history_path) then
			local new_path = item.history_path or item.path
			local old_path = item.old_path or new_path
			return cached("file:" .. tostring(item.commit) .. ":" .. tostring(old_path) .. ":" .. tostring(new_path), function()
				local old_lines, old_ok = view.read_git_blob_lines(item.parent or (item.commit .. "^"), old_path)
				if not old_ok then
					return as_view(old_lines)
				end
				local new_lines, new_ok = view.read_git_blob_lines(item.commit, new_path)
				if not new_ok then
					return as_view(new_lines)
				end
				local lines, highlights, focus_row = diff_ui.from_lines(old_lines, new_lines, { context = 3 })
				local _, filetype = view.file_snippet(new_path, 1)
				return as_view(lines, highlights, focus_row, filetype)
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
		local old_lines, old_ok = read_head_file(path)
		if not old_ok then
			return as_view(old_lines)
		end
		local new_lines, new_ok = view.read_file_lines(path)
		if not new_ok then
			return as_view(new_lines)
		end
		if #old_lines == 0 and #new_lines == 0 then
			return as_view(git_patch_for(path))
		end
		local lines, highlights, focus_row = diff_ui.from_lines(old_lines, new_lines, { context = 3 })
		local _, filetype = view.file_snippet(path, 1)
		return as_view(lines, highlights, focus_row, filetype)
	end)
end

return M
