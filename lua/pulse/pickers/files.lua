local M = {}

M.mode = {
	name = "files",
	start = "",
	icon = "󰈔",
	placeholder = "Search Files",
}

M.preview = false

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

function M.items(state, query)
	local pulse = require("pulse")
	local items, seen = {}, {}

	if not query or query == "" then
		local function add_section(label, paths)
			local section = {}
			for _, path in ipairs(paths) do
				if not seen[path] then
					seen[path] = true
					section[#section + 1] = { kind = "file", path = path }
				end
			end
			if #section > 0 then
				items[#items + 1] = { kind = "header", label = label }
				vim.list_extend(items, section)
			end
		end
		add_section("Active", state.opened)
		add_section("Recent Files", state.recent)
		return items
	end

	local match = pulse.make_matcher(query, { ignore_case = true, plain = true })
	for _, path in ipairs(ensure_repo_files(state)) do
		if match(path) then
			items[#items + 1] = { kind = "file", path = path }
		end
	end
	return items
end

function M.total_count(state)
	return #(ensure_repo_files(state) or {})
end

return M
