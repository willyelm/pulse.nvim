local M = {}

function M.jump_to(selection)
	local function edit_target(path)
		local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
		if not ok then
			vim.notify(tostring(err), vim.log.levels.WARN)
			return false
		end
		return true
	end

	if selection and type(selection.execute) == "function" then
		return selection.execute(selection)
	end

	if selection.kind == "file" then
		return edit_target(selection.path)
	end

	if selection.filename and selection.filename ~= "" then
		if not edit_target(selection.filename) then
			return false
		end
	end

	if selection.lnum then
		vim.api.nvim_win_set_cursor(0, { selection.lnum, math.max((selection.col or 1) - 1, 0) })
	end

	return true
end

return M
