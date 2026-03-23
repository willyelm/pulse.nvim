local pulse = require("pulse")
local scope = require("pulse.scope")
local uv = vim.uv or vim.loop

local M = {}
local PROJECT_CACHE = {}
local DIR_CACHE = {}
local git_status_and_ignored
local path_exists
local normalize_entry_path

local function normalize_path(path)
	return vim.fn.fnamemodify(path, ":p")
end

local function sort_names(a, b)
	return a:lower() < b:lower()
end

function M.navigator_opts(defaults, opts)
	return vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

local function in_project(path, root)
	local r = normalize_path(root)
	if r:sub(-1) ~= "/" then
		r = r .. "/"
	end
	return normalize_path(path):sub(1, #r) == r
end

function M.collect_opened_files()
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
	if type(code) == "table" then
		local out = {}
		for _, token in ipairs({ "!", "??", "+", "~", "-" }) do
			if code[token] then
				out[#out + 1] = token
			end
		end
		return out
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

function M.absolute_path(root, path)
	if not path or path == "" then
		return nil
	end
	return path:sub(1, 1) == "/" and path or (root .. "/" .. path)
end

local function opened_set(state)
	local set = {}
	for _, path in ipairs(state.opened or M.collect_opened_files()) do
		set[path] = true
		set[normalize_path(path)] = true
	end
	return set
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
	if rel == "." or rel == "" or rel:sub(1, 3) == "../" then
		return nil
	end
	return rel:gsub("/$", "")
end

local function folder_scope_prefix(state)
	return (state.scope and state.scope.kind == "folder") and relative_scope_path(state.root, state.scope) or nil
end

local function scope_ignored(state, ignored_map)
	local scoped = folder_scope_prefix(state)
	if not scoped then
		return false
	end
	return ignored_map[scoped] == true or ignored_map[scoped .. "/"] == true
end

local function dir_statuses(status_map)
	local by_dir = {}
	for path, code in pairs(status_map or {}) do
		local dir = vim.fn.fnamemodify(path, ":h")
		while dir and dir ~= "." and dir ~= "" do
			by_dir[dir] = by_dir[dir] or {}
			for _, token in ipairs(status_tokens(code)) do
				by_dir[dir][token] = true
			end
			local parent = vim.fn.fnamemodify(dir, ":h")
			if parent == dir then
				break
			end
			dir = parent
		end
	end
	return by_dir
end

local function collect_tree_metadata(state)
	if state.ignored and state.git_status and state.dir_statuses then
		return state.ignored, state.git_status, state.dir_statuses
	end
	local ignored_list
	state.git_status, ignored_list = git_status_and_ignored(state.root, state.opts)
	state.ignored = {}
	for _, path in ipairs(ignored_list or {}) do
		path = normalize_entry_path(state.root, path)
		if path ~= "" and path_exists(state.root, path) and not is_filtered(path, state.opts) then
			state.ignored[path] = true
		end
	end
	state.dir_statuses = dir_statuses(state.git_status or {})
	return state.ignored, state.git_status or {}, state.dir_statuses
end

local function scan_dir(state, dir_rel, parent_ignored)
	local abs_dir = dir_rel == "" and state.root or M.absolute_path(state.root, dir_rel)
	local cache_key = normalize_path(abs_dir)
	local cached = DIR_CACHE[cache_key]
	if cached then
		return cached
	end
	local ignored_map, git_status, dir_status_map = collect_tree_metadata(state)
	local handle = uv.fs_scandir(abs_dir)
	local children = {}
	if handle then
		while true do
			local name, kind = uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if name ~= ".git" then
				local rel = (dir_rel ~= "" and (dir_rel .. "/" .. name) or name)
				local is_dir = kind == "directory"
				local rel_with_slash = is_dir and (rel .. "/") or rel
				if not is_filtered(rel_with_slash, state.opts) then
					local ignored = parent_ignored == true or ignored_map[rel] == true or ignored_map[rel_with_slash] == true
					children[#children + 1] = {
						kind = is_dir and "folder" or "file",
						path = rel,
						label = name,
						ignored = ignored,
						status = is_dir and dir_status_map[rel] or git_status[rel],
					}
				end
			end
		end
	end
	table.sort(children, function(a, b)
		if a.kind ~= b.kind then
			return a.kind == "folder"
		end
		return sort_names(a.label, b.label)
	end)
	DIR_CACHE[cache_key] = children
	return children
end

local function lazy_tree_entries(state)
	local ignored_map = collect_tree_metadata(state)
	local scope_prefix = folder_scope_prefix(state) or ""
	local root_ignored = scope_prefix ~= "" and (ignored_map[scope_prefix] == true or ignored_map[scope_prefix .. "/"] == true) or false
	local entries = {}
	local function walk(dir_rel, parent_ignored)
		for _, child in ipairs(scan_dir(state, dir_rel, parent_ignored)) do
			entries[#entries + 1] = child
			if child.kind == "folder" and state.expanded[child.path] == true then
				walk(child.path, child.ignored)
			end
		end
	end
	walk(scope_prefix, root_ignored)
	return entries, ignored_map, scope_prefix, root_ignored
end

function M.parent_scope(state)
	local scoped = folder_scope_prefix(state)
	if not scoped then
		return nil
	end
	local parent = vim.fn.fnamemodify(scoped, ":h")
	if parent == "." or parent == "" then
		return nil
	end
	return scope.folder(state.root .. "/" .. parent)
end

local function scoped_display_path(state, path)
	local rel = relative_path(state.root, path)
	local scoped = folder_scope_prefix(state)
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
	local scoped = folder_scope_prefix(state)
	if not scoped then
		return paths, ignored, statuses
	end
	local prefix = scoped .. "/"
	local scoped_paths, scoped_ignored, scoped_statuses = {}, {}, {}
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

path_exists = function(root, path)
	if not path or path == "" then
		return false
	end
	local abs = M.absolute_path(normalize_path(root), path)
	if path:sub(-1) == "/" then
		return vim.fn.isdirectory(abs:sub(1, -2)) == 1
	end
	return vim.fn.filereadable(abs) == 1 or vim.fn.isdirectory(abs) == 1
end

normalize_entry_path = function(root, path)
	if not path or path == "" then
		return path
	end
	local abs = M.absolute_path(normalize_path(root), path)
	if abs and vim.fn.isdirectory(abs) == 1 and path:sub(-1) ~= "/" then
		return path .. "/"
	end
	return path
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

git_status_and_ignored = function(root, opts)
	if not (opts.git and opts.git.enable) or vim.fn.isdirectory(root .. "/.git") ~= 1 then
		return {}, {}
	end
	local status_map, ignored, seen_ignored = {}, {}, {}
	local cmd = { "git", "-C", root, "status", "--porcelain=v1", "--untracked-files=all" }
	if opts.git.ignore then
		cmd[#cmd + 1] = "--ignored=matching"
	end
	local lines = vim.fn.systemlist(cmd)
	if vim.v.shell_error ~= 0 then
		return status_map, ignored
	end
	for _, line in ipairs(lines or {}) do
		local code = vim.trim(line:sub(1, 2))
		local path = normalize_status_path(vim.trim(line:sub(4)))
		if path ~= "" then
			if code == "!!" then
				if not seen_ignored[path] then
					seen_ignored[path] = true
					ignored[#ignored + 1] = path
				end
			else
				status_map[path] = code
			end
		end
	end
	return status_map, ignored
end

local function right_matches(tokens)
	local matches, col = {}, 0
	for i, token in ipairs(tokens or {}) do
		local hl = (token == "+" or token == "??") and "Added"
			or (token == "-") and "Removed"
			or (token == "~") and "Changed"
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
	local text = (#tokens > 0) and table.concat(tokens, " ") or nil
	return {
		display_right = text,
		right_matches = text and right_matches(tokens) or nil,
	}
end

local function ordered_statuses(statuses, ignored)
	local out = {}
	for _, token in ipairs({ "!", "??", "+", "~", "-" }) do
		if token == "!" and ignored then
			out[#out + 1] = token
		elseif token ~= "!" and statuses and statuses[token] then
			out[#out + 1] = token
		end
	end
	return out
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
	child = { name = name, path = path, dirs = {}, files = {}, ignored = ignored == true, statuses = {} }
	node.dirs[name] = child
	return child
end

local function item(kind, path, label, depth, ignored, opts, extra)
	return vim.tbl_extend("force", {
		kind = kind,
		path = path,
		label = label,
		depth = depth or 0,
		no_icon = opts.icons == false,
		icon_color = opts.icon_color == true,
		ignored = ignored == true,
	}, extra or {})
end

local function file_item(opts, path, label, depth, ignored, is_open, code)
	return item("file", path, label, depth, ignored, opts, vim.tbl_extend("force", { is_open = is_open }, display_meta(status_tokens(code or (ignored and "!" or nil)))))
end

local function parent_item(state)
	return item("folder", "..", "..", 0, false, state.opts, { scope_parent = true, expanded = false })
end

function M.collect_project_files(state)
	if state.files and state.ignored and state.git_status then
		return state.files, state.ignored
	end
	local root, opts = state.root or vim.fn.getcwd(), state.opts
	local cache_key = table.concat({
		root,
		tostring(opts.git and opts.git.enable == true),
		tostring(opts.git and opts.git.ignore == true),
		table.concat(opts.filters or {}, "\0"),
	}, "|")
	local cached = PROJECT_CACHE[cache_key]
	if cached then
		state.files = cached.files
		state.ignored = cached.ignored
		state.git_status = cached.git_status
		return state.files, state.ignored
	end
	local files, ignored, seen = {}, {}, {}
	local initial_ignored
	state.git_status, initial_ignored = git_status_and_ignored(root, opts)
	local function add_paths(paths, is_ignored)
		for _, path in ipairs(paths or {}) do
			path = normalize_entry_path(root, path)
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
			add_paths(initial_ignored, true)
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
	state.files, state.ignored = files, ignored
	PROJECT_CACHE[cache_key] = {
		files = state.files,
		ignored = state.ignored,
		git_status = state.git_status,
	}
	return state.files, state.ignored
end

local function collapsed_folder(node, compact)
	if not compact then
		return node.name, node.path, node
	end
	local parts = { node.name }
	local current = node
	while vim.tbl_count(current.files) == 0 and vim.tbl_count(current.dirs) == 1 do
		local only = next(current.dirs)
		current = current.dirs[only]
		parts[#parts + 1] = current.name
	end
	return table.concat(parts, "/"), current.path, current
end

function M.build_tree(entries, expanded, opts)
	local tree_opts = opts or {}
	local root = { dirs = {}, files = {}, statuses = {} }
	local base_depth = tree_opts.base_depth or 0
	local ignored_map = tree_opts.ignored or {}
	local prefix = (tree_opts.scope_prefix and tree_opts.scope_prefix ~= "") and (tree_opts.scope_prefix .. "/") or nil
	for _, entry in ipairs(entries or {}) do
		local path = entry.path
		local has_trailing_slash = path:sub(-1) == "/"
		local is_dir = entry.kind == "folder" or has_trailing_slash
		local clean_path = has_trailing_slash and path:sub(1, -2) or path
		local display_path = prefix and clean_path:sub(1, #prefix) == prefix and clean_path:sub(#prefix + 1) or clean_path
		local parts = vim.split(display_path, "/", { plain = true, trimempty = true })
		local node, dir = root, nil
		for i = 1, math.max(#parts - 1, 0) do
			dir = dir and (dir .. "/" .. parts[i]) or parts[i]
			local child = ensure_dir(node, parts[i], dir, false)
			child.statuses = add_status_set(child.statuses, entry.status)
			node = child
		end
		if is_dir and #parts > 0 then
			local child = ensure_dir(node, parts[#parts], clean_path, entry.ignored == true)
			child.statuses = add_status_set(child.statuses, entry.status)
			if entry.extra then
				child.extra = vim.tbl_extend("force", child.extra or {}, entry.extra)
			end
		elseif #parts > 0 then
			node.files[parts[#parts]] = vim.tbl_extend("force", {
				kind = entry.kind or "file",
				name = entry.label or parts[#parts],
				path = clean_path,
				ignored = entry.ignored == true,
				status = entry.status,
				is_open = entry.is_open == true,
			}, entry)
		end
	end
	for path, code in pairs(tree_opts.git_status or {}) do
		local display_path = prefix and path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or path
		local parts = vim.split(display_path, "/", { plain = true, trimempty = true })
		local node, dir = root, nil
		for i = 1, math.max(#parts - 1, 0) do
			dir = dir and (dir .. "/" .. parts[i]) or parts[i]
			local child = ensure_dir(node, parts[i], dir, ignored_map[dir] == true or ignored_map[dir .. "/"] == true)
			child.statuses = add_status_set(child.statuses, code)
			node = child
		end
	end
	local function mark_ignored(node)
		local explicit_ignored = node.ignored == true
		node.statuses = node.statuses or {}
		for _, child in pairs(node.dirs) do
			mark_ignored(child)
			for token in pairs(child.statuses or {}) do
				node.statuses[token] = true
			end
		end
		for _, file in pairs(node.files) do
			node.statuses = add_status_set(node.statuses, file.status)
		end
		node.ignored = explicit_ignored
		return node.ignored
	end
	local items = {}
	local function append(node, depth, parent_ignored)
		local dir_names, file_names = vim.tbl_keys(node.dirs), vim.tbl_keys(node.files)
		table.sort(dir_names, sort_names)
		table.sort(file_names, sort_names)
		for _, name in ipairs(dir_names) do
			local child = node.dirs[name]
			local label, folder_path, leaf = collapsed_folder(child, tree_opts.compact_dirs == true)
			local folder_key = tree_opts.folder_key and tree_opts.folder_key(folder_path, leaf) or folder_path
			local is_expanded = expanded[folder_key] == true
			if not is_expanded and expanded[folder_key] == nil and tree_opts.folder_expanded then
				is_expanded = tree_opts.folder_expanded(folder_path, folder_key, leaf) == true
			end
			local ignored = parent_ignored == true or leaf.ignored == true
			local folder_item = item("folder", folder_path, label, depth, ignored, tree_opts, vim.tbl_extend("force", {
				expanded = is_expanded,
				tree_key = folder_key ~= folder_path and folder_key or nil,
			}, display_meta(ordered_statuses(leaf.statuses, ignored)), leaf.extra or {}))
			items[#items + 1] = folder_item
			if is_expanded then
				append(leaf, depth + 1, ignored)
			end
		end
		for _, name in ipairs(file_names) do
			local file = node.files[name]
			local meta = file.status and display_meta(status_tokens(file.status)) or {}
			items[#items + 1] = item(file.kind or "file", file.path, file.name, depth, parent_ignored == true or file.ignored == true, tree_opts, vim.tbl_extend("force", {
				is_open = file.is_open,
			}, meta, file))
		end
	end
	mark_ignored(root)
	append(root, base_depth, tree_opts.initial_ignored == true)
	if tree_opts.scope_prefix and tree_opts.scope_prefix ~= "" then
		table.insert(items, 1, parent_item(tree_opts.state))
	end
	return items
end

local function build_search_items(state, paths, ignored_map)
	local groups, order = {}, {}
	local git_status, open_map = state.git_status or {}, opened_set(state)
	local scoped = scope_ignored(state, ignored_map)
	for _, path in ipairs(paths or {}) do
		local rel = scoped_display_path(state, path)
		local dir = vim.fn.fnamemodify(rel, ":h")
		if dir == "." then
			dir = ""
		end
		if not groups[dir] then
			groups[dir], order[#order + 1] = {}, dir
		end
		groups[dir][#groups[dir] + 1] = {
			path = path,
			rel = rel,
			name = vim.fn.fnamemodify(rel, ":t"),
			ignored = scoped or ignored_map[path] == true,
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
			items[#items + 1] = item("folder", dir, dir_label, 0, false, state.opts, { expanded = true })
			for _, file in ipairs(files) do
				items[#items + 1] = file_item(state.opts, file.path, file.name, 1, file.ignored, file.is_open, file.status)
			end
		else
			for _, file in ipairs(files) do
				items[#items + 1] = file_item(state.opts, file.path, file.rel, 0, file.ignored, file.is_open, file.status)
			end
		end
	end
	if state.scope and state.scope.kind == "folder" then
		table.insert(items, 1, parent_item(state))
	end
	return items
end

local function panel_paths(state, panel_name)
	if panel_name == "files_open" then
		state.opened = filtered_paths(M.collect_opened_files(), state.opts)
		return state.opened, {}
	end
	return M.collect_project_files(state)
end

function M.invalidate(state)
	if not state then
		return
	end
	if state.root then
		for key in pairs(PROJECT_CACHE) do
			if key:sub(1, #state.root + 1) == (state.root .. "|") then
				PROJECT_CACHE[key] = nil
			end
		end
		for key in pairs(DIR_CACHE) do
			if key:sub(1, #state.root + 1) == (state.root .. "/") or key == normalize_path(state.root) then
				DIR_CACHE[key] = nil
			end
		end
	end
	state.files = nil
	state.ignored = nil
	state.git_status = nil
	state.opened = M.collect_opened_files()
end

function M.items(state, query, panel_name)
	if state.scope and state.scope.kind == "file" then
		return {}
	end
	if not query or query == "" then
		if panel_name == "files_all" then
			local entries, lazy_ignored, scope_prefix, scoped = lazy_tree_entries(state)
			local open_map = opened_set(state)
			for _, entry in ipairs(entries) do
				if entry.kind == "file" then
					local path = entry.path
					entry.is_open = open_map[path] == true or open_map[normalize_path(path)] == true
				end
			end
			return M.build_tree(entries, state.expanded or {}, vim.tbl_extend("force", {}, state.opts, {
				ignored = lazy_ignored,
				git_status = {},
				initial_ignored = scoped,
				scope_prefix = scope_prefix,
				state = state,
				compact_dirs = state.opts.compact_dirs == true,
			}))
		end
		local paths, ignored_map = panel_paths(state, panel_name)
		paths, ignored_map, state.git_status = apply_scope(state, paths, ignored_map, state.git_status or {})
		local open_map = opened_set(state)
		local scoped = scope_ignored(state, ignored_map)
		local items = {}
		for _, path in ipairs(paths) do
			items[#items + 1] = file_item(
				state.opts,
				path,
				scoped_display_path(state, path),
				0,
				scoped or ignored_map[path] == true,
				panel_name ~= "files_open" and (open_map[path] == true or open_map[normalize_path(path)] == true) or false,
				(state.git_status or {})[path]
			)
		end
		return items
	end
	local paths, ignored_map = M.collect_project_files(state)
	paths, ignored_map, state.git_status = apply_scope(state, paths, ignored_map, state.git_status or {})
	local match = pulse.make_matcher(query, { ignore_case = true, plain = true })
	local matches = {}
	for _, path in ipairs(paths) do
		if match(path) then
			matches[#matches + 1] = path
		end
	end
	return build_search_items(state, matches, ignored_map)
end

function M.total_count(state, panel_name)
	if state.scope and state.scope.kind == "file" then
		return 0
	end
	if panel_name == "files_all" then
		local entries = lazy_tree_entries(state)
		return #entries
	end
	local paths = panel_paths(state, panel_name)
	paths = apply_scope(state, paths, {}, state.git_status or {})
	return #paths
end

return M
