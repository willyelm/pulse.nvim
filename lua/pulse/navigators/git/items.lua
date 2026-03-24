local pulse = require("pulse")
local file_items = require("pulse.navigators.files.items")
local util = require("pulse.navigators.git.util")

local M = {}
local HISTORY_PAGE_SIZE = 100
local HISTORY_PREFETCH = 30
local HISTORY_LIMIT = 5000

local function history_cache_key(state, panel_name)
	local pathspec = util.history_pathspec(state, panel_name)
	return panel_name .. "|" .. tostring(pathspec or ""), pathspec
end

local function parse_history_output(text, panel_name, pathspec)
	local out = {}
	for _, line in ipairs(vim.split(text or "", "\n", { plain = true, trimempty = true })) do
		local commit, ts, author, email, subject = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
		if commit and subject then
			out[#out + 1] = {
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
			}
		end
	end
	return out
end

local function parse_status_lines(lines, scope_prefix)
	local items = {}
	for _, line in ipairs(lines or {}) do
		local code = vim.trim(line:sub(1, 2))
		local path = util.normalize_status_path(vim.trim(line:sub(4)))
		if path ~= "" and (not scope_prefix or path:sub(1, #scope_prefix) == scope_prefix) then
			items[#items + 1] = {
				kind = "git_status",
				code = code,
				path = path,
				label = path,
				filename = path,
				added = 0,
				removed = 0,
			}
		end
	end
	return items
end

local function decorate_status_items(items, stats)
	local zero = { added = 0, removed = 0 }
	for _, item in ipairs(items or {}) do
		local stat = (stats or {})[item.path] or zero
		local added = stat.added
		if item.code == "??" and added == 0 then
			added = util.line_count(item.path)
		end
		item.added = added
		item.removed = stat.removed
		item.display_right = table.concat(vim.tbl_filter(function(v)
			return v ~= nil and v ~= ""
		end, {
			item.added > 0 and ("+" .. item.added) or nil,
			item.removed > 0 and ("-" .. item.removed) or nil,
			item.code,
		}), " ")
	end
end

local function warm_status_all(state)
	if state._status_loading or state.status_all ~= nil then
		return
	end
	state._status_loading = true
	vim.system({ "git", "-c", "core.fsmonitor=false", "status", "--porcelain=v1", "--untracked-files=all" }, { text = true }, function(result)
		local items = {}
		if result.code == 0 then
			items = parse_status_lines(vim.split(result.stdout or "", "\n", { plain = true, trimempty = true }), state.scope_prefix)
		end
		state.status_all = items
			state._status_loading = false
		if #items > 0 then
			vim.system({ "git", "-c", "core.fsmonitor=false", "diff", "--numstat" }, { text = true }, function(diff_result)
				local stats = {}
				if diff_result.code == 0 then
					for _, line in ipairs(vim.split(diff_result.stdout or "", "\n", { plain = true, trimempty = true })) do
						local added, removed, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
						if path and path ~= "" then
							stats[util.normalize_status_path(path)] = {
								added = tonumber(added) or 0,
								removed = tonumber(removed) or 0,
							}
						end
					end
				end
				vim.system({ "git", "-c", "core.fsmonitor=false", "diff", "--cached", "--numstat" }, { text = true }, function(cached_result)
					if cached_result.code == 0 then
						for _, line in ipairs(vim.split(cached_result.stdout or "", "\n", { plain = true, trimempty = true })) do
							local added, removed, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
							if path and path ~= "" then
								local key = util.normalize_status_path(path)
								local row = stats[key] or { added = 0, removed = 0 }
								row.added = row.added + (tonumber(added) or 0)
								row.removed = row.removed + (tonumber(removed) or 0)
								stats[key] = row
							end
						end
					end
					decorate_status_items(items, stats)
					if state._on_update then
						vim.schedule(state._on_update)
					end
				end)
			end)
		end
		if state._on_update then
			vim.schedule(state._on_update)
		end
	end)
end

local function commit_files(state, commit, pathspec)
	local entries = state.history_files[commit]
	if not entries then
		local cmd = { "git", "--no-pager", "show", "--numstat", "--format=", commit }
		if pathspec then
			cmd[#cmd + 1] = "--"
			cmd[#cmd + 1] = pathspec
		end

		entries = {}
		for _, line in ipairs(util.git_lines(cmd) or {}) do
			local added, removed, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
			if path and path ~= "" then
				local parsed = util.parse_numstat_path(path)
				path = parsed and parsed.path or util.normalize_status_path(path)
				local old_path = parsed and parsed.old_path or nil
				entries[#entries + 1] = {
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
				}
			end
		end
		state.history_files[commit] = entries
	end
	return file_items.build_tree(entries, state.expanded, {
		icons = true,
		icon_color = false,
		compact_dirs = true,
		base_depth = 1,
		folder_key = function(path)
			return commit .. ":" .. path
		end,
		folder_expanded = function()
			return true
		end,
	})
end

local function ensure_history_loaded(state, panel_name)
	local cache_key, pathspec = history_cache_key(state, panel_name)
	if state.history_key ~= cache_key then
		state.history_key = cache_key
		state.history_all = {}
		state.history_has_more = true
		state._history_loading = false
	end
	if state._history_loading or state.history_has_more == false then
		return
	end
	if #(state.history_all or {}) >= HISTORY_LIMIT then
		state.history_has_more = false
		return
	end
	state._history_loading = true
	local skip = #(state.history_all or {})
	local cmd = {
		"git",
		"-c",
		"core.fsmonitor=false",
		"--no-pager",
		"log",
		"--pretty=format:%h%x09%at%x09%an%x09%ae%x09%s",
		"-n",
		tostring(HISTORY_PAGE_SIZE),
		"--skip",
		tostring(skip),
	}
	if pathspec then
		cmd[#cmd + 1] = "--"
		cmd[#cmd + 1] = pathspec
	end
	vim.system(cmd, { text = true }, function(result)
		local out = {}
		if result.code == 0 then
			out = parse_history_output(result.stdout, panel_name, pathspec)
		end
		if state.history_key ~= cache_key then
			return
		end
		if #out > 0 then
			local remaining = HISTORY_LIMIT - #(state.history_all or {})
			if remaining > 0 and #out > remaining then
				out = vim.list_slice(out, 1, remaining)
			end
		end
		state.history_all = vim.list_extend(state.history_all or {}, out)
		state.history_has_more = #out >= HISTORY_PAGE_SIZE and #(state.history_all or {}) < HISTORY_LIMIT
		state._history_loading = false
		if state._on_update then
			vim.schedule(state._on_update)
		end
	end)
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

local function expanded_signature(expanded)
	local keys = {}
	for key, value in pairs(expanded or {}) do
		if value then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys)
	return table.concat(keys, "\0")
end

local function history_rows(state, query, panel_name)
	local cache_key = table.concat({
		tostring(panel_name or ""),
		vim.trim(query or ""),
		tostring(#(state.history_all or {})),
		expanded_signature(state.expanded),
	}, "|")
	if state.history_rows_key == cache_key and state.history_rows_cache then
		return state.history_rows_cache
	end
	local q = vim.trim(query or "")
	local match = pulse.make_matcher(q, { ignore_case = true, plain = true })
	local _, pathspec = history_cache_key(state, panel_name)
	local filtered = {}
	for _, item in ipairs(state.history_all or {}) do
		if match(table.concat({ item.commit, tostring(item.timestamp), item.author, item.email, item.subject, pathspec or "" }, " ")) then
			filtered[#filtered + 1] = item
		end
	end
	if panel_name == "git_file_history" then
		state.history_rows_key = cache_key
		state.history_rows_cache = filtered
		return filtered
	end
	if panel_name == "git_project_history" then
		local out = {}
		for _, item in ipairs(grouped_commits(filtered)) do
			out[#out + 1] = item
			if item.kind == "git_commit" and state.expanded[item.commit] then
				for _, child in ipairs(commit_files(state, item.commit, item.history_path)) do
					out[#out + 1] = child
				end
			end
		end
		filtered = out
	end
	state.history_rows_key = cache_key
	state.history_rows_cache = filtered
	return filtered
end

local function history_items(state, query, panel_name)
	ensure_history_loaded(state, panel_name)
	local provider = {}

	local function rows()
		return history_rows(state, query, panel_name)
	end

	local function maybe_prefetch(index, row_count)
		if state.history_has_more ~= true then
			return
		end
		if index >= math.max(row_count - HISTORY_PREFETCH, 1) then
			ensure_history_loaded(state, panel_name)
		end
	end

	function provider:count()
		local row_count = #rows()
		if state.history_has_more or state._history_loading then
			return row_count + 1
		end
		return row_count
	end

	function provider:get(index)
		index = tonumber(index) or 0
		if index < 1 then
			return nil
		end
		local current = rows()
		maybe_prefetch(index, #current)
		local item = current[index]
		if item ~= nil then
			return item
		end
		if state.history_has_more or state._history_loading then
			return { kind = "loading", label = "Loading..." }
		end
		return nil
	end

	return provider
end

local function status_items(state, query)
	local q = vim.trim(query or "")
	local match = pulse.make_matcher(q, { ignore_case = true, plain = true })
	local status_key = tostring(state.scope_prefix or "")
	if state.status_key ~= status_key then
		state.status_key = status_key
		state.status_all = nil
	end
	warm_status_all(state)

	local filtered = {}
	for _, item in ipairs(state.status_all or {}) do
		if match(item.path .. " " .. item.code) then
			filtered[#filtered + 1] = item
		end
	end
	local provider = {}

	function provider:count()
		return #filtered
	end

	function provider:get(index)
		return filtered[index]
	end

	return provider
end

function M.items(state, query, panel_name)
	panel_name = panel_name or "git_status"
	state.current_panel = panel_name
	if panel_name == "git_project_history" or panel_name == "git_file_history" then
		return history_items(state, query, panel_name)
	end
	return status_items(state, query)
end

function M.invalidate(state)
	if not state then
		return
	end
	state.history_files = {}
	state.history_all = {}
	state.history_key = nil
	state.history_has_more = true
	state.history_rows_key = nil
	state.history_rows_cache = nil
	state.status_all = nil
	state.status_key = nil
	state._status_loading = false
end

function M.invalidate_status(state)
	if not state then
		return
	end
	state.status_all = nil
	state.status_key = nil
	state._status_loading = false
end

return M
