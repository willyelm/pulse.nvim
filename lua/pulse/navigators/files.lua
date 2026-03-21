local M = {}
local scope = require("pulse.scope")

local DEFAULT_OPTS = {
	icons = false,
	open_on_directory = false,
	filters = {},
	git = {
		enable = false,
		ignore = true,
	},
}

M.mode = {
	name = "files",
	start = "",
	icon = "󰈔",
	placeholder = "Search Files",
}

M.context = false

M.panels = {
	{ name = "files_all", label = "All" },
	{ name = "files_open", label = "Open" },
	{ name = "files_recent", label = "Recent" },
}

local function navigator_opts(opts)
	return vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_OPTS), opts or {})
end

local function current_opts(state)
	return (state and state.opts) or DEFAULT_OPTS
end

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

local function is_filtered(path, opts)
	local name = vim.fn.fnamemodify(path or "", ":t")
	for _, pattern in ipairs((opts and opts.filters) or {}) do
		if type(pattern) == "string" and pattern ~= "" then
			if name:match(pattern) or tostring(path or ""):match(pattern) then
				return true
			end
		end
	end
	return false
end

local function filtered_paths(paths, opts)
	return vim.tbl_filter(function(path)
		return not is_filtered(path, opts)
	end, paths or {})
end

local function opened_set(state)
	local set = {}
	for _, path in ipairs(state.opened or collect_opened_files()) do
		set[path] = true
		set[normalize_path(path)] = true
	end
	return set
end

local function setup_highlights()
	pcall(vim.api.nvim_set_hl, 0, "PulseAdd", { link = "Added", default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseDelete", { link = "Removed", default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseChange", { link = "Changed", default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseOpenFile", { bold = true, default = true })
end

function M.init(ctx)
	setup_highlights()
	local project_root = type(ctx) == "string" and ctx or (ctx and ctx.cwd) or vim.fn.getcwd()
	local opts = navigator_opts(ctx and ctx.opts)
	return {
		root = project_root,
		opts = opts,
		opened = collect_opened_files(),
		recent = collect_recent_files(project_root),
		files = nil,
		ignored = nil,
		git_status = nil,
		expanded = {},
		scope = ctx and ctx.scope or nil,
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

local function relative_scope_path(root, scoped)
	if not (scoped and scoped.path) then
		return nil
	end
	local rel = vim.fn.fnamemodify(scoped.path, ":.")
	if rel == "." or rel == "" then
		return nil
	end
	if rel:sub(1, 3) == "../" then
		return nil
	end
	return rel:gsub("/$", "")
end

local function scoped_display_path(state, path)
	local rel = relative_path(state.root, path)
	local scoped = relative_scope_path(state.root, state.scope)
	if not scoped or scoped == "" then
		return rel
	end
	local prefix = scoped .. "/"
	if rel == scoped then
		return vim.fn.fnamemodify(rel, ":t")
	end
	if rel:sub(1, #prefix) == prefix then
		return rel:sub(#prefix + 1)
	end
	return rel
end

local function apply_scope(state, paths, ignored, statuses)
	local scoped = relative_scope_path(state.root, state.scope)
	if not (scoped and state.scope and state.scope.kind == "folder") then
		return paths, ignored, statuses
	end

	local prefix = scoped .. "/"
	local scoped_paths = {}
	local scoped_ignored = {}
	local scoped_statuses = {}
	local function in_scope(path)
		local rel = relative_path(state.root, path)
		return rel == scoped or rel:sub(1, #prefix) == prefix
	end

	for _, path in ipairs(paths or {}) do
		if in_scope(path) then
			scoped_paths[#scoped_paths + 1] = path
		end
	end
	for path, value in pairs(ignored or {}) do
		if in_scope(path) then
			scoped_ignored[path] = value
		end
	end
	for path, value in pairs(statuses or {}) do
		if in_scope(path) then
			scoped_statuses[path] = value
		end
	end
	return scoped_paths, scoped_ignored, scoped_statuses
end

local function path_exists(root, path)
	if not path or path == "" then
		return false
	end
	local abs = path:sub(1, 1) == "/" and path or (normalize_path(root) .. "/" .. path)
	if path:sub(-1) == "/" then
		return vim.fn.isdirectory(abs:sub(1, -2)) == 1
	end
	return vim.fn.filereadable(abs) == 1 or vim.fn.isdirectory(abs) == 1
end

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

local function git_status_map(root, opts)
	if not (opts.git and opts.git.enable) or vim.fn.isdirectory(root .. "/.git") ~= 1 then
		return {}
	end

	local out = {}
	local cmd = { "git", "-C", root, "status", "--porcelain=v1", "--untracked-files=all" }
	if opts.git.ignore then
		cmd[#cmd + 1] = "--ignored=matching"
	end
	local lines = vim.fn.systemlist(cmd)
	if vim.v.shell_error ~= 0 then
		return out
	end

	for _, line in ipairs(lines or {}) do
		local code = line:sub(1, 2)
		local rest = vim.trim(line:sub(4))
		local path = normalize_status_path(rest)
		if path ~= "" then
			out[path] = vim.trim(code)
		end
	end
	return out
end

local function status_tokens(code)
	if not code or code == "" then
		return {}
	end
	if code == "!!" or code == "ignored" then
		return { "!" }
	end
	if code == "??" then
		return { "??" }
	end
	local tokens = {}
	local x, y = code:sub(1, 1), code:sub(2, 2)
	if x == "A" or y == "A" then
		tokens[#tokens + 1] = "+"
	end
	if x == "M" or y == "M" then
		tokens[#tokens + 1] = "~"
	end
	if x == "D" or y == "D" then
		tokens[#tokens + 1] = "-"
	end
	return tokens
end

local function join_tokens(tokens)
	return (#tokens > 0) and table.concat(tokens, " ") or ""
end

local function right_matches(tokens)
	local matches = {}
	local col = 0
	for i, token in ipairs(tokens or {}) do
		local hl = (token == "+" or token == "??") and "PulseAdd"
			or (token == "-") and "PulseDelete"
			or (token == "~") and "PulseChange"
			or (token == "!") and "Comment"
			or nil
		if hl then
			matches[#matches + 1] = { col, col + #token, hl }
		end
		col = col + #token
		if i < #(tokens or {}) then
			col = col + 1
		end
	end
	return matches
end

local function display_meta(tokens)
	return {
		display_right = join_tokens(tokens),
		right_matches = right_matches(tokens),
	}
end

local function file_display_meta(code, ignored)
	return display_meta(status_tokens(code or (ignored and "!" or nil)))
end

local function ordered_statuses(statuses, ignored)
	local out = {}
	local order = { "!", "??", "+", "~", "-" }
	if ignored then
		out[#out + 1] = "!"
	end
	for _, token in ipairs(order) do
		if token ~= "!" and statuses and statuses[token] then
			out[#out + 1] = token
		end
	end
	return out
end

local function folder_display_meta(statuses, ignored)
	return display_meta(ordered_statuses(statuses, ignored))
end

local function add_status_set(target, code)
	target = target or {}
	for _, token in ipairs(status_tokens(code)) do
		target[token] = true
	end
	return target
end

local function ensure_dir(node, name, path, ignored)
	local child = node.dirs[name]
	if child then
		if ignored then
			child.ignored = true
		end
		return child
	end
	child = {
		name = name,
		path = path,
		dirs = {},
		files = {},
		ignored = ignored == true,
		statuses = {},
	}
	node.dirs[name] = child
	return child
end

local function collect_project_files(state)
	if state.files and state.ignored and state.git_status then
		return state.files, state.ignored
	end

	local root = state.root or vim.fn.getcwd()
	local opts = current_opts(state)
	local files = {}
	local ignored = {}
	local seen = {}
	state.git_status = git_status_map(root, opts)

	local function add_paths(paths, is_ignored)
		for _, path in ipairs(paths or {}) do
			if path ~= "" and path_exists(root, path) and not seen[path] and not is_filtered(path, opts) then
				seen[path] = true
				files[#files + 1] = path
			end
			if is_ignored and path ~= "" and path_exists(root, path) and not is_filtered(path, opts) then
				ignored[path] = true
			end
		end
	end

	if opts.git.enable and vim.fn.isdirectory(root .. "/.git") == 1 then
		add_paths(vim.fn.systemlist({ "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard" }), false)
		if opts.git.ignore then
			add_paths(vim.fn.systemlist({ "git", "-C", root, "ls-files", "--ignored", "--others", "--exclude-standard" }), true)
			add_paths(vim.fn.systemlist({ "git", "-C", root, "ls-files", "--ignored", "--others", "--exclude-standard", "--directory" }), true)
		else
			add_paths(vim.fn.systemlist({ "rg", "--files", "--hidden", "--no-ignore", "-g", "!.git", root }), false)
		end
	else
		local visible = vim.fn.systemlist({ "rg", "--files", "--hidden", "-g", "!.git", root })
		local all = vim.fn.systemlist({ "rg", "--files", "--hidden", "--no-ignore", "-g", "!.git", root })
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

local function item(kind, path, label, depth, ignored, opts, extra)
	return vim.tbl_extend("force", {
		kind = kind,
		path = path,
		label = label,
		depth = depth or 0,
		no_icon = opts.icons == false,
		ignored = ignored == true,
	}, extra or {})
end

local function file_item(opts, path, label, depth, ignored, is_open, code)
	return item("file", path, label, depth, ignored, opts, vim.tbl_extend("force", {
		is_open = is_open,
	}, file_display_meta(code, ignored)))
end

local function build_tree_items(paths, ignored, expanded, opts)
	local root = { dirs = {}, files = {} }
	local git_status = opts.git_status or {}
	local open_map = opts.open_map or {}
	local prefix = (opts.scope_prefix and opts.scope_prefix ~= "") and (opts.scope_prefix .. "/") or nil

	for _, path in ipairs(paths or {}) do
		local is_dir = path:sub(-1) == "/"
		local clean_path = is_dir and path:sub(1, -2) or path
		local display_path = clean_path
		if prefix and clean_path:sub(1, #prefix) == prefix then
			display_path = clean_path:sub(#prefix + 1)
		end
		local parts = vim.split(display_path, "/", { plain = true, trimempty = true })
		local node = root
		local dir = nil

		for i = 1, math.max(#parts - (is_dir and 0 or 1), 0) do
			dir = dir and (dir .. "/" .. parts[i]) or parts[i]
			local child = ensure_dir(node, parts[i], dir, ignored[dir] == true or ignored[dir .. "/"] == true)
			child.statuses = add_status_set(child.statuses, git_status[dir] or git_status[dir .. "/"])
			node = child
		end

		if not is_dir and #parts > 0 then
			node.files[parts[#parts]] = {
				name = parts[#parts],
				path = clean_path,
				ignored = ignored[path] == true,
				status = git_status[clean_path],
				is_open = open_map[clean_path] == true or open_map[normalize_path(clean_path)] == true,
			}
		end
	end

	for path, code in pairs(git_status) do
		local parts = vim.split(path, "/", { plain = true, trimempty = true })
		local node = root
		local dir = nil
		for i = 1, math.max(#parts - 1, 0) do
			dir = dir and (dir .. "/" .. parts[i]) or parts[i]
			local child = ensure_dir(node, parts[i], dir, ignored[dir] == true or ignored[dir .. "/"] == true)
			child.statuses = add_status_set(child.statuses, code)
			node = child
		end
	end

	local function mark_ignored(node)
		local has_visible = false
		local forced_ignored = node.ignored == true

		for _, child in pairs(node.dirs) do
			if not mark_ignored(child) then
				has_visible = true
			end
			for token in pairs(child.statuses or {}) do
				node.statuses = node.statuses or {}
				node.statuses[token] = true
			end
		end

		for _, file in pairs(node.files) do
			if not file.ignored then
				has_visible = true
			end
			node.statuses = add_status_set(node.statuses, file.status)
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
			items[#items + 1] = item("folder", child.path, child.name, depth, child.ignored, opts, vim.tbl_extend("force", {
				expanded = expanded[child.path] == true,
			}, folder_display_meta(child.statuses, child.ignored)))
			if expanded[child.path] == true then
				append(child, depth + 1)
			end
		end

		for _, name in ipairs(file_names) do
			local file = node.files[name]
			items[#items + 1] = file_item(opts, file.path, file.name, depth, file.ignored, file.is_open, file.status)
		end
	end

	mark_ignored(root)
	append(root, 0)
	return items
end

local function build_search_items(state, paths, ignored)
	local groups = {}
	local order = {}
	local git_status = state.git_status or {}
	local open_map = opened_set(state)

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
			rel = scoped_display_path(state, path),
			name = vim.fn.fnamemodify(rel, ":t"),
			ignored = ignored[path] == true,
			status = git_status[path],
			is_open = open_map[path] == true or open_map[normalize_path(path)] == true,
		}
	end

	table.sort(order, sort_names)
	local items = {}
	for _, dir in ipairs(order) do
		local files = groups[dir]
		local dir_label = dir == "" and "" or scoped_display_path(state, dir)
		table.sort(files, function(a, b)
			return sort_names(a.name, b.name)
		end)

		if dir ~= "" and #files > 1 then
			items[#items + 1] = item("folder", dir, dir_label, 0, false, state.opts, {
				expanded = true,
				search_group = true,
			})
			for _, file in ipairs(files) do
				items[#items + 1] = file_item(state.opts, file.path, file.name, 1, file.ignored, file.is_open, file.status)
			end
		else
			for _, file in ipairs(files) do
				items[#items + 1] = file_item(state.opts, file.path, file.rel, 0, file.ignored, file.is_open, file.status)
			end
		end
	end

	return items
end

local function panel_paths(state, panel_name)
	if panel_name == "files_open" then
		state.opened = filtered_paths(collect_opened_files(), current_opts(state))
		return state.opened, {}
	end
	if panel_name == "files_recent" then
		state.recent = filtered_paths(collect_recent_files(state.root), current_opts(state))
		return state.recent, {}
	end
	return collect_project_files(state)
end

function M.items(state, query, panel_name)
	local pulse = require("pulse")
	local items = {}
	local paths, ignored = panel_paths(state, panel_name)
	paths, ignored, state.git_status = apply_scope(state, paths, ignored, state.git_status or {})
	local open_map = opened_set(state)

	if not query or query == "" then
		if panel_name == "files_all" then
			local tree_opts = vim.tbl_extend("force", {}, state.opts, {
				git_status = state.git_status or {},
				open_map = open_map,
				scope_prefix = relative_scope_path(state.root, state.scope),
			})
			return build_tree_items(paths, ignored, state.expanded or {}, tree_opts)
		end
		for _, path in ipairs(paths) do
			items[#items + 1] = file_item(
				state.opts,
				path,
				scoped_display_path(state, path),
				0,
				ignored[path] == true,
				open_map[path] == true or open_map[normalize_path(path)] == true,
				(state.git_status or {})[path]
			)
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

function M.input_scope(_, scoped)
	return scoped
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
	if not (ctx and ctx.item) then
		return
	end
	if ctx.item.kind == "folder" then
		ctx.set_scope(scope.folder(ctx.state.root .. "/" .. ctx.item.path))
		return
	end
	if ctx.jump(ctx.item) then
		local path = ctx.state.root .. "/" .. ctx.item.path
		local bufnr = vim.fn.bufnr(vim.fn.fnamemodify(path, ":p"))
		ctx.set_scope(scope.file(path, bufnr > 0 and bufnr or nil))
	end
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
	local paths = panel_paths(state, panel_name)
	paths = apply_scope(state, paths, {}, state.git_status or {})
	return #(paths)
end

function M.setup_directory_hijack(opts)
	local group = vim.api.nvim_create_augroup("PulseFilesDirectoryHijack", { clear = true })
	vim.api.nvim_create_autocmd({ "VimEnter", "BufEnter" }, {
		group = group,
		callback = function(args)
			if not (opts and opts.is_enabled and opts.is_enabled()) then
				return
			end
			if vim.b[args.buf].pulse_directory_hijacked then
				return
			end
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(args.buf) then
					return
				end
				local path = vim.api.nvim_buf_get_name(args.buf)
				if path == "" or vim.fn.isdirectory(path) ~= 1 then
					return
				end

				vim.b[args.buf].pulse_directory_hijacked = true
				vim.cmd("silent keepalt enew")
				if vim.api.nvim_buf_is_valid(args.buf) then
					pcall(vim.api.nvim_buf_delete, args.buf, { force = true })
				end
				opts.open(path)
			end)
		end,
	})
end

return M
