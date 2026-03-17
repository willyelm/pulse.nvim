local M = {}
local util = require("pulse.util")

function M.seed(ctx)
	local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
	local state = { bufnr = bufnr, actions = {}, on_update = ctx and ctx.on_update, pending = 0 }

	-- Get cursor position
	local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
	if not ok or not cursor then
		return state
	end

	local row, col = cursor[1] - 1, cursor[2]
	local params = {
		textDocument = { uri = vim.uri_from_bufnr(bufnr) },
		range = { start = { line = row, character = col }, ["end"] = { line = row, character = col } },
		context = { diagnostics = vim.diagnostic.get(bufnr, { lnum = row }) },
	}

	-- Request from all clients
	local clients = vim.lsp.get_clients({ bufnr = bufnr })
	for _, client in ipairs(clients) do
		if client.supports_method("textDocument/codeAction") then
			state.pending = state.pending + 1
			client.request("textDocument/codeAction", params, function(err, result)
				if result and type(result) == "table" then
					for _, action in ipairs(result) do
						if action then
							local title = action.title or (type(action.command) == "string" and action.command) or ""
							if title ~= "" then
								state.actions[#state.actions + 1] = {
									kind = "code_action",
									title = title,
									action = action,
								}
							end
						end
					end
				end
				state.pending = state.pending - 1
				if state.pending == 0 and state.on_update then
					vim.schedule(function() state.on_update() end)
				end
			end, bufnr)
		end
	end

	return state
end

function M.items(state, query)
	local match = util.make_matcher(query or "", { ignore_case = true, plain = true })
	local out = {}
	for _, action in ipairs(state.actions) do
		if match(action.title) then out[#out + 1] = action end
	end
	return out
end

return M
