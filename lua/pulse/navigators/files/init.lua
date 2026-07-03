local M = {}
local actions = require("pulse.navigators.files.actions")
local items = require("pulse.navigators.files.items")
local sync = require("pulse.sync")
local uv = vim.uv or vim.loop

local WATCHERS = {}
local toggle_folder

local DEFAULT_OPTS = {
	icons = false,
	icon_color = false,
	compact_dirs = false,
	open_on_directory = false,
	filters = {},
	git = {
		enable = false,
		ignore = true,
	},
}

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

local function has_subscribers(watcher)
	for _ in pairs(watcher.subscribers) do
		return true
	end
	return false
end

local function prune_watchers()
	for root, watcher in pairs(WATCHERS) do
		if not has_subscribers(watcher) then
			close_watcher(root, watcher)
		end
	end
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

local function file_actions(ctx)
	return actions.mode_actions(ctx, toggle_folder)
end

M.name = "files"
M.icon = "󰈔"
M.actions = file_actions

M.view = false
M.panels = {
	{ start = "", name = "files_all", label = "Files", contexts = { "workspace", "folder" } },
	{ start = "", name = "buffers", label = "Buffers", contexts = { "workspace" } },
}

function M.init(ctx)
	local project_root = type(ctx) == "string" and ctx or (ctx and ctx.cwd) or vim.fn.getcwd()
		local state = {
			root = project_root,
			opts = items.navigator_opts(DEFAULT_OPTS, ctx and ctx.opts),
			opened = items.collect_opened_files(),
			ignored = nil,
			git_status = nil,
		expanded = {},
		context = ctx and ctx.context or nil,
		_on_update = ctx and ctx.on_update or nil,
		_dirty = false,
		_opened_dirty = true,
	}
	local open_group = vim.api.nvim_create_augroup("PulseFilesOpened" .. tostring(state.root), { clear = false })
	vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufEnter", "BufWipeout" }, {
		group = open_group,
		callback = function()
			state._opened_dirty = true
		end,
	})
	sync.register(state, {
		group = "PulseFilesSync",
		events = { "FocusGained", "BufWritePost", "ShellCmdPost", "DirChanged", "BufAdd", "BufDelete", "BufEnter", "BufWipeout" },
		when = function(current)
			if current and (current._dirty or current._opened_dirty) then
				current._dirty = false
				current._opened_dirty = false
				return true
			end
			return false
		end,
		invalidate = items.invalidate,
		on_update = function()
			prune_watchers()
			if state._on_update then
				state._on_update()
			end
		end,
	})
	ensure_watcher(project_root).subscribers[state] = true
	return state
end

function M.items(state, query, panel_name)
	return items.items(state, query, panel_name)
end

function M.input_context(_, scoped)
	return scoped
end

toggle_folder = function(ctx)
	local item = ctx and ctx.item
	if not (ctx and ctx.state and item and item.kind == "folder" and item.path) then
		return false
	end
	if item.scope_parent then
		local parent = items.parent_scope(ctx.state)
		if parent then
			ctx.set_context(parent)
		else
			ctx.clear_context()
		end
		return true
	end
	local expanding = not ctx.state.expanded[item.path]
	ctx.state.expanded[item.path] = expanding
	ctx.refresh()
	return true
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
