local M = {}
local context = require("pulse.context")
local sync = require("pulse.sync")
local git_view = require("pulse.navigators.git.view")
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
				return (ctx.state and ctx.state.expanded and ctx.state.expanded[item.commit]) and "hide files"
					or "show files"
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
	{
		key = "<C-r>",
		name = "restore",
		when = function(ctx)
			local item = ctx and ctx.item
			return ctx and ctx.panel and ctx.panel.name == "git_status" and item and item.code ~= "??"
		end,
		run = function(ctx)
			local item = ctx and ctx.item
			if not item then
				return
			end
			local confirm = vim.fn.confirm("Restore " .. item.path .. "?", "&Yes\n&No", 2)
			if confirm ~= 1 then
				return
			end
			vim.fn.system({ "git", "restore", "--staged", "--worktree", "--", item.path })
			items.invalidate_status(ctx.state)
			ctx.refresh()
		end,
	},
}

M.panels = {
	{ start = "~", name = "git_status", label = "Git Status", contexts = { "workspace", "folder" } },
	{ start = "~", name = "git_project_history", label = "History", contexts = { "workspace", "folder" } },
	{ start = "~", name = "git_file_history", label = "History", contexts = { "buffer" } },
}

M.view = function(item)
	return item and (item.kind == "git_commit" or item.code == "??" or ((item.added or 0) + (item.removed or 0) > 0))
end
M.view_item = git_view.view_item

function M.init(ctx)
	local scoped = ctx and ctx.context
	local state = {
		history_files = {},
		history_all = {},
		expanded = {},
		history_key = nil,
		status_all = {},
		status_key = nil,
		context = (scoped and scoped.kind == "folder" and context.folder(scoped.path)) or nil,
		scope_prefix = (scoped and scoped.kind == "folder" and (vim.fn.fnamemodify(scoped.path, ":.") .. "/")) or nil,
		_on_update = ctx and ctx.on_update or nil,
	}
	sync.register(state, {
		group = "PulseGitFocusSync",
		events = { "FocusGained" },
		invalidate = items.invalidate,
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

function M.input_context(state)
	return state and state.context or nil
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
