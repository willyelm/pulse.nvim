local M = {}
local diff_ui = require("pulse.ui.diff")
local context = require("pulse.context")
local scope = require("pulse.scope")

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

local function read_commit_file(commit, path)
	if not (commit and path and path ~= "") then
		return {}
	end
	local lines = vim.fn.systemlist({ "git", "--no-pager", "show", commit .. ":" .. path })
	return (vim.v.shell_error == 0) and lines or {}
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

function M.context_item(item)
	if item.kind == "git_commit" then
		if item.history_kind == "file" and item.history_path then
			local old_lines = read_commit_file(item.parent or (item.commit .. "^"), item.history_path)
			local new_lines = read_commit_file(item.commit, item.history_path)
			local lines, highlights, focus_row = diff_ui.from_lines(old_lines, new_lines, { context = 3 })
			lines, highlights, focus_row = with_summary(lines, highlights, focus_row, item.added, item.removed)
			local _, filetype = context.file_snippet(item.history_path, 1)
			return lines, filetype, highlights, nil, focus_row
		end
			local cmd = {
				"git",
				"--no-pager",
				"show",
				"--stat",
				"--date=short",
				"--format=format:%h  %as  %an <%ae>%n%n%s%n%b",
				item.commit,
			}
		if item.history_path then
			cmd[#cmd + 1] = "--"
			cmd[#cmd + 1] = item.history_path
		end
		local lines = vim.fn.systemlist(cmd)
		if vim.v.shell_error ~= 0 or #lines == 0 then
			lines = { "No git history for " .. tostring(item.commit or "") }
		end
		return lines, "git", {}, nil, 1
	end
	local path = item.path or item.filename
	local old_lines, new_lines = read_head_file(path), read_worktree_file(path)
	if #old_lines == 0 and #new_lines == 0 then
		return git_patch_for(path), "text", {}, nil, 1
	end
	local lines, highlights, focus_row = diff_ui.from_lines(old_lines, new_lines, { context = 3 })
	lines, highlights, focus_row = with_summary(lines, highlights, focus_row, item.added, item.removed)
	local _, filetype = context.file_snippet(path, 1)
	return lines, filetype, highlights, nil, focus_row
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
	absorb(vim.fn.systemlist({ "git", "diff", "--numstat" }))
	absorb(vim.fn.systemlist({ "git", "diff", "--cached", "--numstat" }))
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

local function history_items(state, query, panel_name)
	local pulse = require("pulse")
	local q = vim.trim(query or "")
	local match = pulse.make_matcher(q, { ignore_case = true, plain = true })
	state.files = {}
	state.all_files = {}

	local cmd = {
		"git",
		"--no-pager",
		"log",
		"--pretty=format:%h%x09%at%x09%an%x09%ae%x09%s",
		"--numstat",
		"-n",
		"200",
	}
	local pathspec = history_pathspec(state, panel_name)
	if pathspec then
		cmd[#cmd + 1] = "--"
		cmd[#cmd + 1] = pathspec
	end

	local lines = vim.fn.systemlist(cmd)
	if vim.v.shell_error ~= 0 then
		return {}
	end

	local current = nil
	for _, line in ipairs(lines) do
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
			state.all_files[#state.all_files + 1] = current
			if match(table.concat({ commit, tostring(ts), author, email, subject, pathspec or "" }, " ")) then
				state.files[#state.files + 1] = current
			else
				current = nil
			end
		elseif current then
			local added, removed = line:match("^(%S+)%s+(%S+)%s+(.+)$")
			if added and removed then
				current.added = current.added + (tonumber(added) or 0)
				current.removed = current.removed + (tonumber(removed) or 0)
			end
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
		return history_items(state, query, panel_name)
	end

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
			if state.scope_prefix and path:sub(1, #state.scope_prefix) ~= state.scope_prefix then
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
			if item.added > 0 then
				display[#display + 1] = "+" .. item.added
			end
			if item.removed > 0 then
				display[#display + 1] = "-" .. item.removed
			end
			local label = item.code
			if label then
				display[#display + 1] = label
			end
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
