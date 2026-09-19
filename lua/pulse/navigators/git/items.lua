local pulse = require("pulse")
local file_items = require("pulse.navigators.files.items")
local git = require("pulse.navigators.git.cmd")
local util = require("pulse.navigators.git.util")

local M = {}
local uv = vim.uv or vim.loop
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

-- raw_code is always the trailing token of display_right; precomputes its absolute highlight spans.
local function set_status_display(item)
	local raw_start = #item.display_right - #item.raw_code
	item.status_matches = {}
	for _, span in ipairs(util.status_spans(item.raw_code)) do
		item.status_matches[#item.status_matches + 1] = { raw_start + span[1], raw_start + span[2], span[3] }
	end
end

local function now_ms()
	return uv.hrtime() / 1e6
end

-- Parses `git status --porcelain=v1 -z`: "XY path\0" entries (unquoted, unlike the line format), where
-- renames/copies carry an extra "orig\0" field that is skipped.
local function parse_status_z(text, scope_prefix)
	local items = {}
	local root = git.root()
	local fields = vim.split(text or "", "\0", { plain = true, trimempty = true })
	local i = 1
	while i <= #fields do
		-- raw_code keeps the index/worktree columns positional; code (trimmed) can't.
		local raw_code = fields[i]:sub(1, 2)
		local path = util.normalize_status_path(fields[i]:sub(4))
		i = i + (raw_code:find("[RC]") and 2 or 1)
		if path ~= "" and (not scope_prefix or path:sub(1, #scope_prefix) == scope_prefix) then
			items[#items + 1] = {
				kind = "git_status",
				code = vim.trim(raw_code),
				raw_code = raw_code,
				path = path,
				label = path,
				-- path is root-relative (git's identity for it); filename is what the filesystem and jump need.
				filename = root and (root .. "/" .. path) or path,
			}
		end
	end
	return items
end

-- Line-counting untracked files reads them synchronously, so bound how many get counted per refresh.
local UNTRACKED_COUNT_LIMIT = 200

local function decorate_status_items(items, stats)
	local budget = UNTRACKED_COUNT_LIMIT
	for _, item in ipairs(items) do
		local stat = stats[item.path]
		local added, removed = stat and stat.added or 0, stat and stat.removed or 0
		if item.code == "??" and added == 0 and budget > 0 then
			budget = budget - 1
			added = util.line_count(item.filename)
		end
		item.added, item.removed = added, removed
		item.display_right = table.concat(vim.tbl_filter(function(v)
			return v ~= nil and v ~= ""
		end, {
			added > 0 and ("+" .. added) or nil,
			removed > 0 and ("-" .. removed) or nil,
			item.raw_code,
		}), " ")
		set_status_display(item)
	end
end

-- Parses `git diff --numstat -z` output into { [path] = { added, removed } }.
local function parse_numstat_z(text)
	local stats = {}
	for _, record in ipairs(vim.split(text or "", "\0", { plain = true, trimempty = true })) do
		local added, removed, path = util.parse_numstat_line(record)
		if path and path ~= "" then
			stats[util.normalize_status_path(path)] = { added = tonumber(added) or 0, removed = tonumber(removed) or 0 }
		end
	end
	return stats
end

-- HEAD-vs-worktree counts: the same comparison the preview shows, in one process (--no-renames keeps
-- every record a plain "added removed path").
local function fetch_numstat(on_done)
	git.spawn({ "git", "diff", "HEAD", "--numstat", "--no-renames", "-z" }, function(result)
		if result.code == 0 then
			return on_done(result.stdout)
		end
		-- No HEAD yet (fresh repo): the index is the only side with content.
		git.spawn({ "git", "diff", "--cached", "--numstat", "--no-renames", "-z" }, function(fallback)
			on_done(fallback.code == 0 and fallback.stdout or "")
		end)
	end)
end

-- Everything a row displays or previews from; equal signatures mean nothing needs re-rendering.
local function status_signature(items)
	local parts = {}
	for i, item in ipairs(items) do
		parts[i] = table.concat({ item.raw_code, item.path, item.added, item.removed, util.file_stamp(item.filename) }, "\t")
	end
	return table.concat(parts, "\n")
end

-- Cheap fingerprint of what the counts derive from besides status text: the index (staging, commits) and
-- every listed file's size/mtime.
local function worktree_stamps(items)
	local git_dir = git.git_dir()
	local parts = { util.file_stamp(git_dir and (git_dir .. "/index") or nil) }
	for i, item in ipairs(items) do
		parts[i + 1] = util.file_stamp(item.filename)
	end
	return table.concat(parts, "\n")
end

local STATUS_ARGS = { "git", "status", "--porcelain=v1", "-z", "--untracked-files=all" }

-- Refetches status and per-file counts. Normally both git calls run concurrently (fastest refresh). With
-- `quiet` (background polling) status runs alone first, and the numstat is skipped when neither the status
-- nor the fingerprint above changed, so an idle poll costs one process instead of two.
local function warm_status_all(state, quiet)
	if state._status_loading then
		return
	end
	-- status_dirty (not status_all == nil) triggers a refetch, so selection survives it.
	if state.status_all ~= nil and not state.status_dirty and not quiet then
		return
	end
	quiet = quiet and state.status_all ~= nil and not state.status_dirty
	state._status_loading = true
	state.status_dirty = false
	-- invalidate_status bumps the generation, so a fetch overtaken by newer state never publishes.
	local gen = (state._status_gen or 0) + 1
	state._status_gen = gen
	local started = now_ms()

	local function finish()
		state._status_loading = false
		state._status_ms = now_ms() - started
	end

	-- `stamps` is only recorded when taken before the numstat ran, so an edit during it forces a refetch.
	local function publish(status_text, numstat_text, stamps)
		if state._status_gen ~= gen then
			return
		end
		finish()
		state.status_text, state.status_stamps = status_text, stamps
		local changed = false
		if status_text then
			local items = parse_status_z(status_text, state.scope_prefix)
			decorate_status_items(items, parse_numstat_z(numstat_text))
			local signature = status_signature(items)
			if state.status_all == nil or signature ~= state.status_signature then
				state.status_all, state.status_signature, changed = items, signature, true
			end
		elseif state.status_all == nil then
			-- Not a repo / git failed with nothing to show yet; a failure later keeps the last good list.
			state.status_all, changed = {}, true
		end
		if changed and state._on_update then
			state._on_update()
		end
	end

	if quiet then
		git.spawn(STATUS_ARGS, function(result)
			local text = result.code == 0 and (result.stdout or "") or nil
			vim.schedule(function()
				if state._status_gen ~= gen then
					return
				end
				if text and text == state.status_text and state.status_stamps == worktree_stamps(state.status_all) then
					return finish()
				end
				if not text then
					return publish(nil, "", nil)
				end
				local stamps = worktree_stamps(parse_status_z(text, state.scope_prefix))
				fetch_numstat(function(numstat_text)
					vim.schedule(function()
						publish(text, numstat_text, stamps)
					end)
				end)
			end)
		end)
		return
	end

	-- Independent, so run concurrently: latency is the slower one, not the sum.
	local pending, status_text, numstat_text = 2, nil, ""
	local function part_done()
		pending = pending - 1
		if pending == 0 then
			vim.schedule(function()
				publish(status_text, numstat_text, nil)
			end)
		end
	end
	git.spawn(STATUS_ARGS, function(result)
		status_text = result.code == 0 and (result.stdout or "") or nil
		part_done()
	end)
	fetch_numstat(function(text)
		numstat_text = text
		part_done()
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
		for _, line in ipairs(git.lines(cmd) or {}) do
			local added, removed, path = util.parse_numstat_line(line)
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
		state._history_gen = (state._history_gen or 0) + 1
	end
	if state._history_loading or state.history_has_more == false then
		return
	end
	if #(state.history_all or {}) >= HISTORY_LIMIT then
		state.history_has_more = false
		return
	end
	state._history_loading = true
	-- Bumped by every invalidation/re-key, so a page requested before one can't be appended after it.
	local gen = state._history_gen or 0
	local cmd = {
		"git",
		"--no-pager",
		"log",
		"--pretty=format:%h%x09%at%x09%an%x09%ae%x09%s",
		"-n",
		tostring(HISTORY_PAGE_SIZE),
		"--skip",
		tostring(#(state.history_all or {})),
	}
	if pathspec then
		cmd[#cmd + 1] = "--"
		cmd[#cmd + 1] = pathspec
	end
	git.spawn(cmd, function(result)
		if state._history_gen ~= gen then
			return
		end
		local out = {}
		if result.code == 0 then
			out = parse_history_output(result.stdout, panel_name, pathspec)
		end
		local remaining = HISTORY_LIMIT - #(state.history_all or {})
		if #out > remaining then
			out = vim.list_slice(out, 1, math.max(remaining, 0))
		end
		state.history_all = vim.list_extend(state.history_all or {}, out)
		state.history_has_more = #out >= HISTORY_PAGE_SIZE and #state.history_all < HISTORY_LIMIT
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
		if value ~= nil then
			keys[#keys + 1] = key .. "=" .. tostring(value)
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

	function provider:count()
		local row_count = #history_rows(state, query, panel_name)
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
		local current = history_rows(state, query, panel_name)
		if state.history_has_more == true and index >= math.max(#current - HISTORY_PREFETCH, 1) then
			ensure_history_loaded(state, panel_name)
		end
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

-- Groups into "staged"/"unstaged" gray, non-selectable header rows.
local function grouped_status(items)
	local staged, unstaged = {}, {}
	for _, item in ipairs(items) do
		local bucket = util.is_staged(item) and staged or unstaged
		bucket[#bucket + 1] = item
	end
	if #staged == 0 or #unstaged == 0 then
		return items
	end
	local grouped = {}
	grouped[#grouped + 1] = { kind = "header", label = "staged" }
	vim.list_extend(grouped, staged)
	grouped[#grouped + 1] = { kind = "header", label = "unstaged" }
	vim.list_extend(grouped, unstaged)
	return grouped
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

	local matched = {}
	for _, item in ipairs(state.status_all or {}) do
		if match(item.path .. " " .. item.code) then
			matched[#matched + 1] = item
		end
	end
	local filtered = grouped_status(matched)
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
	M.invalidate_history(state)
	M.invalidate_status(state)
end

function M.invalidate_history(state)
	if not state then
		return
	end
	state._history_gen = (state._history_gen or 0) + 1
	state._history_loading = false
	state.history_head = nil
	state.history_files = {}
	state.history_all = {}
	state.history_key = nil
	state.history_has_more = true
	state.history_rows_key = nil
	state.history_rows_cache = nil
end

function M.invalidate_status(state)
	if not state then
		return
	end
	-- Leaves status_all in place (see warm_status_all) so selection survives the refetch.
	state.status_dirty = true
	state._status_loading = false
	state._status_gen = (state._status_gen or 0) + 1
end

-- Notices commits/checkouts/amends made elsewhere: history only changes when HEAD does.
local function check_head(state)
	if state._head_checking then
		return
	end
	state._head_checking = true
	git.spawn({ "git", "rev-parse", "HEAD" }, function(result)
		vim.schedule(function()
			state._head_checking = false
			local head = result.code == 0 and vim.trim(result.stdout or "") or ""
			local previous = state.history_head
			if previous ~= nil and previous ~= head then
				M.invalidate_history(state)
				if state._on_update then
					state._on_update()
				end
			end
			state.history_head = head
		end)
	end)
end

local POLL_MIN_MS, POLL_MAX_MS = 1500, 15000

-- Keeps the visible git panel current with changes made outside nvim (a terminal split, another tool).
-- Costs one one-shot timer; a tick re-renders only when the fetched state actually differs, and the
-- interval stretches to 10x the last fetch time so a slow repo is never hammered.
function M.watch(state, alive, active)
	local timer = uv.new_timer()
	local tick
	local function stop()
		if timer then
			timer:stop()
			timer:close()
			timer = nil
		end
	end
	tick = function()
		if not timer then
			return
		end
		if not alive() then
			return stop()
		end
		timer:start(math.min(math.max((state._status_ms or 0) * 10, POLL_MIN_MS), POLL_MAX_MS), 0, vim.schedule_wrap(tick))
		if not active() then
			return
		end
		if state.current_panel == "git_status" then
			warm_status_all(state, true)
		else
			check_head(state)
		end
	end
	timer:start(POLL_MIN_MS, 0, vim.schedule_wrap(tick))
end

return M
