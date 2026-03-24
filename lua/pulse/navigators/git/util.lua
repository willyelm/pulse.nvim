local M = {}
local uv = vim.uv or vim.loop

function M.git_lines(cmd)
	if cmd and cmd[1] == "git" then
		local next_cmd = { "git", "-c", "core.fsmonitor=false" }
		for i = 2, #cmd do
			next_cmd[#next_cmd + 1] = cmd[i]
		end
		cmd = next_cmd
	end
	local lines = vim.fn.systemlist(cmd)
	return (vim.v.shell_error == 0) and lines or nil
end

function M.line_count(path)
	local resolved = vim.fn.fnamemodify(path or "", ":p")
	local stat = resolved ~= "" and uv.fs_stat(resolved) or nil
	if not (stat and stat.type == "file") then
		return 0
	end
	local fd = uv.fs_open(resolved, "r", 438)
	if not fd then
		return 0
	end
	local data = uv.fs_read(fd, stat.size or 0, 0) or ""
	uv.fs_close(fd)
	if data == "" then
		return 0
	end
	local _, count = data:gsub("\n", "\n")
	if data:sub(-1) == "\n" then
		return count
	end
	return count + 1
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

function M.parse_numstat_path(path)
	if not path or path == "" then
		return nil
	end
	if not path:find("=>", 1, true) then
		local normalized = M.normalize_status_path(path)
		return {
			path = normalized,
			old_path = nil,
			label = vim.fn.fnamemodify(normalized, ":t"),
			right = nil,
		}
	end

	local old_path, new_path
	local prefix, old_mid, new_mid, suffix = path:match("^(.-){(.-) => (.-)}(.*)$")
	if prefix ~= nil then
		old_path = prefix .. old_mid .. suffix
		new_path = prefix .. new_mid .. suffix
	else
		old_path, new_path = path:match("^(.-) => (.+)$")
	end

	old_path = M.normalize_status_path(old_path or path)
	new_path = M.normalize_status_path(new_path or path)
	return {
		path = new_path,
		old_path = old_path,
		label = vim.fn.fnamemodify(new_path, ":t"),
		right = nil,
	}
end

function M.path_dir(path)
	local dir = vim.fn.fnamemodify(path or "", ":h")
	return dir == "." and "" or dir
end

function M.path_name(path)
	return vim.fn.fnamemodify(path or "", ":t")
end

function M.rename_right(old_path, new_path, added, removed)
	local old_name = old_path or ""
	if old_name ~= "" and M.path_dir(old_path) == M.path_dir(new_path) then
		old_name = M.path_name(old_path)
	end
	local parts = {}
	if old_name ~= "" then
		parts[#parts + 1] = "renamed from " .. old_name
	end
	local stats = M.file_change_right(added, removed)
	if stats ~= "" then
		parts[#parts + 1] = stats
	end
	return table.concat(parts, " ")
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
