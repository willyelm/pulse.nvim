local M = {}

M.defaults = {
	cmdline = false,
	initial_mode = "insert",
	position = "top",
	width = 0.50,
	height = 0.75,
	border = "rounded",
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return
