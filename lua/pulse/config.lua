local M = {
	defaults = {
		cmdline = false,
		initial_mode = "insert",
		position = "top",
		width = 0.50,
		height = 0.75,
		border = "rounded",
		pickers = {
			"files",
			"commands",
			"git_status",
			"diagnostics",
			"code_actions",
			"symbols",
			"workspace_symbols",
			"live_grep",
			"fuzzy_search",
		},
	},
}
M.options = M.defaults

function M.setup(opts)
	local pickers_config = (opts and opts.pickers) or M.defaults.pickers
	local safe_opts = opts and vim.tbl_extend("force", {}, opts) or {}
	safe_opts.pickers = nil
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), safe_opts)

	local pickers = {}
	local registry = {}
	local by_start = {}
	local default_mode = nil

	for _, p in ipairs(pickers_config) do
		local picker_module
		if type(p) == "string" then
			local ok, mod = pcall(require, "pulse.pickers." .. p)
			if ok and mod then
				picker_module = mod
			else
				vim.notify("Pulse: failed to load picker '" .. p .. "'", vim.log.levels.WARN)
			end
		elseif type(p) == "table" then
			picker_module = p
		else
			vim.notify("Pulse: invalid picker entry (must be string name or module)", vim.log.levels.WARN)
		end

		if
			picker_module
			and picker_module.mode
			and picker_module.mode.name
			and type(picker_module.init) == "function"
			and type(picker_module.items) == "function"
		then
			local mode_name = picker_module.mode.name
			if registry[mode_name] then
				vim.notify("Pulse: duplicate picker name '" .. mode_name .. "'", vim.log.levels.WARN)
			else
				pickers[#pickers + 1] = picker_module
				registry[mode_name] = picker_module

				-- Build prefix routing
				if picker_module.mode.start and picker_module.mode.start ~= "" then
					if by_start[picker_module.mode.start] then
						vim.notify(
							"Pulse: prefix '"
								.. picker_module.mode.start
								.. "' already taken, ignoring picker '"
								.. mode_name
								.. "'",
							vim.log.levels.WARN
						)
					else
						by_start[picker_module.mode.start] = { mode = mode_name, strip = #picker_module.mode.start + 1 }
					end
				else
					default_mode = mode_name
				end
			end
		else
			vim.notify("Pulse: invalid picker entry in pickers list", vim.log.levels.WARN)
		end
	end

	M.options.pickers = pickers
	M.options._picker_registry = registry
	M.options._by_start = by_start
	M.options._default_mode = default_mode
end

return M
