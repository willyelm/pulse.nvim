-- Review tab: the staged version (left) against the real file (right), whole file, in native diff mode.
-- Edit the right side as usual; `dp` a hunk into the left and `:w` it to stage just that hunk.
local git = require("pulse.navigators.git.cmd")
local util = require("pulse.navigators.git.util")
local read_blob_lines = require("pulse.navigators.git.view").read_blob_lines

local M = {}

-- One review at a time: { tab, left, right, files, idx, viewed, mapped, watcher, group, diffopt }
local R = nil

local KEYS = { "]f", "[f", "<leader>v", "<leader>s", "q" }
local STATUSCOLUMN = "%!v:lua.require'pulse.navigators.git.review'.statuscolumn()"

-- A Pulse* group when the theme defines one (same rule as the diff preview), else the standard Diff* group.
-- Resolved on use, so a colorscheme loaded after Pulse still applies.
local function colors()
	local function pick(name, fallback)
		return vim.fn.hlexists(name) == 1 and name or fallback
	end
	local add, delete = pick("PulseDiffAdd", "DiffAdd"), pick("PulseDiffDelete", "DiffDelete")
	return { add = add, delete = delete, num_add = pick("PulseDiffNAdd", add), num_delete = pick("PulseDiffNDelete", delete) }
end

local function valid_win(win)
	return win and vim.api.nvim_win_is_valid(win)
end

-- Changed files that exist on disk (a deleted file has nothing to edit), in git status order.
local function changed_files()
	local root = git.root()
	local out, ok = git.system({ "git", "status", "--porcelain=v1", "-z", "--untracked-files=all" })
	if not (ok and root) then
		return {}
	end
	local files = {}
	for _, e in ipairs(util.parse_status_z(out)) do
		if not e.raw_code:find("D") then
			files[#files + 1] = { path = e.path, abs = root .. "/" .. e.path }
		end
	end
	return files
end

local function current()
	return R and R.files[R.idx]
end

local function render_winbars()
	local f, c = current(), colors()
	if not f then
		return
	end
	local seen = 0
	for _, g in ipairs(R.files) do
		seen = seen + (R.viewed[g.path] and 1 or 0)
	end
	local dir = vim.fn.fnamemodify(f.path, ":h")
	if valid_win(R.left) then
		vim.wo[R.left].winbar = "%#" .. c.num_delete .. "# STAGED %*  %#Comment#dp then :w stages a hunk"
	end
	if valid_win(R.right) then
		vim.wo[R.right].winbar = table.concat({
			"%#" .. c.num_add .. "# WORKING %*  ",
			R.viewed[f.path] and ("%#" .. c.num_add .. "#✓ ") or "",
			"%#Title#" .. vim.fn.fnamemodify(f.path, ":t"),
			dir ~= "." and ("  %#Comment#" .. dir) or "",
			string.format("%%=%%#Comment#file %d/%d · %d viewed ", R.idx, #R.files, seen),
		})
	end
end

-- Line numbers take their row's add/delete color, like the preview's numbered diff.
function M.statuscolumn()
	if vim.v.virtnum ~= 0 then
		return ""
	end
	local group = "LineNr"
	if vim.fn.diff_hlID(vim.v.lnum, 1) > 0 then
		local c = colors()
		group = (R and vim.g.statusline_winid == R.left) and c.num_delete or c.num_add
	end
	return string.format("%%#%s#%4d ", group, vim.v.lnum)
end

-- The ╱ filler rows: NonText blended most of the way into the background. A theme can override the group.
local function define_filler()
	local function get(name)
		return vim.api.nvim_get_hl(0, { name = name, link = false })
	end
	local fg = get("NonText").fg
	-- Transparent themes have no Normal bg; blend toward Neovim's default one instead (as Pulse's panels do).
	local bg = get("Normal").bg
		or vim.api.nvim_get_color_by_name(vim.o.background == "dark" and "NvimDarkGrey2" or "NvimLightGrey2")
	local spec = { link = "NonText", default = true }
	if fg and bg then
		local out = 0
		for shift = 16, 0, -8 do
			local f, b = math.floor(fg / 2 ^ shift) % 256, math.floor(bg / 2 ^ shift) % 256
			out = out * 256 + math.floor(b + (f - b) * 0.4 + 0.5)
		end
		spec = { fg = out, default = true }
	end
	vim.api.nvim_set_hl(0, "PulseReviewFiller", spec)
end

local function style(win, left)
	local c = colors()
	local line = left and c.delete or c.add
	local wo = vim.wo[win]
	wo.foldenable = false -- whole file; `zi` folds the unchanged parts back
	wo.fillchars = "diff:╱,eob: "
	wo.foldcolumn = "0"
	wo.signcolumn = "no"
	wo.number = true
	wo.relativenumber = false
	wo.wrap = false
	wo.cursorline = true
	wo.statuscolumn = STATUSCOLUMN
	-- Changed characters keep the theme's DiffText; filler rows stay quiet.
	wo.winhighlight = "DiffAdd:" .. line .. ",DiffChange:" .. line .. ",DiffDelete:PulseReviewFiller"
end

-- Writing the staged buffer puts exactly its text in the index, so `dp` + `:w` stages one hunk.
local function write_index(buf, f)
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
	local sha, ok = git.system({ "git", "hash-object", "-w", "--stdin" }, text)
	local err = sha
	if ok then
		err, ok = git.system({ "git", "update-index", "--add", "--cacheinfo", f.mode .. "," .. vim.trim(sha) .. "," .. f.path })
	end
	if not ok then
		return vim.notify("Stage failed: " .. tostring(err), vim.log.levels.ERROR)
	end
	vim.bo[buf].modified = false
	render_winbars()
end

local function staged_buffer(f)
	local entry = (git.lines({ "git", "ls-files", "-s", "--", f.path }) or {})[1]
	f.mode = entry and entry:match("^(%d+)") or (vim.fn.executable(f.abs) == 1 and "100755" or "100644")
	local lines, editable = {}, true
	if entry then
		lines, editable = read_blob_lines("", f.path) -- "" + ":" + path = the index version
	end
	local name = "pulse-staged://" .. f.path
	local old = vim.fn.bufnr(name)
	if old ~= -1 then
		-- Still on screen until replaced (bufhidden=wipe then drops it); just free the name.
		vim.api.nvim_buf_set_name(old, name .. "#" .. old)
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, name)
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = vim.filetype.match({ filename = f.path }) or ""
	vim.bo[buf].modified = false
	vim.bo[buf].modifiable = editable
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			write_index(buf, f)
		end,
	})
	return buf
end

-- Edits written to disk by anything else (an AI agent) show up live and un-view the file. Re-armed after
-- every event: tools that save by renaming a temp file over it would otherwise end the watch.
local function watch(f, buf)
	if R.watcher then
		R.watcher:stop()
	else
		R.watcher = vim.uv.new_fs_event()
	end
	R.watcher:start(f.abs, {}, vim.schedule_wrap(function()
		if current() ~= f then
			return
		end
		vim.cmd("checktime " .. buf)
		if R.viewed[f.path] and not vim.bo[buf].modified then
			R.viewed[f.path] = nil
			render_winbars()
		end
		watch(f, buf)
	end))
end

local show

local function map_keys(buf)
	if R.mapped[buf] then
		return
	end
	R.mapped[buf] = true
	local actions = {
		["]f"] = function()
			M.refresh()
			show(R.idx + 1)
		end,
		["[f"] = function()
			M.refresh()
			show(R.idx - 1)
		end,
		["<leader>v"] = function()
			local f = current()
			R.viewed[f.path] = not R.viewed[f.path] or nil
			if R.viewed[f.path] then
				for step = 1, #R.files do
					local j = (R.idx - 1 + step) % #R.files + 1
					if not R.viewed[R.files[j].path] then
						return show(j)
					end
				end
			end
			render_winbars()
		end,
		["<leader>s"] = function()
			local f = current()
			vim.api.nvim_win_call(R.right, function()
				vim.cmd("silent! update")
			end)
			local err, ok = git.system({ "git", "add", "--", f.path })
			if not ok then
				return vim.notify(err, vim.log.levels.ERROR)
			end
			R.viewed[f.path] = true
			show(R.idx)
		end,
		q = M.close,
	}
	for _, lhs in ipairs(KEYS) do
		vim.keymap.set("n", lhs, actions[lhs], { buffer = buf, nowait = true, desc = "Pulse review" })
	end
end

show = function(i)
	if #R.files == 0 then
		return
	end
	R.idx = math.max(1, math.min(i, #R.files))
	local f = current()
	vim.cmd("diffoff!")

	vim.api.nvim_set_current_win(R.right)
	vim.cmd("edit " .. vim.fn.fnameescape(f.abs))
	local work = vim.api.nvim_get_current_buf()
	vim.bo[work].autoread = true
	local staged = staged_buffer(f)
	vim.api.nvim_win_set_buf(R.left, staged)

	for _, win in ipairs({ R.left, R.right }) do
		vim.api.nvim_win_call(win, function()
			vim.cmd("diffthis")
		end)
		style(win, win == R.left)
	end
	map_keys(work)
	map_keys(staged)
	watch(f, work)
	render_winbars()
	pcall(vim.cmd, "normal! gg]c")
end

-- Re-read the changed files (an agent may have added some), keeping the current file selected.
function M.refresh()
	local f = current()
	R.files = changed_files()
	R.idx = 1
	for i, g in ipairs(R.files) do
		if f and g.path == f.path then
			R.idx = i
		end
	end
end

local function teardown()
	local r = R
	R = nil
	if not r then
		return
	end
	if r.watcher then
		r.watcher:stop()
		r.watcher:close()
	end
	pcall(vim.api.nvim_del_augroup_by_id, r.group)
	vim.o.diffopt = r.diffopt
	-- The working buffers are the user's own; leave them as they were before the review.
	for buf in pairs(r.mapped) do
		if vim.api.nvim_buf_is_valid(buf) then
			for _, lhs in ipairs(KEYS) do
				pcall(vim.keymap.del, "n", lhs, { buffer = buf })
			end
		end
	end
	return r
end

function M.close()
	local r = teardown()
	if not (r and vim.api.nvim_tabpage_is_valid(r.tab)) then
		return
	end
	if #vim.api.nvim_list_tabpages() > 1 then
		vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(r.tab))
	else
		vim.cmd("diffoff!")
		if valid_win(r.left) then
			vim.api.nvim_win_close(r.left, true)
		end
	end
end

-- `:Pulse git_review`: review the current buffer's file, or every change when it has none.
function M.open_current()
	local name = vim.api.nvim_buf_get_name(0)
	local path = name ~= "" and git.relative(name) or nil
	return M.open(path and { path = path } or nil)
end

-- Opens the review on `item` (a git status row), or on the first changed file.
function M.open(item)
	M.close()
	local files = changed_files()
	if #files == 0 then
		vim.notify("No changes to review")
		return false
	end
	local idx = 1
	for i, f in ipairs(files) do
		if item and f.path == item.path then
			idx = i
		end
	end

	local diffopt = vim.o.diffopt
	for _, opt in ipairs({ "algorithm:histogram", "indent-heuristic", "linematch:60", "inline:char" }) do
		pcall(function()
			vim.opt.diffopt:append(opt)
		end)
	end

	define_filler()
	vim.cmd("tabnew")
	local right = vim.api.nvim_get_current_win()
	vim.cmd("leftabove vsplit")
	R = {
		tab = vim.api.nvim_get_current_tabpage(),
		left = vim.api.nvim_get_current_win(),
		right = right,
		files = files,
		idx = idx,
		viewed = {},
		mapped = {},
		diffopt = diffopt,
		group = vim.api.nvim_create_augroup("PulseGitReview", { clear = true }),
	}
	-- Closing either pane or the tab by hand ends the review the same way `q` does.
	vim.api.nvim_create_autocmd("WinClosed", {
		group = R.group,
		pattern = { tostring(R.left), tostring(R.right) },
		callback = vim.schedule_wrap(M.close),
	})
	vim.api.nvim_create_autocmd("TabClosed", {
		group = R.group,
		callback = function()
			if R and not vim.api.nvim_tabpage_is_valid(R.tab) then
				teardown()
			end
		end,
	})

	show(idx)
	return true
end

return M
