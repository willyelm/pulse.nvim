local M = {}
local scope = require("pulse.scope")
local items = require("pulse.navigators.files.items")
local uv = vim.uv or vim.loop

local transfer
local WATCHERS = {}
local WATCHER_GROUP

local DEFAULT_OPTS = {
	icons = false,
	icon_color = false,
	open_on_directory = false,
	filters = {},
	git = {
		enable = false,
		ignore = true,
	},
}

local function setup_highlights()
	pcall(vim.api.nvim_set_hl, 0, "PulseAdd", { link = "Added", default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseDelete", { link = "Removed", default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseChange", { link = "Changed", default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseOpenFile", { bold = true, default = true })
end

local function schedule_state_refresh(state)
	if not state or state._refresh_pending then
		return
	end
	state._refresh_pending = true
	vim.schedule(function()
		state._refresh_pending = false
		items.invalidate(state)
		if state._on_update then
			state._on_update()
		end
	end)
end

local function mark_dirty(state)
	if state then
		state._dirty = true
	end
end

local function close_watcher(root, watcher)
	for _, handle in ipairs(watcher.handles or {}) do
		pcall(handle.stop, handle)
		pcall(handle.close, handle)
	end
	WATCHERS[root] = nil
end

local function subscribe_events()
	if WATCHER_GROUP then
		return
	end
	WATCHER_GROUP = vim.api.nvim_create_augroup("PulseFilesSync", { clear = true })
	vim.api.nvim_create_autocmd({ "FocusGained", "BufWritePost", "ShellCmdPost", "DirChanged", "CursorHold", "CursorHoldI" }, {
		group = WATCHER_GROUP,
		callback = function()
			for root, watcher in pairs(WATCHERS) do
				local has_subscribers = false
				for subscribed in pairs(watcher.subscribers) do
					has_subscribers = true
					if subscribed._dirty then
						subscribed._dirty = false
						schedule_state_refresh(subscribed)
					end
				end
				if not has_subscribers then
					close_watcher(root, watcher)
				end
			end
		end,
	})
end

local function ensure_watcher(root)
	root = vim.fn.fnamemodify(root, ":p")
	local watcher = WATCHERS[root]
	if watcher then
		return watcher
	end

	watcher = {
		subscribers = setmetatable({}, { __mode = "k" }),
		handles = {},
	}
	WATCHERS[root] = watcher

	local function notify_all()
		for state in pairs(watcher.subscribers) do
			mark_dirty(state)
		end
	end

	local function start_watch(path)
		if not path or path == "" or vim.fn.isdirectory(path) ~= 1 then
			return
		end
		local handle = uv.new_fs_event()
		if not handle then
			return
		end
		local ok = pcall(handle.start, handle, path, {
			recursive = vim.fn.has("macunix") == 1 or vim.fn.has("win32") == 1,
		}, vim.schedule_wrap(function()
			notify_all()
		end))
		if ok then
			watcher.handles[#watcher.handles + 1] = handle
		else
			pcall(handle.stop, handle)
			pcall(handle.close, handle)
		end
	end

	start_watch(root)
	start_watch(root .. "/.git")
	return watcher
end

local function selected_path(ctx)
	local item = ctx and ctx.item
	if not (ctx and ctx.state and item and item.path) then
		return nil
	end
	if item.scope_parent or item.search_group then
		return nil
	end
	return items.absolute_path(ctx.state.root, item.path)
end

local function target_dir(ctx)
	local path = selected_path(ctx)
	if path and ctx.item and ctx.item.kind == "folder" then
		return path
	end
	if path and ctx.item and ctx.item.kind == "file" then
		return vim.fn.fnamemodify(path, ":h")
	end
	if ctx and ctx.state and ctx.state.scope and ctx.state.scope.kind == "folder" then
		return ctx.state.scope.path
	end
	return ctx and ctx.state and ctx.state.root or nil
end

local function notify(message, level)
	vim.notify("Pulse: " .. message, level or vim.log.levels.WARN)
end

local function dispatch(ctx, effects)
	if ctx and ctx.dispatch then
		ctx.dispatch(effects)
	end
end

local function ensure_parent(path)
	local parent = vim.fn.fnamemodify(path, ":h")
	if parent ~= "" then
		vim.fn.mkdir(parent, "p")
	end
end

local function path_taken(path)
	return vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1
end

local function refresh_actions(ctx)
	items.invalidate(ctx and ctx.state)
	dispatch(ctx, { type = "refresh" })
end

local function action_input(prompt, default, cb)
	vim.ui.input({ prompt = prompt, default = default }, cb)
	return false
end

local function action_add(ctx)
	local dest_dir = target_dir(ctx)
	if not dest_dir or dest_dir == "" then
		return true
	end
	return action_input("Add: ", nil, function(value)
		value = vim.trim(value or "")
		if value == "" then
			return dispatch(ctx, { type = "focus_input" })
		end
		local dest = dest_dir .. "/" .. value
		local ok
		if value:sub(-1) == "/" then
			vim.fn.mkdir(dest, "p")
			ok = vim.fn.isdirectory(dest) == 1
		else
			ensure_parent(dest)
			ok = not path_taken(dest) and vim.fn.writefile({}, dest) == 0
		end
		if not ok then
			notify("create failed or target already exists", vim.log.levels.ERROR)
		end
		refresh_actions(ctx)
		dispatch(ctx, { type = "focus_input" })
	end)
end

local function action_rename(ctx)
	local src = selected_path(ctx)
	if not src then
		return true
	end
	local current = vim.fn.fnamemodify(src, ":t")
	return action_input("Rename: ", current, function(value)
		if not value or value == "" or value == current then
			return dispatch(ctx, { type = "focus_input" })
		end
		local dest = vim.fn.fnamemodify(src, ":h") .. "/" .. value
		if path_taken(dest) then
			notify("target already exists", vim.log.levels.ERROR)
		elseif vim.fn.rename(src, dest) ~= 0 then
			notify("rename failed", vim.log.levels.ERROR)
		elseif ctx.scope and ctx.scope.kind == "file" and ctx.scope.path == src then
			dispatch(ctx, { type = "set_scope", scope = scope.file(dest, vim.fn.bufnr(vim.fn.fnamemodify(dest, ":p"))) })
		elseif ctx.scope and ctx.scope.kind == "folder" and ctx.scope.path == src then
			dispatch(ctx, { type = "set_scope", scope = scope.folder(dest) })
		end
		refresh_actions(ctx)
		dispatch(ctx, { type = "focus_input" })
	end)
end

local function action_delete(ctx)
	local src = selected_path(ctx)
	if not src then
		return true
	end
	if vim.fn.confirm("Delete " .. vim.fn.fnamemodify(src, ":t") .. "?", "&Yes\n&No", 2) ~= 1 then
		return true
	end
	if vim.fn.delete(src, "rf") ~= 0 then
		notify("delete failed", vim.log.levels.ERROR)
		return true
	end
	if ctx.scope and ctx.scope.path == src then
		dispatch(ctx, { type = "clear_scope" })
	else
		refresh_actions(ctx)
	end
	return true
end

local function action_stage_transfer(ctx, kind)
	local src = selected_path(ctx)
	if not src then
		return true
	end
	transfer = { kind = kind, path = src }
	return true
end

local function action_paste(ctx)
	if not (transfer and transfer.path and transfer.kind) then
		return true
	end
	local dest_dir = target_dir(ctx)
	if not dest_dir or dest_dir == "" then
		return true
	end
	local dest = dest_dir .. "/" .. vim.fn.fnamemodify(transfer.path, ":t")
	if dest == transfer.path or path_taken(dest) then
		if dest ~= transfer.path then
			notify("target already exists", vim.log.levels.ERROR)
		end
		return true
	end
	ensure_parent(dest)
	local ok
	if transfer.kind == "cut" then
		ok = vim.fn.rename(transfer.path, dest) == 0
	else
		local cmd = (vim.fn.isdirectory(transfer.path) == 1) and { "cp", "-R", transfer.path, dest }
			or { "cp", transfer.path, dest }
		vim.fn.system(cmd)
		ok = vim.v.shell_error == 0
	end
	if not ok then
		notify("paste failed", vim.log.levels.ERROR)
		return true
	end
	if transfer.kind == "cut" then
		transfer = nil
	end
	refresh_actions(ctx)
	return true
end

local function file_actions(ctx)
	local item = ctx and ctx.item
	local editable = item and (item.kind == "file" or item.kind == "folder") and not item.scope_parent and not item.search_group
	local actions = {
		["<C-a>"] = action_add,
	}
	if editable then
		actions["<C-d>"] = action_delete
		actions["<C-r>"] = action_rename
		actions["<C-x>"] = function(next)
			return action_stage_transfer(next, "cut")
		end
		actions["<C-c>"] = function(next)
			return action_stage_transfer(next, "copy")
		end
	end
	if transfer and transfer.path then
		actions["<C-v>"] = action_paste
	end
	return actions
end

M.mode = {
	name = "files",
	icon = "󰈔",
	actions = file_actions,
}

M.context = false
M.panels = {
	{ start = "", name = "files_all", label = "Files", scopes = { "workspace", "folder" } },
	{ start = "", name = "files_open", label = "Open", scopes = { "workspace" } },
}

function M.init(ctx)
	setup_highlights()
	local project_root = type(ctx) == "string" and ctx or (ctx and ctx.cwd) or vim.fn.getcwd()
	local state = {
		root = project_root,
		opts = items.navigator_opts(DEFAULT_OPTS, ctx and ctx.opts),
		opened = items.collect_opened_files(),
		files = nil,
		ignored = nil,
		git_status = nil,
		expanded = {},
		scope = ctx and ctx.scope or nil,
		_on_update = ctx and ctx.on_update or nil,
		_refresh_pending = false,
		_dirty = false,
	}
	subscribe_events()
	ensure_watcher(project_root).subscribers[state] = true
	return state
end

function M.items(state, query, panel_name)
	return items.items(state, query, panel_name)
end

function M.input_scope(_, scoped)
	return scoped
end

local function toggle_folder(ctx)
	local item = ctx and ctx.item
	if not (ctx and ctx.state and item and item.kind == "folder" and item.path and not item.search_group) then
		return false
	end
	if item.scope_parent then
		local parent = items.parent_scope(ctx.state)
		if parent then
			return { { type = "set_scope", scope = parent } }
		else
			return { { type = "clear_scope" } }
		end
	end
	ctx.state.expanded[item.path] = not ctx.state.expanded[item.path]
	return { { type = "refresh" } }
end

function M.on_tab(ctx)
	if not (ctx and ctx.item) then
		return
	end
	if ctx.item.kind == "folder" then
		return { { type = "enter_scope", scope = scope.folder(items.absolute_path(ctx.state.root, ctx.item.path)) } }
	end
	local current_scope = ctx.source_scope and ctx.source_scope() or nil
	local effects = { { type = "preview", item = ctx.item } }
	if current_scope then
		effects[#effects + 1] = { type = "enter_scope", scope = current_scope }
	end
	return effects
end

function M.on_submit(ctx)
	local toggled = toggle_folder(ctx)
	if toggled then
		return toggled
	end
	if ctx.item then
		local effects = { { type = "close" }, { type = "jump", item = ctx.item } }
		local current_scope = ctx.source_scope and ctx.source_scope() or nil
		if current_scope then
			effects[#effects + 1] = { type = "set_scope", scope = current_scope }
		end
		return effects
	end
end

function M.total_count(state, panel_name)
	return items.total_count(state, panel_name)
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
