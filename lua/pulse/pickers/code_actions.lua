local M = {}
local util = require("pulse.util")

function M.seed(ctx)
	local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
	local state = { bufnr = bufnr, actions = {} }

	-- Get cursor position before picker opens
	local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
	if not ok or not cursor then
		return state
	end

	local row = cursor[1] - 1
	local col = cursor[2]

	-- Fetch code actions
	local results = vim.lsp.buf_request_sync(bufnr, "textDocument/codeAction", {
		textDocument = { uri = vim.uri_from_bufnr(bufnr) },
		range = {
			start = { line = row, character = col },
			["end"] = { line = row, character = col },
		},
		context = { diagnostics = vim.diagnostic.get(bufnr, { lnum = row }) },
	}, 2000)

	if results then
		for client_id, response in pairs(results) do
			if response and response.result and type(response.result) == "table" then
				for _, action in ipairs(response.result) do
					if action and action.title then
						state.actions[#state.actions + 1] = {
							kind = "code_action",
							title = action.title,
							action = action,
						}
					end
				end
			end
		end
	end

	return state
end

function M.items(state, query)
	local match = util.make_matcher(query or "", { ignore_case = true, plain = true })
	local out = {}

	for _, action in ipairs(state.actions) do
		if match(action.title) then
			out[#out + 1] = action
		end
	end

	return out
end

return M
