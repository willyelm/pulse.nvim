local pulse = require("pulse")
local scope = require("pulse.scope")

local M = {}

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

local function path_exists(root, path)
	if not path or path == "" then
		return false
	end
	local abs = M.absolute_path(normalize_path(root), path)
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

local function right_matches(tokens)
	local matches, col = {}, 0
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
		display_right = (#tokens > 0) and table.concat(tokens, " ") or "",
		right_matches = right_matches(tokens),
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
	local files, ignored, seen = {}, {}, {}
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
	state.files, state.ignored = files, ignored
	return state.files, state.ignored
end

local function build_tree_items(paths, ignored, expanded, opts)
	local root = { dirs = {}, files = {}, statuses = {} }
	local git_status, open_map = opts.git_status or {}, opts.open_map or {}
	local prefix = (opts.scope_prefix and opts.scope_prefix ~= "") and (opts.scope_prefix .. "/") or nil
	for _, path in ipairs(paths or {}) do
		local is_dir = path:sub(-1) == "/"
		local clean_path = is_dir and path:sub(1, -2) or path
		local display_path = prefix and clean_path:sub(1, #prefix) == prefix and clean_path:sub(#prefix + 1) or clean_path
		local parts = vim.split(display_path, "/", { plain = true, trimempty = true })
		local node, dir = root, nil
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
		local display_path = prefix and path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or path
		local parts = vim.split(display_path, "/", { plain = true, trimempty = true })
		local node, dir = root, nil
		for i = 1, math.max(#parts - 1, 0) do
			dir = dir and (dir .. "/" .. parts[i]) or parts[i]
			local child = ensure_dir(node, parts[i], dir, ignored[dir] == true or ignored[dir .. "/"] == true)
			child.statuses = add_status_set(child.statuses, code)
			node = child
		end
	end
	local function mark_ignored(node)
		local has_visible, forced_ignored = false, node.ignored == true
		node.statuses = node.statuses or {}
		for _, child in pairs(node.dirs) do
			if not mark_ignored(child) then
				has_visible = true
			end
			for token in pairs(child.statuses or {}) do
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
		local dir_names, file_names = vim.tbl_keys(node.dirs), vim.tbl_keys(node.files)
		table.sort(dir_names, sort_names)
		table.sort(file_names, sort_names)
		for _, name in ipairs(dir_names) do
			local child = node.dirs[name]
			items[#items + 1] = item("folder", child.path, child.name, depth, child.ignored, opts, vim.tbl_extend("force", {
				expanded = expanded[child.path] == true,
			}, display_meta(ordered_statuses(child.statuses, child.ignored))))
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
	if opts.scope_prefix and opts.scope_prefix ~= "" then
		table.insert(items, 1, parent_item(opts.state))
	end
	return items
end

local function build_search_items(state, paths, ignored)
	local groups, order = {}, {}
	local git_status, open_map = state.git_status or {}, opened_set(state)
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
			items[#items + 1] = item("folder", dir, dir_label, 0, false, state.opts, { expanded = true, search_group = true })
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
	state.files = nil
	state.ignored = nil
	state.git_status = nil
	state.opened = M.collect_opened_files()
end

function M.items(state, query, panel_name)
	if state.scope and state.scope.kind == "file" then
		return {}
	end
	local paths, ignored = panel_paths(state, panel_name)
	paths, ignored, state.git_status = apply_scope(state, paths, ignored, state.git_status or {})
	local open_map = opened_set(state)
	if not query or query == "" then
		if panel_name == "files_all" then
			return build_tree_items(paths, ignored, state.expanded or {}, vim.tbl_extend("force", {}, state.opts, {
				git_status = state.git_status or {},
				open_map = open_map,
				scope_prefix = folder_scope_prefix(state),
				state = state,
			}))
		end
		local items = {}
		for _, path in ipairs(paths) do
			items[#items + 1] = file_item(state.opts, path, scoped_display_path(state, path), 0, ignored[path] == true, open_map[path] == true or open_map[normalize_path(path)] == true, (state.git_status or {})[path])
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

function M.total_count(state, panel_name)
	if state.scope and state.scope.kind == "file" then
		return 0
	end
	local paths = panel_paths(state, panel_name)
	paths = apply_scope(state, paths, {}, state.git_status or {})
	return #paths
end

return M
