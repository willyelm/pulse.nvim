local M = {}
local scope = require("pulse.scope")
local sync = require("pulse.sync")
local git_context = require("pulse.navigators.git.context")
local items = require("pulse.navigators.git.items")

M.name = "git"
M.icon = "󰊢"
M.actions = {
		{
			key = "<CR>",
			name = function(ctx)
				local item = ctx and ctx.item
				local panel_name = ctx and ctx.panel and ctx.panel.name
				if not item then
					return nil
				end
				if panel_name == "git_project_history" and item.kind == "git_commit" then
					return (ctx.state and ctx.state.expanded and ctx.state.expanded[item.commit]) and "hide files" or "show files"
				end
				if panel_name == "git_project_history" and item.kind == "folder" then
					return "toggle"
				end
				if item.kind == "git_status" then
					return "open"
				end
				return nil
			end,
			when = function(ctx)
				local item = ctx and ctx.item
				local panel_name = ctx and ctx.panel and ctx.panel.name
				if not item then
					return false
				end
				if panel_name == "git_project_history" and item.kind == "git_commit" then
					return true
				end
				if panel_name == "git_project_history" and item.kind == "folder" then
					return true
				end
				if item.kind == "git_commit" then
					return false
				end
				return item.kind == "git_status"
			end,
			run = function(ctx)
				local item = ctx and ctx.item
				local panel_name = ctx and ctx.panel and ctx.panel.name
				if panel_name == "git_project_history" and item and item.kind == "git_commit" then
					ctx.state.expanded[item.commit] = not ctx.state.expanded[item.commit]
					ctx.refresh()
					return
				end
				if panel_name == "git_project_history" and item and item.kind == "folder" and item.tree_key then
					ctx.state.expanded[item.tree_key] = not item.expanded
					ctx.refresh()
					return
				end
				if item and item.kind == "git_commit" then
					return
				end
				if item then
					ctx.jump(item)
					ctx.close()
				end
			end,
		},
}

M.panels = {
	{ start = "~", name = "git_status", label = "Git Status", scopes = { "workspace", "folder" } },
	{ start = "~", name = "git_project_history", label = "History", scopes = { "workspace", "folder" } },
	{ start = "~", name = "git_file_history", label = "History", scopes = { "buffer" } },
}

M.context = function(item)
	return item and (item.kind == "git_commit" or item.code == "??" or ((item.added or 0) + (item.removed or 0) > 0))
end
M.context_item = git_context.context_item

function M.init(ctx)
	local scoped = ctx and ctx.scope
	local state = {
		history_files = {},
		history_all = {},
		expanded = {},
		history_key = nil,
		status_all = {},
		status_key = nil,
		scope = (scoped and scoped.kind == "folder" and scope.folder(scoped.path)) or nil,
		scope_prefix = (scoped and scoped.kind == "folder" and (vim.fn.fnamemodify(scoped.path, ":.") .. "/")) or nil,
		_on_update = ctx and ctx.on_update or nil,
	}
	sync.register(state, {
		group = "PulseGitFocusSync",
		events = { "FocusGained" },
		invalidate = function(current)
			local panel = current and current.current_panel
			if panel == "git_project_history" or panel == "git_file_history" then
				items.invalidate_history(current)
				return
			end
			items.invalidate_status(current)
		end,
		on_update = state._on_update,
	})
	sync.register(state, {
		group = "PulseGitSync",
		events = { "ShellCmdPost", "DirChanged", "BufWritePost" },
		invalidate = items.invalidate,
		on_update = state._on_update,
	})
	return state
end

function M.input_scope(state)
	return state and state.scope or nil
end

	function M.items(state, query, panel_name)
		state.current_panel = panel_name
		return items.items(state, query, panel_name)
	end

function M.total_count(state)
	local count = #(state.current_panel == "git_status" and (state.status_all or {}) or (state.history_all or {}))
	return {
		count = count,
		plus = state.history_has_more == false and count >= 5000,
	}
end

return M
