local M = {}

function M.git_lines(cmd)
	local lines = vim.fn.systemlist(cmd)
	return (vim.v.shell_error == 0) and lines or nil
end

function M.line_count(path)
	local resolved = (path and vim.fn.filereadable(path) == 1) and path or vim.fn.fnamemodify(path or "", ":p")
	if vim.fn.filereadable(resolved) ~= 1 then
		return 0
	end
	return #vim.fn.readfile(resolved)
end

function M.normalize_status_path(path)
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

function M.pretty_date(date)
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

function M.pretty_date_from_ts(ts)
	return M.pretty_date(os.date("%Y-%m-%d", tonumber(ts) or 0))
end

function M.relative_time(ts)
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

function M.file_change_right(added, removed)
	local parts = {}
	if (tonumber(added) or 0) > 0 then
		parts[#parts + 1] = "+" .. tostring(added)
	end
	if (tonumber(removed) or 0) > 0 then
		parts[#parts + 1] = "-" .. tostring(removed)
	end
	return table.concat(parts, " ")
end

function M.history_pathspec(state, panel_name)
	if panel_name == "git_file_history" and state.scope and state.scope.kind == "file" then
		local rel = vim.fn.fnamemodify(state.scope.path, ":.")
		return (rel ~= "" and rel ~= ".") and rel or nil
	end
	if state.scope_prefix then
		return state.scope_prefix:gsub("/$", "")
	end
	return nil
end

return M
