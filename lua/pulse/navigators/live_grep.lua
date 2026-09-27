local M = {}
local nav = require("pulse.navigators.util")
local view = require("pulse.panel_view")
local context = require("pulse.context")

M.name = "live_grep"
M.icon = "󰍉"
M.panels = {
	{ start = "$", name = "live_grep", label = "Live Grep", contexts = { "workspace", "folder" } },
	-- The same search, entered with <C-r>: the input then takes the replacement (see context.replace).
	{ start = "$", name = "live_grep_replace", label = "Replace", contexts = { "replace" } },
}

M.view = true

function M.view_item(item)
	if item.kind == "live_grep_file" then
		return M.view_item(item.first)
	end
	return view.file_snippet(item.path or item.filename, item.lnum, item.query, item.match_cols)
end

-- Pulls `-g <glob>` tokens out of the typed text (ripgrep's own --glob syntax; `-g !glob` excludes); what's
-- left is the actual search pattern. No new syntax to learn if you already know `rg`'s own flags.
local function parse_query(raw)
	local globs, rest, want_glob = {}, {}, false
	for token in (raw or ""):gmatch("%S+") do
		if want_glob then
			globs[#globs + 1] = token
			want_glob = false
		elseif token == "-g" then
			want_glob = true
		else
			rest[#rest + 1] = token
		end
	end
	return table.concat(rest, " "), globs
end

local DEBOUNCE_MS = 60
local RESULT_LIMIT = 5000
local function notify_update(state)
	if type(state.on_update) ~= "function" or state.update_scheduled then
		return
	end
	state.update_scheduled = true
	vim.schedule(function()
		state.update_scheduled = false
		state.on_update()
	end)
end

local function stop_job(state)
	if state.job and state.job > 0 then
		pcall(vim.fn.jobstop, state.job)
	end
	state.job = nil
end

local function stop_timer(state)
	if state.timer then
		state.timer:stop()
		state.timer:close()
	end
	state.timer = nil
end

local function reset_results(state)
	state.items = {}
	state.target = state.items
	state.stopped = false
end

-- rg --json fields are `{text = ...}` for valid UTF-8, or `{bytes = <base64>}` otherwise.
local function decode_field(field)
	if type(field) ~= "table" then
		return ""
	end
	if field.text then
		return field.text
	end
	if field.bytes and vim.base64 then
		local ok, decoded = pcall(vim.base64.decode, field.bytes)
		return ok and decoded or ""
	end
	return ""
end

-- Parses one rg --json line into a live_grep item; match_cols holds one {start, end} span per submatch.
local function append_line(state, raw_line, query)
	-- Skips the JSON decode for begin/end/summary events, which we never use.
	if not (raw_line and raw_line ~= "" and raw_line:find('"type":"match"', 1, true)) then
		return
	end
	local ok, event = pcall(vim.json.decode, raw_line)
	if not (ok and type(event) == "table" and event.type == "match") then
		return
	end
	local data = event.data
	local path = decode_field(data.path)
	local text = decode_field(data.lines):gsub("\n$", "")
	local match_cols, first_col = {}, nil
	-- Only present when rg ran with --replace: the text each submatch becomes, capture groups already expanded.
	local replacements = nil
	for _, submatch in ipairs(data.submatches or {}) do
		local s, e = submatch.start, submatch["end"]
		if type(s) == "number" and type(e) == "number" and e > s then
			first_col = first_col or (s + 1)
			match_cols[#match_cols + 1] = { s + 1, e }
			if submatch.replacement then
				replacements = replacements or {}
				replacements[#match_cols] = decode_field(submatch.replacement)
			end
		end
	end
	if path ~= "" and data.line_number then
		state.target[#state.target + 1] = {
			kind = "live_grep",
			path = path,
			filename = path,
			lnum = data.line_number,
			col = first_col or 1,
			text = text,
			leading = #(text:match("^%s*") or ""),
			query = query,
			match_cols = match_cols,
			replacements = replacements,
		}
	end
end

-- Parses a stdout batch in slices, yielding between them so a big result burst never blocks typing.
local CHUNK_SIZE = 200
local function append_lines_chunked(state, lines, query, token, start_idx)
	if token ~= state.token then
		return
	end
	local last = math.min(start_idx + CHUNK_SIZE - 1, #lines)
	for i = start_idx, last do
		if #state.target >= RESULT_LIMIT then
			state.stopped = true
			stop_job(state)
			notify_update(state)
			return
		end
		append_line(state, lines[i], query)
	end
	if #state.target > 0 and state.target == state.items then
		notify_update(state)
	end
	if last < #lines then
		vim.schedule(function()
			append_lines_chunked(state, lines, query, token, last + 1)
		end)
	end
end

-- `swap` keeps the current results on screen until the new run finishes (a replace-text edit reruns the same
-- search; clearing first would flash an empty list and lose the selection on every keystroke).
local function start_search(state, query, token, swap)
	stop_job(state)
	state.target = {}
	if not swap then
		state.items = state.target
	end
	state.stopped = false

	local pattern, globs = parse_query(query)
	local cmd = {
		"rg",
		"--json",
		"--hidden",
		"--glob",
		"!**/.git/*",
		"--line-buffered",
		"--smart-case",
		"--max-columns",
		"300",
	}
	if state.replacement then
		cmd[#cmd + 1] = "--replace"
		cmd[#cmd + 1] = state.replacement
	end
	for _, g in ipairs(globs) do
		cmd[#cmd + 1] = "--glob"
		cmd[#cmd + 1] = g
	end
	cmd[#cmd + 1] = pattern
	cmd[#cmd + 1] = state.cwd or "."

	state.job = vim.fn.jobstart(cmd, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			if token ~= state.token then
				return
			end
			if not data or #data == 0 then
				return
			end
			append_lines_chunked(state, data, pattern, token, 1)
		end,
		on_exit = function(_, code)
			if token ~= state.token then
				return
			end
			state.job = nil
			state.items = state.target
			-- A bad pattern shows empty results, not a notification: typing passes through invalid states constantly.
			if not (code == 0 or code == 1 or state.stopped) then
				state.items = {}
				state.target = state.items
			end
			notify_update(state)
		end,
	})

	if state.job <= 0 then
		state.job = nil
		reset_results(state)
		notify_update(state)
	end
end

-- Search-and-replace, VS Code style. <C-r> enters a replace context: the search becomes the input's label and
-- the input takes the replacement. Every change reruns rg with --replace, so each row previews exactly what it
-- becomes (capture groups like $1 included) and applying writes rg's own replacement text at rg's own byte
-- offsets -- no translation to Vim's regex dialect, which differs from rg's.

-- rg reads lines with their CR (a CRLF file); a loaded buffer shows them without it.
local function same_line(line, text)
	return line == text or line == text:gsub("\r$", "")
end

-- The line with every submatch swapped for its replacement, right to left so earlier offsets stay valid.
local function replaced_line(line, item)
	for i = #item.match_cols, 1, -1 do
		local span = item.match_cols[i]
		line = line:sub(1, span[1] - 1) .. (item.replacements[i] or "") .. line:sub(span[2] + 1)
	end
	return line
end

-- Rewrites one file's matched lines, bottom-up so a replacement adding lines never shifts the ones still to do.
-- A loaded buffer is edited in place (undo works; saved only if it had no unsaved edits of its own); any other
-- file is rewritten on disk directly, which avoids loading it -- and attaching LSP, treesitter -- just to edit it.
-- A line that changed since the search is skipped. Returns the items applied.
local function replace_in_file(path, items)
	table.sort(items, function(a, b) return a.lnum > b.lnum end)
	local applied = {}
	local bufnr = vim.fn.bufnr(path)
	if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
		local was_modified = vim.bo[bufnr].modified
		for _, item in ipairs(items) do
			local line = vim.api.nvim_buf_get_lines(bufnr, item.lnum - 1, item.lnum, false)[1]
			if line and same_line(line, item.text) then
				local new = vim.split(replaced_line(line, item), "\n", { plain = true })
				vim.api.nvim_buf_set_lines(bufnr, item.lnum - 1, item.lnum, false, new)
				applied[#applied + 1] = item
			end
		end
		if #applied > 0 and not was_modified then
			vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent update") end)
		end
		return applied
	end
	local ok, lines = pcall(vim.fn.readfile, path, "b")
	if not ok then
		return applied
	end
	for _, item in ipairs(items) do
		local line = lines[item.lnum]
		if line and line == item.text then
			local new = vim.split(replaced_line(line, item), "\n", { plain = true })
			table.remove(lines, item.lnum)
			for i = #new, 1, -1 do
				table.insert(lines, item.lnum, new[i])
			end
			applied[#applied + 1] = item
		end
	end
	if #applied > 0 and vim.fn.writefile(lines, path, "b") ~= 0 then
		return {}
	end
	return applied
end

local function plural(n, word, suffix)
	return string.format("%d %s%s", n, word, n == 1 and "" or (suffix or "s"))
end

-- Applies `items` and drops the applied ones from the list; the selection then lands on the next match.
local function replace_items(state, items)
	local by_file, files = {}, {}
	for _, item in ipairs(items) do
		if item.replacements then
			if not by_file[item.filename] then
				by_file[item.filename] = {}
				files[#files + 1] = item.filename
			end
			table.insert(by_file[item.filename], item)
		end
	end
	local done, changed_files = {}, 0
	for _, path in ipairs(files) do
		local applied = replace_in_file(path, by_file[path])
		changed_files = changed_files + (#applied > 0 and 1 or 0)
		for _, item in ipairs(applied) do
			done[item] = true
		end
	end
	local count = vim.tbl_count(done)
	state.items = vim.tbl_filter(function(item) return not done[item] end, state.items)
	state.target = state.items
	notify_update(state)
	local skipped = #items - count
	vim.schedule(function()
		if skipped > 0 then
			nav.notify(string.format("replaced %s, skipped %s changed since the search", plural(count, "line"), plural(skipped, "line")))
		elseif #items > 1 then
			nav.notify(string.format("replaced %s in %s", plural(count, "line"), plural(changed_files, "file")), vim.log.levels.INFO)
		end
	end)
end

local search_actions = vim.list_extend(nav.jump_actions(), {
	{
		key = "<C-r>",
		name = "replace",
		when = function(ctx) return ctx.state.query ~= "" end,
		run = function(ctx)
			local state = ctx.state
			local prompt = ctx.input and ctx.input:get_value() or ("$" .. state.query)
			ctx.set_query("$")
			ctx.enter_context(context.replace({
				query = state.query,
				cwd = state.cwd,
				parent = ctx.context,
				exit_prompt = prompt,
				exit_panel = "live_grep",
			}), "live_grep_replace")
			return false
		end,
	},
})

-- Replacing, the rows only replace: jumping to or previewing a file there would compete for the same keys.
-- <CR> acts on what's selected, a file row or one match under it; <C-a> on everything, whatever is selected.
local replace_actions = {
	{
		key = "<CR>",
		name = function(ctx)
			return ctx.item and ctx.item.kind == "live_grep_file" and "replace file" or "replace"
		end,
		when = function(ctx) return ctx.item ~= nil end,
		run = function(ctx)
			if ctx.item.kind == "live_grep_file" then
				local path = ctx.item.filename
				replace_items(ctx.state, vim.tbl_filter(function(item) return item.filename == path end, ctx.state.items))
			else
				replace_items(ctx.state, { ctx.item })
			end
		end,
	},
	{
		key = "<C-a>",
		name = "replace all",
		when = function(ctx) return #ctx.state.items > 0 end,
		run = function(ctx)
			local state = ctx.state
			local files, matches = {}, 0
			for _, item in ipairs(state.items) do
				files[item.filename] = true
				matches = matches + #item.match_cols
			end
			local prompt = string.format("Replace %s in %s%s?", plural(matches, "match", "es"), plural(vim.tbl_count(files), "file"),
				state.stopped and string.format(" (only the first %d results were loaded)", RESULT_LIMIT) or "")
			if vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1 then
				replace_items(state, state.items)
			end
		end,
	},
}

function M.actions(ctx)
	return (ctx.state and ctx.state.replacing) and replace_actions or search_actions
end

-- A file row ahead of each file's matches, in rg's order. Rebuilt only when the matches change: the list
-- grows while rg streams (same table, longer) and is swapped for a new table after a replace or a rerun.
local function grouped_rows(state)
	local items = state.items
	if state._rows_for == items and state._rows_len == #items then
		return state._rows
	end
	local out, by_file = {}, {}
	local prefix = state.cwd and (vim.fn.fnamemodify(state.cwd, ":p"):gsub("/$", "") .. "/") or ""
	for _, item in ipairs(items) do
		local file = by_file[item.filename]
		if not file then
			local label = item.filename:sub(1, #prefix) == prefix and item.filename:sub(#prefix + 1) or item.filename
			file = { kind = "live_grep_file", filename = item.filename, path = item.filename, label = label, count = 0, first = item, matches = {} }
			by_file[item.filename] = file
			out[#out + 1] = file
		end
		file.count = file.count + #item.match_cols
		file.matches[#file.matches + 1] = item
	end
	local flat = {}
	for _, file in ipairs(out) do
		flat[#flat + 1] = file
		vim.list_extend(flat, file.matches)
		file.matches = nil
	end
	state._rows, state._rows_for, state._rows_len = flat, items, #items
	return flat
end

function M.init(ctx)
	local scoped = ctx and ctx.context
	local replacing = scoped and scoped.kind == "replace" or false
	local cwd = (replacing and scoped.cwd) or (scoped and scoped.kind == "folder" and scoped.path) or (ctx and ctx.cwd) or vim.fn.getcwd()
	local state = {
		on_update = ctx and ctx.on_update,
		cwd = cwd,
		query = "",
		items = {},
		token = 0,
		stopped = false,
		update_scheduled = false,
		-- In the replace context the search is fixed and the input is the replacement (nil: a plain search).
		replacing = replacing,
		search = replacing and scoped.query or nil,
		replacement = nil,
		input_context = (replacing and scoped) or (scoped and scoped.kind == "folder" and context.folder(cwd)) or nil,
	}
	state.target = state.items
	-- Replacing, the rows are grouped: each file, then its matches under it (see grouped_rows).
	local function rows()
		return state.replacing and grouped_rows(state) or state.items or {}
	end
	state.provider = {
		count = function()
			return #rows()
		end,
		get = function(_, index)
			return rows()[index]
		end,
	}
	return state
end

function M.input_context(state)
	return state and state.input_context or nil
end

function M.items(state, query)
	local q, replacement = vim.trim(query or ""), nil
	if state.replacing then
		-- Untrimmed: spaces around a replacement are part of it.
		q, replacement = state.search, query or ""
	end
	if q == "" then
		state.query = ""
		reset_results(state)
		state.token = state.token + 1
		stop_timer(state)
		stop_job(state)
		return state.provider
	end

	if q ~= state.query or replacement ~= state.replacement then
		-- Only the replacement changed: keep the rows (and the selection) up until the new preview is in.
		local swap = q == state.query and #state.items > 0
		state.query, state.replacement = q, replacement
		state.token = state.token + 1
		local token = state.token

		stop_timer(state)
		---@diagnostic disable-next-line: undefined-field
		state.timer = (vim.uv or vim.loop).new_timer()
		state.timer:start(DEBOUNCE_MS, 0, function()
			vim.schedule(function()
				if token ~= state.token or state.query ~= q then
					return
				end
				start_search(state, q, token, swap)
			end)
			stop_timer(state)
		end)
	end

	return state.provider
end

function M.dispose(state)
	if not state then
		return
	end
	stop_timer(state)
	stop_job(state)
	reset_results(state)
end

function M.total_count(state)
	local count = #(state.items or {})
	return {
		count = count,
		plus = count >= RESULT_LIMIT,
	}
end

return M
