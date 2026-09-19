local M = {}
local context = require("pulse.context")
local sync = require("pulse.sync")
local git_view = require("pulse.navigators.git.view")
local items = require("pulse.navigators.git.items")
local git = require("pulse.navigators.git.cmd")
local util = require("pulse.navigators.git.util")
local notify = require("pulse.navigators.util").notify

local is_staged = util.is_staged

local STATUS_KIND = { A = "new file", M = "modified", D = "deleted", R = "renamed", C = "copied" }

-- Mirrors a real `git commit` template (blank subject + staged file comments).
local function commit_template(state)
	local branch = (git.lines({ "git", "rev-parse", "--abbrev-ref", "HEAD" }) or {})[1] or "HEAD"
	local lines = {
		"",
		"# Please enter the commit message for your changes. Lines starting",
		"# with '#' will be ignored, and an empty message aborts the commit.",
		"#",
		"# On branch " .. branch,
		"# Changes to be committed:",
	}
	for _, item in ipairs(state.status_all or {}) do
		if is_staged(item) then
			lines[#lines + 1] = string.format("#\t%s:   %s", STATUS_KIND[item.raw_code:sub(1, 1)] or "changed", item.path)
		end
	end
	lines[#lines + 1] = "#"
	return lines
end

-- Matches git's default commit.cleanup=strip.
local function strip_commit_message(text)
	local out = {}
	for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
		if not line:match("^#") then
			out[#out + 1] = (line:gsub("%s+$", ""))
		end
	end
	while out[1] == "" do
		table.remove(out, 1)
	end
	while out[#out] == "" do
		table.remove(out)
	end
	return table.concat(out, "\n")
end

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
			local out, ok = git.system({ "git", "restore", "--staged", "--worktree", "--", item.path })
			if not ok then
				notify("restore failed: " .. vim.trim(out or ""), vim.log.levels.ERROR)
			end
			items.invalidate_status(ctx.state)
			ctx.refresh()
		end,
	},
	{
		key = "<Tab>",
		name = function(ctx)
			local item = ctx and ctx.item
			if not (item and item.kind == "git_status") then
				return nil
			end
			return is_staged(item) and "unstage" or "stage"
		end,
		when = function(ctx)
			local item = ctx and ctx.item
			return ctx and ctx.panel and ctx.panel.name == "git_status" and item and item.kind == "git_status"
		end,
		run = function(ctx)
			local item = ctx and ctx.item
			if not item then
				return
			end
			local args = is_staged(item) and { "git", "restore", "--staged", "--", item.path }
				or { "git", "add", "--", item.path }
			if not git.lines(args) then
				notify((is_staged(item) and "unstage" or "stage") .. " failed", vim.log.levels.ERROR)
			end
			items.invalidate_status(ctx.state)
			ctx.refresh()
		end,
	},
	{
		key = "<C-c>",
		name = "commit",
		when = function(ctx)
			return ctx and ctx.panel and ctx.panel.name == "git_status"
		end,
		run = function(ctx)
			require("pulse.pulse").prompt({
				title = "commit",
				action_label = "commit",
				value = commit_template(ctx.state),
				comment_prefix = "#",
				on_submit = function(text)
					local message = strip_commit_message(text)
					if message == "" then
						notify("empty commit message, aborting", vim.log.levels.WARN)
						return
					end
					local out, ok = git.system({ "git", "commit", "-F", "-" }, message)
					if not ok then
						notify("commit failed: " .. vim.trim(out or ""), vim.log.levels.ERROR)
						return
					end
					items.invalidate_status(ctx.state)
					ctx.refresh()
				end,
			})
			return false
		end,
	},
}

M.panels = {
	{ start = "~", name = "git_status", label = "Git", contexts = { "workspace", "folder" } },
	{ start = "~", name = "git_project_history", label = "History", contexts = { "workspace", "folder" } },
	{ start = "~", name = "git_file_history", label = "History", contexts = { "buffer" } },
}

M.view = function(item)
	return item and (item.kind == "git_commit" or item.code == "??" or ((item.added or 0) + (item.removed or 0) > 0))
end
M.view_item = git_view.view_item

function M.init(ctx)
	local scoped = ctx and ctx.context
	-- Root-relative like git's own paths; nil for the repo root itself or a folder outside the repo.
	local scope_dir = scoped and scoped.kind == "folder" and git.relative(scoped.path) or nil
	local state = {
		history_files = {},
		history_all = {},
		expanded = {},
		history_key = nil,
		status_all = {},
		status_key = nil,
		context = (scoped and scoped.kind == "folder" and context.folder(scoped.path)) or nil,
		scope_prefix = scope_dir and (scope_dir .. "/") or nil,
		_on_update = ctx and ctx.on_update or nil,
	}
	-- A different directory can mean a different repo; everything else only dirties status (history is
	-- invalidated by items.watch when HEAD moves), so a save or focus change never refetches the log.
	sync.register(state, {
		group = "PulseGitDirSync",
		events = { "DirChanged" },
		invalidate = items.invalidate,
		on_update = state._on_update,
		exclusive = true,
	})
	sync.register(state, {
		group = "PulseGitSync",
		events = { "FocusGained", "ShellCmdPost", "BufWritePost" },
		invalidate = items.invalidate_status,
		on_update = state._on_update,
		exclusive = true,
	})
	if ctx and ctx.is_alive and ctx.is_active then
		items.watch(state, ctx.is_alive, ctx.is_active)
	end
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
