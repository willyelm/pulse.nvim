local pulse = require("pulse")
local util = require("pulse.navigators.git.util")

local M = {}

local function build_numstat_map()
	local map = {}
	local function absorb(lines)
		for _, line in ipairs(lines or {}) do
			local added, removed, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
			if path and path ~= "" then
				local row = map[path] or { added = 0, removed = 0 }
				row.added = row.added + (tonumber(added) or 0)
				row.removed = row.removed + (tonumber(removed) or 0)
				map[util.normalize_status_path(path)] = row
			end
		end
	end
	absorb(util.git_lines({ "git", "diff", "--numstat" }))
	absorb(util.git_lines({ "git", "diff", "--cached", "--numstat" }))
	return map
end

local function load_status_all(state)
	local zero = { added = 0, removed = 0 }
	local stats = build_numstat_map()
	local items = {}
	for _, line in ipairs(util.git_lines({ "git", "status", "--porcelain=v1", "--untracked-files=all" }) or {}) do
		local code = vim.trim(line:sub(1, 2))
		local path = util.normalize_status_path(vim.trim(line:sub(4)))
		if path ~= "" and (not state.scope_prefix or path:sub(1, #state.scope_prefix) == state.scope_prefix) then
			local stat = stats[path] or zero
			local added = stat.added
			if code == "??" and added == 0 then
				added = util.line_count(path)
			end
			local item = {
				kind = "git_status",
				code = code,
				path = path,
				label = path,
				filename = path,
				added = added,
				removed = stat.removed,
			}
			item.display_right = table.concat(vim.tbl_filter(function(v)
				return v ~= nil and v ~= ""
			end, {
				item.added > 0 and ("+" .. item.added) or nil,
				item.removed > 0 and ("-" .. item.removed) or nil,
				item.code,
			}), " ")
			items[#items + 1] = item
		end
	end
	return items
end

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

	local files = {}
	for _, line in ipairs(util.git_lines(cmd) or {}) do
		local added, removed, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
		if path and path ~= "" then
			local parsed = util.parse_numstat_path(path)
			path = parsed and parsed.path or util.normalize_status_path(path)
			local old_path = parsed and parsed.old_path or nil
			files[#files + 1] = {
				kind = "git_commit_file",
				commit = commit,
				parent = commit .. "^",
				path = path,
				old_path = old_path,
				filename = path,
				label = parsed and parsed.label or util.path_name(path),
				added = tonumber(added) or 0,
				removed = tonumber(removed) or 0,
				display_right = old_path and util.rename_right(old_path, path, tonumber(added) or 0, tonumber(removed) or 0)
					or util.file_change_right(tonumber(added) or 0, tonumber(removed) or 0),
				depth = 2,
			}
		end
	end

	table.sort(files, function(a, b)
		if util.path_dir(a.path) == util.path_dir(b.path) then
			return (a.path or "") < (b.path or "")
		end
		return util.path_dir(a.path) < util.path_dir(b.path)
	end)

	local out, current_dir = {}, nil
	for _, file in ipairs(files) do
		local dir = util.path_dir(file.path)
		if dir ~= current_dir then
			current_dir = dir
			if dir ~= "" then
				out[#out + 1] = { kind = "header", label = dir, depth = 1, folder = true, expanded = true }
			end
		end
		if dir == "" then
			file.depth = 1
		end
		out[#out + 1] = file
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

local function history_items(state, query, panel_name)
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

local function status_items(state, query)
	local q = vim.trim(query or "")
	local match = pulse.make_matcher(q, { ignore_case = true, plain = true })
	local status_key = tostring(state.scope_prefix or "")
	if state.status_key ~= status_key then
		state.status_key = status_key
		state.status_all = load_status_all(state)
	end

	state.all_files = state.status_all or {}
	state.files = {}
	for _, item in ipairs(state.all_files) do
		if match(item.path .. " " .. item.code) then
			state.files[#state.files + 1] = item
		end
	end
	return state.files
end

function M.items(state, query, panel_name)
	panel_name = panel_name or "git_status"
	state.active_panel = panel_name
	if panel_name == "git_project_history" or panel_name == "git_file_history" then
		return history_items(state, query, panel_name)
	end
	return status_items(state, query)
end

return M
