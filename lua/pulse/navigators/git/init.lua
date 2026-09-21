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

-- Edits the commit message in an ordinary buffer, like `git commit` would: `:w` commits, `:q` aborts, and an empty
-- message aborts too. `done` runs once the buffer is gone, however it went.
local function edit_commit_message(template, done)
	-- One at a time: an editor that is still open (say the panel was opened over it) is where to go back to.
	local open = vim.fn.bufnr("^COMMIT_EDITMSG$")
	if open > 0 then
		local win = vim.fn.win_findbuf(open)[1]
		if win then
			vim.api.nvim_set_current_win(win)
			return
		end
		vim.api.nvim_buf_delete(open, { force = true })
	end
	vim.cmd("botright 15new")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "gitcommit"
	vim.api.nvim_buf_set_name(buf, "COMMIT_EDITMSG")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, template)
	vim.bo[buf].modified = false
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	-- Later, so the panel's own leaving of insert mode is over first.
	vim.schedule(function()
		if vim.api.nvim_get_current_buf() == buf then
			vim.cmd("startinsert")
		end
	end)
	local function close()
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end)
	end
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			local message = strip_commit_message(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
			if message == "" then
				notify("empty commit message, aborting", vim.log.levels.WARN)
				close()
				return
			end
			local out, ok = git.system({ "git", "commit", "-F", "-" }, message)
			if not ok then
				notify("commit failed: " .. vim.trim(out or ""), vim.log.levels.ERROR)
				return
			end
			vim.bo[buf].modified = false
			close()
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function() done() end })
end

-- <C-r> is named for the git command it runs: `clean` for untracked files, `rm` for files newly added to the
-- index (git has no other way to drop them), and `restore` for everything else, deleted files included.
local function revert_kind(item)
	if item.code == "??" then
		return "clean"
	end
	if item.raw_code:sub(1, 1) == "A" then
		return "remove"
	end
	return "restore"
end

local function revert_args(item, kind)
	if kind == "clean" then
		-- Unlike rm, clean refuses anything git tracks.
		return { "git", "clean", "-f", "--", item.path }
	end
	if kind == "remove" then
		return { "git", "rm", "-f", "--", item.path }
	end
	local args = { "git", "restore", "--staged", "--worktree", "--" }
	-- A rename is restored from both ends; restoring only the new path would delete the file outright.
	if item.raw_code:sub(1, 1) == "R" and item.orig_path then
		args[#args + 1] = item.orig_path
	end
	args[#args + 1] = item.path
	return args
end

-- What <CR> does on the highlighted row: unfold a commit's files or a folder in that tree (project history
-- only), or open a changed file. Nil disables it (headers, file-history commits, loading rows).
local function enter_kind(ctx)
	local item = ctx and ctx.item
	if not item then
		return nil
	end
	if ctx.panel and ctx.panel.name == "git_project_history" then
		if item.kind == "git_commit" then
			return "commit"
		end
		if item.kind == "folder" then
			return "folder"
		end
	end
	return item.kind == "git_status" and "open" or nil
end

M.name = "git"
M.icon = "󰊢"
M.actions = {
	{
		key = "<CR>",
		name = function(ctx)
			local kind = enter_kind(ctx)
			if kind == "commit" then
				return ctx.state.expanded[ctx.item.commit] and "hide files" or "show files"
			end
			return kind and (kind == "folder" and "toggle" or "open") or nil
		end,
		when = function(ctx)
			return enter_kind(ctx) ~= nil
		end,
		run = function(ctx)
			local kind, item = enter_kind(ctx), ctx.item
			if kind == "commit" then
				ctx.state.expanded[item.commit] = not ctx.state.expanded[item.commit]
				ctx.refresh()
			elseif kind == "folder" and item.tree_key then
				ctx.state.expanded[item.tree_key] = not item.expanded
				ctx.refresh()
			else
				ctx.jump(item)
				ctx.close()
			end
		end,
	},
	{
		key = "<C-r>",
		name = function(ctx)
			local item = ctx and ctx.item
			return item and item.kind == "git_status" and revert_kind(item) or nil
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
			local kind = revert_kind(item)
			-- Restoring a purely deleted file can't lose anything, so it doesn't ask.
			if kind ~= "restore" or item.code ~= "D" then
				local verb = kind:sub(1, 1):upper() .. kind:sub(2)
				if vim.fn.confirm(verb .. " " .. item.path .. "?", "&Yes\n&No", 2) ~= 1 then
					return
				end
			end
			local out, ok = git.system(revert_args(item, kind))
			if not ok then
				notify(kind .. " failed: " .. vim.trim(out or ""), vim.log.levels.ERROR)
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
			local out, ok = git.system(args)
			if not ok then
				notify((is_staged(item) and "unstage" or "stage") .. " failed: " .. out, vim.log.levels.ERROR)
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
			local template = commit_template(ctx.state)
			ctx.suspend(function(resume)
				edit_commit_message(template, resume)
			end)
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
	-- The panel may be opened for another project than nvim's cwd (`nvim ../other`); follow it.
	git.set_dir(ctx and ctx.cwd)
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
