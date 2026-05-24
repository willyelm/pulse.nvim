local M = {}

local context = require("pulse.context")
local items = require("pulse.navigators.files.items")

local transfer

local function selected_path(ctx)
	local item = ctx and ctx.item
	if not (ctx and ctx.state and item and item.path) then
		return nil
	end
	if item.scope_parent then
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
	if ctx and ctx.state and ctx.state.context and ctx.state.context.kind == "folder" then
		return ctx.state.context.path
	end
	return ctx and ctx.state and ctx.state.root or nil
end

local function notify(message, level)
	vim.notify("Pulse: " .. message, level or vim.log.levels.WARN)
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
	if ctx then
		ctx.refresh()
	end
end

local function action_input(prompt, default, cb)
	vim.ui.input({ prompt = prompt, default = default }, cb)
	return false
end

function M.add(ctx)
	local dest_dir = target_dir(ctx)
	if not dest_dir or dest_dir == "" then
		return true
	end
	return action_input("Add: ", nil, function(value)
		value = vim.trim(value or "")
		if value == "" then
			return ctx.focus()
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
		ctx.focus()
	end)
end

function M.rename(ctx)
	local src = selected_path(ctx)
	if not src then
		return true
	end
	local current = vim.fn.fnamemodify(src, ":t")
	return action_input("Rename: ", current, function(value)
		if not value or value == "" or value == current then
			return ctx.focus()
		end
		local dest = vim.fn.fnamemodify(src, ":h") .. "/" .. value
		if path_taken(dest) then
			notify("target already exists", vim.log.levels.ERROR)
		elseif vim.fn.rename(src, dest) ~= 0 then
			notify("rename failed", vim.log.levels.ERROR)
		elseif ctx.context and ctx.context.kind == "file" and ctx.context.path == src then
			ctx.set_context(context.file(dest, vim.fn.bufnr(vim.fn.fnamemodify(dest, ":p"))))
		elseif ctx.context and ctx.context.kind == "folder" and ctx.context.path == src then
			ctx.set_context(context.folder(dest))
		end
		refresh_actions(ctx)
		ctx.focus()
	end)
end

function M.delete(ctx)
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
	if ctx.context and ctx.context.path == src then
		ctx.clear_context()
	else
		refresh_actions(ctx)
	end
	return true
end

function M.stage_transfer(ctx, kind)
	local src = selected_path(ctx)
	if not src then
		return true
	end
	transfer = { kind = kind, path = src }
	return true
end

function M.paste(ctx)
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

function M.mode_actions(ctx, toggle_folder)
	local item = ctx and ctx.item
	local editable = item and (item.kind == "file" or item.kind == "folder") and not item.scope_parent
	local actions = {
		{
			key = "<CR>",
			name = function(next)
				local next_item = next and next.item
				if not next_item then
					return nil
				end
				if next_item.scope_parent then
					return "close"
				end
				if next_item.kind == "folder" then
					return next_item.expanded and "close" or "open"
				end
				return "open"
			end,
			when = function(next)
				return next and next.item ~= nil
			end,
			run = function(next) return M.open(next, toggle_folder) end,
		},
		{
			key = "<Tab>",
			name = function(next)
				local next_item = next and next.item
				if not next_item then
					return nil
				end
				if next_item.scope_parent then
					return "close"
				end
				if next_item.kind == "folder" then
					return "view"
				end
				return "preview"
			end,
			when = function(next)
				return next and next.item ~= nil
			end,
			run = function(next)
				return M.preview(next, toggle_folder)
			end,
		},
		{ key = "<C-a>", name = "add", run = M.add },
	}
	if editable then
		actions[#actions + 1] = { key = "<C-d>", name = "delete", run = M.delete }
		actions[#actions + 1] = { key = "<C-r>", name = "rename", run = M.rename }
		actions[#actions + 1] = { key = "<C-x>", name = "cut", run = function(next) return M.stage_transfer(next, "cut") end }
		actions[#actions + 1] = { key = "<C-c>", name = "copy", run = function(next) return M.stage_transfer(next, "copy") end }
	end
	if transfer and transfer.path then
		actions[#actions + 1] = { key = "<C-v>", name = "paste", run = M.paste }
	end
	return actions
end

return M
