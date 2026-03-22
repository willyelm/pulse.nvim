local M = {}
local diff_ui = require("pulse.ui.diff")
local context = require("pulse.context")
local scope = require("pulse.scope")
local CONTEXT_CACHE = {}

M.mode = {
	name = "git",
	icon = "󰊢",
}
M.panels = {
	{ start = "~", name = "git_status", label = "Status", scopes = { "workspace", "folder" } },
	{ start = "~", name = "git_project_history", label = "History", scopes = { "workspace", "folder" } },
	{ start = "~", name = "git_file_history", label = "File History", scopes = { "buffer" } },
}

M.context = function(item)
	return item and (item.kind == "git_commit" or item.code == "??" or item.added + item.removed > 0)
end
M.scope_aware = true

local function git_lines(cmd)
	local lines = vim.fn.systemlist(cmd)
	return (vim.v.shell_error == 0) and lines or nil
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
	return git_lines({ "git", "--no-pager", "show", "HEAD:" .. rel }) or {}
end

local function read_worktree_file(path)
	local r = (path and vim.fn.filereadable(path) == 1) and path or vim.fn.fnamemodify(path or "", ":p")
	return (vim.fn.filereadable(r) == 1) and vim.fn.readfile(r) or {}
end

local function git_patch_for(path)
	local diff = git_lines({ "git", "--no-pager", "diff", "--", path })
	if diff and #diff > 0 then
		return diff
	end
	diff = git_lines({ "git", "--no-pager", "diff", "--cached", "--", path })
	if diff and #diff > 0 then
		return diff
	end
	return { "No git diff for " .. tostring(path) }
end

local function read_commit_file(commit, path)
	if not (commit and path and path ~= "") then
		return {}
	end
	return git_lines({ "git", "--no-pager", "show", commit .. ":" .. path }) or {}
end

local function pretty_date(date)
	if not date or date == "" then
		return ""
	end
	local year, month, day = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not year then
		return date
	end
	local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
	return string.format("%d %s %s", tonumber(day) or 0, months[tonumber(month) or 1] or month, year)
end

local function pretty_date_from_ts(ts)
	return pretty_date(os.date("%Y-%m-%d", tonumber(ts) or 0))
end

local function relative_time(ts)
	local seconds = math.max(os.time() - (tonumber(ts) or 0), 0)
	if seconds < 60 then
		return "just now"
	end
	local minutes = math.floor(seconds / 60)
	if minutes < 60 then
		return string.format("%d min ago", minutes)
	end
	local hours = math.floor(minutes / 60)
	if hours < 24 then
		return string.format("%d hour%s ago", hours, hours == 1 and "" or "s")
	end
	local days = math.floor(hours / 24)
	if days < 7 then
		return string.format("%d day%s ago", days, days == 1 and "" or "s")
	end
	local weeks = math.floor(days / 7)
	if weeks < 5 then
		return string.format("%d week%s ago", weeks, weeks == 1 and "" or "s")
	end
	local months = math.floor(days / 30)
	if months < 12 then
		return string.format("%d month%s ago", months, months == 1 and "" or "s")
	end
	local years = math.floor(days / 365)
	return string.format("%d year%s ago", years, years == 1 and "" or "s")
end

local function diff_summary(added, removed)
	local parts = {}
	if (tonumber(added) or 0) > 0 then
		parts[#parts + 1] = string.format("%d insertions(+)", added)
	end
	if (tonumber(removed) or 0) > 0 then
		parts[#parts + 1] = string.format("%d deletions(-)", removed)
	end
	return #parts > 0 and table.concat(parts, ", ") or "No line changes"
end

local function with_summary(lines, highlights, focus_row, added, removed)
	lines = vim.deepcopy(lines or {})
	highlights = vim.deepcopy(highlights or {})
	table.insert(lines, 1, diff_summary(added, removed))
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

local function cached_context(key, producer)
	local cached = CONTEXT_CACHE[key]
	if cached then
		return unpack(cached)
	end
	local value = { producer() }
	CONTEXT_CACHE[key] = value
	return unpack(value)
end

function M.context_item(item)
	if item.kind == "git_commit" or item.kind == "git_commit_file" then
		if item.kind == "git_commit_file" or (item.history_kind == "file" and item.history_path) then
			local history_path = item.history_path or item.path
			return cached_context("file:" .. tostring(item.commit) .. ":" .. tostring(history_path), function()
				local old_lines = read_commit_file(item.parent or (item.commit .. "^"), history_path)
				local new_lines = read_commit_file(item.commit, history_path)
				local lines, highlights, focus_row = diff_ui.from_lines(old_lines, new_lines, { context = 3 })
				lines, highlights, focus_row = with_summary(lines, highlights, focus_row, item.added, item.removed)
				local _, filetype = context.file_snippet(history_path, 1)
				return lines, filetype, highlights, nil, focus_row
			end)
		end
		return cached_context("commit:" .. tostring(item.commit) .. ":" .. tostring(item.history_path or ""), function()
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
			local lines = git_lines(cmd)
			if not lines or #lines == 0 then
				lines = { "No git history for " .. tostring(item.commit or "") }
			end
			return lines, "git", {}, nil, 1
		end)
	end
	local path = item.path or item.filename
	return cached_context("status:" .. tostring(path) .. ":" .. tostring(item.code or ""), function()
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

M.on_tab = false

local function normalize_status_path(path)
	if not path or path == "" then
		return ""
	end
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
	absorb(git_lines({ "git", "diff", "--numstat" }))
	absorb(git_lines({ "git", "diff", "--cached", "--numstat" }))
	return map
end

local function history_pathspec(state, panel_name)
	if panel_name == "git_file_history" and state.scope and state.scope.kind == "file" then
		local rel = vim.fn.fnamemodify(state.scope.path, ":.")
		return (rel ~= "" and rel ~= ".") and rel or nil
	end
	if state.scope_prefix then
		return state.scope_prefix:gsub("/$", "")
	end
	return nil
end

local function file_change_right(added, removed)
	local parts = {}
	if (tonumber(added) or 0) > 0 then
		parts[#parts + 1] = "+" .. tostring(added)
	end
	if (tonumber(removed) or 0) > 0 then
		parts[#parts + 1] = "-" .. tostring(removed)
	end
	return table.concat(parts, " ")
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
	local out = {}
	for _, line in ipairs(git_lines(cmd) or {}) do
		local added, removed, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
		if path and path ~= "" then
			path = normalize_status_path(path)
			out[#out + 1] = {
				kind = "git_commit_file",
				commit = commit,
				parent = commit .. "^",
				path = path,
				filename = path,
				label = vim.fn.fnamemodify(path, ":t"),
				added = tonumber(added) or 0,
				removed = tonumber(removed) or 0,
				display_right = file_change_right(tonumber(added) or 0, tonumber(removed) or 0),
				depth = 1,
			}
		end
	end
	state.history_files[commit] = out
	return out
end

local function history_items(state, query, panel_name)
	local pulse = require("pulse")
	local q = vim.trim(query or "")
	local match = pulse.make_matcher(q, { ignore_case = true, plain = true })
	local pathspec = history_pathspec(state, panel_name)
	local cache_key = panel_name .. "|" .. tostring(pathspec or "")
	if state.history_key ~= cache_key then
		state.history_key = cache_key
		state.history_all = {}

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

		local current = nil
		for _, line in ipairs(git_lines(cmd) or {}) do
			local commit, ts, author, email, subject = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
			if commit and subject then
				current = {
					kind = "git_commit",
					commit = commit,
					parent = commit .. "^",
					date = pretty_date_from_ts(ts),
					timestamp = tonumber(ts) or 0,
					author = author,
					email = email,
					subject = subject,
					label = subject,
					path = pathspec,
					history_path = pathspec,
					history_kind = panel_name == "git_file_history" and "file" or "project",
					display_right = panel_name == "git_project_history" and relative_time(ts) or pretty_date_from_ts(ts),
					added = 0,
					removed = 0,
				}
				state.history_all[#state.history_all + 1] = current
			elseif current then
				local added, removed = line:match("^(%S+)%s+(%S+)%s+(.+)$")
				if added and removed then
					current.added = current.added + (tonumber(added) or 0)
					current.removed = current.removed + (tonumber(removed) or 0)
				end
			end
		end
	end

	state.all_files = state.history_all or {}
	state.files = {}
	for _, item in ipairs(state.all_files) do
		if match(table.concat({ item.commit, tostring(item.timestamp), item.author, item.email, item.subject, pathspec or "" }, " ")) then
			state.files[#state.files + 1] = item
		end
	end
	if panel_name ~= "git_project_history" then
		return state.files
	end

	local grouped = {}
	local current_day = nil
	for _, item in ipairs(state.files) do
		if item.date ~= current_day then
			current_day = item.date
			grouped[#grouped + 1] = { kind = "header", label = current_day }
		end
		grouped[#grouped + 1] = item
	end
	return grouped
end

function M.init(ctx)
	-- Define highlight groups for git stats
	pcall(vim.api.nvim_set_hl, 0, "PulseAdd", { link = "Added", default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseDelete", { link = "Removed", default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseChange", { link = "Changed", default = true })
	local scoped = ctx and ctx.scope
	return {
		files = {},
		all_files = {},
		history_files = {},
		history_all = {},
		expanded = {},
		history_key = nil,
		status_all = {},
		status_key = nil,
		scope = (scoped and scoped.kind == "folder" and scope.folder(scoped.path)) or nil,
		scope_prefix = (scoped and scoped.kind == "folder" and (vim.fn.fnamemodify(scoped.path, ":.") .. "/")) or nil,
	}
end

function M.input_scope(state)
	return state and state.scope or nil
end

function M.items(state, query, panel_name)
	panel_name = panel_name or "git_status"
	state.active_panel = panel_name
	if panel_name == "git_project_history" or panel_name == "git_file_history" then
		local items = history_items(state, query, panel_name)
		if panel_name ~= "git_project_history" then
			return items
		end
		local out = {}
		for _, item in ipairs(items) do
			out[#out + 1] = item
			if item.kind == "git_commit" and state.expanded[item.commit] then
				for _, child in ipairs(commit_files(state, item.commit, item.history_path)) do
					out[#out + 1] = child
				end
			end
		end
		return out
	end

	local pulse = require("pulse")
	local q = vim.trim(query or "")
	local match = pulse.make_matcher(q, { ignore_case = true, plain = true })
	local status_key = tostring(state.scope_prefix or "")
	if state.status_key ~= status_key then
		state.status_key = status_key
		state.status_all = {}
		local zero = { added = 0, removed = 0 }
		local stats = build_numstat_map()
		for _, line in ipairs(git_lines({ "git", "status", "--porcelain=v1", "--untracked-files=all" }) or {}) do
			local code = line:sub(1, 2)
			local rest = vim.trim(line:sub(4))
			if rest ~= "" then
				local path = normalize_status_path(rest)
				if path ~= "" and (not state.scope_prefix or path:sub(1, #state.scope_prefix) == state.scope_prefix) then
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
					item.display_right = table.concat(vim.tbl_filter(function(v) return v ~= nil and v ~= "" end, {
						item.added > 0 and ("+" .. item.added) or nil,
						item.removed > 0 and ("-" .. item.removed) or nil,
						item.code,
					}), " ")
					state.status_all[#state.status_all + 1] = item
				end
			end
		end
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

function M.on_submit(ctx)
	local item = ctx and ctx.item
	local panel_name = ctx and ctx.state and ctx.state.active_panel
	if panel_name == "git_project_history" and item and item.kind == "git_commit" then
		ctx.state.expanded[item.commit] = not ctx.state.expanded[item.commit]
		ctx.refresh()
		return
	end
	if item and item.kind == "git_commit_file" then
		ctx.jump(item)
		ctx.close()
		return
	end
	if item and item.kind == "git_commit" then
		return
	end
	if item then
		ctx.jump(item)
		ctx.close()
	end
end

function M.total_count(state)
	return #(state.all_files or {})
end

return M
