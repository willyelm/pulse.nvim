local M = {}
local scope = require("pulse.scope")

M.mode = {
	name = "code_action",
	start = ">",
	icon = "󰌶",
	placeholder = "Code Actions",
}

M.context = false
M.scope_aware = true
M.scope_clears_to_files = true

local function apply_action(action, client, req_ctx)
	if action.edit then
		vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
	end

	local command = action.command
	if command then
		client:exec_cmd(type(command) == "table" and command or action, req_ctx)
	end
end

local function execute(item)
	local req_ctx = item and item.lsp_ctx
	local client = req_ctx and req_ctx.client_id and vim.lsp.get_client_by_id(req_ctx.client_id) or nil
	if not client then
		vim.notify("Pulse: code action client is no longer available", vim.log.levels.WARN)
		return false
	end

	local action = item.action
	if type(action.title) == "string" and type(action.command) == "string" then
		apply_action(action, client, req_ctx)
		return true
	end

	if not (action.edit and action.command) and client:supports_method("codeAction/resolve") then
		client:request("codeAction/resolve", action, function(err, resolved)
			if err then
				if action.edit or action.command then
					apply_action(action, client, req_ctx)
				else
					vim.notify(err.code .. ": " .. err.message, vim.log.levels.ERROR)
				end
				return
			end
			apply_action(resolved, client, req_ctx)
		end, req_ctx.bufnr)
		return true
	end

	apply_action(action, client, req_ctx)
	return true
end

function M.init(ctx)
	local scoped = ctx and ctx.scope
	local bufnr = (scoped and scoped.kind == "file" and (scoped.bufnr or vim.fn.bufadd(scoped.path)))
		or (ctx and ctx.bufnr)
		or vim.api.nvim_get_current_buf()
	pcall(vim.fn.bufload, bufnr)
	local win = ctx and ctx.win or 0
	local state = {
		actions = {},
		input_scope = (scoped and scoped.kind == "file" and scope.file(scoped.path, bufnr)) or scope.from_buffer(bufnr),
	}

	local cursor = nil
	if scoped and scoped.kind == "file" then
		local mark = vim.api.nvim_buf_get_mark(bufnr, '"')
		cursor = { math.max(mark[1], 1), math.max(mark[2], 0) }
	else
		local ok, current = pcall(vim.api.nvim_win_get_cursor, win)
		if ok then
			cursor = current
		end
	end
	if not cursor then
		return state
	end

	local row, col = cursor[1] - 1, cursor[2]
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/codeAction" })) do
		---@type lsp.CodeActionParams
		local params = {
			textDocument = vim.lsp.util.make_text_document_params(bufnr),
			range = {
				start = { line = row, character = col },
				["end"] = { line = row, character = col },
			},
		}
		params.context = {
			triggerKind = vim.lsp.protocol.CodeActionTriggerKind.Invoked,
			diagnostics = {},
		}

		for _, is_pull in ipairs({ false, true }) do
			local namespace = vim.lsp.diagnostic.get_namespace(client.id, is_pull)
			for _, diagnostic in ipairs(vim.diagnostic.get(bufnr, { namespace = namespace, lnum = row })) do
				local lsp_diagnostic = diagnostic.user_data and diagnostic.user_data.lsp
				if lsp_diagnostic then
					params.context.diagnostics[#params.context.diagnostics + 1] = lsp_diagnostic
				end
			end
		end

		client:request("textDocument/codeAction", params, function(_, result, req_ctx)
			for _, action in ipairs(result or {}) do
				local title = action.title or (type(action.command) == "string" and action.command) or ""
				if title ~= "" then
					state.actions[#state.actions + 1] = {
						kind = "code_action",
						title = title,
						action = action,
						lsp_ctx = req_ctx and { bufnr = req_ctx.bufnr, client_id = req_ctx.client_id } or nil,
						execute = execute,
					}
				end
			end
			if ctx and ctx.on_update then vim.schedule(ctx.on_update) end
		end, bufnr)
	end

	return state
end

function M.input_scope(state)
	return state and state.input_scope or nil
end

function M.items(state, query)
	local pulse = require("pulse")
	local match = pulse.make_matcher(query or "", { ignore_case = true, plain = true })
	local out = {}
	for _, action in ipairs(state.actions) do
		if match(action.title) then table.insert(out, action) end
	end
	return out
end

return M
