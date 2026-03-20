local M = {}

M.mode = {
	name = "files",
	start = "",
	icon = "󰈔",
	placeholder = "Search Files",
}

M.preview = false

M.panels = {
	{ name = "files_all", label = "All" },
	{ name = "files_open", label = "Open" },
	{ name = "files_recent", label = "Recent" },
}

local function normalize_path(path)
	return vim.fn.fnamemodify(path, ":p")
end

local function in_project(path, root)
	local r = normalize_path(root)
	if r:sub(-1) ~= "/" then r = r .. "/" end
	return normalize_path(path):sub(1, #r) == r
end

local function collect_opened_files()
	local opened = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted then
			local path = vim.api.nvim_buf_get_name(buf)
			if path ~= "" and vim.fn.filereadable(path) == 1 then
				opened[#opened + 1] = path
			end
		end
	end
	table.sort(opened)
	return opened
end

local function collect_recent_files(project_root)
	local recent, seen = {}, {}
	for _, path in ipairs(vim.v.oldfiles or {}) do
		if path ~= "" and vim.fn.filereadable(path) == 1 and in_project(path, project_root) then
			local abs = normalize_path(path)
			if not seen[abs] then
				seen[abs] = true
				recent[#recent + 1] = abs
			end
		end
	end
	return recent
end

function M.init(ctx)
	local project_root = type(ctx) == "string" and ctx or (ctx and ctx.cwd) or vim.fn.getcwd()
	return {
		opened = collect_opened_files(),
		recent = collect_recent_files(project_root),
		files = nil,
	}
end

local function ensure_repo_files(state)
	if state.files then
		return state.files
	end
	local files = vim.fn.systemlist({ "rg", "--files", "--hidden", "-g", "!.git" })
	state.files = (vim.v.shell_error == 0) and files or {}
	return state.files
end

function M.items(state, query, panel_name)
	local pulse = require("pulse")
	local items = {}
	local paths

	if panel_name == "files_open" then
		paths = state.opened
	elseif panel_name == "files_recent" then
		paths = state.recent
	else
		paths = ensure_repo_files(state)
	end

	if not query or query == "" then
		for _, path in ipairs(paths) do
			items[#items + 1] = { kind = "file", path = path }
		end
		return items
	end

	local match = pulse.make_matcher(query, { ignore_case = true, plain = true })
	for _, path in ipairs(paths) do
		if match(path) then
			items[#items + 1] = { kind = "file", path = path }
		end
	end
	return items
end

function M.total_count(state, panel_name)
	if panel_name == "files_open" then
		return #(state.opened or {})
	end
	if panel_name == "files_recent" then
		return #(state.recent or {})
	end
	return #(ensure_repo_files(state) or {})
end

return M
