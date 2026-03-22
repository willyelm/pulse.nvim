local scope = require("pulse.scope")

local M = {}

function M.valid(bufnr)
	return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

function M.resolve(ctx)
	local scoped = ctx and ctx.scope or nil
	local bufnr = nil

	if scoped and scoped.kind == "file" then
		bufnr = scoped.bufnr
		if not M.valid(bufnr) and scoped.path and scoped.path ~= "" then
			local existing = vim.fn.bufnr(scoped.path)
			if type(existing) == "number" and existing > 0 then
				bufnr = existing
			else
				bufnr = vim.fn.bufadd(scoped.path)
			end
		end
	end

	if not M.valid(bufnr) then
		bufnr = ctx and ctx.bufnr or nil
	end
	if not M.valid(bufnr) then
		bufnr = vim.api.nvim_get_current_buf()
	end

	return M.valid(bufnr) and bufnr or nil
end

function M.input_scope(ctx, bufnr)
	local scoped = ctx and ctx.scope or nil
	if scoped and scoped.kind == "file" and scoped.path and bufnr then
		return scope.file(scoped.path, bufnr)
	end
	if bufnr then
		return scope.from_buffer(bufnr)
	end
	return nil
end

return M
