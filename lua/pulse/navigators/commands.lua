local M = {}

M.mode = {
	name = "commands",
	icon = "",
}

M.context = false
M.allow_empty_selection = true
M.panels = {
	{ start = ":", name = "commands", label = "Commands", scopes = { "workspace" } },
}

local function format_cmd_error(err)
	local msg = tostring(err or "")
	local vim_err = msg:match("Vim%b():(.+)$")
	if vim_err and vim_err ~= "" then
		return vim.trim(vim_err)
	end
	local exec_err = msg:match("nvim_exec2%(%), line %d+:%s*(.+)$")
	if exec_err and exec_err ~= "" then
		return vim.trim(exec_err)
	end
	return msg
end

function M.on_submit(ctx)
	local raw = ctx.input and ctx.input:get_value() or ctx.query or ""
	ctx.close()
	M.execute(raw)
end

function M.on_tab(ctx)
	if not ctx.item or not ctx.input then
		return
	end
	local cmd = tostring(ctx.item.command or ""):gsub("^:", "")
	ctx.input:set_value((ctx.surface and ctx.surface.start or "") .. cmd)
	ctx.input:focus(true)
end

local function execute(item)
	local ex = vim.trim((item and item.command) or ""):gsub("^:", "")
	if ex == "" then
		return false
	end
	vim.schedule(function()
		local ok, err = pcall(function()
			vim.cmd(ex)
		end)
		if not ok then
			vim.notify(format_cmd_error(err), vim.log.levels.ERROR)
		end
	end)
	return true
end

function M.init(ctx)
	local history = {}
	local seen = {}
	local last = vim.fn.histnr(":")
	for i = last, math.max(1, last - 250), -1 do
		local cmd = vim.fn.histget(":", i)
		if cmd ~= "" and not seen[cmd] then
			seen[cmd] = true
			history[#history + 1] = cmd
		end
	end

	local commands = {}
	seen = {}
	for _, cmd in ipairs(vim.fn.getcompletion("", "command")) do
		if cmd ~= "" and not seen[cmd] then
			seen[cmd] = true
			commands[#commands + 1] = cmd
		end
	end
	table.sort(commands)

	return { history = history, commands = commands }
end

function M.items(state, query)
	query = query or ""
	local pulse = require("pulse")
	local match = pulse.make_matcher(query, { ignore_case = true, plain = true })
	local items, seen = {}, {}
	local show_history = query == ""

	if show_history then
		for _, cmd in ipairs(state.history) do
			if match(cmd) then
				seen[cmd] = true
				items[#items + 1] = { kind = "command", command = cmd }
			end
		end
	end

	for _, cmd in ipairs(state.commands) do
		if not seen[cmd] and match(cmd) then
			items[#items + 1] = { kind = "command", command = cmd }
		end
	end

	return items
end

function M.execute(cmd)
	return execute({ command = cmd })
end

return M
