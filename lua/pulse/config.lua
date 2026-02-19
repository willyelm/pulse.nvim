local M = {}

M.defaults = {
	cmdline = false,
	keymaps = {
		open = "<leader>p",
		-- commands = "<leader>p:",
		-- workspace_symbol = "<leader>p#",
		-- symbol = "<leader>p@",
	},
	telescope = {
		initial_mode = "insert",
		prompt_prefix = "",
		selection_caret = " ",
		entry_prefix = " ",
		layout_strategy = "vertical",
		sorting_strategy = "ascending",
		layout_config = {
      anchor = "N",
      prompt_position = "top",
			height = 0.40,
			width = 0.70,
			preview_height = 0.45,
		},
	},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
