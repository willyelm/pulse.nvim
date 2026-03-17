local M = {}
local util = require("pulse.util")

function M.seed(ctx)
	local bufnr = ctx and ctx.bufnr or vim.api.nvim_get_current_buf()
	local win = ctx and ctx.win or 0
	local state = { actions = {} }

	local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
	if not ok or not cursor then return state end

	local row, col = cursor[1] - 1, cursor[2]
	vim.lsp.buf_request(bufnr, "textDocument/codeAction", {
		textDocument = { uri = vim.uri_from_bufnr(bufnr) },
		range = { start = { line = row, character = col }, ["end"] = { line = row, character = col } },
		context = { diagnostics = vim.diagnostic.get(bufnr, { lnum = row }) },
	}, function(_, result)
		if result and type(result) == "table" then
			for _, action in ipairs(result) do
				if action then
					local title = action.title or (type(action.command) == "string" and action.command) or ""
					if title ~= "" then
						table.insert(state.actions, { kind = "code_action", title = title, action = action })
					end
				end
			end
		end
		if ctx and ctx.on_update then vim.schedule(ctx.on_update) end
	end)

	return state
end

function M.items(state, query)
	local match = util.make_matcher(query or "", { ignore_case = true, plain = true })
	local out = {}
	for _, action in ipairs(state.actions) do
		if match(action.title) then table.insert(out, action) end
	end
	return out
end

return M
