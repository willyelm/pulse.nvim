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

function M.items(state, query)
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

return M
