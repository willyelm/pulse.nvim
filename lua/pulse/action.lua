local M = {}

local function target_path(selection)
	return selection and (selection.kind == "file" and selection.path or selection.filename) or nil
end

function M.jump_to(selection)
	if selection and type(selection.execute) == "function" then
		return selection.execute(selection)
	end

	local path = target_path(selection)
	if path and path ~= "" then
		local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
		if not ok then
			vim.notify(tostring(err), vim.log.levels.WARN)
			return false
		end
	end

	if selection.lnum then
		vim.api.nvim_win_set_cursor(0, { selection.lnum, math.max((selection.col or 1) - 1, 0) })
	end

	return true
end

return M
