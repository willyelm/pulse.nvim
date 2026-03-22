local M = {}
local scope = require("pulse.scope")
local git_context = require("pulse.navigators.git.context")
local history = require("pulse.navigators.git.history")
local status = require("pulse.navigators.git.status")

M.mode = {
	name = "git",
	icon = "󰊢",
}
M.panels = {
	{ start = "~", name = "git_status", label = "Status", scopes = { "workspace", "folder" } },
	{ start = "~", name = "git_project_history", label = "History", scopes = { "workspace", "folder" } },
	{ start = "~", name = "git_file_history", label = "File History", scopes = { "buffer" } },
}

M.context = function(item)
	return item and (item.kind == "git_commit" or item.code == "??" or item.added + item.removed > 0)
end
M.scope_aware = true
M.context_item = git_context.context_item

M.on_tab = false


function M.init(ctx)
	pcall(vim.api.nvim_set_hl, 0, "PulseAdd", { link = "Added", default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseDelete", { link = "Removed", default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseChange", { link = "Changed", default = true })
	local scoped = ctx and ctx.scope
	return {
		files = {},
		all_files = {},
		history_files = {},
		history_all = {},
		expanded = {},
		history_key = nil,
		status_all = {},
		status_key = nil,
		scope = (scoped and scoped.kind == "folder" and scope.folder(scoped.path)) or nil,
		scope_prefix = (scoped and scoped.kind == "folder" and (vim.fn.fnamemodify(scoped.path, ":.") .. "/")) or nil,
	}
end

function M.input_scope(state)
	return state and state.scope or nil
end

function M.items(state, query, panel_name)
	panel_name = panel_name or "git_status"
	state.active_panel = panel_name
	if panel_name == "git_project_history" or panel_name == "git_file_history" then
		return history.items(state, query, panel_name)
	end
	return status.items(state, query)
end

function M.on_submit(ctx)
	local item = ctx and ctx.item
	local panel_name = ctx and ctx.state and ctx.state.active_panel
	if panel_name == "git_project_history" and item and item.kind == "git_commit" then
		ctx.state.expanded[item.commit] = not ctx.state.expanded[item.commit]
		ctx.refresh()
		return
	end
	if item and item.kind == "git_commit_file" then
		ctx.jump(item)
		ctx.close()
		return
	end
	if item and item.kind == "git_commit" then
		return
	end
	if item then
		ctx.jump(item)
		ctx.close()
	end
end

function M.total_count(state)
	return #(state.all_files or {})
end

return M
