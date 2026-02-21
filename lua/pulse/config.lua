local M = {}

local ui_defaults = {
	initial_mode = "insert",
	prompt_prefix = "",
	selection_caret = " ",
	entry_prefix = " ",
	sorting_strategy = "ascending",
	layout_config = {
		width = 0.70,
		height = 0.50,
		prompt_position = "top",
		anchor = "N",
	},
	border = true,
}

M.defaults = {
	cmdline = false,
	ui = vim.deepcopy(ui_defaults),
	-- Backward compatibility for older configs.
	telescope = vim.deepcopy(ui_defaults),
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	if opts and opts.telescope and not opts.ui then
		M.options.ui = vim.tbl_deep_extend("force", vim.deepcopy(ui_defaults), opts.telescope)
	end
	M.options.telescope = vim.deepcopy(M.options.ui)
end

return M
