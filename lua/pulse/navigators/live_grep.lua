local M = {}
local view = require("pulse.panel_view")
local context = require("pulse.context")

M.name = "live_grep"
M.icon = "󰍉"
M.actions = {
	{
		key = "<CR>",
		name = "jump",
		when = function(ctx)
			return ctx and ctx.item ~= nil
		end,
		run = function(ctx)
			if ctx and ctx.item then
				ctx.jump(ctx.item)
				ctx.close()
				return false
			end
		end,
	},
	{
		key = "<Tab>",
		name = "preview",
		when = function(ctx)
			return ctx and ctx.item ~= nil
		end,
		run = function(ctx)
			if ctx and ctx.item then
				ctx.preview(ctx.item)
			end
		end,
	},
}
M.panels = {
	{ start = "$", name = "live_grep", label = "Live Grep", contexts = { "workspace", "folder" } },
}

M.view = true

function M.view_item(item)
	return view.file_snippet(item.path or item.filename, item.lnum, item.query, item.match_cols)
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
	for _, submatch in ipairs(data.submatches or {}) do
		local s, e = submatch.start, submatch["end"]
		if type(s) == "number" and type(e) == "number" and e > s then
			first_col = first_col or (s + 1)
			match_cols[#match_cols + 1] = { s + 1, e }
		end
	end
	if path ~= "" and data.line_number then
		state.items[#state.items + 1] = {
			kind = "live_grep",
			path = path,
			filename = path,
			lnum = data.line_number,
			col = first_col or 1,
			text = text,
			leading = #(text:match("^%s*") or ""),
			query = query,
			match_cols = match_cols,
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
		if #(state.items or {}) >= RESULT_LIMIT then
			state.stopped = true
			stop_job(state)
			notify_update(state)
			return
		end
		append_line(state, lines[i], query)
	end
	if #state.items > 0 then
		notify_update(state)
	end
	if last < #lines then
		vim.schedule(function()
			append_lines_chunked(state, lines, query, token, last + 1)
		end)
	end
end

local function start_search(state, query, token)
	stop_job(state)
	state.items = {}
	state.stopped = false

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
		query,
		state.cwd or ".",
	}

	state.job = vim.fn.jobstart(cmd, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			if token ~= state.token then
				return
			end
			if not data or #data == 0 then
				return
			end
			append_lines_chunked(state, data, query, token, 1)
		end,
		on_exit = function(_, code)
			if token ~= state.token then
				return
			end
			state.job = nil
			-- A bad pattern shows empty results, not a notification: typing passes through invalid states constantly.
			if not (code == 0 or code == 1 or state.stopped) then
				state.items = {}
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

function M.init(ctx)
	local scoped = ctx and ctx.context
	local cwd = (scoped and scoped.kind == "folder" and scoped.path) or (ctx and ctx.cwd) or vim.fn.getcwd()
	local state = {
		on_update = ctx and ctx.on_update,
		cwd = cwd,
		query = "",
		items = {},
		token = 0,
		stopped = false,
		update_scheduled = false,
		input_context = (scoped and scoped.kind == "folder" and context.folder(cwd)) or nil,
	}
	state.provider = {
		count = function()
			return #(state.items or {})
		end,
		get = function(_, index)
			return state.items and state.items[index] or nil
		end,
	}
	return state
end

function M.input_context(state)
	return state and state.input_context or nil
end

function M.items(state, query)
	local q = vim.trim(query or "")
	if q == "" then
		state.query = ""
		reset_results(state)
		state.token = state.token + 1
		stop_timer(state)
		stop_job(state)
		return state.provider
	end

	if q ~= state.query then
		state.query = q
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
				start_search(state, q, token)
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
