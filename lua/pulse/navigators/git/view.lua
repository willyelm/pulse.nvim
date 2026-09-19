local diff_ui = require("pulse.ui.diff")
local view = require("pulse.panel_view")
local git = require("pulse.navigators.git.cmd")
local util = require("pulse.navigators.git.util")

local M = {}
local CACHE = {}
-- Status diffs depend on the worktree, so they live apart from the immutable commit-keyed entries.
local STATUS_CACHE = {}
local STATUS_CACHE_MAX = 200

-- Lines of `<rev>:<path>` (path relative to the repo root) under the same too-large/binary policy as
-- worktree files. Returns lines, ok; when ok is false, lines is a placeholder to display.
local function read_blob_lines(rev, path)
	if not (rev and path and path ~= "") then
		return {}, true
	end
	local target = rev .. ":" .. path
	local size_out, found = git.system({ "git", "cat-file", "-s", target })
	local size = found and tonumber(vim.trim(size_out)) or nil
	if not size then
		-- No such blob at that rev (new/untracked file); skip the `git show` that would only fail too.
		return {}, true
	end
	local placeholder = view.classify(size)
	if placeholder then
		return placeholder, false
	end
	local raw, ok = git.system({ "git", "--no-pager", "show", target })
	if not ok then
		return {}, true
	end
	placeholder = view.classify(size, raw)
	if placeholder then
		return placeholder, false
	end
	local lines = vim.split(raw, "\n", { plain = true, trimempty = false })
	-- readfile() has no phantom line after the final newline; match it so HEAD-vs-worktree diffs don't flag the last line.
	if lines[#lines] == "" then
		lines[#lines] = nil
	end
	return lines, true
end

-- From the name alone; no need to read the file (which may not even exist in this revision).
local function filetype_for(path)
	local ft = vim.filetype.match({ filename = path or "" })
	return (ft and ft ~= "") and ft or "text"
end

local function git_patch_for(path)
	local diff = git.lines({ "git", "--no-pager", "diff", "--", path })
	if diff and #diff > 0 then
		return diff
	end
	diff = git.lines({ "git", "--no-pager", "diff", "--cached", "--", path })
	if diff and #diff > 0 then
		return diff
	end
	return { "No git diff for " .. tostring(path) }
end

-- Shapes preview lines into the 5-tuple view_item's callers expect.
local function as_view(lines, highlights, focus_row, filetype)
	return lines, filetype or "text", highlights or {}, nil, focus_row or 1
end

-- 12-hour local time to the second, e.g. "2026-09-18 12:00:00 PM".
local COMMIT_DATE_FORMAT = "%Y-%m-%d %I:%M:%S %p"
local COMMIT_FORMAT = table.concat({ "Commit: %h", "Date:   %ad", "Author: %an <%ae>", "", "%B" }, "%n")

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
				local old_lines, old_ok = read_blob_lines(item.parent or (item.commit .. "^"), old_path)
				if not old_ok then
					return as_view(old_lines)
				end
				local new_lines, new_ok = read_blob_lines(item.commit, new_path)
				if not new_ok then
					return as_view(new_lines)
				end
				local lines, highlights, focus_row = diff_ui.from_lines(old_lines, new_lines, { context = 3 })
				local _, filetype = view.file_snippet(new_path, 1)
				return as_view(lines, highlights, focus_row, filetype)
			end)
		end
		return cached("commit:" .. tostring(item.commit) .. ":" .. tostring(item.history_path or ""), function()
			-- The record separator ends the header/message so the stat output that follows can't be confused with it.
			local args = {
				"git",
				"--no-pager",
				"show",
				"--stat",
				"--date=format-local:" .. COMMIT_DATE_FORMAT,
				"--format=format:" .. COMMIT_FORMAT .. "%x1e",
				item.commit,
			}
			-- A pathspec makes git skip commits that don't touch it (e.g. empty ones), so only add one to limit by.
			if item.history_path then
				vim.list_extend(args, { "--", item.history_path })
			end
			local out, ok = git.system(args)
			local head, stat = out:match("^(.-)\30(.*)$")
			if not (ok and head) then
				return { "No git history for " .. tostring(item.commit or "") .. (ok and "" or (": " .. out)) }, "git", {}, nil, 1
			end
			-- Header (3 lines) and a blank, then the full message indented like `git log`, trailers included.
			local lines = vim.split(head, "\n", { plain = true })
			for i = 5, #lines do
				if lines[i] ~= "" then
					lines[i] = "    " .. lines[i]
				end
			end
			while lines[#lines] == "" do
				lines[#lines] = nil
			end
			local summary = stat:match("[^\n]*files? changed[^\n]*")
			if summary then
				lines[#lines + 1] = ""
				lines[#lines + 1] = summary
			end
			return lines, "git", {}, nil, 1
		end)
	end

	local path = item.path -- root-relative, for git
	local file = item.filename or path -- absolute, for the filesystem
	-- Every input of the HEAD-vs-worktree diff: status, HEAD-relative counts, and the file's own content stamp.
	local key = table.concat({
		tostring(path),
		tostring(item.raw_code or item.code or ""),
		tostring(item.added or 0),
		tostring(item.removed or 0),
		util.file_stamp(file),
	}, "\0")
	local hit = STATUS_CACHE[key]
	if hit then
		return unpack(hit)
	end
	-- Untracked files have no HEAD blob; skip the two git calls that would only confirm that.
	local old_lines, old_ok = {}, true
	if item.raw_code ~= "??" then
		old_lines, old_ok = read_blob_lines("HEAD", path)
	end
	local result
	if not old_ok then
		result = { as_view(old_lines) }
	else
		local new_lines, new_ok = view.read_file_lines(file)
		if not new_ok then
			result = { as_view(new_lines) }
		elseif #old_lines == 0 and #new_lines == 0 then
			result = { as_view(git_patch_for(path)) }
		else
			local lines, highlights, focus_row = diff_ui.from_lines(old_lines, new_lines, { context = 3 })
			result = { as_view(lines, highlights, focus_row, filetype_for(path)) }
		end
	end
	if vim.tbl_count(STATUS_CACHE) >= STATUS_CACHE_MAX then
		STATUS_CACHE = {}
	end
	STATUS_CACHE[key] = result
	return unpack(result)
end

return M
