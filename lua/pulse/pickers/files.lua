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
		root = project_root,
		opened = collect_opened_files(),
		recent = collect_recent_files(project_root),
		files = nil,
		ignored = nil,
		expanded = {},
	}
end

local function sort_names(a, b)
	return a:lower() < b:lower()
end

local function relative_path(root, path)
	if not path or path == "" then
		return ""
	end
	if path:sub(-1) == "/" then
		return path
	end
	if path:sub(1, 1) ~= "/" then
		return path
	end
	if in_project(path, root) then
		return vim.fn.fnamemodify(path, ":.")
	end
	return path
end

local function collect_project_files(state)
	if state.files and state.ignored then
		return state.files, state.ignored
	end

	local root = state.root or vim.fn.getcwd()
	local files = {}
	local ignored = {}
	local seen = {}

	local function add_paths(paths, is_ignored)
		for _, path in ipairs(paths or {}) do
			if path ~= "" and not seen[path] then
				seen[path] = true
				files[#files + 1] = path
			end
			if is_ignored and path ~= "" then
				ignored[path] = true
			end
		end
	end

	if vim.fn.isdirectory(root .. "/.git") == 1 then
		add_paths(vim.fn.systemlist({ "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard" }), false)
		add_paths(vim.fn.systemlist({ "git", "-C", root, "ls-files", "--ignored", "--others", "--exclude-standard" }), true)
		add_paths(vim.fn.systemlist({ "git", "-C", root, "ls-files", "--ignored", "--others", "--exclude-standard", "--directory" }), true)
	else
		local visible = vim.fn.systemlist({ "rg", "--files", "--hidden", "-g", "!.git" })
		local all = vim.fn.systemlist({ "rg", "--files", "--hidden", "--no-ignore", "-g", "!.git" })
		if vim.v.shell_error == 0 then
			local visible_set = {}
			for _, path in ipairs(visible or {}) do
				visible_set[path] = true
			end
			for _, path in ipairs(all or {}) do
				add_paths({ path }, not visible_set[path])
			end
		else
			add_paths(visible, false)
		end
	end

	table.sort(files, sort_names)
	state.files = files
	state.ignored = ignored
	return state.files, state.ignored
end

local function build_tree_items(paths, ignored, expanded)
	local root = { dirs = {}, files = {} }

	for _, path in ipairs(paths or {}) do
		local is_dir = path:sub(-1) == "/"
		local clean_path = is_dir and path:sub(1, -2) or path
		local parts = vim.split(clean_path, "/", { plain = true, trimempty = true })
		local node = root
		local dir = nil

		for i = 1, math.max(#parts - (is_dir and 0 or 1), 0) do
			dir = dir and (dir .. "/" .. parts[i]) or parts[i]
			local child = node.dirs[parts[i]]
			if not child then
				child = {
					name = parts[i],
					path = dir,
					dirs = {},
					files = {},
					ignored = ignored[dir] == true or ignored[dir .. "/"] == true,
				}
				node.dirs[parts[i]] = child
			end
			if ignored[dir] == true or ignored[dir .. "/"] == true then
				child.ignored = true
			end
			node = child
		end

		if not is_dir and #parts > 0 then
			node.files[parts[#parts]] = {
				name = parts[#parts],
				path = clean_path,
				ignored = ignored[path] == true,
			}
		end
	end

	local function mark_ignored(node)
		local has_visible = false
		local forced_ignored = node.ignored == true

		for _, child in pairs(node.dirs) do
			if not mark_ignored(child) then
				has_visible = true
			end
		end

		for _, file in pairs(node.files) do
			if not file.ignored then
				has_visible = true
			end
		end

		node.ignored = forced_ignored or not has_visible
		return node.ignored
	end

	local items = {}
	local function append(node, depth)
		local dir_names = vim.tbl_keys(node.dirs)
		local file_names = vim.tbl_keys(node.files)
		table.sort(dir_names, sort_names)
		table.sort(file_names, sort_names)

		for _, name in ipairs(dir_names) do
			local child = node.dirs[name]
			items[#items + 1] = {
				kind = "folder",
				path = child.path,
				label = child.name,
				depth = depth,
				expanded = expanded[child.path] == true,
				ignored = child.ignored,
			}
			if expanded[child.path] == true then
				append(child, depth + 1)
			end
		end

		for _, name in ipairs(file_names) do
			local file = node.files[name]
			items[#items + 1] = {
				kind = "file",
				path = file.path,
				label = file.name,
				depth = depth,
				ignored = file.ignored,
			}
		end
	end

	mark_ignored(root)
	append(root, 0)
	return items
end

local function build_search_items(state, paths, ignored)
	local groups = {}
	local order = {}

	for _, path in ipairs(paths or {}) do
		local rel = relative_path(state.root, path)
		local dir = vim.fn.fnamemodify(rel, ":h")
		if dir == "." then
			dir = ""
		end
		if not groups[dir] then
			groups[dir] = {}
			order[#order + 1] = dir
		end
		groups[dir][#groups[dir] + 1] = {
			path = path,
			rel = rel,
			name = vim.fn.fnamemodify(rel, ":t"),
			ignored = ignored[path] == true,
		}
	end

	table.sort(order, sort_names)
	local items = {}
	for _, dir in ipairs(order) do
		local files = groups[dir]
		table.sort(files, function(a, b)
			return sort_names(a.name, b.name)
		end)

		if dir ~= "" and #files > 1 then
			items[#items + 1] = {
				kind = "folder",
				path = dir,
				label = dir .. "/",
				depth = 0,
				expanded = true,
				ignored = false,
				search_group = true,
			}
			for _, file in ipairs(files) do
				items[#items + 1] = {
					kind = "file",
					path = file.path,
					label = file.name,
					depth = 1,
					ignored = file.ignored,
				}
			end
		else
			for _, file in ipairs(files) do
				items[#items + 1] = {
					kind = "file",
					path = file.path,
					label = file.rel,
					depth = 0,
					ignored = file.ignored,
				}
			end
		end
	end

	return items
end

function M.items(state, query, panel_name)
	local pulse = require("pulse")
	local items = {}
	local paths
	local ignored = {}

	if panel_name == "files_open" then
		state.opened = collect_opened_files()
		paths = state.opened
	elseif panel_name == "files_recent" then
		state.recent = collect_recent_files(state.root)
		paths = state.recent
	else
		paths, ignored = collect_project_files(state)
	end

	if not query or query == "" then
		if panel_name == "files_all" then
			return build_tree_items(paths, ignored, state.expanded or {})
		end
		for _, path in ipairs(paths) do
			items[#items + 1] = { kind = "file", path = path, label = relative_path(state.root, path) }
		end
		return items
	end

	local match = pulse.make_matcher(query, { ignore_case = true, plain = true })
	local matches = {}
	for _, path in ipairs(paths) do
		if match(path) then
			matches[#matches + 1] = path
		end
	end
	return build_search_items(state, matches, ignored)
end

local function toggle_folder(ctx)
	local item = ctx and ctx.item
	if not (ctx and ctx.state and item and item.kind == "folder" and item.path and not item.search_group) then
		return false
	end
	ctx.state.expanded[item.path] = not ctx.state.expanded[item.path]
	ctx.refresh()
	return true
end

function M.on_tab(ctx)
	if toggle_folder(ctx) then
		return
	end
	ctx.jump(ctx.item)
end

function M.on_submit(ctx)
	if toggle_folder(ctx) then
		return
	end
	if ctx.item then
		ctx.close()
		ctx.jump(ctx.item)
	end
end

function M.total_count(state, panel_name)
	if panel_name == "files_open" then
		state.opened = collect_opened_files()
		return #(state.opened or {})
	end
	if panel_name == "files_recent" then
		state.recent = collect_recent_files(state.root)
		return #(state.recent or {})
	end
	return #(collect_project_files(state))
end

return M
