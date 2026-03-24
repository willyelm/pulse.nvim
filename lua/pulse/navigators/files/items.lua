local pulse = require("pulse")
local scope = require("pulse.scope")
local uv = vim.uv or vim.loop

local M = {}
local DIR_CACHE = {}
local RESULT_LIMIT = 5000
local path_exists
local normalize_entry_path
local normalize_status_path
local build_search_items
local add_status_set
local display_meta
local ordered_statuses
local item
local file_item
local parent_item
local stop_search_job

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

local function parse_git_status_output(text)
	local status_map, ignored, seen_ignored = {}, {}, {}
	for _, line in ipairs(vim.split(text or "", "\n", { plain = true, trimempty = true })) do
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

local function warm_tree_metadata(state)
	if state._metadata_loading or state.ignored or state.git_status or state.dir_statuses then
		return
	end
	if not (state.opts.git and state.opts.git.enable) or vim.fn.isdirectory(state.root .. "/.git") ~= 1 then
		state.ignored, state.git_status, state.dir_statuses = {}, {}, {}
		return
	end
	state._metadata_loading = true
	local cmd = { "git", "-c", "core.fsmonitor=false", "-C", state.root, "status", "--porcelain=v1", "--untracked-files=all" }
	if state.opts.git.ignore then
		cmd[#cmd + 1] = "--ignored=matching"
	end
	vim.system(cmd, { text = true }, function(result)
		local status_map, ignored_list = {}, {}
		if result.code == 0 then
			status_map, ignored_list = parse_git_status_output(result.stdout)
		end
		local ignored = {}
		for _, path in ipairs(ignored_list or {}) do
			path = normalize_entry_path(state.root, path)
			if path ~= "" and path_exists(state.root, path) and not is_filtered(path, state.opts) then
				ignored[path] = true
			end
		end
		state.git_status = status_map
		state.ignored = ignored
		state.dir_statuses = dir_statuses(status_map)
		state._metadata_loading = false
		for key in pairs(DIR_CACHE) do
			if key:sub(1, #state.root + 1) == (state.root .. "/") or key == normalize_path(state.root) then
				DIR_CACHE[key] = nil
			end
		end
		state.tree_cache_key = nil
		state.tree_provider = nil
		if state._on_update then
			vim.schedule(state._on_update)
		end
	end)
end

local function collect_tree_metadata(state)
	if state.ignored and state.git_status and state.dir_statuses then
		return state.ignored, state.git_status, state.dir_statuses
	end
	warm_tree_metadata(state)
	return state.ignored or {}, state.git_status or {}, state.dir_statuses or {}
end

local function expanded_signature(expanded)
	local keys = {}
	for path, is_expanded in pairs(expanded or {}) do
		if is_expanded then
			keys[#keys + 1] = path
		end
	end
	table.sort(keys, sort_names)
	return table.concat(keys, "\0")
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

local function collapse_scanned_folder(state, entry)
	if state.opts.compact_dirs ~= true then
		return entry.label, entry.path, entry
	end
	local parts = { entry.label }
	local current = entry
	while current and current.kind == "folder" do
		local children = scan_dir(state, current.path, current.ignored)
		if #children ~= 1 or children[1].kind ~= "folder" then
			break
		end
		current = children[1]
		parts[#parts + 1] = current.label
	end
	return table.concat(parts, "/"), current.path, current
end

local function provider_from_rows(rows)
	local provider = {}

	function provider:count()
		return #rows
	end

	function provider:get(index)
		return rows[index]
	end

	return provider
end

local function count_selectable(items)
	local total = 0
	local count = type(items) == "table" and type(items.count) == "function" and items:count() or #(items or {})
	for i = 1, count do
		local item = type(items) == "table" and type(items.get) == "function" and items:get(i) or items[i]
		if item and item.kind ~= "header" and not item.scope_parent then
			total = total + 1
		end
	end
	return total
end

local function lazy_tree_rows(state)
	local cache_key = table.concat({
		tostring(folder_scope_prefix(state) or ""),
		expanded_signature(state.expanded),
	}, "|")
	if state.tree_cache_key == cache_key and state.tree_provider then
		return state.tree_provider
	end
	local ignored_map = collect_tree_metadata(state)
	local scope_prefix = folder_scope_prefix(state) or ""
	local root_ignored = scope_prefix ~= "" and (ignored_map[scope_prefix] == true or ignored_map[scope_prefix .. "/"] == true) or false
	local open_map = opened_set(state)
	local rows = {}

	if scope_prefix ~= "" then
		rows[#rows + 1] = parent_item(state)
	end

	local function walk(dir_rel, depth, parent_ignored)
		for _, child in ipairs(scan_dir(state, dir_rel, parent_ignored)) do
			if child.kind == "folder" then
				local label, folder_path, leaf = collapse_scanned_folder(state, child)
				local ignored = parent_ignored == true or leaf.ignored == true
				rows[#rows + 1] = item("folder", folder_path, label, depth, ignored, state.opts, vim.tbl_extend("force", {
					expanded = state.expanded[folder_path] == true,
				}, display_meta(ordered_statuses(add_status_set({}, leaf.status), ignored))))
				if state.expanded[folder_path] == true then
					walk(folder_path, depth + 1, ignored)
				end
			else
				local path = child.path
				rows[#rows + 1] = file_item(
					state.opts,
					path,
					child.label,
					depth,
					parent_ignored == true or child.ignored == true,
					open_map[path] == true or open_map[normalize_path(path)] == true,
					child.status
				)
			end
		end
	end

	walk(scope_prefix, 0, root_ignored)
	state.tree_cache_key = cache_key
	state.tree_provider = provider_from_rows(rows)
	return state.tree_provider
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

normalize_status_path = function(path)
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

display_meta = function(tokens)
	local text = (#tokens > 0) and table.concat(tokens, " ") or nil
	return {
		display_right = text,
		right_matches = text and right_matches(tokens) or nil,
	}
end

ordered_statuses = function(statuses, ignored)
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

add_status_set = function(target, code)
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

item = function(kind, path, label, depth, ignored, opts, extra)
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

file_item = function(opts, path, label, depth, ignored, is_open, code)
	return item("file", path, label, depth, ignored, opts, vim.tbl_extend("force", { is_open = is_open }, display_meta(status_tokens(code or (ignored and "!" or nil)))))
end

parent_item = function(state)
	return item("folder", "..", "..", 0, false, state.opts, { scope_parent = true, expanded = false })
end

local function glob_escape(text)
	return (text or ""):gsub("([%*%?%[%]{}\\])", "\\%1")
end

stop_search_job = function(state)
	if type(state._search_job) == "table" and state._search_job.kill then
		pcall(state._search_job.kill, state._search_job, 15)
	elseif type(state._search_job) == "number" and state._search_job > 0 then
		pcall(vim.fn.jobstop, state._search_job)
	end
	state._search_job = nil
end

local function append_search_path(state, rel, query)
	if (#(state.search_paths or {}) + #(state.search_folders or {})) >= RESULT_LIMIT then
		state.search_limited = true
		return
	end
	if rel == "" or is_filtered(rel, state.opts) then
		return
	end
	state._search_seen_paths = state._search_seen_paths or {}
	if state._search_seen_paths[rel] then
		return
	end
	state._search_seen_paths[rel] = true
	state.search_paths = state.search_paths or {}
	state.search_paths[#state.search_paths + 1] = rel

	local q = (query or ""):lower()
	if q == "" then
		return
	end
	state._search_seen_folders = state._search_seen_folders or {}
	state.search_folders = state.search_folders or {}
	local dir = vim.fn.fnamemodify(rel, ":h")
		while dir and dir ~= "." and dir ~= "" do
			if (#(state.search_paths or {}) + #(state.search_folders or {})) >= RESULT_LIMIT then
				state.search_limited = true
				return
			end
			if not state._search_seen_folders[dir] and dir:lower():find(q, 1, true) then
				state._search_seen_folders[dir] = true
				state.search_folders[#state.search_folders + 1] = dir
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
end

local function warm_search_query(state, query)
	if state.search_query == query and (state.search_results ~= nil or state._search_job) then
		return
	end
	stop_search_job(state)
	state.search_query = query
	state._search_match_gen = (state._search_match_gen or 0) + 1
	local gen = state._search_match_gen
	local ignored_map = state.ignored or {}
	local search_root = (state.scope and state.scope.kind == "folder" and state.scope.path) or state.root
	state.search_paths = {}
	state.search_folders = {}
	state.search_limited = false
	state._search_seen_paths = {}
	state._search_seen_folders = {}
	state.search_results = build_search_items(state, ignored_map)
	local cmd = {
		"rg",
		"--files",
		"--hidden",
		"-g",
		"!.git",
		"-g",
		"*" .. glob_escape(query) .. "*",
		search_root,
	}
	state._search_job = vim.fn.jobstart(cmd, {
		stdout_buffered = false,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if state._search_match_gen ~= gen or not data then
				return
			end
			local changed = false
			for _, path in ipairs(data) do
				if path and path ~= "" then
					local rel = relative_path(state.root, path)
					local prev_paths = #(state.search_paths or {})
					local prev_folders = #(state.search_folders or {})
					append_search_path(state, rel, query)
					if #(state.search_paths or {}) ~= prev_paths or #(state.search_folders or {}) ~= prev_folders then
						changed = true
					end
					if state.search_limited then
						stop_search_job(state)
						break
					end
				end
			end
			if changed and state._on_update then
				vim.schedule(state._on_update)
			end
		end,
		on_exit = function()
			if state._search_match_gen ~= gen then
				return
			end
			table.sort(state.search_paths or {}, sort_names)
			table.sort(state.search_folders or {}, sort_names)
			state._search_job = nil
			if state._on_update then
				vim.schedule(state._on_update)
			end
		end,
	})
	if type(state._search_job) ~= "number" or state._search_job <= 0 then
		state._search_job = nil
		if state._on_update then
			vim.schedule(state._on_update)
		end
	end
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

build_search_items = function(state, ignored_map)
	local git_status, open_map = state.git_status or {}, opened_set(state)
	local scoped = scope_ignored(state, ignored_map)
	local has_parent = state.scope and state.scope.kind == "folder"
	local provider = {}

	function provider:count()
		local total = #(state.search_folders or {}) + #(state.search_paths or {})
		return total + (has_parent and 1 or 0)
	end

	function provider:get(index)
		index = tonumber(index) or 0
		if index < 1 then
			return nil
		end
		if has_parent then
			if index == 1 then
				return parent_item(state)
			end
			index = index - 1
		end
			local folders = state.search_folders or {}
			local folder = folders[index]
			if folder then
				return item("folder", folder, scoped_display_path(state, folder), 0, scoped or ignored_map[folder] == true or ignored_map[folder .. "/"] == true, state.opts, {
					expanded = false,
					display_right = nil,
				})
			end
			index = index - #folders
			local path = (state.search_paths or {})[index]
			if not path then
				return nil
			end
		return file_item(
			state.opts,
			path,
			scoped_display_path(state, path),
			0,
			scoped or ignored_map[path] == true,
			open_map[path] == true or open_map[normalize_path(path)] == true,
			git_status[path]
		)
	end

	return provider
end

function M.invalidate(state)
	if not state then
		return
	end
	if state.root then
		for key in pairs(DIR_CACHE) do
			if key:sub(1, #state.root + 1) == (state.root .. "/") or key == normalize_path(state.root) then
				DIR_CACHE[key] = nil
			end
		end
	end
	state.ignored = nil
	state.git_status = nil
	state.dir_statuses = nil
	state.tree_cache_key = nil
	state.tree_provider = nil
	state.search_query = nil
	state.search_results = nil
	state._search_match_gen = 0
	stop_search_job(state)
	state.search_paths = nil
	state.search_folders = nil
	state._search_seen_paths = nil
	state._search_seen_folders = nil
	state.opened = M.collect_opened_files()
end

function M.items(state, query, panel_name)
	if state.scope and state.scope.kind == "file" then
		return {}
	end
	if not query or query == "" then
			state.search_query = nil
			state.search_results = nil
			state.search_paths = nil
			state.search_folders = nil
			state._search_seen_paths = nil
			state._search_seen_folders = nil
			state._search_match_gen = (state._search_match_gen or 0) + 1
				stop_search_job(state)
				if panel_name == "files_all" then
					return lazy_tree_rows(state)
				end
			local paths = filtered_paths(M.collect_opened_files(), state.opts)
			local open_map = opened_set(state)
			local items = {}
			for _, path in ipairs(paths) do
				items[#items + 1] = file_item(
					state.opts,
					path,
					relative_path(state.root, path),
					0,
					false,
					open_map[path] == true or open_map[normalize_path(path)] == true,
					nil
				)
			end
			return items
	end
	warm_search_query(state, query)
	return state.search_results or {}
end

function M.total_count(state, panel_name)
	if state.scope and state.scope.kind == "file" then
		return 0
	end
	if panel_name == "files_all" and state.search_query and state.search_query ~= "" then
		local count = count_selectable(state.search_results or {})
		return { count = count, plus = state.search_limited == true }
	end
	if panel_name == "files_all" then
		return count_selectable(lazy_tree_rows(state))
	end
	if state.search_query and state.search_results then
		local count = count_selectable(state.search_results)
		return { count = count, plus = state.search_limited == true }
	end
	local paths = filtered_paths(M.collect_opened_files(), state.opts)
	return #paths
end

return M
