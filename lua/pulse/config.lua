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

local function is_list(value)
	if type(value) ~= "table" then
		return false
	end
	if vim.islist then
		return vim.islist(value)
	end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count = count + 1
	end
	for i = 1, count do
		if value[i] == nil then
			return false
		end
	end
	return true
end

local function picker_config(opts)
	local configured = opts and opts.pickers
	local legacy = (opts and opts.picker_options) or {}
	if configured == nil then
		return M.defaults.pickers, legacy
	end
	if is_list(configured) then
		return configured, legacy
	end
	if type(configured) ~= "table" then
		return M.defaults.pickers, legacy
	end

	local resolved = {}
	local per_picker = vim.deepcopy(legacy)
	local added = {}
	for _, name in ipairs(M.defaults.pickers) do
		local entry = configured[name]
		if entry ~= false then
			resolved[#resolved + 1] = name
			added[name] = true
			if type(entry) == "table" then
				per_picker[name] = vim.tbl_deep_extend("force", per_picker[name] or {}, entry)
			end
		end
	end
	for name, entry in pairs(configured) do
		if type(name) == "string" and not added[name] and entry ~= false then
			resolved[#resolved + 1] = name
			if type(entry) == "table" then
				per_picker[name] = vim.tbl_deep_extend("force", per_picker[name] or {}, entry)
			end
		end
	end
	return resolved, per_picker
end

function M.for_picker(mode_name)
	local per_picker = M.options._picker_options or {}
	return per_picker[mode_name] or {}
end

function M.setup(opts)
	local pickers_config, per_picker = picker_config(opts)
	local safe_opts = opts and vim.tbl_extend("force", {}, opts) or {}
	safe_opts.pickers = nil
	safe_opts.picker_options = nil
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
	M.options._picker_options = per_picker
	M.options._picker_registry = registry
	M.options._by_start = by_start
	M.options._default_mode = default_mode
end

return M
