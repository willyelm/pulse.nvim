local M = {}

local context = require("pulse.context")
local items = require("pulse.navigators.files.items")
local clipboard = require("pulse.clipboard")
local notify = require("pulse.navigators.util").notify

-- How long a copied or cut row stays marked.
local MARK_MS = 3000

local function selected_path(ctx)
	local item = ctx and ctx.item
	if not (ctx and ctx.state and item and item.path) then
		return nil
	end
	if item.scope_parent then
		return nil
	end
	-- git reports folders as "dir/"; every caller wants the bare path
	return (items.absolute_path(ctx.state.root, item.path):gsub("(.)/+$", "%1"))
end

local function target_dir(ctx)
	local path = selected_path(ctx)
	if path and ctx.item and ctx.item.kind == "folder" then
		return path
	end
	if path and ctx.item and ctx.item.kind == "file" then
		return vim.fn.fnamemodify(path, ":h")
	end
	if ctx and ctx.state and ctx.state.context and ctx.state.context.kind == "folder" then
		return ctx.state.context.path
	end
	return ctx and ctx.state and ctx.state.root or nil
end

local function ensure_parent(path)
	local parent = vim.fn.fnamemodify(path, ":h")
	if parent ~= "" then
		vim.fn.mkdir(parent, "p")
	end
end

local function path_taken(path)
	return vim.uv.fs_lstat(path) ~= nil
end

local function refresh_actions(ctx)
	items.invalidate(ctx and ctx.state)
	if ctx then
		ctx.refresh()
	end
end

-- Asks for a path with Neovim's own input (`vim.ui.input`, file completion included); nothing happens on cancel
-- or an unchanged value. The panel takes its focus back either way.
local function ask_path(ctx, label, default, on_submit)
	vim.ui.input({ prompt = label .. ": ", default = default, completion = "file" }, function(value)
		value = vim.trim(value or "")
		if value ~= "" and value ~= default then
			on_submit(value)
		end
		ctx.focus()
	end)
	return false
end

-- Path as shown when asking: relative to the workspace root, absolute when outside it, "" for the root itself.
local function display_path(root, path)
	if not (root and root ~= "") then
		return path
	end
	if path == root then
		return ""
	end
	if path:sub(1, #root + 1) == root .. "/" then
		return path:sub(#root + 2)
	end
	return path
end

-- Prefills the target folder's workspace-relative path so the destination is visible and editable in place.
function M.add(ctx)
	local dest_dir = target_dir(ctx)
	if not dest_dir or dest_dir == "" then
		return true
	end
	local root = ctx.state and ctx.state.root
	local dir = display_path(root, dest_dir)
	local current = (dir ~= "") and (dir:gsub("/$", "") .. "/") or ""
	return ask_path(ctx, "Add (end with / for a folder)", current, function(value)
		local dest = root and items.absolute_path(root, value) or (dest_dir .. "/" .. value)
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
	end)
end

-- Prefills the workspace-relative path so editing the directory moves it too.
function M.rename(ctx)
	local src = selected_path(ctx)
	if not src then
		return true
	end
	local root = ctx.state and ctx.state.root
	return ask_path(ctx, "Rename", display_path(root, src), function(value)
		local dest = (root and items.absolute_path(root, value) or (vim.fn.fnamemodify(src, ":h") .. "/" .. value))
		dest = vim.fn.fnamemodify(dest, ":p"):gsub("/$", "")
		if path_taken(dest) then
			notify("target already exists", vim.log.levels.ERROR)
		else
			ensure_parent(dest)
			if vim.fn.rename(src, dest) ~= 0 then
				notify("rename failed", vim.log.levels.ERROR)
			elseif ctx.context and ctx.context.kind == "file" and ctx.context.path == src then
				ctx.set_context(context.file(dest, vim.fn.bufnr(vim.fn.fnamemodify(dest, ":p"))))
			elseif ctx.context and ctx.context.kind == "folder" and ctx.context.path == src then
				ctx.set_context(context.folder(dest))
			end
		end
		refresh_actions(ctx)
	end)
end

function M.delete(ctx)
	local src = selected_path(ctx)
	if not src then
		return true
	end
	local shown = display_path(ctx.state and ctx.state.root, src)
	local what = vim.fn.isdirectory(src) == 1 and (shown .. "/ and everything in it") or shown
	if vim.fn.confirm("Delete " .. what .. "?", "&Yes\n&No", 2) ~= 1 then
		return true
	end
	if vim.fn.delete(src, "rf") ~= 0 then
		notify("delete failed", vim.log.levels.ERROR)
	elseif ctx.context and ctx.context.path == src then
		ctx.clear_context()
	else
		refresh_actions(ctx)
	end
	return true
end

function M.close_buffer(ctx)
	local item = ctx and ctx.item
	if not item then
		return true
	end
	-- Buffer rows (terminals and other non-file buffers) carry their number; file rows are found by path.
	local src = selected_path(ctx)
	local bufnr = item.bufnr or (src and vim.fn.bufnr(src)) or -1
	if bufnr < 1 then
		notify("no open buffer for " .. tostring(item.label), vim.log.levels.ERROR)
		return true
	end
	if vim.bo[bufnr].modified and vim.fn.confirm("Buffer has unsaved changes. Close anyway?", "&Yes\n&No", 2) ~= 1 then
		return true
	end
	-- Move background windows off this buffer first, or delete can silently no-op.
	local alt = vim.fn.bufnr("#")
	for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
		if vim.api.nvim_win_is_valid(win) then
			local replacement = (alt > 0 and alt ~= bufnr and vim.api.nvim_buf_is_valid(alt)) and alt
				or vim.api.nvim_create_buf(true, false)
			pcall(vim.api.nvim_win_set_buf, win, replacement)
		end
	end
	if not pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) then
		notify("close failed", vim.log.levels.ERROR)
		return true
	end
	refresh_actions(ctx)
	return true
end

function M.stage_transfer(ctx, kind)
	local src = selected_path(ctx)
	if not src then
		return true
	end
	local entry = clipboard.stage(kind, src, ctx.item.path)
	vim.defer_fn(function()
		entry.marked = false
		ctx.refresh()
	end, MARK_MS)
	ctx.refresh()
	return true
end

function M.paste(ctx)
	local transfer = clipboard.get()
	if not transfer then
		return true
	end
	local src = transfer.path
	if not path_taken(src) then
		clipboard.clear()
		notify("nothing to paste: " .. vim.fn.fnamemodify(src, ":t") .. " no longer exists", vim.log.levels.ERROR)
		return true
	end
	local dest_dir = target_dir(ctx)
	if not dest_dir or dest_dir == "" then
		return true
	end
	if vim.startswith(dest_dir .. "/", src .. "/") then
		notify("cannot paste a folder into itself", vim.log.levels.ERROR)
		return true
	end
	local dest = dest_dir .. "/" .. vim.fn.fnamemodify(src, ":t")
	if path_taken(dest) then
		notify("target already exists", vim.log.levels.ERROR)
		return true
	end
	local out = vim.fn.system(transfer.kind == "cut" and { "mv", src, dest } or { "cp", "-R", src, dest })
	if vim.v.shell_error ~= 0 then
		notify("paste failed: " .. vim.trim(out), vim.log.levels.ERROR)
		return true
	end
	transfer.marked = false
	if transfer.kind == "cut" then
		clipboard.clear()
	end
	refresh_actions(ctx)
	return true
end

function M.preview(ctx, toggle_folder)
	if not (ctx and ctx.item) then
		return
	end
	if ctx.item.scope_parent then
		toggle_folder(ctx)
		return
	end
	if ctx.item.kind == "folder" then
		ctx.enter_context(context.folder(items.absolute_path(ctx.state.root, ctx.item.path)))
		return
	end
	local current_context = nil
	if ctx.item.kind == "file" and ctx.item.path then
		local path = items.absolute_path(ctx.state.root, ctx.item.path)
		local bufnr = vim.fn.bufnr(path)
		if not bufnr or bufnr < 1 then
			bufnr = vim.fn.bufadd(path)
		end
		current_context = context.file(path, bufnr)
	else
		current_context = ctx.source_context and ctx.source_context() or nil
	end
	ctx.preview(ctx.item)
	if current_context then
		ctx.enter_context(current_context)
	end
end

function M.open(ctx, toggle_folder)
	if toggle_folder(ctx) then
		return
	end
	if ctx.item then
		local next_context = nil
		if ctx.item.kind == "file" and ctx.item.path then
			local path = items.absolute_path(ctx.state.root, ctx.item.path)
			next_context = context.file(path, vim.fn.bufnr(path))
		else
			next_context = ctx.source_context and ctx.source_context() or nil
		end
		ctx.close()
		ctx.jump(ctx.item)
		if ctx.item.kind == "file" then
			ctx.set_query("")
		end
		if next_context then
			ctx.set_context(next_context)
		end
	end
end

-- <CR>/<Tab> label: a scope-parent row closes the scope; folders and files each get their own verb
-- (`folder` may be a function of the item).
local function item_label(ctx, folder, file)
	local item = ctx and ctx.item
	if not item then
		return nil
	end
	if item.scope_parent then
		return "close"
	end
	if item.kind == "folder" then
		return type(folder) == "function" and folder(item) or folder
	end
	return file
end

function M.mode_actions(ctx, toggle_folder)
	local item = ctx and ctx.item
	local editable = item and (item.kind == "file" or item.kind == "folder" or item.kind == "buffer") and not item.scope_parent
	local is_buffers = ctx and ctx.panel and ctx.panel.name == "buffers"
	local actions = {
		{
			key = "<CR>",
			name = function(next)
				return item_label(next, function(item) return item.expanded and "close" or "open" end, "open")
			end,
			when = function(next)
				return next and next.item ~= nil
			end,
			run = function(next) return M.open(next, toggle_folder) end,
		},
		{
			key = "<Tab>",
			name = function(next)
				return item_label(next, "view", "preview")
			end,
			when = function(next)
				return next and next.item ~= nil
			end,
			run = function(next)
				return M.preview(next, toggle_folder)
			end,
		},
	}
	if is_buffers then
		if editable then
			actions[#actions + 1] = { key = "<C-x>", name = "close", run = M.close_buffer }
		end
		return actions
	end
	actions[#actions + 1] = { key = "<C-a>", name = "add", run = M.add }
	if editable then
		actions[#actions + 1] = { key = "<C-d>", name = "delete", run = M.delete }
		actions[#actions + 1] = { key = "<C-r>", name = "rename", run = M.rename }
		actions[#actions + 1] = { key = "<C-x>", name = "cut", run = function(next) return M.stage_transfer(next, "cut") end }
		actions[#actions + 1] = { key = "<C-c>", name = "copy", run = function(next) return M.stage_transfer(next, "copy") end }
	end
	if clipboard.get() then
		actions[#actions + 1] = { key = "<C-v>", name = "paste", run = M.paste }
	end
	return actions
end

return M
