local M = {}

M.defaults = {
	cmdline = false,
	telescope = {
		initial_mode = "insert",
		prompt_prefix = "",
		selection_caret = " ",
		entry_prefix = " ",
		sorting_strategy = "ascending",
		layout_config = {
			width = 0.60,
			height = 0.50,
			prompt_position = "top",
			anchor = "N",
		},
		border = true,
	},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
