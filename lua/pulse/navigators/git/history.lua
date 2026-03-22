local pulse = require("pulse")
local util = require("pulse.navigators.git.util")

local M = {}

local function commit_files(state, commit, pathspec)
	local cached = state.history_files[commit]
	if cached then
		return cached
	end

	local cmd = { "git", "--no-pager", "show", "--numstat", "--format=", commit }
	if pathspec then
		cmd[#cmd + 1] = "--"
		cmd[#cmd + 1] = pathspec
	end

	local out = {}
	for _, line in ipairs(util.git_lines(cmd) or {}) do
		local added, removed, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
		if path and path ~= "" then
			path = util.normalize_status_path(path)
			out[#out + 1] = {
				kind = "git_commit_file",
				commit = commit,
				parent = commit .. "^",
				path = path,
				filename = path,
				label = vim.fn.fnamemodify(path, ":t"),
				added = tonumber(added) or 0,
				removed = tonumber(removed) or 0,
				display_right = util.file_change_right(tonumber(added) or 0, tonumber(removed) or 0),
				depth = 1,
			}
		end
	end

	state.history_files[commit] = out
	return out
end

local function load_history_all(state, panel_name)
	local pathspec = util.history_pathspec(state, panel_name)
	local cmd = {
		"git",
		"--no-pager",
		"log",
		"--pretty=format:%h%x09%at%x09%an%x09%ae%x09%s",
		"--numstat",
		"-n",
		"200",
	}
	if pathspec then
		cmd[#cmd + 1] = "--"
		cmd[#cmd + 1] = pathspec
	end

	local out, current = {}, nil
	for _, line in ipairs(util.git_lines(cmd) or {}) do
		local commit, ts, author, email, subject = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
		if commit and subject then
			current = {
				kind = "git_commit",
				commit = commit,
				parent = commit .. "^",
				date = util.pretty_date_from_ts(ts),
				timestamp = tonumber(ts) or 0,
				author = author,
				email = email,
				subject = subject,
				label = subject,
				path = pathspec,
				history_path = pathspec,
				history_kind = panel_name == "git_file_history" and "file" or "project",
				display_right = panel_name == "git_project_history" and util.relative_time(ts) or util.pretty_date_from_ts(ts),
				added = 0,
				removed = 0,
			}
			out[#out + 1] = current
		elseif current then
			local added, removed = line:match("^(%S+)%s+(%S+)%s+(.+)$")
			if added and removed then
				current.added = current.added + (tonumber(added) or 0)
				current.removed = current.removed + (tonumber(removed) or 0)
			end
		end
	end
	return out
end

local function grouped_commits(items)
	local grouped = {}
	local current_day = nil
	for _, item in ipairs(items) do
		if item.date ~= current_day then
			current_day = item.date
			grouped[#grouped + 1] = { kind = "header", label = current_day }
		end
		grouped[#grouped + 1] = item
	end
	return grouped
end

function M.items(state, query, panel_name)
	local q = vim.trim(query or "")
	local match = pulse.make_matcher(q, { ignore_case = true, plain = true })
	local pathspec = util.history_pathspec(state, panel_name)
	local cache_key = panel_name .. "|" .. tostring(pathspec or "")
	if state.history_key ~= cache_key then
		state.history_key = cache_key
		state.history_all = load_history_all(state, panel_name)
	end

	state.all_files = state.history_all or {}
	state.files = {}
	for _, item in ipairs(state.all_files) do
		if match(table.concat({ item.commit, tostring(item.timestamp), item.author, item.email, item.subject, pathspec or "" }, " ")) then
			state.files[#state.files + 1] = item
		end
	end

	if panel_name == "git_file_history" then
		return state.files
	end
	if panel_name ~= "git_project_history" then
		return state.files
	end

	local out = {}
	for _, item in ipairs(grouped_commits(state.files)) do
		out[#out + 1] = item
		if item.kind == "git_commit" and state.expanded[item.commit] then
			for _, child in ipairs(commit_files(state, item.commit, item.history_path)) do
				out[#out + 1] = child
			end
		end
	end
	return out
end

return M
